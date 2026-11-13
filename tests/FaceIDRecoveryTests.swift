import Foundation

@main struct FaceIDRecoveryTests {
    struct Failure: Error { let message: String }
    static func expect(_ condition: Bool, _ message: String) throws {
        if !condition { throw Failure(message: message) }
    }
    static func reject(_ operation: () async throws -> DocumentSnapshot) async throws {
        do {
            _ = try await operation()
            throw Failure(message: "Unsafe hardware restoration was accepted")
        } catch is GestaltFailure {}
    }

    static func main() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let device = directory.appendingPathComponent("device.plist")
        let backupDirectory = directory.appendingPathComponent("backups")
        let root: [String: Any] = [
            "CacheUUID": "fixture-layout", "CacheVersion": "fixture-version", "CacheData": Data([1, 2, 3]),
            "CacheExtra": [
                GestaltKeys.productType: "iPhone14,2", GestaltKeys.hardwareModel: "D63AP",
                GestaltKeys.cpu: "t8110", GestaltKeys.modelNumber: "A2483",
                "VasUgeSzVyHdB27g2XpN0g": "TESTSERIAL01",
                "re6Zb+zwFKJNlkQTUeT+/w": "0123456789ABCDEF",
                GestaltKeys.regionCode: "CH", GestaltKeys.regionInfo: "CH/A"
            ]
        ]
        let originalData = try PropertyListSerialization.data(fromPropertyList: root, format: .binary, options: 0)
        try originalData.write(to: device)
        let store = GestaltFileStore(deviceURL: device, backupDirectory: backupDirectory, deviceID: "fixture",
                                     acquire: { 0 }, release: { _ in })
        let original = try await store.loadDevice()
        let record = try await store.backups().first!
        var spoofed = original.document
        spoofed.set("iPhone16,1", for: GestaltKeys.productType)
        spoofed.set("D83AP", for: GestaltKeys.hardwareModel)
        spoofed.set("t8130", for: GestaltKeys.cpu)
        spoofed.set("A2848", for: GestaltKeys.modelNumber)
        spoofed.applyRegion(code: "LL", salesSuffix: "LL/A")
        spoofed.set("keep me", for: "unrelated")
        let ai = Capability.all.first { $0.id == "ai" }!
        let siri = Capability.all.first { $0.id == "siriAIMode" }!
        ai.apply(.enable, to: &spoofed, restoringFrom: original)
        siri.apply(.enable, to: &spoofed, restoringFrom: original)
        let loaded = try await store.commit(spoofed, expected: original)
        let verifiedImport = DocumentSnapshot(data: originalData, document: original.document,
                                              source: .local, name: "original", ownershipVerified: true)

        for key in GestaltKeys.hardwareIdentity + ["VasUgeSzVyHdB27g2XpN0g"] {
            var invalid = original.document
            invalid.set(nil, for: key)
            let imported = DocumentSnapshot(data: try invalid.encoded(), document: invalid, source: .local,
                                            name: "invalid", ownershipVerified: true)
            try await reject {
                try await store.restoreHardwareIdentity(from: imported, expected: loaded,
                                                        physicalProduct: "iPhone14,2", physicalBoard: "D63AP")
            }
        }
        var wrongCPU = original.document
        wrongCPU.set("t8130", for: GestaltKeys.cpu)
        let wrongCPUImport = DocumentSnapshot(data: try wrongCPU.encoded(), document: wrongCPU,
                                              source: .local, name: "wrong CPU", ownershipVerified: true)
        try await reject {
            try await store.restoreHardwareIdentity(from: wrongCPUImport, expected: loaded,
                                                    physicalProduct: "iPhone14,2", physicalBoard: "D63AP")
        }
        for key in ["CacheUUID", "CacheVersion", "CacheData"] {
            var invalidRoot = root
            invalidRoot[key] = key == "CacheData" ? Data([1, 2, 4]) : "other"
            let data = try PropertyListSerialization.data(fromPropertyList: invalidRoot, format: .binary, options: 0)
            let imported = DocumentSnapshot(data: data, document: try GestaltDocument(data: data),
                                            source: .local, name: "invalid", ownershipVerified: true)
            try await reject {
                try await store.restoreHardwareIdentity(from: imported, expected: loaded,
                                                        physicalProduct: "iPhone14,2", physicalBoard: "D63AP")
            }
        }
        for (product, board) in [("", "D63AP"), ("iPhone16,1", "D63AP"), ("iPhone14,2", "D83AP")] {
            try await reject {
                try await store.restoreHardwareIdentity(from: record, expected: loaded,
                                                        physicalProduct: product, physicalBoard: board)
            }
        }
        var unverified = verifiedImport
        unverified.ownershipVerified = false
        try await reject {
            try await store.restoreHardwareIdentity(from: unverified, expected: loaded,
                                                    physicalProduct: "iPhone14,2", physicalBoard: "D63AP")
        }
        let foreign = BackupRecord(id: record.id, date: record.date, reason: record.reason, source: .device,
                                   deviceID: "other", byteCount: record.byteCount, sha256: record.sha256)
        try await reject {
            try await store.restoreHardwareIdentity(from: foreign, expected: loaded,
                                                    physicalProduct: "iPhone14,2", physicalBoard: "D63AP")
        }
        let legacy = BackupRecord(id: record.id, date: record.date, reason: record.reason, source: .device,
                                  deviceID: record.deviceID, byteCount: record.byteCount)
        try await reject {
            try await store.restoreHardwareIdentity(from: legacy, expected: loaded,
                                                    physicalProduct: "iPhone14,2", physicalBoard: "D63AP")
        }
        let spoofedRecord = try await store.backups().first { $0.reason == "Before applying" }!
        // The original pre-write backup is valid; a current spoofed import is not.
        let spoofedImport = DocumentSnapshot(data: loaded.data, document: loaded.document, source: .local,
                                             name: "spoofed", ownershipVerified: true)
        try await reject {
            try await store.restoreHardwareIdentity(from: spoofedImport, expected: loaded,
                                                    physicalProduct: "iPhone14,2", physicalBoard: "D63AP")
        }
        try expect(try Data(contentsOf: device) == loaded.data, "All rejected repairs leave device bytes untouched")

