import Foundation

@main struct TemporaryExportTests {
    struct Failure: Error { let message: String }
    static func expect(_ condition: Bool, _ message: String) throws {
        if !condition { throw Failure(message: message) }
    }
    static func main() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? fm.removeItem(at: root) }
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        let unrelated = root.appendingPathComponent("unrelated.plist")
        try Data([99]).write(to: unrelated)
        let first = try TemporaryExport(data: Data([1, 2]), name: "export.plist", root: root)
        let second = try TemporaryExport(data: Data([3, 4]), name: "export.plist", root: root)
        try expect(first.url != second.url, "Concurrent exports own separate directories")
        try expect(try Data(contentsOf: first.url) == Data([1, 2]), "Keep source bytes available while sharing")
        first.cleanUp()
        try expect(!fm.fileExists(atPath: first.url.deletingLastPathComponent().path), "Completed or cancelled sharing removes its directory")
        try expect(try Data(contentsOf: second.url) == Data([3, 4]), "Cleaning one export cannot remove another active export")
        try expect(try Data(contentsOf: unrelated) == Data([99]), "Unrelated files survive cleanup")
        first.cleanUp()
        second.cleanUp()
        second.cleanUp()
        try expect(try fm.contentsOfDirectory(atPath: root.path) == ["unrelated.plist"], "Repeated completion/dismissal cleanup is harmless")

        do {
            _ = try TemporaryExport(data: Data([1]), name: "missing/child.plist", root: root)
            throw Failure(message: "The fixture should fail to write below a missing child directory")
        } catch is Failure { throw Failure(message: "Expected a write failure") }
        catch {}
        try expect(try fm.contentsOfDirectory(atPath: root.path) == ["unrelated.plist"], "A failed export removes the newly created directory")
        do {
            _ = try TemporaryExport(data: Data([1]), name: "export.plist", root: unrelated)
            throw Failure(message: "An occupied root must fail")
        } catch is Failure { throw Failure(message: "Expected a directory creation failure") }
        catch {}
        try expect(try Data(contentsOf: unrelated) == Data([99]), "Creation failure leaves an existing root file untouched")
        print("PASS: export bytes remain available until cleanup; isolated, repeatable cleanup and failed-write rollback.")
    }
}
