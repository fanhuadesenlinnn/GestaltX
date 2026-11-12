// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import CryptoKit
import ZIPFoundation

struct CustomizationFailure: LocalizedError {
    let key: String
    init(_ key: String) { self.key = key }
    var errorDescription: String? { L(key) }
}

enum CustomizationFiles {
    static let maximumFile = 256 * 1024 * 1024
    static let maximumTotal = 768 * 1024 * 1024
    static func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    static func relative(_ path: String) throws -> String {
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        guard !path.isEmpty, !path.hasPrefix("/"), !path.contains("\\"), !path.contains("\0"),
              parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }), path.utf8.count < 1024 else {
            throw CustomizationFailure("The archive contains unsafe paths or links.")
        }
        return path
    }
    static func checked(_ relativePath: String, in root: URL, missing: Bool = false) throws -> URL {
        let path = try relative(relativePath)
        let fm = FileManager.default
        let rootValues = try root.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey])
        guard rootValues.isDirectory == true, rootValues.isSymbolicLink != true else {
            throw CustomizationFailure("The archive contains unsafe paths or links.")
        }
        var next = root
        for part in path.split(separator: "/") {
            next.appendPathComponent(String(part))
            do {
                let values = try next.resourceValues(forKeys: [.isSymbolicLinkKey])
                guard values.isSymbolicLink != true else { throw CustomizationFailure("The archive contains unsafe paths or links.") }
            } catch {
                // attributesOfItem distinguishes a broken symbolic link from an absent item.
                if missing, let attributes = try? fm.attributesOfItem(atPath: next.path),
                   attributes[.type] as? FileAttributeType == .typeSymbolicLink {
                    throw CustomizationFailure("The archive contains unsafe paths or links.")
                }
                if missing, (error as NSError).code == NSFileReadNoSuchFileError { continue }
                throw error
            }
        }
        return next
    }
    static func read(_ url: URL) throws -> Data {
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true,
              let size = values.fileSize, size >= 0, size <= maximumFile else {
            throw CustomizationFailure("The archive is invalid or exceeds the size limit.")
        }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        guard let data = try handle.read(upToCount: maximumFile + 1), data.count == size else {
            throw CustomizationFailure("The files changed. Read again before applying.")
        }
        return data
    }
    static func tree(_ root: URL) throws -> [String: String] {
        guard let iterator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey], options: []) else {
            throw CustomizationFailure("The archive is invalid or exceeds the size limit.")
        }
        var result: [String: String] = [:], total = 0, count = 0
        for case let url as URL in iterator {
            count += 1
            guard count <= 4000 else { throw CustomizationFailure("The archive is invalid or exceeds the size limit.") }
            // Enumeration can return /private/var for a root spelled /var.
            // Normalize that system alias before deriving any relative path.
            func normalized(_ path: String) -> String { path.hasPrefix("/var/") ? "/private" + path : path }
            let base = normalized(root.standardizedFileURL.path).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            let child = normalized(url.standardizedFileURL.path)
            let prefix = "/" + base + "/"
            guard child.hasPrefix(prefix) else { throw CustomizationFailure("The archive contains unsafe paths or links.") }
            let relativePath = String(child.dropFirst(prefix.count))
            _ = try checked(relativePath, in: root)
            let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey])
            if values.isDirectory == true { continue }
            guard values.isRegularFile == true else { throw CustomizationFailure("The archive contains unsafe paths or links.") }
            let data = try read(url); total += data.count
            guard total <= maximumTotal else { throw CustomizationFailure("The archive is invalid or exceeds the size limit.") }
            result[relativePath] = digest(data)
        }
        return result
    }
    static func saveVerified<T: Codable>(_ object: T, to url: URL) throws {
        let data = try PropertyListEncoder().encode(object)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
        guard try Data(contentsOf: url) == data else { throw CustomizationFailure("The original files could not be backed up.") }
    }
}

enum CustomizationArchive {
    static func log(_ text: String) {
        NotificationCenter.default.post(name: Notification.Name("GestaltX.worse_query.log"), object: nil,
                                        userInfo: ["message": text])
    }

    private static func archiveErrorName(_ error: Error) -> String {
        let ns = error as NSError
        if let archiveError = error as? Archive.ArchiveError {
            let hint: String
            switch archiveError {
            case .unreadableArchive: hint = "文件损坏或无法读取"
            case .invalidCRC32: hint = "校验和不匹配，包已损坏"
            case .missingEndOfCentralDirectoryRecord: hint = "不是有效的 ZIP 包，或下载不完整/已截断"
            case .uncontainedSymlink: hint = "包含指向外部的符号链接"
            default: hint = "ZIP 结构错误"
            }
            return "\(archiveError)（\(hint)，code \(ns.code)）"
        }
        if let failure = error as? CustomizationFailure {
            return failure.errorDescription ?? failure.key
        }
        return "code \(ns.code): \(ns.localizedDescription)"
    }

