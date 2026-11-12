// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 huamidev
import SwiftUI

private enum IncomingShareOffer {
    case plist(PlistImportOffer)
    case wallpaper(SharedWallpaperOffer)
}

struct ContentView: View {
    @StateObject private var model = GestaltManager()
    @StateObject private var systemSettings = SystemSettingsModel()
    @StateObject private var customizations = CustomizationModel()
    @StateObject private var launchCatalog = LaunchArtworkCatalogModel()
    @Environment(\.scenePhase) private var scenePhase
    @State private var importOffer: PlistImportOffer?
    @State private var showsImportConfirmation = false
    @State private var wallpaperOffer: SharedWallpaperOffer?
    @State private var showsWallpaperConfirmation = false
    @State private var showsSharedWallpapers = false
    @State private var isCheckingSharedImport = false
    @State private var pendingSharedImport = false
    @State private var capturingDirectImports = 0
    @State private var sharesFile: TemporaryExport?
    @State private var activeExport: TemporaryExport?
    @State private var showsChanges = false
    @State private var asksRespring = false
    @State private var asksImportedRestore = false
    @State private var showsShareNotice = false
    @AppStorage("GestaltX.sharedImportNotice.v1") private var sharedImportNoticeShown = false
    @State private var selectedTab = 0
    @State private var didStart = false
    @State private var didAutoRead = false
    #if targetEnvironment(simulator)
    @State private var previewCategory: CapabilityCategory?
    #endif
    @AppStorage("GestaltX.acceptedWelcome.v1") private var acceptedWelcome = false

