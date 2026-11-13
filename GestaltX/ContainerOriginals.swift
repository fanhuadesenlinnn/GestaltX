// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import Darwin

/// Original bytes live next to the target as `filename.bak`. A small xattr on
/// that file identifies the owner and hashes; there is no IDFV dependency, so
/// reinstalling GestaltX does not orphan another app's originals.
enum ContainerOriginals {
    private static let attribute = "com.huami.GestaltX.original"
    private struct Metadata: Codable {
        let version: Int
        let app: String
        let kind: String
        let path: String
        let hash: String
        var allowed: [String]
        let originallyAbsent: Bool?
    }
    struct Backup {
        let data: Data
        let mode: mode_t
        let protection: Int32?
        let allowed: [String]
        let originallyAbsent: Bool
        func matches(_ data: Data) -> Bool { self.data == data || allowed.contains(CustomizationFiles.digest(data)) }
    }
    static func read(in directory: Int32, name: String, app: String, kind: String, path: String, limit: Int) throws -> Backup? {
        try withFile(in: directory, name: name) { fd in
            try decode(fd, app: app, kind: kind, path: path, limit: limit).0
        }
    }
    private static func withFile<T>(in directory: Int32, name: String, body: (Int32) throws -> T) throws -> T? {
        guard !name.isEmpty, !name.contains("/"), name.utf8.count + 4 <= 255 else { throw changed }
        let fd = openat(directory, name + ".bak", O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        if fd < 0, errno == ENOENT { return nil }
        guard fd >= 0 else { throw error() }
        defer { close(fd) }
        return try body(fd)
    }
    private static func decode(_ fd: Int32, app: String, kind: String, path: String, limit: Int) throws -> (Backup, Metadata) {
        var info = stat(), after = stat()
        guard fstat(fd, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG, info.st_nlink == 1,
              info.st_size >= 0, info.st_size <= limit else { throw changed }
        let length = fgetxattr(fd, attribute, nil, 0, 0, 0)
        guard length > 0, length <= 8192 else { throw changed }
        var bytes = Data(count: length)
        let got = bytes.withUnsafeMutableBytes { fgetxattr(fd, attribute, $0.baseAddress, $0.count, 0, 0) }
        guard got == length, let meta = try? PropertyListDecoder().decode(Metadata.self, from: bytes),
              meta.version == 1, meta.app == app, meta.kind == kind, meta.path == path,
              meta.allowed.count <= 2,
              (meta.originallyAbsent == true ? info.st_size == 0 : info.st_size > 0) else { throw changed }
        let data = try FileHandle(fileDescriptor: fd, closeOnDealloc: false).read(upToCount: limit + 1) ?? Data()
        guard data.count == info.st_size, CustomizationFiles.digest(data) == meta.hash,
              fstat(fd, &after) == 0, after.st_size == info.st_size,
              after.st_mtimespec.tv_sec == info.st_mtimespec.tv_sec,
              after.st_mtimespec.tv_nsec == info.st_mtimespec.tv_nsec else { throw changed }
        var protection: Int32?
        #if os(iOS)
        let value = fcntl(fd, F_GETPROTECTIONCLASS)
        if value >= 0 { protection = value }
        #endif
        return (Backup(data: data, mode: info.st_mode & 0o777, protection: protection, allowed: meta.allowed,
                       originallyAbsent: meta.originallyAbsent == true), meta)
    }
    @discardableResult
    static func prepare(in directory: Int32, name: String, app: String, kind: String, path: String,
                        original: Data, mode: mode_t, protection: Int32?, current: Data, replacement: Data, limit: Int,
                        legacyExpected: String? = nil, originallyAbsent: Bool = false) throws -> Backup {
        guard (originallyAbsent ? original.isEmpty : !original.isEmpty), original.count <= limit, name.utf8.count + 4 <= 255,
              !name.contains("/"), !name.contains("\0") else { throw changed }
        if let existing = try read(in: directory, name: name, app: app, kind: kind, path: path, limit: limit) {
            guard !originallyAbsent || existing.originallyAbsent else { throw changed }
            guard existing.matches(current) else { throw CustomizationFailure("The app replaced this file. Its existing backup was kept.") }
            // Update only the xattr, never the original audio/image bytes.
            let fd = openat(directory, name + ".bak", O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
            guard fd >= 0 else { throw error() }
            defer { close(fd) }
            let (backup, old) = try decode(fd, app: app, kind: kind, path: path, limit: limit)
            guard backup.data == existing.data else { throw changed }
            var meta = old
            meta.allowed = Array(Set([CustomizationFiles.digest(current), CustomizationFiles.digest(replacement)])).sorted()
            try writeMetadata(meta, fd: fd)
            guard fsync(fd) == 0 else { throw error() }
            guard let verified = try read(in: directory, name: name, app: app, kind: kind, path: path, limit: limit),
                  verified.data == backup.data, verified.allowed == meta.allowed else { throw changed }
            return verified
        }
        let temporary = ".GestaltX-\(UUID().uuidString)"
        let fd = openat(directory, temporary, O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw error() }
        defer { close(fd); unlinkat(directory, temporary, 0) }
        try original.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let count = Darwin.write(fd, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                if count < 0, errno == EINTR { continue }
                guard count > 0 else { throw error() }
                offset += count
            }
        }
        let hashes = legacyExpected.map { [CustomizationFiles.digest(original), $0] }
            ?? [CustomizationFiles.digest(current), CustomizationFiles.digest(replacement)]
        let meta = Metadata(version: 1, app: app, kind: kind, path: path, hash: CustomizationFiles.digest(original),
                            allowed: Array(Set(hashes)).sorted(), originallyAbsent: originallyAbsent ? true : nil)
        guard fchmod(fd, mode) == 0 else { throw error() }
        #if os(iOS)
        if let protection { guard fcntl(fd, F_SETPROTECTIONCLASS, protection) == 0 else { throw error() } }
        #endif
        try writeMetadata(meta, fd: fd)
        guard fsync(fd) == 0 else { throw error() }
        // linkat publishes exclusively: an existing .bak is never overwritten.
        guard linkat(directory, temporary, directory, name + ".bak", 0) == 0 else { throw error() }
        guard unlinkat(directory, temporary, 0) == 0 else { throw error() }
        guard let verified = try read(in: directory, name: name, app: app, kind: kind, path: path, limit: limit),
              verified.data == original else { throw changed }
        return verified
    }
    private static func writeMetadata(_ meta: Metadata, fd: Int32) throws {
        let bytes = try PropertyListEncoder().encode(meta)
        guard bytes.withUnsafeBytes({ fsetxattr(fd, attribute, $0.baseAddress, $0.count, 0, 0) }) == 0 else { throw error() }
    }
    private static var changed: CustomizationFailure { CustomizationFailure("The original backup is invalid or belongs to another file. It was kept unchanged.") }
    private static func error() -> NSError { NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
}
