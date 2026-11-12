import Foundation

@main struct BackupDeletionTests {
    struct Failure: Error { let message: String }
    final class RemovalTrace: @unchecked Sendable {
        var failPayload = true
        var failMetadataOnce = false
        var paths: [String] = []
    }
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
        let bytes = try PropertyListSerialization.data(fromPropertyList: ["CacheExtra": ["setting": "original"]], format: .binary, options: 0)
        try bytes.write(to: device)
        let trace = RemovalTrace()
        let store = GestaltFileStore(deviceURL: device, backupDirectory: backups, deviceID: "deletion-fixture",
                                     acquire: { 1 }, release: { _ in }, removeBackupItem: { url in
            trace.paths.append(url.lastPathComponent)
            if trace.failPayload && url.pathExtension == "plist" { throw CocoaError(.fileWriteNoPermission) }
            if trace.failMetadataOnce && url.pathExtension == "json" {
                trace.failMetadataOnce = false
                throw CocoaError(.fileWriteNoPermission)
            }
            try FileManager.default.removeItem(at: url)
        })
        let initial = try await store.loadDevice()
        let record = try await store.backups().first!
        let metadata = backups.appendingPathComponent(record.id.uuidString + ".json")
        let originalMetadata = try Data(contentsOf: metadata)
        do {
            try await store.deleteBackup(record)
            throw Failure(message: "The injected payload deletion failure was swallowed")
        } catch let error as CocoaError {
            try expect(error.code == .fileWriteNoPermission, "Report the real deletion error")
        }
        try expect(try await store.backups().contains { $0.id == record.id }, "A failed payload removal must leave the backup visible")
        try expect(try await store.backupData(record) == bytes, "The visible backup remains recoverable")
        try expect(try Data(contentsOf: metadata) == originalMetadata, "A failed payload removal preserves its original metadata")
        try expect(trace.paths == [record.filename], "Metadata removal is not attempted before a successful payload removal")

        trace.failPayload = false
        trace.paths = []
        try await store.deleteBackup(record)
        try expect(try await store.backups().isEmpty, "A successful retry removes the backup from the listing")
        try expect(!fm.fileExists(atPath: metadata.path), "A successful delete removes metadata")
        try expect(!fm.fileExists(atPath: backups.appendingPathComponent(record.filename).path), "A successful delete removes payload")
        try expect(try fm.contentsOfDirectory(atPath: backups.path).isEmpty, "A successful delete leaves no staging or orphan files")

        try await store.backup(initial)
        let interrupted = try await store.backups().first!
        let interruptedMetadata = backups.appendingPathComponent(interrupted.id.uuidString + ".json")
        trace.failMetadataOnce = true
        do {
            try await store.deleteBackup(interrupted)
            throw Failure(message: "The injected metadata deletion failure was swallowed")
        } catch let error as CocoaError {
            try expect(error.code == .fileWriteNoPermission, "Metadata errors remain visible to the caller")
        }
        try expect(!fm.fileExists(atPath: backups.appendingPathComponent(interrupted.filename).path), "The interrupted delete already removed the payload")
        try expect(fm.fileExists(atPath: interruptedMetadata.path), "The interrupted delete still has metadata to clean up")
        try await store.deleteBackup(interrupted)
        try expect(try fm.contentsOfDirectory(atPath: backups.path).isEmpty, "Retry after metadata failure tolerates only the missing payload and completes cleanup")
        try expect(try Data(contentsOf: device) == bytes, "Deleting backups never modifies the device file")
        print("PASS: failed payload deletion preserves a visible recoverable backup; retries also finish interrupted metadata cleanup.")
    }
}
