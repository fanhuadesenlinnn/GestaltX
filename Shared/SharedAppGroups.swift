// SPDX-License-Identifier: GPL-3.0-only
import Foundation

// Uses LCSign's runtime entitlement reader in both processes. Re-signing must
// preserve at least one group shared by the app and its embedded extension.
enum SharedAppGroups {
    private static var hostBundle: Bundle {
        let bundle = Bundle.main
        if bundle.bundleURL.pathExtension == "appex" {
            let parent = bundle.bundleURL.deletingLastPathComponent().deletingLastPathComponent()
            if let host = Bundle(url: parent) { return host }
        }
        return bundle
    }
    static var hostBundleIdentifier: String { hostBundle.bundleIdentifier ?? "com.huami.gestultx" }
    static var hostURLScheme: String {
        let types = hostBundle.object(forInfoDictionaryKey: "CFBundleURLTypes") as? [[String: Any]]
        return (types?.first?["CFBundleURLSchemes"] as? [String])?.first ?? "gestaltx"
    }

    static var inboxes: [SharedPlistInbox] {
        inboxes(kind: .mobileGestalt)
    }

    static var wallpaperInboxes: [SharedPlistInbox] {
        inboxes(kind: .wallpaper)
    }

    private static func inboxes(kind: SharedPlistInbox.Kind) -> [SharedPlistInbox] {
        GXEntitlementsReader.usableAppGroups().compactMap { group in
            guard let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group) else { return nil }
            return try? SharedPlistInbox(container: container, namespace: hostBundleIdentifier, kind: kind)
        }
    }

    static func oldestEntry() throws -> (SharedPlistInbox, SharedPlistEntry)? {
        var pending: [(SharedPlistInbox, SharedPlistEntry)] = []
        for inbox in inboxes { pending.append(contentsOf: try inbox.entries().map { (inbox, $0) }) }
        return pending.min { $0.1.created < $1.1.created }
    }
}
