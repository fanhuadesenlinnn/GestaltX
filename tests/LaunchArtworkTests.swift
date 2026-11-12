import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

private final class WriteCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func failSecond() throws {
        lock.lock(); defer { lock.unlock() }
        count += 1
        if count == 2 { throw CocoaError(.fileWriteUnknown) }
    }
}

@main enum LaunchArtworkTests {
    static let fm = FileManager.default
    static func expect(_ condition: Bool, _ message: String) throws {
        if !condition { throw NSError(domain: "LaunchArtworkTests", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
    }
    static func reject(_ operation: () throws -> Void) throws {
        do { try operation() } catch { return }
        throw NSError(domain: "LaunchArtworkTests", code: 2)
    }
    static func png(_ red: CGFloat, _ green: CGFloat, _ blue: CGFloat, width: Int = 80, height: Int = 160) -> Data {
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(red: red, green: green, blue: blue, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let data = NSMutableData()
        let writer = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(writer, context.makeImage()!, nil); precondition(CGImageDestinationFinalize(writer))
        return data as Data
    }
    static func main() async throws {
        let root = fm.temporaryDirectory.appendingPathComponent("GX-Launch-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: root) }
        try fm.createDirectory(at: root, withIntermediateDirectories: false)
        let app = LaunchArtworkApp(id: "test.launch", name: "Test")
        let container = root.appendingPathComponent(UUID().uuidString)
        let group = container.appendingPathComponent("Library/SplashBoard/Snapshots/\(app.id) - {DEFAULT GROUP}")
        try fm.createDirectory(at: group, withIntermediateDirectories: true)
        let first = group.appendingPathComponent("A@3x.ktx"), second = group.appendingPathComponent("B@3x.ktx")
        let red = png(1, 0, 0), green = png(0, 1, 0), blue = png(0, 0, 1)
        try red.write(to: first); try red.write(to: second)
        let scene = container.appendingPathComponent("Library/SplashBoard/Snapshots/scene-private")
        try fm.createDirectory(at: scene, withIntermediateDirectories: false)
        try green.write(to: scene.appendingPathComponent("private.ktx"))
        let storage = root.appendingPathComponent("Saved")
        let store = LaunchArtworkStore(storage: storage, device: "device", resolver: { _ in container })
        let initial = try await store.state(app)
        try expect(initial.count == 2 && !initial.canRestore && initial.preview != nil, "Initial snapshot discovery failed")
        try expect(try await store.apply(blue, to: app) == 2, "Apply did not cover default launch variants")
        try expect(try Data(contentsOf: first) != red, "Image was not changed")
        try expect(try Data(contentsOf: scene.appendingPathComponent("private.ktx")) == green, "Recent-app snapshot was edited")
        try expect(try await store.apply(green, to: app) == 2, "Repeated Apply failed")
        let reopened = LaunchArtworkStore(storage: storage, device: "device", resolver: { _ in container })
        try expect(try await reopened.restore(app) == 2, "Restore after reopen failed")
        try expect(try Data(contentsOf: first) == red && Data(contentsOf: second) == red, "Repeated edits lost the earliest original")
        let directories = try fm.contentsOfDirectory(atPath: group.path)
        try expect(!directories.contains(where: { $0.hasPrefix(".GestaltX-") }), "Atomic write staging leaked")

        _ = try await store.apply(blue, to: app)
        let foreign = LaunchArtworkStore(storage: storage, device: "other-device", resolver: { _ in container })
        do { _ = try await foreign.restore(app); throw CocoaError(.coderInvalidValue) } catch is CustomizationFailure {}
        try fm.removeItem(at: first)
        try green.write(to: second, options: .atomic)
        try expect(try await store.restore(app) == 0, "Restore overwrote OS-generated data")
        try expect(!fm.fileExists(atPath: first.path), "Restore recreated a deleted snapshot")
        try expect(try Data(contentsOf: second) == green, "OS-refreshed data was overwritten")

        try red.write(to: first); try red.write(to: second)
        let counter = WriteCounter()
        let interrupted = LaunchArtworkStore(storage: root.appendingPathComponent("Interrupted"), device: "device", resolver: { _ in container }, beforeWrite: { try counter.failSecond() })
        var interruptedWriteFailed = false
        do { _ = try await interrupted.apply(blue, to: app) } catch { interruptedWriteFailed = true }
        try expect(interruptedWriteFailed, "Write-failure injection was ignored")
        try expect(try Data(contentsOf: first) == red && Data(contentsOf: second) == red, "Interrupted write did not roll back")

        _ = try await store.apply(blue, to: app)
        let activeURL = storage.appendingPathComponent(app.id).appendingPathComponent("Originals.plist")
        let goodRecord = try Data(contentsOf: activeURL)
        var corrupt = try PropertyListSerialization.propertyList(from: goodRecord, format: nil) as! [String: Any]
        var savedFiles = corrupt["files"] as! [String: [String: Any]]
        savedFiles[first.lastPathComponent]!["original"] = green
        corrupt["files"] = savedFiles
        try PropertyListSerialization.data(fromPropertyList: corrupt, format: .binary, options: 0).write(to: activeURL)
        do { _ = try await store.restore(app); throw CocoaError(.coderInvalidValue) } catch is CustomizationFailure {}
        try expect(try Data(contentsOf: first) != red, "A corrupted backup was restored")
        try goodRecord.write(to: activeURL)
        _ = try await store.restore(app)

        _ = try await store.apply(blue, to: app)
        let reinstall = root.appendingPathComponent(UUID().uuidString)
        let newGroup = reinstall.appendingPathComponent("Library/SplashBoard/Snapshots/\(app.id) - {DEFAULT GROUP}")
        try fm.createDirectory(at: newGroup, withIntermediateDirectories: true)
        try green.write(to: newGroup.appendingPathComponent("new.ktx"))
        let newStore = LaunchArtworkStore(storage: storage, device: "device", resolver: { _ in reinstall })
        do { _ = try await newStore.restore(app); throw CocoaError(.coderInvalidValue) } catch is CustomizationFailure {}
        _ = try await newStore.apply(blue, to: app)
        _ = try await newStore.restore(app)
        try expect(try Data(contentsOf: newGroup.appendingPathComponent("new.ktx")) == green, "Reinstallation reused another container's originals")

        let directory = try LaunchArtworkDirectory(container: container, identifier: app.id)
        let expected = try directory.read(first.lastPathComponent)!
        try green.write(to: first, options: .atomic)
        try reject { try directory.replace(first.lastPathComponent, expected: expected, data: blue) }
        try expect(try Data(contentsOf: first) == green, "Stale write changed the current file")
        try red.write(to: first)
        let beforeLink = try directory.read(first.lastPathComponent)!
        let moved = group.deletingLastPathComponent().appendingPathComponent("moved")
        try fm.moveItem(at: group, to: moved)
        let outside = root.appendingPathComponent("Outside")
        try fm.createDirectory(at: outside, withIntermediateDirectories: false)
        try red.write(to: outside.appendingPathComponent(first.lastPathComponent))
        try fm.createSymbolicLink(at: group, withDestinationURL: outside)
        try reject { try directory.replace(first.lastPathComponent, expected: beforeLink, data: blue) }
        try expect(try Data(contentsOf: outside.appendingPathComponent(first.lastPathComponent)) == red, "A swapped parent redirected the write")
        try reject { _ = try LaunchArtworkDirectory(container: container, identifier: app.id) }
        try fm.removeItem(at: group); try fm.moveItem(at: moved, to: group)

        let rendered = try LaunchArtworkImages.render(blue, width: 160, height: 80)
        let size = try LaunchArtworkImages.dimensions(rendered)
        try expect(size.width == 160 && size.height == 80, "Aspect-fill output dimensions are wrong")
        try reject { _ = try LaunchArtworkImages.render(Data("invalid".utf8), width: 160, height: 80) }
        try reject { _ = try LaunchArtworkImages.render(blue, width: 10000, height: 80) }
        let originalLarge = png(0, 1, 0, width: 1200, height: 2400)
        let exportedSize = try LaunchArtworkImages.dimensions(LaunchArtworkImages.export(originalLarge)!)
        let thumbnailSize = try LaunchArtworkImages.dimensions(LaunchArtworkImages.preview(originalLarge)!)
        try expect(exportedSize.width == 1200 && exportedSize.height == 2400 && thumbnailSize.height <= 900, "Saving used a preview instead of the full-resolution current image")
        print("PASS: launch variants, exact original restoration, reopen, device binding, OS regeneration, rollback, stale writes, pinned parents and image bounds.")
    }
}
