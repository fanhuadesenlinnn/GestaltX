// SPDX-License-Identifier: GPL-3.0-only
import Foundation

// All fixtures are synthetic/desensitized. No private notification text, no real
// pairing codes, no raw user log is copied into the repository.
@main enum NotificationSoundLogParserTests {
    static func expect(_ condition: Bool, _ message: String) throws {
        if !condition { throw NSError(domain: "NSLogParserTests", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
    }

    static func sound(_ parser: NotificationSoundLogParser, _ bundle: String) -> CapturedNotificationSound? {
        parser.capturedSounds.first { $0.bundleID == bundle }
    }

    static func main() throws {
        try testBasicAppDataWithTrailingUUID()
        try testBundleOriginViaCreateEvent()
        try testContinuationFieldOnSeparateLine()
        try testInterleavedApps()
        try testOutOfOrderSoundBeforeBundle()
        try testPercentEscaping()
        try testDashedFilenameNotTruncated()
        try testLogTagNotMistakenForBundle()
        try testUnknownAppNotEmitted()
        try testSystemDefaultNotReplaceable()
        try testRepeatedCaptureUpdatesLastSeen()
        try testAppGroupOrigin()
        try testChunkedInputAcrossLineBoundary()
        try testStaleAssociationNotJoined()
        try testCaseInsensitiveFilenameDeduplication()
        print("NotificationSoundLogParserTests: all passed")
    }

    // Case: data container file + externalTone trailing UUID stripped to real name.
    static func testBasicAppDataWithTrailingUUID() throws {
        let p = NotificationSoundLogParser()
        p.consume("""
        [com.tencent.xin] Adding notification request 1A2B-3C4D for message
        Play sound for notification 1A2B-3C4D : <TLAlert toneIdentifier = "externalTone:/var/mobile/Containers/Data/Application/8E0F/Library/Sounds/empty.mp3-DEADBEEF-0000-1111-2222-333344445555">
        externalToneFileURL = file:///var/mobile/Containers/Data/Application/8E0F/Library/Sounds/empty.mp3

        """)
        guard let s = sound(p, "com.tencent.xin") else { throw err("wechat not captured") }
        try expect(s.filename == "empty.mp3", "filename \(s.filename)")
        try expect(s.origin == .appData, "origin \(s.origin)")
        try expect(s.relativeLocation == "Library/Sounds", "relative \(String(describing: s.relativeLocation))")
        try expect(s.representsReplaceableFile, "should be replaceable")
    }

    // Case, a missing extension dot, and trailing log punctuation all describe
    // the same file and must collapse to one row.
    static func testCaseInsensitiveFilenameDeduplication() throws {
        let p = NotificationSoundLogParser()
        p.consume("""
        [app.example.player] Adding notification request AA11 for a
        Play sound for notification AA11 : <TLAlert soundFileURL = file:///var/mobile/Containers/Data/Application/8E0F/Library/Sounds/a.m4a;>
        [app.example.player] Adding notification request BB22 for b
        Play sound for notification BB22 : <TLAlert soundFileURL = file:///var/mobile/Containers/Data/Application/8E0F/Library/Sounds/a.m4a>

        """)
        let rows = p.capturedSounds.filter { $0.bundleID == "app.example.player" }
        try expect(rows.count == 1, "semicolon/case variants were split into \(rows.count) rows")
        try expect(rows[0].identityFilename == "a.m4a", "filename \(rows[0].filename)")
        try expect(rows[0].cleanFilename == "a.m4a", "display filename \(rows[0].cleanFilename)")
    }

    // Case: structured [create, [id=.., bundle=..]] + bundle-local tone.
    static func testBundleOriginViaCreateEvent() throws {
        let p = NotificationSoundLogParser()
        p.consume("""
        [create, [id=55EE-66FF, bundle=com.ss.iphone.ugc.Aweme], action=present]
        Play sound for notification 55EE-66FF : <TLAlert toneIdentifier = "externalTone:/var/containers/Bundle/Application/7C1A/Aweme.app/douyin_new_im_tone6.caf">

        """)
        guard let s = sound(p, "com.ss.iphone.ugc.Aweme") else { throw err("douyin not captured") }
        try expect(s.filename == "douyin_new_im_tone6.caf", "filename \(s.filename)")
        try expect(s.origin == .bundle, "origin \(s.origin)")
        try expect(s.relativeLocation == "Aweme.app", "relative \(String(describing: s.relativeLocation))")
    }

    // Case: soundFileURL arrives on its own continuation line after Play sound.
    static func testContinuationFieldOnSeparateLine() throws {
        let p = NotificationSoundLogParser()
        p.consume("""
        [app.swiftgram.ios] Saving notification 77AA-88BB to store
        Play sound for notification 77AA-88BB : <TLAlert
            toneIdentifier = "externalTone:ignored"
            soundFileURL = file:///var/containers/Bundle/Application/90DD/Swiftgram.app/0.m4a

        """)
        guard let s = sound(p, "app.swiftgram.ios") else { throw err("swiftgram not captured") }
        try expect(s.filename == "0.m4a", "filename \(s.filename)")
        try expect(s.origin == .bundle, "origin \(s.origin)")
    }

    // Case: two apps' events interleaved; each sound joins its own request id.
    static func testInterleavedApps() throws {
        let p = NotificationSoundLogParser()
        p.consume("""
        [com.tencent.xin] Adding notification request AAAA-0001 for a
        [create, [id=BBBB-0002, bundle=com.ss.iphone.ugc.Aweme], action=present]
        Play sound for notification BBBB-0002 : <TLAlert toneIdentifier = "externalTone:/var/containers/Bundle/Application/X/Aweme.app/im6.caf">
        Play sound for notification AAAA-0001 : <TLAlert toneIdentifier = "externalTone:/var/mobile/Containers/Data/Application/Y/Library/Sounds/wx.caf">

        """)
        try expect(sound(p, "com.tencent.xin")?.filename == "wx.caf", "wechat wrong")
        try expect(sound(p, "com.ss.iphone.ugc.Aweme")?.filename == "im6.caf", "aweme wrong")
    }

    // Case: sound event is processed before the owning app event appears.
    static func testOutOfOrderSoundBeforeBundle() throws {
        let p = NotificationSoundLogParser()
        p.consume("Play sound for notification CCCC-9 : <TLAlert soundFileURL = file:///var/mobile/Containers/Data/Application/Z/Library/Sounds/late.caf>\n")
        try expect(p.capturedSounds.isEmpty, "must not emit before bundle known")
        p.consume("[com.example.late] Saving notification CCCC-9 done\n")
        try expect(sound(p, "com.example.late")?.filename == "late.caf", "late join failed")
    }

    // Case: percent-encoded file URL is decoded.
    static func testPercentEscaping() throws {
        let p = NotificationSoundLogParser()
        p.consume("""
        [com.example.space] Adding notification request DD-1 x
        Play sound for notification DD-1 : <TLAlert soundFileURL = file:///var/mobile/Containers/Data/Application/Q/Library/Sounds/my%20tone.caf>

        """)
        try expect(sound(p, "com.example.space")?.filename == "my tone.caf", "percent decode failed")
    }

    // Case: a legitimate dash in the filename is NOT cut (no canonical UUID suffix).
    static func testDashedFilenameNotTruncated() throws {
        let p = NotificationSoundLogParser()
        p.consume("""
        [com.example.dash] Adding notification request EE-2 x
        Play sound for notification EE-2 : <TLAlert toneIdentifier = "externalTone:/var/containers/Bundle/Application/W/Dash.app/im-tone-6.caf">

        """)
        try expect(sound(p, "com.example.dash")?.filename == "im-tone-6.caf", "dashed name truncated")
    }

    // Case: a log category tag with no dot/no event structure is not a bundle id.
    static func testLogTagNotMistakenForBundle() throws {
        let p = NotificationSoundLogParser()
        p.consume("""
        [NCNotificationStructuredSectionList] Adding notification request FF-3 x
        Play sound for notification FF-3 : <TLAlert soundFileURL = file:///var/mobile/Containers/Data/Application/V/Library/Sounds/ghost.caf>

        """)
        try expect(p.capturedSounds.isEmpty, "log tag must not become a bundle")
    }

    // Case: sound with a file but no app association is never attributed.
    static func testUnknownAppNotEmitted() throws {
        let p = NotificationSoundLogParser()
        p.consume("Play sound for notification GG-4 : <TLAlert soundFileURL = file:///var/mobile/Containers/Data/Application/U/Library/Sounds/orphan.caf>\n")
        try expect(p.capturedSounds.isEmpty, "orphan sound must not emit")
    }

    // Case: system default tone is shown but not as a replaceable file.
    static func testSystemDefaultNotReplaceable() throws {
        let p = NotificationSoundLogParser()
        p.consume("""
        [com.example.sys] Adding notification request HH-5 x
        Play sound for notification HH-5 : <TLAlert toneIdentifier = "default">

        """)
        guard let s = sound(p, "com.example.sys") else { throw err("system tone not recorded") }
        try expect(s.origin == .system, "origin \(s.origin)")
        try expect(!s.representsReplaceableFile, "system default must not be replaceable")
    }

    // Case: seeing the same sound twice keeps a single entry, newest lastSeen.
    static func testRepeatedCaptureUpdatesLastSeen() throws {
        var clock = Date(timeIntervalSince1970: 1_000_000)
        let p = NotificationSoundLogParser(now: { clock })
        p.consume("[com.example.rep] Adding notification request II-6 x\nPlay sound for notification II-6 : <TLAlert soundFileURL = file:///var/mobile/Containers/Data/Application/R/Library/Sounds/r.caf>\n")
        let first = sound(p, "com.example.rep")!.lastSeen
        clock = clock.addingTimeInterval(30)
        p.consume("[com.example.rep] Adding notification request II-7 x\nPlay sound for notification II-7 : <TLAlert soundFileURL = file:///var/mobile/Containers/Data/Application/R/Library/Sounds/r.caf>\n")
        try expect(p.capturedSounds.filter { $0.bundleID == "com.example.rep" }.count == 1, "should dedupe")
        try expect(sound(p, "com.example.rep")!.lastSeen > first, "lastSeen not updated")
    }

    // Case: shared App Group Library/Sounds path.
    static func testAppGroupOrigin() throws {
        let p = NotificationSoundLogParser()
        p.consume("""
        [com.example.grp] Adding notification request JJ-8 x
        Play sound for notification JJ-8 : <TLAlert soundFileURL = file:///var/mobile/Containers/Shared/AppGroup/ABCD/Library/Sounds/g.caf>

        """)
        try expect(sound(p, "com.example.grp")?.origin == .appGroup, "appGroup origin failed")
    }

    // Case: input split so that a line is delivered across two chunks.
    static func testChunkedInputAcrossLineBoundary() throws {
        let p = NotificationSoundLogParser()
        p.consume("[com.example.chunk] Adding notification request KK-9 x\nPlay sound for notification KK-9 : <TLAlert soundFileURL = file:///var/mobile/Containers/Data/App")
        try expect(p.capturedSounds.isEmpty, "should wait for full line")
        p.consume("lication/C/Library/Sounds/chunk.caf>\n")
        try expect(sound(p, "com.example.chunk")?.filename == "chunk.caf", "chunked join failed")
    }

    // Case: a request id reused long after its association has expired is not joined.
    static func testStaleAssociationNotJoined() throws {
        var clock = Date(timeIntervalSince1970: 2_000_000)
        var opts = NotificationSoundLogParser.Options()
        opts.requestTTL = 60
        let p = NotificationSoundLogParser(now: { clock }, options: opts)
        p.consume("[com.example.old] Saving notification LL-1 x\n")
        clock = clock.addingTimeInterval(600)   // long after, TTL expired
        p.consume("Play sound for notification LL-1 : <TLAlert soundFileURL = file:///var/mobile/Containers/Data/Application/O/Library/Sounds/old.caf>\n")
        try expect(p.capturedSounds.isEmpty, "stale id must not join")
    }

    static func err(_ m: String) -> NSError { NSError(domain: "NSLogParserTests", code: 9, userInfo: [NSLocalizedDescriptionKey: m]) }
}
