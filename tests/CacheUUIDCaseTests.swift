import Foundation

@main struct CacheUUIDCaseTests {
    struct Failure: Error { let message: String }
    static func expect(_ condition: Bool, _ message: String) throws {
        if !condition { throw Failure(message: message) }
    }

    static func document(uuid: String, setting: String = "original") throws -> GestaltDocument {
        let layout = MobileGestaltCacheLayout.originalProfile
        var cache = Data(repeating: 0, count: layout.byteCount)
        cache[layout.greenTeaOffset] = 1
        for index in [layout.greenTeaIndex, layout.notGreenTeaIndex, layout.wapiIndex!] {
            cache[layout.validityOffset(for: index)] = 1
        }
        cache[layout.wapiOffset!] = 1
        let root: [String: Any] = [
            "CacheUUID": uuid, "CacheVersion": "same-version", "CacheData": cache,
            "CacheExtra": ["VasUgeSzVyHdB27g2XpN0g": "same-device", "setting": setting]
        ]
        return try GestaltDocument(data: PropertyListSerialization.data(fromPropertyList: root, format: .binary, options: 0))
    }

    static func originalFlags() throws {
        let uuid = MobileGestaltCacheLayout.originalProfile.uuid
        let original = try document(uuid: uuid)
        let flags = try CachedOptionsOriginal(document: original)
        let wapi = try WAPIOriginal(document: original)
        for spelling in [uuid.lowercased(), String(uuid.prefix(8)).lowercased() + String(uuid.dropFirst(8))] {
            var edited = try document(uuid: spelling)
            try edited.setCacheOptions(.enabled)
            try edited.setWAPI(false)
            try expect(MobileGestaltCacheLayout.originalProfile.matches(edited), "The resolver must accept the equivalent UUID spelling")
            do {
                try expect(try flags.flags(in: edited) == .restricted, "The original cache flags must remain available")
                try expect(try wapi.value(in: edited), "The original WAPI value must remain available")
            } catch is GestaltFailure {
                throw Failure(message: "Equivalent UUID case must preserve access to recorded cache originals")
            }
        }
    }

    static func fixture() throws -> (URL, URL, GestaltFileStore) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let device = root.appendingPathComponent("device.plist")
        try document(uuid: MobileGestaltCacheLayout.originalProfile.uuid).encoded().write(to: device)
        let store = GestaltFileStore(deviceURL: device, backupDirectory: root.appendingPathComponent("backups"),
                                    deviceID: "uuid-case-fixture", acquire: { 1 }, release: { _ in })
        return (root, device, store)
    }

    static func compatibleRestore() async throws {
        let (root, device, store) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let initial = try await store.loadDevice()
        let record = try await store.backups().first!
        let restored = try document(uuid: MobileGestaltCacheLayout.originalProfile.uuid.lowercased(), setting: "restored")
        do {
            let result = try await store.commit(restored, expected: initial, restoring: record)
            try expect(result.document.matches(restored), "The matching layout restore must retain all requested values")
        } catch is GestaltFailure {
            throw Failure(message: "Equivalent UUID case must allow a compatible backup restore")
        }
        try expect(try GestaltDocument(data: Data(contentsOf: device)).matches(restored), "Readback must match the restored document")
    }

    static func recoverHistory() async throws {
        let (root, device, store) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let initial = try await store.loadDevice()
        var edited = initial.document
        edited.set("edited", for: "setting")
        try edited.setCacheOptions(.enabled)
        _ = try await store.commit(edited, expected: initial)
        try FileManager.default.removeItem(at: root.appendingPathComponent("backups/OriginalValues.plist"))
        var liveRoot = edited.root
        liveRoot["CacheUUID"] = MobileGestaltCacheLayout.originalProfile.uuid.lowercased()
        try PropertyListSerialization.data(fromPropertyList: liveRoot, format: .binary, options: 0).write(to: device)

        let recovered = try await store.loadDevice()

        try expect(recovered.originals["setting"]?.value as? String == "original",
                   "Equivalent UUID case must not discard the matching backup history")
        try expect(try recovered.originalCachedOptionFlags() == .restricted, "Recovered flags must retain the original values")
    }

    static func main() async throws {
        let selected = CommandLine.arguments.dropFirst().first ?? "all"
        if selected == "flags" || selected == "all" { try originalFlags() }
        if selected == "restore" || selected == "all" { try await compatibleRestore() }
        if selected == "history" || selected == "all" { try await recoverHistory() }
        print("PASS: cache UUID case, recorded originals, compatible restore, and backup history")
    }
}
