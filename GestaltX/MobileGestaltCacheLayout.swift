// SPDX-License-Identifier: GPL-3.0-only
import Foundation

struct MobileGestaltCacheLayout: Codable, Equatable, Sendable {
    let uuid: String
    let slotCount: Int
    let greenTeaIndex: Int
    let notGreenTeaIndex: Int
    var wapiIndex: Int? = nil

    var wapiOffset: Int? { wapiIndex.map { $0 * 8 } }

    var byteCount: Int { slotCount * 9 }
    var greenTeaOffset: Int { greenTeaIndex * 8 }
    var notGreenTeaOffset: Int { notGreenTeaIndex * 8 }
    func validityOffset(for index: Int) -> Int { slotCount * 8 + index }

    // Retain offline editing of the previously verified layout. Other layouts
    // are resolved from the device's own library, never selected by model/OS.
    static let originalProfile = Self(uuid: "7F1DF278-18B7-4E5A-8425-09E8830DE9AF",
                                      slotCount: 720, greenTeaIndex: 383, notGreenTeaIndex: 506, wapiIndex: 694)
    private static let runtimeProfile: Self? = {
        #if os(iOS) && !targetEnvironment(simulator)
        guard let image = GXCopyMobileGestaltImage() else { return nil }
        return try? scan(image: image)
        #else
        return nil
        #endif
    }()

    func matches(_ document: GestaltDocument) -> Bool {
        guard (1...16384).contains(slotCount), (0..<slotCount).contains(greenTeaIndex),
              (0..<slotCount).contains(notGreenTeaIndex), greenTeaIndex != notGreenTeaIndex,
              let uuid = document.root["CacheUUID"] as? String,
              let data = document.root["CacheData"] as? Data else { return false }
        if let wapiIndex, (!(0..<slotCount).contains(wapiIndex) || wapiIndex == greenTeaIndex || wapiIndex == notGreenTeaIndex) { return false }
        return self.uuid.caseInsensitiveCompare(uuid) == .orderedSame && data.count == byteCount
    }

    static func resolve(in document: GestaltDocument) throws -> Self {
        for layout in [runtimeProfile, originalProfile].compactMap({ $0 }) {
            if layout.matches(document) { return layout }
        }
        throw GestaltFailure("Unable to resolve this device's MobileGestalt cache layout.")
    }

    static func scan(image: [String: Any]) throws -> Self {
        guard let strings = image["strings"] as? Data,
              let address = image["stringAddress"] as? NSNumber,
              let constants = image["constants"] as? [Data] else {
            throw GestaltFailure("Unable to resolve this device's MobileGestalt cache layout.")
        }
        return try scan(strings: strings, stringAddress: address.uint64Value, constants: constants)
    }

    // Modern MobileGestalt query descriptors are 64 bytes. Their first pointer
    // identifies the exact obfuscated key; +0x3A is the signed cache index and
    // +0x3C is the query type (11 = Boolean). Resolve both independently.
    static func scan(strings: Data, stringAddress: UInt64, constants: [Data]) throws -> Self {
        let failure = GestaltFailure("Unable to resolve this device's MobileGestalt cache layout.")
        guard !strings.isEmpty, strings.count <= 32 * 1024 * 1024,
              stringAddress <= UInt64.max - UInt64(strings.count),
              constants.count <= 8, constants.allSatisfy({ $0.count <= 32 * 1024 * 1024 }) else { throw failure }
        let bytes = [UInt8](strings)
        var hashes: [UInt64: String] = [:]
        var uuids = Set<String>()
        var start = 0
        for end in bytes.indices where bytes[end] == 0 {
            let token = bytes[start..<end]
            if token.count == 22 && token.allSatisfy({
                (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || $0 == 43 || $0 == 47
            }) {
                hashes[stringAddress + UInt64(start)] = String(decoding: token, as: UTF8.self)
            } else if token.count == 36, let text = String(bytes: token, encoding: .utf8), let uuid = UUID(uuidString: text) {
                uuids.insert(uuid.uuidString)
            }
            start = end + 1
        }
        // Ambiguous UUIDs or descriptors are rejected rather than guessed.
        guard uuids.count == 1, let uuid = uuids.first else { throw failure }
        var indices = Set<Int>()
        var targets: [String: Set<Int>] = [:]
        var wapiIndices = Set<Int>()
        var wapiLocations = Set<String>()
        var invalidWAPI = false
        var targetLocations: [String: Set<String>] = [:]
        for (sectionID, section) in constants.enumerated() where section.count >= 64 {
            try section.withUnsafeBytes { raw in
                for offset in stride(from: 0, through: section.count - 64, by: 8) {
                    // Loaded pointers may carry arm64e PAC bits; no pointer is
                    // dereferenced. Compare its canonical user address only.
                    let pointer = UInt64(littleEndian: raw.loadUnaligned(fromByteOffset: offset, as: UInt64.self)) & 0x0000_FFFF_FFFF_FFFF
                    guard let key = hashes[pointer] else { continue }
                    let index = Int(Int16(littleEndian: raw.loadUnaligned(fromByteOffset: offset + 0x3A, as: Int16.self)))
                    let type = UInt32(littleEndian: raw.loadUnaligned(fromByteOffset: offset + 0x3C, as: UInt32.self))
                    if key == DeviceCacheOptions.wapiKey {
                        if type == 11 && index >= 0 && index < 16384 {
                            wapiIndices.insert(index)
                            wapiLocations.insert("\(sectionID):\(offset % 64)")
                        } else { invalidWAPI = true }
                    }
                    if key == DeviceCacheOptions.greenTeaKey || key == DeviceCacheOptions.notGreenTeaKey {
                        // Every reference to a target must be usable. Ignoring an
                        // invalid duplicate would silently select another offset.
                        guard type == 11, (0..<16384).contains(index) else { throw failure }
                        targets[key, default: []].insert(index)
                        targetLocations[key, default: []].insert("\(sectionID):\(offset % 64)")
                    }
                    guard (-1..<16384).contains(index), (1...11).contains(type) else { continue }
                    if index >= 0 { indices.insert(index) }
                }
            }
        }
        guard let maximum = indices.max(), maximum >= 1,
              indices.count > (maximum + 1) / 2,
              let green = targets[DeviceCacheOptions.greenTeaKey], green.count == 1,
              let notGreen = targets[DeviceCacheOptions.notGreenTeaKey], notGreen.count == 1,
              let greenIndex = green.first, let notGreenIndex = notGreen.first, greenIndex != notGreenIndex,
              let greenLocation = targetLocations[DeviceCacheOptions.greenTeaKey], greenLocation.count == 1,
              greenLocation == targetLocations[DeviceCacheOptions.notGreenTeaKey] else { throw failure }
        let wapi = !invalidWAPI && wapiIndices.count == 1 && !wapiIndices.contains(greenIndex) && !wapiIndices.contains(notGreenIndex) && wapiLocations == greenLocation
            ? wapiIndices.first : nil
        return Self(uuid: uuid, slotCount: maximum + 1, greenTeaIndex: greenIndex,
                    notGreenTeaIndex: notGreenIndex, wapiIndex: wapi)
    }
}
