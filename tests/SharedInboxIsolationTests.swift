import Foundation

@main struct SharedInboxIsolationTests {
    struct Failure: Error { let message: String }
    static func expect(_ condition: Bool, _ message: String = "Unexpected inbox contents") throws {
        if !condition { throw Failure(message: message) }
    }

    static func main() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("GestaltX-inbox-isolation-" + UUID().uuidString)
        defer { try? fm.removeItem(at: root) }
        let bad = try SharedPlistInbox(container: root.appendingPathComponent("bad-group"), namespace: "test")
        let good = try SharedPlistInbox(container: root.appendingPathComponent("good-group"), namespace: "test")
        let missing = try SharedPlistInbox(container: root.appendingPathComponent("missing-group"), namespace: "test")
        try fm.createDirectory(at: bad.directory.deletingLastPathComponent(), withIntermediateDirectories: true)
        let sentinel = Data("The inbox path is a file, not a directory.".utf8)
        try sentinel.write(to: bad.directory)
        let bytes = try PropertyListSerialization.data(fromPropertyList: ["CacheExtra": ["fixture": true]], format: .binary, options: 0)
        let entry = try good.enqueue(bytes, name: "healthy.plist")

        for inboxes in [[bad, good], [good, bad], [missing, bad, good]] {
            let found = try SharedImportQueue.snapshot(in: inboxes)
            try expect(found.count == 1 && found[0].entry.id == entry.id,
                         "An unreadable inbox must not suppress another App Group's valid document")
            try expect(try found[0].inbox.read(found[0].entry) == bytes)
        }
        try expect(try Data(contentsOf: bad.directory) == sentinel,
                     "Fault isolation must not remove or replace the damaged path")
        try good.acknowledge(entry)
        for inboxes in [[bad], [bad, good], [missing, bad]] {
            do {
                _ = try SharedImportQueue.snapshot(in: inboxes)
                throw Failure(message: "An inaccessible remaining inbox must still report its error")
            } catch is Failure { throw Failure(message: "An inaccessible remaining inbox must still report its error") }
            catch { /* A real enumeration failure remains visible to the caller. */ }
        }
        try expect(try SharedImportQueue.snapshot(in: [good, missing]).isEmpty)
        try expect(try SharedImportQueue.snapshot(in: []).isEmpty)
        print("PASS: failed App Groups do not hide healthy shared documents; remaining errors and empty inboxes stay distinguishable.")
    }
}
