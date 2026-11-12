import Foundation

@main struct DirectFileImportTests {
    struct Failure: Error { let message: String }
    static func expect(_ condition: Bool, _ message: String) throws {
        if !condition { throw Failure(message: message) }
    }
    @MainActor static func main() async throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? fm.removeItem(at: root) }
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        let container = root.appendingPathComponent("app", isDirectory: true)
        let inbox = try DirectFileImports.inbox(container: container)
        func file(_ name: String, value: Int) throws -> (URL, Data) {
            let data = try PropertyListSerialization.data(fromPropertyList: ["CacheExtra": ["value": value]], format: .binary, options: 0)
            let url = root.appendingPathComponent(name)
            try data.write(to: url)
            return (url, data)
        }
        let (firstURL, firstData) = try file("first.plist", value: 1)
        let first = try await DirectFileImports.capture(firstURL, in: inbox).value
        try fm.removeItem(at: firstURL)
        try expect(try inbox.read(first) == firstData, "Queued bytes outlive the sender's URL")
        let waiting = try SharedImportQueue.snapshot(in: [inbox])
        let deferred: SharedImportQueue.Selection<SharedPlistEntry> = await SharedImportQueue.next(in: waiting) { _, _ in .deferred(nil) }
        if case .deferred = deferred {} else { throw Failure(message: "A closed presentation gate must defer") }
        try expect(try inbox.entries().map(\.id) == [first.id], "Welcome or another sheet cannot consume the pending file")

        // Reconstructing the private inbox models a process restart before confirmation.
        let reopened = try DirectFileImports.inbox(container: container)
        try expect(try reopened.read(first) == firstData, "Pending direct files survive a process restart")
        let offered: SharedImportQueue.Selection<SharedPlistEntry> = await SharedImportQueue.next(in: waiting) { _, entry in .ready(entry) }
        if case .ready(let entry) = offered { try expect(entry.id == first.id, "Offer the original pending file") }
        else { throw Failure(message: "The first file was lost") }

        let (secondURL, secondData) = try file("second.plist", value: 2)
        let second = try await DirectFileImports.capture(secondURL, in: inbox).value
        try fm.removeItem(at: secondURL)
        try expect(try inbox.read(first) == firstData, "A new URL cannot replace the currently offered bytes")
        try inbox.acknowledge(first)
        let following = try SharedImportQueue.snapshot(in: [reopened])
        try expect(following.map(\.entry.id) == [second.id], "Accepting or cancelling one offer leaves the next queued file")
        try expect(try reopened.read(second) == secondData, "The next offer retains its own captured bytes")

        let invalid = root.appendingPathComponent("invalid.plist")
        try Data("not a plist".utf8).write(to: invalid)
        do {
            _ = try await DirectFileImports.capture(invalid, in: inbox).value
            throw Failure(message: "An invalid file entered the confirmation queue")
        } catch is SharedPlistError {}
        try expect(try reopened.entries().map(\.id) == [second.id], "Failed capture leaves earlier pending files untouched")
        try reopened.acknowledge(second)
        try expect(try reopened.entries().isEmpty, "Normal confirmation cleanup also handles direct files")
        print("PASS: direct file capture survives closed gates, URL removal, process restart and later incoming files.")
    }
}
