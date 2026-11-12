import Foundation

extension DocumentTests {
    static func verifyWAPI(in root: URL) async throws {
        let layout = MobileGestaltCacheLayout.originalProfile
        let offset = layout.wapiOffset!
        func fixture(_ enabled: Bool) throws -> GestaltDocument {
            var cache = Data(repeating: 0, count: layout.byteCount)
            cache[layout.greenTeaOffset] = 1
            for index in [layout.greenTeaIndex, layout.notGreenTeaIndex, layout.wapiIndex!] {
                cache[layout.validityOffset(for: index)] = 1
            }
            cache[offset] = enabled ? 1 : 0
            cache[27] = 92
            return try GestaltDocument(data: PropertyListSerialization.data(fromPropertyList: [
                "CacheUUID": layout.uuid, "CacheVersion": "fixture",
                "CacheData": cache, "OtherRoot": ["keep": true],
                "CacheExtra": [GestaltKeys.productType: "fixture", GestaltKeys.regionCode: "CH",
                               "VasUgeSzVyHdB27g2XpN0g": "wapi-test-device"]
            ], format: .binary, options: 0))
        }
        func replacingCache(_ doc: GestaltDocument, _ cache: Data) throws -> GestaltDocument {
            var root = doc.root; root["CacheData"] = cache
            return try GestaltDocument(data: PropertyListSerialization.data(fromPropertyList: root, format: .binary, options: 0))
        }
        let original = try fixture(true)
        var disabled = original
        try disabled.setWAPI(false)
        try DeviceCacheOptions.validateEdit(from: original, to: disabled)
        let before = original.root["CacheData"] as! Data, after = disabled.root["CacheData"] as! Data
        try expect(before.indices.filter { before[$0] != after[$0] } == [offset], "WAPI changes only its own cached Boolean")
        try expect(disabled.extra as NSDictionary == original.extra as NSDictionary, "WAPI preserves region and other CacheExtra values")
        try expect(DeviceCacheOptions.changes(from: original, to: disabled).map(\.name) == ["wapi"], "WAPI appears in the review/count")
        var combined = disabled
        try combined.setCacheOptions(.enabled)
        try DeviceCacheOptions.validateEdit(from: original, to: combined)
        try expect(!DeviceCacheOptions.wapi(in: combined), "Green-tea and WAPI edits coexist")
        try combined.setCacheOptions(.restricted)
        try expect(combined.matches(disabled), "Restoring green-tea preserves staged WAPI")
        for bad in [offset, offset + 1, layout.validityOffset(for: layout.wapiIndex!)] {
            var invalid = original
            var bytes = before
            bytes[bad] = bad == offset ? 2 : (bad == offset + 1 ? 1 : 0)
            invalid = try replacingCache(invalid, bytes)
            try expectThrows("Reject invalid WAPI byte, padding or validity") { try invalid.setWAPI(false) }
            try invalid.setCacheOptions(.enabled)
            try DeviceCacheOptions.validateEdit(from: replacingCache(original, bytes), to: invalid)
        }
        for key in [DeviceCacheOptions.wapiKey, "wapi"] {
            var invalid = original; invalid.set(true, for: key)
            try expectThrows("Reject conflicting WAPI override") { try invalid.setWAPI(false) }
        }
        var unrelated = disabled; var bytes = after; bytes[27] = 0; unrelated = try replacingCache(unrelated, bytes)
        try expectThrows("Reject unrelated bytes alongside WAPI") { try DeviceCacheOptions.validateEdit(from: original, to: unrelated) }
        var invalidGreen = original; bytes = before; bytes[layout.greenTeaOffset + 1] = 1; invalidGreen = try replacingCache(invalidGreen, bytes)
        var onlyWAPI = invalidGreen; try onlyWAPI.setWAPI(false)
        try DeviceCacheOptions.validateEdit(from: invalidGreen, to: onlyWAPI)
        try expect(DeviceCacheOptions.changes(from: invalidGreen, to: onlyWAPI).map(\.name) == ["wapi"], "WAPI works independently of green-tea validity")

        // Preserve the first value across repeated edits, app reopen, deleted
        // visible backups, and migration from a journal without a WAPI entry.
        for initialValue in [false, true] {
            for recoverJournal in [false, true] {
                let tag = "wapi-\(initialValue)-\(recoverJournal)"
                let url = root.appendingPathComponent(tag + ".plist")
                let backups = root.appendingPathComponent(tag, isDirectory: true)
                let baseline = try fixture(initialValue)
                try baseline.encoded().write(to: url)
                let store = GestaltFileStore(deviceURL: url, backupDirectory: backups, deviceID: tag, acquire: { 1 }, release: { _ in })
                let first = try await store.loadDevice()
                var changed = first.document; try changed.setWAPI(!initialValue)
                _ = try await store.commit(changed, expected: first)
                let journal = backups.appendingPathComponent("OriginalValues.plist")
                if recoverJournal {
                    var saved = try PropertyListSerialization.propertyList(from: Data(contentsOf: journal), format: nil) as! [String: Any]
                    saved.removeValue(forKey: "wapi")
                    saved.removeValue(forKey: "cacheHistoryRecovered")
                    try PropertyListSerialization.data(fromPropertyList: saved, format: .binary, options: 0).write(to: journal)
                } else {
                    for record in try await store.backups() { try await store.deleteBackup(record) }
                }
                let reopened = GestaltFileStore(deviceURL: url, backupDirectory: backups, deviceID: tag, acquire: { 1 }, release: { _ in })
                let loaded = try await reopened.loadDevice()
                try expect(loaded.originalWAPI() == initialValue, "Exact original WAPI survives journal recovery/reopen")
                var restored = loaded.document; try restored.setWAPI(loaded.originalWAPI())
                try expect(restored.matches(baseline), "Restoring WAPI preserves all other values")
                _ = try await reopened.commit(restored, expected: loaded)
            }
        }
        if let path = ProcessInfo.processInfo.environment["GX_TEST_WAPI_IMAGE"] {
            let image = try PropertyListSerialization.propertyList(from: Data(contentsOf: URL(fileURLWithPath: path)), format: nil) as! [String: Any]
            let actual = try MobileGestaltCacheLayout.scan(image: image)
            try expect(actual.wapiIndex == 694 && actual.slotCount == 720, "Resolve WAPI and cache size from the actual device library")
        }
        if let path = ProcessInfo.processInfo.environment["GX_TEST_WAPI_EXPORT"] {
            let url = URL(fileURLWithPath: path), bytes = try Data(contentsOf: url)
            var doc = try GestaltDocument(data: bytes); let value = try DeviceCacheOptions.wapi(in: doc)
            let original = doc
            try doc.setWAPI(!value); try DeviceCacheOptions.validateEdit(from: original, to: doc)
            try doc.setWAPI(value)
            try expect(doc.matches(original) && Data(contentsOf: url) == bytes, "Real device export round-trips without changing the source file")
        }
        print("PASS: WAPI isolation, combined edits, validation, durable original values, journal migration and real-export round trip.")
    }
}
