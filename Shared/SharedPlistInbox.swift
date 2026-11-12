// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import Darwin

struct SharedPlistError: LocalizedError {
    let key: String
    let retryable: Bool
    init(key: String, retryable: Bool = false) { self.key = key; self.retryable = retryable }
    var errorDescription: String? { NSLocalizedString(key, comment: "") }

    static func canRetry(_ error: Error, depth: Int = 0) -> Bool {
        if error is CancellationError { return true }
        if let error = error as? SharedPlistError { return error.retryable }
        guard depth < 8 else { return false }
        let error = error as NSError
        if error.domain == NSPOSIXErrorDomain,
           [EACCES, EPERM, EBUSY, EAGAIN, EINTR, EMFILE, ENFILE, ETIMEDOUT].contains(where: { Int($0) == error.code }) { return true }
        if error.domain == NSCocoaErrorDomain,
           [CocoaError.fileReadNoPermission.rawValue, CocoaError.fileLocking.rawValue,
            CocoaError.userCancelled.rawValue].contains(error.code) { return true }
        if let underlying = error.userInfo[NSUnderlyingErrorKey] as? Error {
            return canRetry(underlying, depth: depth + 1)
        }
        return false
    }
}

struct SharedPlistEntry: Codable, Identifiable, Sendable {
    let id: UUID
    let name: String
    let created: Date
    let byteCount: Int
}

struct SharedPlistInbox: Sendable {
    enum Kind: Sendable { case mobileGestalt, wallpaper }
    static let maximumByteCount = 16 * 1024 * 1024
    static let maximumWallpaperByteCount = 256 * 1024 * 1024
    private static let maximumMetadataByteCount = 4096
    let directory: URL
    private let container: URL
    private let namespace: String
    let kind: Kind
    private var byteLimit: Int { kind == .wallpaper ? Self.maximumWallpaperByteCount : Self.maximumByteCount }

    init(container: URL, namespace: String, kind: Kind = .mobileGestalt) throws {
        guard !namespace.isEmpty, namespace.utf8.allSatisfy({
            (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || [45, 46, 95].contains($0)
        }), namespace != ".", namespace != ".." else { throw Self.invalidQueue }
        self.container = container
        self.kind = kind
        self.namespace = namespace
        let base = container.appendingPathComponent("GestaltX/ShareInbox", isDirectory: true)
            .appendingPathComponent(namespace, isDirectory: true)
        directory = kind == .wallpaper ? base.appendingPathComponent("Wallpapers", isDirectory: true) : base
    }

    static func isWallpaperName(_ name: String) -> Bool {
        ["tendies", "tendis", "zip"].contains((name as NSString).pathExtension.lowercased())
    }

    private static var invalidQueue: SharedPlistError {
        SharedPlistError(key: "The shared plist could not be read. Share it again.")
    }

    static func validate(_ data: Data) throws {
        guard data.count <= maximumByteCount else { throw SharedPlistError(key: "Choose a plist smaller than 16 MB.") }
        guard let root = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any],
              root["CacheExtra"] is [String: Any] else {
            throw SharedPlistError(key: "Choose a MobileGestalt plist with a CacheExtra dictionary.")
        }
    }

    // Read within the item-provider callback, while its temporary URL is valid.
    static func readDocument(at url: URL, coordinator: NSFileCoordinator = NSFileCoordinator()) throws -> Data {
        guard url.isFileURL else { throw invalidQueue }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        // Coordination itself can wait on a FIFO before invoking the accessor.
        // Reject known special files first, but let File Providers materialize
        // missing placeholders or supply a different URL during coordination.
        var info = stat()
        let status = url.withUnsafeFileSystemRepresentation { path in
            path.map { lstat($0, &info) } ?? -1
        }
        guard status != 0 || (info.st_mode & S_IFMT) == S_IFREG else { throw invalidQueue }
        // A security scope grants access, while coordination asks File Providers
        // to materialize their document and keeps concurrent changes out of the read.
        var coordinationError: NSError?
        var result: Result<Data, Error>?
        coordinator.coordinate(readingItemAt: url, options: [], error: &coordinationError) { readableURL in
            result = Result {
                let data = try readLimited(readableURL, limit: maximumByteCount)
                try validate(data)
                return data
            }
        }
        if let coordinationError { throw coordinationError }
        guard let result else { throw invalidQueue }
        return try result.get()
    }

