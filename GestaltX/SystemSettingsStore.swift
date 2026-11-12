// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import CryptoKit
import Darwin

enum SystemSettingsFile: String, Codable, CaseIterable, Sendable {
    case footnote
    var relativePath: String {
        "containers/Shared/SystemGroup/systemgroup.com.apple.configurationprofiles/Library/ConfigurationProfiles/SharedDeviceConfiguration.plist"
    }
}

enum SystemSetting: String, CaseIterable, Identifiable, Codable, Sendable {
    case lockScreenText
    var id: String { rawValue }
    var title: String { "Lock Screen Text" }
    var detail: String { "Add your own text at the bottom of the Lock Screen." }
    var file: SystemSettingsFile { .footnote }
    // This configuration-profiles System Group is accessible on iOS 27.
    var key: String { "LockScreenFootnote" }
}

struct SystemPreferenceValue: Codable, Equatable, Sendable {
    let data: Data?
    init(_ value: Any?) throws {
        data = try value.map { try PropertyListSerialization.data(fromPropertyList: ["value": $0], format: .binary, options: 0) }
    }
    func decoded() throws -> Any? {
        guard let data else { return nil }
        guard let root = try PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any],
              let value = root["value"] else { throw GestaltFailure("Original values could not be read. No system changes were made.") }
        return value
    }
    static func == (lhs: Self, rhs: Self) -> Bool {
        guard let a = try? lhs.decoded(), let b = try? rhs.decoded() else { return lhs.data == nil && rhs.data == nil }
        return GestaltDocument.valuesEqual(a, b)
    }
    var display: String {
        guard let value = try? decoded() else { return NSLocalizedString("System Default", comment: "") }
        if let value = value as? String { return value.isEmpty ? NSLocalizedString("Empty", comment: "") : value }
        return NSLocalizedString("System Default", comment: "")
    }
}

enum SystemSettingAction: Sendable {
    case text(String), restore
}

struct SystemSettingsSnapshot: Sendable {
    var values: [SystemSetting: SystemPreferenceValue] = [:]
    var originals: [SystemSetting: SystemPreferenceValue] = [:]
    var errors: [SystemSettingsFile: String] = [:]
}

