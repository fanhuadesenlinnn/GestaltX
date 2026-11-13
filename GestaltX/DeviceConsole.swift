// SPDX-License-Identifier: GPL-3.0-only
import Foundation

enum DeviceConsoleError: LocalizedError {
    case unavailable
    case busy
    case failed(String)
    var errorDescription: String? {
        switch self {
        case .unavailable: return L("The device console is not available in this build.")
        case .busy: return L("Another pairing or capture is already running.")
        case .failed(let message): return message
        }
    }
}

struct PairingOutcome: Sendable {
    var deviceName: String
    var deviceModel: String
    var deviceUDID: String
    var pairingFilePath: String
    var hostAltIRKHex: String
}

/// Swift front end for the `gx_device_console` native library (GXDeviceConsole.h).
/// Serialized by the native session layer: one pairing OR capture at a time.
///
/// The native backend is compiled in only when the app is built with the
/// `GXDEVICECONSOLE` active-compilation condition and linked against the
/// `GXDeviceConsole` xcframework (see Native/DeviceConsole/INTEGRATION.md).
/// Without it every call reports `.unavailable`, so the rest of the app builds
/// and runs unchanged.
final class DeviceConsole: @unchecked Sendable {
    static let shared = DeviceConsole()
    private init() {}

    private let lock = NSLock()
    private var generation: UInt64 = 0

    var isAvailable: Bool {
        #if GXDEVICECONSOLE
        return true
        #else
        return false
        #endif
    }

    /// Current active session generation, 0 when idle.
    var currentGeneration: UInt64 {
        lock.lock(); defer { lock.unlock() }
        return generation
    }

    func cancelCurrent() {
        #if GXDEVICECONSOLE
        let g = currentGeneration
        if g != 0 { gx_session_cancel(g) }
        #endif
    }

    func setTargetHosts(_ hosts: [String]) {
        #if GXDEVICECONSOLE
        let cstrings = hosts.map { strdup($0) }
        defer { cstrings.forEach { free($0) } }
        var pointers = cstrings.map { UnsafePointer<CChar>($0) }
        pointers.withUnsafeMutableBufferPointer { buf in
            gx_console_set_target_hosts(buf.baseAddress, buf.count)
        }
        #else
        _ = hosts
        #endif
    }

    // MARK: - Pairing

