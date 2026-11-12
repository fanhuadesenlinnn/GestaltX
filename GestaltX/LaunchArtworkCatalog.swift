// SPDX-License-Identifier: GPL-3.0-only
import Foundation

struct LaunchArtworkCandidate: Sendable {
    var app: LaunchArtworkApp
    let generation: String
    let container: String?
    var installed = true
}
struct LaunchArtworkInventory: Sendable {
    let complete: Bool
    let candidates: [LaunchArtworkCandidate]
    var containerGeneration = ""
}
struct LaunchArtworkAvailability: Sendable {
    let available: Bool
    var retryable = false
    var missing = false
}
enum LaunchArtworkCatalogEvent: Sendable {
    case snapshot([LaunchArtworkApp])
    case upsert(LaunchArtworkApp)
    case remove(String)
}

enum LaunchArtworkAppOrder {
    static func before(_ left: LaunchArtworkApp, _ right: LaunchArtworkApp) -> Bool {
        let a = left.byteCount > 0 ? left.byteCount : Int64.max
        let b = right.byteCount > 0 ? right.byteCount : Int64.max
        if a != b { return a < b }
        let order = left.name.localizedStandardCompare(right.name)
        return order == .orderedSame ? left.id < right.id : order == .orderedAscending
    }
    static func upsert(_ app: LaunchArtworkApp, in rows: inout [LaunchArtworkApp]) {
        if let existing = rows.firstIndex(where: { $0.id == app.id }) { rows.remove(at: existing) }
        var low = 0, high = rows.count
        while low < high {
            let middle = (low + high) / 2
            if before(rows[middle], app) { low = middle + 1 } else { high = middle }
        }
        rows.insert(app, at: low)
    }
}

