import Foundation

@main struct NonFinitePlistTests {
    struct Failure: Error { let message: String }
    final class Trace: @unchecked Sendable { var writes = 0 }
    static func expect(_ condition: Bool, _ message: String) throws {
        if !condition { throw Failure(message: message) }
    }

    static func main() async throws {
        let xml = Data("""
        <?xml version="1.0" encoding="UTF-8"?>
        <plist version="1.0"><dict><key>CacheExtra</key><dict>
        <key>measurement</key><real>nan</real>
        <key>nested</key><array><dict><key>value</key><real>nan</real></dict></array>
        <key>setting</key><string>original</string>
        </dict></dict></plist>
        """.utf8)
        let document = try GestaltDocument(data: xml)
        try expect((document.extra["measurement"] as? NSNumber)?.doubleValue.isNaN == true, "The fixture contains a real Foundation-parsed NaN")
        try expect(document.matches(document), "A valid plist containing NaN must compare equal to itself")
        let binary = try document.encoded()
        let roundtrip = try GestaltDocument(data: binary)
        try expect(document.matches(roundtrip), "Nested NaNs survive XML-to-binary document comparison")

        let nan = NSNumber(value: Double.nan)
        let cases: [NSNumber] = [nan, NSNumber(value: Double.infinity), NSNumber(value: -Double.infinity),
                                 NSNumber(value: 0.0), NSNumber(value: 1.25)]
        for (leftIndex, left) in cases.enumerated() {
            for (rightIndex, right) in cases.enumerated() {
                try expect(GestaltDocument.valuesEqual(left, right) == (leftIndex == rightIndex), "NaN, signed infinities and finite reals remain distinct")
            }
        }
        try expect(!GestaltDocument.valuesEqual(nan, "nan"), "A NaN real is not a string")
        try expect(!GestaltDocument.valuesEqual(nan, NSNumber(value: 0)), "A NaN real is not an integer")
        try expect(!GestaltDocument.valuesEqual(nan, NSNumber(value: false)), "A NaN real is not a Boolean")
        for text in ["nan", "inf", "-inf"] {
            do {
                _ = try PlistValueKind.real.parse(text)
                throw Failure(message: "Scalar editing unexpectedly accepted a non-finite value")
            } catch is GestaltFailure {}
        }

        let key = Data(repeating: 19, count: 32)
        let sealed = try DeviceBoundPlist.seal(binary, key: key)
        let verified = try DeviceBoundPlist.verify(sealed, key: key)
        try expect(document.matches(GestaltDocument(data: verified)), "A device proof verifies its own payload containing NaN")
        var tampered = try PropertyListSerialization.propertyList(from: sealed, format: nil) as! [String: Any]
        var extra = tampered["CacheExtra"] as! [String: Any]
        extra["measurement"] = NSNumber(value: 0.0)
        tampered["CacheExtra"] = extra
        let changedOuter = try PropertyListSerialization.data(fromPropertyList: tampered, format: .binary, options: 0)
        do {
            _ = try DeviceBoundPlist.verify(changedOuter, key: key)
            throw Failure(message: "A finite replacement of a signed NaN payload was accepted")
        } catch is SharedPlistError {}

        let fm = FileManager.default
        let directory = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: directory) }
        let device = directory.appendingPathComponent("device.plist")
        try xml.write(to: device)
        let trace = Trace()
        let store = GestaltFileStore(deviceURL: device, backupDirectory: directory.appendingPathComponent("backups"),
                                     deviceID: "nan-fixture", acquire: { 1 }, release: { _ in },
                                     writeData: { data, url in trace.writes += 1; try data.write(to: url) })
        let initial = try await store.loadDevice()
        var edited = initial.document
        edited.set("changed", for: "setting")
        let result = try await store.commit(edited, expected: initial)
        try expect(trace.writes == 1 && result.document.matches(edited), "An unrelated device edit with NaN passes full readback verification")
        try expect(result.originals["measurement"] == nil && result.originals["nested"] == nil, "Unchanged NaNs are not recorded as field edits")
        let saved = try Data(contentsOf: device)
        let corruptingStore = GestaltFileStore(deviceURL: device, backupDirectory: directory.appendingPathComponent("bad-readback"),
                                               deviceID: "nan-fixture", acquire: { 1 }, release: { _ in },
                                               writeData: { data, url in
            var altered = try GestaltDocument(data: data)
            altered.set(NSNumber(value: Double.infinity), for: "measurement")
            try altered.encoded().write(to: url)
        })
        let beforeCorruption = try await corruptingStore.loadDevice()
        var next = beforeCorruption.document
        next.set("next edit", for: "setting")
        do {
            _ = try await corruptingStore.commit(next, expected: beforeCorruption)
            throw Failure(message: "Replacing NaN with infinity passed readback verification")
        } catch is GestaltFailure {}
        try expect(try Data(contentsOf: device) == saved, "A non-finite value mismatch still restores the previous device bytes")
        print("PASS: reflexive NaN document comparison, distinct infinities and types, proof roundtrip, verified device edits and corruption rollback.")
    }
}
