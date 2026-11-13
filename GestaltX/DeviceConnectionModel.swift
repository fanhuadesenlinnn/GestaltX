// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import Combine
#if canImport(UIKit)
import UIKit
#endif

@MainActor
final class DeviceConnectionModel: ObservableObject {
    enum State: Equatable {
        case idle           // not paired yet
        case advertising    // host is up, waiting for the device to connect
        case pairing        // handshake in progress (PIN shown)
        case paired         // a pairing record exists
        case failed(String)
    }

    enum VPNState: Equatable {
        case unknown
        case checking
        case ready(String)
        case unavailable
    }

    @Published private(set) var state: State = .idle
    @Published private(set) var pin: String?
    @Published private(set) var record: DevicePairingRecord?
    @Published private(set) var busy = false
    @Published private(set) var vpnState: VPNState = .unknown
    @Published var message: String?
    @Published var loopbackHost: String = ""

    private let store = DevicePairingStore(directory: DeviceConsolePaths.pairing, device: DeviceConsolePaths.deviceIdentifier)
    private let advertiser = PairableHostAdvertiser()
    private var pairingTask: Task<Void, Never>?
    private var backgroundTaskActive = false
    private var screenWasKeptAwake = false
    private var legacyBackgroundTask: UIBackgroundTaskIdentifier = .invalid
    private var vpnCheckTask: Task<String?, Never>?
    private let keepAlive = AudioKeepAlive()

    var consoleAvailable: Bool { DeviceConsole.shared.isAvailable }

    func load() {
        Task {
            let existing = await store.current()
            if let existing, await store.currentPairingPath() != nil {
                self.record = existing
                self.state = .paired
            } else if existing != nil {
                // The index survived but the native record did not. Keep the
                // metadata visible, but require pairing again before capture.
                self.record = existing
                self.state = .idle
                self.message = L("The saved pairing file is missing. Pair this iPhone again before capturing.")
            } else {
                self.record = nil
                self.state = .idle
            }
        }
    }

    /// Begin a real self-pairing: bind the host, advertise over Bonjour, show the
    /// PIN, and persist a record only once the handshake actually completes.
    func beginPairing() {
        guard !busy, pairingTask == nil else { return }
        guard DeviceConsole.shared.isAvailable else { message = DeviceConsoleError.unavailable.localizedDescription; return }
        busy = true
        pin = nil
        state = .advertising
        PairingNotifier.clear()
        askForNotificationPermission()
        keepScreenAwake()
        // The continued-processing task can be unavailable after side-load
        // re-signing. Keep the pairing host resident while the user is in
        // Settings with the same audio background mode used by capture.
        keepAlive.start()

        // The user has to leave the app for Settings. Without a continued
        // processing task iOS suspends us and the Bonjour host disappears;
        // the system also uses this task for the Dynamic Island card.
        backgroundTaskActive = DeviceConsoleBackgroundTask.shared.begin(
            title: L("GestaltX Pairing"),
            subtitle: L("Privacy & Security → Developer Mode"),
            fraction: 0.05,
            onExpire: { [weak self] in self?.cancel() })
        if !backgroundTaskActive {
            message = L("iOS could not start the background pairing task. Keep GestaltX open, or try again in a moment.")
            beginLegacyBackgroundTask()
        }

        pairingTask = Task {
            let outPath = await store.pairingDirectory().appendingPathComponent("gestaltx_pairing.plist").path
            // A failed/aborted attempt can leave an unreadable native pairing
            // file behind. Without a stored record, discard it so the next
            // handshake starts from a clean identity.
            if record == nil { try? FileManager.default.removeItem(atPath: outPath) }
            let altIRK = await store.savedHostAltIRKHex()
            do {
                let outcome = try await DeviceConsole.shared.runPairing(
                    bindAddr: "0.0.0.0", port: 0, name: "GestaltX", model: DeviceConsolePaths.hostModelName,
                    outPath: outPath, altIRKHex: altIRK,
                    ready: { [weak self] serviceID, port, txt in
                        Task { @MainActor in
                            self?.advertiser.publish(port: port, serviceID: serviceID, txt: txt)
                            DeviceConsoleBackgroundTask.shared.update(
                                subtitle: L("Privacy & Security → Developer Mode"),
                                fraction: 0.2)
                        }
                    },
                    pin: { [weak self] value in
                        Task { @MainActor in
                            self?.pin = value
                            self?.state = .pairing
                            let formatted = PairingNotifier.formatted(value)
                            DeviceConsoleBackgroundTask.shared.update(
                                subtitle: "\(L("Pairing Code")): \(formatted)",
                                fraction: 0.6)
                            UINotificationFeedbackGenerator().notificationOccurred(.success)
                            UIAccessibility.post(notification: .announcement, argument: "\(L("Pairing Code")) \(formatted)")
                            Task { await PairingNotifier.show(code: value) }
                        }
                    })
                let new = DevicePairingRecord(
                    deviceName: outcome.deviceName, deviceModel: outcome.deviceModel, deviceUDID: outcome.deviceUDID,
                    pairingFilePath: outcome.pairingFilePath, hostAltIRKHex: outcome.hostAltIRKHex,
                    pairedAt: Date(), lastConnected: nil)
                await store.store(new)
                self.record = new
                self.state = .paired
                self.pin = nil
                self.finishBackgroundTask(success: true)
            } catch is CancellationError {
                self.state = self.record == nil ? .idle : .paired
                self.finishBackgroundTask(success: false)
            } catch {
                let text = error.localizedDescription
                self.message = text
                self.state = .failed(text)
                self.finishBackgroundTask(success: false)
            }
            self.advertiser.stop()
            self.pin = nil
            self.busy = false
            self.pairingTask = nil
        }
    }

