import Foundation
import Darwin
import Security

@main struct SharedImportRecoveryTests {
    struct Failure: Error { let message: String }
    static func expect(_ condition: Bool, _ message: String) throws {
        if !condition { throw Failure(message: message) }
    }

    static func main() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("GestaltX-import-recovery-" + UUID().uuidString)
        defer { try? fm.removeItem(at: root) }
        let inbox = try SharedPlistInbox(container: root, namespace: "test")
        let bytes = try PropertyListSerialization.data(fromPropertyList: ["CacheExtra": ["fixture": true]], format: .binary, options: 0)
        let temporary: [Error] = [NSError(domain: NSPOSIXErrorDomain, code: Int(EACCES)),
                                  NSError(domain: NSPOSIXErrorDomain, code: Int(EINTR)),
                                  NSError(domain: NSCocoaErrorDomain, code: CocoaError.fileReadNoPermission.rawValue),
                                  NSError(domain: NSCocoaErrorDomain, code: CocoaError.userCancelled.rawValue),
                                  NSError(domain: "FileProviderWrapper", code: 1, userInfo: [NSUnderlyingErrorKey: NSError(domain: NSPOSIXErrorDomain, code: Int(EBUSY))]),
                                  DeviceBoundPlist.keychainFailure(errSecInteractionNotAllowed),
                                  DeviceBoundPlist.keychainFailure(errSecNotAvailable),
                                  DevicePlistIdentity.unavailable, CancellationError()]
        for error in temporary {
            let entry = try inbox.enqueue(bytes, name: "retry.plist")
            try expect(!inbox.reject(entry, after: error), "Temporary failures must not quarantine a valid document")
            try expect(try inbox.entries().contains { $0.id == entry.id }, "The retained entry remains available for a later retry")
            try expect(try inbox.read(entry) == bytes, "A successful retry reads the original bytes")
            try inbox.acknowledge(entry)
        }
        let permanent: [Error] = [SharedPlistError(key: "Choose a MobileGestalt plist with a CacheExtra dictionary."),
                                  DevicePlistIdentity.mismatch, DevicePlistIdentity.incomplete,
                                  DeviceBoundPlist.keychainFailure(errSecItemNotFound),
                                  DeviceBoundPlist.keychainFailure(errSecDecode),
                                  NSError(domain: NSPOSIXErrorDomain, code: Int(ENOENT)),
                                  NSError(domain: NSCocoaErrorDomain, code: CocoaError.fileReadCorruptFile.rawValue),
                                  NSError(domain: NSPOSIXErrorDomain, code: Int.max),
                                  NSError(domain: "UnknownFailure", code: 1)]
        for error in permanent {
            let entry = try inbox.enqueue(bytes, name: "reject.plist")
            try expect(inbox.reject(entry, after: error), "Permanent and unknown failures must not become endless retries")
            try expect(try inbox.entries().isEmpty, "Rejected entries leave the automatic queue")
        }
        print("PASS: temporary filesystem, keychain and cancellation failures retain exact bytes; invalid content, missing proofs and unknown failures are quarantined.")
    }
}