    static func extract(_ source: URL, into root: URL) throws {
        let size = (try? source.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? -1
        log("Wallpaper import: 打开 \(source.lastPathComponent)（\(size) bytes）")
        guard try source.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? Int.max <= CustomizationFiles.maximumFile else {
            throw CustomizationFailure("The archive is invalid or exceeds the size limit.")
        }
        let archive: Archive
        do {
            archive = try Archive(url: source, accessMode: .read)
        } catch {
            log("Wallpaper import: 打开 ZIP 失败 — \(archiveErrorName(error))")
            throw error
        }
        var seen = Set<String>(), expected: UInt64 = 0, count = 0
        for entry in archive {
            count += 1
            let path = entry.path.hasSuffix("/") ? String(entry.path.dropLast()) : entry.path
            _ = try CustomizationFiles.relative(path)
            guard entry.type != .symlink,
                  seen.insert(path.precomposedStringWithCanonicalMapping.lowercased()).inserted,
                  count <= 4000, entry.uncompressedSize <= UInt64(CustomizationFiles.maximumFile) else {
                throw CustomizationFailure("The archive contains unsafe paths or links.")
            }
            expected += entry.uncompressedSize
            guard expected <= UInt64(CustomizationFiles.maximumTotal) else { throw CustomizationFailure("The archive is invalid or exceeds the size limit.") }
        }
        let fm = FileManager.default
        guard !fm.fileExists(atPath: root.path) else { throw CustomizationFailure("The archive contains unsafe paths or links.") }
        try fm.createDirectory(at: root, withIntermediateDirectories: false)
        var successful = false, total = 0
        defer { if !successful { try? fm.removeItem(at: root) } }
        for entry in archive {
            try Task.checkCancellation()
            let path = entry.path.hasSuffix("/") ? String(entry.path.dropLast()) : entry.path
            let target = try CustomizationFiles.checked(path, in: root, missing: true)
            if entry.type == .directory {
                try fm.createDirectory(at: target, withIntermediateDirectories: true)
                continue
            }
            try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            guard fm.createFile(atPath: target.path, contents: nil) else { throw CocoaError(.fileWriteUnknown) }
            let handle = try FileHandle(forWritingTo: target)
            var extracted = 0
            do {
                let crc = try archive.extract(entry, bufferSize: 64 * 1024) { data in
                    extracted += data.count; total += data.count
                    guard extracted <= CustomizationFiles.maximumFile, total <= CustomizationFiles.maximumTotal else {
                        throw CustomizationFailure("The archive is invalid or exceeds the size limit.")
                    }
                    try handle.write(contentsOf: data)
                }
                try handle.close()
                guard crc == entry.checksum, UInt64(extracted) == entry.uncompressedSize else {
                    throw CustomizationFailure("The archive is invalid or exceeds the size limit.")
                }
            } catch {
                try? handle.close()
                log("Wallpaper import: 解压条目 '\(path)' 失败 — \(archiveErrorName(error))")
                throw error
            }
        }
        successful = true
        log("Wallpaper import: 完成（共解压 \(total) bytes）")
    }
}

/// Original absence is different from an empty file. The journal survives app relaunches.
struct CustomizationOriginal: Codable, Equatable, Sendable {
    var data: Data?
}
struct CustomizationJournal: Codable {
    var device: String
    var originals: [String: CustomizationOriginal] = [:]
}
struct CustomizationFileTransaction {
    let root: URL
    let storage: URL
    let device: String
    var beforeWrite: (() throws -> Void)?
    private var journalURL: URL { storage.appendingPathComponent("Originals.plist") }
    private func journal() throws -> CustomizationJournal {
        guard FileManager.default.fileExists(atPath: journalURL.path) else { return .init(device: device) }
        let journal = try PropertyListDecoder().decode(CustomizationJournal.self, from: Data(contentsOf: journalURL))
        guard journal.device == device else { throw CustomizationFailure("The original files could not be backed up.") }
        return journal
    }
    private func current(_ relative: String) throws -> CustomizationOriginal {
        let target = try CustomizationFiles.checked(relative, in: root, missing: true)
        guard FileManager.default.fileExists(atPath: target.path) else { return .init(data: nil) }
        return .init(data: try CustomizationFiles.read(target))
    }
    private func write(_ original: CustomizationOriginal, to path: String) throws {
        let url = try CustomizationFiles.checked(path, in: root, missing: true)
        if let data = original.data {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
        } else if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
        guard try current(path) == original else { throw CustomizationFailure("The files changed. Read again before applying.") }
    }
    func replace(_ changes: [String: Data], expected: [String: CustomizationOriginal]? = nil) throws {
        try perform(changes.mapValues { CustomizationOriginal(data: $0) }, expected: expected, savingOriginals: true)
    }
    func restore() throws {
        try perform(journal().originals, expected: nil, savingOriginals: false)
    }
    var hasOriginals: Bool { (try? journal().originals.isEmpty == false) ?? false }
    var hasChanges: Bool {
        guard let originals = try? journal().originals else { return false }
        return originals.contains { path, value in (try? current(path)) != value }
    }
    private func perform(_ changes: [String: CustomizationOriginal], expected: [String: CustomizationOriginal]?, savingOriginals: Bool) throws {
        guard !changes.isEmpty else { return }
        var journal = try journal(), before: [String: CustomizationOriginal] = [:]
        for path in changes.keys.sorted() {
            before[path] = try current(path)
            if let value = expected?[path], value != before[path] { throw CustomizationFailure("The files changed. Read again before applying.") }
            if savingOriginals, journal.originals[path] == nil { journal.originals[path] = before[path] }
        }
        try CustomizationFiles.saveVerified(before, to: storage.appendingPathComponent("Backups/\(UUID().uuidString).plist"))
        if savingOriginals { try CustomizationFiles.saveVerified(journal, to: journalURL) }
        for path in before.keys where try current(path) != before[path] { throw CustomizationFailure("The files changed. Read again before applying.") }
        var written: [String] = []
        do {
            for path in changes.keys.sorted() {
                guard try current(path) == before[path] else { throw CustomizationFailure("The files changed. Read again before applying.") }
                written.append(path)
                try beforeWrite?()
                try write(changes[path]!, to: path)
            }
        } catch {
            var recovered = true
            for path in written.reversed() { do { try write(before[path]!, to: path) } catch { recovered = false } }
            if !recovered { throw CustomizationFailure("Some files could not be restored. The backup has been kept.") }
            throw error
        }
    }
}