actor LaunchArtworkCatalogStore {
    struct Backend: Sendable {
        let inventory: @Sendable (Bool) -> LaunchArtworkInventory
        let verify: @Sendable (LaunchArtworkCandidate) -> LaunchArtworkAvailability
        static var device: Backend {
            #if os(iOS) && !targetEnvironment(simulator)
            return Backend(inventory: { discover in
                let raw = GXCustomizationAccess.launchApplicationInventory(discover)
                let candidates = (raw["applications"] as? [[String: Any]] ?? []).compactMap { item -> LaunchArtworkCandidate? in
                    guard let id = item["identifier"] as? String, LaunchArtworkDirectory.validIdentifier(id) else { return nil }
                    return LaunchArtworkCandidate(app: LaunchArtworkApp(id: id, name: item["name"] as? String ?? id,
                        byteCount: (item["size"] as? NSNumber)?.int64Value ?? 0), generation: item["generation"] as? String ?? "",
                        container: item["container"] as? String, installed: (item["installed"] as? NSNumber)?.boolValue ?? true)
                }
                return LaunchArtworkInventory(complete: (raw["complete"] as? NSNumber)?.boolValue ?? false, candidates: candidates,
                                              containerGeneration: raw["containerGeneration"] as? String ?? "")
            }, verify: { candidate in
                var metadata: [String: Any] = ["identifier": candidate.app.id]
                if let container = candidate.container { metadata["container"] = container }
                let result = GXCustomizationAccess.verifyLaunchApplication(metadata)
                return LaunchArtworkAvailability(available: (result["available"] as? NSNumber)?.boolValue ?? false,
                    retryable: (result["retryable"] as? NSNumber)?.boolValue ?? false, missing: (result["missing"] as? NSNumber)?.boolValue ?? false)
            })
            #else
            return Backend(inventory: { _ in .init(complete: true, candidates: []) }, verify: { _ in .init(available: false) })
            #endif
        }
    }
    private struct Entry: Codable {
        var app: LaunchArtworkApp
        let generation: String
        let available: Bool
        let checked: Date
    }
    private struct Cache: Codable {
        let version: Int
        let device: String
        var entries: [String: Entry]
        var roster: String?
        var containerGeneration: String?
        var discoveryDate: Date?
    }
    private let storage: URL
    private let device: String
    private let backend: Backend
    private var entries: [String: Entry] = [:]
    private var loaded = false
    private var dirty = 0
    private var roster = ""
    private var containerGeneration = ""
    private var discoveryDate = Date.distantPast
    init(storage: URL, device: String, backend: Backend = .device) {
        self.storage = storage; self.device = device; self.backend = backend
    }
    private var index: URL { storage.appendingPathComponent("Index.plist") }
    private func load() {
        guard !loaded else { return }; loaded = true
        try? FileManager.default.removeItem(at: storage.appendingPathComponent("Icons", isDirectory: true))
        guard !device.isEmpty, let size = try? index.resourceValues(forKeys: [.fileSizeKey, .isSymbolicLinkKey]), size.isSymbolicLink != true,
              (size.fileSize ?? Int.max) <= 4 * 1024 * 1024,
              let data = try? Data(contentsOf: index), let cache = try? PropertyListDecoder().decode(Cache.self, from: data),
              cache.version == 4, cache.device == device, cache.entries.count <= 2048 else { return }
        entries = cache.entries.filter { $0.key == $0.value.app.id && LaunchArtworkDirectory.validIdentifier($0.key) }
        roster = cache.roster ?? ""; containerGeneration = cache.containerGeneration ?? ""; discoveryDate = cache.discoveryDate ?? .distantPast
    }
    func cached() -> [LaunchArtworkApp] {
        load()
        return entries.values.filter(\.available).map(\.app).sorted(by: LaunchArtworkAppOrder.before)
    }
    private func save() {
        guard dirty > 0, !device.isEmpty else { return }
        do { try CustomizationFiles.saveVerified(Cache(version: 4, device: device, entries: entries, roster: roster,
            containerGeneration: containerGeneration, discoveryDate: discoveryDate), to: index); dirty = 0 }
        catch { /* Keep the in-memory list usable when storage is temporarily unavailable. */ }
    }
    nonisolated func events(force: Bool = false) -> AsyncStream<LaunchArtworkCatalogEvent> {
        AsyncStream { continuation in
            let worker = Task {
                await refresh(force: force, continuation: continuation)
                continuation.finish()
            }
            continuation.onTermination = { _ in worker.cancel() }
        }
    }
    private func refresh(force: Bool, continuation: AsyncStream<LaunchArtworkCatalogEvent>.Continuation) {
        continuation.yield(.snapshot(cached()))
        defer { save() }
        var processed: [String: String] = [:]
        let first = backend.inventory(false)
        let fingerprint = CustomizationFiles.digest(Data(first.candidates.sorted(by: { $0.app.id < $1.app.id }).map {
            "\($0.app.id)|\($0.generation)|\($0.installed)"
        }.joined(separator: "\n").utf8))
        process(first, force: force, processed: &processed, continuation: continuation)
        guard !Task.isCancelled else { return }
        // Cache-first display does not wait for inode discovery. Missing paths
        // and restricted LaunchServices listings are filled by one background pass.
        let rosterChanged = roster != fingerprint
        let containersChanged = !first.containerGeneration.isEmpty && first.containerGeneration != containerGeneration
        let needsPaths = first.candidates.contains { $0.installed && $0.container == nil }
        let unknownDirectoryState = first.containerGeneration.isEmpty && Date().timeIntervalSince(discoveryDate) > 120
        if force || containersChanged || (rosterChanged && needsPaths) || (!first.complete && unknownDirectoryState) {
            let discovered = backend.inventory(true)
            process(discovered, force: force, processed: &processed, continuation: continuation)
            discoveryDate = Date()
        }
        roster = fingerprint; containerGeneration = first.containerGeneration; dirty += 1
    }
    private func process(_ inventory: LaunchArtworkInventory, force: Bool, processed: inout [String: String],
                         continuation: AsyncStream<LaunchArtworkCatalogEvent>.Continuation) {
        guard !Task.isCancelled else { return }
        let installed = Set(inventory.candidates.filter(\.installed).map { $0.app.id })
        if inventory.complete {
            for id in Array(entries.keys) where !installed.contains(id) { remove(id, continuation: continuation) }
        }
        for candidate in inventory.candidates.sorted(by: { LaunchArtworkAppOrder.before($0.app, $1.app) }) {
            if Task.isCancelled { return }
            let id = candidate.app.id
            guard LaunchArtworkDirectory.validIdentifier(id) else { continue }
            if !candidate.installed { remove(id, continuation: continuation); continue }
            if processed[id] == candidate.generation { continue }
            let old = entries[id]
            var app = candidate.app
            if app.name == id, let previous = old?.app.name, previous != id { app = .init(id: id, name: previous, byteCount: app.byteCount) }
            // A container identifier alone is not a resolved application row.
            // The database pass supplies names before newly found apps appear.
            if app.name == id { continue }
            if app.byteCount <= 0, let size = old?.app.byteCount { app.byteCount = size }
            let same = old?.generation == candidate.generation
            let recentNegative = old.map { !$0.available && Date().timeIntervalSince($0.checked) < 60 } ?? false
            if !force, same, let old, old.available || recentNegative {
                var next = old; next.app = app
                entries[id] = next
                if next.app != old.app { dirty += 1 }
                if next.available { continuation.yield(.upsert(next.app)) }
                processed[id] = candidate.generation
                continue
            }
            let result = backend.verify(candidate)
            if result.missing { remove(id, continuation: continuation); processed[id] = candidate.generation; continue }
            if result.retryable {
                if old == nil {
                    entries[id] = Entry(app: app, generation: candidate.generation, available: false, checked: Date())
                    dirty += 1; processed[id] = candidate.generation
                }
                continue
            }
            // iOS can briefly remove/rebuild a snapshot while the app remains
            // installed. Retain its cached row until removal is confirmed.
            if !result.available, old?.available == true { processed[id] = candidate.generation; continue }
            let next = Entry(app: app, generation: candidate.generation, available: result.available, checked: Date())
            entries[id] = next; dirty += 1; processed[id] = candidate.generation
            if result.available { continuation.yield(.upsert(next.app)) }
            else { continuation.yield(.remove(id)) }
            if dirty >= 12 { save() }
        }
    }
    private func remove(_ id: String, continuation: AsyncStream<LaunchArtworkCatalogEvent>.Continuation) {
        if entries.removeValue(forKey: id) != nil { dirty += 1 }
        continuation.yield(.remove(id))
    }
}