    func cancel() {
        DeviceConsole.shared.cancelCurrent()
        pairingTask?.cancel()
        advertiser.stop()
        if !busy { return }
    }

    func clearPairing() {
        Task {
            await store.clear()
            self.record = nil
            self.state = .idle
        }
    }

    /// Candidate loopback hosts to feed the native tunnel, honoring the user's
    /// edited gateway address.
    func applyTargetHosts() {
        let hosts = LoopbackRoute.candidateHosts(userConfigured: loopbackHost.isEmpty ? [] : [loopbackHost])
        DeviceConsole.shared.setTargetHosts(hosts)
    }

    /// Probe the loopback tunnel before capture. A plain proxy VPN also raises
    /// a utun, so this checks the RSD port instead of assuming the VPN is ready.
    func checkVPN(showProgress: Bool = true) async -> String? {
        // Coalesce taps and the automatic refresh onto one probe. Previously a
        // tap during the periodic check returned nil and the first tap looked
        // like it did nothing.
        if let vpnCheckTask { return await vpnCheckTask.value }
        if showProgress || vpnState == .unknown { vpnState = .checking }
        let task = Task<String?, Never> { @MainActor [weak self] in
            guard let self else { return nil }
            let hosts = LoopbackRoute.candidateHosts(userConfigured: self.loopbackHost.isEmpty ? [] : [self.loopbackHost])
            if let host = await LoopbackRoute.firstReachable(in: hosts) {
                self.vpnState = .ready(host)
                self.loopbackHost = host
                DeviceConsole.shared.setTargetHosts([host])
                return host
            }
            self.vpnState = .unavailable
            return nil
        }
        vpnCheckTask = task
        let result = await task.value
        vpnCheckTask = nil
        return result
    }

    /// Resolve the native pairing file against the current data container.
    func currentPairingPath() async -> String? {
        await store.currentPairingPath()
    }

    /// Best-effort deep link; LocalDevVPN has no documented public scheme, so
    /// fall back to the app's Settings page if the open request is rejected.
    func openLocalDevVPN() {
        #if canImport(UIKit)
        let candidates = ["localdevvpn://", "LocalDevVPN://", "localdevvpn:"]
        for string in candidates {
            guard let url = URL(string: string) else { continue }
            UIApplication.shared.open(url, options: [:]) { opened in
                if !opened, let settings = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(settings)
                }
            }
            return
        }
        #endif
    }

    // MARK: - Pairing session helpers

    private func askForNotificationPermission() {
        Task { await PairingNotifier.requestAuthorization() }
    }

    private func keepScreenAwake() {
        #if canImport(UIKit)
        if !screenWasKeptAwake {
            screenWasKeptAwake = true
            UIApplication.shared.isIdleTimerDisabled = true
        }
        #endif
    }

    /// Best-effort fallback for systems where the continued-processing task is
    /// unavailable. Gives the handshake a short window while Settings is open.
    private func beginLegacyBackgroundTask() {
        #if canImport(UIKit)
        guard legacyBackgroundTask == .invalid else { return }
        legacyBackgroundTask = UIApplication.shared.beginBackgroundTask(withName: "gestaltx.pairing") { [weak self] in
            self?.cancel()
        }
        #endif
    }

    private func finishBackgroundTask(success: Bool) {
        if backgroundTaskActive {
            DeviceConsoleBackgroundTask.shared.end(success: success)
            backgroundTaskActive = false
        }
        PairingNotifier.clear()
        keepAlive.stop()
        #if canImport(UIKit)
        if legacyBackgroundTask != .invalid {
            UIApplication.shared.endBackgroundTask(legacyBackgroundTask)
            legacyBackgroundTask = .invalid
        }
        if screenWasKeptAwake {
            screenWasKeptAwake = false
            UIApplication.shared.isIdleTimerDisabled = false
        }
        #endif
    }
}
