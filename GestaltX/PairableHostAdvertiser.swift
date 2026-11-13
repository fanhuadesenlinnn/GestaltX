// SPDX-License-Identifier: GPL-3.0-only
//
// Network.framework Bonjour listener adapted from Locus (MIT).
// Copyright (c) 2026 Locus contributors.
import Foundation
import Network

/// Public pairable-host endpoint for iOS Developer Mode.
///
/// `NetService` is not discovered reliably by the on-device pairing sheet.
/// `NWListener` publishes the service iOS browses, and each accepted connection
/// is relayed to the Rust pairable-host bound on 127.0.0.1.
final class PairableHostAdvertiser {
    private var listener: NWListener?
    private var relay: RelayPipe?
    private var rustPort: UInt16 = 0

    func publish(port: UInt16, serviceID: String, txt: [String: String]) {
        stop()
        rustPort = port

        var record = NWTXTRecord()
        for (key, value) in txt {
            record[key] = value
        }

        do {
            let parameters = NWParameters.tcp
            parameters.allowLocalEndpointReuse = true
            parameters.includePeerToPeer = true

            let listener = try NWListener(using: parameters)
            listener.service = NWListener.Service(
                name: serviceID,
                type: "_remotepairing-pairable-host._tcp",
                domain: "local",
                txtRecord: record
            )
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    _ = listener.port
                default:
                    break
                }
            }
            listener.newConnectionHandler = { [weak self] connection in
                self?.relayInbound(connection)
            }
            listener.start(queue: .global(qos: .userInitiated))
            self.listener = listener
        } catch {}
    }

    func stop() {
        relay?.cancel()
        relay = nil
        listener?.cancel()
        listener = nil
        rustPort = 0
    }

    private func relayInbound(_ inbound: NWConnection) {
        relay?.cancel()
        guard rustPort > 0, let port = NWEndpoint.Port(rawValue: rustPort) else {
            inbound.cancel()
            return
        }
        let outbound = NWConnection(host: "127.0.0.1", port: port, using: .tcp)
        let pipe = RelayPipe(inbound: inbound, outbound: outbound)
        relay = pipe
        pipe.start()
    }
}

private final class RelayPipe {
    private let inbound: NWConnection
    private let outbound: NWConnection
    private let queue = DispatchQueue(label: "gestaltx.pairable.relay")

    init(inbound: NWConnection, outbound: NWConnection) {
        self.inbound = inbound
        self.outbound = outbound
    }

    func start() {
        inbound.stateUpdateHandler = { [weak self] state in
            if case .failed = state { self?.cancel() }
            if case .cancelled = state { self?.cancel() }
        }
        outbound.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                self.pump(from: self.inbound, to: self.outbound)
                self.pump(from: self.outbound, to: self.inbound)
            case .failed, .cancelled:
                self.cancel()
            default:
                break
            }
        }
        inbound.start(queue: queue)
        outbound.start(queue: queue)
    }

    func cancel() {
        inbound.cancel()
        outbound.cancel()
    }

    private func pump(from: NWConnection, to: NWConnection) {
        from.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, complete, error in
            guard let self else { return }
            if error != nil {
                self.cancel()
                return
            }
            if let data, !data.isEmpty {
                to.send(content: data, completion: .contentProcessed { sendError in
                    if sendError != nil {
                        self.cancel()
                    } else if complete {
                        self.cancel()
                    } else {
                        self.pump(from: from, to: to)
                    }
                })
            } else if complete {
                self.cancel()
            } else {
                self.pump(from: from, to: to)
            }
        }
    }
}
