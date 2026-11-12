// SPDX-License-Identifier: GPL-3.0-only
import SwiftUI
import Combine

@MainActor
final class SystemSettingsModel: ObservableObject {
    @Published private(set) var snapshot: SystemSettingsSnapshot?
    @Published private(set) var isBusy = false
    @Published private(set) var staged: [SystemSetting: SystemSettingAction] = [:]
    @Published private(set) var lockScreenText = ""
    @Published var message: String?
    private let store: SystemSettingsStore

    init() {
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("GestaltX/SystemSettings", isDirectory: true)
        let deviceID = UIDevice.current.identifierForVendor?.uuidString
            ?? UserDefaults.standard.string(forKey: "GestaltX.installationID") ?? "local"
        store = SystemSettingsStore(storage: directory, deviceID: deviceID, acquire: { path in
            #if targetEnvironment(simulator)
            throw GestaltFailure("Device access is unavailable in the Simulator. Open a plist to explore GestaltX.")
            #else
            let groups = GXEntitlementsReader.usableAppGroups()
            guard !groups.isEmpty else { throw GestaltFailure("The signed app has no usable App Group. Enable its App Group capability and sign it again.") }
            for group in groups {
                // This argument only skips the PoC's preflight lstat. The settings
                // store creates a missing preference file only after Apply.
                var handle = worse_query(path, group, false, true)
                if handle == -4, let root = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group) {
                    try? FileManager.default.createDirectory(at: root.appendingPathComponent("Library/Caches"), withIntermediateDirectories: true)
                    handle = worse_query(path, group, false, true)
                }
                if handle >= 0 { return handle }
            }
            throw GestaltFailure("These system settings are not accessible on this device.")
            #endif
        }, release: { worse_query_release($0) }, event: { text in
            NotificationCenter.default.post(name: Notification.Name("GestaltX.worse_query.log"), object: nil,
                                            userInfo: ["message": text])
        })
    }
    var hasChanges: Bool { !staged.isEmpty }
    func stageText(_ text: String) {
        guard !isBusy, snapshot?.values[.lockScreenText] != nil else { return }
        lockScreenText = text
        if (try? SystemPreferenceValue(text)) == snapshot?.values[.lockScreenText] {
            staged.removeValue(forKey: .lockScreenText)
        } else { staged[.lockScreenText] = .text(text) }
    }
    private func accept(_ value: SystemSettingsSnapshot, clearing settings: Set<SystemSetting>) {
        snapshot = value
        for setting in settings { staged.removeValue(forKey: setting) }
        if staged[.lockScreenText] == nil {
            lockScreenText = ((try? value.values[.lockScreenText]?.decoded()) as? String) ?? ""
        }
    }
    func load() async {
        guard !isBusy, !hasChanges else { return }
        isBusy = true; defer { isBusy = false }
        do { accept(try await store.load(), clearing: []) }
        catch { message = error.localizedDescription }
    }
    func discard() {
        guard !isBusy, let snapshot else { return }
        accept(snapshot, clearing: Set(staged.keys))
    }
    func canRestore(_ setting: SystemSetting) -> Bool {
        guard !isBusy, let snapshot, let current = snapshot.values[setting] else { return false }
        if staged[setting] != nil { return true }
        guard let original = snapshot.originals[setting] else { return false }
        return original != current
    }
    private func apply(_ changes: [SystemSetting: SystemSettingAction]) async {
        guard !isBusy, !changes.isEmpty, let before = snapshot else { return }
        isBusy = true; defer { isBusy = false }
        do {
            let updated = try await store.apply(changes, expected: before)
            accept(updated, clearing: Set(changes.keys))
            message = L("Lock screen text updated.")
        } catch {
            message = error.localizedDescription
            if let updated = try? await store.load() { snapshot = updated }
        }
    }
    func applyChanges() async { await apply(staged) }
    func restore(_ setting: SystemSetting) async {
        guard canRestore(setting) else { return }
        if snapshot?.originals[setting] == nil || snapshot?.originals[setting] == snapshot?.values[setting] {
            staged.removeValue(forKey: setting)
            if setting == .lockScreenText, let snapshot { accept(snapshot, clearing: []) }
        } else { await apply([setting: .restore]) }
    }
}

struct SystemSettingsView: View {
    @ObservedObject var model: SystemSettingsModel
    @State private var asksApply = false

    var body: some View {
        List {
            Section {
                ForEach(SystemSetting.allCases) { setting in
                    VStack(alignment: .leading, spacing: 8) {
                        if let value = model.snapshot?.values[setting] {
                            Text(L(setting.title))
                            TextField(L("Your lock screen text"), text: Binding(get: { model.lockScreenText }, set: model.stageText))
                                .accessibilityIdentifier("system-lock-screen-text")
                            Text(L(setting.detail)).font(.caption).foregroundStyle(.secondary)
                            Text(L("Current Value") + ": " + value.display)
                                .lineLimit(3).font(.caption).foregroundStyle(.secondary)
                        } else {
                            LabeledContent(L(setting.title), value: L(model.snapshot == nil ? "Not Loaded" : "Unavailable"))
                            if let error = model.snapshot?.errors[setting.file] {
                                Text(error).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                    .padding(.vertical, 3)
                }
            }
            Section {
                Button { asksApply = true } label: {
                    Label(L("Apply Changes"), systemImage: "checkmark")
                }.disabled(!model.hasChanges)
                Button(L("Discard Changes"), role: .destructive) { model.discard() }.disabled(!model.hasChanges)
                Button { Task { await model.load() } } label: {
                    Label(L("Read Again"), systemImage: "arrow.clockwise")
                }.disabled(model.hasChanges)
            }
        }
        .disabled(model.isBusy)
        .navigationTitle(L("System Settings"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .topBarTrailing) { if model.isBusy { ProgressView() } } }
        .task { if model.snapshot == nil { await model.load() } }
        .alert(L("Apply these changes?"), isPresented: $asksApply) {
            Button(L("Cancel"), role: .cancel) {}
            Button(L("Apply")) { Task { await model.applyChanges() } }
        } message: { Text(L("A backup is created before each write.")) }
        .alert(L("System Settings"), isPresented: Binding(get: { model.message != nil }, set: { if !$0 { model.message = nil } })) {
            Button(L("OK"), role: .cancel) { model.message = nil }
        } message: { Text(model.message ?? "") }
    }
}
