# GestaltX Native Device Console — provenance & third-party notices

This crate (`gx_device_console`, GPL-3.0-only) provides GestaltX's on-device
self-pairing (RPPairing host) and `com.apple.syslog_relay` capture over a
loopback RSD tunnel. It is used to learn which app played which notification
sound. It does **not** include any file-injection / sandbox-escape exploit.

## Reuse from AirCard-iOS

The device connection layer (RSD/Lockdown tunnel selection, RPPairing host, and
the syslog read loop) is adapted from **AirCard-iOS** by Johnny Franks
(MIT License, Copyright (c) 2026 Johnny Franks), https://github.com/Mak5er/AirCard-iOS.

Adapted with substantive changes:

- Only the pairing + syslog connection path is reused. AirCard's Airlift
  file-injection exploit (`al_exploit_run`, `al_exploit_write_dir`,
  `al_exploit_inject_folder`, AFC / com.apple.atc / streaming_zip_conduit) is
  **not** ported.
- Cancellation is rewritten: a serialized, generation-scoped session with a real
  cancel token, replacing the reference's global `AtomicBool` stop flag and its
  UI-only `softCancel()`. The connect phase and the syslog read are cancelled
  through `tokio::select!`, not a 500 ms poll.
- The pairing PIN and key material are never written to any log.

## Vendored dependencies

Both are copies from **jkcoxson/idevice** @ `7bd551c16c6dd2e058740d85a2d9399a51a776e9`,
https://github.com/jkcoxson/idevice (MIT License, Jackson Coxson). The upstream
`idevice` crate declares `license = "MIT"`; `idevice-ffi` ships in the same
repository under the same license (the vendored `Cargo.toml` carries no explicit
`license` field, so `vendor/*/LICENSE` records the upstream MIT text).

- `vendor/idevice` — local change: **`src/remote_pairing/opack.rs`**, adding OPACK
  back-reference decoding (devices emit tag `0xAB` when `name == model`, which the
  upstream decoder rejected as "unsupported OPACK tag"). Documented in
  `vendor/idevice/README.md`. The `[patch]` in `Cargo.toml` redirects both our
  direct dependency and `idevice-ffi`'s git dependency to this patched copy so a
  single `idevice` instance is unified.
- `vendor/idevice-ffi` — provides `tunnel_provider` (RSD tunnel creation).
- `vendor/cpp` — C/C++ headers pulled in by the FFI build.

## Build

See `build-xcframework.sh`. The `device` feature builds `idevice` with the
`aws-lc` backend, which compiles C sources and therefore requires `cmake` (and
`nasm` on x86_64 hosts) plus the `aarch64-apple-ios` and `aarch64-apple-ios-sim`
Rust targets. Host builds and `cargo test` use no features and need none of this.
