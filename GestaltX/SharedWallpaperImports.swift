// SPDX-License-Identifier: GPL-3.0-only
import Foundation

struct SharedWallpaperOffer: Identifiable {
    let inbox: SharedPlistInbox
    let entry: SharedPlistEntry
    let file: URL
    var id: UUID { entry.id }
    var name: String { entry.name }
    func cleanUp() { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
}

enum SharedWallpaperImports {
    private final class Coordination: @unchecked Sendable { let coordinator = NSFileCoordinator() }

    static func inbox(container: URL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]) throws -> SharedPlistInbox {
        try SharedPlistInbox(container: container, namespace: "direct-files", kind: .wallpaper)
    }
    static func capture(_ source: URL, in inbox: SharedPlistInbox) -> Task<SharedPlistEntry, Error> {
        let scoped = source.startAccessingSecurityScopedResource()
        let coordination = Coordination()
        return Task.detached(priority: .userInitiated) {
            defer { if scoped { source.stopAccessingSecurityScopedResource() } }
            return try await withTaskCancellationHandler {
                try Task.checkCancellation()
                return try inbox.enqueueWallpaper(at: source, name: source.lastPathComponent, coordinator: coordination.coordinator)
            } onCancel: { coordination.coordinator.cancel() }
        }
    }

    static func prepare(_ entry: SharedPlistEntry, from inbox: SharedPlistInbox) async throws -> SharedWallpaperOffer {
        let worker = Task.detached(priority: .userInitiated) {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("GX-SharedWallpaper-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
            var ready = false
            defer { if !ready { try? FileManager.default.removeItem(at: directory) } }
            let name = (entry.name as NSString).lastPathComponent
            guard !name.isEmpty, name != ".", name != ".." else { throw CocoaError(.fileReadInvalidFileName) }
            let file = directory.appendingPathComponent(name)
            try inbox.stageWallpaper(entry, at: file)
            try Task.checkCancellation()
            ready = true
            return SharedWallpaperOffer(inbox: inbox, entry: entry, file: file)
        }
        return try await withTaskCancellationHandler {
            let offer = try await worker.value
            if Task.isCancelled { offer.cleanUp(); throw CancellationError() }
            return offer
        } onCancel: { worker.cancel() }
    }
}
