// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import ImageIO

@main enum CustomizationTests {
    static let fm = FileManager.default
    static func require(_ condition: @autoclosure () throws -> Bool, _ reason: String) throws {
        if try !condition() { throw NSError(domain: "CustomizationTests", code: 1, userInfo: [NSLocalizedDescriptionKey: reason]) }
    }
    static func rejects(_ operation: () throws -> Void) throws {
        do { try operation() } catch { return }
        throw NSError(domain: "CustomizationTests", code: 2, userInfo: [NSLocalizedDescriptionKey: "Unsafe operation was accepted"])
    }
    static func main() async throws {
        let fixtures = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        let root = fm.temporaryDirectory.appendingPathComponent("GX-CustomizationTests-\(UUID().uuidString)")
        try fm.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? fm.removeItem(at: root) }
        let archiveRoot = root.appendingPathComponent("valid")
        try CustomizationArchive.extract(fixtures.appendingPathComponent("valid.zip"), into: archiveRoot)
        let descriptors = try WallpaperPackages.descriptors(in: archiveRoot)
        try require(descriptors.count == 1 && descriptors[0].1 == .collections, "Valid pack/provider not recognized")
        let descriptor = descriptors[0].0
        let identifierFile = descriptor.appendingPathComponent("com.apple.posterkit.provider.descriptor.identifier")
        try WallpaperPackages.randomize(descriptor)
        let identifier = String(data: try Data(contentsOf: identifierFile), encoding: .utf8)!
        let plist = try PropertyListSerialization.propertyList(from: Data(contentsOf: descriptor.appendingPathComponent("Wallpaper.plist")), format: nil) as! [String: Any]
        try require(String(plist["identifier"] as! Int) == identifier && identifier != "123", "Descriptor references were not randomized together")
        for name in ["traversal", "absolute", "backslash", "symlink", "case-collision", "oversize", "bad-crc"] {
            let destination = root.appendingPathComponent(name)
            try rejects { try CustomizationArchive.extract(fixtures.appendingPathComponent(name + ".zip"), into: destination) }
            try require(!fm.fileExists(atPath: destination.path), "Rejected archive left extracted content")
        }
        try require(!fm.fileExists(atPath: root.appendingPathComponent("escaped").path), "ZIP traversal escaped root")
        let device = root.appendingPathComponent("Device")
        let journal = root.appendingPathComponent("Journal")
        try fm.createDirectory(at: device, withIntermediateDirectories: false)
        let original = Data("original bytes".utf8), replacement = Data("new bytes".utf8)
        try original.write(to: device.appendingPathComponent("existing.png"))
        let transaction = CustomizationFileTransaction(root: device, storage: journal, device: "this-device")
        try transaction.replace(["existing.png": replacement, "added.png": replacement])
        try require(transaction.hasChanges, "Applied state not detected")
        try require(try Data(contentsOf: device.appendingPathComponent("existing.png")) == replacement, "Replacement failed")
        let reopened = CustomizationFileTransaction(root: device, storage: journal, device: "this-device")
        try reopened.restore()
        try require(try Data(contentsOf: device.appendingPathComponent("existing.png")) == original, "Original not restored after reopen")
        try require(!fm.fileExists(atPath: device.appendingPathComponent("added.png").path), "Originally absent file not removed")
        try require(!reopened.hasChanges, "Reset state remains modified")
        try rejects { try CustomizationFileTransaction(root: device, storage: journal, device: "other-device").restore() }
        try rejects { try transaction.replace(["existing.png": replacement], expected: ["existing.png": .init(data: Data("stale".utf8))]) }
        try require(try Data(contentsOf: device.appendingPathComponent("existing.png")) == original, "Stale input changed target")
        var calls = 0
        let injected = CustomizationFileTransaction(root: device, storage: root.appendingPathComponent("Rollback"), device: "this-device", beforeWrite: {
            calls += 1
            if calls == 2 { throw CocoaError(.fileWriteUnknown) }
        })
        try rejects { try injected.replace(["existing.png": replacement, "later.png": replacement]) }
        try require(try Data(contentsOf: device.appendingPathComponent("existing.png")) == original, "Interrupted transaction did not roll back")
        try require(!fm.fileExists(atPath: device.appendingPathComponent("later.png").path), "Interrupted transaction left a new file")
        let outside = root.appendingPathComponent("outside")
        try original.write(to: outside)
        try fm.createSymbolicLink(at: device.appendingPathComponent("link"), withDestinationURL: outside)
        try rejects { try transaction.replace(["link": replacement]) }
        try require(try Data(contentsOf: outside) == original, "Symbolic link target changed")
        try fm.createSymbolicLink(at: device.appendingPathComponent("broken"), withDestinationURL: root.appendingPathComponent("missing"))
        try rejects { try transaction.replace(["broken": replacement]) }
        try require(!fm.fileExists(atPath: root.appendingPathComponent("missing").path), "Broken symlink followed")
        let base = device.appendingPathComponent("Library/Application Support/PRBPosterExtensionDataStore")
        for version in ["61", "75"] {
            try fm.createDirectory(at: base.appendingPathComponent(version + "/Extensions/com.apple.MercuryPoster/descriptors"), withIntermediateDirectories: true)
        }
        let providerPaths = try WallpaperPackages.providerPaths(in: device, provider: .mercury)
        try require(providerPaths.count == 1 && providerPaths[0].contains("/75/"), "Wallpaper store version was hardcoded")
        try await storeTests(root: root, fixtures: fixtures)
        print("Customization tests passed: archive containment/CRC/limits, descriptor IDs, dynamic store versions, original absence, reopen/restore, rollback, stale writes, device binding, symlinks and complete wallpaper transactions.")
    }
    static func storeTests(root: URL, fixtures: URL) async throws {
        let poster = root.appendingPathComponent("PosterBoard")
        let library = root.appendingPathComponent("Library")
        let provider = poster.appendingPathComponent("Library/Application Support/PRBPosterExtensionDataStore/61/Extensions/com.apple.WallpaperKit.CollectionsPoster/descriptors")
        let existing = provider.appendingPathComponent("existing/Original.bin")
        try fm.createDirectory(at: existing.deletingLastPathComponent(), withIntermediateDirectories: true)
        let untouched = Data("keep existing wallpaper".utf8)
        try untouched.write(to: existing)
        let prefs = poster.appendingPathComponent("Library/Preferences/com.apple.PosterBoard.unprotectedUserDefaults.plist")
        try fm.createDirectory(at: prefs.deletingLastPathComponent(), withIntermediateDirectories: true)
        let originalPrefs = try PropertyListSerialization.data(fromPropertyList: ["unrelated": "keep", "PBF_LOCALE_DID_CHANGE": true], format: .binary, options: 0)
        try originalPrefs.write(to: prefs)
        let store = CustomizationStore(storage: library, device: "this-device", resolver: { _ in poster })
        let receipt = UUID()
        let imported = try await store.importWallpaper(fixtures.appendingPathComponent("valid.zip"), id: receipt)
        try require(imported.count == 1 && !imported[0].isApplied, "Import changed the device")
        let retried = try await store.importWallpaper(fixtures.appendingPathComponent("valid.zip"), id: receipt)
        try require(retried.count == 1 && retried[0].id == receipt, "Retrying a share receipt duplicated the pack")
        let id = imported[0].id
        let applied = try await store.applyWallpaper(id)
        try require(applied[0].installations.count == 1 && applied[0].isApplied, "Wallpaper installation failed")
        try require(try Data(contentsOf: existing) == untouched, "Existing wallpaper changed")
        let merged = try PropertyListSerialization.propertyList(from: Data(contentsOf: prefs), format: nil) as! [String: Any]
        try require(merged["unrelated"] as? String == "keep" && merged["PBF_LOCALE_DID_CHANGE"] as? Bool == true, "Refresh replaced unrelated defaults")
        let twice = try await store.applyWallpaper(id)
        try require(twice[0].installations.count == 1, "Repeated Apply duplicated a wallpaper")
        let foreign = CustomizationStore(storage: library, device: "other-device", resolver: { _ in poster })
        var foreignRefused = false
        do { _ = try await foreign.removeWallpaper(id) } catch { foreignRefused = true }
        try require(foreignRefused, "Foreign-device installation records accepted")
        let target = poster.appendingPathComponent(applied[0].installations[0].relative)
        let identifier = target.appendingPathComponent("com.apple.posterkit.provider.descriptor.identifier")
        let installedBytes = try Data(contentsOf: identifier)
        try Data("externally changed".utf8).write(to: identifier)
        var changedRefused = false
        do { _ = try await store.removeWallpaper(id) } catch { changedRefused = true }
        try require(changedRefused && fm.fileExists(atPath: target.path), "Externally modified wallpaper was removed")
        try installedBytes.write(to: identifier)
        _ = try await store.removeWallpaper(id)
        try require(!fm.fileExists(atPath: target.path) && fm.fileExists(atPath: existing.path), "Removal affected unowned wallpapers")
        let next = try await store.importWallpaper(fixtures.appendingPathComponent("valid.zip"))
        try Data("invalid preferences".utf8).write(to: prefs)
        var failed = false
        do { _ = try await store.applyWallpaper(next[0].id) } catch { failed = true }
        let afterFailure = try await store.listWallpapers()
        try require(failed && afterFailure[0].installations.isEmpty, "Failed wallpaper operation left ownership records")
        try require(try fm.contentsOfDirectory(atPath: provider.path) == ["existing"], "Failed wallpaper operation left a descriptor/staging folder")
        try originalPrefs.write(to: prefs)
    }
}
