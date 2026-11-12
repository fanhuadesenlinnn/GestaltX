import Foundation

@main struct MalformedCacheDescriptorTests {
    struct Failure: Error { let message: String }
    static func expect(_ condition: Bool, _ message: String) throws {
        if !condition { throw Failure(message: message) }
    }

    static func main() throws {
        let uuid = "A4A4A4A4-1111-2222-3333-123456789ABC"
        let address: UInt64 = 0x180100000
        let keys = ["AAAAAAAAAAAAAAAAAAAAAA", DeviceCacheOptions.greenTeaKey,
                    DeviceCacheOptions.wapiKey, "CCCCCCCCCCCCCCCCCCCCCC",
                    DeviceCacheOptions.notGreenTeaKey, "DDDDDDDDDDDDDDDDDDDDDD"]
        var strings = Data((uuid + "\0").utf8)
        var pointers: [UInt64] = []
        for key in keys {
            pointers.append(address + UInt64(strings.count))
            strings.append(contentsOf: (key + "\0").utf8)
        }
        func put<T: FixedWidthInteger>(_ value: T, into data: inout Data, at offset: Int) {
            var little = value.littleEndian
            withUnsafeBytes(of: &little) { data.replaceSubrange(offset..<(offset + $0.count), with: $0) }
        }
        func descriptor(_ slot: Int, index: Int16, type: UInt32) -> Data {
            var bytes = Data(repeating: 0, count: 64)
            put(pointers[slot], into: &bytes, at: 0)
            put(index, into: &bytes, at: 0x3A)
            put(type, into: &bytes, at: 0x3C)
            return bytes
        }
        let valid = keys.indices.reduce(into: Data()) { $0.append(descriptor($1, index: Int16($1), type: 11)) }
        let layout = try MobileGestaltCacheLayout.scan(strings: strings, stringAddress: address, constants: [valid])
        try expect(layout.slotCount == 6 && layout.greenTeaIndex == 1 && layout.notGreenTeaIndex == 4,
                   "A complete valid table still resolves")

        let malformed: [(Int16, UInt32)] = [(-2, 11), (-1, 11), (16384, 11), (.max, 11),
                                           (1, 0), (1, 5), (1, 12), (1, .max)]
        for target in [1, 4] {
            for (index, type) in malformed {
                for prefix in [false, true] {
                    let duplicate = descriptor(target, index: index, type: type)
                    let table = prefix ? duplicate + valid : valid + duplicate
                    do {
                        _ = try MobileGestaltCacheLayout.scan(strings: strings, stringAddress: address, constants: [table])
                        throw Failure(message: "Accepted malformed target \(target), index \(index), type \(type)")
                    } catch is GestaltFailure {
                        // The valid duplicate must not hide an unusable target reference.
                    }
                }
            }
        }
        let unrelated = valid + descriptor(0, index: -2, type: 0)
        let stillValid = try MobileGestaltCacheLayout.scan(strings: strings, stringAddress: address, constants: [unrelated])
        try expect(stillValid == layout, "Unrelated invalid descriptors do not disable a valid target table")
        let badWAPI = valid + descriptor(2, index: -2, type: 0)
        let optional = try MobileGestaltCacheLayout.scan(strings: strings, stringAddress: address, constants: [badWAPI])
        try expect(optional.wapiIndex == nil && optional.greenTeaIndex == 1 && optional.notGreenTeaIndex == 4,
                   "Malformed optional WAPI remains isolated from the required pair")
        print("PASS: malformed target indices/types cannot hide behind valid duplicates; valid and unrelated controls resolve.")
    }
}