    static func readDocumentAsync(at url: URL, coordinator: NSFileCoordinator = NSFileCoordinator()) async throws -> Data {
        try Task.checkCancellation()
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        return try await SharedPlistReadJob(coordinator).run { try readDocument(at: url, coordinator: $0) }
    }

    func readAsync(_ entry: SharedPlistEntry) async throws -> Data {
        try await SharedPlistReadJob(NSFileCoordinator()).run { _ in try read(entry) }
    }

    private static func readLimited(_ url: URL, limit: Int) throws -> Data {
        // Open without waiting for a writer and check the opened descriptor, not
        // just the path: a FIFO must not block the app while scanning its inbox.
        let descriptor = url.withUnsafeFileSystemRepresentation { path in
            path.map { open($0, O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC) } ?? -1
        }
        return try readLimited(descriptor: descriptor, limit: limit)
    }

    private static func readLimited(_ name: String, in directory: Int32, limit: Int) throws -> Data {
        try readLimited(descriptor: openat(directory, name, O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC), limit: limit)
    }

    private static func readLimited(descriptor: Int32, limit: Int) throws -> Data {
        guard descriptor >= 0 else { throw fileError() }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }
        var info = stat()
        guard fstat(descriptor, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else { throw invalidQueue }
        var data = Data()
        while true {
            let part = try handle.read(upToCount: min(64 * 1024, limit - data.count + 1)) ?? Data()
            if part.isEmpty { return data }
            guard part.count <= limit - data.count else { throw SharedPlistError(key: "Choose a plist smaller than 16 MB.") }
            data.append(part)
        }
    }

    func enqueue(_ data: Data, name: String) throws -> SharedPlistEntry {
        guard kind == .mobileGestalt else { throw Self.invalidQueue }
        try Self.validate(data)
        guard let parent = try openDirectory(create: true) else { throw Self.invalidQueue }
        defer { close(parent) }
        cleanupStaleEntries()
        let id = UUID()
        let entry = SharedPlistEntry(id: id, name: Self.displayName(name),
                                    created: Date(), byteCount: data.count)
        let metadata = try JSONEncoder().encode(entry)
        guard metadata.count <= Self.maximumMetadataByteCount else { throw Self.invalidQueue }
        let staging = "." + id.uuidString + ".pending"
        do {
            guard mkdirat(parent, staging, 0o700) == 0 else { throw Self.fileError() }
            let stagingDirectory = try Self.openChild(staging, in: parent)
            defer { close(stagingDirectory) }
            let lease = try SharedInboxHousekeeping.writerLock(in: stagingDirectory)
            defer { close(lease) }
            try Self.write(data, named: "document.plist", in: stagingDirectory)
            try Self.write(metadata, named: "entry.json", in: stagingDirectory)
            // Publish only complete pairs. The main app ignores hidden staging folders.
            guard renameat(parent, staging, parent, id.uuidString) == 0 else { throw Self.fileError() }
        } catch {
            try? Self.removeDirectory(staging, in: parent)
            throw error
        }
        return entry
    }

    func entries() throws -> [SharedPlistEntry] {
        guard let parent = try openDirectory(create: false) else { return [] }
        defer { close(parent) }
        cleanupStaleEntries()
        return try Self.names(in: parent).compactMap { name -> SharedPlistEntry? in
                guard let id = UUID(uuidString: name),
                      let child = try? Self.openChild(name, in: parent) else { return nil }
                defer { close(child) }
                guard let bytes = try? Self.readLimited("entry.json", in: child, limit: Self.maximumMetadataByteCount),
                      let entry = try? JSONDecoder().decode(SharedPlistEntry.self, from: bytes), entry.id == id,
                      (0...byteLimit).contains(entry.byteCount) else { return nil }
                return entry
            }.sorted { $0.created == $1.created ? $0.id.uuidString < $1.id.uuidString : $0.created < $1.created }
    }

