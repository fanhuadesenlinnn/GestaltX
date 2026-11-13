// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import UserNotifications

/// Shows the short-lived RPPairing code while the user is over in Settings.
/// The code is never written to disk and is removed as soon as pairing ends.
enum PairingNotifier {
    static let identifier = "gestaltx.pairing.code"
    private static var requested = false

    static func requestAuthorization() async {
        guard !requested else { return }
        requested = true
        _ = try? await UNUserNotificationCenter.current()
            .requestAuthorization(options: [.alert, .sound])
    }

    static func show(code: String) async {
        let center = UNUserNotificationCenter.current()
        var settings = await center.notificationSettings()
        if settings.authorizationStatus == .notDetermined {
            _ = try? await center.requestAuthorization(options: [.alert, .sound])
            settings = await center.notificationSettings()
        }
        guard settings.authorizationStatus == .authorized
                || settings.authorizationStatus == .provisional
                || settings.authorizationStatus == .ephemeral else { return }

        let content = UNMutableNotificationContent()
        content.title = L("Pairing Code")
        content.body = "\(formatted(code))\n\(L("Enter this code in Settings to finish pairing."))"
        content.sound = .default
        content.threadIdentifier = "gestaltx.pairing"
        content.relevanceScore = 1
        content.userInfo = ["code": code]

        let request = UNNotificationRequest(identifier: identifier, content: content, trigger: nil)
        try? await center.add(request)
    }

    static func clear() {
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: [identifier])
        center.removeDeliveredNotifications(withIdentifiers: [identifier])
    }

    /// 123456 -> "123 456" so it is easy to read from the Dynamic Island.
    static func formatted(_ code: String) -> String {
        let digits = code.filter(\.isNumber)
        guard digits.count == 6 else { return code }
        let split = digits.index(digits.startIndex, offsetBy: 3)
        return "\(digits[..<split]) \(digits[split...])"
    }
}
