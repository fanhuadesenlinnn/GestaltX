// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import Darwin

/// Pin the selected app's snapshot hierarchy. A target app changing a symlink
/// cannot redirect a launch-image write into another container or directory.
final class LaunchArtworkDirectory {
    struct File {
        let data: Data
        let device: UInt64
        let inode: UInt64
        let mode: mode_t
        let protection: Int32?
    }
    private let descriptors: [Int32]
    private let components: [String]
    private let identifier: String
    private var directory: Int32 { descriptors.last! }
    static let maximumFile = 20 * 1024 * 1024

    init(container: URL, identifier: String) throws {
        self.identifier = identifier
        guard Self.validIdentifier(identifier) else { throw Self.changed }
        let parts = ["Library", "SplashBoard", "Snapshots", "\(identifier) - {DEFAULT GROUP}"]
        var handles: [Int32] = []
        do {
            let root = open(container.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard root >= 0 else { throw Self.fileError() }
            handles.append(root)
            for part in parts {
                let child = openat(handles.last!, part, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                guard child >= 0 else { throw Self.fileError() }
                handles.append(child)
            }
        } catch { handles.forEach { close($0) }; throw error }
        descriptors = handles; components = parts
    }
    deinit { descriptors.forEach { close($0) } }
    func original(_ name: String) throws -> ContainerOriginals.Backup? {
        guard Self.validName(name) else { throw Self.changed }
        try validateHierarchy()
        return try ContainerOriginals.read(in: directory, name: name, app: identifier, kind: "launch", path: name, limit: Self.maximumFile)
    }
    func backup(_ name: String, file: File, replacement: Data, legacy: LaunchArtworkStore.Saved? = nil) throws {
        guard Self.validName(name) else { throw Self.changed }
        try validateHierarchy()
        _ = try ContainerOriginals.prepare(in: directory, name: name, app: identifier, kind: "launch", path: name,
            original: legacy?.original ?? file.data, mode: legacy.map { mode_t($0.mode) } ?? file.mode,
            protection: legacy?.protection ?? file.protection, current: file.data, replacement: replacement, limit: Self.maximumFile)
    }
    func migrateBackup(_ name: String, saved: LaunchArtworkStore.Saved) throws {
        guard Self.validName(name) else { throw Self.changed }
        try validateHierarchy()
        if let existing = try original(name) {
            guard existing.data == saved.original else { throw Self.changed }
            return
        }
        _ = try ContainerOriginals.prepare(in: directory, name: name, app: identifier, kind: "launch", path: name,
            original: saved.original, mode: mode_t(saved.mode), protection: saved.protection,
            current: saved.original, replacement: saved.original, limit: Self.maximumFile, legacyExpected: saved.expected)
    }
    func archiveLegacy(_ name: String, data: Data) throws {
        guard !name.isEmpty, name.utf8.count <= 200, !name.contains("/"), !name.contains("\\"),
              name != ".", name != "..", name.hasSuffix(".plist"), data.count <= 128 * 1024 * 1024 else { throw Self.changed }
        try validateHierarchy()
        if mkdirat(directory, ".GestaltX-legacy", 0o700) != 0, errno != EEXIST { throw Self.fileError() }
        let folder = openat(directory, ".GestaltX-legacy", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard folder >= 0 else { throw Self.fileError() }
        defer { close(folder) }
        func existing() throws -> Data? {
            let fd = openat(folder, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
            if fd < 0, errno == ENOENT { return nil }
            guard fd >= 0 else { throw Self.fileError() }
            defer { close(fd) }
            var info = stat()
            guard fstat(fd, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG, info.st_size == data.count else { throw Self.changed }
            return try FileHandle(fileDescriptor: fd, closeOnDealloc: false).read(upToCount: data.count + 1)
        }
        if let old = try existing() { guard old == data else { throw Self.changed }; return }
        let temporary = ".GestaltX-\(UUID().uuidString)"
        let fd = openat(folder, temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw Self.fileError() }
        defer { close(fd); unlinkat(folder, temporary, 0) }
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let count = Darwin.write(fd, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                if count < 0, errno == EINTR { continue }
                guard count > 0 else { throw Self.fileError() }
                offset += count
            }
        }
        guard fsync(fd) == 0, linkat(folder, temporary, folder, name, 0) == 0 else { throw Self.fileError() }
        guard try existing() == data else { throw Self.changed }
    }
    static func validIdentifier(_ identifier: String) -> Bool {
        identifier.contains(".") && identifier.utf8.count <= 255 && identifier != "." && identifier != ".."
            && identifier.utf8.allSatisfy { (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || [45, 46].contains($0) }
    }
    static func validName(_ name: String) -> Bool {
        !name.isEmpty && !name.hasPrefix(".") && !name.contains("/") && !name.contains("\\") && !name.contains("\0")
            && name.utf8.count <= 255 && ["ktx", "png", "jpg", "jpeg"].contains((name as NSString).pathExtension.lowercased())
    }
    func names() throws -> [String] {
        let duplicate = dup(directory)
        guard duplicate >= 0 else { throw Self.fileError() }
        guard let stream = fdopendir(duplicate) else { close(duplicate); throw Self.fileError() }
        defer { closedir(stream) }
        rewinddir(stream)
        var names: [String] = [], count = 0
        errno = 0
        while let entry = readdir(stream) {
            count += 1; guard count <= 256 else { throw Self.changed }
            let capacity = MemoryLayout.size(ofValue: entry.pointee.d_name)
            let name = withUnsafePointer(to: &entry.pointee.d_name) { pointer in
                pointer.withMemoryRebound(to: CChar.self, capacity: capacity) { String(cString: $0) }
            }
            if Self.validName(name) { names.append(name) }
            errno = 0
        }
        guard errno == 0 else { throw Self.fileError() }
        guard names.count <= 16 else { throw Self.changed }
        return names.sorted()
    }
    func read(_ name: String) throws -> File? {
        guard Self.validName(name) else { throw Self.changed }
        let fd = openat(directory, name, O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
        if fd < 0, errno == ENOENT { return nil }
        guard fd >= 0 else { throw Self.fileError() }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0 else { throw Self.fileError() }
        guard (info.st_mode & S_IFMT) == S_IFREG, info.st_size >= 0,
              info.st_size <= Self.maximumFile else { throw Self.changed }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: false)
        let data = try handle.read(upToCount: Self.maximumFile + 1) ?? Data()
        var after = stat()
        guard data.count == info.st_size, fstat(fd, &after) == 0, after.st_size == info.st_size,
              after.st_mtimespec.tv_sec == info.st_mtimespec.tv_sec,
              after.st_mtimespec.tv_nsec == info.st_mtimespec.tv_nsec else { throw Self.changed }
        var protection: Int32?
        #if os(iOS)
        let value = fcntl(fd, F_GETPROTECTIONCLASS)
        if value >= 0 { protection = value }
        #endif
        return File(data: data, device: UInt64(UInt32(bitPattern: info.st_dev)), inode: UInt64(info.st_ino), mode: info.st_mode & 0o777, protection: protection)
    }
    func replace(_ name: String, expected: File, data: Data, protection: Int32? = nil, mode: mode_t? = nil) throws {
        guard data.count <= Self.maximumFile, let current = try read(name),
              current.device == expected.device, current.inode == expected.inode, current.data == expected.data else { throw Self.changed }
        try validateHierarchy()
        let temporary = ".GestaltX-\(UUID().uuidString)"
        let fd = openat(directory, temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw Self.fileError() }
        defer { close(fd); unlinkat(directory, temporary, 0) }
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let count = Darwin.write(fd, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                if count < 0, errno == EINTR { continue }
                guard count > 0 else { throw Self.fileError() }
                offset += count
            }
        }
        guard fchmod(fd, mode ?? current.mode) == 0 else { throw Self.fileError() }
        #if os(iOS)
        if let value = protection ?? current.protection {
            guard fcntl(fd, F_SETPROTECTIONCLASS, value) == 0 else { throw Self.fileError() }
        }
        #endif
        guard fsync(fd) == 0 else { throw Self.fileError() }
        try validateHierarchy()
        guard let latest = try read(name), latest.inode == expected.inode, latest.device == expected.device,
              latest.data == expected.data else { throw Self.changed }
        guard renameat(directory, temporary, directory, name) == 0 else { throw Self.fileError() }
        guard try read(name)?.data == data else { throw Self.changed }
    }
    private func validateHierarchy() throws {
        for (index, component) in components.enumerated() {
            var path = stat(), pinned = stat()
            guard fstatat(descriptors[index], component, &path, AT_SYMLINK_NOFOLLOW) == 0,
                  fstat(descriptors[index + 1], &pinned) == 0,
                  (path.st_mode & S_IFMT) == S_IFDIR, path.st_dev == pinned.st_dev, path.st_ino == pinned.st_ino else { throw Self.changed }
        }
    }
    private static var changed: CustomizationFailure { CustomizationFailure("The files changed. Read again before applying.") }
    private static func fileError() -> NSError { NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
}