    func read(_ entry: SharedPlistEntry) throws -> Data {
        guard kind == .mobileGestalt else { throw Self.invalidQueue }
        guard let parent = try openDirectory(create: false) else { throw Self.invalidQueue }
        defer { close(parent) }
        let child = try Self.openChild(entry.id.uuidString, in: parent)
        defer { close(child) }
        // Published inbox files are local copies, not File Provider URLs. Open
        // relative to the pinned directory so replacing a path cannot redirect
        // a read into a different namespace while it is in progress.
        let bytes = try Self.readLimited("document.plist", in: child, limit: Self.maximumByteCount)
        try Self.validate(bytes)
        guard bytes.count == entry.byteCount else { throw Self.invalidQueue }
        return bytes
    }

    // Archive transport is isolated from MobileGestalt and never relaxes its
    // CacheExtra/device checks. Copy inside the provider callback's URL lease.
    func enqueueWallpaper(at source: URL, name: String, coordinator: NSFileCoordinator = NSFileCoordinator(), checkCancellation: () throws -> Void = { try Task.checkCancellation() }) throws -> SharedPlistEntry {
        guard kind == .wallpaper, source.isFileURL else { throw Self.invalidArchive }
        let scoped = source.startAccessingSecurityScopedResource()
        defer { if scoped { source.stopAccessingSecurityScopedResource() } }
        var info = stat()
        if lstat(source.path, &info) == 0, (info.st_mode & S_IFMT) != S_IFREG { throw Self.invalidArchive }
        var coordinationError: NSError?, result: Result<SharedPlistEntry, Error>?
        coordinator.coordinate(readingItemAt: source, options: [], error: &coordinationError) { readable in
            result = Result { try publishWallpaper(readable, name: name, checkCancellation: checkCancellation) }
        }
        if let coordinationError { throw coordinationError }
        guard let result else { throw Self.invalidArchive }
        return try result.get()
    }

