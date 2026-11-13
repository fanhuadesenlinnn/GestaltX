// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import Darwin

struct AppSoundEntry: Identifiable, Hashable, Sendable {
    let path: String
    let bytes: Int64
    let device: UInt64
    let inode: UInt64
    var group: String? = nil
    var id: String { (group.map { $0 + ":" } ?? "") + path }
}

/// Directory-relative operations never follow an app-controlled symbolic link.
final class AppSoundDirectory {
    static let maximumFile = 32 * 1024 * 1024
    static let extensions: Set<String> = ["wav", "caf", "aif", "aiff", "m4a", "mp3", "aac", "flac"]
    static let importExtensions: Set<String> = extensions
    struct File: Sendable {
        let data: Data
        let device: UInt64
        let inode: UInt64
        let mode: mode_t
        let protection: Int32?
    }
    struct Scan: Sendable {
        let files: [AppSoundEntry]
        let partial: Bool
    }
    private let root: Int32
    private let container: URL
    init(container: URL) throws {
        self.container = container
        root = open(container.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard root >= 0 else { throw Self.error() }
    }
    deinit { close(root) }
    static func validPath(_ path: String) -> Bool {
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        return ((parts.count == 3 && parts[0] == "Library" && ["Sound", "Sounds"].contains(String(parts[1])))
                || (parts.count == 2 && ["Sound", "Sounds"].contains(String(parts[0]))))
            && path.utf8.count < 1024 && !path.contains("\\") && !path.contains("\0")
            && parts.allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." && !$0.hasPrefix(".GestaltX-") }
            && extensions.contains((path as NSString).pathExtension.lowercased())
    }
    func scan() throws -> Scan {
        // Only explicit sound-resource directories are inspected, one level.
        // Chat attachments, favorites, mini-apps and arbitrary caches are excluded.
        var files: [AppSoundEntry] = [], partial = false
        func scanDirectory(_ parts: [String]) throws {
            var fd = dup(root)
            guard fd >= 0 else { throw Self.error() }
            for part in parts {
                let child = openat(fd, part, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                let failure = errno
                close(fd)
                if child < 0 { if failure != ENOENT { partial = true }; return }
                fd = child
            }
            guard let stream = fdopendir(fd) else { close(fd); partial = true; return }
            defer { closedir(stream) }
            var count = 0
            while true {
                try Task.checkCancellation()
                errno = 0
                guard let entry = readdir(stream) else { if errno != 0 { partial = true }; break }
                count += 1
                guard count <= 1024, files.count < 512 else { partial = true; return }
                let capacity = MemoryLayout.size(ofValue: entry.pointee.d_name)
                let name = withUnsafePointer(to: &entry.pointee.d_name) {
                    $0.withMemoryRebound(to: CChar.self, capacity: capacity) { String(cString: $0) }
                }
                let path = (parts + [name]).joined(separator: "/")
                guard !name.hasPrefix("."), Self.validPath(path) else { continue }
                var info = stat()
                guard fstatat(fd, name, &info, AT_SYMLINK_NOFOLLOW) == 0 else { partial = true; continue }
                guard (info.st_mode & S_IFMT) == S_IFREG, info.st_size > 0, info.st_size <= Self.maximumFile else { continue }
                files.append(AppSoundEntry(path: path, bytes: info.st_size,
                    device: UInt64(UInt32(bitPattern: info.st_dev)), inode: UInt64(info.st_ino)))
            }
        }
        for path in [["Library", "Sounds"], ["Library", "Sound"], ["Sounds"], ["Sound"]] { try scanDirectory(path) }
        return Scan(files: files.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }, partial: partial)
    }
    private func parent<T>(_ path: String, createDirectories: Bool = false, operation: (Int32, String, () throws -> Void) throws -> T) throws -> T {
        guard Self.validPath(path) else { throw Self.changed }
        let components = path.split(separator: "/").map(String.init)
        var handles = [root]
        defer { handles.dropFirst().forEach { close($0) } }
        for part in components.dropLast() {
            if createDirectories, mkdirat(handles.last!, part, 0o755) != 0, errno != EEXIST { throw Self.error() }
            let fd = openat(handles.last!, part, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard fd >= 0 else { throw Self.error() }
            handles.append(fd)
        }
        func validate() throws {
            var current = stat(), pinned = stat()
            guard lstat(container.path, &current) == 0, fstat(root, &pinned) == 0,
                  (current.st_mode & S_IFMT) == S_IFDIR, current.st_dev == pinned.st_dev,
                  current.st_ino == pinned.st_ino else { throw Self.changed }
            for (index, part) in components.dropLast().enumerated() {
                guard fstatat(handles[index], part, &current, AT_SYMLINK_NOFOLLOW) == 0,
                      fstat(handles[index + 1], &pinned) == 0, (current.st_mode & S_IFMT) == S_IFDIR,
                      current.st_dev == pinned.st_dev, current.st_ino == pinned.st_ino else { throw Self.changed }
            }
        }
        try validate()
        return try operation(handles.last!, components.last!, validate)
    }
    private func read(_ name: String, in directory: Int32) throws -> File {
        let fd = openat(directory, name, O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw Self.error() }
        defer { close(fd) }
        var info = stat(), after = stat()
        guard fstat(fd, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG,
              info.st_size > 0, info.st_size <= Self.maximumFile else { throw Self.changed }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: false)
        let data = try handle.read(upToCount: Self.maximumFile + 1) ?? Data()
        guard data.count == info.st_size, fstat(fd, &after) == 0, after.st_size == info.st_size,
              after.st_mtimespec.tv_sec == info.st_mtimespec.tv_sec,
              after.st_mtimespec.tv_nsec == info.st_mtimespec.tv_nsec,
              after.st_ctimespec.tv_sec == info.st_ctimespec.tv_sec,
              after.st_ctimespec.tv_nsec == info.st_ctimespec.tv_nsec else { throw Self.changed }
        var protection: Int32?
        #if os(iOS)
        let value = fcntl(fd, F_GETPROTECTIONCLASS)
        if value >= 0 { protection = value }
        #endif
        return File(data: data, device: UInt64(UInt32(bitPattern: info.st_dev)), inode: UInt64(info.st_ino),
                    mode: info.st_mode & 0o777, protection: protection)
    }
    func read(_ path: String) throws -> File { try parent(path) { directory, name, _ in try read(name, in: directory) } }
    func original(_ path: String, app: String) throws -> ContainerOriginals.Backup? {
        try parent(path) { directory, name, _ in
            try ContainerOriginals.read(in: directory, name: name, app: app, kind: "audio", path: path, limit: Self.maximumFile)
        }
    }
    func backup(_ path: String, app: String, file: File, replacement: Data) throws {
        try parent(path) { directory, name, validate in
            try validate()
            _ = try ContainerOriginals.prepare(in: directory, name: name, app: app, kind: "audio", path: path,
                original: file.data, mode: file.mode, protection: file.protection, current: file.data,
                replacement: replacement, limit: Self.maximumFile)
        }
    }
    func createNamedSound(_ name: String, app: String, data: Data) throws {
        let path = "Library/Sounds/" + name
        guard !name.hasPrefix("."), Self.validPath(path), !data.isEmpty, data.count <= Self.maximumFile else { throw Self.changed }
        try parent(path, createDirectories: true) { directory, leaf, validate in
            func checkAbsent() throws {
                try validate()
                var info = stat()
                if fstatat(directory, leaf, &info, AT_SYMLINK_NOFOLLOW) == 0 { throw CustomizationFailure("A file with this name already exists. Select it from the list to replace it.") }
                guard errno == ENOENT else { throw Self.error() }
            }
            try checkAbsent()
            // A zero-byte .bak with typed metadata records that no override
            // existed. Restore removes the added file and returns to the bundle.
            _ = try ContainerOriginals.prepare(in: directory, name: leaf, app: app, kind: "audio", path: path,
                original: Data(), mode: 0o644, protection: nil, current: Data(), replacement: data,
                limit: Self.maximumFile, originallyAbsent: true)
            let temporary = ".GestaltX-\(UUID().uuidString)"
            let fd = openat(directory, temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o644)
            guard fd >= 0 else { throw Self.error() }
            defer { close(fd); unlinkat(directory, temporary, 0) }
            try data.withUnsafeBytes { bytes in
                var offset = 0
                while offset < bytes.count {
                    let count = Darwin.write(fd, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                    if count < 0, errno == EINTR { continue }
                    guard count > 0 else { throw Self.error() }
                    offset += count
                }
            }
            guard fsync(fd) == 0 else { throw Self.error() }
            try checkAbsent()
            guard linkat(directory, temporary, directory, leaf, 0) == 0 else { throw Self.error() }
            guard try read(leaf, in: directory).data == data else { throw Self.changed }
        }
    }
    func removeAddedSound(_ path: String, expected: File) throws {
        try parent(path) { directory, name, validate in
            try validate()
            let current = try read(name, in: directory)
            guard current.device == expected.device, current.inode == expected.inode,
                  current.data == expected.data else { throw Self.changed }
            guard unlinkat(directory, name, 0) == 0 else { throw Self.error() }
        }
    }
    func replace(_ path: String, expected: File, data: Data, mode: mode_t? = nil, protection: Int32? = nil) throws {
        guard !data.isEmpty, data.count <= Self.maximumFile else { throw Self.changed }
        try parent(path) { directory, name, validate in
            func check() throws {
                try validate()
                let current = try read(name, in: directory)
                guard current.device == expected.device, current.inode == expected.inode,
                      current.data == expected.data else { throw Self.changed }
            }
            try check()
            let temporary = ".GestaltX-\(UUID().uuidString)"
            let fd = openat(directory, temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
            guard fd >= 0 else { throw Self.error() }
            defer { close(fd); unlinkat(directory, temporary, 0) }
            try data.withUnsafeBytes { bytes in
                var offset = 0
                while offset < bytes.count {
                    let count = Darwin.write(fd, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                    if count < 0, errno == EINTR { continue }
                    guard count > 0 else { throw Self.error() }
                    offset += count
                }
            }
            guard fchmod(fd, mode ?? expected.mode) == 0 else { throw Self.error() }
            #if os(iOS)
            if let value = protection ?? expected.protection {
                guard fcntl(fd, F_SETPROTECTIONCLASS, value) == 0 else { throw Self.error() }
            }
            #endif
            guard fsync(fd) == 0 else { throw Self.error() }
            try check()
            guard renameat(directory, temporary, directory, name) == 0 else { throw Self.error() }
            guard try read(name, in: directory).data == data else { throw Self.changed }
        }
    }
    static var changed: CustomizationFailure { CustomizationFailure("The files changed. Read again before applying.") }
    private static func error() -> NSError { NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
}