        let repaired = try await store.restoreHardwareIdentity(from: spoofedRecord, expected: loaded,
                                                               physicalProduct: "iPhone14,2", physicalBoard: "d63ap")
        var expected = loaded.document
        for key in GestaltKeys.hardwareIdentity { expected.set(original.document.extra[key], for: key) }
        try expect(repaired.document.matches(expected), "Repair changes exactly the four hardware fields")
        try expect(try GestaltDocument(data: Data(contentsOf: device)).matches(expected), "Repair survives readback")
        let reopened = try await store.loadDevice()
        try expect(reopened.document.matches(expected), "Repair and original-value history survive reopening")
        let importedRepair = try await store.restoreHardwareIdentity(from: verifiedImport, expected: repaired,
                                                                     physicalProduct: "iPhone14,2", physicalBoard: "D63AP")
        try expect(importedRepair.data == repaired.data, "Verified import recovery is a no-op when already repaired")
        let recoveredBackup = try await store.backups().first!
        try expect(try await store.backupData(recoveredBackup) == loaded.data, "Repair backs up the complete pre-repair file")
        let externalDevice = directory.appendingPathComponent("externally-spoofed.plist")
        try loaded.data.write(to: externalDevice)
        let externalStore = GestaltFileStore(deviceURL: externalDevice,
                                             backupDirectory: directory.appendingPathComponent("external-backups"),
                                             deviceID: "external", acquire: { 0 }, release: { _ in })
        let external = try await externalStore.loadDevice()
        _ = try await externalStore.restoreHardwareIdentity(from: verifiedImport, expected: external,
                                                            physicalProduct: "iPhone14,2", physicalBoard: "D63AP")
        let externalReloaded = try await externalStore.loadDevice()
        for key in GestaltKeys.hardwareIdentity {
            try expect(GestaltDocument.valuesEqual(externalReloaded.originalValue(for: key)!,
                                                   original.document.extra[key]!),
                       "Future Revert must not reintroduce externally spoofed \(key)")
        }
        var changed = repaired.document
        changed.set("changed externally", for: "unrelated")
        try changed.encoded().write(to: device)
        try await reject {
            try await store.restoreHardwareIdentity(from: verifiedImport, expected: repaired,
                                                    physicalProduct: "iPhone14,2", physicalBoard: "D63AP")
        }

        var enabled = original.document
        ai.apply(.enable, to: &enabled, restoringFrom: original)
        siri.apply(.enable, to: &enabled, restoringFrom: original)
        for key in GestaltKeys.hardwareIdentity {
            try expect(GestaltDocument.valuesEqual(enabled.extra[key]!, original.document.extra[key]!),
                       "AI activation must not spoof \(key)")
        }
        try expect((enabled.extra[GestaltKeys.siriMode] as? NSNumber)?.intValue == 2, "AI mode writes SiriMode 2")
        siri.apply(.disable, to: &enabled, restoringFrom: original)
        try expect(enabled.extra[GestaltKeys.siriMode] == nil, "Reverting removes an originally absent SiriMode")
        print("PASS: hardware recovery preserves AI/region settings, rejects unsafe backups and verifies writes; AI mode never spoofs hardware.")
    }
}
