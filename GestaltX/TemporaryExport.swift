// SPDX-License-Identifier: GPL-3.0-only
import Foundation

struct TemporaryExport: Identifiable, Sendable {
    let id: UUID
    let url: URL
    private let directory: URL

    init(data: Data, name: String, root: URL = FileManager.default.temporaryDirectory.appendingPathComponent("GestaltXExports", isDirectory: true)) throws {
        id = UUID()
        directory = root.appendingPathComponent(id.uuidString, isDirectory: true)
        url = directory.appendingPathComponent(name)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
        } catch {
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
    }

    func cleanUp() {
        // The immutable directory belongs to this one export. Never remove the
        // shared root, another export, or a destination chosen in the activity.
        try? FileManager.default.removeItem(at: directory)
    }
}
