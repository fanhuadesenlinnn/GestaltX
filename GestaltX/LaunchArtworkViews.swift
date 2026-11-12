// SPDX-License-Identifier: GPL-3.0-only
import SwiftUI
import Combine
import PhotosUI
import Photos

@MainActor
final class LaunchArtworkCatalogModel: ObservableObject {
    @Published private(set) var applications: [LaunchArtworkApp] = []
    @Published private(set) var scanning = false
    private let catalog: LaunchArtworkCatalogStore
    private var scan: Task<Void, Never>?
    private var loaded = false
    private var pending = false
    private var pendingForce = false
    init() {
        catalog = LaunchArtworkCatalogStore(storage: FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("GestaltX/LaunchImages/Catalog", isDirectory: true), device: UIDevice.current.identifierForVendor?.uuidString ?? "")
    }
    func refreshIfLoaded() { if loaded { refresh() } }
    func refresh(force: Bool = false) {
        loaded = true
        if scan != nil { pending = true; pendingForce = pendingForce || force; return }
        scanning = true
        scan = Task {
            for await event in catalog.events(force: force) {
                if Task.isCancelled { break }
                switch event {
                case .snapshot(let apps): applications = apps
                case .upsert(let app): LaunchArtworkAppOrder.upsert(app, in: &applications)
                case .remove(let id): applications.removeAll { $0.id == id }
                }
            }
            scanning = false; scan = nil
            if pending { let force = pendingForce; pending = false; pendingForce = false; refresh(force: force) }
        }
    }
}

@MainActor
final class LaunchArtworkModel: ObservableObject {
    @Published private(set) var state: LaunchArtworkState?
    @Published private(set) var busy = false
    @Published private(set) var draft: Data?
    @Published private(set) var preview: Data?
    @Published var message: String?
    private let store: LaunchArtworkStore
    init() {
        store = LaunchArtworkStore(storage: FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("GestaltX/LaunchImages", isDirectory: true), device: UIDevice.current.identifierForVendor?.uuidString ?? "")
    }
    func load(_ app: LaunchArtworkApp) async {
        guard !busy else { return }
        busy = true; defer { busy = false }
        do { state = try await store.state(app); if draft == nil { preview = state?.preview } }
        catch { message = error.localizedDescription }
    }
    func choose(_ item: PhotosPickerItem) async {
        guard !busy, let state else { return }
        busy = true; defer { busy = false }
        do {
            guard let data = try await item.loadTransferable(type: Data.self), data.count <= LaunchArtworkImages.maximumPhoto else {
                throw CustomizationFailure("This image could not be used. Choose another image.")
            }
            let width = state.width, height = state.height
            let thumbnail = try await Task.detached(priority: .userInitiated) {
                let ratio = min(1.0, 900.0 / Double(max(width, height)))
                return try LaunchArtworkImages.render(data, width: max(1, Int(Double(width) * ratio)), height: max(1, Int(Double(height) * ratio)))
            }.value
            draft = data; preview = thumbnail
        } catch { message = error.localizedDescription }
    }
    func discard() { draft = nil; preview = state?.preview }
    func saveCurrent(_ app: LaunchArtworkApp) async {
        guard !busy else { return }
        busy = true; defer { busy = false }
        do {
            let png = try await store.currentImage(app)
            var authorization = PHPhotoLibrary.authorizationStatus(for: .addOnly)
            if authorization == .notDetermined { authorization = await PHPhotoLibrary.requestAuthorization(for: .addOnly) }
            guard authorization == .authorized || authorization == .limited else {
                throw CustomizationFailure("Allow GestaltX to add photos in Settings, then try again.")
            }
            try await PHPhotoLibrary.shared().performChanges {
                let request = PHAssetCreationRequest.forAsset()
                let options = PHAssetResourceCreationOptions()
                options.originalFilename = "\(app.id.prefix(120))-launch.png"
                request.addResource(with: .photo, data: png, options: options)
            }
            message = L("The launch image was saved to Photos.")
        } catch { message = error.localizedDescription }
    }
    func apply(_ app: LaunchArtworkApp) async {
        guard !busy, let draft else { return }
        busy = true; defer { busy = false }
        do {
            _ = try await store.apply(draft, to: app)
            self.draft = nil
            state = try await store.state(app); preview = state?.preview
            message = L("Launch image saved. Close and reopen the app to see it.")
        } catch { message = error.localizedDescription }
    }
    func restore(_ app: LaunchArtworkApp) async {
        guard !busy else { return }
        busy = true; defer { busy = false }
        do {
            _ = try await store.restore(app)
            draft = nil; state = try await store.state(app); preview = state?.preview
            message = L("Restored. Launch images refreshed by iOS were left unchanged.")
        } catch { message = error.localizedDescription }
    }
}

