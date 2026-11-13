// SPDX-License-Identifier: GPL-3.0-only
import Foundation

/// A single notification sound captured from the device system log, associated
/// to the app that played it. The parser only emits a value when it has enough
/// evidence (a bundle identifier joined to a concrete sound), and it never
/// fabricates a filename for a system default sound.
struct CapturedNotificationSound: Codable, Hashable, Sendable, Identifiable {
    enum Origin: String, Codable, Sendable {
        case appData    // App's own Library/Sounds data container.
        case appGroup   // Shared App Group Library/Sounds.
        case bundle     // Inside the app bundle (.app).
        case system     // System default tone, not a replaceable file.
        case unknown    // Known filename, unresolved location.
    }
    var bundleID: String
    var filename: String
    var origin: Origin
    /// A short, readable relative location (e.g. "Library/Sounds"). Never a full
    /// private container path and never the raw log line.
    var relativeLocation: String?
    var lastSeen: Date
    /// Set by the store after a container/app change: the filename clue is kept
    /// but its resolved location must be re-confirmed before use. `nil` = fresh.
    var needsReconfirm: Bool?
    /// APFS is case-insensitive, and some log paths omit the dot before the
    /// extension (`0M4A` vs `0.M4A`). Keep the original spelling for
    /// display/writes, but normalize the identity for deduplication.
    /// Log lines often terminate a filename with punctuation (`a.m4a;`,
    /// `"a.m4a",`). That punctuation is not part of the file name.
    static func cleanedName(_ name: String) -> String {
        var value = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let trailing = CharacterSet(charactersIn: ";,，。；、\"'“”‘’)]}>")
        while let last = value.last, last.unicodeScalars.allSatisfy({ trailing.contains($0) }) {
            value.removeLast()
            value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return value
    }

    static func normalizedName(_ name: String) -> String {
        let lower = cleanedName(name)
            .precomposedStringWithCanonicalMapping
            .lowercased()
        let extensions = ["aiff", "flac", "m4a", "caf", "wav", "mp3", "aac", "aif"]
        for ext in extensions where lower.hasSuffix(ext) {
            let base = String(lower.dropLast(ext.count))
            if !base.isEmpty, !base.hasSuffix(".") {
                return base + "." + ext
            }
            break
        }
        return lower
    }

    var identityFilename: String { Self.normalizedName(filename) }
    var cleanFilename: String { Self.cleanedName(filename) }
    var id: String { bundleID + "\u{0}" + identityFilename }

    /// A system default tone has no concrete file to overwrite.
    var representsReplaceableFile: Bool { origin != .system && !filename.isEmpty }
}

/// Parses `com.apple.syslog_relay` output in memory to determine which app
/// played which notification sound. The parser is bounded (TTL + capacity) and
/// accepts input line-by-line or in arbitrary chunks. It keeps no original log
/// text once a line has been consumed.
final class NotificationSoundLogParser {
    struct Options {
        /// How long an un-joined request-id association stays valid.
        var requestTTL: TimeInterval = 300
        /// Maximum number of pending request-id entries kept at once.
        var capacity: Int = 512
        /// Lines longer than this are not trusted (truncated records are dropped).
        var maxLineLength: Int = 65_536
        /// How long a "Play sound" continuation context stays active for the
        /// following indented fields (toneIdentifier / *FileURL on their own line).
        var continuationWindow: TimeInterval = 5
        init() {}
    }

    private struct Timed<T> { var value: T; var time: Date }

    private struct PendingSound {
        var filename: String?
        var origin: CapturedNotificationSound.Origin = .unknown
        var relativeLocation: String?
        var isSystemDefault = false
        var firstSeen: Date
        var hasConcreteFile: Bool { filename != nil || isSystemDefault }
    }

    private let now: () -> Date
    private let options: Options

    private var bundleByRequest: [String: Timed<String>] = [:]
    private var pendingByRequest: [String: Timed<PendingSound>] = [:]
    private var lineBuffer = ""

    // Active "Play sound" continuation: following indented field lines belong here.
    private var activeRequest: String?
    private var activeUntil: Date = .distantPast

    private(set) var results: [String: CapturedNotificationSound] = [:]

