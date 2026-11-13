import Foundation

@main struct BackupMetadataIdentityTests {
    struct Failure: Error { let message: String }
    static func expect(_ condition: Bool, _ message: String) throws {
        if !condition { throw Failure(message: message) }
    }

    static func run(_ name: String) async throws {
        let fm = FileManager.default
        let directory = fm.temporaryDirectory.appendingPathComponent("GestaltX-backup-identity-" + UUID().uuidString)
        let backups = directory.appendingPathComponent("backups")
        try fm.createDirectory(at: backups, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: directory) }
        let data = try PropertyListSerialization.data(fromPropertyList: ["CacheExtra": ["value": "original"]], format: .binary, options: 0)
        let store = GestaltFileStore(deviceURL: directory.appendingPathComponent("device.plist"), backupDirectory: backups,
                                     deviceID: "fixture", acquire: { -1 }, release: { _ in })
        let record = BackupRecord(id: UUID(), date: Date(), reason: "Manual backup", source: .local,
                                  deviceID: "fixture", byteCount: data.count)
        let metadata = backups.appendingPathComponent(record.id.uuidString + ".json")
        try data.write(to: backups.appendingPathComponent(record.filename))
        try JSONEncoder().encode(record).write(to: metadata)
        switch name {
        case "duplicate":
            let duplicate = backups.appendingPathComponent(UUID().uuidString + ".json")
            try fm.copyItem(at: metadata, to: duplicate)
            let records = try await store.backups()
            try expect(records.count == 1 && records[0].id == record.id,
                       "Mismatched metadata must not duplicate another backup")
            try expect(try await store.backupData(records[0]) == data, "The authentic backup remains recoverable")
            try expect(fm.fileExists(atPath: duplicate.path), "Listing must not delete a mismatched file")
        case "renamed-only":
            try fm.moveItem(at: metadata, to: backups.appendingPathComponent(UUID().uuidString + ".json"))
            try expect(try await store.backups().isEmpty,
                       "A metadata alias must not offer operations against another backup ID")
            try expect(try Data(contentsOf: backups.appendingPathComponent(record.filename)) == data,
                       "Rejected metadata must leave the payload intact")
        case "non-uuid":
            try fm.copyItem(at: metadata, to: backups.appendingPathComponent("Backup copy.json"))
            try expect(try await store.backups().count == 1,
                       "Unrecognized metadata names must not enter backup history")
        case "legacy":
            let records = try await store.backups()
            try expect(records.count == 1 && records[0].sha256 == nil, "Legacy records without a digest remain visible")
            try expect(try await store.backupData(records[0]) == data, "Valid legacy backups remain readable")
        case "lowercase":
            // Use a separate temporary name so this also works on case-insensitive volumes.
            let temporary = backups.appendingPathComponent("rename.tmp")
            try fm.moveItem(at: metadata, to: temporary)
            try fm.moveItem(at: temporary, to: backups.appendingPathComponent(record.id.uuidString.lowercased() + ".json"))
            let records = try await store.backups()
            try expect(records.count == 1 && records[0].id == record.id, "UUID filename case must not reject the same identity")
        case "delete":
            let listed = try await store.backups()
            try expect(listed.count == 1, "The authentic backup is listed before deletion")
            try await store.deleteBackup(listed[0])
            try expect(try fm.contentsOfDirectory(atPath: backups.path).isEmpty,
                       "A listed backup's deletion addresses its own metadata and payload")
        default: throw Failure(message: "Unknown case: \(name)")
        }
        print("PASS \(name)")
    }

    static func main() async throws {
        let cases = Array(CommandLine.arguments.dropFirst())
        for name in cases.isEmpty || cases == ["all"] ? ["duplicate", "renamed-only", "non-uuid", "legacy", "lowercase", "delete"] : cases {
            try await run(name)
        }
    }
}
