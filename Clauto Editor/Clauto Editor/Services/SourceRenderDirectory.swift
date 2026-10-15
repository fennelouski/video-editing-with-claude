import Foundation
import Darwin

/// Immutable directory descriptors anchor all writes. A renamed/disconnected path
/// cannot redirect a write or cleanup into a replacement directory. No recursive
/// pathname cleanup is performed; failed evidence remains in its owned staging dir.
final class SourceRenderDirectory: Sendable {
    let descriptor: Int32
    let url: URL
    let identity: RenderDirectoryIdentity
    private init(descriptor: Int32, url: URL) throws {
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFDIR else { Darwin.close(descriptor); throw ProjectFailure.invalidProject }
        self.descriptor = descriptor; self.url = url
        identity = .init(device: info.st_dev, inode: info.st_ino)
    }
    deinit { Darwin.close(descriptor) }
    static func open(_ url: URL) throws -> SourceRenderDirectory {
        guard url.isFileURL else { throw ProjectFailure.invalidProject }
        let canonical = url.resolvingSymlinksInPath().standardizedFileURL
        let fd = Darwin.open(canonical.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard fd >= 0 else { throw WorkflowFailure.invalid("The render workspace is unavailable. Reconnect its drive before retrying.") }
        return try .init(descriptor: fd, url: canonical)
    }
    func child(_ name: String, create: Bool = false, exclusive: Bool = false) throws -> SourceRenderDirectory {
        try leaf(name)
        if create, mkdirat(descriptor, name, S_IRWXU) != 0, errno != EEXIST || exclusive { throw ioFailure() }
        let fd = openat(descriptor, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard fd >= 0 else { throw ioFailure() }
        return try .init(descriptor: fd, url: url.appendingPathComponent(name))
    }
    func checkPath() throws {
        let current = try Self.open(url)
        guard current.identity == identity else { throw WorkflowFailure.invalid("The render workspace changed or disconnected. Its previous current preview is preserved.") }
    }
    func writeNew(_ data: Data, name: String) throws {
        try leaf(name)
        let fd = openat(descriptor, name, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, S_IRUSR | S_IWUSR)
        guard fd >= 0 else { throw ioFailure() }
        defer { Darwin.close(fd) }
        try data.withUnsafeBytes { buffer in
            var written = 0
            while written < buffer.count {
                let count = Darwin.write(fd, buffer.baseAddress!.advanced(by: written), buffer.count-written)
                guard count > 0 else { throw ioFailure() }; written += count
            }
        }
        guard fsync(fd) == 0 else { throw ioFailure() }
    }
    func read(_ name: String, limit: Int = 64 * 1024 * 1024) throws -> Data {
        try leaf(name)
        let fd = openat(descriptor, name, O_RDONLY | O_NOFOLLOW)
        guard fd >= 0 else { throw ioFailure() }; defer { Darwin.close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_size <= limit else { throw ProjectFailure.invalidProject }
        let before = [Int64(info.st_dev), Int64(info.st_ino), info.st_size, Int64(info.st_mtimespec.tv_sec), Int64(info.st_mtimespec.tv_nsec), Int64(info.st_ctimespec.tv_sec), Int64(info.st_ctimespec.tv_nsec)]
        var bytes = Data(), buffer = [UInt8](repeating: 0, count: 1024 * 1024)
        while true {
            try Task.checkCancellation()
            let count = Darwin.read(fd, &buffer, buffer.count)
            guard count >= 0 else { throw ioFailure() }; if count == 0 { break }
            guard bytes.count + count <= limit else { throw ProjectFailure.invalidProject }
            bytes.append(contentsOf: buffer.prefix(count))
        }
        guard fstat(fd, &info) == 0 else { throw ioFailure() }
        let after = [Int64(info.st_dev), Int64(info.st_ino), info.st_size, Int64(info.st_mtimespec.tv_sec), Int64(info.st_mtimespec.tv_nsec), Int64(info.st_ctimespec.tv_sec), Int64(info.st_ctimespec.tv_nsec)]
        let pathFD = openat(descriptor, name, O_RDONLY | O_NOFOLLOW)
        guard pathFD >= 0 else { throw ioFailure() }; defer { Darwin.close(pathFD) }
        var pathInfo = stat()
        guard before == after, fstat(pathFD, &pathInfo) == 0, pathInfo.st_dev == info.st_dev, pathInfo.st_ino == info.st_ino else {
            throw WorkflowFailure.invalid("An owned render artifact changed while being checked.")
        }
        return bytes
    }
    func materializeBundle(_ name: String, to destination: String, expected: RenderDirectoryIdentity) throws -> (SourceRenderDirectory, String) {
        try leaf(name); try leaf(destination)
        let source = try child(name)
        guard source.identity == expected else { throw WorkflowFailure.invalid("The owned staging directory changed before publication.") }
        if renameatx_np(descriptor, name, descriptor, destination, UInt32(RENAME_EXCL)) == 0 {
            guard fsync(descriptor) == 0 else { throw ioFailure(operation: "bundle directory fsync") }
            let final = try child(destination)
            guard final.identity == expected else { throw ProjectFailure.invalidProject }
            return (final, "exclusive_rename")
        }
        // The Videos SMB volume returns ENOTSUP for RENAME_EXCL. Reserve a new
        // UUID directory atomically, then use only exclusive descriptor-relative
        // copies. An incomplete directory is not publication: current changes last.
        guard errno == ENOTSUP else { throw ioFailure(operation: "exclusive bundle rename") }
        try source.checkPath()
        let final = try child(destination, create: true, exclusive: true)
        for filename in ["input.json", "source-map.json", "render-proof.json", "review.mov", "timeline.fcpxml"] {
            try Task.checkCancellation()
            try final.writeNew(source.read(filename), name: filename)
        }
        guard fsync(final.descriptor) == 0 else { throw ioFailure(operation: "copied bundle directory fsync") }
        return (final, "exclusive_directory_copy")
    }
    func replacePointer(_ data: Data, name: String) throws {
        try leaf(name)
        let temporary = ".source-span-pointer-" + UUID().uuidString
        try writeNew(data, name: temporary)
        try Task.checkCancellation()
        guard renameat(descriptor, temporary, descriptor, name) == 0 else { throw ioFailure() }
        // Atomic rename is the publication point. Directory fsync is best effort
        // afterward; do not report an unpublished failure after replacing current.
        _ = fsync(descriptor)
    }
    private func leaf(_ name: String) throws {
        guard !name.isEmpty, name != ".", name != "..", !name.contains("/"), !name.utf8.contains(0) else { throw ProjectFailure.invalidProject }
    }
    private func ioFailure(operation: String = "owned file I/O") -> WorkflowFailure {
        let code = errno
        return .invalid("The owned render workspace failed during \(operation) (POSIX \(code): \(String(cString: strerror(code)))). Its previous current preview is preserved; incomplete evidence is retained.")
    }
}
