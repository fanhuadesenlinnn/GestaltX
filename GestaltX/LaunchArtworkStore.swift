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
        guard record.version == 1, record.device == device, record.app == app.id, record.files.count <= 16,
              record.files.keys.allSatisfy(LaunchArtworkDirectory.validName),
              record.files.values.allSatisfy({ $0.mode <= 0o777 && $0.original.count <= LaunchArtworkDirectory.maximumFile
                  && CustomizationFiles.digest($0.original) == $0.originalHash && (try? LaunchArtworkImages.dimensions($0.original)) != nil }),
              record.files.values.reduce(0, { $0 + $1.original.count }) <= 64 * 1024 * 1024 else { throw changed }
        return record
    }
    func state(_ app: LaunchArtworkApp) throws -> LaunchArtworkState {
        try access(app) { container, directory in
            let names = try directory.names(), record = try load(app)
            var canRestore = false, preview: Data?, width = 1, height = 2
            for name in names {
                guard let file = try directory.read(name) else { continue }
                let size = try LaunchArtworkImages.dimensions(file.data)
                if preview == nil { preview = LaunchArtworkImages.preview(file.data); width = size.width; height = size.height }
                if record?.container == container.lastPathComponent,
                   let saved = record?.files[name], CustomizationFiles.digest(file.data) == saved.expected,
                   file.data != saved.original { canRestore = true }
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
            let names = try directory.names()
            guard !names.isEmpty else { throw CustomizationFailure("No launch images found. Open the app once, close it, then read again.") }
            let old = try load(app)
            var before: [String: LaunchArtworkDirectory.File] = [:], replacements: [String: Data] = [:], originals: [String: Saved] = [:]
            var total = 0, encodedTotal = 0
            for name in names {
                guard let file = try directory.read(name) else { throw changed }
                total += file.data.count
                guard total <= 64 * 1024 * 1024 else { throw changed }
                let size = try LaunchArtworkImages.dimensions(file.data)
                let png = try LaunchArtworkImages.render(photo, width: size.width, height: size.height)
                guard png.count <= LaunchArtworkDirectory.maximumFile else {
                    throw CustomizationFailure("This image could not be used. Choose another image.")
                }
                encodedTotal += png.count
                guard encodedTotal <= 64 * 1024 * 1024 else {
                    throw CustomizationFailure("This image could not be used. Choose another image.")
                }
                let previous = old?.container == container.lastPathComponent ? old?.files[name] : nil
                let tracked = previous.map { CustomizationFiles.digest(file.data) == $0.expected || file.data == $0.original } ?? false
                let original = tracked ? previous!.original : file.data
                originals[name] = Saved(original: original, originalHash: CustomizationFiles.digest(original), expected: CustomizationFiles.digest(png),
                                       mode: tracked ? previous!.mode : UInt16(file.mode), protection: tracked ? previous!.protection : file.protection)
                before[name] = file; replacements[name] = png
            }
            let next = Record(version: 1, device: device, app: app.id, container: container.lastPathComponent, files: originals)
            try backup(before, app: app)
            if let old { try CustomizationFiles.saveVerified(old, to: history(app)) }
            // Record all original bytes and intended hashes before the first write.
            try CustomizationFiles.saveVerified(next, to: recordURL(app))
            try commit(replacements, before: before, directory: directory, app: app, old: old)
            log("Launch images: applied \(replacements.count) image(s).")
            return replacements.count
        }
    }
    func restore(_ app: LaunchArtworkApp) throws -> Int {
        try access(app) { container, directory in
            guard let record = try load(app) else { return 0 }
            guard record.container == container.lastPathComponent else {
                throw CustomizationFailure("The app was reinstalled. Its saved launch images cannot be restored.")
            }
            var before: [String: LaunchArtworkDirectory.File] = [:], replacements: [String: Data] = [:]
            for (name, saved) in record.files {
                // Missing/rebuilt snapshots belong to iOS. Never recreate them or
                // replace newly generated content with a stale cache generation.
                guard let file = try directory.read(name), CustomizationFiles.digest(file.data) == saved.expected,
                      file.data != saved.original else { continue }
                before[name] = file; replacements[name] = saved.original
            }
            try backup(before, app: app)
            try CustomizationFiles.saveVerified(record, to: history(app))
            try commit(replacements, before: before, directory: directory, app: app, old: record, restoring: record.files)
            try fm.removeItem(at: recordURL(app))
            log("Launch images: restored \(replacements.count) image(s); refreshed system files left unchanged.")
            return replacements.count
        }
    }
    private func history(_ app: LaunchArtworkApp) -> URL {
        storage.appendingPathComponent(app.id).appendingPathComponent("Backups/\(UUID().uuidString).plist")
    }
    private func backup(_ files: [String: LaunchArtworkDirectory.File], app: LaunchArtworkApp) throws {
        try CustomizationFiles.saveVerified(files.mapValues { CustomizationOriginal(data: $0.data) }, to: history(app))
    }
    private func commit(_ replacements: [String: Data], before: [String: LaunchArtworkDirectory.File], directory: LaunchArtworkDirectory,
                        app: LaunchArtworkApp, old: Record?, restoring: [String: Saved] = [:]) throws {
        var written: [String] = []
        do {
            for name in replacements.keys.sorted() {
                try beforeWrite?()
                written.append(name)
                try directory.replace(name, expected: before[name]!, data: replacements[name]!,
                                      protection: restoring[name]?.protection, mode: restoring[name].map { mode_t($0.mode) })
            }
        } catch {
            var recovered = true
            for name in written.reversed() {
                do {
                    guard let current = try directory.read(name) else { continue }
                    if current.data == before[name]!.data { continue }
                    guard current.data == replacements[name] else { continue }
                    try directory.replace(name, expected: current, data: before[name]!.data,
                                          protection: before[name]!.protection, mode: before[name]!.mode)
                } catch { recovered = false }
            }
            if recovered {
                if let old { try CustomizationFiles.saveVerified(old, to: recordURL(app)) }
                else if fm.fileExists(atPath: recordURL(app).path) { try fm.removeItem(at: recordURL(app)) }
            } else { throw CustomizationFailure("Some files could not be restored. The backup has been kept.") }
            throw error
        }
    }
    private var changed: CustomizationFailure { CustomizationFailure("The files changed. Read again before applying.") }
    private func log(_ message: String) {
        NotificationCenter.default.post(name: Notification.Name("GestaltX.worse_query.log"), object: nil, userInfo: ["message": message])
    }
}