    var body: some View {
        TabView(selection: $selectedTab) {
            NavigationStack { tools }
                .tabItem { Label(L("Tools"), systemImage: "square.grid.2x2") }.tag(0)
            NavigationStack { FieldsView() }
                .tabItem { Label(L("MG Control"), systemImage: "slider.horizontal.3") }.tag(1)
            NavigationStack { BackupsView(share: presentShare) }
                .tabItem { Label(L("Backups"), systemImage: "clock.arrow.circlepath") }.tag(2)
            NavigationStack { AboutView() }
                .tabItem { Label(L("About"), systemImage: "info.circle") }.tag(3)
        }
        .environmentObject(model)
        .tint(.blue)
        #if targetEnvironment(simulator)
        .sheet(item: $previewCategory) { category in
            NavigationStack { CategoryView(category: category) }.environmentObject(model)
        }
        #endif
        .sheet(isPresented: Binding(get: { !acceptedWelcome && !isPreviewSession }, set: { _ in })) {
            WelcomeView { acceptedWelcome = true }
        }
        .sheet(item: $sharesFile, onDismiss: {
            activeExport?.cleanUp()
            activeExport = nil
        }) { ShareSheet(export: $0) }
        .sheet(isPresented: $showsChanges) { ChangeReviewView().environmentObject(model) }
        .sheet(isPresented: $showsSharedWallpapers) {
            NavigationStack {
                WallpapersView(model: customizations)
                    .toolbar { ToolbarItem(placement: .topBarTrailing) { Button(L("Done")) { showsSharedWallpapers = false } } }
            }
        }
        .fullScreenCover(isPresented: $model.isRespringing) { NeoSpringView() }
        .alert(L("GestaltX"), isPresented: Binding(get: { model.message != nil && !showsChanges }, set: { if !$0 { model.message = nil } })) {
            Button(L("OK"), role: .cancel) { model.message = nil }
        } message: { Text(model.message ?? "") }
        .alert(L("Respring now?"), isPresented: $asksRespring) {
            Button(L("Cancel"), role: .cancel) {}
            Button(L("Respring")) { model.isRespringing = true }
        } message: { Text(L("This will attempt to restart SpringBoard using NeoSpring.")) }
        .alert(L("Import Plist"), isPresented: $showsImportConfirmation) {
            Button(L("Cancel"), role: .cancel) {
                if let offer = importOffer { model.discardImport(offer) }
                importOffer = nil
                pendingSharedImport = true
            }
            Button(L("Import")) {
                guard let offer = importOffer else { return }
                isCheckingSharedImport = true
                importOffer = nil
                pendingSharedImport = true
                Task {
                    await model.acceptImport(offer)
                    isCheckingSharedImport = false
                    await resumeSharedImports()
                }
            }
        } message: {
            Text(verbatim: (importOffer?.name ?? "") + "\n\n" + L("This plist has been verified for this device. Import it?"))
        }
        .alert(L("Import Wallpaper"), isPresented: $showsWallpaperConfirmation) {
            Button(L("Cancel"), role: .cancel) {
                if let offer = wallpaperOffer {
                    do { try offer.inbox.acknowledge(offer.entry) } catch { model.message = error.localizedDescription }
                    offer.cleanUp()
                }
                wallpaperOffer = nil
                pendingSharedImport = true
            }
            Button(L("Import")) {
                guard let offer = wallpaperOffer else { return }
                wallpaperOffer = nil
                isCheckingSharedImport = true
                Task {
                    let imported = await customizations.importWallpaper(offer.file, id: offer.id)
                    if imported {
                        do {
                            try offer.inbox.acknowledge(offer.entry)
                            showsSharedWallpapers = true
                        } catch { model.message = error.localizedDescription }
                    } else {
                        model.message = customizations.message
                        customizations.message = nil
                        offer.inbox.reject(offer.entry)
                    }
                    offer.cleanUp()
                    pendingSharedImport = true
                    isCheckingSharedImport = false
                    await resumeSharedImports()
                }
            }
        } message: {
            Text(verbatim: (wallpaperOffer?.name ?? "") + "\n\n" + L("Import this wallpaper pack? It will be added to Wallpaper Settings."))
        }
        .alert(L("Restore Imported Plist"), isPresented: $asksImportedRestore) {
            Button(L("Cancel"), role: .cancel) {}
            Button(L("Restore"), role: .destructive) { Task { await model.restoreImportedPlist() } }
        } message: {
            Text(L("The current device file will be backed up before restoring. Restart the device afterward."))
        }
        .alert(L("Import Plist"), isPresented: $showsShareNotice) {
            Button(L("OK"), role: .cancel) {}
        } message: {
            Text(L("Share this device's plist to GestaltX to edit its keys and values or restore a verified backup. Export a copy from GestaltX first to keep a device-bound proof."))
        }
        .onOpenURL { url in
            if url.scheme?.lowercased() == SharedAppGroups.hostURLScheme.lowercased(), url.host == "share" {
                Task { await checkSharedImport() }
            } else if url.isFileURL {
                do {
                    // Own the bytes before deferring presentation. The same
                    // durable confirmation queue handles Files and share events.
                    let capture = SharedPlistInbox.isWallpaperName(url.lastPathComponent)
                        ? SharedWallpaperImports.capture(url, in: try SharedWallpaperImports.inbox())
                        : DirectFileImports.capture(url, in: try DirectFileImports.inbox())
                    capturingDirectImports += 1
                    pendingSharedImport = true
                    Task {
                        do {
                            _ = try await withTaskCancellationHandler {
                                try await capture.value
                            } onCancel: { capture.cancel() }
                            capturingDirectImports -= 1
                            guard !Task.isCancelled else { return }
                            await resumeSharedImports()
                        } catch {
                            capturingDirectImports -= 1
                            if !Task.isCancelled && !(error is CancellationError) { model.message = error.localizedDescription }
                        }
                    }
                } catch { model.message = error.localizedDescription }
            }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active && !isPreviewSession {
                launchCatalog.refreshIfLoaded()
                Task { await checkSharedImport() }
            }
        }
        .onChange(of: canPresentSharedImport) { _, ready in
            if ready && pendingSharedImport && !isCheckingSharedImport {
                Task { await resumeSharedImports() }
            }
        }
        .onChange(of: acceptedWelcome) { _, accepted in
            if accepted && !isPreviewSession { Task { await autoRead(); showShareNoticeIfNeeded() } }
        }
        .task {
            guard !didStart else { return }
            didStart = true
            await model.reloadBackups()
            #if targetEnvironment(simulator)
            let arguments = ProcessInfo.processInfo.arguments
            if let flag = arguments.firstIndex(of: "--preview-document"), arguments.indices.contains(flag + 1) {
                await model.open(URL(fileURLWithPath: arguments[flag + 1]))
            }
            if let flag = arguments.firstIndex(of: "--preview-tab"), arguments.indices.contains(flag + 1), let tab = Int(arguments[flag + 1]) {
                selectedTab = tab
            }
            if arguments.contains("--preview-review") {
                if !arguments.contains("--preview-cache-option") { model.choices["pencil"] = .enable }
                showsChanges = true
            }
            if arguments.contains("--preview-cache-option") {
                model.stageCacheOption(.enable)
            }
            if let flag = arguments.firstIndex(of: "--preview-category"), arguments.indices.contains(flag + 1) {
                previewCategory = CapabilityCategory(rawValue: arguments[flag + 1])
            }
            if arguments.contains("--preview-document") || arguments.contains("--preview-tab") { return }
            #endif
            if acceptedWelcome { await autoRead(); showShareNoticeIfNeeded() }
        }
    }

    private var isPreviewSession: Bool {
        #if targetEnvironment(simulator)
        let arguments = ProcessInfo.processInfo.arguments
        return arguments.contains("--preview-tab") || arguments.contains("--preview-document")
        #else
        return false
        #endif
    }

    private func autoRead() async {
        guard !didAutoRead else { return }
        didAutoRead = true
        if await checkSharedImport() || model.hasDocument { return }
        await model.connect(showErrorAlert: false)
    }

