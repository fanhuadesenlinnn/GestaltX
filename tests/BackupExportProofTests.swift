import Foundation

@main struct BackupExportProofTests {
    struct Failure: Error { let message: String }
    final class Trace: @unchecked Sendable { var seals = 0 }
    static func expect(_ condition: Bool, _ message: String) throws {
        if !condition { throw Failure(message: message) }
    }
    static func main() async throws {
        let fm = FileManager.default
        let directory = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? fm.removeItem(at: directory) }
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        let device = directory.appendingPathComponent("device.plist")
        let backups = directory.appendingPathComponent("backups", isDirectory: true)
        // Real caches can omit all stable identifiers; their exports need proof.
        let original = try PropertyListSerialization.data(fromPropertyList: ["CacheExtra": ["feature": true]], format: .binary, options: 0)
        try original.write(to: device)
        let store = GestaltFileStore(deviceURL: device, backupDirectory: backups, deviceID: "this-installation", acquire: { 1 }, release: { _ in })
        _ = try await store.loadDevice()
        let owned = try await store.backups().first!
        let key = Data(repeating: 0x31, count: 32)
        let exported = try await store.backupExportData(owned, sealingWith: { try DeviceBoundPlist.seal($0, key: key) })
        let verified = try DeviceBoundPlist.verify(exported, key: key)
        try expect(try GestaltDocument(data: verified).matches(GestaltDocument(data: original)), "An owned device backup round-trips through proof verification")
        try expect(try await store.backupData(owned) == original, "Export never changes the stored backup")
        do {
            _ = try DeviceBoundPlist.verify(exported, key: Data(repeating: 0x32, count: 32))
            throw Failure(message: "Another device key accepted the export")
        } catch is SharedPlistError {}

        let trace = Trace()
        let foreign = BackupRecord(id: owned.id, date: owned.date, reason: owned.reason, source: .device,
                                   deviceID: "other-installation", byteCount: owned.byteCount, sha256: owned.sha256)
        let foreignData = try await store.backupExportData(foreign, sealingWith: { data in trace.seals += 1; return data })
        try expect(foreignData == original && trace.seals == 0, "Foreign device metadata cannot acquire this installation's proof")
        let local = try await store.loadLocal(data: original, name: "local.plist")
        try await store.backup(local)
        let localRecord = try await store.backups().first { $0.source == .local }!
        let localData = try await store.backupExportData(localRecord, sealingWith: { data in trace.seals += 1; return data })
        try expect(localData == original && trace.seals == 0, "Local backup exports remain unproven")

        do {
            _ = try await store.backupExportData(owned, sealingWith: { _ in throw Failure(message: "Sealing unavailable") })
            throw Failure(message: "A failed seal must not fall back to an unproven export")
        } catch let error as Failure {
            try expect(error.message == "Sealing unavailable", "Propagate a sealing failure")
        }
        try Data("corrupt backup".utf8).write(to: backups.appendingPathComponent(owned.filename))
        do {
            _ = try await store.backupExportData(owned, sealingWith: { data in trace.seals += 1; return data })
            throw Failure(message: "A corrupt backup received an export")
        } catch is GestaltFailure {}
        try expect(trace.seals == 0, "Verify backup integrity before invoking the sealer")
        print("PASS: device-owned backup export proof, identifier-free roundtrip, foreign/local isolation and failure propagation.")
    }
}