    init(now: @escaping () -> Date = Date.init, options: Options = Options()) {
        self.now = now
        self.options = options
    }

    /// Deduplicated captured sounds, newest `lastSeen` kept per (bundle, file).
    var capturedSounds: [CapturedNotificationSound] {
        results.values.sorted { $0.lastSeen > $1.lastSeen }
    }

    // MARK: - Feeding input

    /// Consume a chunk of log text (possibly spanning partial lines). Returns the
    /// sounds finalized during this call.
    @discardableResult
    func consume(_ chunk: String) -> [CapturedNotificationSound] {
        lineBuffer += chunk
        var emitted: [CapturedNotificationSound] = []
        // Split on \n and NUL, ignore \r (matches upstream syslog line framing).
        while let idx = lineBuffer.firstIndex(where: { $0 == "\n" || $0 == "\u{0}" }) {
            let raw = String(lineBuffer[lineBuffer.startIndex..<idx])
            lineBuffer.removeSubrange(lineBuffer.startIndex...idx)
            emitted.append(contentsOf: process(line: raw))
        }
        // Guard against an unbounded line with no terminator.
        if lineBuffer.utf8.count > options.maxLineLength {
            lineBuffer = ""
        }
        return emitted
    }

    @discardableResult
    func consumeLine(_ line: String) -> [CapturedNotificationSound] {
        process(line: line)
    }

    // MARK: - Line processing

    private func process(line rawLine: String) -> [CapturedNotificationSound] {
        let line = rawLine.hasSuffix("\r") ? String(rawLine.dropLast()) : rawLine
        // Over-length records are not trusted: drop rather than mis-parse.
        if line.utf8.count > options.maxLineLength { return [] }
        let t = now()
        expire(reference: t)
        var emitted: [CapturedNotificationSound] = []

        // 1. Structured create event: [create, [id=.., bundle=..], ..]
        if line.contains("create"), line.contains("id="), line.contains("bundle=") {
            if let id = Self.firstGroup(Self.createID, in: line),
               let bundle = Self.firstGroup(Self.createBundle, in: line),
               Self.isValidBundleID(bundle) {
                associate(request: id, bundle: bundle, at: t, into: &emitted)
                return emitted
            }
        }

        // 2. Bracket-tagged app event: [bundle] Adding notification request <ID>
        if let m = Self.firstTwoGroups(Self.bracketApp, in: line) {
            if Self.isValidBundleID(m.0) {
                associate(request: m.1, bundle: m.0, at: t, into: &emitted)
                return emitted
            }
        }

        // 3. Play sound event starts a continuation context.
        if let id = Self.firstGroup(Self.playSound, in: line) {
            activeRequest = id
            activeUntil = t.addingTimeInterval(options.continuationWindow)
            applySoundFields(from: line, to: id, at: t, into: &emitted)
            return emitted
        }

        // 4. Continuation field lines (toneIdentifier / *FileURL on their own line).
        if let id = activeRequest, t <= activeUntil,
           Self.hasSoundField(line) {
            applySoundFields(from: line, to: id, at: t, into: &emitted)
            return emitted
        }

        // Any other recognizable event line ends the continuation window.
        if !line.trimmingCharacters(in: .whitespaces).isEmpty, !Self.hasSoundField(line) {
            activeRequest = nil
        }
        return emitted
    }

    // MARK: - Sound field extraction

    private func applySoundFields(from line: String, to request: String, at t: Date,
                                  into emitted: inout [CapturedNotificationSound]) {
        var pending = pendingByRequest[request]?.value ?? PendingSound(firstSeen: t)

        // Prefer concrete file URLs; they are already resolved and percent-encoded.
        if let url = Self.firstGroup(Self.externalURL, in: line) ?? Self.firstGroup(Self.soundURL, in: line),
           let path = Self.fileURLPath(url) {
            let info = Self.analyze(path: path)
            pending.filename = info.filename
            pending.origin = info.origin
            pending.relativeLocation = info.relative
            pending.isSystemDefault = false
        } else if let tone = Self.firstGroup(Self.toneIdentifier, in: line) {
            if let ext = Self.externalTonePath(tone) {
                let info = Self.analyze(path: ext)
                if pending.filename == nil {   // don't override a resolved file URL
                    pending.filename = info.filename
                    pending.origin = info.origin
                    pending.relativeLocation = info.relative
                }
            } else if Self.isSystemTone(tone) {
                if pending.filename == nil { pending.isSystemDefault = true }
            }
        }

        pendingByRequest[request] = Timed(value: pending, time: t)
        trim(&pendingByRequest)
        finalizeIfReady(request: request, at: t, into: &emitted)
    }