    private var canPresentSharedImport: Bool {
        acceptedWelcome && !model.isBusy && model.changeCount == 0 && importOffer == nil
            && wallpaperOffer == nil && !showsWallpaperConfirmation && !showsSharedWallpapers
            && !customizations.busy && !customizations.isPresenting && customizations.message == nil
            && !showsImportConfirmation && !showsChanges && !model.isRespringing
            && sharesFile == nil && !asksRespring && !asksImportedRestore
            && !showsShareNotice && model.message == nil
    }

    private func resumeSharedImports() async {
        guard acceptedWelcome, !isPreviewSession else { return }
        if await checkSharedImport() { return }
        // Initial automatic reading may have yielded to an import that was
        // subsequently cancelled or rejected. Resume it when the queue empties.
        if didAutoRead && !model.hasDocument && !model.isBusy {
            await model.connect(showErrorAlert: false)
        }
    }

    @discardableResult
    private func checkSharedImport() async -> Bool {
        guard acceptedWelcome else { return false }
        guard !isCheckingSharedImport, importOffer == nil, wallpaperOffer == nil else { return true }
        do {
            let inboxes = [try DirectFileImports.inbox(), try SharedWallpaperImports.inbox()]
                + SharedAppGroups.inboxes + SharedAppGroups.wallpaperInboxes
            let entries = try SharedImportQueue.snapshot(in: inboxes)
            guard !entries.isEmpty else {
                pendingSharedImport = capturingDirectImports > 0
                return pendingSharedImport
            }
            guard canPresentSharedImport else {
                let firstNotice = !pendingSharedImport
                pendingSharedImport = true
                if model.changeCount > 0 && firstNotice && model.message == nil {
                    model.message = L("A shared file is waiting. Save or discard your current changes, then import it.")
                }
                return true
            }
            pendingSharedImport = false
            isCheckingSharedImport = true
            defer { isCheckingSharedImport = false }
            selectedTab = 0
            sharedImportNoticeShown = true
            let selection: SharedImportQueue.Selection<IncomingShareOffer> = await SharedImportQueue.next(in: entries) { inbox, entry in
                guard canPresentSharedImport else { return .deferred(nil) }
                if inbox.kind == .wallpaper {
                    do { return .ready(.wallpaper(try await SharedWallpaperImports.prepare(entry, from: inbox))) }
                    catch {
                        if SharedPlistError.canRetry(error) { return .deferred(error.localizedDescription) }
                        inbox.reject(entry)
                        return .rejected(error.localizedDescription)
                    }
                }
                switch await model.prepareSharedPlist(entry, from: inbox) {
                case .ready(let offer): return .ready(.plist(offer))
                case .deferred(let message): return .deferred(message)
                case .rejected(let message): return .rejected(message)
                }
            }
            switch selection {
            case .ready(let offer):
                // Verification may suspend while reading the device. Recheck
                // presentation after that await; the unacknowledged inbox file
                // remains available when the new modal/busy gate clears.
                guard canPresentSharedImport else {
                    if case .wallpaper(let wallpaper) = offer { wallpaper.cleanUp() }
                    pendingSharedImport = true
                    return true
                }
                pendingSharedImport = true
                switch offer {
                case .plist(let plist): importOffer = plist; showsImportConfirmation = true
                case .wallpaper(let wallpaper): wallpaperOffer = wallpaper; showsWallpaperConfirmation = true
                }
            case .deferred(let message):
                // A UI/busy gate can resume automatically. An unavailable device
                // identity waits for the next foreground/share event, avoiding
                // an isBusy -> retry -> isBusy loop on the same retained file.
                pendingSharedImport = message == nil
                if let message { model.message = message }
            case .empty(let lastRejection):
                pendingSharedImport = false
                if let lastRejection { model.message = lastRejection }
            }
            return selection.blocksAutomaticRead
        } catch {
            model.message = error.localizedDescription
            return true
        }
    }

    private func showShareNoticeIfNeeded() {
        guard !sharedImportNoticeShown, acceptedWelcome, !isPreviewSession,
              importOffer == nil, model.message == nil, !pendingSharedImport else { return }
        sharedImportNoticeShown = true
        showsShareNotice = true
    }

    private func presentShare(_ export: TemporaryExport) {
        guard sharesFile == nil, activeExport == nil else { export.cleanUp(); return }
        activeExport = export
        sharesFile = export
    }

