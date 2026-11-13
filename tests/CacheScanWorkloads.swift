import Foundation

// Synthetic descriptor workloads for the public scanner. No device library is
// bundled, and these fixtures do not claim real-device startup measurements.
@main struct CacheScanWorkloads {
    struct Fixture {
        let strings: Data
        let constants: [Data]
        let slots: Int
        let address: UInt64 = 0x180100000
    }
    static let uuid = "A4A4A4A4-1111-2222-3333-123456789ABC"

    static func fixture(slots: Int, strings count: Int, padding: Int = 0) -> Fixture {
        var strings = Data((uuid + "\0").utf8)
        var constants = Data(repeating: 0, count: slots * 64)
        for index in 0..<count {
            let key: String
            switch index {
            case 1: key = DeviceCacheOptions.greenTeaKey
            case 2: key = DeviceCacheOptions.wapiKey
            case 4: key = DeviceCacheOptions.notGreenTeaKey
            default: key = "AAAAAAAAAAAAAAAA" + String(format: "%06d", index)
            }
            let pointer = UInt64(0x180100000) + UInt64(strings.count)
            strings.append(contentsOf: (key + "\0").utf8)
            if index < slots {
                func put<T: FixedWidthInteger>(_ value: T, at offset: Int) {
                    var little = value.littleEndian
                    withUnsafeBytes(of: &little) { constants.replaceSubrange(offset..<(offset + $0.count), with: $0) }
                }
                put(pointer, at: index * 64)
                put(Int16(index), at: index * 64 + 0x3A)
                put(UInt32(11), at: index * 64 + 0x3C)
            }
        }
        strings.append(Data(repeating: 65, count: padding))
        if padding > 0 { strings.append(0) }
        return Fixture(strings: strings, constants: [constants], slots: slots)
    }

    static func scan(_ fixture: Fixture) throws -> MobileGestaltCacheLayout {
        let layout = try MobileGestaltCacheLayout.scan(strings: fixture.strings, stringAddress: fixture.address,
                                                       constants: fixture.constants)
        precondition(layout.uuid == uuid && layout.slotCount == fixture.slots && layout.greenTeaIndex == 1 &&
                     layout.notGreenTeaIndex == 4 && layout.wapiIndex == 2, "Changed descriptor result")
        return layout
    }

    static func main() throws {
        let mode = CommandLine.arguments.dropFirst().first ?? "compat"
        let fixture: Fixture
        switch mode {
        case "typical": fixture = self.fixture(slots: 720, strings: 2_500)
        case "many-strings": fixture = self.fixture(slots: 4_096, strings: 200_000)
        case "large-string-area": fixture = self.fixture(slots: 720, strings: 2_500, padding: 8 * 1024 * 1024)
        default:
            for slots in [6, 720, 4_096, 16_384] {
                let item = self.fixture(slots: slots, strings: slots + 200)
                _ = try scan(item)
                var invalid = item.strings
                invalid.append(contentsOf: "11111111-2222-3333-4444-555555555555\0".utf8)
                do {
                    _ = try MobileGestaltCacheLayout.scan(strings: invalid, stringAddress: item.address, constants: item.constants)
                    preconditionFailure("Ambiguous UUIDs must remain rejected")
                } catch is GestaltFailure { }
            }
            let item = self.fixture(slots: 6, strings: 6)
            var padding = Data([0xFF, 0xFE, 0])
            padding.append(item.strings)
            var constants = item.constants[0]
            for index in 0..<6 {
                let offset = index * 64
                let original = constants.withUnsafeBytes { UInt64(littleEndian: $0.loadUnaligned(fromByteOffset: offset, as: UInt64.self)) }
                var pointer = (original + 3).littleEndian
                withUnsafeBytes(of: &pointer) { constants.replaceSubrange(offset..<(offset + 8), with: $0) }
            }
            let shifted = Fixture(strings: padding, constants: [constants], slots: 6)
            _ = try scan(shifted)
            print("PASS: five valid layouts, unrelated/invalid strings and four ambiguous-UUID cases")
            return
        }
        for _ in 0..<3 { _ = try scan(fixture) }
        var samples: [Double] = []
        for _ in 0..<15 {
            let start = DispatchTime.now().uptimeNanoseconds
            _ = try scan(fixture)
            samples.append(Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000)
        }
        samples.sort()
        let result: [String: Any] = ["case": mode, "strings_bytes": fixture.strings.count,
                                     "slots": fixture.slots, "median_ms": samples[7], "iqr_ms": samples[11] - samples[3],
                                     "samples_ms": samples]
        print(String(data: try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys]), encoding: .utf8)!)
    }
}
