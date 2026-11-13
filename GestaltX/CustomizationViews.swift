// SPDX-License-Identifier: GPL-3.0-only
import SwiftUI
import Combine
import UniformTypeIdentifiers

@MainActor
final class CustomizationModel: ObservableObject {
    @Published private(set) var packs: [WallpaperPack] = []
    @Published private(set) var previews: [UUID: Data] = [:]
    @Published private(set) var busy = false
    @Published private(set) var isPresenting = false
    private var presentationOwners = Set<UUID>()
    func setPresenting(_ presenting: Bool, owner: UUID) {
        if presenting { presentationOwners.insert(owner) } else { presentationOwners.remove(owner) }
        isPresenting = !presentationOwners.isEmpty
    }
    @Published var message: String?
    private let store: CustomizationStore
    init() {
        let storage = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("GestaltX/Customization", isDirectory: true)
        store = CustomizationStore(storage: storage, device: UIDevice.current.identifierForVendor?.uuidString ?? "local")
    }
    private func run(_ operation: () async throws -> Void) async {
        guard !busy else { return }
        busy = true; defer { busy = false }
        do { try await operation() } catch is CancellationError {} catch { message = error.localizedDescription }
    }
    private func loadPreviews() async {
        for pack in packs where previews[pack.id] == nil { previews[pack.id] = try? await store.wallpaperPreview(pack.id) }
    }
    func loadWallpapers() async {
        await run { packs = try await store.listWallpapers(); await loadPreviews() }
    }
    @discardableResult
    func importWallpaper(_ url: URL, id: UUID = UUID()) async -> Bool {
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        guard !busy else { return false }
        busy = true; defer { busy = false }
        do { packs = try await store.importWallpaper(url, id: id); await loadPreviews(); return true }
        catch { message = error.localizedDescription; return false }
    }
    func applyWallpaper(_ pack: WallpaperPack) async {
        await run {
            packs = try await store.applyWallpaper(pack.id)
            message = L("Wallpaper added. Open the wallpaper gallery to select it. If it does not appear, restart PosterBoard or respring.")
        }
    }
    func removeWallpaper(_ pack: WallpaperPack) async {
        await run { packs = try await store.removeWallpaper(pack.id); previews.removeValue(forKey: pack.id) }
    }
    func deleteImportedWallpaper(_ pack: WallpaperPack) async {
        await run {
            try await store.deleteImportedWallpaper(pack.id)
            packs.removeAll { $0.id == pack.id }
            previews.removeValue(forKey: pack.id)
        }
    }
    func open(_ identifier: String) {
        guard GXCustomizationAccess.openApplication(identifier) else {
            message = L("The app could not be opened. Open it manually."); return
        }
    }
}

/// Copy mode owns the document inside this app; it does not depend on retained Files bookmarks.
struct CustomizationFilePicker: UIViewControllerRepresentable {
    @Environment(\.dismiss) private var dismiss
    let allowedTypes: [UTType]
    let complete: (Result<URL, Error>) -> Void
    init(allowedTypes: [UTType] = [.data, .zip], complete: @escaping (Result<URL, Error>) -> Void) {
        self.allowedTypes = allowedTypes
        self.complete = complete
    }
    func makeCoordinator() -> Coordinator { Coordinator(complete, cancel: { dismiss() }) }
    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: allowedTypes, asCopy: true)
        picker.delegate = context.coordinator
        picker.allowsMultipleSelection = false
        return picker
    }
    func updateUIViewController(_ uiViewController: UIDocumentPickerViewController, context: Context) {}
    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        let complete: (Result<URL, Error>) -> Void
        let cancel: () -> Void
        init(_ complete: @escaping (Result<URL, Error>) -> Void, cancel: @escaping () -> Void) { self.complete = complete; self.cancel = cancel }
        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) { cancel() }
        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            guard let source = urls.first else { return }
            Task {
                let result = await Task.detached(priority: .userInitiated) { () -> Result<URL, Error> in
                    let scoped = source.startAccessingSecurityScopedResource()
                    defer { if scoped { source.stopAccessingSecurityScopedResource() } }
                    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("GX-Import-\(UUID().uuidString)")
                    do {
                        let size = try source.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
                        guard size.isRegularFile == true, (size.fileSize ?? Int.max) <= CustomizationFiles.maximumFile else {
                            throw CustomizationFailure("The archive is invalid or exceeds the size limit.")
                        }
                        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
                        let target = directory.appendingPathComponent(source.lastPathComponent)
                        try FileManager.default.copyItem(at: source, to: target)
                        return .success(target)
                    } catch { try? FileManager.default.removeItem(at: directory); return .failure(error) }
                }.value
                complete(result)
            }
        }
    }
}

