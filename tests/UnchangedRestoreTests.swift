import Foundation

@main struct UnchangedRestoreTests {
    struct Failure: Error { let message: String }
    final class Trace: @unchecked Sendable { var writes = 0; var acquisitions = 0; var releases = 0 }
    static func expect(_ condition: Bool, _ message: String) throws {
        if !condition { throw Failure(message: message) }
    }

    static func main() async throws {
        let fm = FileManager.default
        let directory = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: directory) }
        let device = directory.appendingPathComponent("device.plist")
        let backups = directory.appendingPathComponent("backups")
        // Keep the live file in XML to prove the no-op preserves its actual bytes.
        let bytes = try PropertyListSerialization.data(fromPropertyList: [
            "CacheExtra": ["VasUgeSzVyHdB27g2XpN0g": "same-device", "setting": "original"],
            "CacheUUID": "current-layout", "CacheVersion": "version", "CacheData": Data([0, 1, 2])
        ], format: .xml, options: 0)
        try bytes.write(to: device)
        let trace = Trace()
        let store = GestaltFileStore(deviceURL: device, backupDirectory: backups, deviceID: "unchanged-fixture",
                                     acquire: { trace.acquisitions += 1; return 1 }, release: { _ in trace.releases += 1 },
                                     writeData: { data, url in trace.writes += 1; try data.write(to: url) })
        let initial = try await store.loadDevice()
        let record = try await store.backups().first!
        let identical = try GestaltDocument(data: initial.document.encoded())
        let result = try await store.commit(identical, expected: initial, restoring: record)
        try expect(trace.writes == 0, "Restoring identical values must not write the device")
        try expect(result.data == bytes && (try Data(contentsOf: device)) == bytes, "No-op restoration preserves the original file encoding and snapshot bytes")
        try expect(try await store.backups().count == 1, "No-op restoration must not create a duplicate backup")
        try expect(!fm.fileExists(atPath: backups.appendingPathComponent("OriginalValues.plist").path), "No-op restoration must not create a journal")
        try expect(trace.acquisitions == 2 && trace.releases == 2, "No-op restoration still checks the live file within a balanced access scope")

        var imported = try await store.loadLocal(data: identical.encoded(), name: "same.plist")
        imported.ownershipVerified = true
        _ = try await store.restoreVerifiedImport(imported, expected: initial)
        let afterImportBackups = try await store.backups()
        try expect(trace.writes == 0 && afterImportBackups.count == 1, "An identical verified import also avoids writing and duplicate backup creation")
        var changed = initial.document
        changed.set("external change", for: "setting")
        try changed.encoded().write(to: device)
        for verifiedImport in [false, true] {
            do {
                if verifiedImport { _ = try await store.restoreVerifiedImport(imported, expected: initial) }
                else { _ = try await store.commit(identical, expected: initial, restoring: record) }
                throw Failure(message: "An identical target bypassed stale snapshot detection")
            } catch let failure as GestaltFailure {
                try expect(failure.key == "MobileGestalt changed since it was loaded. Refresh before applying your edits.", "No-op restore reports a stale snapshot")
            }
        }
        try bytes.write(to: device)
        let foreign = BackupRecord(id: record.id, date: record.date, reason: record.reason, source: .device,
                                   deviceID: "another-device", byteCount: record.byteCount, sha256: record.sha256)
        do {
            _ = try await store.commit(identical, expected: initial, restoring: foreign)
            throw Failure(message: "An identical target bypassed backup ownership validation")
        } catch is GestaltFailure {}
        try expect(trace.writes == 0, "Rejected no-op restores never invoke the writer")

        let corrected = try await store.commit(identical, expected: initial, restoring: record, originallyAbsentKeys: ["confirmed-added"])
        try expect(corrected.originals["confirmed-added"] != nil && corrected.originals["confirmed-added"]?.value == nil,
                   "Explicit original-absence corrections are not discarded as no-ops")
        let writesBeforeChange = trace.writes
        let actualRestore = try await store.commit(changed, expected: corrected, restoring: record)
        try expect(trace.writes == writesBeforeChange + 1 && actualRestore.document.matches(changed), "A real restore still writes and verifies the new document")
        print("PASS: identical backups and imports skip writes; freshness, ownership and explicit origin corrections remain enforced.")
    }
}
