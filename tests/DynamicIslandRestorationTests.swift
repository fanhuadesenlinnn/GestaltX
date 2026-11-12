import Foundation

@main struct DynamicIslandRestorationTests {
    struct Failure: Error { let message: String }
    static func expect(_ condition: Bool, _ message: String) throws {
        if !condition { throw Failure(message: message) }
    }
    static func document(_ extra: [String: Any]) throws -> GestaltDocument {
        try GestaltDocument(data: PropertyListSerialization.data(fromPropertyList: ["CacheExtra": extra], format: .binary, options: 0))
    }
    static func snapshot(_ original: GestaltDocument, edited: GestaltDocument) throws -> DocumentSnapshot {
        let before = DocumentSnapshot(data: try original.encoded(), document: original, source: .local, name: "fixture")
        return DocumentSnapshot(data: try edited.encoded(), document: edited, source: .local, name: "fixture",
                                originals: before.recordingChanges(to: edited))
    }
    static func main() throws {
        let capability = Capability.all.first { $0.id == "dynamicIsland" }!
        let flag = capability.keys[0]
        let subtype = "ArtworkDeviceSubType"
        let name = "ArtworkDeviceProductDescription"
        let originalFlags: [Any?] = [nil, NSNumber(value: false), NSNumber(value: 1)]
        let originalArtworks: [Any?] = [nil, [String: Any](), [subtype: NSNumber(value: 2436), name: "Factory", "unknown": Data([1, 2, 3])]]
        for originalFlag in originalFlags {
            for originalArtwork in originalArtworks {
                var extra: [String: Any] = ["unrelated": "keep"]
                extra[flag] = originalFlag
                extra[GestaltKeys.artwork] = originalArtwork
                let original = try document(extra)
                var changed = original
                changed.set(NSNumber(value: true), for: flag)
                changed.setArtwork(NSNumber(value: 2736), for: subtype)
                let saved = try snapshot(original, edited: changed)
                for choice in [PresetChoice.disable, .removeAdded] {
                    var restored = changed
                    capability.apply(choice, to: &restored, restoringFrom: saved)
                    var expected = original
                    if choice == .removeAdded { expected.set(nil, for: flag) }
                    try expect(restored.matches(expected), "Restoring the layout must restore its original presence, type and flag")
                }
            }
        }

        let original = try document([flag: NSNumber(value: false), GestaltKeys.artwork: [subtype: NSNumber(value: 2436), name: "Factory"]])
        var changed = original
        changed.set(NSNumber(value: true), for: flag)
        changed.setArtwork(NSNumber(value: 2556), for: subtype)
        changed.setArtwork("Saved custom name", for: name)
        changed.setArtwork(Data([9]), for: "new-vendor-key")
        let saved = try snapshot(original, edited: changed)
        var restored = changed
        capability.apply(.disable, to: &restored, restoringFrom: saved)
        try expect(restored.artwork[name] as? String == "Saved custom name", "Restoring the layout preserves a saved custom model name")
        try expect(restored.artwork["new-vendor-key"] as? Data == Data([9]), "Unknown artwork members survive")
        try expect(GestaltDocument.valuesEqual(restored.artwork[subtype]!, original.artwork[subtype]!), "Restore the exact original subtype")

        var pending = changed
        pending.setArtwork("Pending custom name", for: name)
        pending.setArtwork(Data([8]), for: "pending-vendor-key")
        var rebased = saved.rebasingPendingEdits(pending, onto: restored, excluding: Set(capability.keys))
        capability.apply(.disable, to: &rebased, restoringFrom: saved)
        try expect(rebased.artwork[name] as? String == "Pending custom name", "Pending model-name edits survive an immediate Revert")
        try expect(rebased.artwork["pending-vendor-key"] as? Data == Data([8]), "Pending unknown members survive an immediate Revert")
        try expect(GestaltDocument.valuesEqual(rebased.artwork[subtype]!, original.artwork[subtype]!), "Rebasing must not reintroduce the changed layout")

        var malformed = changed
        malformed.set("user-entered artwork", for: GestaltKeys.artwork)
        capability.apply(.disable, to: &malformed, restoringFrom: saved)
        try expect(malformed.extra[GestaltKeys.artwork] as? String == "user-entered artwork", "Do not replace a separately edited malformed artwork value")
        print("PASS: layout and flag restoration, exact presence/types, and independent saved/pending artwork edits.")
    }
}
