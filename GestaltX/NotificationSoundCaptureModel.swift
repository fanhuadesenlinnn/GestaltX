// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import Combine

/// Owns the parser and the pending buffer on a private serial queue, so raw log
/// lines are parsed off the main thread and only coalesced results ever cross
/// back. All mutable state is confined to `queue`.
final class CaptureSink: @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.huami.gestaltx.capture.parse")
    private let parser = NotificationSoundLogParser()
    private let store: CapturedSoundStore
    private var pending: [CapturedNotificationSound] = []
    private var timer: DispatchSourceTimer?
    private var onUpdate: (@Sendable ([CapturedNotificationSound]) -> Void)?
    private var onFirstLine: (@Sendable () -> Void)?
    private var sawLine = false

    init(store: CapturedSoundStore) { self.store = store }

    func begin(onFirstLine: @escaping @Sendable () -> Void,
               onUpdate: @escaping @Sendable ([CapturedNotificationSound]) -> Void) {
        queue.async {
            self.onFirstLine = onFirstLine
            self.onUpdate = onUpdate
            self.sawLine = false
            let timer = DispatchSource.makeTimerSource(queue: self.queue)
            timer.schedule(deadline: .now() + 0.5, repeating: 0.5)
            timer.setEventHandler { [weak self] in self?.flush() }
            timer.resume()
            self.timer = timer
        }
    }

    func ingest(_ line: String) {
        queue.async {
            if !self.sawLine { self.sawLine = true; self.onFirstLine?() }
            let emitted = self.parser.consume(line + "\n")
            if !emitted.isEmpty { self.pending.append(contentsOf: emitted) }
        }
    }

    /// Flush buffered results into the store; runs on `queue`.
    private func flush() {
        guard !pending.isEmpty else { return }
        let batch = pending
        pending.removeAll(keepingCapacity: true)
        let onUpdate = self.onUpdate
        Task {
            let changed = await self.store.record(batch)
            if !changed.isEmpty {
                let all = await self.store.all()
                onUpdate?(all)
            }
        }
    }

    func end(completion: @escaping @Sendable () -> Void) {
        queue.async {
            self.timer?.cancel(); self.timer = nil
            let batch = self.pending
            self.pending.removeAll(keepingCapacity: true)
            let onUpdate = self.onUpdate
            self.onFirstLine = nil
            Task {
                if !batch.isEmpty { _ = await self.store.record(batch) }
                let all = await self.store.all()
                onUpdate?(all)
                completion()
            }
        }
    }
}

@MainActor
final class NotificationSoundCaptureModel: ObservableObject {
    enum CaptureState: Equatable {
        case idle
        case connecting
        case capturing
        case stopped
        case failed(String)
    }

    @Published private(set) var state: CaptureState = .idle
    @Published private(set) var capturedSounds: [CapturedNotificationSound] = []
    @Published var message: String?

    let store = CapturedSoundStore.shared
    private lazy var sink = CaptureSink(store: store)
    private var task: Task<Void, Never>?
    private let keepAlive = AudioKeepAlive()
    private var watchdog: Task<Void, Never>?

    var isRunning: Bool { state == .connecting || state == .capturing }
    var capturedAppCount: Int { Set(capturedSounds.map(\.bundleID)).count }

    func loadCached() {
        Task { self.capturedSounds = await store.all() }
    }

    /// Begin capture — only ever from an explicit Start action, after the user
    /// has paired and started a loopback VPN.
    func start(pairingPath: String, loopbackHost: String) {
        guard !isRunning, task == nil else { return }
        guard DeviceConsole.shared.isAvailable else { message = DeviceConsoleError.unavailable.localizedDescription; return }
        state = .connecting
        // A continued-processing task is for short foreground-started work and
        // gets expired by the system during a long capture. Keep the process
        // resident with the audio background mode instead, started only here.
        keepAlive.start()

        sink.begin(
            onFirstLine: { [weak self] in
                Task { @MainActor in
                    guard let self else { return }
                    if self.state == .connecting {
                        self.state = .capturing
                    }
                }
            },
            onUpdate: { [weak self] all in
                Task { @MainActor in
                    guard let self else { return }
                    self.capturedSounds = all
                }
            })

        DeviceConsole.shared.setTargetHosts(LoopbackRoute.candidateHosts(userConfigured: loopbackHost.isEmpty ? [] : [loopbackHost]))

        watchdog?.cancel()
        watchdog = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(8))
            guard !Task.isCancelled, let self, self.state == .connecting else { return }
            self.abortConnecting(L("Cannot reach the device console. Open LocalDevVPN, wait for it to connect, then try again."))
        }

        let sink = self.sink
        task = Task {
            do {
                try await DeviceConsole.shared.runSyslog(pairingPath: pairingPath) { line in
                    sink.ingest(line)
                }
                await self.finish(.stopped)
            } catch is CancellationError {
                await self.finish(.stopped)
            } catch {
                let message = error.localizedDescription
                if self.capturedSounds.isEmpty {
                    await self.finish(.failed(message))
                } else {
                    // Data was already captured; a tunnel/stream error at the
                    // end should not turn a successful run into a failure
                    // alert. Keep the results and stop cleanly.
                    NSLog("GestaltX capture ended after data: \(message)")
                    await self.finish(.stopped)
                }
            }
        }
    }

    func stop() {
        watchdog?.cancel(); watchdog = nil
        DeviceConsole.shared.cancelCurrent()
        task?.cancel()
    }

    func abortConnecting(_ text: String) {
        watchdog?.cancel(); watchdog = nil
        DeviceConsole.shared.cancelCurrent()
        task?.cancel()
        keepAlive.stop()
        state = .failed(text)
        message = text
    }

    private func finish(_ newState: CaptureState) async {
        watchdog?.cancel(); watchdog = nil
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            sink.end { c.resume() }
        }
        if case .failed = state, newState == .stopped { task = nil; keepAlive.stop(); return }
        state = newState
        task = nil
        keepAlive.stop()
        if case .failed(let m) = newState {
            NSLog("GestaltX capture failed: \(m)")
            message = m
        } else {
            NSLog("GestaltX capture finished: \(newState)")
        }
    }
}
