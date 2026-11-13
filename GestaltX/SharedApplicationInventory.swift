// SPDX-License-Identifier: GPL-3.0-only
import Foundation

/// Both tools share app names, identifiers, sizes and container metadata.
/// Each tool retains its own availability result; a readable launch image says
/// nothing about whether the same app has a replaceable notification sound.
final class SharedApplicationInventory: @unchecked Sendable {
    static let shared: SharedApplicationInventory = {
        let key = "GestaltX.applicationInventory.installation"
        let defaults = UserDefaults.standard
        let installation = defaults.string(forKey: key) ?? UUID().uuidString
        defaults.set(installation, forKey: key)
        return SharedApplicationInventory(storage: FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("GestaltX/Applications/Inventory.plist"), device: installation)
    }()
    private struct Saved: Codable {
        let version: Int
        let device: String
        let inventory: LaunchArtworkInventory
    }
    private let lock = NSLock()
    private let storage: URL
    private let device: String
    private var loaded = false
    private var cached: LaunchArtworkInventory?
    private var checked = Date.distantPast
    private var discovered = Date.distantPast
    init(storage: URL, device: String) { self.storage = storage; self.device = device }
    func invalidate() {
        lock.lock(); defer { lock.unlock() }
        checked = .distantPast
        discovered = .distantPast
    }
    func inventory(discover: Bool, loader: (Bool) -> LaunchArtworkInventory) -> LaunchArtworkInventory {
        lock.lock(); defer { lock.unlock() }
        if !loaded {
            loaded = true
            if let values = try? storage.resourceValues(forKeys: [.fileSizeKey, .isSymbolicLinkKey]),
               values.isSymbolicLink != true, (values.fileSize ?? Int.max) <= 4 * 1024 * 1024,
               let bytes = try? Data(contentsOf: storage), let saved = try? PropertyListDecoder().decode(Saved.self, from: bytes),
               saved.version == 1, saved.device == device, Self.valid(saved.inventory) { cached = saved.inventory }
        }
        let now = Date()
        if var cached, !discover {
            cached.refreshNeeded = now.timeIntervalSince(checked) > 10
            return cached
        }
        // Coalesce the full discovery requested by both pages during the same
        // foreground transition, while allowing a later manual refresh.
        if let cached, discover, now.timeIntervalSince(discovered) < 1 { return cached }
        var next = loader(discover)
        guard Self.valid(next) else {
            return cached ?? LaunchArtworkInventory(complete: false, candidates: [])
        }
        if !next.complete, let previous = cached {
            let seen = Set(next.candidates.map { $0.app.id })
            let retained = previous.candidates.filter { !seen.contains($0.app.id) }.prefix(2048 - next.candidates.count)
            next = LaunchArtworkInventory(complete: false, candidates: next.candidates + retained,
                                          containerGeneration: next.containerGeneration)
        }
        next.refreshNeeded = false
        cached = next; checked = now
        if discover { discovered = now }
        try? CustomizationFiles.saveVerified(Saved(version: 1, device: device, inventory: next), to: storage)
        return next
    }
    private static func valid(_ inventory: LaunchArtworkInventory) -> Bool {
        inventory.candidates.count <= 2048
            && Set(inventory.candidates.map { $0.app.id }).count == inventory.candidates.count
            && inventory.candidates.allSatisfy {
                LaunchArtworkDirectory.validIdentifier($0.app.id) && $0.app.name.utf8.count <= 1024
                    && $0.generation.utf8.count <= 8192 && ($0.container?.utf8.count ?? 0) <= 4096
            }
    }
}
