// SPDX-License-Identifier: GPL-3.0-only
import Foundation

actor CustomizationStore {
    private let storage: URL
    private let device: String
    private let resolver: (@Sendable (String) throws -> URL)?
    private let fm = FileManager.default
    init(storage: URL, device: String, resolver: (@Sendable (String) throws -> URL)? = nil) {
        self.storage = storage; self.device = device; self.resolver = resolver
    }
    private var wallpapers: URL { storage.appendingPathComponent("Wallpapers", isDirectory: true) }
    private func folder(_ id: UUID) -> URL { wallpapers.appendingPathComponent(id.uuidString, isDirectory: true) }
    private func manifest(_ id: UUID) -> URL { folder(id).appendingPathComponent("Pack.plist") }
    private func log(_ message: String) {
        NotificationCenter.default.post(name: Notification.Name("GestaltX.worse_query.log"), object: nil,
                                        userInfo: ["message": message])
    }
    private func access<T>(_ identifier: String, _ operation: (URL) throws -> T) throws -> T {
        if let resolver { return try operation(resolver(identifier)) }
        #if os(iOS) && !targetEnvironment(simulator)
        guard let path = GXCustomizationAccess.container(for: identifier) else {
            throw CustomizationFailure("The device container could not be located. Read again.")
        }
        let handle = GXCustomizationAccess.acquirePath(path)
        guard handle >= 0 else { throw CustomizationFailure("These system settings are not accessible on this device.") }
        defer { worse_query_release(handle) }
        return try operation(URL(fileURLWithPath: path, isDirectory: true))
        #else
        throw CustomizationFailure("Device access is unavailable in the Simulator. Open a plist to explore GestaltX.")
        #endif
    }
    func listWallpapers() throws -> [WallpaperPack] {
        try fm.createDirectory(at: wallpapers, withIntermediateDirectories: true)
        return try fm.contentsOfDirectory(at: wallpapers, includingPropertiesForKeys: nil).compactMap { url in
            guard let id = UUID(uuidString: url.lastPathComponent) else { return nil }
            return try loadPack(id)
        }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
    private func loadPack(_ id: UUID) throws -> WallpaperPack {
        try decodePack(Data(contentsOf: manifest(id)), id: id)
    }
    private func decodePack(_ data: Data, id: UUID) throws -> WallpaperPack {
        let pack = try PropertyListDecoder().decode(WallpaperPack.self, from: data)
        guard pack.id == id else { throw CustomizationFailure("The archive contains unsafe paths or links.") }
        return pack
    }
    private func savePack(_ pack: WallpaperPack) throws {
        try CustomizationFiles.saveVerified(pack, to: manifest(pack.id))
    }
    private func installationRecordsURL(_ id: UUID) throws -> URL {
        try CustomizationFiles.checked("WallpaperInstallations/\(id.uuidString).plist", in: storage, missing: true)
    }
    private func installationRecords(_ id: UUID) throws -> [Data] {
        let url = try installationRecordsURL(id)
        guard fm.fileExists(atPath: url.path) else { return [] }
        let records = try PropertyListDecoder().decode([Data].self, from: CustomizationFiles.read(url))
        for record in records { _ = try decodePack(record, id: id) }
        return records
    }
    func deleteImportedWallpaper(_ id: UUID) throws {
        let directory = try CustomizationFiles.checked("Wallpapers/\(id.uuidString)", in: storage, missing: true)
        guard fm.fileExists(atPath: directory.path) else { return }
        let data = try CustomizationFiles.read(CustomizationFiles.checked("Pack.plist", in: directory))
        let pack = try decodePack(data, id: id)
        if !pack.installations.isEmpty || pack.installedDevice != nil {
            var records = try installationRecords(id)
            if !records.contains(data) {
                // Keep complete manifests, including unknown fields and interrupted installations.
                // Multiple snapshots retain ownership if a share receipt reimports the same UUID.
                records.append(data)
                try CustomizationFiles.saveVerified(records, to: installationRecordsURL(id))
            }
        }
        try fm.removeItem(at: directory)
        log("Wallpapers: deleted the imported pack; applied wallpapers and installation records were kept.")
    }
    func importWallpaper(_ source: URL, id: UUID = UUID()) throws -> [WallpaperPack] {
        // Retrying a durable share receipt after interruption must not duplicate
        // an already imported pack. The library is only published when complete.
        if fm.fileExists(atPath: manifest(id).path) { _ = try loadPack(id); return try listWallpapers() }
        let temporary = fm.temporaryDirectory.appendingPathComponent("GX-Wallpaper-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: temporary) }
        try CustomizationArchive.extract(source, into: temporary)
        let descriptors = try WallpaperPackages.descriptors(in: temporary)
        let destination = folder(id)
        try fm.createDirectory(at: wallpapers, withIntermediateDirectories: true)
        let staging = wallpapers.appendingPathComponent(".import-\(UUID().uuidString)", isDirectory: true)
        var saved = false
        defer { if !saved { try? fm.removeItem(at: staging) } }
        try fm.createDirectory(at: staging, withIntermediateDirectories: false)
        var pack = WallpaperPack(id: id, name: source.deletingPathExtension().lastPathComponent, descriptors: [])
        for (sourceFolder, provider) in descriptors {
            let name = UUID().uuidString
            let target = staging.appendingPathComponent(name)
            try fm.copyItem(at: sourceFolder, to: target)
            if provider != .mercury { try WallpaperPackages.randomize(target) }
            let files = try CustomizationFiles.tree(target)
            guard !files.isEmpty else { throw CustomizationFailure("This pack contains no compatible wallpapers.") }
            pack.descriptors.append(.init(folder: name, provider: provider))
            if pack.preview == nil, let image = try CustomizationImages.thumbnail(in: target) {
                try image.write(to: staging.appendingPathComponent("Preview.png"), options: .atomic)
                pack.preview = "Preview.png"
            }
        }
        try CustomizationFiles.saveVerified(pack, to: staging.appendingPathComponent("Pack.plist"))
        try fm.moveItem(at: staging, to: destination); saved = true
        log("Wallpapers: imported \(pack.descriptors.count) descriptor(s).")
        return try listWallpapers()
    }
    func wallpaperPreview(_ id: UUID) throws -> Data? {
        guard let name = try loadPack(id).preview else { return nil }
        return try CustomizationFiles.read(CustomizationFiles.checked(name, in: folder(id)))
    }
    private func stageURL(_ relative: String, root: URL) throws -> URL {
        let target = try installationURL(relative, root: root)
        return target.deletingLastPathComponent().appendingPathComponent(".GestaltX-stage-\(target.lastPathComponent)")
    }
    private func installationURL(_ relative: String, root: URL) throws -> URL {
        let pieces = relative.split(separator: "/").map(String.init)
        guard pieces.count == 8, Array(pieces[0...2]) == ["Library", "Application Support", "PRBPosterExtensionDataStore"],
              Int(pieces[3]) != nil, pieces[4] == "Extensions", pieces[6] == "descriptors",
              WallpaperProvider.collections.identifiers.contains(pieces[5]) || WallpaperProvider.mercury.identifiers.contains(pieces[5]) || WallpaperProvider.video.identifiers.contains(pieces[5]),
              UUID(uuidString: pieces[7]) != nil else { throw CustomizationFailure("The archive contains unsafe paths or links.") }
        return try CustomizationFiles.checked(relative, in: root, missing: true)
    }
    private func removeInstallation(_ entry: WallpaperInstallation, root: URL) throws {
        for url in [try installationURL(entry.relative, root: root), try stageURL(entry.relative, root: root)] {
            guard fm.fileExists(atPath: url.path) else { continue }
            let actual = try CustomizationFiles.tree(url)
            guard actual.allSatisfy({ entry.files[$0.key] == $0.value }),
                  !entry.committed || actual == entry.files else {
                throw CustomizationFailure("This wallpaper was changed outside GestaltX. It was not removed.")
            }
            try fm.removeItem(at: url)
        }
    }
    func applyWallpaper(_ id: UUID) throws -> [WallpaperPack] {
        var pack = try loadPack(id)
        guard pack.installations.isEmpty else { return try listWallpapers() }
        pack.installedDevice = device
        try access("com.apple.PosterBoard") { root in
            do {
                for descriptor in pack.descriptors {
                    guard UUID(uuidString: descriptor.folder) != nil else { throw CustomizationFailure("The archive contains unsafe paths or links.") }
                    let source = try CustomizationFiles.checked(descriptor.folder, in: folder(id))
                    let hashes = try CustomizationFiles.tree(source)
                    for providerPath in try WallpaperPackages.providerPaths(in: root, provider: descriptor.provider) {
                        let relative = providerPath + "/" + UUID().uuidString
                        let target = try installationURL(relative, root: root)
                        let stage = try stageURL(relative, root: root)
                        guard !fm.fileExists(atPath: target.path), !fm.fileExists(atPath: stage.path) else {
                            throw CustomizationFailure("The files changed. Read again before applying.")
                        }
                        // Persist ownership before touching the device, including interrupted copies.
                        pack.installations.append(.init(relative: relative, files: hashes))
                        try savePack(pack)
                        try fm.copyItem(at: source, to: stage)
                        guard try CustomizationFiles.tree(stage) == hashes else {
                            throw CustomizationFailure("The files changed. Read again before applying.")
                        }
                        try fm.moveItem(at: stage, to: target)
                        pack.installations[pack.installations.count-1].committed = true
                        try savePack(pack)
                    }
                }
                try refreshPosterBoard(root)
            } catch {
                let originalError = error
                var remaining: [WallpaperInstallation] = []
                for entry in pack.installations {
                    do { try removeInstallation(entry, root: root) } catch { remaining.append(entry) }
                }
                pack.installations = remaining
                try savePack(pack)
                if !remaining.isEmpty { throw CustomizationFailure("Some files could not be restored. The backup has been kept.") }
                throw originalError
            }
        }
        log("Wallpapers: installed and verified \(pack.installations.count) descriptor folder(s).")
        return try listWallpapers()
    }
    private func refreshPosterBoard(_ root: URL) throws {
        let path = "Library/Preferences/com.apple.PosterBoard.unprotectedUserDefaults.plist"
        let url = try CustomizationFiles.checked(path, in: root, missing: true)
        var values: [String: Any] = [:]
        var before = CustomizationOriginal(data: nil)
        if fm.fileExists(atPath: url.path) {
            let data = try CustomizationFiles.read(url)
            guard let dictionary = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else {
                throw CustomizationFailure("The files changed. Read again before applying.")
            }
            values = dictionary; before = .init(data: data)
        }
        // Gester's refresh flag, merged into existing preferences instead of replacing them.
        values["PBF_RESET_FILE_PROTECTIONS"] = true
        let data = try PropertyListSerialization.data(fromPropertyList: values, format: .binary, options: 0)
        let writer = CustomizationFileTransaction(root: root, storage: storage.appendingPathComponent("PosterBoardDefaults"), device: device)
        try writer.replace([path: data], expected: [path: before])
    }
    func removeWallpaper(_ id: UUID) throws -> [WallpaperPack] {
        let directory = try CustomizationFiles.checked("Wallpapers/\(id.uuidString)", in: storage, missing: true)
        let hasImport = fm.fileExists(atPath: directory.path)
        let imported = hasImport ? try loadPack(id) : nil
        var packs = try installationRecords(id).map { try decodePack($0, id: id) }
        if let imported { packs.append(imported) }
        guard !packs.isEmpty else { throw CocoaError(.fileReadNoSuchFile) }
        var installations: [WallpaperInstallation] = []
        for pack in packs where !pack.installations.isEmpty {
            guard pack.installedDevice == device else { throw CustomizationFailure("The files changed. Read again before applying.") }
            for entry in pack.installations {
                if let index = installations.firstIndex(where: { $0.relative == entry.relative }) {
                    guard installations[index].files == entry.files else {
                        throw CustomizationFailure("This wallpaper was changed outside GestaltX. It was not removed.")
                    }
                    installations[index].committed = installations[index].committed || entry.committed
                } else {
                    installations.append(entry)
                }
            }
        }
        if !installations.isEmpty {
            try access("com.apple.PosterBoard") { root in
                // Validate every installed folder before deleting the first one.
                for entry in installations {
                    let url = try installationURL(entry.relative, root: root)
                    if fm.fileExists(atPath: url.path), try CustomizationFiles.tree(url) != entry.files, entry.committed {
                        throw CustomizationFailure("This wallpaper was changed outside GestaltX. It was not removed.")
                    }
                }
                for entry in installations { try removeInstallation(entry, root: root) }
            }
        }
        if var pack = imported {
            pack.installations = []
            try savePack(pack)
        }
        let recordsURL = try installationRecordsURL(id)
        if fm.fileExists(atPath: recordsURL.path) { try fm.removeItem(at: recordsURL) }
        if hasImport { try fm.removeItem(at: directory) }
        log("Wallpapers: removed only this pack's tracked additions.")
        return try listWallpapers()
    }
}
