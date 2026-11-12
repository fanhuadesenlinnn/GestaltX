import Foundation

@main struct LocalRestoreProvenanceTests {
    struct Failure: Error { let message: String }
    static func expect(_ condition: Bool, _ message: String) throws {
        if !condition { throw Failure(message: message) }
    }

    static func main() async throws {
        let fm = FileManager.default
        let directory = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: directory) }
        let device = directory.appendingPathComponent("device.plist")
        func fixture(_ serial: String, _ value: String) throws -> Data {
            try PropertyListSerialization.data(fromPropertyList: [
                "CacheExtra": ["VasUgeSzVyHdB27g2XpN0g": serial, "setting": value],
                "CacheUUID": "same-layout", "CacheVersion": "same-version", "CacheData": Data([0, 1, 2])
            ], format: .binary, options: 0)
        }
        let initialBytes = try fixture("current-device", "original")
        try initialBytes.write(to: device)
        let store = GestaltFileStore(deviceURL: device, backupDirectory: directory.appendingPathComponent("backups"),
                                     deviceID: "provenance-fixture", acquire: { 1 }, release: { _ in })
        let live = try await store.loadDevice()
        var verified = try await store.loadLocal(data: initialBytes, name: "verified-export.plist")
        verified.ownershipVerified = true
        var edit = verified.document
        edit.set("local edit", for: "setting")
        let savedEdit = try await store.commit(edit, expected: verified)
        try expect(savedEdit.ownershipVerified, "Ordinary edits preserve a verified import's ownership")

        let untrustedBytes = try fixture("foreign-device", "unverified backup")
        let untrusted = try await store.loadLocal(data: untrustedBytes, name: "foreign.plist")
        try await store.backup(untrusted)
        let record = try await store.backups().first { $0.source == .local && $0.reason == "Manual backup" }!
        let replacement = try GestaltDocument(data: await store.backupData(record))
        let restored = try await store.commit(replacement, expected: savedEdit, restoring: record)
        try expect(restored.source == .local && restored.document.matches(replacement), "Unverified backups remain available for local editing")
        try expect(!restored.ownershipVerified, "A replacement backup must not inherit the previous import's device ownership")
        do {
            _ = try await store.restoreVerifiedImport(restored, expected: live)
            throw Failure(message: "The replacement backup incorrectly qualified as a verified import")
        } catch let failure as GestaltFailure {
            try expect(failure.key == "This plist's device proof could not be verified on this device.", "Reject replacement at the ownership gate")
        }
        try expect(try Data(contentsOf: device) == initialBytes, "Local replacement never writes the device")

        var anotherEdit = restored.document
        anotherEdit.set("further edit", for: "setting")
        let stillUnverified = try await store.commit(anotherEdit, expected: restored)
        try expect(!stillUnverified.ownershipVerified, "Later edits cannot regain the discarded ownership")
        let identical = try await store.commit(verified.document, expected: verified, restoring: record)
        try expect(!identical.ownershipVerified, "A backup replacement requires fresh verification even when its values happen to match")
        print("PASS: local edits preserve provenance; backup replacement clears it and cannot restore the device.")
    }
}
