// SPDX-License-Identifier: GPL-3.0-only
import Foundation

/// A saved remote-pairing record. The pairing credentials themselves live in a
/// separate native `.plist` at `pairingFilePath`; this record only tracks where
/// it is and what it paired with. Kept in private Application Support — never in
/// Documents or a shared container, never synced.
struct DevicePairingRecord: Codable, Sendable, Equatable {
    var deviceName: String
    var deviceModel: String
    var deviceUDID: String
    /// Absolute path to the native pairing file in Application Support.
    var pairingFilePath: String
    /// The host altIRK a previous run returned, so re-pairing reuses host keys.
    var hostAltIRKHex: String
    var pairedAt: Date
    /// Last time a real tunnel/service handshake succeeded (not merely saved).
    var lastConnected: Date?
}

/// Persists the single current pairing record, device-bound, with complete file
/// protection. A successful pairing is kept even when a later connection fails,
/// so the user can retry the VPN without re-pairing.
actor DevicePairingStore {
    private struct Cache: Codable {
        let version: Int
        let device: String
        var record: DevicePairingRecord?
    }

    private let directory: URL
    private let device: String
    private var record: DevicePairingRecord?
    private var loaded = false
    private static let version = 1

    init(directory: URL, device: String) {
        self.directory = directory
        self.device = device
    }

    private var index: URL { directory.appendingPathComponent("Pairing.plist") }
    /// The native pairing file is always stored here. The absolute path in the
    /// index can go stale when iOS moves the app's data container (reinstall,
    /// side-load update), so resolve it against the current container first.
    private var expectedNativePath: String {
        directory.appendingPathComponent("Native/gestaltx_pairing.plist").path
    }

    /// Directory for the native pairing file, created on demand. Private,
    /// excluded from backup, complete file protection.
    func pairingDirectory() -> URL {
        let dir = directory.appendingPathComponent("Native", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true,
            attributes: [.protectionKey: FileProtectionType.complete])
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var mutable = dir
        try? mutable.setResourceValues(values)
        return dir
    }

    private func load() {
        guard !loaded else { return }
        loaded = true
        guard !device.isEmpty,
              let values = try? index.resourceValues(forKeys: [.fileSizeKey, .isSymbolicLinkKey]),
              values.isSymbolicLink != true, (values.fileSize ?? Int.max) <= 256 * 1024,
              let data = try? Data(contentsOf: index),
              let cache = try? PropertyListDecoder().decode(Cache.self, from: data),
              cache.version == Self.version, cache.device == device else { return }
        record = cache.record
        guard var current = record else { return }
        if !FileManager.default.fileExists(atPath: current.pairingFilePath) {
            if FileManager.default.fileExists(atPath: expectedNativePath) {
                current.pairingFilePath = expectedNativePath
                record = current
                save()
            }
        }
    }

    private func save() {
        guard !device.isEmpty else { return }
        do {
            let data = try PropertyListEncoder().encode(Cache(version: Self.version, device: device, record: record))
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try data.write(to: index, options: [.atomic, .completeFileProtection])
        } catch { /* keep in-memory record usable if storage is unavailable */ }
    }

    func current() -> DevicePairingRecord? {
        load()
        return record
    }

    /// Path that can actually be read right now, or nil when the native record
    /// is gone and the user must pair again.
    func currentPairingPath() -> String? {
        load()
        guard var current = record else { return nil }
        if FileManager.default.fileExists(atPath: current.pairingFilePath) {
            return current.pairingFilePath
        }
        guard FileManager.default.fileExists(atPath: expectedNativePath) else { return nil }
        current.pairingFilePath = expectedNativePath
        record = current
        save()
        return expectedNativePath
    }

    /// Replace the pairing record (after a successful handshake).
    func store(_ new: DevicePairingRecord) {
        load()
        record = new
        save()
    }

    /// Mark that a real connection succeeded at `date`.
    func markConnected(at date: Date = Date()) {
        load()
        guard var r = record else { return }
        r.lastConnected = date
        record = r
        save()
    }

    /// The altIRK to feed the next pairing run so host keys are reused.
    func savedHostAltIRKHex() -> String {
        load()
        return record?.hostAltIRKHex ?? ""
    }

    /// Forget the pairing. Also deletes the native pairing file if present.
    func clear() {
        load()
        if let path = record?.pairingFilePath, !path.isEmpty {
            try? FileManager.default.removeItem(atPath: path)
        }
        record = nil
        try? FileManager.default.removeItem(at: index)
    }
}
