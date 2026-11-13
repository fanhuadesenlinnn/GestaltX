// SPDX-License-Identifier: GPL-3.0-only
import Foundation

@main enum CapturedSoundStoreTests {
    static func expect(_ condition: Bool, _ message: String) throws {
        if !condition { throw NSError(domain: "CapturedSoundStoreTests", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
    }

    static func sound(_ bundle: String, _ file: String, origin: CapturedNotificationSound.Origin = .appData,
                      at t: Date = Date(timeIntervalSince1970: 1_000)) -> CapturedNotificationSound {
        CapturedNotificationSound(bundleID: bundle, filename: file, origin: origin, relativeLocation: "Library/Sounds", lastSeen: t)
    }

    static func main() async throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("GX-CapturedSounds-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: root) }
        try fm.createDirectory(at: root, withIntermediateDirectories: true)

        try await testDedupeAndMerge(root)
        try await testPersistenceRoundTrip(root)
        try await testCapacityEviction(root)
        try await testReconfirmAndForget(root)
        try await testWrongDeviceIgnored(root)
        try await testRejectsMalformed(root)
        print("CapturedSoundStoreTests: all passed")
    }

    static func testDedupeAndMerge(_ root: URL) async throws {
        let store = CapturedSoundStore(storage: root.appendingPathComponent("dedupe"), device: "dev")
        _ = await store.record([sound("com.a.b", "x.caf", origin: .unknown, at: Date(timeIntervalSince1970: 100))])
        _ = await store.record([sound("com.a.b", "x.caf", origin: .bundle, at: Date(timeIntervalSince1970: 200))])
        let all = await store.all()
        try expect(all.count == 1, "expected single deduped row, got \(all.count)")
        try expect(all[0].origin == .bundle, "origin should upgrade to bundle, got \(all[0].origin)")
        try expect(all[0].lastSeen == Date(timeIntervalSince1970: 200), "lastSeen should be newest")
    }

    static func testPersistenceRoundTrip(_ root: URL) async throws {
        let dir = root.appendingPathComponent("persist")
        let a = CapturedSoundStore(storage: dir, device: "dev")
        _ = await a.record([sound("com.a.b", "x.caf"), sound("com.c.d", "y.m4a", origin: .bundle)])
        let b = CapturedSoundStore(storage: dir, device: "dev")
        let loaded = await b.all()
        try expect(loaded.count == 2, "expected 2 persisted rows, got \(loaded.count)")
        let bundles = await b.observedBundleIDs()
        try expect(bundles == ["com.a.b", "com.c.d"], "observed bundles wrong: \(bundles)")
    }

    static func testCapacityEviction(_ root: URL) async throws {
        var limits = CapturedSoundStore.Limits(); limits.maxCount = 2
        let store = CapturedSoundStore(storage: root.appendingPathComponent("cap"), device: "dev", limits: limits)
        _ = await store.record([sound("com.a.b", "1.caf", at: Date(timeIntervalSince1970: 100))])
        _ = await store.record([sound("com.a.b", "2.caf", at: Date(timeIntervalSince1970: 200))])
        _ = await store.record([sound("com.a.b", "3.caf", at: Date(timeIntervalSince1970: 300))])
        let all = await store.all()
        try expect(all.count == 2, "capacity not enforced, got \(all.count)")
        try expect(!all.contains { $0.filename == "1.caf" }, "oldest should be evicted")
    }

    static func testReconfirmAndForget(_ root: URL) async throws {
        let dir = root.appendingPathComponent("reconfirm")
        let store = CapturedSoundStore(storage: dir, device: "dev")
        _ = await store.record([sound("com.a.b", "x.caf"), sound("com.c.d", "y.caf")])
        await store.markNeedsReconfirm(bundleIDs: ["com.a.b"])
        let reloaded = CapturedSoundStore(storage: dir, device: "dev")
        let rows = await reloaded.all()
        try expect(rows.first { $0.bundleID == "com.a.b" }?.needsReconfirm == true, "reconfirm flag not persisted")
        try expect(rows.first { $0.bundleID == "com.c.d" }?.needsReconfirm == nil, "untouched row changed")
        await store.forget(bundleIDs: ["com.a.b"])
        let after = await store.observedBundleIDs()
        try expect(after == ["com.c.d"], "forget failed: \(after)")
    }

    static func testWrongDeviceIgnored(_ root: URL) async throws {
        let dir = root.appendingPathComponent("device")
        let a = CapturedSoundStore(storage: dir, device: "deviceA")
        _ = await a.record([sound("com.a.b", "x.caf")])
        let b = CapturedSoundStore(storage: dir, device: "deviceB")
        let rows = await b.all()
        try expect(rows.isEmpty, "cache from another device must not load, got \(rows.count)")
    }

    static func testRejectsMalformed(_ root: URL) async throws {
        let store = CapturedSoundStore(storage: root.appendingPathComponent("malformed"), device: "dev")
        // No dot in bundle id, and an empty filename with a non-system origin.
        let bad1 = CapturedNotificationSound(bundleID: "notabundle", filename: "x.caf", origin: .bundle, relativeLocation: nil, lastSeen: Date())
        let bad2 = CapturedNotificationSound(bundleID: "com.a.b", filename: "", origin: .bundle, relativeLocation: nil, lastSeen: Date())
        let changed = await store.record([bad1, bad2])
        try expect(changed.isEmpty, "malformed rows must be rejected")
        try expect(await store.all().isEmpty, "store should be empty")
    }
}
