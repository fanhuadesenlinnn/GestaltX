import Foundation

@main struct CapabilityCatalogTests {
    struct Failure: Error { let message: String }
    static func expect(_ condition: Bool, _ message: String) throws {
        if !condition { throw Failure(message: message) }
    }

    static func main() throws {
        let ids = Capability.all.map(\.id)
        try expect(Set(ids).count == ids.count, "Capability ids are unique")
        for capability in Capability.all {
            try expect(!capability.keys.isEmpty, "\(capability.id) has at least one key")
            for key in capability.keys {
                try expect(key.count == 22 || key == "UIParallaxCapability",
                           "\(capability.id) uses a MobileGestalt key: \(key)")
                if let values = capability.values {
                    try expect(values[key] != nil, "\(capability.id) has a value for \(key)")
                }
            }
        }

        let original: [String: Any] = [
            "CacheExtra": [
                "YlEtTtHlNesRBMal1CqRaA": NSNumber(value: 0),
                "UIParallaxCapability": NSNumber(value: 1),
                "qqrspu7CpuPdZwSDxNY+Fg": NSNumber(value: 1),
            ],
            "CacheData": Data([0, 1, 2]),
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: original, format: .binary, options: 0)
        let document = try GestaltDocument(data: data)
        let snapshot = DocumentSnapshot(data: data, document: document, source: .local, name: "fixture")

        for capability in Capability.all where capability.availableChoices.contains(.enable) {
            var enabled = document
            capability.apply(.enable, to: &enabled, restoringFrom: snapshot)
            for key in capability.keys {
                let expected = capability.values?[key] ?? capability.enabled
                let actual: Any = enabled.extra[key] ?? NSNull()
                try expect(GestaltDocument.valuesEqual(actual, expected),
                           "\(capability.id) enables \(key) with the catalog value")
            }

            capability.apply(.disable, to: &enabled, restoringFrom: snapshot)
            try expect(enabled.matches(document), "\(capability.id) restores the original document")

            capability.apply(.removeAdded, to: &enabled, restoringFrom: snapshot)
            for key in capability.keys {
                try expect(enabled.extra[key] == nil, "\(capability.id) removes \(key)")
            }
        }
        print("PASS: unique capabilities, key/value coverage, enable values, original restoration and removal.")
    }
}