    // MARK: - Association & finalization

    private func associate(request: String, bundle: String, at t: Date,
                           into emitted: inout [CapturedNotificationSound]) {
        bundleByRequest[request] = Timed(value: bundle, time: t)
        trim(&bundleByRequest)
        finalizeIfReady(request: request, at: t, into: &emitted)
    }

    private func finalizeIfReady(request: String, at t: Date,
                                 into emitted: inout [CapturedNotificationSound]) {
        guard let bundleEntry = bundleByRequest[request],
              let pendingEntry = pendingByRequest[request],
              pendingEntry.value.hasConcreteFile else { return }
        // Do not join across a stale association (reused request id much later).
        guard abs(bundleEntry.time.timeIntervalSince(pendingEntry.value.firstSeen)) <= options.requestTTL
        else { return }

        let pending = pendingEntry.value
        let sound = CapturedNotificationSound(
            bundleID: bundleEntry.value,
            filename: (pending.filename ?? "").trimmingCharacters(in: .whitespacesAndNewlines),
            origin: pending.isSystemDefault ? .system : pending.origin,
            relativeLocation: pending.relativeLocation,
            lastSeen: t)

        if var existing = results[sound.id] {
            if t > existing.lastSeen { existing.lastSeen = t }
            // Upgrade origin/location if we learned something more specific.
            if existing.origin == .unknown, sound.origin != .unknown {
                existing.origin = sound.origin
                existing.relativeLocation = sound.relativeLocation ?? existing.relativeLocation
            }
            results[sound.id] = existing
        } else {
            results[sound.id] = sound
        }
        emitted.append(results[sound.id]!)
        pendingByRequest[request] = nil     // consume the pending sound; keep bundle mapping briefly
    }

    // MARK: - Bounds

    private func expire(reference t: Date) {
        let ttl = options.requestTTL
        bundleByRequest = bundleByRequest.filter { t.timeIntervalSince($0.value.time) <= ttl }
        pendingByRequest = pendingByRequest.filter { t.timeIntervalSince($0.value.time) <= ttl }
    }

    private func trim<V>(_ map: inout [String: Timed<V>]) {
        guard map.count > options.capacity else { return }
        let overflow = map.count - options.capacity
        let oldest = map.sorted { $0.value.time < $1.value.time }.prefix(overflow).map(\.key)
        for key in oldest { map[key] = nil }
    }

    // MARK: - Static helpers (regex + path analysis)

    private static func regex(_ pattern: String) -> NSRegularExpression {
        try! NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
    }

