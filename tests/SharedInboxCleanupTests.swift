import Foundation
import Darwin

@main struct SharedInboxCleanupTests {
    struct Failure: Error { let message: String }
    static func expect(_ condition: Bool, _ message: String) throws {
        if !condition { throw Failure(message: message) }
    }

    static func main() throws {
        // A separate process holds the same advisory lease as an extension.
        // The five-second poll bounds even a regressed blocking cleanup test.
        if CommandLine.arguments.count == 3, CommandLine.arguments[1] == "--hold-lock" {
            let descriptor = open(CommandLine.arguments[2], O_RDWR | O_NOFOLLOW | O_CLOEXEC)
            guard descriptor >= 0 else { throw Failure(message: "Open the writer lease") }
            defer { close(descriptor) }
            try expect(flock(descriptor, LOCK_EX | LOCK_NB) == 0, "Hold the writer lease in the child process")
            try FileHandle.standardOutput.write(contentsOf: Data([1]))
            var input = pollfd(fd: STDIN_FILENO, events: Int16(POLLIN), revents: 0)
            _ = poll(&input, 1, 5000)
            return
        }

        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("GestaltX-inbox-cleanup-" + UUID().uuidString)
        defer { try? fm.removeItem(at: root) }
        let inbox = try SharedPlistInbox(container: root, namespace: "test")
        let bytes = try PropertyListSerialization.data(fromPropertyList: ["CacheExtra": ["fixture": true]], format: .binary, options: 0)
        let now = Date()
        let old = now.addingTimeInterval(-9 * 24 * 60 * 60)
        let published = try inbox.enqueue(bytes, name: "published.plist")
        try fm.setAttributes([.modificationDate: old], ofItemAtPath: inbox.directory.appendingPathComponent(published.id.uuidString).path)
        let recentlyRejected = try inbox.enqueue(bytes, name: "recently-rejected.plist")
        try fm.setAttributes([.modificationDate: old], ofItemAtPath: inbox.directory.appendingPathComponent(recentlyRejected.id.uuidString).path)
        inbox.reject(recentlyRejected)
        let recentRejection = inbox.directory.appendingPathComponent("." + recentlyRejected.id.uuidString + ".rejected")

        func fixture(_ suffix: String, date: Date, name: String? = nil) throws -> URL {
            let url = inbox.directory.appendingPathComponent(name ?? "." + UUID().uuidString + suffix)
            try fm.createDirectory(at: url, withIntermediateDirectories: false)
            try bytes.write(to: url.appendingPathComponent("document.plist"))
            try fm.setAttributes([.modificationDate: date], ofItemAtPath: url.path)
            return url
        }
        let abandoned = try fixture(".pending", date: old)
        let rejected = try fixture(".rejected", date: old)
        let recent = try fixture(".pending", date: now)
        let unknown = try fixture(".pending", date: old, name: ".not-our-uuid.pending")
        let active = try fixture(".pending", date: old)
        let lease = active.appendingPathComponent(".writer.lock")
        try Data().write(to: lease)
        try fm.setAttributes([.modificationDate: old], ofItemAtPath: active.path)
        let outside = root.appendingPathComponent("outside")
        try fm.createDirectory(at: outside, withIntermediateDirectories: false)
        try bytes.write(to: outside.appendingPathComponent("keep.plist"))
        let link = inbox.directory.appendingPathComponent("." + UUID().uuidString + ".pending")
        try fm.createSymbolicLink(at: link, withDestinationURL: outside)
        let badLease = try fixture(".pending", date: old)
        let fifo = badLease.appendingPathComponent(".writer.lock")
        try expect(fifo.withUnsafeFileSystemRepresentation { mkfifo($0!, 0o600) } == 0, "Create a malformed lease fixture")
        try fm.setAttributes([.modificationDate: old], ofItemAtPath: badLease.path)

        let child = Process()
        child.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
        child.arguments = ["--hold-lock", lease.path]
        let ready = Pipe(), release = Pipe()
        child.standardOutput = ready
        child.standardInput = release
        try child.run()
        try ready.fileHandleForWriting.close()
        defer { try? release.fileHandleForWriting.close(); if child.isRunning { child.terminate() } }
        try expect(try ready.fileHandleForReading.read(upToCount: 1) == Data([1]), "The child must hold its lease before cleanup")
        let start = Date()
        let removed = inbox.cleanupStaleEntries(now: now)
        try expect(Date().timeIntervalSince(start) < 2, "Cleanup must not wait for another process's writer lock")
        try expect(removed == 2, "Only expired pending/rejected fixtures are removed")
        try expect(!fm.fileExists(atPath: abandoned.path) && !fm.fileExists(atPath: rejected.path), "Remove abandoned payloads")
        for url in [recent, unknown, active, recentRejection, badLease, link] {
            try expect(fm.fileExists(atPath: url.path), "Preserve recent, active, unknown and linked directories")
        }
        try expect(try Data(contentsOf: outside.appendingPathComponent("keep.plist")) == bytes, "Never follow a cleanup symlink")
        try expect(try inbox.read(published) == bytes, "Published entries are retained regardless of age")
        try release.fileHandleForWriting.write(contentsOf: Data([1]))
        try release.fileHandleForWriting.close()
        child.waitUntilExit()
        try expect(child.terminationStatus == 0, "The cooperating writer exits cleanly")
        try expect(inbox.cleanupStaleEntries(now: now) == 1, "After the writer exits, its expired staging folder can be removed")
        try expect(!fm.fileExists(atPath: active.path), "Clean a released abandoned lease")
        try expect(try inbox.entries().map(\.id) == [published.id], "Housekeeping never consumes the automatic import queue")

        let inaccessible = try SharedPlistInbox(container: root.appendingPathComponent("not-a-directory"), namespace: "test")
        try Data([0]).write(to: root.appendingPathComponent("not-a-directory"))
        try expect(inaccessible.cleanupStaleEntries(now: now) == 0, "Failed housekeeping is best effort")
        let another = try inbox.enqueue(bytes, name: "after-cleanup.plist")
        try expect(try inbox.read(another) == bytes, "Normal handoff still succeeds after malformed cleanup fixtures")
        print("PASS: aged staging/quarantine cleanup, bounded cross-process writer leases, published/recent retention and malformed-path isolation.")
    }
}
