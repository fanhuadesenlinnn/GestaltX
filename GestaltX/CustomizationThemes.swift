// SPDX-License-Identifier: GPL-3.0-only
// Wallpaper descriptor conventions: Gester (MIT), Erosion (GPL-3.0).
// See Licenses/ThirdPartyNotices.txt for sources and complete licenses.
import Foundation
import ImageIO
import UniformTypeIdentifiers

enum WallpaperProvider: String, Codable, Sendable {
    case collections, mercury, video
    var identifiers: [String] {
        switch self {
        case .collections: return ["com.apple.WallpaperKit.CollectionsPoster", "com.apple.Posters.CollectionsPosterApp"]
        case .mercury: return ["com.apple.MercuryPoster"]
        case .video: return ["com.apple.PhotosUIPrivate.PhotosPosterProvider"]
        }
    }
}
struct WallpaperDescriptor: Codable, Sendable {
    var folder: String
    var provider: WallpaperProvider
}
struct WallpaperInstallation: Codable, Sendable {
    var relative: String
    var files: [String: String]
    var committed = false
}
struct WallpaperPack: Identifiable, Codable, Sendable {
    var id: UUID
    var name: String
    var descriptors: [WallpaperDescriptor]
    var preview: String?
    var installations: [WallpaperInstallation] = []
    var installedDevice: String?
    var isApplied: Bool { !installations.isEmpty }
}

enum WallpaperPackages {
    private static let containers = Set(["descriptor", "descriptors", "ordered-descriptor", "ordered-descriptors", "video-descriptor", "video-descriptors"])
    static func descriptors(in root: URL) throws -> [(URL, WallpaperProvider)] {
        let fm = FileManager.default
        guard let iterator = fm.enumerator(at: root, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) else { return [] }
        var result: [(URL, WallpaperProvider)] = []
        for case let folder as URL in iterator {
            guard try folder.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true else { continue }
            let names = try fm.contentsOfDirectory(atPath: folder.path)
            let identifiesDescriptor = names.contains("com.apple.posterkit.provider.descriptor.identifier")
            let childOfContainer = containers.contains(folder.deletingLastPathComponent().lastPathComponent.lowercased()) &&
                names.contains(where: { name in
                    (try? folder.appendingPathComponent(name).resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
                })
            guard identifiesDescriptor || childOfContainer else { continue }
            let lower = folder.path.lowercased()
            let provider: WallpaperProvider = lower.contains("mercury") ? .mercury :
                (lower.contains("video-descriptor") || lower.contains("photosposter") || names.contains("VideoCAML")) ? .video : .collections
            result.append((folder, provider)); iterator.skipDescendants()
        }
        guard !result.isEmpty, result.count <= 30 else { throw CustomizationFailure("This pack contains no compatible wallpapers.") }
        return result
    }
    static func randomize(_ folder: URL) throws {
        // Randomize only documented identifiers; CAML and binary resources remain intact.
        let number = Int.random(in: 100_000...Int(Int32.max))
        guard let iterator = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: [.isRegularFileKey]) else { return }
        for case let url as URL in iterator {
            guard try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else { continue }
            switch url.lastPathComponent {
            case "com.apple.posterkit.provider.descriptor.identifier":
                try Data(String(number).utf8).write(to: url, options: .atomic)
            case "com.apple.posterkit.provider.contents.userInfo", "Wallpaper.plist":
                let data = try CustomizationFiles.read(url)
                guard var plist = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else {
                    throw CustomizationFailure("This pack contains no compatible wallpapers.")
                }
                plist[url.lastPathComponent == "Wallpaper.plist" ? "identifier" : "wallpaperRepresentingIdentifier"] = number
                try PropertyListSerialization.data(fromPropertyList: plist, format: .binary, options: 0).write(to: url, options: .atomic)
            default: break
            }
        }
    }
    static func providerPaths(in root: URL, provider: WallpaperProvider) throws -> [String] {
        let base = "Library/Application Support/PRBPosterExtensionDataStore"
        let store = try CustomizationFiles.checked(base, in: root)
        let versions = try FileManager.default.contentsOfDirectory(atPath: store.path).compactMap(Int.init).sorted(by: >)
        for version in versions {
            let paths = provider.identifiers.map { "\(base)/\(version)/Extensions/\($0)/descriptors" }
            let existing = paths.filter { relative in
                guard let url = try? CustomizationFiles.checked(relative, in: root) else { return false }
                return (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
            }
            if !existing.isEmpty { return existing }
        }
        throw CustomizationFailure("This pack contains no compatible wallpapers.")
    }
}

enum CustomizationImages {
    static func png(_ data: Data, size: Int = 512) throws -> Data {
        guard data.count <= 24 * 1024 * 1024,
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: max(32, min(size, 1024))
              ] as CFDictionary) else {
            throw CustomizationFailure("This pack contains no compatible wallpapers.")
        }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, UTType.png.identifier as CFString, 1, nil) else {
            throw CustomizationFailure("This pack contains no compatible wallpapers.")
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw CustomizationFailure("This pack contains no compatible wallpapers.") }
        return output as Data
    }
    static func thumbnail(in root: URL) throws -> Data? {
        guard let iterator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey], options: [.skipsHiddenFiles]) else { return nil }
        for case let url as URL in iterator {
            guard ["png", "jpg", "jpeg", "heic"].contains(url.pathExtension.lowercased()),
                  let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
                  values.isRegularFile == true, (values.fileSize ?? Int.max) < 12 * 1024 * 1024 else { continue }
            if let result = try? png(CustomizationFiles.read(url), size: 640) { return result }
        }
        return nil
    }
}
