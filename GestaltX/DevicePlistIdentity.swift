// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import CoreFoundation

struct DevicePlistIdentity: Sendable {
    // Compare individual-device identifiers, never model/region/cache UUID.
    private(set) var values: [String: String]
    static let unavailable = SharedPlistError(key: "This device's identity could not be verified. Read MobileGestalt on this device and try sharing again.", retryable: true)
    static let mismatch = SharedPlistError(key: "This plist belongs to another device and cannot be imported.")
    static let incomplete = SharedPlistError(key: "This plist does not contain enough device identifiers to verify ownership.")
    private static let keys = [
        "UniqueDeviceID": "re6Zb+zwFKJNlkQTUeT+/w",
        "SerialNumber": "VasUgeSzVyHdB27g2XpN0g",
        "UniqueChipID": "TF31PAB6aO8KAbPyNKSxKA"
    ]

    init(properties: [String: Any]) throws {
        var result: [String: String] = [:]
        for (name, hash) in Self.keys {
            for key in [name, hash] where properties[key] != nil {
                guard let value = Self.normalized(properties[key]!, name: name) else { throw Self.incomplete }
                if let previous = result[name], previous != value { throw Self.mismatch }
                result[name] = value
            }
        }
        values = result
    }

    init(plist data: Data) throws {
        try SharedPlistInbox.validate(data)
        let root = try PropertyListSerialization.propertyList(from: data, options: [], format: nil) as! [String: Any]
        try self.init(properties: root["CacheExtra"] as! [String: Any])
    }

    func mergingTrusted(_ other: Self) throws -> Self {
        var merged = self
        for (key, value) in other.values {
            if let previous = merged.values[key], previous != value { throw Self.unavailable }
            merged.values[key] = value
        }
        return merged
    }

    func requireMatch(with trusted: Self) throws {
        guard trusted.values.count >= 2 else { throw Self.unavailable }
        var matching = 0
        for (key, value) in values {
            if let expected = trusted.values[key] {
                guard value == expected else { throw Self.mismatch }
                matching += 1
            }
        }
        guard matching >= 2 else { throw Self.incomplete }
    }

    private static func normalized(_ value: Any, name: String) -> String? {
        if name == "UniqueChipID" {
            let text: String
            if let number = value as? NSNumber {
                guard CFGetTypeID(number) != CFBooleanGetTypeID(), !CFNumberIsFloatType(unsafeBitCast(number, to: CFNumber.self)) else { return nil }
                text = number.stringValue
            } else if let string = value as? String { text = string } else { return nil }
            let number = text.lowercased().hasPrefix("0x") ? UInt64(text.dropFirst(2), radix: 16) : UInt64(text)
            guard let number, number != 0 else { return nil }
            return String(number)
        }
        guard let string = value as? String, !string.isEmpty,
              string == string.trimmingCharacters(in: .whitespacesAndNewlines) else { return nil }
        let normalized = string.uppercased()
        if name == "UniqueDeviceID" {
            guard (16...64).contains(normalized.utf8.count), normalized.utf8.allSatisfy({
                (48...57).contains($0) || (65...70).contains($0) || $0 == 45
            }) else { return nil }
        } else {
            guard (8...32).contains(normalized.utf8.count), normalized.utf8.allSatisfy({
                (48...57).contains($0) || (65...90).contains($0)
            }) else { return nil }
        }
        return normalized
    }
}
