import Foundation

@main struct SystemSettingsTests {
    struct Failure: Error { let message: String }
    static func expect(_ condition: Bool, _ message: String) throws {
        if !condition { throw Failure(message: message) }
    }
    static func write(_ dictionary: [String: Any], to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try PropertyListSerialization.data(fromPropertyList: dictionary, format: .binary, options: 0).write(to: url)
    }
    static func read(_ url: URL) throws -> [String: Any] {
        try PropertyListSerialization.propertyList(from: Data(contentsOf: url), options: [], format: nil) as! [String: Any]
    }
    static func main() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try expect(SystemSetting.allCases == [.lockScreenText] && SystemSettingsFile.allCases == [.footnote], "Only lock-screen text is exposed and accessed")
        let values: [Any?] = [nil, "Factory", "", "原始文字 👋", NSNumber(value: 2)]
        for (index, value) in values.enumerated() {
            let system = root.appendingPathComponent("case-\(index)/system")
            let history = root.appendingPathComponent("case-\(index)/history")
            let file = system.appendingPathComponent(SystemSettingsFile.footnote.relativePath)
            var original: [String: Any] = ["unrelated": ["bytes": Data([1, 9]), "enabled": true]]
            original["LockScreenFootnote"] = value
            try write(original, to: file)
            let store = SystemSettingsStore(systemRoot: system, storage: history, deviceID: "fixture", acquire: { _ in 0 }, release: { _ in })
            let before = try await store.load()
            let applied = try await store.apply([.lockScreenText: .text("My text 你好 👋")], expected: before)
            try expect(try read(file)["LockScreenFootnote"] as? String == "My text 你好 👋", "Text is written")
            let unchanged = try read(file)["unrelated"]!
            try expect(GestaltDocument.valuesEqual(unchanged, original["unrelated"]!), "Unrelated profile configuration survives")
            let backups = try FileManager.default.contentsOfDirectory(at: history.appendingPathComponent("Backups"), includingPropertiesForKeys: nil)
            try expect(backups.count == 1, "Pre-write backup exists")
            _ = try await store.apply([.lockScreenText: .text("My text 你好 👋")], expected: applied)
            try expect(try FileManager.default.contentsOfDirectory(atPath: history.appendingPathComponent("Backups").path).count == 1, "No-op writes do not create more backups")
            let reopened = SystemSettingsStore(systemRoot: system, storage: history, deviceID: "fixture", acquire: { _ in 0 }, release: { _ in })
            let current = try await reopened.load()
            let restored = try await reopened.apply([.lockScreenText: .restore], expected: current)
            try expect(restored.values == before.values && GestaltDocument.valuesEqual(try read(file), original), "Reopening restores exact original type, value or absence")
            let foreign = SystemSettingsStore(systemRoot: system, storage: history, deviceID: "another-device", acquire: { _ in 0 }, release: { _ in })
            do { _ = try await foreign.load(); throw Failure(message: "Foreign originals accepted") } catch is GestaltFailure {}
        }
        let system = root.appendingPathComponent("missing/system")
        let history = root.appendingPathComponent("missing/history")
        let file = system.appendingPathComponent(SystemSettingsFile.footnote.relativePath)
        let store = SystemSettingsStore(systemRoot: system, storage: history, deviceID: "fixture", acquire: { _ in 0 }, release: { _ in })
        let missing = try await store.load()
        for text in [String(repeating: "x", count: 257), "line\nbreak"] {
            do { _ = try await store.apply([.lockScreenText: .text(text)], expected: missing); throw Failure(message: "Invalid text accepted") } catch is GestaltFailure {}
        }
        let added = try await store.apply([.lockScreenText: .text("Added")], expected: missing)
        _ = try await store.apply([.lockScreenText: .restore], expected: added)
        try expect(!FileManager.default.fileExists(atPath: file.path), "An originally absent file is removed when empty after revert")
        let stale = try await store.load()
        try write(["LockScreenFootnote": "Changed elsewhere"], to: file)
        do { _ = try await store.apply([.lockScreenText: .text("Overwrite")], expected: stale); throw Failure(message: "Stale value accepted") } catch is GestaltFailure {}
        let fresh = try await store.load()
        try write(["LockScreenFootnote": "Changed elsewhere", "new-field": 42], to: file)
        _ = try await store.apply([.lockScreenText: .text("Updated")], expected: fresh)
        try expect(try read(file)["new-field"] as? Int == 42, "Concurrent unrelated changes survive")
        let linkSystem = root.appendingPathComponent("link/system")
        let link = linkSystem.appendingPathComponent(SystemSettingsFile.footnote.relativePath)
        let target = root.appendingPathComponent("untouched.plist")
        try write(["keep": true], to: target)
        try FileManager.default.createDirectory(at: link.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        let linked = SystemSettingsStore(systemRoot: linkSystem, storage: root.appendingPathComponent("link/history"), deviceID: "fixture", acquire: { _ in 0 }, release: { _ in })
        let refused = try await linked.load()
        try expect(refused.errors[.footnote] != nil && refused.values.isEmpty, "Symlinks are refused")
        let failSystem = root.appendingPathComponent("failure/system")
        let failedFile = failSystem.appendingPathComponent(SystemSettingsFile.footnote.relativePath)
        let failure = SystemSettingsStore(systemRoot: failSystem, storage: root.appendingPathComponent("failure/history"), deviceID: "fixture", acquire: { _ in 0 }, release: { _ in }, writeOverride: { url, data in
            if let data {
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try data.write(to: url, options: .atomic)
                throw Failure(message: "Injected failure after write")
            } else if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
        })
        let baseline = try await failure.load()
        do { _ = try await failure.apply([.lockScreenText: .text("Fail")], expected: baseline); throw Failure(message: "Failure missing") }
        catch let error as Failure { try expect(error.message == "Injected failure after write", "Write error is preserved") }
        try expect(!FileManager.default.fileExists(atPath: failedFile.path), "Failed writes roll back")
        print("PASS: lock-screen text only, exact originals, absent files, verified backups, stale writes, input validation, symlinks, device binding and rollback.")
    }
}
