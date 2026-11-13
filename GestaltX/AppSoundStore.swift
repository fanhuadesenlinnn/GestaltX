// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import Darwin

struct AppSoundSelection: Sendable {
    let entry: AppSoundEntry
    let current: AppSoundDirectory.File
    let duration: Double
    let canRestore: Bool
}
actor AppSoundStore {
    private let storage: URL
    private let device: String
    private let resolver: (@Sendable (LaunchArtworkApp) throws -> URL)?
    private let groupResolver: (@Sendable (LaunchArtworkApp, String) throws -> URL)?
    private let groupInventory: (@Sendable (LaunchArtworkApp) -> [String])?
    init(storage: URL, device: String, resolver: (@Sendable (LaunchArtworkApp) throws -> URL)? = nil,
         groupResolver: (@Sendable (LaunchArtworkApp, String) throws -> URL)? = nil,
         groupInventory: (@Sendable (LaunchArtworkApp) -> [String])? = nil) {
        self.storage = storage; self.device = device; self.resolver = resolver
        self.groupResolver = groupResolver; self.groupInventory = groupInventory
    }
    private func access<T>(_ app: LaunchArtworkApp, group: String? = nil, _ body: (URL, AppSoundDirectory) throws -> T) throws -> T {
        guard !device.isEmpty, LaunchArtworkDirectory.validIdentifier(app.id) else { throw AppSoundDirectory.changed }
        let folder = storage.appendingPathComponent(app.id, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let lock = open(folder.appendingPathComponent(".writer.lock").path, O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard lock >= 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        defer { close(lock) }
        guard flock(lock, LOCK_EX | LOCK_NB) == 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        let container: URL
        var lease: Int64 = -1
        if let group, let groupResolver { container = try groupResolver(app, group) }
        else if group == nil, let resolver { container = try resolver(app) }
        else {
            #if os(iOS) && !targetEnvironment(simulator)
            let resolved: String?
            if let group { resolved = GXCustomizationAccess.applicationGroupContainers(for: app.id)[group] }
            else { resolved = GXCustomizationAccess.applicationContainer(for: app.id, hint: nil) }
            guard let path = resolved else {
                throw CustomizationFailure("The device container could not be located. Read again.")
            }
            container = URL(fileURLWithPath: path, isDirectory: true)
            if group != nil || app.id != Bundle.main.bundleIdentifier {
                lease = GXCustomizationAccess.acquirePath(path)
                guard lease >= 0 else { throw CustomizationFailure("The device container could not be located. Read again.") }
            }
            #else
            throw CustomizationFailure("Device access is unavailable in the Simulator. Open a plist to explore GestaltX.")
            #endif
        }
        defer {
            #if os(iOS) && !targetEnvironment(simulator)
            if lease >= 0 { worse_query_release(lease) }
            #endif
        }
        return try body(container, AppSoundDirectory(container: container))
    }
    func scan(_ app: LaunchArtworkApp) throws -> AppSoundDirectory.Scan {
        log("[Audio] scan \(app.id)")
        var files: [AppSoundEntry] = [], partial = false
        do { let scan = try access(app) { _, directory in try directory.scan() }; files = scan.files; partial = scan.partial }
        catch is CancellationError { throw CancellationError() }
        catch { partial = true }
        let groups: [String]
        if let groupInventory { groups = groupInventory(app) }
        else {
            #if os(iOS) && !targetEnvironment(simulator)
            groups = Array(GXCustomizationAccess.applicationGroupContainers(for: app.id).keys)
            #else
            groups = []
            #endif
        }
        for group in groups.sorted() {
            try Task.checkCancellation()
            do {
                let scan = try access(app, group: group) { _, directory in try directory.scan() }
                files.append(contentsOf: scan.files.map { var entry = $0; entry.group = group; return entry })
                partial = partial || scan.partial
            } catch is CancellationError { throw CancellationError() }
            catch { partial = true }
        }
        let result = AppSoundDirectory.Scan(files: files, partial: partial)
        log("[Audio] \(app.id): \(result.files.count) audio files, partial=\(result.partial)")
        return result
    }
    func select(_ entry: AppSoundEntry, app: LaunchArtworkApp) throws -> AppSoundSelection {
        try access(app, group: entry.group) { container, directory in
            let current = try directory.read(entry.path)
            guard current.device == entry.device, current.inode == entry.inode else { throw AppSoundDirectory.changed }
            let info = try AppSoundCodec.inspect(current.data, extension: (entry.path as NSString).pathExtension)
            let saved = try? directory.original(entry.path, app: app.id)
            return AppSoundSelection(entry: entry, current: current, duration: info.duration,
                                     // A verified sibling backup is enough to offer restore.
                                     // The app (or a previous edit) may legitimately have
                                     // changed the current bytes; the saved original is still
                                     // the thing the user asked to put back.
                                     canRestore: saved != nil || ledger(app.id).contains(entry.path))
        }
    }
    func prepare(_ url: URL, selection: AppSoundSelection) throws -> Data {
        let (data, suffix) = try readImport(url)
        return try AppSoundCodec.replacement(data, suffix: suffix, original: selection.current.data,
                                             targetSuffix: (selection.entry.path as NSString).pathExtension)
    }
    func prepareNamed(_ url: URL, name: String) throws -> Data {
        guard Self.validNewName(name) else { throw CustomizationFailure("Enter the notification sound's exact filename, including its extension.") }
        let (data, suffix) = try readImport(url)
        return try AppSoundCodec.namedReplacement(data, suffix: suffix, targetSuffix: (name as NSString).pathExtension)
    }
    static func validNewName(_ name: String) -> Bool {
        !name.hasPrefix(".") && name.utf8.count <= 200 && AppSoundDirectory.validPath("Library/Sounds/" + name)
    }
    /// Same-name overrides created by GestaltX have no original bytes. The
    /// sibling `.bak` marker is the primary record; this small ledger is a
    /// fallback if an app update or container migration drops that marker.
    private func ledger(_ app: String) -> Set<String> {
        let url = storage.appendingPathComponent(app, isDirectory: true).appendingPathComponent("named-overrides.plist")
        guard let data = try? Data(contentsOf: url),
              let paths = try? PropertyListDecoder().decode([String].self, from: data) else { return [] }
        return Set(paths)
    }
    private func markLedger(_ app: String, path: String, present: Bool) {
        var paths = ledger(app)
        if present { paths.insert(path) } else { paths.remove(path) }
        let url = storage.appendingPathComponent(app, isDirectory: true).appendingPathComponent("named-overrides.plist")
        guard let data = try? PropertyListEncoder().encode(Array(paths).sorted()) else { return }
        try? data.write(to: url, options: .atomic)
    }
    private func readImport(_ url: URL) throws -> (Data, String) {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let suffix = url.pathExtension.lowercased()
        guard AppSoundDirectory.importExtensions.contains(suffix) else { throw CustomizationFailure("This audio format is not supported.") }
        let info = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey])
        guard info.isRegularFile == true, info.isSymbolicLink != true, (info.fileSize ?? Int.max) <= AppSoundDirectory.maximumFile else {
            throw CustomizationFailure("Choose notification audio shorter than 30 seconds and smaller than 32 MB.")
        }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let data = try handle.read(upToCount: AppSoundDirectory.maximumFile + 1) ?? Data()
        guard data.count <= AppSoundDirectory.maximumFile else {
            throw CustomizationFailure("Choose notification audio shorter than 30 seconds and smaller than 32 MB.")
        }
        return (data, suffix)
    }
    func createNamed(_ name: String, data: Data, app: LaunchArtworkApp) throws {
        guard Self.validNewName(name) else { throw CustomizationFailure("Enter the notification sound's exact filename, including its extension.") }
        _ = try AppSoundCodec.inspect(data, extension: (name as NSString).pathExtension)
        try access(app) { _, directory in try directory.createNamedSound(name, app: app.id, data: data) }
        markLedger(app.id, path: "Library/Sounds/" + name, present: true)
        log("[Audio] named override saved: \(app.id)/\(name)")
    }
    func apply(_ data: Data, selection: AppSoundSelection, app: LaunchArtworkApp) throws {
        let suffix = (selection.entry.path as NSString).pathExtension
        let output = try AppSoundCodec.inspect(data, extension: suffix)
        let target = try AppSoundCodec.inspect(selection.current.data, extension: suffix)
        guard output.format == target.format, output.sampleRate == target.sampleRate, output.channels == target.channels else {
            throw CustomizationFailure("This audio format is not supported.")
        }
        try access(app, group: selection.entry.group) { container, directory in
            let path = selection.entry.path, current = try directory.read(path)
            guard current.device == selection.current.device, current.inode == selection.current.inode,
                  current.data == selection.current.data else { throw AppSoundDirectory.changed }
            try directory.backup(path, app: app.id, file: current, replacement: data)
            log("[Audio] sibling .bak verified; replacing \(app.id)/\(path)")
            try directory.replace(path, expected: current, data: data)
            log("[Audio] write verified \(app.id)/\(path)")
        }
    }
    func restore(_ selection: AppSoundSelection, app: LaunchArtworkApp) throws {
        try access(app, group: selection.entry.group) { container, directory in
            let path = selection.entry.path, current = try directory.read(path)
            let saved = try? directory.original(path, app: app.id)
            if saved == nil, ledger(app.id).contains(path) {
                // The marker was lost, but GestaltX created this same-name
                // override and knows the original state was "absent".
                try directory.removeAddedSound(path, expected: current)
                markLedger(app.id, path: path, present: false)
                log("[Audio] named override removed via ledger \(app.id)/\(path)")
                return
            }
            guard let saved else {
                throw CustomizationFailure("No saved original was found for this sound. The app may have replaced it after the last edit.")
            }
            if saved.originallyAbsent { try directory.removeAddedSound(path, expected: current) }
            else if current.data != saved.data { try directory.replace(path, expected: current, data: saved.data, mode: saved.mode, protection: saved.protection) }
            markLedger(app.id, path: path, present: false)
            log("[Audio] original restored \(app.id)/\(path)")
        }
    }
    private func log(_ message: String) {
        NotificationCenter.default.post(name: Notification.Name("GestaltX.worse_query.log"), object: nil, userInfo: ["message": message])
    }
}
