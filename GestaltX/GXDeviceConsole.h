// SPDX-License-Identifier: GPL-3.0-only
//
// GestaltX native device console — C FFI surface.
//
// Scope: on-device self-pairing (RPPairing host) + com.apple.syslog_relay
// capture over a loopback RSD tunnel. No file-injection exploit.
//
// All fallible calls return int32 (0 == OK). Heap strings must be released with
// gx_string_free(). Pointers passed to callbacks are valid only for the duration
// of the call — copy them.

#ifndef GX_DEVICE_CONSOLE_H
#define GX_DEVICE_CONSOLE_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

// ---- Logging ---------------------------------------------------------------

// Receives formatted log lines (never a pairing PIN or key material). Called
// from arbitrary threads.
typedef void (*GXLogCallback)(void *ctx, const char *msg);

// Install the log forwarder. 0 on success, 1 if already initialised.
int32_t gx_console_log_init(GXLogCallback cb, void *ctx);

// Free any char* returned by this library.
void gx_string_free(char *p);

// ---- Target host configuration ---------------------------------------------

// Candidate hosts to dial for the RSD tunnel (e.g. the loopback VPN gateway the
// user enabled). 127.0.0.1 is never dialled by the native layer.
void gx_console_set_target_hosts(const char *const *hosts, size_t count);
void gx_console_clear_target_hosts(void);

// ---- Session lifecycle -----------------------------------------------------

// Reserve a session generation. Returns 0 if one is already active (only one
// pairing/capture at a time), else a non-zero generation id.
uint64_t gx_session_begin(void);

// Request cancellation of a generation. Returns immediately; the blocked run
// function unwinds and returns on its own thread.
void gx_session_cancel(uint64_t generation);

// ---- Pairing — RPPairing host ----------------------------------------------

// Fires once the host is bound; the Swift side advertises service_id over
// Bonjour (NetService). All pointers valid only during the call.
typedef void (*GXPairReadyCb)(void *ctx,
                              const char *service_id,
                              uint16_t port,
                              const char *const *txt_keys,
                              const char *const *txt_vals,
                              size_t txt_count);

// Fires with the PIN the user confirms in Settings. Not written to any log.
typedef void (*GXPairPinCb)(void *ctx, const char *pin);

typedef struct {
    char *error;
    char *device_name;
    char *device_model;
    char *device_udid;
    char *pairing_file_path;
    char *host_alt_irk_hex;
} GXPairResult;

// Run the RPPairing host for `generation`. BLOCKS until paired, cancelled, or
// errored — call off the main thread. `port` 0 lets the OS choose.
// `host_alt_irk_hex` is a value a previous run returned, or NULL/"" first time.
// Returns 0 on success, 1 on error (out->error set), 2 if out is NULL, 3 if the
// generation is not the active session.
int32_t gx_pairing_run_host(uint64_t generation,
                            const char *bind_addr,
                            uint16_t port,
                            const char *name,
                            const char *model,
                            const char *out_path,
                            const char *host_alt_irk_hex,
                            GXPairReadyCb ready_cb,
                            GXPairPinCb pin_cb,
                            void *ctx,
                            GXPairResult *out);

void gx_pair_result_free(GXPairResult *r);

// ---- Syslog capture --------------------------------------------------------

typedef void (*GXSyslogLineCallback)(void *ctx, const char *line);

// Stream com.apple.syslog_relay for `generation` over the RSD tunnel built from
// `pairing_path`. BLOCKS until cancelled, EOF, or error — call off the main
// thread. Each decoded line (bounded to 64 KiB) is delivered to line_cb.
// Returns 0 on clean stop/EOF, 1 on error (out_error set), 3 if the generation
// is not the active session.
int32_t gx_syslog_run(uint64_t generation,
                      const char *pairing_path,
                      GXSyslogLineCallback line_cb,
                      void *ctx,
                      char **out_error);

#ifdef __cplusplus
}
#endif

#endif /* GX_DEVICE_CONSOLE_H */
