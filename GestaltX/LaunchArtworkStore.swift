// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import Darwin

struct LaunchArtworkApp: Identifiable, Hashable, Codable, Sendable {
    let id: String
    let name: String
    var byteCount: Int64 = 0
}
struct LaunchArtworkState: Sendable {
    let count: Int
    let canRestore: Bool
    let preview: Data?
    let width: Int
    let height: Int
}

actor LaunchArtworkStore {
    struct Saved: Codable {
        let original: Data
        let originalHash: String
        let expected: String
        let mode: UInt16
        let protection: Int32?
    }
    struct Record: Codable {
        let version: Int
        let device: String
        let app: String
        let container: String
        var files: [String: Saved]
    }
    private let storage: URL
    private let device: String
    private let resolver: (@Sendable (LaunchArtworkApp) throws -> URL)?
    private let beforeWrite: (@Sendable () throws -> Void)?
    private let fm = FileManager.default
    init(storage: URL, device: String, resolver: (@Sendable (LaunchArtworkApp) throws -> URL)? = nil,
         beforeWrite: (@Sendable () throws -> Void)? = nil) {
        self.storage = storage; self.device = device; self.resolver = resolver; self.beforeWrite = beforeWrite
    }
    func applications() -> [LaunchArtworkApp] {
        #if os(iOS) && !targetEnvironment(simulator)
        return GXCustomizationAccess.launchApplications().compactMap {
            guard let identifier = $0["identifier"], let name = $0["name"] else { return nil }
            return LaunchArtworkApp(id: identifier, name: name)
        }
        #else
        return []
        #endif
    }
    private func access<T>(_ app: LaunchArtworkApp, _ operation: (URL, LaunchArtworkDirectory) throws -> T) throws -> T {
        guard !device.isEmpty, LaunchArtworkDirectory.validIdentifier(app.id) else { throw changed }
        let folder = storage.appendingPathComponent(app.id, isDirectory: true)
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        let lease = open(folder.appendingPathComponent(".writer.lock").path, O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard lease >= 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        defer { close(lease) }
        guard flock(lease, LOCK_EX | LOCK_NB) == 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        let container: URL
        var handle: Int64 = -1
        if let resolver { container = try resolver(app) }
        else {
            #if os(iOS) && !targetEnvironment(simulator)
            guard let path = GXCustomizationAccess.launchContainer(for: app.id) else {
                throw CustomizationFailure("The device container could not be located. Read again.")
            }
            container = URL(fileURLWithPath: path, isDirectory: true)
            if app.id != Bundle.main.bundleIdentifier {
                handle = GXCustomizationAccess.acquirePath(path)
                guard handle >= 0 else { throw CustomizationFailure("These system settings are not accessible on this device.") }
            }
            #else
            throw CustomizationFailure("Device access is unavailable in the Simulator. Open a plist to explore GestaltX.")
            #endif
        }
        defer {
            #if os(iOS) && !targetEnvironment(simulator)
            if handle >= 0 { worse_query_release(handle) }
            #endif
        }
        return try operation(container, LaunchArtworkDirectory(container: container, identifier: app.id))
    }
    private func recordURL(_ app: LaunchArtworkApp) -> URL { storage.appendingPathComponent(app.id).appendingPathComponent("Originals.plist") }
    private func load(_ app: LaunchArtworkApp) throws -> Record? {
        let url = recordURL(app)
        guard fm.fileExists(atPath: url.path) else { return nil }
        let record = try PropertyListDecoder().decode(Record.self, from: CustomizationFiles.read(url))
        guard record.version == 1, record.app == app.id, record.files.count <= 16,
              record.files.keys.allSatisfy(LaunchArtworkDirectory.validName),
              record.files.values.allSatisfy({ $0.mode <= 0o777 && $0.original.count <= LaunchArtworkDirectory.maximumFile
                  && CustomizationFiles.digest($0.original) == $0.originalHash && (try? LaunchArtworkImages.dimensions($0.original)) != nil }),
              record.files.values.reduce(0, { $0 + $1.original.count }) <= 64 * 1024 * 1024 else { throw changed }
        return record
    }
    private func migrateLegacy(_ app: LaunchArtworkApp, container: URL, directory: LaunchArtworkDirectory) throws {
        if let record = try load(app) {
            guard record.container == container.lastPathComponent else { return }
            // Every original gets its own sibling .bak, including snapshots that
            // iOS has removed. A new cache generation is not made restorable.
            for (name, saved) in record.files { try directory.migrateBackup(name, saved: saved) }
            let archived = try CustomizationFiles.read(recordURL(app))
            try directory.archiveLegacy("Originals-" + CustomizationFiles.digest(archived) + ".plist", data: archived)
            try fm.removeItem(at: recordURL(app))
            log("Launch images: migrated \(record.files.count) original(s) to sibling .bak files.")
        }
        // Preserve old history outside GestaltX too. No new history is written
        // here; this directory exists only for upgrades from older releases.
        let history = storage.appendingPathComponent(app.id).appendingPathComponent("Backups")
        if fm.fileExists(atPath: history.path) {
            let values = try history.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey])
            guard values.isSymbolicLink != true, values.isDirectory == true else { throw changed }
            for file in try fm.contentsOfDirectory(at: history, includingPropertiesForKeys: nil) {
                guard file.pathExtension == "plist", UUID(uuidString: file.deletingPathExtension().lastPathComponent) != nil else { throw changed }
                let data = try CustomizationFiles.read(file)
                try directory.archiveLegacy(file.lastPathComponent, data: data)
                try fm.removeItem(at: file)
            }
            try fm.removeItem(at: history)
        }
    }
    /// Run on upgrade and retry when the relevant app is opened. Failed items
    /// remain in the old location; an unrelated app cannot receive their bytes.
    func migrateLegacyBackups() {
        guard let folders = try? fm.contentsOfDirectory(at: storage, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey]) else { return }
        for folder in folders where LaunchArtworkDirectory.validIdentifier(folder.lastPathComponent) {
            do {
                try Task.checkCancellation()
                let values = try folder.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                guard values.isDirectory == true, values.isSymbolicLink != true else { continue }
                let app = LaunchArtworkApp(id: folder.lastPathComponent, name: folder.lastPathComponent)
                let legacy = try load(app)
                #if os(iOS) && !targetEnvironment(simulator)
                if resolver == nil {
                    let hint = legacy.map { "/private/var/mobile/Containers/Data/Application/" + $0.container }
                    guard GXCustomizationAccess.applicationContainer(for: app.id, hint: hint) != nil else { continue }
                }
                #endif
                try access(app) { container, directory in try migrateLegacy(app, container: container, directory: directory) }
            } catch { log("Launch images: backup migration deferred for \(folder.lastPathComponent): \(error.localizedDescription)") }
        }
    }
    func state(_ app: LaunchArtworkApp) throws -> LaunchArtworkState {
        try access(app) { container, directory in
            try migrateLegacy(app, container: container, directory: directory)
            let names = try directory.names()
            var canRestore = false, preview: Data?, width = 1, height = 2
            for name in names {
                guard let file = try directory.read(name) else { continue }
                let size = try LaunchArtworkImages.dimensions(file.data)
                if preview == nil { preview = LaunchArtworkImages.preview(file.data); width = size.width; height = size.height }
                if let saved = try directory.original(name), saved.matches(file.data), file.data != saved.data { canRestore = true }
            }
            return LaunchArtworkState(count: names.count, canRestore: canRestore, preview: preview, width: width, height: height)
        }
    }
    func currentImage(_ app: LaunchArtworkApp) throws -> Data {
        try access(app) { _, directory in
            for name in try directory.names() {
                if let file = try directory.read(name), let png = LaunchArtworkImages.export(file.data) { return png }
            }
            throw CustomizationFailure("No launch images found. Open the app once, close it, then read again.")
        }
    }
    func apply(_ photo: Data, to app: LaunchArtworkApp) throws -> Int {
        try access(app) { container, directory in
            try migrateLegacy(app, container: container, directory: directory)
            let names = try directory.names()
            guard !names.isEmpty else { throw CustomizationFailure("No launch images found. Open the app once, close it, then read again.") }
            var before: [String: LaunchArtworkDirectory.File] = [:], replacements: [String: Data] = [:]
            var total = 0, encodedTotal = 0
            for name in names {
                guard let file = try directory.read(name) else { throw changed }
                total += file.data.count
                guard total <= 64 * 1024 * 1024 else { throw changed }
                let size = try LaunchArtworkImages.dimensions(file.data)
                let png = try LaunchArtworkImages.render(photo, width: size.width, height: size.height)
                encodedTotal += png.count
                guard png.count <= LaunchArtworkDirectory.maximumFile, encodedTotal <= 64 * 1024 * 1024 else {
                    throw CustomizationFailure("This image could not be used. Choose another image.")
                }
                before[name] = file; replacements[name] = png
            }
            // Publish and verify every original before touching any target.
            for name in names { try directory.backup(name, file: before[name]!, replacement: replacements[name]!) }
            try commit(replacements, before: before, directory: directory)
            log("Launch images: applied \(replacements.count) image(s); originals kept beside the files.")
            return replacements.count
        }
    }
    func restore(_ app: LaunchArtworkApp) throws -> Int {
        try access(app) { container, directory in
            try migrateLegacy(app, container: container, directory: directory)
            var before: [String: LaunchArtworkDirectory.File] = [:], replacements: [String: Data] = [:]
            var originals: [String: ContainerOriginals.Backup] = [:]
            for name in try directory.names() {
                guard let file = try directory.read(name), let saved = try directory.original(name),
                      saved.matches(file.data), saved.data != file.data else { continue }
                _ = try LaunchArtworkImages.dimensions(saved.data)
                before[name] = file; replacements[name] = saved.data; originals[name] = saved
            }
            try commit(replacements, before: before, directory: directory, restoring: originals)
            log("Launch images: restored \(replacements.count) image(s); sibling backups retained.")
            return replacements.count
        }
    }
    private func commit(_ replacements: [String: Data], before: [String: LaunchArtworkDirectory.File], directory: LaunchArtworkDirectory,
                        restoring: [String: ContainerOriginals.Backup] = [:]) throws {
        var written: [String] = []
        do {
            for name in replacements.keys.sorted() {
                try beforeWrite?()
                written.append(name)
                try directory.replace(name, expected: before[name]!, data: replacements[name]!,
                                      protection: restoring[name]?.protection, mode: restoring[name]?.mode)
            }
        } catch {
            var recovered = true
            for name in written.reversed() {
                do {
                    guard let current = try directory.read(name), current.data == replacements[name] else { continue }
                    try directory.replace(name, expected: current, data: before[name]!.data,
                                          protection: before[name]!.protection, mode: before[name]!.mode)
                } catch { recovered = false }
            }
            if !recovered { throw CustomizationFailure("Some files could not be restored. The backup has been kept.") }
            throw error
        }
    }
    private var changed: CustomizationFailure { CustomizationFailure("The files changed. Read again before applying.") }
    private func log(_ message: String) {
        NotificationCenter.default.post(name: Notification.Name("GestaltX.worse_query.log"), object: nil, userInfo: ["message": message])
    }
}
