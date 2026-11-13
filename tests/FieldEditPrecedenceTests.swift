// SPDX-License-Identifier: GPL-3.0-only
// Run on macOS with: python3 tests/run_field_manager_regression.py --test tests/FieldEditPrecedenceTests.swift
import Foundation

@MainActor @main struct FieldEditPrecedenceTests {
    struct Failure: Error { let message: String }
    static let flag = "YlEtTtHlNesRBMal1CqRaA"
    static let layout = "ArtworkDeviceSubType"
    static func expect(_ condition: Bool, _ message: String) throws {
        if !condition { throw Failure(message: message) }
    }

    static func manager() throws -> FieldEditManagerHarness {
        let original = try GestaltDocument(data: PropertyListSerialization.data(fromPropertyList: [
            "CacheExtra": [flag: NSNumber(value: false),
                           GestaltKeys.artwork: [layout: NSNumber(value: 2436), "Vendor": Data([1, 2])],
                           "unrelated": "keep"]
        ], format: .binary, options: 0))
        var changed = original
        changed.set(NSNumber(value: true), for: flag)
        changed.setArtwork(NSNumber(value: 2736), for: layout)
        let before = DocumentSnapshot(data: try original.encoded(), document: original, source: .local, name: "fixture")
        let saved = DocumentSnapshot(data: try changed.encoded(), document: changed, source: .local, name: "fixture",
                                     originals: before.recordingChanges(to: changed))
        return FieldEditManagerHarness(snapshot: saved)
    }

    static func run(_ name: String) throws {
        let model = try manager()
        switch name {
        case "edit-flag":
            model.subtype = 2848
            try model.stage(FieldDraft(originalKey: flag, key: flag, kind: .integer, text: "0"))
            try expect(GestaltDocument.valuesEqual(model.preview!.extra[flag]!, NSNumber(value: 0)),
                       "Explicit flag values must not be overwritten by a pending layout")
        case "remove-flag":
            model.subtype = 2848
            model.removeField(flag)
            try expect(model.preview!.extra[flag] == nil, "A removed flag must not be recreated by a pending layout")
        case "rename-flag":
            model.subtype = 2848
            try model.stage(FieldDraft(originalKey: flag, key: "renamed", kind: .boolean, text: "false"))
            try expect(model.preview!.extra[flag] == nil && model.preview!.extra["renamed"] as? Bool == false,
                       "Renaming a flag must not recreate its old key")
        case "edit-artwork-disable", "edit-artwork-remove":
            model.choices["dynamicIsland"] = name == "edit-artwork-disable" ? .disable : .removeAdded
            let replacement: [String: Any] = [layout: NSNumber(value: 3000), "Vendor": Data([9, 8])]
            try model.stage(FieldDraft(originalKey: GestaltKeys.artwork, key: GestaltKeys.artwork,
                                       kind: .dictionary, text: PlistValueKind.dictionary.text(for: replacement)))
            try expect(GestaltDocument.valuesEqual(model.preview!.artwork, replacement),
                       "Explicit artwork must not be overwritten by a restore preset")
        case "remove-artwork":
            model.choices["dynamicIsland"] = .removeAdded
            model.removeField(GestaltKeys.artwork)
            try expect(model.preview!.extra[GestaltKeys.artwork] == nil && model.preview!.extra[flag] as? Bool == true,
                       "Removing artwork must clear a conflicting multi-field restore preset")
        case "unrelated-edit":
            model.subtype = 2848
            model.choices["dynamicIsland"] = .disable
            try model.stage(FieldDraft(originalKey: "unrelated", key: "unrelated", text: "edited"))
            try expect(model.subtype == 2848 && model.choices["dynamicIsland"] == .disable,
                       "Unrelated field edits must preserve layout presets")
        case "enable-and-artwork":
            model.choices["dynamicIsland"] = .enable
            let replacement: [String: Any] = [layout: NSNumber(value: 3000)]
            try model.stage(FieldDraft(originalKey: GestaltKeys.artwork, key: GestaltKeys.artwork,
                                       kind: .dictionary, text: PlistValueKind.dictionary.text(for: replacement)))
            try expect(model.choices["dynamicIsland"] == .enable && GestaltDocument.valuesEqual(model.preview!.artwork, replacement),
                       "A flag-only enable preset may coexist with an artwork edit")
        case "ordinary-flag-edit":
            try model.stage(FieldDraft(originalKey: flag, key: flag, kind: .boolean, text: "false"))
            try expect(model.preview!.extra[flag] as? Bool == false, "Ordinary flag edits still work")
        case "other-presets":
            model.subtype = 2848
            model.changesName = true
            model.modelName = "Custom name"
            model.modelID = "A3472"
            model.choices["aod"] = .enable
            model.removeField(flag)
            try expect(model.changesName && model.modelID == "A3472" && model.choices["aod"] == .enable,
                       "Clearing a conflicting layout preserves independent presets")
        default: throw Failure(message: "Unknown case: " + name)
        }
        print("PASS " + name)
    }

    static func main() throws {
        let cases = ["edit-flag", "remove-flag", "rename-flag", "edit-artwork-disable", "edit-artwork-remove",
                     "remove-artwork", "unrelated-edit", "enable-and-artwork", "ordinary-flag-edit", "other-presets"]
        let selected = CommandLine.arguments.dropFirst().first ?? "all"
        for name in selected == "all" ? cases : [selected] { try run(name) }
    }
}
