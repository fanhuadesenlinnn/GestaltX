// SPDX-License-Identifier: GPL-3.0-only
//! Device-backed implementation (feature = "device").
//!
//! The RSD/Lockdown tunnel selection, RPPairing host, and syslog read loop are
//! adapted from AirCard-iOS (MIT, Johnny Franks) — connection path only, no
//! Airlift exploit — over the MIT `idevice` crate. Differences from the
//! reference, per the integration plan:
//!   * Serialized, generation-scoped cancellation via a real `CancelToken`
//!     (not a global `AtomicBool`); the connect phase and the read loop are
//!     cancelled through `tokio::select!`.
//!   * The pairing PIN and key material are never logged.

use std::ffi::{c_char, c_void, CString};
use std::net::{IpAddr, Ipv4Addr, SocketAddr};
use std::sync::{Arc, Mutex};

use idevice::pairing_file::PairingFile;
use idevice::provider::{IdeviceProvider, TcpProvider};
use idevice::remote_pairing::{
    PairableHost, PairableHostInfo, RpPairingFile, RpPairingSocket,
};
use idevice::services::lockdown::LockdownClient;
use idevice::{Idevice, IdeviceService, ReadWrite};
use tokio::io::AsyncReadExt;
use tokio::net::TcpListener;

use crate::session::CancelToken;
use crate::{GXLogCallback, GXPairPinCb, GXPairReadyCb, GXSyslogLineCallback};

/// RSD port exposed by the loopback VPN tunnel (LocalDevVPN default).
const RSD_PORT: u16 = 49152;

// ---------------------------------------------------------------------------
// Large-stack runner — iOS GCD / Swift cooperative threads have tiny stacks.
// ---------------------------------------------------------------------------

fn run_with_large_stack<F, R>(name: &str, f: F) -> Result<R, String>
where
    F: FnOnce() -> R + Send + 'static,
    R: Send + 'static,
{
    std::thread::Builder::new()
        .name(name.to_string())
        .stack_size(4 * 1024 * 1024)
        .spawn(f)
        .map_err(|e| format!("failed to spawn worker '{name}': {e}"))?
        .join()
        .map_err(|e| format!("worker '{name}' panicked: {e:?}"))
}

// ---------------------------------------------------------------------------
// Logging
// ---------------------------------------------------------------------------

pub fn log_init(cb: GXLogCallback, ctx: *mut c_void) -> i32 {
    logging::init(cb, ctx)
}

mod logging {
    use super::{GXLogCallback, CString};
    use std::ffi::{c_char, c_void};
    use std::io;
    use std::sync::atomic::{AtomicPtr, AtomicUsize, Ordering};
    use std::sync::OnceLock;

    static LOG_CB: AtomicUsize = AtomicUsize::new(0);
    static LOG_CTX: AtomicPtr<c_void> = AtomicPtr::new(std::ptr::null_mut());
    static INIT: OnceLock<()> = OnceLock::new();

    pub fn emit(msg: &str) {
        let addr = LOG_CB.load(Ordering::Relaxed);
        if addr == 0 {
            return;
        }
        let cb: extern "C" fn(*mut c_void, *const c_char) = unsafe { std::mem::transmute(addr) };
        let ctx = LOG_CTX.load(Ordering::Relaxed);
        if let Ok(c) = CString::new(msg) {
            cb(ctx, c.as_ptr());
        }
    }

    struct FfiWriter;
    impl io::Write for FfiWriter {
        fn write(&mut self, buf: &[u8]) -> io::Result<usize> {
            let msg = String::from_utf8_lossy(buf).trim_end_matches('\n').to_string();
            if !msg.is_empty() {
                emit(&msg);
            }
            Ok(buf.len())
        }
        fn flush(&mut self) -> io::Result<()> {
            Ok(())
        }
    }
    unsafe impl Send for FfiWriter {}
    unsafe impl Sync for FfiWriter {}

