import Foundation
import AVFAudio

@main enum AppSoundTests {
    static func expect(_ condition: Bool, _ message: String) throws {
        if !condition { throw NSError(domain: "AppSoundTests", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
    }
    static func reject(_ operation: () async throws -> Void) async throws {
        do { try await operation() } catch { return }
        throw NSError(domain: "AppSoundTests", code: 2, userInfo: [NSLocalizedDescriptionKey: "Unsafe operation succeeded"])
    }
    static func wav(rate: Int = 16000, channels: Int = 1, frequency: Double = 440) -> Data {
        let frames = rate / 4, bytes = frames * channels * 2
        var data = Data()
        func text(_ value: String) { data.append(contentsOf: value.utf8) }
        func u32(_ value: Int) { var n = UInt32(value).littleEndian; withUnsafeBytes(of: &n) { data.append(contentsOf: $0) } }
        func u16(_ value: Int) { var n = UInt16(value).littleEndian; withUnsafeBytes(of: &n) { data.append(contentsOf: $0) } }
        text("RIFF"); u32(bytes + 36); text("WAVEfmt "); u32(16); u16(1); u16(channels)
        u32(rate); u32(rate * channels * 2); u16(channels * 2); u16(16); text("data"); u32(bytes)
        for frame in 0..<frames {
            var sample = Int16(sin(Double(frame) * frequency * 2 * .pi / Double(rate)) * 15000).littleEndian
            for _ in 0..<channels { withUnsafeBytes(of: &sample) { data.append(contentsOf: $0) } }
        }
        return data
    }
    static func main() async throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("GX-SoundTests-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: root) }
        let container = root.appendingPathComponent("App")
        let sounds = container.appendingPathComponent("Library/Sounds")
        try fm.createDirectory(at: sounds, withIntermediateDirectories: true)
        let target = sounds.appendingPathComponent("message.wav")
        let original = wav(), input = wav(rate: 24000, channels: 2, frequency: 880)
        try original.write(to: target)
        let imported = root.appendingPathComponent("import.wav"); try input.write(to: imported)
        let outside = root.appendingPathComponent("outside.wav"); try original.write(to: outside)
        try fm.createSymbolicLink(at: sounds.appendingPathComponent("linked.wav"), withDestinationURL: outside)
        try fm.createSymbolicLink(at: container.appendingPathComponent("Documents"), withDestinationURL: root)
        let favorites = container.appendingPathComponent("Library/WechatPrivate/account/Favorites/Data")
        try fm.createDirectory(at: favorites, withIntermediateDirectories: true)
        try original.write(to: favorites.appendingPathComponent("voice.wav"))
        let miniapp = container.appendingPathComponent("Library/WechatPrivate/account/WeApp/Sandbox")
        try fm.createDirectory(at: miniapp, withIntermediateDirectories: true)
        try original.write(to: miniapp.appendingPathComponent("sound.wav"))
        let nested = sounds.appendingPathComponent("Attachments")
        try fm.createDirectory(at: nested, withIntermediateDirectories: true)
        try original.write(to: nested.appendingPathComponent("voice.wav"))
        let app = LaunchArtworkApp(id: "test.audio", name: "Test")
        let storage = root.appendingPathComponent("GestaltX")
        let store = AppSoundStore(storage: storage, device: "install1", resolver: { _ in container })
        let scan = try await store.scan(app)
        try expect(scan.files.count == 1 && scan.files[0].path == "Library/Sounds/message.wav", "Notification scan included user audio, nested resources or symbolic links")
        let selection = try await store.select(scan.files[0], app: app)
        let converted = try await store.prepare(imported, selection: selection)
        let details = try AppSoundCodec.inspect(converted, extension: "wav")
        try expect(details.sampleRate == 16000 && details.channels == 1 && details.duration > 0.2, "Conversion lost the original stream format")
        try await store.apply(converted, selection: selection, app: app)
        let backup = target.appendingPathExtension("bak")
        try expect(try Data(contentsOf: backup) == original, "Original was not saved beside the audio")
        try expect(try Data(contentsOf: target) == converted, "Replacement did not persist")
        let ownFiles = fm.enumerator(at: storage, includingPropertiesForKeys: nil)!.allObjects as! [URL]
        try expect(ownFiles.allSatisfy { $0.lastPathComponent == app.id || $0.lastPathComponent == ".writer.lock" }, "Original bytes were stored in GestaltX")
        try fm.removeItem(at: storage)
        let fresh = AppSoundStore(storage: root.appendingPathComponent("Reinstalled"), device: "new-IDFV", resolver: { _ in container })
        let after = try await fresh.scan(app)
        let saved = try await fresh.select(after.files[0], app: app)
        try expect(saved.canRestore, "Reinstalling GestaltX lost restore availability")
        let another = try AppSoundCodec.replacement(wav(frequency: 220), suffix: "wav", original: converted, targetSuffix: "wav")
        try await fresh.apply(another, selection: saved, app: app)
        try expect(try Data(contentsOf: backup) == original, "Repeated replacement overwrote the first original")
        let currentEntries = try await fresh.scan(app)
        let current = try await fresh.select(currentEntries.files[0], app: app)
        try await fresh.restore(current, app: app)
        try expect(try Data(contentsOf: target) == original && Data(contentsOf: backup) == original, "Restore lost the persistent original")
        let restoredEntries = try await fresh.scan(app)
        let restored = try await fresh.select(restoredEntries.files[0], app: app)
        try input.write(to: target, options: .atomic)
        try await reject { try await fresh.apply(converted, selection: restored, app: app) }
        try expect(try Data(contentsOf: target) == input, "A stale selection overwrote app-generated data")
        try expect(!AppSoundDirectory.validPath("Library/../outside.wav") && !AppSoundDirectory.validPath("/Library/Sounds/x.wav"), "Unsafe paths accepted")
        try await reject { _ = try AppSoundCodec.inspect(Data("invalid".utf8), extension: "wav") }
        // An existing unrelated .bak is never replaced or silently adopted.
        let other = sounds.appendingPathComponent("other.wav"); try original.write(to: other)
        try input.write(to: other.appendingPathExtension("bak"))
        let entries = try await fresh.scan(app)
        let entry = entries.files.first { $0.path.hasSuffix("other.wav") }!
        try await reject { _ = try await fresh.select(entry, app: app) }
        try expect(try Data(contentsOf: other.appendingPathExtension("bak")) == input, "Unrelated .bak was overwritten")
        let groupRoot = root.appendingPathComponent("SharedGroup")
        let groupSounds = groupRoot.appendingPathComponent("Library/Sounds")
        try fm.createDirectory(at: groupSounds, withIntermediateDirectories: true)
        let groupTarget = groupSounds.appendingPathComponent("message.wav")
        try original.write(to: groupTarget)
        let sharedStore = AppSoundStore(storage: root.appendingPathComponent("SharedStore"), device: "device",
            resolver: { _ in container }, groupResolver: { _, group in
                guard group == "group.test.sound" else { throw CocoaError(.fileReadNoSuchFile) }
                return groupRoot
            }, groupInventory: { _ in ["group.test.sound"] })
        let sharedScan = try await sharedStore.scan(app)
        let sameNames = sharedScan.files.filter { $0.path == "Library/Sounds/message.wav" }
        try expect(sameNames.count == 2 && Set(sameNames.map(\.id)).count == 2, "Main and shared sound identities collided")
        let groupEntry = sameNames.first { $0.group != nil }!
        let groupSelection = try await sharedStore.select(groupEntry, app: app)
        try await sharedStore.apply(converted, selection: groupSelection, app: app)
        try expect(try Data(contentsOf: groupTarget) == converted && Data(contentsOf: target) == input, "Shared sound write targeted the main app")
        try expect(try Data(contentsOf: groupTarget.appendingPathExtension("bak")) == original, "Shared original was not stored beside its file")
        let changedGroupScan = try await sharedStore.scan(app)
        let changedGroup = try await sharedStore.select(changedGroupScan.files.first { $0.id == groupEntry.id }!, app: app)
        try await sharedStore.restore(changedGroup, app: app)
        try expect(try Data(contentsOf: groupTarget) == original, "Shared sound restoration failed")
        // Synthetic tones keep the MP3 passthrough case independent of ffmpeg at test time.
        let originalMP3 = Data(base64Encoded: "SUQzBAAAAAAAIlRTU0UAAAAOAAADTGF2ZjYzLjEuMTAxAAAAAAAAAAAAAAD/+1DEAAAKLEMuVZSAAYEVZiM60AAHqsOOM4XTZPGhwQgcWB9eHxgcRgQeieWzLloPqDsTa/D4YFAUBAMCgkQMTmjRo2wfeIAQBDE4P8EHTnT5zl/Ocv7un3cuD4Pg+HwQDEoAwf0gAQgAAQQAGGo6GHtxCABDFORkaDG0yjW4hQCBxvsHSnZzMDiiZiWExhGEi3uv1sEdAdPgOUSYLV+FqHaMKJb/juGGEuJEev/kiZF4vGJd//LpkXi8iXS7/EQVBURHv+CqAAABmcLaZSQU//tSxASCCUghIb3hACF/iuFRz9RIADBgAZgSAXiACQwBwPDP3e1Mxgcsw4giTBgA/MCEDAwKQJjAvAeLNWu2XOpVmadfq/kvyrf+tdv9X6v3pxvv//vABBgUEmOiAZ/R5viZGEoh5ZnszrGZ4SHmmEuAqgHFXCBo9QgaARwGgX6BksigKAQWWRQvmiCfb8vKV+6jqBnXuSnW6YvTl3o69Rotq9yvtRb+437p0wZQt7rTt8xf1oTVgEwEkBSMBQAcTAcwLgwMgFvMHdEgDMuIzgz/+1LEDQIL/FcKL+xGwUwEYeW/7EjGMRmMG0BOzZUoyQxNzXjlsk2A1DBZpsus9VNvpCraicijaJP3Vooesx3iD0b05BX362Oazko9t+tdVrBz3Pc88PVGc03QBCSoqBgAykpNcYjv90wcwLKMwdVyjL0gswwdUD5PQpDZnY1tpNYwDMC5Dd/KfAH016svoy4vTuIV/Wjtsb/xlLtm/c2byxuwgmM7yOpOUR6brhyBzHRFMgmIy4ozUtGMGOEBzKuX5UynAPxMFrBGgMlEcDEYgP/7UsQRggtgVwwufqJBLARiGb/sSAzISwNCqQDKomAkDRkidNtaXtrmfv7ue8hfF8o9XTO0enukv32j77JA4j5Noygvalq/y2gTfKXPEiDShAGZEOGop501sYM2EqmVsJLZlS4SyYM8BoHaxZqrKaQtGj1JkpOnRG6TMENWUF/Ro/1fRWUd8vfJJQj3Db1fZ/P9dbJ1W//pAFBBjsiGPjKZZUxpymmC+iDhlIkBsZP+IDGCrAkZoKcZQMm0oxw06asSiQc6sus9eddsCzdgo7vf//tSxByDCfQlDK5/YkFHhKGFv+xI+xleH9ik/ivKSFuj7ldWr+7orRr6P02gEChnJSbozHz9JhEwXYZy+tmGcDBeRhFoIaftdG7RhscCa90GaHhdt/JXSVwtkN1LKnbFKsUXZIO+p1+53TO6dO5lGldbd+q5DtF/7WV30aaaMBGAUzASQHYwGIDFMCvBhjBnhMkyy2VfMrgEsTBdQVg0BnM5GDgE06OsNpKg4ZadFbWq276xTLv0cM66lyKWZKui4qz7XbXijN2b/1LfR0PZ3XL/+1LEKYILGFUKD+xGwRaEoiK8EADAn6vZ9ygIgwqgDmAuCGYRIMJhNCtGMAX4e2X7Z4VrVmYOQ+YyYWpg3h2mGuF6YZYY5gNgcoVuvKLFghbw36v/yX37f/ut/T//p/11AAA0us2u23t1lEYCFYd4AThIia2dKr5O6hZvQhaKU0pkQxkRpon4XQCxhKs0oFIgz7wwaet1rZftuBrohgiBqwc0+1PAk3HnENIIAy0BKg4iz5wpW9T2T0OPJbNIlMOeGC5gC4MIZb1v8JzPutl12f/7UsQ4ABNYuUm5rQARHozYw57AAFp8JXrWVh3jq7jrvf73/gZyn1j0BROGOnyIYDgLN/61/9L0+4UFkmHhJbC7BHg5lGJKDlHC8H0F6BlCMowOIDMMY9QjoVIZjx0ZLrsnRkfRsmLsC6h0feyeu4u61tq6EgZBXiU6DQ8NkiwdEq3f1P4NQ0pMQU1FNC4wqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqq")!
        let replacementMP3 = Data(base64Encoded: "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")!
        let resourceFolder = container.appendingPathComponent("Library/Sound")
        try fm.createDirectory(at: resourceFolder, withIntermediateDirectories: true)
        let mp3Target = resourceFolder.appendingPathComponent("notification.mp3")
        try originalMP3.write(to: mp3Target)
        let mp3Import = root.appendingPathComponent("replacement.mp3")
        try replacementMP3.write(to: mp3Import)
        let mp3Scan = try await fresh.scan(app)
        let mp3Entry = mp3Scan.files.first { $0.path == "Library/Sound/notification.mp3" }
        try expect(mp3Entry != nil, "Non-CAF sound directory resource was excluded")
        let mp3Selection = try await fresh.select(mp3Entry!, app: app)
        let preparedMP3 = try await fresh.prepare(mp3Import, selection: mp3Selection)
        try expect(preparedMP3 == replacementMP3, "Matching MP3 should retain its encoded bytes")
        try await fresh.apply(preparedMP3, selection: mp3Selection, app: app)
        try expect(try Data(contentsOf: mp3Target) == replacementMP3, "MP3 sound replacement did not persist")
        try expect(try Data(contentsOf: mp3Target.appendingPathExtension("bak")) == originalMP3, "MP3 original was not saved")
        let named = try await fresh.prepareNamed(imported, name: "0.m4a")
        let namedInfo = try AppSoundCodec.inspect(named, extension: "m4a")
        try expect(namedInfo.format == kAudioFormatMPEG4AAC && namedInfo.duration < 1, "Named M4A override was not encoded as AAC")
        try await fresh.createNamed("0.m4a", data: named, app: app)
        let override = sounds.appendingPathComponent("0.m4a")
        try expect(try Data(contentsOf: override) == named, "Named override was not created")
        try await reject { try await fresh.createNamed("0.m4a", data: named, app: app) }
        let noLocalState = AppSoundStore(storage: root.appendingPathComponent("AfterAnotherReinstall"), device: "new-installation", resolver: { _ in container })
        let namedScan = try await noLocalState.scan(app)
        let namedEntry = namedScan.files.first { $0.path == "Library/Sounds/0.m4a" }!
        let namedSelection = try await noLocalState.select(namedEntry, app: app)
        try expect(namedSelection.canRestore, "The absent-original marker did not survive reinstall")
        try await noLocalState.restore(namedSelection, app: app)
        try expect(!fm.fileExists(atPath: override.path), "Restore did not remove a file that originally did not exist")
        try expect(fm.fileExists(atPath: override.appendingPathExtension("bak").path), "Absent-original marker was lost")
        try await noLocalState.createNamed("0.m4a", data: named, app: app)
        let again = try await noLocalState.scan(app)
        let againSelection = try await noLocalState.select(again.files.first { $0.path == "Library/Sounds/0.m4a" }!, app: app)
        let edited = try await noLocalState.prepare(imported, selection: againSelection)
        try await noLocalState.apply(edited, selection: againSelection, app: app)
        let editedScan = try await noLocalState.scan(app)
        let editedSelection = try await noLocalState.select(editedScan.files.first { $0.path == "Library/Sounds/0.m4a" }!, app: app)
        try await noLocalState.restore(editedSelection, app: app)
        try expect(!fm.fileExists(atPath: override.path), "Repeated replacements lost the original absence state")
        print("PASS: notification-only scan, format conversion, sibling originals, repeated replacements, reinstall restore, stale writes, symlinks and existing backup conflicts.")
    }
}
