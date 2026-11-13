// SPDX-License-Identifier: GPL-3.0-only
// Run on macOS with: python3 tests/run_document_diff_regression.py --test tests/DocumentDiffTests.swift
import Foundation

@MainActor @main struct DocumentDiffTests {
    struct Failure: Error { let message: String }
    static func expect(_ condition: Bool, _ message: String) throws {
        if !condition { throw Failure(message: message) }
    }
    static func encoded(_ values: [String: Any]) throws -> GestaltDocument {
        try GestaltDocument(data: PropertyListSerialization.data(fromPropertyList: ["CacheExtra": values], format: .binary, options: 0))
    }
    static func correctness() throws {
        let renderer = DocumentDiffHarness()
        var outputs: [String: [String]] = [:]
        outputs["simple"] = renderer.rendered(["z": 1, "gone": Data([1])], ["a": true, "z": 2])
        try expect(outputs["simple"] == ["+ a = true", "- gone  (was 1 bytes)", "~ z: 1 → 2"], "Simple diff order and text remain exact")
        outputs["nested"] = renderer.rendered(["outer": ["same": 1, "changed": 2, "remove": "x"]],
                                               ["outer": ["changed": 3, "add": "y", "same": 1]])
        try expect(outputs["nested"] == ["+ outer.add = y", "~ outer.changed: 2 → 3", "- outer.remove  (was x)"],
                   "Nested changes retain depth-first lexical order")
        outputs["unchanged"] = renderer.rendered(["empty": [String: Any](), "n": Double.nan], ["n": Double.nan, "empty": [String: Any]()])
        try expect(outputs["unchanged"] == [], "Unchanged empty dictionaries and NaNs remain silent")
        outputs["types"] = renderer.rendered(["bool": true, "integer": NSNumber(value: UInt64.max), "array": [1, 2]],
                                              ["bool": 1, "integer": NSNumber(value: Int64(-1)), "array": [1, 3]])
        outputs["replacement"] = renderer.rendered(["dictionary": ["a": 1], "scalar": "before"],
                                                    ["dictionary": "after", "scalar": ["a": 1]])
        outputs["empty-member"] = renderer.rendered(["empty": [String: Any]()], ["empty": ["new": [String: Any]()]])
        outputs["prefix"] = renderer.rendered(["same": "keep", "changed": "before"], ["same": "keep", "changed": "after"], prefix: "CacheExtra")
        try expect(outputs["prefix"] == ["~ CacheExtra.changed: before → after"], "Caller prefixes remain exact")
        outputs["long-text"] = renderer.rendered(["text": String(repeating: "a", count: 90)], ["text": String(repeating: "b", count: 90)])
        outputs["date"] = renderer.rendered(["date": Date(timeIntervalSince1970: 0)], ["date": Date(timeIntervalSince1970: 1)])
        outputs["unicode"] = renderer.rendered(["字段": ["旧": "值"]], ["字段": ["新": "值"]])
        let json = try JSONSerialization.data(withJSONObject: outputs, options: [.sortedKeys])
        print(String(decoding: json, as: UTF8.self))
    }
    static func fixture(_ kind: String) throws -> (GestaltDocument, GestaltDocument) {
        var values: [String: Any] = [:]
        let count = kind == "dense" ? 2000 : kind == "deep" ? 2500 : 15000
        for index in 0..<count { values["field-\(index)"] = NSNumber(value: index) }
        var changed = values
        if kind == "dense" {
            for index in 0..<count { changed["field-\(index)"] = NSNumber(value: -index - 1) }
        } else if kind != "unchanged" { changed["field-\(count / 2)"] = NSNumber(value: -1) }
        if kind == "deep" {
            for depth in 0..<24 {
                values = ["level-\(depth)": values, "unchanged": depth]
                changed = ["level-\(depth)": changed, "unchanged": depth]
            }
        }
        return try (encoded(values), encoded(changed))
    }
    static func benchmark(_ kind: String) throws {
        let renderer = DocumentDiffHarness()
        let (before, after) = try fixture(kind)
        let expected = renderer.rendered(before.root, after.root)
        try expect(expected.count == (kind == "dense" ? 2000 : kind == "unchanged" ? 0 : 1), "Fixture has the intended change count")
        let repetitions = kind == "deep" ? 4 : 12
        var samples: [Double] = []
        var checksum = 0
        for _ in 0..<5 {
            let start = DispatchTime.now().uptimeNanoseconds
            for _ in 0..<repetitions { checksum += renderer.rendered(before.root, after.root).count }
            samples.append(Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000_000)
        }
        try expect(checksum == repetitions * 5 * expected.count, "Every measured diff completes")
        let data = try JSONSerialization.data(withJSONObject: ["case": kind, "samples_seconds": samples,
                                                               "repetitions": repetitions, "changes": expected.count], options: [.sortedKeys])
        print(String(decoding: data, as: UTF8.self))
    }
    static func main() throws {
        let selected = CommandLine.arguments.dropFirst().first ?? "correctness"
        if selected == "correctness" { try correctness() }
        else if ["sparse", "deep", "dense", "unchanged"].contains(selected) { try benchmark(selected) }
        else { throw Failure(message: "Unknown case: " + selected) }
    }
}
