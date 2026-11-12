import Foundation

@main struct OriginalHistoryMigrationTests {
    struct Failure: Error { let message: String }
    final class Trace: @unchecked Sendable { var backupReads = 0; var writes = 0 }
    static func expect(_ condition: Bool, _ message: String) throws {
        if !condition { throw Failure(message: message) }
    }

    static func verify(in directory: URL, legacy: Bool, cacheEdits: Bool) async throws {
        let fm = FileManager.default
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        let device = directory.appendingPathComponent("device.plist")
        let backups = directory.appendingPathComponent("backups")
        let layout = MobileGestaltCacheLayout.originalProfile
        var cache = Data(repeating: 0, count: layout.byteCount)
        for index in [layout.greenTeaIndex, layout.notGreenTeaIndex, layout.wapiIndex!] { cache[layout.validityOffset(for: index)] = 1 }
        cache[layout.greenTeaOffset] = 1
        cache[layout.wapiOffset!] = 1
        let bytes = try PropertyListSerialization.data(fromPropertyList: [
            "CacheExtra": ["setting": "original", "VasUgeSzVyHdB27g2XpN0g": "same-device"],
            "CacheUUID": layout.uuid, "CacheVersion": "test-version", "CacheData": cache
        ], format: .binary, options: 0)
        try bytes.write(to: device)
        let trace = Trace()
        func makeStore() -> GestaltFileStore {
            GestaltFileStore(deviceURL: device, backupDirectory: backups, deviceID: "migration-fixture",
                             acquire: { 1 }, release: { _ in },
                             writeData: { data, url in trace.writes += 1; try data.write(to: url) },
                             eventSink: { event in
                if event.hasPrefix("Original values: reading backup ") { trace.backupReads += 1 }
            })
        }
        let store = makeStore()
        let initial = try await store.loadDevice()
        var edited = initial.document
        edited.set("changed", for: "setting")
        if cacheEdits { try edited.setCacheOptions(.enabled); try edited.setWAPI(false) }
        _ = try await store.commit(edited, expected: initial)
        let record = try await store.backups().first { $0.reason == "Before applying" }!
        let payload = backups.appendingPathComponent(record.filename)
        let journal = backups.appendingPathComponent("OriginalValues.plist")
        if legacy {
            var old = try PropertyListSerialization.propertyList(from: Data(contentsOf: journal), format: nil) as! [String: Any]
            old.removeValue(forKey: "cacheHistoryRecovered")
            old.removeValue(forKey: "faceTimeAudio")
            old.removeValue(forKey: "wapi")
            try PropertyListSerialization.data(fromPropertyList: old, format: .binary, options: 0).write(to: journal)
        } else {
            // A valid current journal is sufficient even if an old full-file
            // backup was later truncated or replaced outside the app.
            try Data([0]).write(to: payload)
        }
        trace.backupReads = 0
        let reopened = makeStore()
        let loaded = try await reopened.loadDevice()
        try expect(loaded.originalValue(for: "setting") as? String == "original", "A complete journal retains its real original field value")
        try expect(trace.backupReads == (legacy ? 1 : 0), "Legacy flags use one actual backup read; current journals do not enter history recovery")
        if cacheEdits {
            try expect(loaded.originalCachedOptionFlags() == .restricted, "One legacy pass recovers the original audio flags")
            try expect(loaded.originalWAPI(), "The same legacy pass recovers original WAPI")
        } else {
            try expect(loaded.cachedOptionsOriginal == nil && loaded.wapiOriginal == nil, "Migration does not invent edits when cache flags have no history")
        }
        let migrated = try PropertyListSerialization.propertyList(from: Data(contentsOf: journal), format: nil) as! [String: Any]
        try expect(migrated["cacheHistoryRecovered"] as? Bool == true, "Completed migration is durable even when neither flag has an entry")

        try Data([0]).write(to: payload)
        trace.backupReads = 0
        let again = try await makeStore().loadDevice()
        try expect(trace.backupReads == 0, "Reopening does not rescan a now-corrupt backup after migration")
        var laterEdit = again.document
        laterEdit.set("another edit", for: "later")
        _ = try await reopened.commit(laterEdit, expected: again)
        try expect(trace.backupReads == 0 && trace.writes == 2, "A complete journal allows subsequent verified device writes without reading corrupt history")
    }

    static func main() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try await verify(in: directory.appendingPathComponent("current"), legacy: false, cacheEdits: false)
        try await verify(in: directory.appendingPathComponent("legacy-fields"), legacy: true, cacheEdits: false)
        try await verify(in: directory.appendingPathComponent("legacy-flags"), legacy: true, cacheEdits: true)
        print("PASS: durable one-pass legacy migration; complete journals survive corrupt old backups on reopen and commit.")
    }
}
