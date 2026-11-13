//
//  GestaltXApp.swift
//  GestaltX
//

import SwiftUI

@main
struct GestaltXApp: App {
    init() {
        // Register the continued-processing launch handler early. It is only
        // ever *submitted* later, from an explicit pairing/capture action.
        DeviceConsoleBackgroundTask.shared.registerIfNeeded()
        // A reinstall can move the app's data container while the pairing
        // index keeps its old absolute path. Resolve it once at launch so
        // capture never opens a stale path.
        Task {
            let store = DevicePairingStore(directory: DeviceConsolePaths.pairing,
                                           device: DeviceConsolePaths.deviceIdentifier)
            _ = await store.currentPairingPath()
        }
    }
    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(\.layoutDirection, Bundle.main.preferredLocalizations.first?.hasPrefix("fa") == true ? .rightToLeft : .leftToRight)
        }
    }
}