    pub fn init(cb: GXLogCallback, ctx: *mut c_void) -> i32 {
        if INIT.set(()).is_err() {
            return 1;
        }
        if let Some(f) = cb {
            LOG_CB.store(f as usize, Ordering::Relaxed);
            LOG_CTX.store(ctx, Ordering::Relaxed);
        }
        let subscriber = tracing_subscriber::fmt()
            .with_writer(|| FfiWriter)
            .with_ansi(false)
            .finish();
        let _ = tracing::subscriber::set_global_default(subscriber);
        0
    }
}

struct Logger {
    cb: GXLogCallback,
    ctx: *mut c_void,
}
unsafe impl Send for Logger {}
unsafe impl Sync for Logger {}

impl Logger {
    fn silent() -> Self {
        Logger { cb: None, ctx: std::ptr::null_mut() }
    }
    fn log(&self, msg: impl AsRef<str>) {
        let s = msg.as_ref();
        tracing::info!("{s}");
        if let Some(cb) = self.cb {
            if let Ok(c) = CString::new(s) {
                cb(self.ctx, c.as_ptr());
            }
        }
    }
}

// ---------------------------------------------------------------------------
// Target host configuration
// ---------------------------------------------------------------------------

static TARGET_HOSTS: Mutex<Vec<String>> = Mutex::new(Vec::new());

pub fn set_target_hosts(hosts: Vec<String>) {
    if let Ok(mut lock) = TARGET_HOSTS.lock() {
        *lock = hosts;
    }
}

pub fn clear_target_hosts() {
    if let Ok(mut lock) = TARGET_HOSTS.lock() {
        lock.clear();
    }
}

fn resolve_target_hosts() -> Vec<String> {
    let mut targets: Vec<String> = Vec::new();
    if let Ok(guard) = TARGET_HOSTS.lock() {
        for host in guard.iter() {
            let h = host.trim();
            if !h.is_empty() && !targets.contains(&h.to_string()) {
                targets.push(h.to_string());
            }
        }
    }
    // Known default loopback-VPN gateways. Never 127.0.0.1: connecting to it
    // makes remotepairingdeviced drop the control channel until Developer Mode
    // is toggled.
    for fb in ["10.7.0.1", "10.7.0.2", "10.7.0.3", "10.0.0.1", "172.16.0.1"] {
        let s = fb.to_string();
        if !targets.contains(&s) {
            targets.push(s);
        }
    }
    targets
}

// ---------------------------------------------------------------------------
// Tunnel — RSD or Lockdown (connection path only, adapted from AirCard)
// ---------------------------------------------------------------------------

enum AppDeviceTunnel {
    Rsd {
        adapter: idevice::tcp::handle::AdapterHandle,
        handshake: idevice::services::rsd::RsdHandshake,
    },
    Lockdown {
        provider: TcpProvider,
        pairing_file: PairingFile,
        legacy: bool,
    },
}

impl AppDeviceTunnel {
    async fn connect_service(&mut self, service_base: &str, logger: &Logger) -> Result<Box<dyn ReadWrite>, String> {
        match self {
            AppDeviceTunnel::Rsd { adapter, handshake } => {
                connect_service_rsd(adapter, handshake, service_base, logger).await
            }
            AppDeviceTunnel::Lockdown { provider, pairing_file, legacy } => {
                connect_service_lockdown(provider, pairing_file, *legacy, service_base, logger).await
            }
        }
    }
}

async fn connect_service_lockdown(
    provider: &TcpProvider,
    pairing_file: &PairingFile,
    legacy: bool,
    service_name: &str,
    logger: &Logger,
) -> Result<Box<dyn ReadWrite>, String> {
    logger.log(format!("console: starting '{service_name}' via Lockdown..."));
    let mut lockdown = LockdownClient::connect(provider)
        .await
        .map_err(|e| format!("Lockdown connect failed: {e:?}"))?;
    let _ = lockdown
        .start_session(pairing_file)
        .await
        .map_err(|e| format!("Lockdown start_session failed: {e:?}"))?;
    let (port, ssl) = lockdown
        .start_service(service_name)
        .await
        .map_err(|e| format!("Lockdown start_service('{service_name}') failed: {e:?}"))?;
    let mut idevice = provider
        .connect(port)
        .await
        .map_err(|e| format!("connect to service port {port} failed: {e:?}"))?;
    if ssl {
        idevice
            .start_session(pairing_file, legacy)
            .await
            .map_err(|e| format!("service TLS session failed: {e:?}"))?;
    }
    idevice
        .get_socket()
        .ok_or_else(|| "failed to get socket from idevice".to_string())
}

