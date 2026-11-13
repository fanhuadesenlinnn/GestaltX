// SPDX-License-Identifier: GPL-3.0-only
//! GestaltX native device console — C FFI surface.
//!
//! Scope: on-device self-pairing (RPPairing host) and streaming the device's own
//! `com.apple.syslog_relay` over a loopback RSD tunnel, so GestaltX can learn
//! which app played which notification sound. It deliberately does NOT include
//! AirCard's Airlift file-injection exploit — only the pairing + console path.
//!
//! All fallible calls return an int32 (0 == OK). Heap strings returned by this
//! library must be released with `gx_string_free`. The device-backed
//! implementation is compiled only with the `device` feature (built for iOS on a
//! toolchain that has cmake/nasm and the aws-lc C sources); without it the FFI is
//! present and the session lifecycle still works, but pairing/syslog return an
//! error so the crate can be built and unit-tested on any host.

use std::ffi::{c_char, c_void, CStr, CString};

mod session;
#[cfg(feature = "device")]
mod device;

// ---------------------------------------------------------------------------
// Small FFI helpers
// ---------------------------------------------------------------------------

fn opt_str(p: *const c_char, default: &str) -> String {
    if p.is_null() {
        return default.to_owned();
    }
    // Safety: the caller guarantees a valid C string or null.
    unsafe { CStr::from_ptr(p) }.to_str().unwrap_or(default).to_owned()
}

fn cstr(s: impl std::fmt::Display) -> *mut c_char {
    CString::new(format!("{s}"))
        .unwrap_or_else(|_| CString::new("(invalid string)").unwrap())
        .into_raw()
}

/// Free any `*mut c_char` returned by this library.
///
/// # Safety
/// `p` must be null or a pointer previously returned by this library.
#[no_mangle]
pub unsafe extern "C" fn gx_string_free(p: *mut c_char) {
    if !p.is_null() {
        drop(CString::from_raw(p));
    }
}

// ---------------------------------------------------------------------------
// Logging
// ---------------------------------------------------------------------------

pub type GXLogCallback = Option<extern "C" fn(ctx: *mut c_void, msg: *const c_char)>;

/// Install the log forwarder. Returns 0 on success, 1 if already initialised.
/// The callback never receives pairing PINs or key material.
#[no_mangle]
pub extern "C" fn gx_console_log_init(cb: GXLogCallback, ctx: *mut c_void) -> i32 {
    #[cfg(feature = "device")]
    {
        device::log_init(cb, ctx)
    }
    #[cfg(not(feature = "device"))]
    {
        let _ = (cb, ctx);
        0
    }
}

// ---------------------------------------------------------------------------
// Target host configuration
// ---------------------------------------------------------------------------

/// Set candidate target hosts to dial for the RSD tunnel (e.g. the loopback VPN
/// gateway the user enabled). Loopback 127.0.0.1 is never dialled by the native
/// layer. `hosts` is an array of `count` C strings.
///
/// # Safety
/// `hosts` must point to `count` valid C strings, or be null when `count` is 0.
#[no_mangle]
pub unsafe extern "C" fn gx_console_set_target_hosts(hosts: *const *const c_char, count: usize) {
    let mut out = Vec::with_capacity(count);
    if !hosts.is_null() {
        for i in 0..count {
            let p = *hosts.add(i);
            if !p.is_null() {
                out.push(opt_str(p, ""));
            }
        }
    }
    #[cfg(feature = "device")]
    device::set_target_hosts(out);
    #[cfg(not(feature = "device"))]
    let _ = out;
}

#[no_mangle]
pub extern "C" fn gx_console_clear_target_hosts() {
    #[cfg(feature = "device")]
    device::clear_target_hosts();
}

// ---------------------------------------------------------------------------
// Session lifecycle
// ---------------------------------------------------------------------------

/// Reserve a new session generation. Returns 0 if a session is already active
/// (only one pairing/capture runs at a time), otherwise a non-zero generation to
/// pass to `gx_pairing_run_host` / `gx_syslog_run` and `gx_session_cancel`.
#[no_mangle]
pub extern "C" fn gx_session_begin() -> u64 {
    match session::begin() {
        Some((generation, _token)) => generation,
        None => 0,
    }
}

/// Request cancellation of `generation`. Returns promptly; the blocked run
/// function unwinds its connection and returns on its own thread.
#[no_mangle]
pub extern "C" fn gx_session_cancel(generation: u64) {
    session::cancel(generation);
}

// ---------------------------------------------------------------------------
// Pairing — RPPairing host
// ---------------------------------------------------------------------------

pub type GXPairReadyCb = Option<
    extern "C" fn(
        ctx: *mut c_void,
        service_id: *const c_char,
        port: u16,
        txt_keys: *const *const c_char,
        txt_vals: *const *const c_char,
        txt_count: usize,
    ),
>;

pub type GXPairPinCb = Option<extern "C" fn(ctx: *mut c_void, pin: *const c_char)>;

#[repr(C)]
pub struct GXPairResult {
    pub error: *mut c_char,
    pub device_name: *mut c_char,
    pub device_model: *mut c_char,
    pub device_udid: *mut c_char,
    pub pairing_file_path: *mut c_char,
    pub host_alt_irk_hex: *mut c_char,
}