    private func publishWallpaper(_ source: URL, name: String, checkCancellation: () throws -> Void) throws -> SharedPlistEntry {
        guard let parent = try openDirectory(create: true) else { throw Self.invalidArchive }
        defer { close(parent) }
        cleanupStaleEntries()
        let id = UUID(), staging = "." + id.uuidString + ".pending"
        guard mkdirat(parent, staging, 0o700) == 0 else { throw Self.fileError() }
        do {
            let child = try Self.openChild(staging, in: parent)
            defer { close(child) }
            let lease = try SharedInboxHousekeeping.writerLock(in: child)
            defer { close(lease) }
            let input = open(source.path, O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
            guard input >= 0 else { throw Self.fileError() }
            defer { close(input) }
            let output = openat(child, "document.archive", O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
            guard output >= 0 else { throw Self.fileError() }
            defer { close(output) }
            let count = try Self.copyArchive(from: input, to: output, checkCancellation: checkCancellation)
            let entry = SharedPlistEntry(id: id, name: Self.displayName(name), created: Date(), byteCount: count)
            let metadata = try JSONEncoder().encode(entry)
            guard metadata.count <= Self.maximumMetadataByteCount else { throw Self.invalidArchive }
            try Self.write(metadata, named: "entry.json", in: child)
            try checkCancellation()
            guard renameat(parent, staging, parent, id.uuidString) == 0 else { throw Self.fileError() }
            return entry
        } catch { try? Self.removeDirectory(staging, in: parent); throw error }
    }

    // Give the app an owned, immutable-by-other-App-Groups copy before showing
    // confirmation. An accepted import consumes these exact bytes.
    func stageWallpaper(_ entry: SharedPlistEntry, at destination: URL) throws {
        guard kind == .wallpaper, destination.isFileURL,
              let parent = try openDirectory(create: false) else { throw Self.invalidArchive }
        defer { close(parent) }
        let child = try Self.openChild(entry.id.uuidString, in: parent)
        defer { close(child) }
        let input = openat(child, "document.archive", O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
        guard input >= 0 else { throw Self.fileError() }
        defer { close(input) }
        let output = open(destination.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard output >= 0 else { throw Self.fileError() }
        defer { close(output) }
        do {
            guard try Self.copyArchive(from: input, to: output) == entry.byteCount else { throw Self.invalidArchive }
        } catch { unlink(destination.path); throw error }
    }

    private static var invalidArchive: SharedPlistError {
        SharedPlistError(key: "The archive is invalid or exceeds the size limit.")
    }

    private static func copyArchive(from input: Int32, to output: Int32, checkCancellation: () throws -> Void = { try Task.checkCancellation() }) throws -> Int {
        var before = stat()
        guard fstat(input, &before) == 0 else { throw fileError() }
        guard (before.st_mode & S_IFMT) == S_IFREG,
              before.st_size >= 4, before.st_size <= maximumWallpaperByteCount else { throw invalidArchive }
        var buffer = [UInt8](repeating: 0, count: 64 * 1024), total = 0
        while true {
            try checkCancellation()
            let count = Darwin.read(input, &buffer, buffer.count)
            if count < 0, errno == EINTR { continue }
            guard count >= 0 else { throw fileError() }
            if count == 0 { break }
            guard count <= maximumWallpaperByteCount - total else { throw invalidArchive }
            if total == 0 {
                guard count >= 4, buffer[0] == 0x50, buffer[1] == 0x4b,
                      (buffer[2] == 3 && buffer[3] == 4) || (buffer[2] == 5 && buffer[3] == 6) else { throw invalidArchive }
            }
            try buffer.withUnsafeBytes { bytes in
                var offset = 0
                while offset < count {
                    let written = Darwin.write(output, bytes.baseAddress!.advanced(by: offset), count - offset)
                    if written < 0, errno == EINTR { continue }
                    guard written > 0 else { throw fileError() }
                    offset += written
                }
            }
            total += count
        }
        var after = stat()
        guard fstat(input, &after) == 0, total == before.st_size, after.st_size == before.st_size,
              before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec,
              before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec else { throw invalidArchive }
        guard fsync(output) == 0 else { throw fileError() }
        return total
    }

    func acknowledge(_ entry: SharedPlistEntry) throws {
        guard let parent = try openDirectory(create: false) else { throw Self.invalidQueue }
        defer { close(parent) }
        try Self.removeDirectory(entry.id.uuidString, in: parent)
    }

    func reject(_ entry: SharedPlistEntry) {
        guard let parent = try? openDirectory(create: false) else { return }
        defer { close(parent) }
        guard let child = try? Self.openChild(entry.id.uuidString, in: parent) else { return }
        defer { close(child) }
        if renameat(parent, entry.id.uuidString, parent, "." + entry.id.uuidString + ".rejected") == 0 {
            _ = futimens(child, nil)
        }
    }

    @discardableResult
    func cleanupStaleEntries(now: Date = Date()) -> Int {
        SharedInboxHousekeeping.clean(container: container, namespace: namespace,
                                     subdirectory: kind == .wallpaper ? "Wallpapers" : nil, now: now)
    }

    private static func fileError() -> NSError { NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }

    private static func openChild(_ name: String, in parent: Int32) throws -> Int32 {
        let descriptor = openat(parent, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw fileError() }
        return descriptor
    }

    private func openDirectory(create: Bool) throws -> Int32? {
        if create { try FileManager.default.createDirectory(at: container, withIntermediateDirectories: true) }
        var descriptor = container.withUnsafeFileSystemRepresentation { path in
            path.map { open($0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC) } ?? -1
        }
        if descriptor < 0 {
            if !create && errno == ENOENT { return nil }
            throw Self.fileError()
        }
        do {
            // Check every component below the trusted App Group container. The
            // descriptor walk also survives concurrent renaming of an ancestor.
            for name in ["GestaltX", "ShareInbox", namespace] + (kind == .wallpaper ? ["Wallpapers"] : []) {
                if create && mkdirat(descriptor, name, 0o700) != 0 && errno != EEXIST { throw Self.fileError() }
                let next: Int32
                do { next = try Self.openChild(name, in: descriptor) }
                catch {
                    if !create && (error as NSError).code == Int(ENOENT) { close(descriptor); return nil }
                    throw error
                }
                close(descriptor)
                descriptor = next
            }
            return descriptor
        } catch { close(descriptor); throw error }
    }

    private static func names(in directory: Int32) throws -> [String] {
        let duplicate = dup(directory)
        guard duplicate >= 0 else { throw fileError() }
        guard let stream = fdopendir(duplicate) else { let error = fileError(); close(duplicate); throw error }
        defer { closedir(stream) }
        rewinddir(stream)
        var result: [String] = []
        errno = 0
        while let entry = readdir(stream) {
            let capacity = MemoryLayout.size(ofValue: entry.pointee.d_name)
            let name = withUnsafePointer(to: &entry.pointee.d_name) { pointer in
                pointer.withMemoryRebound(to: CChar.self, capacity: capacity) {
                    String(cString: $0)
                }
            }
            if name != ".", name != ".." { result.append(name) }
            errno = 0
        }
        guard errno == 0 else { throw fileError() }
        return result
    }

    private static func write(_ data: Data, named name: String, in directory: Int32) throws {
        let descriptor = openat(directory, name, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw fileError() }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }
        try handle.write(contentsOf: data)
    }

    private static func removeDirectory(_ name: String, in parent: Int32, depth: Int = 0) throws {
        guard depth < 64 else { throw invalidQueue }
        let directory = try openChild(name, in: parent)
        defer { close(directory) }
        for child in try names(in: directory) {
            var info = stat()
            guard fstatat(directory, child, &info, AT_SYMLINK_NOFOLLOW) == 0 else { throw fileError() }
            if (info.st_mode & S_IFMT) == S_IFDIR { try removeDirectory(child, in: directory, depth: depth + 1) }
            else if unlinkat(directory, child, 0) != 0 { throw fileError() }
        }
        guard unlinkat(parent, name, AT_REMOVEDIR) == 0 else { throw fileError() }
    }

    private static func displayName(_ name: String) -> String {
        let leaf = (name as NSString).lastPathComponent.filter { !$0.isNewline && !$0.isASCIIControl }
        var result = ""
        var byteCount = 0
        // A Character may contain many UTF-8 bytes, so a character count alone
        // cannot keep entry.json within the reader's limit. Leave room for JSON
        // escaping and the remaining metadata, without splitting a grapheme.
        for character in leaf.prefix(200) {
            let count = String(character).utf8.count
            guard count <= 1024 - byteCount else { break }
            result.append(character)
            byteCount += count
        }
        return result.isEmpty ? "MobileGestalt.plist" : result
    }

    // Temporary access failures do not prove that a published document is bad.
    // Keep those bytes for an explicit retry; malformed contents still leave the
    // automatic queue so they cannot block later documents forever.
    @discardableResult
    func reject(_ entry: SharedPlistEntry, after error: Error) -> Bool {
        guard !SharedPlistError.canRetry(error) else { return false }
        reject(entry)
        return true
    }
}

// Each coordinator is used by one worker. Foundation explicitly permits cancel
// from another thread; no other coordinator operation crosses that boundary.
private final class SharedPlistReadJob: @unchecked Sendable {
    private let coordinator: NSFileCoordinator
    init(_ coordinator: NSFileCoordinator) { self.coordinator = coordinator }

    func run(_ read: @escaping @Sendable (NSFileCoordinator) throws -> Data) async throws -> Data {
        try Task.checkCancellation()
        let worker = Task.detached(priority: .userInitiated) {
            try Task.checkCancellation()
            do {
                let bytes = try read(self.coordinator)
                try Task.checkCancellation()
                return bytes
            } catch {
                try Task.checkCancellation()
                throw error
            }
        }
        return try await withTaskCancellationHandler {
            let bytes = try await worker.value
            try Task.checkCancellation()
            return bytes
        } onCancel: {
            worker.cancel()
            self.coordinator.cancel()
        }
    }
}

private enum SharedInboxHousekeeping {
    private static let lockName = ".writer.lock"

    static func writerLock(in directory: Int32) throws -> Int32 {
        let descriptor = openat(directory, lockName, O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw error() }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else { let failure = error(); close(descriptor); throw failure }
        return descriptor
    }

    static func clean(container: URL, namespace: String, subdirectory: String? = nil, now: Date) -> Int {
        // Housekeeping is best effort. A failed scan must never prevent normal
        // enqueue/read operations, and an active producer is never waited on.
        guard let parent = try? openDirectory(container: container, namespace: namespace, subdirectory: subdirectory) else { return 0 }
        defer { close(parent) }
        guard let names = try? names(in: parent) else { return 0 }
        var removed = 0
        for name in names {
            guard removed < 32, let retention = retention(for: name) else { continue }
            let child = openat(parent, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard child >= 0 else { continue }
            defer { close(child) }
            var info = stat()
            guard fstat(child, &info) == 0,
                  now.timeIntervalSince1970 - Double(info.st_mtimespec.tv_sec) >= retention else { continue }
            let lease = openat(child, lockName, O_RDWR | O_CREAT | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC, 0o600)
            guard lease >= 0 else { continue }
            defer { close(lease) }
            var lockInfo = stat()
            guard fstat(lease, &lockInfo) == 0, (lockInfo.st_mode & S_IFMT) == S_IFREG,
                  flock(lease, LOCK_EX | LOCK_NB) == 0 else { continue }
            var current = stat()
            guard fstatat(parent, name, &current, AT_SYMLINK_NOFOLLOW) == 0,
                  current.st_dev == info.st_dev, current.st_ino == info.st_ino else { continue }
            do { try removeContents(in: child); guard unlinkat(parent, name, AT_REMOVEDIR) == 0 else { continue }; removed += 1 }
            catch { continue }
        }
        return removed
    }

    private static func retention(for name: String) -> TimeInterval? {
        let suffix: String
        let age: TimeInterval
        if name.hasSuffix(".pending") { suffix = ".pending"; age = 24 * 60 * 60 }
        else if name.hasSuffix(".rejected") { suffix = ".rejected"; age = 7 * 24 * 60 * 60 }
        else { return nil }
        guard name.hasPrefix(".") else { return nil }
        let identifier = String(name.dropFirst().dropLast(suffix.count))
        guard let id = UUID(uuidString: identifier), id.uuidString == identifier else { return nil }
        return age
    }

    private static func openDirectory(container: URL, namespace: String, subdirectory: String?) throws -> Int32 {
        var descriptor = container.withUnsafeFileSystemRepresentation { path in
            path.map { open($0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC) } ?? -1
        }
        guard descriptor >= 0 else { throw error() }
        for component in ["GestaltX", "ShareInbox", namespace] + (subdirectory.map { [$0] } ?? []) {
            let next = openat(descriptor, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            let failure = error()
            close(descriptor)
            guard next >= 0 else { throw failure }
            descriptor = next
        }
        return descriptor
    }

    private static func names(in directory: Int32) throws -> [String] {
        let duplicate = dup(directory)
        guard duplicate >= 0 else { throw error() }
        guard let stream = fdopendir(duplicate) else { let failure = error(); close(duplicate); throw failure }
        defer { closedir(stream) }
        rewinddir(stream)
        var result: [String] = []
        errno = 0
        while let entry = readdir(stream) {
            let capacity = MemoryLayout.size(ofValue: entry.pointee.d_name)
            let name = withUnsafePointer(to: &entry.pointee.d_name) { pointer in
                pointer.withMemoryRebound(to: CChar.self, capacity: capacity) { String(cString: $0) }
            }
            if name != ".", name != ".." { result.append(name) }
            errno = 0
        }
        guard errno == 0 else { throw error() }
        return result
    }

    private static func removeContents(in directory: Int32, depth: Int = 0) throws {
        guard depth < 64 else { throw SharedPlistError(key: "The shared plist could not be read. Share it again.") }
        for name in try names(in: directory) {
            var info = stat()
            guard fstatat(directory, name, &info, AT_SYMLINK_NOFOLLOW) == 0 else { throw error() }
            if (info.st_mode & S_IFMT) == S_IFDIR {
                let child = openat(directory, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                guard child >= 0 else { throw error() }
                defer { close(child) }
                try removeContents(in: child, depth: depth + 1)
                guard unlinkat(directory, name, AT_REMOVEDIR) == 0 else { throw error() }
            } else if unlinkat(directory, name, 0) != 0 { throw error() }
        }
    }

    private static func error() -> NSError { NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
}

private extension Character {
    var isASCIIControl: Bool { unicodeScalars.contains { $0.value < 32 || $0.value == 127 } }
}
