// SPDX-License-Identifier: GPL-3.0-only
import Foundation

// Bridge a provider callback to Task cancellation even if the provider never
// calls back after cancelling its Progress. Callbacks may arrive on any queue.
final class ItemProviderLoad<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Value, Error>?
    private var progress: Progress?
    private var finished = false
    private var cancelled = false
    private var completing = false

    static func load(_ start: (ItemProviderLoad<Value>) -> Progress?) async throws -> Value {
        let request = ItemProviderLoad<Value>()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                guard request.install(continuation) else { return }
                request.attach(start(request))
            }
        } onCancel: {
            request.cancel()
        }
    }

    // Keep temporary-file reads inside the provider callback, and skip the read
    // entirely when the extension has already been cancelled or completed.
    func complete(onDiscard: (Value) -> Void = { _ in }, _ read: () throws -> Value) {
        lock.lock()
        guard !finished, !completing else { lock.unlock(); return }
        completing = true
        lock.unlock()
        let result = Result(catching: read)
        lock.lock()
        guard !finished else {
            lock.unlock()
            if case .success(let value) = result { onDiscard(value) }
            return
        }
        finished = true
        let continuation = self.continuation
        self.continuation = nil
        progress = nil
        lock.unlock()
        continuation?.resume(with: result)
    }

    func checkCancellation() throws {
        lock.lock()
        let cancelled = self.cancelled
        lock.unlock()
        if cancelled { throw CancellationError() }
    }

    private func install(_ continuation: CheckedContinuation<Value, Error>) -> Bool {
        lock.lock()
        if cancelled {
            lock.unlock()
            continuation.resume(throwing: CancellationError())
            return false
        }
        self.continuation = continuation
        lock.unlock()
        return true
    }

    private func attach(_ progress: Progress?) {
        lock.lock()
        let shouldCancel = cancelled
        if !finished { self.progress = progress }
        lock.unlock()
        if shouldCancel { progress?.cancel() }
    }

    private func cancel() {
        lock.lock()
        guard !finished else { lock.unlock(); return }
        cancelled = true
        finished = true
        let continuation = self.continuation
        let progress = self.progress
        self.continuation = nil
        self.progress = nil
        lock.unlock()
        continuation?.resume(throwing: CancellationError())
        // A provider can invoke its callback synchronously from cancel().
        progress?.cancel()
    }
}
