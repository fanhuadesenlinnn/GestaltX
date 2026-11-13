// SPDX-License-Identifier: GPL-3.0-only
import Foundation
#if canImport(Network)
import Network
#endif

/// Discovers candidate loopback-VPN gateway addresses and probes whether the RSD
/// port is actually reachable — a real connection attempt, never "some utun
/// exists, assume ready". A plain proxy VPN raises a utun with no RSD listener,
/// which this correctly reports as not ready.
enum LoopbackRoute {
    /// RSD port exposed by the loopback VPN tunnel (LocalDevVPN default).
    static let rsdPort: UInt16 = 49152

    /// Well-known loopback-VPN gateways, plus any the user configured. 127.0.0.1
    /// is intentionally excluded (dialling it wedges remotepairingdeviced).
    static func candidateHosts(userConfigured: [String]) -> [String] {
        var hosts: [String] = []
        for h in userConfigured {
            let t = h.trimmingCharacters(in: .whitespaces)
            if !t.isEmpty && t != "127.0.0.1" && !hosts.contains(t) { hosts.append(t) }
        }
        for fallback in ["10.7.0.1", "10.7.0.2", "10.7.0.3", "10.0.0.1", "172.16.0.1"] where !hosts.contains(fallback) {
            hosts.append(fallback)
        }
        return hosts
    }

    /// Probe each host's RSD port in turn; returns the first that accepts a TCP
    /// connection within `timeout`, or nil if none do.
    static func firstReachable(in hosts: [String], port: UInt16 = rsdPort, timeout: TimeInterval = 1.2) async -> String? {
        #if canImport(Network)
        await withTaskGroup(of: String?.self) { group in
            for host in hosts {
                group.addTask { await probe(host: host, port: port, timeout: timeout) ? host : nil }
            }
            for await result in group {
                if let host = result {
                    group.cancelAll()
                    return host
                }
            }
            return nil
        }
        #else
        return nil
        #endif
    }

    #if canImport(Network)
    private static func probe(host: String, port: UInt16, timeout: TimeInterval) async -> Bool {
        guard let nwPort = NWEndpoint.Port(rawValue: port) else { return false }
        let params = NWParameters.tcp
        params.prohibitedInterfaceTypes = [.loopback]
        let connection = NWConnection(host: NWEndpoint.Host(host), port: nwPort, using: params)
        return await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            let finished = ManagedAtomicFlag()
            let finish: (Bool) -> Void = { ok in
                if finished.testAndSet() { connection.cancel(); continuation.resume(returning: ok) }
            }
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready: finish(true)
                case .failed, .cancelled: finish(false)
                default: break
                }
            }
            connection.start(queue: .global(qos: .utility))
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { finish(false) }
        }
    }
    #endif
}

/// A tiny one-shot flag so the probe resumes its continuation exactly once.
private final class ManagedAtomicFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false
    /// Returns true the first time it is called, false afterwards.
    func testAndSet() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if done { return false }
        done = true
        return true
    }
}