    private var tools: some View {
        Form {
            Section(L("Device")) {
                LabeledContent(L("Model"), value: model.hasDocument ? model.displayedName : UIDevice.current.model)
                LabeledContent("iOS", value: "\(UIDevice.current.systemVersion) (\(VersionSupport.label))")
                LabeledContent(L("Status"), value: L(model.hasDocument ? (model.sourceIsDevice ? "Connected" : "Local File") : (model.isBusy ? "Reading…" : "Not Loaded")))
                if let document = model.working {
                    LabeledContent("CacheExtra", value: String(document.extra.count))
                }
            }
            Section {
                Button { Task { await model.connect() } } label: {
                    Label(L(model.isBusy ? "Reading…" : model.hasDocument ? "Read Again" : "Read MobileGestalt"), systemImage: "arrow.clockwise")
                }.disabled(model.isBusy || model.changeCount > 0)
            }
            Section("MobileGestalt") {
                ForEach(CapabilityCategory.allCases) { category in
                    NavigationLink { CategoryView(category: category) } label: {
                        Label(L(category.rawValue), systemImage: category.symbol)
                    }
                    .disabled(!model.hasDocument || model.isBusy)
                }
            }
            Section(L("Customization")) {
                NavigationLink { SystemSettingsView(model: systemSettings) } label: {
                    Label(L("System Settings"), systemImage: "gearshape")
                }.disabled(model.isBusy)
                NavigationLink { WallpapersView(model: customizations) } label: {
                    Label(L("Wallpaper Settings"), systemImage: "photo.on.rectangle.angled")
                }.disabled(model.isBusy)
                NavigationLink { LaunchArtworkApplicationsView(customizations: customizations, catalog: launchCatalog) } label: {
                    Label(L("App Launch Images"), systemImage: "app.badge")
                }
            }
            Section(L("Actions")) {
                if model.snapshot?.source == .local && model.snapshot?.ownershipVerified == true {
                    Button { asksImportedRestore = true } label: { Label(L("Restore Imported Plist"), systemImage: "arrow.uturn.backward") }
                        .disabled(!model.canRestoreImportedPlist)
                }
                Button { showsChanges = true } label: {
                    HStack {
                        Label(L("Apply Changes"), systemImage: "checkmark")
                        Spacer()
                        if model.changeCount > 0 { Text(String(model.changeCount)).foregroundStyle(.secondary) }
                    }
                    .foregroundStyle(model.changeCount == 0 || model.isBusy ? Color(uiColor: .tertiaryLabel) : Color.blue)
                }
                .disabled(model.changeCount == 0 || model.isBusy)
                Button(role: .destructive) { model.clearStaged() } label: {
                    Label(L("Discard Changes"), systemImage: "xmark")
                        .foregroundStyle(model.changeCount == 0 || model.isBusy ? Color(uiColor: .tertiaryLabel) : Color.red)
                }
                .disabled(model.changeCount == 0 || model.isBusy)
                Button { Task { await model.backup() } } label: { Label(L("Create Backup"), systemImage: "externaldrive.badge.plus") }
                    .disabled(!model.hasDocument || model.isBusy)
                Button {
                    if let export = model.exportDocument() { presentShare(export) }
                } label: { Label(L("Export Plist"), systemImage: "square.and.arrow.up") }
                    .disabled(!model.hasDocument || model.isBusy)
                Button { asksRespring = true } label: { Label(L("Respring"), systemImage: "arrow.trianglehead.2.clockwise.rotate.90") }
                    .disabled(model.isBusy)
            }
            if model.needsRespring {
                Section { Label(L("Some changes require a device restart."), systemImage: "info.circle").font(.footnote).foregroundStyle(.secondary) }
            }
            Section { NavigationLink { SessionLogView() } label: { Label(L("Log"), systemImage: "text.alignleft") } }
        }
        .navigationTitle("GestaltX")
        .toolbar { ToolbarItem(placement: .topBarTrailing) { if model.isBusy { ProgressView() } } }
    }
}