actor SystemSettingsStore {
    private struct FileState {
        let data: Data?
        let permissions: Int
        var dictionary: [String: Any] {
            get throws {
                guard let data else { return [:] }
                guard let value = try PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any] else {
                    throw GestaltFailure("The system settings file is not a valid dictionary.")
                }
                return value
            }
        }
    }
    private struct Journal: Codable {
        let version: Int
        let deviceID: String
        var originals: [SystemSetting: SystemPreferenceValue]
        var fileExisted: [SystemSettingsFile: Bool]
    }
    private struct Plan {
        let file: SystemSettingsFile
        let before: FileState
        let after: Data?
    }
    private let systemRoot: URL
    private let storage: URL
    private let deviceID: String
    private let acquire: @Sendable (String) throws -> Int64
    private let release: @Sendable (Int64) -> Void
    private let writeOverride: (@Sendable (URL, Data?) throws -> Void)?
    private let event: @Sendable (String) -> Void

    init(systemRoot: URL = URL(fileURLWithPath: "/private/var", isDirectory: true), storage: URL, deviceID: String,
         acquire: @escaping @Sendable (String) throws -> Int64, release: @escaping @Sendable (Int64) -> Void,
         writeOverride: (@Sendable (URL, Data?) throws -> Void)? = nil,
         event: @escaping @Sendable (String) -> Void = { _ in }) {
        self.systemRoot = systemRoot; self.storage = storage; self.deviceID = deviceID
        self.acquire = acquire; self.release = release; self.writeOverride = writeOverride; self.event = event
    }
    private func url(_ file: SystemSettingsFile) -> URL { systemRoot.appendingPathComponent(file.relativePath) }
    private func access<T>(_ files: Set<SystemSettingsFile>, _ body: () throws -> T) throws -> T {
        var handles: [Int64] = []
        defer { for handle in handles.reversed() { release(handle) } }
        for parent in Set(files.map { url($0).deletingLastPathComponent().path }).sorted() {
            handles.append(try acquire(parent))
        }
        return try body()
    }
    private func read(_ file: SystemSettingsFile) throws -> FileState {
        let path = url(file)
        let fd = open(path.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        if fd < 0 {
            if errno == ENOENT { return FileState(data: nil, permissions: 0o600) }
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? handle.close() }
        var info = stat()
        guard fstat(fd, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG, info.st_size <= 16 * 1024 * 1024 else {
            throw GestaltFailure("The system settings file is not a valid dictionary.")
        }
        var data = Data()
        while let chunk = try handle.read(upToCount: 64 * 1024), !chunk.isEmpty {
            data.append(chunk)
            guard data.count <= 16 * 1024 * 1024 else { throw GestaltFailure("The system settings file is not a valid dictionary.") }
        }
        let result = FileState(data: data, permissions: Int(info.st_mode & 0o777))
        _ = try result.dictionary
        return result
    }
    private var journalURL: URL { storage.appendingPathComponent("OriginalValues.plist") }
    private func journal() throws -> Journal {
        guard FileManager.default.fileExists(atPath: journalURL.path) else {
            return Journal(version: 1, deviceID: deviceID, originals: [:], fileExisted: [:])
        }
        let value: Journal
        do { value = try PropertyListDecoder().decode(Journal.self, from: Data(contentsOf: journalURL)) }
        catch { throw GestaltFailure("Original values could not be read. No system changes were made.") }
        guard value.version == 1, value.deviceID == deviceID else { throw GestaltFailure("The original-value record belongs to a different device.") }
        for original in value.originals.values { _ = try original.decoded() }
        return value
    }
    private func saveJournal(_ value: Journal) throws {
        try FileManager.default.createDirectory(at: storage, withIntermediateDirectories: true)
        let bytes = try PropertyListEncoder().encode(value)
        try bytes.write(to: journalURL, options: .atomic)
        guard try Data(contentsOf: journalURL) == bytes else {
            throw GestaltFailure("Original values could not be saved and verified. No system write was started.")
        }
    }
    func load() throws -> SystemSettingsSnapshot {
        let saved = try journal()
        var result = SystemSettingsSnapshot(originals: saved.originals)
        for file in SystemSettingsFile.allCases {
            do {
                let state = try access([file]) { try read(file) }
                let dictionary = try state.dictionary
                for setting in SystemSetting.allCases where setting.file == file {
                    result.values[setting] = try SystemPreferenceValue(dictionary[setting.key])
                }
            } catch { result.errors[file] = error.localizedDescription }
        }
        return result
    }
    private func backup(_ plans: [Plan]) throws {
        let folder = storage.appendingPathComponent("Backups/" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var manifest: [String: Any] = ["created": Date(), "files": [String: Any]()]
        var files: [String: Any] = [:]
        for plan in plans {
            var entry: [String: Any] = ["existed": plan.before.data != nil]
            if let bytes = plan.before.data {
                let output = folder.appendingPathComponent(plan.file.rawValue + ".plist")
                try bytes.write(to: output, options: .atomic)
                guard try Data(contentsOf: output) == bytes else { throw GestaltFailure("The settings backup could not be verified. No changes were applied.") }
                entry["sha256"] = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
            }
            files[plan.file.rawValue] = entry
        }
        manifest["files"] = files
        let bytes = try PropertyListSerialization.data(fromPropertyList: manifest, format: .binary, options: 0)
        let output = folder.appendingPathComponent("Manifest.plist")
        try bytes.write(to: output, options: .atomic)
        guard try Data(contentsOf: output) == bytes else { throw GestaltFailure("The settings backup could not be verified. No changes were applied.") }
        event("[system-settings] Pre-write backup verified")
    }
    private func write(_ data: Data?, file: SystemSettingsFile, permissions: Int) throws {
        let target = url(file)
        if let writeOverride { try writeOverride(target, data) }
        else if let data {
            try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: target, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: permissions], ofItemAtPath: target.path)
        } else if FileManager.default.fileExists(atPath: target.path) {
            try FileManager.default.removeItem(at: target)
        }
    }
    func apply(_ actions: [SystemSetting: SystemSettingAction], expected: SystemSettingsSnapshot) throws -> SystemSettingsSnapshot {
        var saved = try journal()
        try access(Set(actions.keys.map(\.file))) {
            var plans: [Plan] = []
            for file in SystemSettingsFile.allCases where actions.keys.contains(where: { $0.file == file }) {
                let before = try read(file)
                var dictionary = try before.dictionary
                var changed = false
                for setting in SystemSetting.allCases where setting.file == file {
                    guard let action = actions[setting] else { continue }
                    guard let expectedValue = expected.values[setting] else { throw GestaltFailure("These system settings are not accessible on this device.") }
                    let current = try SystemPreferenceValue(dictionary[setting.key])
                    guard current == expectedValue else { throw GestaltFailure("System settings changed. Read them again before applying.") }
                    let desired: SystemPreferenceValue
                    switch action {
                    case .text(let value):
                        guard setting == .lockScreenText, value.count <= 256, !value.contains(where: { $0.isNewline }) else {
                            throw GestaltFailure("Use a single line of up to 256 characters.")
                        }
                        desired = try SystemPreferenceValue(value)
                    case .restore:
                        guard let original = saved.originals[setting] else { throw GestaltFailure("Original values could not be read. No system changes were made.") }
                        desired = original
                    }
                    guard current != desired else { continue }
                    if saved.originals[setting] == nil { saved.originals[setting] = current }
                    if saved.fileExisted[file] == nil { saved.fileExisted[file] = before.data != nil }
                    dictionary[setting.key] = try desired.decoded()
                    changed = true
                }
                if changed {
                    let output = dictionary.isEmpty && saved.fileExisted[file] == false ? nil
                        : try PropertyListSerialization.data(fromPropertyList: dictionary, format: .binary, options: 0)
                    plans.append(Plan(file: file, before: before, after: output))
                }
            }
            guard !plans.isEmpty else { return }
            try backup(plans)
            try saveJournal(saved)
            var completed: [Plan] = []
            do {
                for plan in plans {
                    guard try read(plan.file).data == plan.before.data else { throw GestaltFailure("System settings changed. Read them again before applying.") }
                    // Include this plan before writing so a failed read-back is also rolled back.
                    completed.append(plan)
                    try write(plan.after, file: plan.file, permissions: plan.before.permissions)
                    guard try read(plan.file).data == plan.after else { throw GestaltFailure("System settings could not be verified after writing.") }
                    event("[system-settings] " + plan.file.rawValue + ": write verified")
                }
            } catch {
                var rollbackFailed = false
                for plan in completed.reversed() {
                    do {
                        let current = try read(plan.file)
                        if current.data == plan.before.data { continue }
                        guard current.data == plan.after else { rollbackFailed = true; continue }
                        try write(plan.before.data, file: plan.file, permissions: plan.before.permissions)
                        if try read(plan.file).data != plan.before.data { rollbackFailed = true }
                    } catch { rollbackFailed = true }
                }
                event(rollbackFailed ? "[system-settings] Rollback incomplete; retained backups and originals" : "[system-settings] Changes rolled back")
                if rollbackFailed { throw GestaltFailure("Some settings could not be restored automatically. Read them again and use Revert.") }
                throw error
            }
        }
        return try load()
    }
}
