import Foundation

@main struct SiriCapabilityTests {
    struct Failure: Error { let message: String }
    static func expect(_ condition: Bool, _ message: String) throws {
        if !condition { throw Failure(message: message) }
    }

    static func fixture(_ value: Any?) throws -> GestaltDocument {
        var extra: [String: Any] = [
            GestaltKeys.regionCode: "LL",
            "A62OafQ85EJAiiqKn4agtg": NSNumber(value: 1),
        ]
        extra["K/R1GfGfCkXvEhaPS2Vrng"] = value
        let layout = MobileGestaltCacheLayout.originalProfile
        var cache = Data(count: layout.byteCount)
        cache[layout.validityOffset(for: layout.greenTeaIndex)] = 1
        cache[layout.validityOffset(for: layout.notGreenTeaIndex)] = 1
        let root: [String: Any] = [
            "CacheExtra": extra, "CacheData": cache, "CacheUUID": layout.uuid, "CacheVersion": "fixture",
        ]
        return try GestaltDocument(data: PropertyListSerialization.data(fromPropertyList: root, format: .binary, options: 0))
    }

    static func main() async throws {
        let siri = Capability.all.first { $0.id == "siriOnDevice" }!
        let key = siri.keys.first!
        try expect(siri.availableChoices == [.keep, .disable, .removeAdded],
                   "Siri exposes current-value and recovery choices")
        for capability in Capability.all where capability.id != siri.id {
            try expect(capability.availableChoices == PresetChoice.allCases,
                       "\(capability.id): all existing preset choices remain available")
        }
        let values: [(String, Any?)] = [
            ("absent", nil), ("false", NSNumber(value: false)), ("true", NSNumber(value: true)),
            ("zero", NSNumber(value: 0)), ("one", NSNumber(value: 1)), ("two", NSNumber(value: 2)),
            ("three", NSNumber(value: 3)), ("four", NSNumber(value: 4)), ("future value", NSNumber(value: 5)),
        ]
        for (label, value) in values {
            let original = try fixture(value)
            let data = try original.encoded()
            let snapshot = DocumentSnapshot(data: data, document: original, source: .local, name: label)
            var document = original
            siri.apply(.keep, to: &document, restoringFrom: snapshot)
            try expect(document.matches(original), "\(label): Keep Current preserves the complete document")
            siri.apply(.enable, to: &document, restoringFrom: snapshot)
            try expect(document.matches(original), "\(label): a forced enable preserves the system capability value")
            let roundtrip = try GestaltDocument(data: document.encoded())
            try expect(roundtrip.matches(original), "\(label): encoding preserves the capability value and type")
            siri.apply(.removeAdded, to: &document, restoringFrom: snapshot)
            try expect(document.extra[key] == nil, "\(label): explicit field removal remains available")
        }

        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        for (label, value) in values {
            let original = try fixture(value)
            let device = directory.appendingPathComponent(label + ".plist")
            let backups = directory.appendingPathComponent(label + "-backups")
            try original.encoded().write(to: device)
            let store = GestaltFileStore(deviceURL: device, backupDirectory: backups, deviceID: label,
                                         acquire: { 0 }, release: { _ in })
            let baseline = try await store.loadDevice()
            var previouslyModified = baseline.document
            // Reproduce a value written by v1.0.4/v1.0.5, including its original-value journal.
            previouslyModified.set(NSNumber(value: 1), for: key)
            _ = try await store.commit(previouslyModified, expected: baseline)

            let reloadedStore = GestaltFileStore(deviceURL: device, backupDirectory: backups, deviceID: label,
                                                 acquire: { 0 }, release: { _ in })
            let loaded = try await reloadedStore.loadDevice()
            var restored = loaded.document
            siri.apply(.disable, to: &restored, restoringFrom: loaded)
            try expect(restored.matches(original), "\(label): Restore Original recovers the recorded value and type")
            let result = try await reloadedStore.commit(restored, expected: loaded)
            try expect(result.document.matches(original), "\(label): the restored value survives the normal commit path")
            let readback = try GestaltDocument(data: Data(contentsOf: device))
            try expect(readback.matches(original), "\(label): readback preserves region, AI flags and cache data")
        }
        print("PASS: Siri capability values are preserved and legacy originals survive journal reload and restoration.")
    }
}