async fn connect_service_rsd(
    adapter: &mut idevice::tcp::handle::AdapterHandle,
    handshake: &mut idevice::services::rsd::RsdHandshake,
    service_base: &str,
    logger: &Logger,
) -> Result<Box<dyn ReadWrite>, String> {
    let shim_name = format!("{service_base}.shim.remote");
    if let Some(s) = handshake.services.get(&shim_name) {
        let port = s.port;
        logger.log(format!("console: RSD shim '{shim_name}' on port {port}"));
        let stream = adapter
            .connect(port)
            .await
            .map_err(|e| format!("connect to '{shim_name}' on {port} failed: {e:?}"))?;
        let mut dev = Idevice::new(Box::new(stream), "GestaltX");
        dev.rsd_checkin()
            .await
            .map_err(|e| format!("RSD checkin for '{shim_name}' failed: {e:?}"))?;
        return dev.get_socket().ok_or_else(|| "failed to get socket".to_string());
    }
    if let Some(s) = handshake.services.get(service_base) {
        let port = s.port;
        logger.log(format!("console: RSD bare '{service_base}' on port {port}"));
        let stream = adapter
            .connect(port)
            .await
            .map_err(|e| format!("connect to '{service_base}' on {port} failed: {e:?}"))?;
        let mut dev = Idevice::new(Box::new(stream), "GestaltX");
        dev.rsd_checkin()
            .await
            .map_err(|e| format!("RSD checkin for '{service_base}' failed: {e:?}"))?;
        return dev.get_socket().ok_or_else(|| "failed to get socket".to_string());
    }
    logger.log(format!("console: '{service_base}' not in RSD, trying fresh Lockdown..."));
    let mut lockdown = handshake
        .connect::<LockdownClient>(adapter)
        .await
        .map_err(|e| format!("Lockdown connect for '{service_base}' failed: {e:?}"))?;
    let (port, ssl) = lockdown
        .start_service(service_base)
        .await
        .map_err(|e| format!("Lockdown start_service('{service_base}') failed: {e:?}"))?;
    logger.log(format!("console: '{service_base}' on port {port} (ssl={ssl})"));
    let stream = adapter
        .connect(port)
        .await
        .map_err(|e| format!("connect to service port {port} failed: {e:?}"))?;
    Ok(Box::new(stream))
}

async fn try_lockdown(
    target_ips: &[String],
    pf: &PairingFile,
    logger: &Logger,
    last_err: &mut String,
) -> Option<AppDeviceTunnel> {
    for ip_str in target_ips {
        let Ok(ip) = ip_str.parse::<Ipv4Addr>() else { continue };
        if ip.is_loopback() {
            continue;
        }
        let provider = TcpProvider {
            addr: IpAddr::V4(ip),
            scope_id: None,
            pairing_file: pf.clone(),
            label: "GestaltX".to_string(),
        };
        match tokio::time::timeout(std::time::Duration::from_millis(800), LockdownClient::connect(&provider)).await {
            Ok(Ok(mut lockdown)) => match lockdown.start_session(pf).await {
                Ok(legacy) => {
                    logger.log(format!("console: Lockdown on {ip_str}:62078 (legacy={legacy})"));
                    return Some(AppDeviceTunnel::Lockdown { provider, pairing_file: pf.clone(), legacy });
                }
                Err(e) => *last_err = format!("lockdownd start_session on {ip_str}: {e:?}"),
            },
            Ok(Err(e)) => *last_err = format!("connect lockdownd on {ip_str}: {e:?}"),
            Err(_) => *last_err = format!("connect lockdownd on {ip_str} timed out"),
        }
    }
    None
}