impl GXPairResult {
    fn empty() -> Self {
        Self {
            error: std::ptr::null_mut(),
            device_name: std::ptr::null_mut(),
            device_model: std::ptr::null_mut(),
            device_udid: std::ptr::null_mut(),
            pairing_file_path: std::ptr::null_mut(),
            host_alt_irk_hex: std::ptr::null_mut(),
        }
    }
}

/// Run the RPPairing host for `generation`. BLOCKS until paired, cancelled, or
/// errored — call on a background thread. Cancel with `gx_session_cancel`.
///
/// # Safety
/// All `*const c_char` args must be null or valid C strings; `out` must point to
/// a writable `GXPairResult`.
#[allow(clippy::too_many_arguments)]
#[no_mangle]
pub unsafe extern "C" fn gx_pairing_run_host(
    generation: u64,
    bind_addr: *const c_char,
    port: u16,
    name: *const c_char,
    model: *const c_char,
    out_path: *const c_char,
    host_alt_irk_hex: *const c_char,
    ready_cb: GXPairReadyCb,
    pin_cb: GXPairPinCb,
    ctx: *mut c_void,
    out: *mut GXPairResult,
) -> i32 {
    if out.is_null() {
        return 2;
    }
    *out = GXPairResult::empty();

    let Some(token) = session::token_for(generation) else {
        (*out).error = cstr("pairing session is not active");
        return 3;
    };

    #[cfg(feature = "device")]
    let result = {
        let params = device::PairParams {
            bind_addr: opt_str(bind_addr, "0.0.0.0"),
            port,
            name: opt_str(name, "GestaltX"),
            model: opt_str(model, "iPhone"),
            out_path: opt_str(out_path, "gestaltx_pairing.plist"),
            host_alt_irk_hex: opt_str(host_alt_irk_hex, ""),
        };
        device::run_pairing_host(token, params, ready_cb, pin_cb, ctx)
    };
    #[cfg(not(feature = "device"))]
    let result: Result<device_stub::PairOk, String> = {
        let _ = (bind_addr, port, name, model, out_path, host_alt_irk_hex, ready_cb, pin_cb, ctx, &token);
        Err("device backend not built in this binary".to_owned())
    };

    session::end(generation);

    match result {
        Ok(ok) => {
            (*out).device_name = cstr(ok.device_name);
            (*out).device_model = cstr(ok.device_model);
            (*out).device_udid = cstr(ok.device_udid);
            (*out).pairing_file_path = cstr(ok.pairing_file_path);
            (*out).host_alt_irk_hex = cstr(ok.host_alt_irk_hex);
            0
        }
        Err(e) => {
            (*out).error = cstr(e);
            1
        }
    }
}

/// Free the heap strings inside a `GXPairResult`.
///
/// # Safety
/// `r` must be null or a `GXPairResult` populated by `gx_pairing_run_host`.
#[no_mangle]
pub unsafe extern "C" fn gx_pair_result_free(r: *mut GXPairResult) {
    if r.is_null() {
        return;
    }
    for p in [
        (*r).error,
        (*r).device_name,
        (*r).device_model,
        (*r).device_udid,
        (*r).pairing_file_path,
        (*r).host_alt_irk_hex,
    ] {
        if !p.is_null() {
            drop(CString::from_raw(p));
        }
    }
    *r = GXPairResult::empty();
}

// ---------------------------------------------------------------------------
// Syslog capture
// ---------------------------------------------------------------------------

pub type GXSyslogLineCallback = Option<extern "C" fn(ctx: *mut c_void, line: *const c_char)>;

/// Stream `com.apple.syslog_relay` for `generation`. BLOCKS until cancelled, EOF,
/// or error — call on a background thread. Each decoded line is delivered to
/// `line_cb` (bounded to 64 KiB per line). Cancel with `gx_session_cancel`.
///
/// # Safety
/// `pairing_path` must be null or a valid C string; `out_error` must be null or
/// a writable `*mut c_char`.
#[no_mangle]
pub unsafe extern "C" fn gx_syslog_run(
    generation: u64,
    pairing_path: *const c_char,
    line_cb: GXSyslogLineCallback,
    ctx: *mut c_void,
    out_error: *mut *mut c_char,
) -> i32 {
    let Some(token) = session::token_for(generation) else {
        if !out_error.is_null() {
            *out_error = cstr("syslog session is not active");
        }
        return 3;
    };

    #[cfg(feature = "device")]
    let result = device::run_syslog(token, opt_str(pairing_path, "gestaltx_pairing.plist"), line_cb, ctx);
    #[cfg(not(feature = "device"))]
    let result: Result<(), String> = {
        let _ = (pairing_path, line_cb, ctx, &token);
        Err("device backend not built in this binary".to_owned())
    };

    session::end(generation);

    match result {
        Ok(()) => 0,
        Err(e) => {
            if !out_error.is_null() {
                *out_error = cstr(e);
            }
            1
        }
    }
}

// Host-only placeholder type so the non-device branch has a concrete Ok type.
#[cfg(not(feature = "device"))]
mod device_stub {
    pub struct PairOk {
        pub device_name: String,
        pub device_model: String,
        pub device_udid: String,
        pub pairing_file_path: String,
        pub host_alt_irk_hex: String,
    }
}