struct LaunchArtworkApplicationsView: View {
    @ObservedObject var customizations: CustomizationModel
    @ObservedObject var catalog: LaunchArtworkCatalogModel
    @State private var search = ""
    private var apps: [LaunchArtworkApp] {
        catalog.applications.filter { search.isEmpty || $0.name.localizedCaseInsensitiveContains(search) || $0.id.localizedCaseInsensitiveContains(search) }
    }
    var body: some View {
        List {
            if catalog.scanning { HStack(spacing: 12) { ProgressView(); Text(L("Reading…")) }.foregroundStyle(.secondary) }
            else if apps.isEmpty { ContentUnavailableView(L("No Launch Images"), systemImage: "app.badge") }
            ForEach(apps) { app in
                NavigationLink { LaunchArtworkEditor(app: app, customizations: customizations) } label: {
                    HStack(spacing: 12) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(app.name).lineLimit(1)
                            Text(app.id).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Spacer(minLength: 4)
                    }
                }
            }
            Section {} footer: { Text(L("Only apps with readable launch images are listed. iOS may refresh these images.")) }
        }
        .navigationTitle(L("App Launch Images"))
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $search)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                if catalog.scanning { ProgressView().accessibilityLabel(L("Reading…")) }
                else {
                    Button { catalog.refresh(force: true) } label: { Image(systemName: "arrow.clockwise") }
                        .accessibilityLabel(L("Read Again"))
                }
            }
        }
        .task { catalog.refresh() }
        .transaction { $0.animation = nil }
    }
}

private struct LaunchArtworkEditor: View {
    let app: LaunchArtworkApp
    @ObservedObject var customizations: CustomizationModel
    @StateObject private var model = LaunchArtworkModel()
    @State private var selectedPhoto: PhotosPickerItem?
    @State private var showsPhotos = false
    @State private var asksApply = false
    @State private var asksRestore = false
    @State private var presentationOwner = UUID()
    private var blocksImport: Bool { model.busy || model.draft != nil || showsPhotos || asksApply || asksRestore || model.message != nil }
    var body: some View {
        List {
            Section {
                HStack {
                    Spacer()
                    Group {
                        if let data = model.preview, let image = UIImage(data: data) {
                            Image(uiImage: image).resizable().scaledToFill()
                        } else { Rectangle().fill(Color(uiColor: .tertiarySystemFill)).overlay { Image(systemName: "photo").foregroundStyle(.secondary) } }
                    }
                    .frame(width: 180, height: min(420, max(100, 180 * CGFloat(model.state?.height ?? 2) / CGFloat(model.state?.width ?? 1))))
                    .clipped().clipShape(RoundedRectangle(cornerRadius: 14))
                    Spacer()
                }.listRowBackground(Color.clear)
            }
            Section {
                Button { showsPhotos = true } label: { Label(L("Choose Photo"), systemImage: "photo") }
                    .disabled(model.state?.count == 0 || model.state == nil)
                Button { Task { await model.saveCurrent(app) } } label: { Label(L("Save Current Launch Image"), systemImage: "square.and.arrow.down") }
                    .disabled(model.state?.count == 0 || model.state == nil)
                if model.draft != nil {
                    Button(L("Discard Changes"), role: .destructive) { model.discard() }
                }
            } footer: { Text(L("Shown briefly while the app opens. Close the selected app before applying.")) }
            Section {
                Button { asksApply = true } label: { Label(L("Apply Changes"), systemImage: "checkmark") }
                    .disabled(model.draft == nil)
                Button { asksRestore = true } label: { Label(L("Restore Original"), systemImage: "arrow.uturn.backward") }
                    .disabled(model.state?.canRestore != true)
                Button { Task { await model.load(app) } } label: { Label(L("Read Again"), systemImage: "arrow.clockwise") }
            }
            if model.state?.count == 0 {
                Section { Text(L("No launch images found. Open the app once, close it, then read again.")).foregroundStyle(.secondary) }
            }
        }
        .disabled(model.busy)
        .navigationTitle(app.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .topBarTrailing) { if model.busy { ProgressView() } } }
        .task { await model.load(app) }
        .onChange(of: blocksImport, initial: true) { _, presenting in customizations.setPresenting(presenting, owner: presentationOwner) }
        .onDisappear { if !showsPhotos { customizations.setPresenting(false, owner: presentationOwner) } }
        .photosPicker(isPresented: $showsPhotos, selection: $selectedPhoto, matching: .images, preferredItemEncoding: .compatible)
        .onChange(of: selectedPhoto) { _, item in
            guard let item else { return }
            selectedPhoto = nil
            Task { await model.choose(item) }
        }
        .alert(L("Apply these changes?"), isPresented: $asksApply) {
            Button(L("Cancel"), role: .cancel) {}
            Button(L("Apply")) { Task { await model.apply(app) } }
        } message: { Text(L("The original launch images will be backed up before applying.")) }
        .alert(L("Restore Original"), isPresented: $asksRestore) {
            Button(L("Cancel"), role: .cancel) {}
            Button(L("Restore")) { Task { await model.restore(app) } }
        } message: { Text(L("Only launch images changed by GestaltX will be restored.")) }
        .alert(L("GestaltX"), isPresented: Binding(get: { model.message != nil }, set: { if !$0 { model.message = nil } })) {
            Button(L("OK"), role: .cancel) { model.message = nil }
        } message: { Text(model.message ?? "") }
    }
}