struct CategoryView: View {
    let category: CapabilityCategory
    @EnvironmentObject private var model: GestaltManager
    @State private var asksInternalBuild = false
    var body: some View {
        Form {
            if category == .display {
                Section {
                    Picker(L("Dynamic Island Layout"), selection: $model.subtype) {
                        Text(L("Keep Current")).tag(0)
                        Text("iPhone 14 Pro · 2556").tag(2556)
                        Text("iPhone 14 Pro Max · 2796").tag(2796)
                        Text("iPhone Air · 2736").tag(2736)
                        Text("iPhone 16 Pro · 2622").tag(2622)
                        Text("iPhone 16 Pro Max · 2868").tag(2868)
                    }
                    .onChange(of: model.subtype) { _, value in if value != 0 { model.choices["dynamicIsland"] = .keep } }
                    if let error = model.artworkEditingError {
                        Text(error.localizedDescription).font(.caption).foregroundStyle(.secondary)
                    }
                }.disabled(model.artworkEditingError != nil)
            }
            if category == .device {
                Section(L("Device Identity")) {
                    Toggle(L("Change Model Name"), isOn: $model.changesName)
                    if model.changesName {
                        TextField(L("Model Name"), text: $model.modelName).autocorrectionDisabled()
                        Text(L("A device restart may be required.")).font(.caption).foregroundStyle(.secondary)
                    }
                    if let error = model.artworkEditingError {
                        Text(error.localizedDescription).font(.caption).foregroundStyle(.secondary)
                    }
                }.disabled(model.artworkEditingError != nil)
            }
            if category == .intelligence {
                Section {
                    Picker(L("Region Code"), selection: $model.regionCodeID) {
                        ForEach(RegionPreset.all) { Text(L($0.title)).tag($0.id) }
                    }
                    if model.regionCodeID != "keep" { Text(L("A device restart may be required.")).font(.caption).foregroundStyle(.secondary) }
                } footer: {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(L("Usually, changing the region code is enough. There is no need to change Sales Region."))
                        Text(L("* If you previously changed Sales Region, restore your device's original sales region and apply it first."))
                    }
                }
                Section {
                    Picker(L("Sales Region"), selection: $model.regionID) {
                        ForEach(RegionPreset.all) { Text(L($0.title)).tag($0.id) }
                    }
                    if model.regionID != "keep" { Text(L("Restart the device after changing the region.")).font(.caption).foregroundStyle(.secondary) }
                } footer: {
                    Text(L("Changing the sales-region suffix may cause verification tools to report a mismatch with factory information."))
                }
                Section {
                    Picker(L("Model Number"), selection: $model.modelID) {
                        ForEach(ModelPreset.all) { Text(L($0.title)).tag($0.id) }
                    }
                    HStack(alignment: .firstTextBaseline) {
                        if model.modelID != "keep" {
                            Text(L("A device restart may be required after changing the model number.")).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 8)
                        Button(L("Revert")) { Task { await model.restoreCapability(ModelPreset.restoration) } }
                            .font(.caption).buttonStyle(.borderless)
                            .disabled(!model.canRestore(ModelPreset.restoration))
                    }
                } footer: {
                    Text(L("Listed values apply to iPhone Air, iPhone 18 Pro and iPhone 18 Pro Max only. Choosing a model number that does not match your hardware can make verification tools report a mismatch."))
                }
            }
            Section {
                ForEach(Capability.all.filter { $0.category == category }) { capability in
                    VStack(alignment: .leading, spacing: 4) {
                    Picker(selection: Binding(
                        get: { model.choices[capability.id] ?? .keep },
                        set: {
                            if capability.requiresEnableConfirmation, $0 == .enable,
                               model.choices[capability.id] != .enable {
                                asksInternalBuild = true
                                return
                            }
                            model.choices[capability.id] = $0
                            if capability.id == "dynamicIsland" && $0 != .keep { model.subtype = 0 }
                        }
                    )) {
                        ForEach(capability.availableChoices) { choice in
                            let title = capability.id == "siriOnDevice" && choice == .disable
                                ? "Restore Original" : choice.title
                            Text(L(title)).tag(choice)
                        }
                    } label: {
                        HStack(spacing: 6) {
                            Text(L(capability.title))
                            if capability.caution {
                                Image(systemName: "exclamationmark.triangle").font(.caption2).foregroundStyle(.orange)
                                    .accessibilityLabel(L("Experimental"))
                            }
                        }
                    }.pickerStyle(.menu)
                    if capability.requiresEnableConfirmation || capability.id == "siriOnDevice" {
                        Text(L(capability.detail)).font(.caption).foregroundStyle(.secondary)
                    }
                    HStack(alignment: .firstTextBaseline) {
                        if (model.choices[capability.id] ?? .keep) != .keep {
                            Text(L(capability.effectHint)).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 8)
                        Button(L("Revert")) { Task { await model.restoreCapability(capability) } }
                            .font(.caption).buttonStyle(.borderless)
                            .disabled(!model.canRestore(capability))
                    }
                    }
                }
                if category == .device {
                    AdditionalOptionsRow()
                    WAPIPresetRow()
                }
            } header: {
                Text(L("Presets"))
            }
            if category == .ipad || category == .advanced {
                Section { Text(L("Experimental settings. Back up before applying.")).font(.footnote).foregroundStyle(.secondary) }
            }
            if model.changeCount > 0 {
                Section { NavigationLink(L("Review Changes")) { ChangeReviewView(isSheet: false) } }
            }
        }
        .navigationTitle(L(category.rawValue)).disabled(model.isBusy)
        .alert(L("Enable Internal Build?"), isPresented: $asksInternalBuild) {
            Button(L("Cancel"), role: .cancel) {}
            Button(L("Enable"), role: .destructive) {
                guard !model.isBusy, model.hasDocument else { return }
                model.choices["storage"] = .enable
            }
        } message: {
            Text(L("This stages the system-wide InternalBuild flag. It can affect system services beyond the storage screen. You can review the change before applying it."))
        }
    }
}

struct AdditionalOptionsRow: View {
    @EnvironmentObject private var model: GestaltManager