    /// Run the RPPairing host. Blocks the calling work item until paired,
    /// cancelled, or errored, so it is dispatched to a background queue.
    func runPairing(bindAddr: String, port: UInt16, name: String, model: String,
                    outPath: String, altIRKHex: String,
                    ready: @escaping (_ serviceID: String, _ port: UInt16, _ txt: [String: String]) -> Void,
                    pin: @escaping (_ pin: String) -> Void) async throws -> PairingOutcome {
        #if GXDEVICECONSOLE
        let g = gx_session_begin()
        guard g != 0 else { throw DeviceConsoleError.busy }
        lock.lock(); generation = g; lock.unlock()
        defer { lock.lock(); if generation == g { generation = 0 }; lock.unlock() }

        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let box = PairCallbackBox(ready: ready, pin: pin)
                let ctx = Unmanaged.passRetained(box).toOpaque()
                defer { Unmanaged<PairCallbackBox>.fromOpaque(ctx).release() }

                var out = GXPairResult()
                let code = bindAddr.withCString { ba in name.withCString { nm in model.withCString { md in
                    outPath.withCString { op in altIRKHex.withCString { irk in
                        gx_pairing_run_host(g, ba, port, nm, md, op, irk, pairReadyThunk, pairPinThunk, ctx, &out)
                    } }
                } } }

                defer { gx_pair_result_free(&out) }
                if code == 0 {
                    continuation.resume(returning: PairingOutcome(
                        deviceName: Self.string(out.device_name),
                        deviceModel: Self.string(out.device_model),
                        deviceUDID: Self.string(out.device_udid),
                        pairingFilePath: Self.string(out.pairing_file_path),
                        hostAltIRKHex: Self.string(out.host_alt_irk_hex)))
                } else {
                    continuation.resume(throwing: DeviceConsoleError.failed(Self.string(out.error, L("Pairing failed."))))
                }
            }
        }
        #else
        _ = (bindAddr, port, name, model, outPath, altIRKHex, ready, pin)
        throw DeviceConsoleError.unavailable
        #endif
    }

    // MARK: - Syslog

    func runSyslog(pairingPath: String, line: @escaping (_ line: String) -> Void) async throws {
        #if GXDEVICECONSOLE
        let g = gx_session_begin()
        guard g != 0 else { throw DeviceConsoleError.busy }
        lock.lock(); generation = g; lock.unlock()
        defer { lock.lock(); if generation == g { generation = 0 }; lock.unlock() }

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            DispatchQueue.global(qos: .userInitiated).async {
                let box = LineCallbackBox(line: line)
                let ctx = Unmanaged.passRetained(box).toOpaque()
                defer { Unmanaged<LineCallbackBox>.fromOpaque(ctx).release() }

                var error: UnsafeMutablePointer<CChar>?
                let code = pairingPath.withCString { pp in
                    gx_syslog_run(g, pp, syslogLineThunk, ctx, &error)
                }
                if code == 0 {
                    continuation.resume()
                } else {
                    let message = error.map { String(cString: $0) } ?? L("Capture stopped.")
                    if let error { gx_string_free(error) }
                    continuation.resume(throwing: DeviceConsoleError.failed(message))
                }
            }
        }
        #else
        _ = (pairingPath, line)
        throw DeviceConsoleError.unavailable
        #endif
    }

    #if GXDEVICECONSOLE
    private static func string(_ p: UnsafeMutablePointer<CChar>?, _ fallback: String = "") -> String {
        guard let p else { return fallback }
        return String(cString: p)
    }
    #endif
}

#if GXDEVICECONSOLE
// Boxes that carry Swift closures across the C boundary. Retained for the
// duration of the native call and released in the dispatch block's defer.
private final class PairCallbackBox {
    let ready: (String, UInt16, [String: String]) -> Void
    let pin: (String) -> Void
    init(ready: @escaping (String, UInt16, [String: String]) -> Void, pin: @escaping (String) -> Void) {
        self.ready = ready; self.pin = pin
    }
}
private final class LineCallbackBox {
    let line: (String) -> Void
    init(line: @escaping (String) -> Void) { self.line = line }
}

private let pairReadyThunk: @convention(c) (UnsafeMutableRawPointer?, UnsafePointer<CChar>?, UInt16,
    UnsafePointer<UnsafePointer<CChar>?>?, UnsafePointer<UnsafePointer<CChar>?>?, Int) -> Void = { ctx, serviceID, port, keys, vals, count in
    guard let ctx else { return }
    let box = Unmanaged<PairCallbackBox>.fromOpaque(ctx).takeUnretainedValue()
    let id = serviceID.map { String(cString: $0) } ?? ""
    var txt: [String: String] = [:]
    if let keys, let vals {
        for i in 0..<count {
            if let k = keys[i], let v = vals[i] {
                txt[String(cString: k)] = String(cString: v)
            }
        }
    }
    box.ready(id, port, txt)
}

private let pairPinThunk: @convention(c) (UnsafeMutableRawPointer?, UnsafePointer<CChar>?) -> Void = { ctx, pin in
    guard let ctx, let pin else { return }
    let box = Unmanaged<PairCallbackBox>.fromOpaque(ctx).takeUnretainedValue()
    box.pin(String(cString: pin))
}

private let syslogLineThunk: @convention(c) (UnsafeMutableRawPointer?, UnsafePointer<CChar>?) -> Void = { ctx, line in
    guard let ctx, let line else { return }
    let box = Unmanaged<LineCallbackBox>.fromOpaque(ctx).takeUnretainedValue()
    box.line(String(cString: line))
}
#endif
