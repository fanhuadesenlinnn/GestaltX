// SPDX-License-Identifier: GPL-3.0-only
import Foundation

enum SharedImportPreparation<Offer> {
    case ready(Offer)
    case rejected(String)
    case deferred(String?)
}

enum SharedImportQueue {
    typealias Item = (inbox: SharedPlistInbox, entry: SharedPlistEntry)

    enum Selection<Offer> {
        case ready(Offer)
        case deferred(String?)
        case empty(lastRejection: String?)

        var blocksAutomaticRead: Bool {
            if case .empty = self { return false }
            return true
        }
    }

    static func snapshot(in inboxes: [SharedPlistInbox]) throws -> [Item] {
        var items: [Item] = []
        var firstError: Error?
        for inbox in inboxes {
            do { items.append(contentsOf: try inbox.entries().map { (inbox, $0) }) }
            catch { if firstError == nil { firstError = error } }
        }
        // One damaged container must not hide documents already delivered to
        // another signed App Group. Keep reporting the error when there are no
        // readable entries, including after the healthy inbox has been drained.
        if items.isEmpty, let firstError { throw firstError }
        return items.sorted {
            if $0.entry.created != $1.entry.created { return $0.entry.created < $1.entry.created }
            if $0.entry.id != $1.entry.id { return $0.entry.id.uuidString < $1.entry.id.uuidString }
            return $0.inbox.directory.path < $1.inbox.directory.path
        }
    }

    @MainActor
    static func next<Offer>(in snapshot: [Item],
                            prepare: (SharedPlistInbox, SharedPlistEntry) async -> SharedImportPreparation<Offer>) async -> Selection<Offer> {
        var lastRejection: String?
        // Visit each captured entry at most once, even if quarantine fails or
        // another extension keeps adding files while verification is in progress.
        for item in snapshot {
            switch await prepare(item.inbox, item.entry) {
            case .ready(let offer): return .ready(offer)
            case .rejected(let message): lastRejection = message
            case .deferred(let message): return .deferred(message)
            }
        }
        return .empty(lastRejection: lastRejection)
    }
}
