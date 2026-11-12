// SPDX-License-Identifier: GPL-3.0-only
import Foundation

enum DirectFileImports {
    private final class Coordination: @unchecked Sendable {
        let coordinator = NSFileCoordinator()
    }
    static func inbox(container: URL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]) throws -> SharedPlistInbox {
        try SharedPlistInbox(container: container, namespace: "direct-files")
    }

    static func capture(_ url: URL, in inbox: SharedPlistInbox) -> Task<SharedPlistEntry, Error> {
        // Acquire access before returning from onOpenURL, then own the bytes
        // without waiting for welcome or another presentation gate to clear.
        let scoped = url.startAccessingSecurityScopedResource()
        let coordination = Coordination()
        return Task.detached(priority: .userInitiated) {
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            return try await withTaskCancellationHandler {
                try Task.checkCancellation()
                let data = try SharedPlistInbox.readDocument(at: url, coordinator: coordination.coordinator)
                try Task.checkCancellation()
                return try inbox.enqueue(data, name: url.lastPathComponent)
            } onCancel: {
                coordination.coordinator.cancel()
            }
        }
    }
}
