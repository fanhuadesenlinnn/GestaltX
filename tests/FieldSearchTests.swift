import Foundation

// SearchModel.preview and SearchFields.keys/valueText are extracted unchanged
// from production sources by run_field_search.py. The model's document and
// preset operations use the real Foundation implementation.
@main @MainActor struct FieldSearchTests {
    struct Failure: Error { let message: String }

    static func expect(_ condition: Bool, _ message: String) throws {
        if !condition { throw Failure(message: message) }
    }

    static func model(_ extra: [String: Any]) throws -> SearchModel {
        let data = try PropertyListSerialization.data(fromPropertyList: ["CacheExtra": extra], format: .binary, options: 0)
        let document = try GestaltDocument(data: data)
        let result = SearchModel()
        result.working = document
        result.snapshot = DocumentSnapshot(data: data, document: document, source: .local, name: "search.plist")
        return result
    }

    static func check(_ name: String, _ model: SearchModel, _ query: String, _ expected: [String]) throws {
        let fields = SearchFields(model: model, search: query)
        try expect(fields.matchingKeys() == expected.sorted(), name)
        print("PASS \(name)")
    }

    static func correctness() throws {
        try check("no document", SearchModel(), "", [])
        try check("empty document", model([:]), "missing", [])
        let extra: [String: Any] = [
            "alpha": "Hello Universe",
            "NEEDLE-key": "other",
            "日本語": "Unicode value",
            "boolean": NSNumber(value: true),
            "integer": NSNumber(value: Int64.min),
            "real": NSNumber(value: 3.125),
            "blob": Data([0, 127, 255]),
            "array": ["array-needle", Data([1, 2])],
            "dictionary": ["nested": "dict-needle"],
            "date": Date(timeIntervalSince1970: 0.125),
            GestaltKeys.artwork: ["ArtworkDeviceProductDescription": "Original Model", "preserved": "original"],
            "Z/dqyWS6OZTRy10UcmUAhw": "Original Model",
            "bbtR9jQx50Fv5Af/affNtA": "Original Model",
        ]
        let current = try model(extra)
        let original = current.working!
        try check("empty search remains sorted", current, "", Array(extra.keys))
        try check("case insensitive key", current, "needle-KEY", ["NEEDLE-key"])
        try check("Unicode key", current, "日本", ["日本語"])
        try check("case insensitive string value", current, "hELLo", ["alpha"])
        try check("Boolean display value", current, "true", ["boolean"])
        try check("full integer display value", current, "9223372036854775808", ["integer"])
        try check("real display value", current, "3.125", ["real"])
        try check("Data byte count display value", current, "3 bytes", ["blob"])
        try check("array XML display value", current, "array-needle", ["array"])
        try check("dictionary XML display value", current, "dict-needle", ["dictionary"])
        try check("date display value", current, "1970-01-01T00:00:00.125Z", ["date"])
        try check("absent value", current, "no-such-value-zz", [])

        current.changesName = true
        current.modelName = "  Staged Model  "
        let nameKeys = [GestaltKeys.artwork, "Z/dqyWS6OZTRy10UcmUAhw", "bbtR9jQx50Fv5Af/affNtA"]
        try check("search includes staged preset values", current, "Staged Model", nameKeys)
        var fields = SearchFields(model: current, search: "Staged Model")
        current.modelName = "Second Model"
        try expect(fields.matchingKeys().isEmpty, "An existing view must not retain an older preview")
        fields.search = "Second Model"
        try expect(fields.matchingKeys() == nameKeys.sorted(), "Changing the search must read current staged values")
        try expect(fields.displayText("Z/dqyWS6OZTRy10UcmUAhw") == "Second Model", "Rows must read current staged values")
        current.changesName = false
        try expect(fields.matchingKeys().isEmpty, "Clearing a preset must invalidate previous results")
        try expect(fields.displayText("Z/dqyWS6OZTRy10UcmUAhw") == "Original Model", "Rows must reflect cleared presets")
        print("PASS edits and cleared presets update existing views and row text")
        try expect(current.working!.matches(original) && current.snapshot!.document.matches(original),
                   "Searching must not mutate the working document or original snapshot")
        print("PASS search preserves working and original documents")

        var edited = current.working!
        edited.set("replacement-value", for: "alpha")
        current.working = edited
        fields.search = "replacement-value"
        try expect(fields.matchingKeys() == ["alpha"], "Working document edits must be visible without recreating the view")
        edited.set(nil, for: "alpha")
        current.working = edited
        try expect(fields.matchingKeys().isEmpty && fields.displayText("alpha").isEmpty,
                   "Removed fields must not remain in search results or row text")
        current.working = nil
        fields.search = ""
        try expect(fields.matchingKeys().isEmpty, "Closing the document must clear previous results")
        print("PASS edits, deletion and closing update existing views")
    }

    static func benchmark(_ count: Int, _ mode: String, _ query: String) throws {
        var extra: [String: Any] = [:]
        for index in 0..<count { extra[String(format: "field-%04d", index)] = String(format: "value-%04d", index) }
        let current = try model(extra)
        if mode == "staged" { current.changesName = true; current.modelName = "Staged Model" }
        let fields = SearchFields(model: current, search: query)
        let expected = fields.matchingKeys()
        let iterations = count >= 2048 ? 1 : 3
        var checksum = 0
        for _ in 0..<2 { checksum += fields.matchingKeys().count }
        var samples: [Double] = []
        for _ in 0..<9 {
            let start = DispatchTime.now().uptimeNanoseconds
            for _ in 0..<iterations { checksum += fields.matchingKeys().count }
            samples.append(Double(DispatchTime.now().uptimeNanoseconds - start) / Double(iterations) / 1_000_000)
        }
        try expect(fields.matchingKeys() == expected, "Repeated search results must remain stable")
        let ordered = samples.sorted()
        let record: [String: Any] = [
            "fixture_fields": count, "preview_fields": current.preview!.extra.count,
            "mode": mode, "query": query, "iterations": iterations,
            "matching_keys": expected, "checksum": checksum,
            "samples_ms": samples, "median_ms": ordered[4], "q1_ms": ordered[2], "q3_ms": ordered[6],
        ]
        let data = try JSONSerialization.data(withJSONObject: record, options: [.sortedKeys])
        print(String(decoding: data, as: UTF8.self))
    }

    static func main() throws {
        if CommandLine.arguments.count == 5 && CommandLine.arguments[1] == "benchmark" {
            guard let count = Int(CommandLine.arguments[2]), count > 0 else { throw Failure(message: "Expected a positive fixture size") }
            try benchmark(count, CommandLine.arguments[3], CommandLine.arguments[4])
        } else {
            try correctness()
        }
    }
}
