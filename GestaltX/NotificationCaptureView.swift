// SPDX-License-Identifier: GPL-3.0-only
import SwiftUI

/// Capture lives with the audio library, while pairing stays a separate
/// device-level feature. The sheet only reads the shared pairing record.
struct NotificationCaptureView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var connection = DeviceConnectionModel()
    @StateObject private var capture = NotificationSoundCaptureModel()
    @State private var isStarting = false

    var body: some View {
        List {
            if !connection.consoleAvailable {
                Section {
                    Label(L("The device console is not available in this build."), systemImage: "bolt.slash")
                        .foregroundStyle(.secondary)
                }
            }
            pairingSection
            if case .paired = connection.state {
                captureSection
                if !capture.capturedSounds.isEmpty { capturedSection }
            }
        }
        .navigationTitle(L("Capture Notification Sounds"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button(L("Done")) { dismiss() }
            }
        }
        .task {
            connection.load()
            capture.loadCached()
            while !Task.isCancelled {
                if case .paired = connection.state {
                    _ = await connection.checkVPN(showProgress: false)
                }
                try? await Task.sleep(for: .seconds(5))
            }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active, case .paired = connection.state {
                Task {
                    let host = await connection.checkVPN(showProgress: false)
                    if capture.state == .connecting, host == nil {
                        capture.abortConnecting(L("Cannot reach the device console. Open LocalDevVPN, wait for it to connect, then try again."))
                    }
                }
            }
        }
        .alert(L("GestaltX"), isPresented: Binding(get: { connection.message != nil }, set: { if !$0 { connection.message = nil } })) {
            Button(L("OK"), role: .cancel) { connection.message = nil }
        } message: { Text(connection.message ?? "") }
        .alert(L("GestaltX"), isPresented: Binding(get: { capture.message != nil }, set: { if !$0 { capture.message = nil } })) {
            Button(L("OK"), role: .cancel) { capture.message = nil }
        } message: { Text(capture.message ?? "") }
    }

    @ViewBuilder private var pairingSection: some View {
        switch connection.state {
        case .paired:
            Section(L("Device Pairing")) {
                if let record = connection.record {
                    LabeledContent(L("Device")) { Text(record.deviceName).foregroundStyle(.secondary) }
                }
            }
        case .advertising, .pairing:
            Section(L("Device Pairing")) {
                HStack(spacing: 10) {
                    ProgressView()
                    Text(L("Pairing is in progress. Finish it in Tools → Device Pairing."))
                        .font(.footnote)
                }
                NavigationLink { DeviceConnectionView() } label: {
                    Label(L("Open Device Pairing"), systemImage: "link")
                }
            }
        case .idle, .failed:
            Section(L("Device Pairing")) {
                Text(L("Pair once before capturing."))
                    .font(.footnote).foregroundStyle(.secondary)
                NavigationLink { DeviceConnectionView() } label: {
                    Label(L("Open Device Pairing"), systemImage: "link")
                }
            }
        }
    }

    @ViewBuilder private var captureSection: some View {
        Section(L("Capture")) {
            LabeledContent(L("Loopback VPN")) {
                Text(vpnStatusText)
                    .foregroundStyle(connection.vpnState == .unavailable ? .red : .secondary)
            }
            if connection.vpnState == .unavailable {
                Button { connection.openLocalDevVPN() } label: {
                    Label(L("Open LocalDevVPN"), systemImage: "arrow.up.forward.app")
                }
            }
            switch capture.state {
            case .connecting:
                HStack { ProgressView(); Text(L("Connecting…")) }
                Text(L("If this stays here, open LocalDevVPN and wait for it to finish connecting."))
                    .font(.footnote).foregroundStyle(.secondary)
                if connection.vpnState == .unavailable {
                    Button { connection.openLocalDevVPN() } label: {
                        Label(L("Open LocalDevVPN"), systemImage: "arrow.up.forward.app")
                    }
                }
                Button(role: .cancel) { capture.stop() } label: { Text(L("Stop Capture")) }
            case .capturing:
                HStack { ProgressView(); Text(L("Capturing…")) }
                LabeledContent(L("Captured")) {
                    Text("\(capture.capturedAppCount) / \(capture.capturedSounds.count)").foregroundStyle(.secondary)
                }
                Button(role: .cancel) { capture.stop() } label: { Label(L("Stop Capture"), systemImage: "stop.fill") }
            default:
                if isStarting {
                    HStack(spacing: 10) {
                        ProgressView()
                        Text(L("Checking…"))
                    }
                    .foregroundStyle(.secondary)
                } else {
                    Button { startCapture() } label: {
                        HStack(spacing: 10) {
                            Image(systemName: "dot.radiowaves.left.and.right")
                            Text(L("Start Capture")).fontWeight(.semibold)
                            Spacer(minLength: 0)
                        }
                        .foregroundStyle(.tint)
                        .padding(.vertical, 4)
                    }
                }
            }
        }
    }

    @ViewBuilder private var capturedSection: some View {
        Section(L("Captured Notification Sounds")) {
            ForEach(capture.capturedSounds) { sound in
                VStack(alignment: .leading, spacing: 4) {
                    Text(sound.bundleID).lineLimit(1)
                    Text(sound.representsReplaceableFile ? sound.filename : L("System default (not replaceable)"))
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
        }
    }

    private var vpnStatusText: String {
        switch connection.vpnState {
        case .unknown: return L("Not checked")
        case .checking: return L("Checking…")
        case .ready(let host): return "\(L("Connected")) · \(host)"
        case .unavailable: return L("Not reachable")
        }
    }

    private func startCapture() {
        guard !isStarting else { return }
        isStarting = true
        Task {
            defer { isStarting = false }
            guard let path = await connection.currentPairingPath() else {
                connection.message = L("The saved pairing file is missing. Pair this iPhone again before capturing.")
                return
            }
            guard let host = await connection.checkVPN() else {
                connection.message = L("Loopback VPN is not reachable. Open LocalDevVPN, wait until it connects, then try again.")
                return
            }
            capture.start(pairingPath: path, loopbackHost: host)
        }
    }
}