async fn try_rsd(
    target_ips: &[String],
    mut rpf: RpPairingFile,
    logger: &Logger,
    last_err: &mut String,
) -> Option<AppDeviceTunnel> {
    let extra_hosts: Vec<IpAddr> = target_ips
        .iter()
        .filter_map(|s| s.parse::<IpAddr>().ok())
        .filter(|ip| !ip.is_loopback())
        .collect();

    for ip_str in target_ips {
        let Ok(ip) = ip_str.parse::<Ipv4Addr>() else { continue };
        if ip.is_loopback() {
            continue;
        }
        let socket_addr = SocketAddr::new(IpAddr::V4(ip), RSD_PORT);
        logger.log(format!("console: RSD tunnel on {ip_str}:{RSD_PORT} via RemoteXPC..."));
        match tokio::time::timeout(
            std::time::Duration::from_millis(2500),
            idevice_ffi::tunnel_provider::tunnel_create_remotexpc_multihost_async(socket_addr, "GestaltX", &mut rpf, &extra_hosts),
        )
        .await
        {
            Ok(Ok((adapter, handshake))) => {
                logger.log(format!("console: tunnel up on {ip_str}:{RSD_PORT} (RemoteXPC)"));
                return Some(AppDeviceTunnel::Rsd { adapter, handshake });
            }
            Ok(Err(failure)) => {
                *last_err = format!("{ip_str}:{RSD_PORT}: {:?} ({:?})", failure.error, failure.kind);
                if failure.kind != idevice_ffi::tunnel_provider::TunnelFailureKind::TunnelFailureRsdUnreachable {
                    logger.log(format!("console: fallback raw RPPairing on {ip_str}:{RSD_PORT}..."));
                    match tokio::time::timeout(
                        std::time::Duration::from_millis(2500),
                        idevice_ffi::tunnel_provider::tunnel_create_rppairing_multihost_async(socket_addr, "GestaltX", &mut rpf, &extra_hosts),
                    )
                    .await
                    {
                        Ok(Ok((adapter, handshake))) => {
                            logger.log(format!("console: tunnel up on {ip_str}:{RSD_PORT} (raw RPPairing)"));
                            return Some(AppDeviceTunnel::Rsd { adapter, handshake });
                        }
                        Ok(Err(raw)) => {
                            let is_pair_verify = raw.kind == idevice_ffi::tunnel_provider::TunnelFailureKind::TunnelFailurePairVerify;
                            let hint = if is_pair_verify {
                                " (iPhone rejected pairing keys — re-pair in Settings › Privacy & Security › Developer Mode)"
                            } else {
                                ""
                            };
                            *last_err = format!("{ip_str}:{RSD_PORT}: {:?}{hint}", raw.kind);
                        }
                        Err(_) => *last_err = format!("{ip_str}:{RSD_PORT}: raw RPPairing timed out"),
                    }
                }
            }
            Err(_) => *last_err = format!("{ip_str}:{RSD_PORT}: RemoteXPC timed out"),
        }
    }
    None
}

async fn connect_tunnel(pairing_bytes: &[u8], logger: &Logger) -> Result<AppDeviceTunnel, String> {
    let mut last_error = String::new();
    let target_ips = resolve_target_hosts();
    let parsed_lockdown = PairingFile::from_bytes(pairing_bytes).ok();
    let parsed_rp = RpPairingFile::from_bytes(pairing_bytes).ok();

    if parsed_lockdown.is_none() && parsed_rp.is_none() {
        return Err("pairing file carries neither a Lockdown record nor Remote Pairing credentials".to_string());
    }
    // RSD is the modern path on iOS 17+; try it first to avoid wasted lockdown timeouts.
    if let Some(rpf) = parsed_rp {
        if let Some(tunnel) = try_rsd(&target_ips, rpf, logger, &mut last_error).await {
            return Ok(tunnel);
        }
    }
    if let Some(pf) = &parsed_lockdown {
        if let Some(tunnel) = try_lockdown(&target_ips, pf, logger, &mut last_error).await {
            return Ok(tunnel);
        }
    }
    Err(format!(
        "device connection failed: {last_error}. Ensure a loopback VPN (e.g. LocalDevVPN) is active."
    ))
}