    private var support: Result<CachedOptionFlags, Error> {
        Result {
            guard let document = model.preview else { throw GestaltFailure("Load a document first.") }
            return try DeviceCacheOptions.flags(in: document)
        }
    }

    var body: some View {
        switch support {
        case .success:
            VStack(alignment: .leading, spacing: 8) {
                Picker(L("Additional Options"), selection: Binding(
                    get: { model.cacheOptionChoice },
                    set: { model.stageCacheOption($0) }
                )) {
                    ForEach(CacheOptionChoice.allCases) { choice in
                        Text(choice.title).tag(choice)
                    }
                }
                .pickerStyle(.menu)
                .accessibilityIdentifier("cache-option-choice")
                Text(L("Some changes require a device restart."))
                    .font(.caption).foregroundStyle(.secondary)
                HStack(alignment: .firstTextBaseline) {
                    Spacer(minLength: 8)
                    Button(L("Revert")) { Task { await model.restoreCacheOption() } }
                        .font(.caption).buttonStyle(.borderless)
                        .disabled(!model.canRestoreCacheOption)
                        .accessibilityIdentifier("cache-option-revert")
                }
            }
        case .failure(let error):
            VStack(alignment: .leading, spacing: 4) {
                LabeledContent(L("Additional Options")) { Text(L("Unsupported")).foregroundStyle(.secondary) }
                Text(error.localizedDescription).font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

struct WAPIPresetRow: View {
    @EnvironmentObject private var model: GestaltManager
    private var supported: Bool {
        guard let document = model.preview else { return false }
        return (try? DeviceCacheOptions.wapi(in: document)) != nil
    }
    var body: some View {
        if supported {
            VStack(alignment: .leading, spacing: 8) {
                Picker("WAPI", selection: Binding(get: { model.wapiChoice }, set: { model.stageWAPI($0) })) {
                    ForEach(WAPIChoice.allCases) { choice in Text(choice.title).tag(choice) }
                }
                .pickerStyle(.menu)
                .accessibilityIdentifier("wapi-choice")
                Text(L("Disabling may show Wi-Fi and change some network options. Restart to apply."))
                    .font(.caption).foregroundStyle(.secondary)
            }
        } else {
            LabeledContent("WAPI") { Text(L("Unsupported")).foregroundStyle(.secondary) }
        }
    }
}

struct FieldsView: View {
    @EnvironmentObject private var model: GestaltManager
    @State private var search = ""
    @State private var draft: FieldDraft?
    @State private var deletesKey: String?
    private var keys: [String] {
        (model.preview?.extra.keys.sorted() ?? []).filter { key in
            search.isEmpty || key.localizedCaseInsensitiveContains(search) || valueText(key).localizedCaseInsensitiveContains(search)
        }
    }
    private func valueText(_ key: String) -> String {
        guard let value = model.preview?.extra[key] else { return "" }
        let type = PlistValueKind.detect(value)
        if type == .data { return String(format: L("%lld bytes"), Int64((value as? Data)?.count ?? 0)) }
        return type.text(for: value)
    }
    var body: some View {
        List {
            if !model.hasDocument {
                ContentUnavailableView(L("No Document Open"), systemImage: "doc.text.magnifyingglass", description: Text(L("Read MobileGestalt in Tools, or share this device's plist to GestaltX.")))
            } else {
                Section {
                    ForEach(keys, id: \.self) { key in
                        Button {
                            guard let value = model.preview?.extra[key] else { return }
                            let kind = PlistValueKind.detect(value)
                            draft = FieldDraft(originalKey: key, key: key, kind: kind, text: kind.text(for: value), originalValue: value)
                        } label: {
                            VStack(alignment: .leading, spacing: 6) {
                                HStack(alignment: .firstTextBaseline) {
                                    Text(key).font(.system(.subheadline, design: .monospaced)).foregroundStyle(.primary).lineLimit(2)
                                    Spacer(minLength: 4)
                                    if let value = model.preview?.extra[key] {
                                        Text(L(PlistValueKind.detect(value).rawValue)).font(.caption2).foregroundStyle(Color.gestaltAccent)
                                    }
                                }
                                Text(valueText(key)).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                            }.padding(.vertical, 5)
                        }
                        .swipeActions(allowsFullSwipe: false) { Button(L("Delete")) { deletesKey = key }.tint(.red) }
                    }
                } header: { Text("CacheExtra") }
                if keys.isEmpty { ContentUnavailableView.search(text: search) }
            }
        }
        .navigationTitle(L("MG Control"))
        .searchable(text: $search, prompt: L("Search keys and values"))
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { draft = FieldDraft() } label: { Image(systemName: "plus").accessibilityLabel(L("Add Field")) }
                    .disabled(!model.hasDocument || model.isBusy)
            }
        }
        .sheet(item: $draft) { FieldEditorView(draft: $0).environmentObject(model) }.disabled(model.isBusy)
        .alert(L("Delete this field?"), isPresented: Binding(get: { deletesKey != nil }, set: { if !$0 { deletesKey = nil } })) {
            Button(L("Cancel"), role: .cancel) { deletesKey = nil }
            Button(L("Delete"), role: .destructive) { if let key = deletesKey { model.removeField(key) }; deletesKey = nil }
        } message: { Text(L("The deletion is staged. The device file changes only after you apply.")) }
    }
}

struct FieldEditorView: View {
    @State var draft: FieldDraft
    @State private var error: String?
    @EnvironmentObject private var model: GestaltManager
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            Form {
                Section(L("Key")) {
                    TextField(L("Field Key"), text: $draft.key).font(.system(.subheadline, design: .monospaced))
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                }
                Section(L("Value")) {
                    Picker(L("Type"), selection: $draft.kind) { ForEach(PlistValueKind.allCases) { Text(L($0.rawValue)).tag($0) } }
                    TextEditor(text: $draft.text).font(.system(.subheadline, design: .monospaced))
                        .frame(minHeight: 150).textInputAutocapitalization(.never).autocorrectionDisabled()
                }
                if draft.kind == .array || draft.kind == .dictionary {
                    Section { Text(L("Use an XML plist fragment, including the array or dict tags. Nested data and numeric types are preserved.")).font(.footnote).foregroundStyle(.secondary) }
                } else if draft.kind == .data {
                    Section { Text(L("Data values use Base64 encoding.")).font(.footnote).foregroundStyle(.secondary) }
                }
                if let error { Section { Text(error).foregroundStyle(.red).font(.footnote) } }
            }
            .navigationTitle(L(draft.originalKey == nil ? "Add Field" : "Edit Field"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(L("Cancel")) { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(L("Stage")) {
                        do { try model.stage(draft); dismiss() } catch { self.error = error.localizedDescription }
                    }.fontWeight(.semibold)
                }
            }
        }
    }
}

struct ChangeReviewView: View {
    var isSheet = true
    @EnvironmentObject private var model: GestaltManager
    @Environment(\.dismiss) private var dismiss
    @State private var asksApply = false
    var body: some View {
        Group {
            if isSheet { NavigationStack { contents } } else { contents }
        }
    }
    private var contents: some View {
        List {
            Section {
                Label(L(model.sourceIsDevice ? "Write to this device" : "Save local document"), systemImage: model.sourceIsDevice ? "iphone" : "doc.text")
                Text(L(model.sourceIsDevice ? "A backup is created before writing. The result is read back and compared." : "This edits the opened file in GestaltX. Export it to save a copy; the system file is not changed."))
                    .font(.footnote).foregroundStyle(.secondary)
            }
            if let message = model.message { Section { Text(message).font(.footnote).foregroundStyle(.red) } }
            ForEach(model.changeKeys, id: \.self) { key in
                Section {
                    Text(key).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                    valueRow("Before", value: model.snapshot?.document.extra[key])
                    valueRow("After", value: model.preview?.extra[key])
                    if let capability = Capability.all.first(where: { $0.keys.contains(key) }) {
                        Text(L(capability.effectHint)).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            ForEach(model.cacheDataChanges) { change in
                Section {
                    Text(verbatim: "CacheData · \(change.name)")
                        .font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                    valueRow("Before", value: NSNumber(value: change.before))
                    valueRow("After", value: NSNumber(value: change.after))
                }
            }
            Section {
                Button(L(model.sourceIsDevice ? "Apply to Device" : "Save Local Changes")) { asksApply = true }
                    .fontWeight(.semibold).disabled(model.changeCount == 0 || model.isBusy)
                Button(L("Discard Changes"), role: .destructive) { model.clearStaged(); dismiss() }.disabled(model.isBusy)
            }
        }
        .navigationTitle(L("Review Changes")).navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if isSheet { ToolbarItem(placement: .cancellationAction) { Button(L("Done")) { dismiss() }.disabled(model.isBusy) } }
            ToolbarItem(placement: .topBarTrailing) { if model.isBusy { ProgressView() } }
        }
        .alert(L("Apply these changes?"), isPresented: $asksApply) {
            Button(L("Cancel"), role: .cancel) {}
            Button(L("Apply")) { Task { await model.apply(); if model.changeCount == 0 { dismiss() } } }
        } message: { Text(L(model.sourceIsDevice ? "Incorrect system values can affect device behavior. A verified backup will be kept. No respring is triggered automatically." : "The current local document will be backed up before saving your edits.")) }
    }
    private func valueRow(_ title: String, value: Any?) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(L(title)).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            Text(value.map { PlistValueKind.detect($0).text(for: $0) } ?? L("Not present"))
                .font(.system(.caption, design: .monospaced)).lineLimit(6).textSelection(.enabled)
        }
    }
}

struct BackupsView: View {
    let share: (TemporaryExport) -> Void
    @EnvironmentObject private var model: GestaltManager
    @State private var restores: BackupRecord?
    @State private var deletes: BackupRecord?
    var body: some View {
        List {
            Section {
                Button { Task { await model.backup() } } label: { Label(L("Create Backup"), systemImage: "plus.circle.fill") }
                    .disabled(!model.hasDocument || model.isBusy)
            } footer: {
                if model.changeCount > 0 {
                    Text(L("Save or discard your current changes before opening another plist."))
                }
            }
            if model.backups.isEmpty {
                ContentUnavailableView(L("No Backups"), systemImage: "externaldrive.badge.timemachine", description: Text(L("A backup is created before each write.")))
            }
            ForEach(model.backups) { record in
                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Image(systemName: record.source == .device ? "iphone" : "doc.text").foregroundStyle(Color.gestaltAccent)
                            Text(L(record.reason)).fontWeight(.medium)
                            Spacer()
                        }
                        Text(record.date, format: .dateTime.year().month().day().hour().minute().second()).font(.subheadline)
                        Text(L(record.source == .device ? "Device Backup" : "Local File Backup") + " · " + ByteCountFormatter.string(fromByteCount: Int64(record.byteCount), countStyle: .file))
                            .font(.caption).foregroundStyle(.secondary)
                        HStack {
                            Button(L("Open")) { Task { await model.openBackup(record) } }
                                .disabled(model.changeCount > 0)
                            Spacer()
                            Button(L("Export")) { Task { if let url = await model.exportBackup(record) { share(url) } } }
                            Spacer()
                            Button(L("Restore")) { restores = record }
                                .disabled(model.changeCount > 0 || !model.hasDocument || (model.sourceIsDevice && record.source != .device))
                        }.font(.subheadline).buttonStyle(.borderless).padding(.top, 6)
                    }.padding(.vertical, 6)
                }.swipeActions(allowsFullSwipe: false) { Button(L("Delete")) { deletes = record }.tint(.red) }
            }
        }
        .navigationTitle(L("Backups")).disabled(model.isBusy)
        .task { await model.reloadBackups() }
        .refreshable { await model.reloadBackups() }
        .alert(L("Restore this backup?"), isPresented: Binding(get: { restores != nil }, set: { if !$0 { restores = nil } })) {
            Button(L("Cancel"), role: .cancel) { restores = nil }
            Button(L("Restore")) { if let record = restores { Task { await model.restore(record) } }; restores = nil }
                .disabled(model.isBusy || model.changeCount > 0)
        } message: { Text(L("The current document is backed up first. Device restores are verified after writing.")) }
        .alert(L("Delete this backup?"), isPresented: Binding(get: { deletes != nil }, set: { if !$0 { deletes = nil } })) {
            Button(L("Cancel"), role: .cancel) { deletes = nil }
            Button(L("Delete"), role: .destructive) { if let record = deletes { Task { await model.deleteBackup(record) } }; deletes = nil }
        } message: { Text(L("This removes the local backup permanently. It does not change the device file.")) }
    }
}