struct WallpapersView: View {
    @ObservedObject var model: CustomizationModel
    @State private var showsImport = false
    @State private var pendingApply: WallpaperPack?
    @State private var pendingDelete: WallpaperPack?
    @State private var presentationOwner = UUID()
    var body: some View {
        List {
            Section {
                Button { showsImport = true } label: { Label(L("Import Wallpaper"), systemImage: "square.and.arrow.down") }
            } footer: { Text(L("Import a .tendies or .zip wallpaper pack. You can also share it to GestaltX.")) }
            if model.packs.isEmpty {
                Section { ContentUnavailableView(L("No Wallpapers"), systemImage: "photo.on.rectangle.angled") }
            } else {
                Section {
                    ForEach(model.packs) { pack in
                        HStack(spacing: 14) {
                            preview(pack).frame(width: 70, height: 110).clipShape(RoundedRectangle(cornerRadius: 12))
                            VStack(alignment: .leading, spacing: 8) {
                                Text(pack.name).font(.headline).lineLimit(2)
                                Label(String(pack.descriptors.count), systemImage: "square.stack").font(.caption).foregroundStyle(.secondary)
                                if pack.isApplied { Label(L("Applied"), systemImage: "checkmark.circle.fill").font(.caption).foregroundStyle(.green) }
                                HStack {
                                    Button(L("Apply")) { pendingApply = pack }.disabled(pack.isApplied)
                                    Spacer()
                                    Button(role: .destructive) { pendingDelete = pack } label: { Image(systemName: "trash") }
                                        .accessibilityLabel(L("Delete"))
                                }.buttonStyle(.borderless)
                            }
                        }.padding(.vertical, 5)
                    }
                }
            }
            Section {
                Button { model.open("com.apple.PosterBoard") } label: { Label(L("Open Wallpaper Gallery"), systemImage: "photo.on.rectangle") }
            }
        }
        .navigationTitle(L("Wallpaper Settings"))
        .navigationBarTitleDisplayMode(.inline)
        .disabled(model.busy)
        .toolbar { ToolbarItem(placement: .topBarTrailing) { if model.busy { ProgressView() } } }
        .task { await model.loadWallpapers() }
        .onChange(of: showsImport || pendingApply != nil || pendingDelete != nil || model.message != nil, initial: true) { _, presenting in
            model.setPresenting(presenting, owner: presentationOwner)
        }
        .onDisappear { if !showsImport { model.setPresenting(false, owner: presentationOwner) } }
        .sheet(isPresented: $showsImport) {
            CustomizationFilePicker { result in
                showsImport = false
                switch result {
                case .success(let url): Task { await model.importWallpaper(url) }
                case .failure(let error): model.message = error.localizedDescription
                }
            }.ignoresSafeArea()
        }
        .alert(L("Apply these changes?"), isPresented: Binding(get: { pendingApply != nil }, set: { if !$0 { pendingApply = nil } })) {
            Button(L("Cancel"), role: .cancel) { pendingApply = nil }
            Button(L("Apply")) { if let pack = pendingApply { Task { await model.applyWallpaper(pack) } }; pendingApply = nil }
        } message: { Text(L("This adds new wallpapers without replacing your existing ones.")) }
        .alert(L("Delete the imported wallpaper pack?"), isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } })) {
            Button(L("Cancel"), role: .cancel) { pendingDelete = nil }
            Button(L("Delete"), role: .destructive) { if let pack = pendingDelete { Task { await model.deleteImportedWallpaper(pack) } }; pendingDelete = nil }
        } message: { Text(L("This only deletes the imported pack from GestaltX. Applied wallpapers will be kept.")) }
        .alert(L("GestaltX"), isPresented: Binding(get: { model.message != nil }, set: { if !$0 { model.message = nil } })) {
            Button(L("OK"), role: .cancel) { model.message = nil }
        } message: { Text(model.message ?? "") }
    }
    @ViewBuilder private func preview(_ pack: WallpaperPack) -> some View {
        if let data = model.previews[pack.id], let image = UIImage(data: data) {
            Image(uiImage: image).resizable().scaledToFill().clipped()
        } else {
            RoundedRectangle(cornerRadius: 12).fill(Color(uiColor: .tertiarySystemFill))
                .overlay { Image(systemName: "photo.on.rectangle.angled").foregroundStyle(.secondary) }
        }
    }
}
