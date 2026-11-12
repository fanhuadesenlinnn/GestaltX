import Foundation

@main struct OriginalCacheGenerationTests {
    struct Failure: Error { let message: String }
    static let deviceID = "cache-generation-fixture"
    static let layout = MobileGestaltCacheLayout.originalProfile
    static func expect(_ condition: Bool, _ message: String) throws {
        if !condition { throw Failure(message: message) }
    }
    static func bytes(_ value: Any) throws -> Data {
        try PropertyListSerialization.data(fromPropertyList: value, format: .binary, options: 0)
    }
    static func fixture(_ flags: CachedOptionFlags, wapi: Bool, setting: String = "original") throws -> GestaltDocument {
        var cache = Data(repeating: 0, count: layout.byteCount)
        for index in [layout.greenTeaIndex, layout.notGreenTeaIndex, layout.wapiIndex!] { cache[layout.validityOffset(for: index)] = 1 }
        cache[layout.greenTeaOffset] = flags.greenTea ? 1 : 0
        cache[layout.notGreenTeaOffset] = flags.notGreenTea ? 1 : 0
        cache[layout.wapiOffset!] = wapi ? 1 : 0
        return try GestaltDocument(data: bytes([
            "CacheUUID": layout.uuid, "CacheVersion": "current-system", "CacheData": cache,
            "CacheExtra": ["VasUgeSzVyHdB27g2XpN0g": "same-device", "setting": setting]
        ]))
    }
    static func staleCacheEntry<T: Encodable>(_ value: T) throws -> Data {
        var encoded = try PropertyListSerialization.propertyList(from: PropertyListEncoder().encode(value), format: nil) as! [String: Any]
        encoded["layoutUUID"] = "previous-layout"
        return try bytes(encoded)
    }
    static func oldJournal() throws -> Data {
        let original = try fixture(.restricted, wapi: true)
        return try bytes([
            "version": 1, "deviceID": deviceID,
            "identity": ["VasUgeSzVyHdB27g2XpN0g": "same-device"],
            "values": ["setting": ["exists": true, "value": "remembered-original"]],
            "faceTimeAudio": try staleCacheEntry(CachedOptionsOriginal(document: original)),
            "wapi": try staleCacheEntry(WAPIOriginal(document: original))
        ])
    }
    static func writeBackup(_ document: GestaltDocument, to directory: URL, at time: TimeInterval) throws {
        let data = try document.encoded()
        let record = BackupRecord(id: UUID(), date: Date(timeIntervalSinceReferenceDate: time), reason: "Before applying",
                                  source: .device, deviceID: deviceID, byteCount: data.count)
        try data.write(to: directory.appendingPathComponent(record.filename))
        try JSONEncoder().encode(record).write(to: directory.appendingPathComponent(record.id.uuidString + ".json"))
    }
    static func makeStore(device: URL, backups: URL) -> GestaltFileStore {
        GestaltFileStore(deviceURL: device, backupDirectory: backups, deviceID: deviceID, acquire: { 1 }, release: { _ in })
    }
    static func expectUnavailable(_ snapshot: DocumentSnapshot) throws {
        do {
            _ = try snapshot.originalCachedOptionFlags()
            throw Failure(message: "Unproven current audio flags became an original baseline")
        } catch let error as GestaltFailure {
            try expect(error.key == "The original value belongs to a different cache layout. A matching backup is needed to restore it.", "An unavailable original explains the cache-layout mismatch")
        }
        do {
            _ = try snapshot.originalWAPI()
            throw Failure(message: "Unproven current WAPI became an original baseline")
        } catch let error as GestaltFailure {
            try expect(error.key == "The original value belongs to a different cache layout. A matching backup is needed to restore it.", "WAPI reports the same unavailable layout history")
        }
    }

    static func verifyMigration(in directory: URL) async throws {
        let fm = FileManager.default
        let backups = directory.appendingPathComponent("backups")
        try fm.createDirectory(at: backups, withIntermediateDirectories: true)
        let device = directory.appendingPathComponent("device.plist")
        let original = try fixture(.restricted, wapi: true)
        let current = try fixture(.enabled, wapi: false, setting: "changed")
        try current.encoded().write(to: device)
        // The earliest owned backup is from another system generation, with
        // valid but different cache flags. It must not supply this baseline.
        var oldRoot = try fixture(.enabled, wapi: false, setting: "previous-system-default").root
        oldRoot["CacheVersion"] = "previous-system"
        try writeBackup(GestaltDocument(data: bytes(oldRoot)), to: backups, at: 1)
        oldRoot["CacheUUID"] = "previous-layout"
        oldRoot["CacheVersion"] = "current-system"
        try writeBackup(GestaltDocument(data: bytes(oldRoot)), to: backups, at: 2)
        try writeBackup(original, to: backups, at: 3)
        let journal = backups.appendingPathComponent("OriginalValues.plist")
        let legacy = try oldJournal()
        try legacy.write(to: journal)
        let loaded = try await makeStore(device: device, backups: backups).loadDevice()
        try expect(loaded.originalCachedOptionFlags() == .restricted, "A new layout recovers audio flags from its own earliest pre-write backup")
        try expect(loaded.originalWAPI(), "A new layout recovers WAPI from that same baseline")
        try expect(loaded.originalValue(for: "setting") as? String == "remembered-original", "Cache migration preserves separately recorded CacheExtra originals")
        try expect(loaded.cachedOptionsOriginal?.layoutUUID == layout.uuid && loaded.wapiOriginal?.layoutUUID == layout.uuid, "Incompatible cache entries are replaced only by matching-layout evidence")
        let archives = try fm.contentsOfDirectory(at: backups, includingPropertiesForKeys: nil).filter { $0.lastPathComponent.hasPrefix("OriginalValues-") }
        try expect(archives.count == 1 && (try Data(contentsOf: archives[0])) == legacy, "Migration preserves the complete legacy journal as an exact archive")
        try expect(try Data(contentsOf: device) == current.encoded(), "Journal migration does not change the device file")
        let reloaded = try await makeStore(device: device, backups: backups).loadDevice()
        try expect(reloaded.originalCachedOptionFlags() == .restricted && reloaded.originalWAPI(), "Migrated cache originals survive reopen")

        // The same generation boundary also applies when a deleted journal
        // must be rebuilt, so old OS defaults are not recorded as app edits.
        try fm.removeItem(at: journal)
        let recovered = try await makeStore(device: device, backups: backups).loadDevice()
        try expect(recovered.originalValue(for: "setting") as? String == "original", "Backup recovery does not chain CacheExtra values across system generations")
        try expect(recovered.originalCachedOptionFlags() == .restricted && recovered.originalWAPI(), "Missing-journal recovery skips older system flag values")
    }

