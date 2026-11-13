// SPDX-License-Identifier: GPL-3.0-only
import Foundation
#if canImport(UIKit)
import UIKit
#endif

/// Shared storage locations for the device-console feature. Everything lives in
/// private Application Support, device-bound by `deviceIdentifier`.
enum DeviceConsolePaths {
    static func base() -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    }
    static var pairing: URL { base().appendingPathComponent("GestaltX/Pairing", isDirectory: true) }
    static var capturedSounds: URL { base().appendingPathComponent("GestaltX/CapturedSounds", isDirectory: true) }

    static var deviceIdentifier: String {
        #if canImport(UIKit)
        return UIDevice.current.identifierForVendor?.uuidString ?? ""
        #else
        return ""
        #endif
    }

    /// Bundle id at runtime — background-task identifiers derive from this so a
    /// self-signed rewrite of the bundle id does not break registration.
    static var runtimeBundleID: String {
        Bundle.main.bundleIdentifier ?? "com.huami.gestaltx"
    }

    static var hostModelName: String {
        #if canImport(UIKit)
        return UIDevice.current.model
        #else
        return "iPhone"
        #endif
    }
}
