// SPDX-License-Identifier: GPL-3.0-only
// Run on macOS with: python3 tests/run_field_manager_regression.py --test tests/FieldKeyIdentityTests.swift
import Foundation

@MainActor @main struct FieldKeyIdentityTests {
    struct Failure: Error { let message: String }
    static func expect(_ condition: Bool, _ message: String) throws {
        if !condition { throw Failure(message: message) }
    }
    static func manager(_ values: [String: Any]) throws -> FieldEditManagerHarness {
        let document = try GestaltDocument(data: PropertyListSerialization.data(fromPropertyList: ["CacheExtra": values], format: .binary, options: 0))
        return FieldEditManagerHarness(snapshot: DocumentSnapshot(data: try document.encoded(), document: document,
                                                                  source: .local, name: "fixture"))
    }
    static func run(_ name: String) throws {
        switch name {
        case "spaces", "unicode-space", "only-space", "empty":
            let key = ["spaces": " vendor ", "unicode-space": "\u{00a0}vendor\n", "only-space": " \t", "empty": ""][name]!
            let model = try manager([key: "original", "unrelated": Data([1, 2, 3])])
            do { try model.stage(FieldDraft(originalKey: key, key: key, text: "edited")) }
            catch { throw Failure(message: "Existing plist keys must remain editable without normalization") }
            try expect(model.working!.extra[key] as? String == "edited" && Set(model.working!.extra.keys) == Set([key, "unrelated"]),
                       "Existing plist keys must retain their exact identity when values change")
            let roundTrip = try GestaltDocument(data: model.working!.encoded())
            try expect(roundTrip.extra[key] as? String == "edited", "The original key survives binary serialization")
        case "collision":
            let model = try manager([" vendor ": "spaced", "vendor": "plain"])
            let before = model.working!
            do { try model.stage(FieldDraft(originalKey: " vendor ", key: " vendor ", text: "spaced")) }
            catch { throw Failure(message: "An unchanged key must not collide with its trimmed neighbor") }
            try expect(model.working!.matches(before), "A no-op edit preserves both distinct keys")
        case "new-key":
            let model = try manager(["old": "keep"])
            try model.stage(FieldDraft(key: " new ", text: "value"))
            try expect(model.working!.extra["new"] as? String == "value" && model.working!.extra[" new "] == nil,
                       "New keys keep their existing trimming behavior")
        case "rename":
            let model = try manager([" old ": "value"])
            try model.stage(FieldDraft(originalKey: " old ", key: " renamed ", text: "value"))
            try expect(model.working!.extra["renamed"] as? String == "value" && model.working!.extra[" old "] == nil,
                       "Intentional renames still trim their destination")
        case "invalid-new":
            let model = try manager(["old": "keep"])
            for key in ["", " \t\n"] {
                do { try model.stage(FieldDraft(key: key, text: "value")); throw Failure(message: "Blank new keys must be rejected") }
                catch is GestaltFailure { }
            }
        case "rename-collision":
            let model = try manager([" old ": "value", "existing": "keep"])
            do { try model.stage(FieldDraft(originalKey: " old ", key: " existing ", text: "value")); throw Failure(message: "Renames must reject occupied destinations") }
            catch is GestaltFailure { }
        default: throw Failure(message: "Unknown case: " + name)
        }
        print("PASS " + name)
    }
    static func main() throws {
        let cases = ["spaces", "unicode-space", "only-space", "empty", "collision", "new-key", "rename", "invalid-new", "rename-collision"]
        let selected = CommandLine.arguments.dropFirst().first ?? "all"
        for name in selected == "all" ? cases : [selected] { try run(name) }
    }
}