// ---------------------------------------------------------------------------
// Pairing — RPPairing host (adapted; PIN is never logged)
// ---------------------------------------------------------------------------

pub struct PairParams {
    pub bind_addr: String,
    pub port: u16,
    pub name: String,
    pub model: String,
    pub out_path: String,
    pub host_alt_irk_hex: String,
}

pub struct PairOk {
    pub device_name: String,
    pub device_model: String,
    pub device_udid: String,
    pub pairing_file_path: String,
    pub host_alt_irk_hex: String,
}

struct PairCbs {
    ready: GXPairReadyCb,
    pin: GXPairPinCb,
    ctx: *mut c_void,
}
unsafe impl Send for PairCbs {}

pub fn run_pairing_host(
    token: Arc<CancelToken>,
    params: PairParams,
    ready_cb: GXPairReadyCb,
    pin_cb: GXPairPinCb,
    ctx: *mut c_void,
) -> Result<PairOk, String> {
    let cbs = PairCbs { ready: ready_cb, pin: pin_cb, ctx };
    run_with_large_stack("gx_pairing_run_host", move || {
        idevice_ffi::run_sync_local(async move {
            tokio::select! {
                res = async_run_host(params, cbs) => res,
                _ = token.cancelled() => Err("pairing cancelled".to_string()),
            }
        })
    })
    .and_then(|r| r)
}

async fn async_run_host(p: PairParams, cbs: PairCbs) -> Result<PairOk, String> {
    let ip: IpAddr = p.bind_addr.parse().unwrap_or(IpAddr::V4(Ipv4Addr::UNSPECIFIED));
    let listener = TcpListener::bind(SocketAddr::new(ip, p.port))
        .await
        .map_err(|e| format!("failed to bind {}:{}: {e}", p.bind_addr, p.port))?;
    let bound_port = listener.local_addr().map_err(|e| format!("no local addr: {e}"))?.port();

    let mut pairing_file = match RpPairingFile::read_from_file(&p.out_path).await {
        Ok(mut existing) => {
            existing.alt_irk = None;
            existing
        }
        Err(_) => RpPairingFile::generate(&p.name),
    };

    let mut host_info = PairableHostInfo::generate(&p.name, &p.model);
    if let Some(irk) = parse_alt_irk(&p.host_alt_irk_hex) {
        host_info.alt_irk = irk;
    }
    let host_alt_irk = host_info.alt_irk;
    let service_id = pairing_file.identifier.clone();

    emit_ready(&cbs, &service_id, bound_port, &host_info);

    let (stream, _peer) = listener.accept().await.map_err(|e| format!("accept failed: {e}"))?;
    let socket = RpPairingSocket::new_device(stream);
    let mut host = PairableHost::new(socket, host_info);

    let pin_cb = cbs.pin;
    let pin_ctx = cbs.ctx;
    let peer_info = host
        .accept(&mut pairing_file, move |pin| {
            let pin_cb = pin_cb;
            let pin_ctx = pin_ctx;
            async move {
                // Deliberately NOT logged.
                if let Some(cb) = pin_cb {
                    if let Ok(c) = CString::new(pin.as_str()) {
                        cb(pin_ctx, c.as_ptr());
                    }
                }
            }
        })
        .await
        .map_err(|e| format!("pairing failed: {e}"))?;

    pairing_file
        .write_to_file(&p.out_path)
        .await
        .map_err(|e| format!("failed to write pairing file: {e}"))?;
    let size = tokio::fs::metadata(&p.out_path).await.map(|m| m.len()).unwrap_or(0);
    if size == 0 {
        return Err(format!("handshake completed but pairing file {} is empty", p.out_path));
    }

    Ok(PairOk {
        device_name: peer_info.name,
        device_model: peer_info.model,
        device_udid: peer_info.remotepairing_udid,
        pairing_file_path: p.out_path,
        host_alt_irk_hex: bytes_to_hex(&host_alt_irk),
    })
}