    private static let createID = regex(#"\bid\s*=\s*([A-Za-z0-9][A-Za-z0-9\-]{2,})"#)
    private static let createBundle = regex(#"\bbundle\s*=\s*([A-Za-z0-9][A-Za-z0-9._\-]+)"#)
    private static let bracketApp = regex(#"^\s*\[([A-Za-z0-9][A-Za-z0-9._\-]+)\]\s+(?:Adding notification request|Saving notification)\s+([A-Za-z0-9][A-Za-z0-9\-]{2,})"#)
    private static let playSound = regex(#"Play sound for notification\s+([A-Za-z0-9][A-Za-z0-9\-]{2,})\s*:"#)
    private static let toneIdentifier = regex(#"toneIdentifier\s*=\s*"?([^"\s,>]+)"?"#)
    private static let externalURL = regex(#"externalToneFileURL\s*=\s*(file:[^\s,>}]+)"#)
    private static let soundURL = regex(#"soundFileURL\s*=\s*(file:[^\s,>}]+)"#)
    private static let trailingUUID = regex(#"-[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$"#)

    private static func hasSoundField(_ line: String) -> Bool {
        line.contains("toneIdentifier") || line.contains("externalToneFileURL") || line.contains("soundFileURL")
    }

    static func isValidBundleID(_ s: String) -> Bool {
        // Reverse-DNS: at least two dot-separated alphanumeric labels.
        let pattern = #"^[A-Za-z0-9][A-Za-z0-9\-]*(\.[A-Za-z0-9][A-Za-z0-9\-]*)+$"#
        guard s.range(of: pattern, options: .regularExpression) != nil else { return false }
        // Reject obvious non-bundles (pure numeric version strings).
        return s.contains(where: { $0.isLetter })
    }

    private static func isSystemTone(_ tone: String) -> Bool {
        let lower = tone.lowercased()
        return lower == "default" || lower.hasPrefix("system:") || lower == "none" || lower.hasPrefix("ctcall")
    }

    /// Extract the file path from an `externalTone:` tone identifier, stripping a
    /// clear trailing canonical UUID only (never a bare last-dash cut).
    static func externalTonePath(_ tone: String) -> String? {
        guard tone.lowercased().hasPrefix("externaltone:") else { return nil }
        let path = String(tone.dropFirst("externalTone:".count))
        guard !path.isEmpty else { return nil }
        return path
    }

    static func fileURLPath(_ raw: String) -> String? {
        if let url = URL(string: raw), url.isFileURL { return url.path }
        // Fallback: strip scheme and percent-decode.
        guard let range = raw.range(of: "file://") else { return nil }
        let rest = String(raw[range.upperBound...])
        let path = rest.hasPrefix("/") ? rest : "/" + rest
        return path.removingPercentEncoding ?? path
    }

    struct PathInfo { var filename: String; var origin: CapturedNotificationSound.Origin; var relative: String? }

    static func analyze(path: String) -> PathInfo {
        var last = CapturedNotificationSound.cleanedName((path as NSString).lastPathComponent)
        // Only strip a clearly-formed trailing UUID appended after the full name.
        if let m = trailingUUID.firstMatch(in: last, range: NSRange(last.startIndex..., in: last)),
           let r = Range(m.range, in: last) {
            let stripped = String(last[..<r.lowerBound])
            if stripped.contains(".") { last = stripped }   // keep only if a real name+ext remains
        }
        let origin: CapturedNotificationSound.Origin
        if path.contains("/Containers/Shared/AppGroup/") || path.contains("/Shared/SystemGroup/") {
            origin = .appGroup
        } else if path.contains("/Containers/Data/Application/") || path.contains("/Data/Application/") {
            origin = .appData
        } else if path.range(of: #"/Bundle/Application/"#) != nil || path.contains(".app/") {
            origin = .bundle
        } else {
            origin = .unknown
        }
        return PathInfo(filename: last, origin: origin, relative: relativeLocation(path: path, origin: origin))
    }

    /// A short readable location with no private container UUIDs.
    private static func relativeLocation(path: String, origin: CapturedNotificationSound.Origin) -> String? {
        let comps = path.split(separator: "/").map(String.init)
        guard comps.count >= 2 else { return nil }
        let dir = Array(comps.dropLast())   // drop filename
        switch origin {
        case .appData, .appGroup:
            if let i = dir.firstIndex(of: "Library") { return dir[i...].joined(separator: "/") }
            return dir.suffix(2).joined(separator: "/")
        case .bundle:
            if let i = dir.firstIndex(where: { $0.hasSuffix(".app") }) { return dir[i...].joined(separator: "/") }
            return dir.suffix(1).joined(separator: "/")
        case .unknown, .system:
            return dir.suffix(2).joined(separator: "/")
        }
    }

    private static func firstGroup(_ re: NSRegularExpression, in s: String) -> String? {
        let range = NSRange(s.startIndex..., in: s)
        guard let m = re.firstMatch(in: s, range: range), m.numberOfRanges > 1,
              let r = Range(m.range(at: 1), in: s) else { return nil }
        return String(s[r])
    }

    private static func firstTwoGroups(_ re: NSRegularExpression, in s: String) -> (String, String)? {
        let range = NSRange(s.startIndex..., in: s)
        guard let m = re.firstMatch(in: s, range: range), m.numberOfRanges > 2,
              let r1 = Range(m.range(at: 1), in: s), let r2 = Range(m.range(at: 2), in: s)
        else { return nil }
        return (String(s[r1]), String(s[r2]))
    }
}
