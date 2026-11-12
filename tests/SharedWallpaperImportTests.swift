import Foundation
import Darwin

@main struct SharedWallpaperImportTests {
    struct Failure: Error { let message: String }
    static func expect(_ value: Bool, _ message: String) throws { if !value { throw Failure(message: message) } }
    static func reject(_ operation: () throws -> Void) throws {
        do { try operation() } catch is Failure { throw Failure(message: "Unexpected test failure") } catch { return }
        throw Failure(message: "Unsafe input was accepted")
    }
    @MainActor static func main() async throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? fm.removeItem(at: root) }
        try fm.createDirectory(at: root, withIntermediateDirectories: false)
        let container = root.appendingPathComponent("group", isDirectory: true)
        let archive = try SharedPlistInbox(container: container, namespace: "app", kind: .wallpaper)
        let plist = try SharedPlistInbox(container: container, namespace: "app")
        let bytes = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))
        let source = root.appendingPathComponent("Forest.tendies")
        try bytes.write(to: source)
        let entry = try archive.enqueueWallpaper(at: source, name: "Forest.tendies")
        try fm.removeItem(at: source)
        try expect(try plist.entries().isEmpty, "A wallpaper entered the MobileGestalt queue")
        let similarBundle = try SharedPlistInbox(container: container, namespace: "app.wallpapers")
        try expect(try similarBundle.entries().isEmpty, "Wallpaper kind collided with another re-signed bundle namespace")
        try reject { try SharedPlistInbox.validate(bytes) }
        try reject { _ = try archive.read(entry) }
        try reject { _ = try archive.enqueue(bytes, name: "disguised.plist") }
        let reopened = try SharedPlistInbox(container: container, namespace: "app", kind: .wallpaper)
        try expect(try reopened.entries().map(\.id) == [entry.id], "Handoff did not survive process restart or source removal")
        let queued = try SharedImportQueue.snapshot(in: [plist, reopened])
        let selection: SharedImportQueue.Selection<SharedPlistEntry> = await SharedImportQueue.next(in: queued) { _, _ in .deferred(nil) }
        if case .deferred = selection {} else { throw Failure(message: "Closed presentation gate consumed an archive") }
        let offer = try await SharedWallpaperImports.prepare(entry, from: reopened)
        defer { offer.cleanUp() }
        try expect(try Data(contentsOf: offer.file) == bytes, "Confirmation did not own the archive bytes")
        let published = archive.directory.appendingPathComponent(entry.id.uuidString).appendingPathComponent("document.archive")
        try Data("changed after presentation".utf8).write(to: published)
        try expect(try Data(contentsOf: offer.file) == bytes, "An App Group edit changed an already offered file")
        let destination = root.appendingPathComponent("bad-stage.zip")
        try reject { try reopened.stageWallpaper(entry, at: destination) }
        try expect(!fm.fileExists(atPath: destination.path), "Failed staging left a partial archive")
        try reopened.acknowledge(entry)
        offer.cleanUp()
        try expect(try reopened.entries().isEmpty, "Cancellation/confirmation cleanup left an entry")

        // The archive path has its own larger limit, copied in fixed-size chunks.
        let large = root.appendingPathComponent("large.zip")
        fm.createFile(atPath: large.path, contents: Data([0x50, 0x4b, 3, 4]))
        let writer = try FileHandle(forWritingTo: large)
        try writer.truncate(atOffset: 17 * 1024 * 1024)
        try writer.close()
        let largeEntry = try archive.enqueueWallpaper(at: large, name: "large.zip")
        try expect(largeEntry.byteCount > SharedPlistInbox.maximumByteCount, "Wallpaper transport retained the plist size limit")
        try archive.acknowledge(largeEntry)
        let oversized = try FileHandle(forWritingTo: large)
        try oversized.truncate(atOffset: UInt64(SharedPlistInbox.maximumWallpaperByteCount + 1))
        try oversized.close()
        try reject { _ = try archive.enqueueWallpaper(at: large, name: "oversized.tendies") }
        try expect(try archive.entries().isEmpty, "An oversized archive was published")

        try bytes.write(to: source)
        var cancellationChecks = 0
        do {
            _ = try archive.enqueueWallpaper(at: source, name: "cancelled.tendies", checkCancellation: {
                cancellationChecks += 1
                if cancellationChecks > 1 { throw CancellationError() }
            })
            throw Failure(message: "Cancelled archive was published")
        } catch is CancellationError {}
        try expect(try archive.entries().isEmpty, "Cancelled transfer left a visible entry")
        try expect(try fm.contentsOfDirectory(atPath: archive.directory.path).isEmpty, "Cancelled transfer leaked staging files")
        let link = root.appendingPathComponent("linked.tendies")
        try fm.createSymbolicLink(at: link, withDestinationURL: source)
        try reject { _ = try archive.enqueueWallpaper(at: link, name: "linked.tendies") }
        let fifo = root.appendingPathComponent("pipe.tendies")
        try expect(mkfifo(fifo.path, 0o600) == 0, "Could not create FIFO fixture")
        try reject { _ = try archive.enqueueWallpaper(at: fifo, name: "pipe.tendies") }

        let direct = try SharedWallpaperImports.inbox(container: root.appendingPathComponent("private"))
        let captured = try await SharedWallpaperImports.capture(source, in: direct).value
        try fm.removeItem(at: source)
        let capturedOffer = try await SharedWallpaperImports.prepare(captured, from: direct)
        try expect(try Data(contentsOf: capturedOffer.file) == bytes, "File-open handoff lost its security-scoped copy")
        capturedOffer.cleanUp(); try direct.acknowledge(captured)
        try expect(SharedPlistInbox.isWallpaperName("A.TENDIES") && SharedPlistInbox.isWallpaperName("A.tendis"), "Archive extension classification failed")
        print("PASS: wallpaper streaming, restart/gates, immutable offer, cancellation, size limits, special-file rejection and plist isolation.")
    }
}