fn emit_ready(cbs: &PairCbs, service_id: &str, port: u16, host_info: &PairableHostInfo) {
    let Some(cb) = cbs.ready else { return };
    let records = host_info.mdns_txt_records(service_id);
    let keys: Vec<CString> = records.iter().map(|(k, _)| CString::new(k.as_str()).unwrap_or_default()).collect();
    let vals: Vec<CString> = records.iter().map(|(_, v)| CString::new(v.as_str()).unwrap_or_default()).collect();
    let key_ptrs: Vec<*const c_char> = keys.iter().map(|s| s.as_ptr()).collect();
    let val_ptrs: Vec<*const c_char> = vals.iter().map(|s| s.as_ptr()).collect();
    let Ok(id_c) = CString::new(service_id) else { return };
    cb(cbs.ctx, id_c.as_ptr(), port, key_ptrs.as_ptr(), val_ptrs.as_ptr(), records.len());
}

fn parse_alt_irk(s: &str) -> Option<[u8; 16]> {
    if s.len() != 32 {
        return None;
    }
    let mut out = [0u8; 16];
    for (i, b) in out.iter_mut().enumerate() {
        *b = u8::from_str_radix(s.get(i * 2..i * 2 + 2)?, 16).ok()?;
    }
    Some(out)
}

fn bytes_to_hex(b: &[u8]) -> String {
    b.iter().map(|x| format!("{x:02x}")).collect()
}

// ---------------------------------------------------------------------------
// Syslog capture (adapted; cancellation via select!, bounded line buffer)
// ---------------------------------------------------------------------------

struct LineCbs {
    cb: GXSyslogLineCallback,
    ctx: *mut c_void,
}
unsafe impl Send for LineCbs {}

pub fn run_syslog(
    token: Arc<CancelToken>,
    pairing_path: String,
    line_cb: GXSyslogLineCallback,
    ctx: *mut c_void,
) -> Result<(), String> {
    // Box the callback bundle so the closure captures it as a single `Send`
    // value instead of disjoint-capturing the raw `ctx` pointer.
    let cbs = Box::new(LineCbs { cb: line_cb, ctx });
    run_with_large_stack("gx_syslog_run", move || {
        idevice_ffi::run_sync_local(async move {
            let pairing_bytes = std::fs::read(&pairing_path)
                .map_err(|e| format!("failed to read pairing file at {pairing_path}: {e}"))?;
            let logger = Logger::silent();

            let mut tunnel = tokio::select! {
                r = connect_tunnel(&pairing_bytes, &logger) => r?,
                _ = token.cancelled() => return Err("cancelled before connect".to_string()),
            };
            let mut stream = tokio::select! {
                r = tunnel.connect_service("com.apple.syslog_relay", &logger) => r?,
                _ = token.cancelled() => return Err("cancelled before service".to_string()),
            };

            let mut buf = vec![0u8; 4096];
            let mut line_buf: Vec<u8> = Vec::new();
            loop {
                let n = tokio::select! {
                    read = stream.read(&mut buf) => match read {
                        Ok(0) => break,     // EOF
                        Ok(n) => n,
                        Err(_) => break,
                    },
                    _ = token.cancelled() => break,
                };
                for &b in &buf[..n] {
                    if b == b'\n' || b == 0 {
                        if !line_buf.is_empty() {
                            let line = String::from_utf8_lossy(&line_buf).replace('\0', " ");
                            line_buf.clear();
                            if let Some(cb) = cbs.cb {
                                if let Ok(c) = CString::new(line) {
                                    cb(cbs.ctx, c.as_ptr());
                                }
                            }
                        }
                    } else if b != b'\r' {
                        line_buf.push(b);
                        if line_buf.len() > 65536 {
                            line_buf.clear(); // over-length record: drop, don't flush a truncation
                        }
                    }
                }
            }
            Ok::<(), String>(())
        })
    })
    .and_then(|r| r)
}