struct SessionLogView: View {
    @EnvironmentObject private var model: GestaltManager
    @State private var export: TemporaryExport?

    private func shareLog() {
        let text = model.logs.joined(separator: "\n") + "\n"
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let name = "GestaltX-session-\(Int(Date.now.timeIntervalSince1970)).log"
        export = try? TemporaryExport(data: Data(text.utf8), name: name)
    }

    var body: some View {
        ScrollView {
            Text(model.logs.isEmpty ? L("No activity yet.") : model.logs.joined(separator: "\n"))
                .font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading).padding()
                .environment(\.layoutDirection, .leftToRight)
        }
        .navigationTitle(L("Session Log"))
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { shareLog() } label: { Image(systemName: "square.and.arrow.up") }
                    .disabled(model.logs.isEmpty)
                    .accessibilityLabel(L("Share Log"))
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button(L("Clear")) { model.clearLog() }
            }
        }
        .sheet(item: $export) { ShareSheet(export: $0) }
    }
}

struct BrandMark: View {
    var size: CGFloat = 44
    var body: some View {
        Image("AppMark").resizable().frame(width: size, height: size)
            .clipShape(RoundedRectangle(cornerRadius: size * 0.22, style: .continuous)).accessibilityHidden(true)
    }
}
extension Color { static let gestaltAccent = Color.blue }
struct ShareSheet: UIViewControllerRepresentable {
    let export: TemporaryExport
    func makeUIViewController(context: Context) -> UIActivityViewController {
        let controller = UIActivityViewController(activityItems: [export.url], applicationActivities: nil)
        controller.completionWithItemsHandler = { _, _, _, _ in export.cleanUp() }
        return controller
    }
    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