    static func verifyUnavailableHistory(in directory: URL) async throws {
        let fm = FileManager.default
        let backups = directory.appendingPathComponent("backups")
        try fm.createDirectory(at: backups, withIntermediateDirectories: true)
        let device = directory.appendingPathComponent("device.plist")
        let current = try fixture(.enabled, wapi: false, setting: "already-modified")
        try current.encoded().write(to: device)
        var oldRoot = try fixture(.restricted, wapi: true).root
        oldRoot["CacheUUID"] = "previous-layout"
        try writeBackup(GestaltDocument(data: bytes(oldRoot)), to: backups, at: 1)
        let legacy = try oldJournal()
        let journal = backups.appendingPathComponent("OriginalValues.plist")
        try legacy.write(to: journal)
        let store = makeStore(device: device, backups: backups)
        let loaded = try await store.loadDevice()
        try expectUnavailable(loaded)
        var unrelated = loaded.document
        unrelated.set("unrelated edit", for: "another-setting")
        let saved = try await store.commit(unrelated, expected: loaded)
        try expect(saved.document.extra["another-setting"] as? String == "unrelated edit", "Unavailable cache originals do not block unrelated device edits")
        var flags = saved.document
        try flags.setCacheOptions(.restricted)
        try flags.setWAPI(true)
        let afterFlags = try await store.commit(flags, expected: saved)
        try expectUnavailable(afterFlags)
        let reopened = try await makeStore(device: device, backups: backups).loadDevice()
        try expectUnavailable(reopened)
        try expect(reopened.cachedOptionsOriginal?.layoutUUID == "previous-layout", "Later edits must not replace unavailable history with the already-modified current flags")
        let metadata = try PropertyListSerialization.propertyList(from: Data(contentsOf: journal), format: nil) as! [String: Any]
        let unavailable = metadata["unavailableCacheOriginals"] as? [String: [String]]
        try expect(unavailable?["faceTimeAudio"] == [layout.uuid] && unavailable?["wapi"] == [layout.uuid], "The unavailable baseline survives subsequent journal writes")
        let archives = try fm.contentsOfDirectory(at: backups, includingPropertiesForKeys: nil).filter { $0.lastPathComponent.hasPrefix("OriginalValues-") }
        try expect(archives.count == 1 && (try Data(contentsOf: archives[0])) == legacy, "The original evidence is retained without creating a new archive on every edit")

        // Exercise the old on-disk single-UUID marker as well as a layout cycle.
        // B's pre-write backups were made after its origin became unknown.
        var singleUUID = metadata
        singleUUID["unavailableCacheOriginals"] = ["faceTimeAudio": layout.uuid, "wapi": layout.uuid]
        try bytes(singleUUID).write(to: journal)
        let beforeCycle = try Data(contentsOf: device)
        var thirdLayout = reopened.document.root
        thirdLayout["CacheUUID"] = "third-layout"
        try bytes(thirdLayout).write(to: device)
        let third = try await makeStore(device: device, backups: backups).loadDevice()
        try expect(third.cachedOptionsOriginal?.layoutUUID == "previous-layout" && third.wapiOriginal?.layoutUUID == "previous-layout",
                   "An unknown third layout does not invent original cache entries")
        try beforeCycle.write(to: device)
        let returned = try await makeStore(device: device, backups: backups).loadDevice()
        try expectUnavailable(returned)
        try expect(returned.cachedOptionsOriginal?.layoutUUID == "previous-layout" && returned.wapiOriginal?.layoutUUID == "previous-layout",
                   "Returning to an unknown layout must not use backups created after its failed recovery as originals")
        let cycled = try PropertyListSerialization.propertyList(from: Data(contentsOf: journal), format: nil) as! [String: Any]
        let remembered = cycled["unavailableCacheOriginals"] as? [String: [String]]
        for key in ["faceTimeAudio", "wapi"] {
            try expect(Set(remembered?[key] ?? []) == Set([layout.uuid, "third-layout"]), "All unknown layouts remain recorded across a layout cycle")
        }
    }

    static func main() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try await verifyMigration(in: directory.appendingPathComponent("matching-history"))
        try await verifyUnavailableHistory(in: directory.appendingPathComponent("unavailable-history"))
        print("PASS: cache originals migrate from matching generations, old journals are preserved, and unavailable history stays local to restore operations.")
    }
}
