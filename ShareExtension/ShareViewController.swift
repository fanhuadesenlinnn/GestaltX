// SPDX-License-Identifier: GPL-3.0-only
// File handoff follows LoadController / LCSign's Share Extension workflow.
import UIKit
import UniformTypeIdentifiers

@objc(GXShareViewController)
final class ShareViewController: UIViewController {
    private struct Receipt: Sendable {
        let inbox: SharedPlistInbox
        let entry: SharedPlistEntry
        var wallpaper: Bool { inbox.kind == .wallpaper }
        func cancel() { try? inbox.acknowledge(entry) }
    }
    private let status = UILabel()
    private let spinner = UIActivityIndicatorView(style: .medium)
    private let closeButton = UIButton(type: .system)
    private var started = false
    private var work: Task<Void, Never>?
    private var receivedWallpaper = false

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemGroupedBackground
        let title = UILabel()
        title.text = "GestaltX"
        title.font = .preferredFont(forTextStyle: .title2)
        title.textAlignment = .center
        status.text = text("Importing…")
        status.font = .preferredFont(forTextStyle: .body)
        status.numberOfLines = 0
        status.textAlignment = .center
        closeButton.setTitle(text("Cancel"), for: .normal)
        closeButton.addTarget(self, action: #selector(close), for: .touchUpInside)
        let stack = UIStackView(arrangedSubviews: [title, spinner, status, closeButton])
        stack.axis = .vertical
        stack.spacing = 20
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 28),
            stack.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -28),
            stack.centerYAnchor.constraint(equalTo: view.safeAreaLayoutGuide.centerYAnchor)
        ])
        spinner.startAnimating()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        guard !started else { return }
        started = true
        work = Task { await receive() }
    }

    private func receive() async {
        do {
            let providers = (extensionContext?.inputItems as? [NSExtensionItem])?.flatMap { $0.attachments ?? [] } ?? []
            guard providers.count == 1 else { throw SharedPlistError(key: "Share one file at a time.") }
            guard SharedAppGroups.inboxes.first != nil else {
                throw SharedPlistError(key: "Sign GestaltX and its share extension with the same App Group, then try again.")
            }
            let receipt = try await read(providers[0])
            if Task.isCancelled { receipt.cancel(); throw CancellationError() }
            receivedWallpaper = receipt.wallpaper
            // The inbox is the durable handoff; URL opening is just a notification.
            var components = URLComponents()
            components.scheme = SharedAppGroups.hostURLScheme
            components.host = "share"
            components.queryItems = [URLQueryItem(name: "from", value: SharedAppGroups.hostBundleIdentifier)]
            guard let url = components.url else { throw SharedPlistError(key: "The shared plist could not be read. Share it again.") }
            if let context = extensionContext {
                let opened = await context.open(url)
                guard !Task.isCancelled else { return }
                if opened { finish() } else { openContainingApp(url) }
            } else { showSaved() }
        } catch is CancellationError {
            // The user closed the extension before publishing a document.
        } catch {
            spinner.stopAnimating()
            status.text = error.localizedDescription
            closeButton.setTitle(text("OK"), for: .normal)
        }
    }

    private func read(_ provider: NSItemProvider) async throws -> Receipt {
        var types = ["com.huami.gestaltx.wallpaper", UTType.zip.identifier, UTType.propertyList.identifier, UTType.xml.identifier, UTType.data.identifier]
        let archiveHint = provider.registeredTypeIdentifiers.contains {
            $0 == "com.huami.gestaltx.wallpaper" || UTType($0)?.conforms(to: .zip) == true
        }
        types += provider.registeredTypeIdentifiers.filter { !types.contains($0) && $0 != UTType.fileURL.identifier }
        var firstError: Error?
        for type in types where provider.hasItemConformingToTypeIdentifier(type) {
            for inPlace in [false, true] {
                do { return try await readFile(provider, type: type, inPlace: inPlace, archiveHint: archiveHint) }
                catch {
                    try Task.checkCancellation()
                    if firstError == nil { firstError = error }
                }
            }
        }
        guard provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) else {
            throw firstError ?? SharedPlistError(key: "Choose a MobileGestalt plist or a wallpaper pack.")
        }
        let suggestedName = provider.suggestedName
        return try await ItemProviderLoad<Receipt>.load { request in
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, error in
                request.complete(onDiscard: { $0.cancel() }) {
                    if let error { throw error }
                    let url = (item as? URL) ?? (item as? Data).flatMap { URL(dataRepresentation: $0, relativeTo: nil) }
                    guard let url else { throw SharedPlistError(key: "The shared plist could not be read. Share it again.") }
                    return try Self.save(url, suggestedName: suggestedName, archiveHint: archiveHint, checkCancellation: request.checkCancellation)
                }
            }
            return nil
        }
    }

    private func readFile(_ provider: NSItemProvider, type: String, inPlace: Bool, archiveHint: Bool) async throws -> Receipt {
        let suggestedName = provider.suggestedName
        return try await ItemProviderLoad<Receipt>.load { request in
            let complete: @Sendable (URL?, Error?) -> Void = { url, error in
                request.complete(onDiscard: { $0.cancel() }) {
                    if let error { throw error }
                    guard let url else { throw SharedPlistError(key: "The shared plist could not be read. Share it again.") }
                    return try Self.save(url, suggestedName: suggestedName, archiveHint: archiveHint, checkCancellation: request.checkCancellation)
                }
            }
            if inPlace {
                return provider.loadInPlaceFileRepresentation(forTypeIdentifier: type) { url, _, error in complete(url, error) }
            } else {
                return provider.loadFileRepresentation(forTypeIdentifier: type, completionHandler: complete)
            }
        }
    }

    nonisolated private static func save(_ url: URL, suggestedName: String?, archiveHint: Bool, checkCancellation: () throws -> Void) throws -> Receipt {
        let wallpaper = archiveHint || SharedPlistInbox.isWallpaperName(suggestedName ?? "") || SharedPlistInbox.isWallpaperName(url.lastPathComponent)
        let inboxes = wallpaper ? SharedAppGroups.wallpaperInboxes : SharedAppGroups.inboxes
        guard let inbox = inboxes.first else { throw SharedPlistError(key: "Sign GestaltX and its share extension with the same App Group, then try again.") }
        let name = suggestedName ?? url.lastPathComponent
        try checkCancellation()
        let receipt: Receipt
        if wallpaper {
            let entry = try inbox.enqueueWallpaper(at: url, name: name, checkCancellation: checkCancellation)
            receipt = Receipt(inbox: inbox, entry: entry)
        } else {
            let data = try SharedPlistInbox.readDocument(at: url)
            let publication = try SharedPlistInbox.enqueue(data, name: name, in: inboxes, checkCancellation: checkCancellation)
            receipt = Receipt(inbox: publication.inbox, entry: publication.entry)
        }
        do { try checkCancellation() } catch { receipt.cancel(); throw error }
        return receipt
    }

    // Same modern responder-chain open used by LoadController. No sharedApplication.
    private func openContainingApp(_ url: URL) {
        var responder: UIResponder? = self
        while let current = responder {
            if let app = current as? UIApplication {
                app.open(url, options: [:]) { [weak self] opened in
                    guard let self, self.work?.isCancelled != true else { return }
                    if opened { self.finish() } else { self.showSaved() }
                }
                return
            }
            responder = current.next
        }
        showSaved()
    }

    private func showSaved() {
        spinner.stopAnimating()
        status.text = text(receivedWallpaper ? "Open GestaltX to confirm importing the wallpaper pack." : "Open GestaltX to confirm importing the plist.")
        closeButton.setTitle(text("OK"), for: .normal)
    }
    private func finish() { extensionContext?.completeRequest(returningItems: nil) }
    @objc private func close() {
        work?.cancel()
        extensionContext?.completeRequest(returningItems: nil)
    }
    private func text(_ key: String) -> String { NSLocalizedString(key, comment: "") }
}
