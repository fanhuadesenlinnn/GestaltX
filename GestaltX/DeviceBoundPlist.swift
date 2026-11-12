// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import CryptoKit
import Security

// A device-only Keychain secret is never placed in the shared container or export.
enum DeviceBoundPlist {
    static let proofKey = "GestaltXDeviceProof"
    private static let service = "com.huami.gestultx.device-proof"
    private static let lock = NSLock()
    private static var invalid: SharedPlistError { SharedPlistError(key: "This plist's device proof could not be verified on this device.") }

    static func keychainFailure(_ status: OSStatus) -> SharedPlistError {
        if [errSecNotAvailable, errSecInteractionNotAllowed, errSecUserCanceled].contains(status) {
            return SharedPlistError(key: "The device proof is temporarily unavailable. Unlock this device and try again.", retryable: true)
        }
        return invalid
    }

    static func seal(_ payload: Data) throws -> Data { try seal(payload, key: key(create: true)) }
    static func verifiedPayload(_ exported: Data) throws -> Data? {
        let root = try PropertyListSerialization.propertyList(from: exported, options: [], format: nil) as? [String: Any]
        guard root?[proofKey] != nil else { return nil }
        return try verify(exported, key: key(create: false))
    }
    static func seal(_ payload: Data, key: Data) throws -> Data {
        try SharedPlistInbox.validate(payload)
        guard key.count == 32, var root = try PropertyListSerialization.propertyList(from: payload, options: [], format: nil) as? [String: Any] else { throw invalid }
        root.removeValue(forKey: proofKey)
        let plain = try PropertyListSerialization.data(fromPropertyList: root, format: .binary, options: 0)
        let tag = Data(HMAC<SHA256>.authenticationCode(for: plain, using: SymmetricKey(data: key)))
        root[proofKey] = ["version": 1, "payload": plain, "tag": tag]
        let exported = try PropertyListSerialization.data(fromPropertyList: root, format: .binary, options: 0)
        guard exported.count <= SharedPlistInbox.maximumByteCount else { throw SharedPlistError(key: "Choose a plist smaller than 16 MB.") }
        return exported
    }
    static func verify(_ exported: Data, key: Data) throws -> Data {
        guard key.count == 32, exported.count <= SharedPlistInbox.maximumByteCount,
              var outer = try PropertyListSerialization.propertyList(from: exported, options: [], format: nil) as? [String: Any],
              let proof = outer.removeValue(forKey: proofKey) as? [String: Any], proof["version"] as? Int == 1,
              let payload = proof["payload"] as? Data, payload.count <= SharedPlistInbox.maximumByteCount,
              let tag = proof["tag"] as? Data, tag.count == 32,
              HMAC<SHA256>.isValidAuthenticationCode(tag, authenticating: payload, using: SymmetricKey(data: key)),
              let original = try PropertyListSerialization.propertyList(from: payload, options: [], format: nil) as? [String: Any],
              original[proofKey] == nil, GestaltDocument.valuesEqual(outer, original) else { throw invalid }
        try SharedPlistInbox.validate(payload)
        return payload
    }
    private static func key(create: Bool) throws -> Data {
        lock.lock(); defer { lock.unlock() }
        let query: [CFString: Any] = [kSecClass: kSecClassGenericPassword, kSecAttrService: service,
                                     kSecAttrAccount: "local-v1", kSecAttrSynchronizable: false,
                                     kSecUseDataProtectionKeychain: true]
        var read = query
        read[kSecReturnData] = true; read[kSecMatchLimit] = kSecMatchLimitOne
        var found: CFTypeRef?
        let status = SecItemCopyMatching(read as CFDictionary, &found)
        if status == errSecSuccess, let bytes = found as? Data, bytes.count == 32 { return bytes }
        guard status == errSecItemNotFound, create else { throw keychainFailure(status) }
        var bytes = Data(count: 32)
        let generated = bytes.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, 32, $0.baseAddress!) }
        guard generated == errSecSuccess else { throw keychainFailure(generated) }
        var add = query
        add[kSecAttrAccessible] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        add[kSecValueData] = bytes
        let saved = SecItemAdd(add as CFDictionary, nil)
        guard saved == errSecSuccess else { throw keychainFailure(saved) }
        return bytes
    }
}
