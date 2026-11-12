import Foundation

private struct ProviderFailure: Error {}

private final class ProviderProbe: @unchecked Sendable {
    let started = DispatchSemaphore(value: 0)
    let completed = DispatchSemaphore(value: 0)
    let progress = Progress(totalUnitCount: 1)
    private let lock = NSLock()
    private var request: ItemProviderLoad<Int>?
    private var readCount = 0

    func start(_ request: ItemProviderLoad<Int>) -> Progress {
        lock.lock()
        self.request = request
        lock.unlock()
        started.signal()
        return progress
    }

    func respond() {
        lock.lock()
        let request = self.request
        lock.unlock()
        request?.complete {
            self.lock.lock()
            self.readCount += 1
            self.lock.unlock()
            return 42
        }
    }

    var reads: Int {
        lock.lock(); defer { lock.unlock() }
        return readCount
    }
}

@main struct ItemProviderLoadTests {
    @MainActor static func main() async throws {
        let immediate = try await ItemProviderLoad<Int>.load { request in
            request.complete { 7 }
            request.complete { preconditionFailure("A second provider callback must be ignored") }
            return Progress(totalUnitCount: 1)
        }
        precondition(immediate == 7, "Handle callbacks delivered before Progress is returned")
        do {
            _ = try await ItemProviderLoad<Int>.load { request in
                request.complete { throw ProviderFailure() }
                return nil
            }
            preconditionFailure("Propagate provider failures")
        } catch is ProviderFailure {}

        // A cancelled task must complete even when the provider never calls back.
        let pending = ProviderProbe()
        let task = Task.detached {
            defer { pending.completed.signal() }
            return try await ItemProviderLoad<Int>.load { pending.start($0) }
        }
        precondition(pending.started.wait(timeout: .now() + 5) == .success)
        task.cancel()
        precondition(pending.completed.wait(timeout: .now() + 5) == .success,
                     "Cancel must resume a stalled provider continuation")
        do { _ = try await task.value; preconditionFailure("Expected cancellation") }
        catch is CancellationError {}
        precondition(pending.progress.isCancelled, "Cancel the underlying file-provider operation")
        pending.respond()
        precondition(pending.reads == 0, "A late callback must not read a temporary file after cancellation")

        // This child inherits the main actor, so it cannot start before cancel().
        let alreadyCancelled = Task {
            try await ItemProviderLoad<Int>.load { _ in
                preconditionFailure("A cancelled request must not start another provider load")
            }
        }
        alreadyCancelled.cancel()
        do { _ = try await alreadyCancelled.value; preconditionFailure("Expected cancellation before startup") }
        catch is CancellationError {}

        // Cancellation can win after startup but before the API returns Progress.
        let starting = ProviderProbe()
        let releaseStartup = DispatchSemaphore(value: 0)
        let duringStartup = Task.detached {
            defer { starting.completed.signal() }
            return try await ItemProviderLoad<Int>.load { request in
                let progress = starting.start(request)
                precondition(releaseStartup.wait(timeout: .now() + 5) == .success)
                return progress
            }
        }
        precondition(starting.started.wait(timeout: .now() + 5) == .success)
        duringStartup.cancel()
        releaseStartup.signal()
        precondition(starting.completed.wait(timeout: .now() + 5) == .success)
        do { _ = try await duringStartup.value; preconditionFailure("Expected cancellation during startup") }
        catch is CancellationError {}
        precondition(starting.progress.isCancelled, "Cancel Progress returned after cancellation")
        starting.respond()
        precondition(starting.reads == 0)

        // Some providers invoke completion synchronously from Progress.cancel().
        let reentrant = ProviderProbe()
        reentrant.progress.cancellationHandler = { reentrant.respond() }
        let reentrantTask = Task.detached {
            defer { reentrant.completed.signal() }
            return try await ItemProviderLoad<Int>.load { reentrant.start($0) }
        }
        precondition(reentrant.started.wait(timeout: .now() + 5) == .success)
        reentrantTask.cancel()
        precondition(reentrant.completed.wait(timeout: .now() + 5) == .success)
        do { _ = try await reentrantTask.value; preconditionFailure("Expected cancellation") }
        catch is CancellationError {}
        precondition(reentrant.reads == 0, "Cancellation callbacks must not deadlock or resume twice")
        reentrant.progress.cancellationHandler = nil

        let enteredRead = DispatchSemaphore(value: 0), releaseRead = DispatchSemaphore(value: 0)
        let discarded = DispatchSemaphore(value: 0), callbackDone = DispatchSemaphore(value: 0)
        let duringRead = Task.detached {
            try await ItemProviderLoad<Int>.load { request in
                DispatchQueue.global().async {
                    request.complete(onDiscard: { _ in discarded.signal() }) {
                        enteredRead.signal()
                        precondition(releaseRead.wait(timeout: .now() + 5) == .success)
                        return 99
                    }
                    callbackDone.signal()
                }
                return nil
            }
        }
        precondition(enteredRead.wait(timeout: .now() + 5) == .success)
        duringRead.cancel()
        do { _ = try await duringRead.value; preconditionFailure("Expected cancellation during callback") }
        catch is CancellationError {}
        releaseRead.signal()
        precondition(discarded.wait(timeout: .now() + 5) == .success, "A receipt published during cancellation must be cleaned up")
        precondition(callbackDone.wait(timeout: .now() + 5) == .success)
        print("PASS: provider success/errors, cancellation before/during/after startup, stalled loads and late callbacks.")
    }
}
