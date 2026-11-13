// SPDX-License-Identifier: GPL-3.0-only
import Foundation

enum CapturedSoundEvent: Sendable {
    case snapshot([CapturedNotificationSound])
    case upsert(CapturedNotificationSound)
    case remove(String)   // id
}

/// Durable, minimal store of captured notification sounds. It persists only the
/// smallest useful result (bundle id, filename, origin, a short readable
/// location, timestamp) — never the raw console text, notification body, pairing
/// code, or absolute private container paths. Deduplicates per (bundle, file).
actor CapturedSoundStore {
    /// One actor per process so capture writes emit events to every listener
    /// (the audio library subscribes while the capture sheet is open).
    static let shared = CapturedSoundStore(
        storage: DeviceConsolePaths.capturedSounds,
        device: DeviceConsolePaths.deviceIdentifier)

    struct Limits: Sendable {
        var maxCount = 2048
        var maxFilenameLength = 255
        var maxBundleLength = 255
        var maxLocationLength = 255
        var maxFileSize = 2 * 1024 * 1024
        init() {}
    }

    private struct Cache: Codable {
        let version: Int
        let device: String
        var sounds: [CapturedNotificationSound]
    }

    private let storage: URL
    private let device: String
    private let limits: Limits

    private var sounds: [String: CapturedNotificationSound] = [:]
    private var loaded = false
    private var dirty = false
    private var subscribers: [UUID: AsyncStream<CapturedSoundEvent>.Continuation] = [:]

    private static let version = 1

    init(storage: URL, device: String, limits: Limits = Limits()) {
        self.storage = storage; self.device = device; self.limits = limits
    }

    private var index: URL { storage.appendingPathComponent("CapturedSounds.plist") }

    // MARK: - Loading / saving

    private func load() {
        guard !loaded else { return }
        loaded = true
        guard !device.isEmpty,
              let values = try? index.resourceValues(forKeys: [.fileSizeKey, .isSymbolicLinkKey]),
              values.isSymbolicLink != true, (values.fileSize ?? Int.max) <= limits.maxFileSize,
              let data = try? Data(contentsOf: index),
              let cache = try? PropertyListDecoder().decode(Cache.self, from: data),
              cache.version == Self.version, cache.device == device else { return }
        for raw in cache.sounds {
            var sound = raw
            sound.filename = sound.cleanFilename
            guard isWellFormed(sound) else { continue }
            sounds[sound.id] = sound
        }
        enforceCapacity()
    }

    private func save() {
        guard dirty, !device.isEmpty else { return }
        let payload = Cache(version: Self.version, device: device,
                            sounds: Array(sounds.values).sorted { $0.lastSeen > $1.lastSeen })
        do { try CustomizationFiles.saveVerified(payload, to: index); dirty = false }
        catch { /* Keep the in-memory results usable if storage is unavailable. */ }
    }

    private func isWellFormed(_ s: CapturedNotificationSound) -> Bool {
        NotificationSoundLogParser.isValidBundleID(s.bundleID)
            && s.bundleID.utf8.count <= limits.maxBundleLength
            && s.filename.utf8.count <= limits.maxFilenameLength
            && (s.relativeLocation?.utf8.count ?? 0) <= limits.maxLocationLength
            && (s.origin == .system || !s.filename.isEmpty)
    }

    // MARK: - Public API

    /// Merge newly captured sounds, persist, and notify subscribers. Returns the
    /// rows that changed.
    @discardableResult
    func record(_ incoming: [CapturedNotificationSound]) -> [CapturedNotificationSound] {
        load()
        var changed: [CapturedNotificationSound] = []
        for raw in incoming {
            guard isWellFormed(raw) else { continue }
            var merged = raw
            merged.filename = merged.cleanFilename
            merged.needsReconfirm = nil   // a fresh capture resolves provenance
            if let existing = sounds[raw.id] {
                merged.lastSeen = max(existing.lastSeen, raw.lastSeen)
                merged.origin = Self.betterOrigin(existing.origin, raw.origin)
                merged.relativeLocation = raw.relativeLocation ?? existing.relativeLocation
                if existing == merged { continue }
            }
            sounds[raw.id] = merged
            changed.append(merged)
        }
        guard !changed.isEmpty else { return [] }
        enforceCapacity()
        dirty = true
        save()
        for sound in changed { emit(.upsert(sound)) }
        return changed
    }

    func all() -> [CapturedNotificationSound] {
        load()
        return sounds.values.sorted { $0.lastSeen > $1.lastSeen }
    }

    /// Bundle identifiers that have at least one captured sound — used to build
    /// the app-list union.
    func observedBundleIDs() -> Set<String> {
        load()
        return Set(sounds.values.map(\.bundleID))
    }

    func sounds(for bundleID: String) -> [CapturedNotificationSound] {
        load()
        return sounds.values.filter { $0.bundleID == bundleID }.sorted { $0.lastSeen > $1.lastSeen }
    }

    /// Remove one captured sound clue.
    func remove(id: String) {
        load()
        guard sounds.removeValue(forKey: id) != nil else { return }
        dirty = true
        save()
        emit(.remove(id))
    }

    /// After an app update or container regeneration, keep the filename clues but
    /// flag their resolved location as needing re-confirmation (never reuse an old
    /// absolute path). Removes nothing on its own.
    func markNeedsReconfirm(bundleIDs: Set<String>) {
        load()
        var touched = false
        for (id, var sound) in sounds where bundleIDs.contains(sound.bundleID) {
            if sound.needsReconfirm == true { continue }
            sound.needsReconfirm = true
            sounds[id] = sound
            touched = true
            emit(.upsert(sound))
        }
        if touched { dirty = true; save() }
    }

    /// Drop all captured sounds for apps confirmed uninstalled.
    func forget(bundleIDs: Set<String>) {
        load()
        var touched = false
        for (id, sound) in sounds where bundleIDs.contains(sound.bundleID) {
            sounds[id] = nil
            touched = true
            emit(.remove(id))
        }
        if touched { dirty = true; save() }
    }

    nonisolated func events() -> AsyncStream<CapturedSoundEvent> {
        AsyncStream { continuation in
            let token = UUID()
            let task = Task { await self.subscribe(token, continuation) }
            continuation.onTermination = { _ in task.cancel(); Task { await self.unsubscribe(token) } }
        }
    }

    // MARK: - Internals

    private func subscribe(_ token: UUID, _ continuation: AsyncStream<CapturedSoundEvent>.Continuation) {
        load()
        subscribers[token] = continuation
        continuation.yield(.snapshot(sounds.values.sorted { $0.lastSeen > $1.lastSeen }))
    }

    private func unsubscribe(_ token: UUID) { subscribers[token] = nil }

    private func emit(_ event: CapturedSoundEvent) {
        for continuation in subscribers.values { continuation.yield(event) }
    }

    private func enforceCapacity() {
        guard sounds.count > limits.maxCount else { return }
        let overflow = sounds.count - limits.maxCount
        let oldest = sounds.values.sorted { $0.lastSeen < $1.lastSeen }.prefix(overflow)
        for sound in oldest { sounds[sound.id] = nil; emit(.remove(sound.id)) }
    }

    private static func betterOrigin(_ existing: CapturedNotificationSound.Origin,
                                     _ incoming: CapturedNotificationSound.Origin) -> CapturedNotificationSound.Origin {
        func rank(_ o: CapturedNotificationSound.Origin) -> Int {
            switch o { case .appData, .appGroup, .bundle: return 3; case .unknown: return 2; case .system: return 1 }
        }
        return rank(incoming) >= rank(existing) ? incoming : existing
    }
}
