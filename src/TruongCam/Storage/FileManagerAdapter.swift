import CryptoKit
import Darwin
import Foundation
import Synchronization

// LIBRARY.md "Staging and save protocol" + CONTRACTS.md "Folder protocol
// hardening" + TEST_PLAN.md T10–T19.
//
// This is the real provider-facing implementation of the frozen
// `FileSystemAdapter` protocol from Core/FileSystemAdapter.swift. Every method
// maps native errors onto `FileAdapterError` so callers can show typed,
// actionable failures instead of guessing.

/// Bounded-transfer constants for the storage stack. These are memory policy,
/// never hardware claims.
enum FileAdapterDefaults {
    /// Default streaming digest chunk: 1 MiB, so a multi-megabyte DNG is never
    /// held as one `Data` for hashing.
    static let hashChunkBytes = 1 << 20
    /// Hard ceiling for a caller-requested chunk so a bad argument cannot turn
    /// the streaming digest back into a whole-file allocation.
    static let maxHashChunkBytes = 4 << 20
}

/// Storage-stack SHA-256 helpers. `SHA256Digest` is the frozen Core identity
/// type for a 64-character lowercase hex digest.
enum StorageCrypto {
    static func sha256Hex(_ data: Data) throws -> SHA256Digest {
        try digestHex(SHA256.hash(data: data).map { $0 })
    }

    static func digestHex(_ bytes: [UInt8]) throws -> SHA256Digest {
        let hex = bytes.map { String(format: "%02x", $0) }.joined()
        guard let digest = SHA256Digest(hex: hex) else {
            throw FileAdapterError.ioFailure("SHA-256 produced a non-canonical digest")
        }
        return digest
    }
}

// MARK: - Real file system adapter

/// FileManager/FileHandle implementation of `FileSystemAdapter`.
///
/// The type holds no mutable state; `FileManager.default` and POSIX calls are
/// thread-safe for the operations used here, and the two handle types own their
/// own locking. That makes the adapter `Sendable` without an `@unchecked`
/// escape hatch.
final class SystemFileSystemAdapter: FileSystemAdapter {
    init() {}

    func fileExists(at url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path)
    }

    func isDirectory(at url: URL) throws -> Bool {
        do {
            let values = try url.resourceValues(forKeys: [.isDirectoryKey])
            return values.isDirectory ?? false
        } catch {
            throw FileAdapterError.classify(error)
        }
    }

    func createDirectory(at url: URL, withIntermediateDirectories: Bool) throws {
        do {
            try FileManager.default.createDirectory(
                at: url, withIntermediateDirectories: withIntermediateDirectories)
        } catch {
            throw FileAdapterError.classify(error)
        }
    }

    func removeItem(at url: URL) throws {
        do {
            try FileManager.default.removeItem(at: url)
        } catch {
            throw FileAdapterError.classify(error)
        }
    }

    func attributes(at url: URL) throws -> [FileAttributeKey: Any] {
        do {
            return try FileManager.default.attributesOfItem(atPath: url.path)
        } catch {
            throw FileAdapterError.classify(error)
        }
    }

    func writeNewFile(at url: URL, bytes: Data) throws {
        let handle = try beginExclusiveCreate(at: url)
        do {
            try handle.write(bytes)
            try handle.close()
        } catch {
            // Preserve the primary failure; a failed cleanup of this
            // transaction's own partial bytes is not more interesting.
            do { try handle.closeAndDelete() } catch { /* already failing */ }
            throw error
        }
    }

    /// Create-not-overwrite. POSIX `O_CREAT | O_EXCL` is the primary path: it
    /// fails with `EEXIST` rather than replacing an existing original.
    func beginExclusiveCreate(at url: URL) throws -> FileWriteHandle {
        let descriptor = url.withUnsafeFileSystemRepresentation { pointer -> Int32 in
            guard let pointer else { return -1 }
            return open(pointer, O_WRONLY | O_CREAT | O_EXCL, 0o644)
        }
        if descriptor >= 0 {
            return SystemFileWriteHandle(url: url, file: FileHandle(fileDescriptor: descriptor, closeOnDealloc: false))
        }

        let failure = errno
        if failure == EEXIST {
            throw FileAdapterError.alreadyExists(url.path)
        }
        // A file-provider-backed path may not implement POSIX create at all.
        // Fall back to the FileManager primitive only after proving the path
        // does not already exist, and never for publication: publishing uses
        // `moveItem`, which the provider performs as create-not-overwrite.
        if failure == ENOTSUP || failure == EOPNOTSUPP || failure == EINVAL || failure == ENOSYS {
            if fileExists(at: url) { throw FileAdapterError.alreadyExists(url.path) }
            guard FileManager.default.createFile(atPath: url.path, contents: nil) else {
                throw FileAdapterError.classify(NSError(domain: NSPOSIXErrorDomain, code: Int(failure)))
            }
            do {
                return SystemFileWriteHandle(url: url, file: try FileHandle(forWritingTo: url))
            } catch {
                throw FileAdapterError.classify(error)
            }
        }
        throw FileAdapterError.classify(NSError(domain: NSPOSIXErrorDomain, code: Int(failure)))
    }

    func readAll(at url: URL, maxBytes: Int) throws -> Data {
        let handle = try openRead(at: url)
        var collected = Data()
        do {
            // Read at most one byte beyond the bound so an over-sized file is
            // rejected instead of being loaded.
            let probeLimit = maxBytes < Int.max ? maxBytes + 1 : maxBytes
            while collected.count < probeLimit {
                let chunk = try handle.read(maxBytes: probeLimit - collected.count)
                if chunk.isEmpty { break }
                collected.append(chunk)
            }
            try handle.close()
        } catch {
            do { try handle.close() } catch { /* already failing */ }
            throw error
        }
        guard collected.count <= maxBytes else {
            throw FileAdapterError.ioFailure(
                "\(url.lastPathComponent) is larger than the \(maxBytes)-byte read bound")
        }
        return collected
    }

    func openRead(at url: URL) throws -> FileReadHandle {
        do {
            let file = try FileHandle(forReadingFrom: url)
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            let size = (attributes[.size] as? NSNumber)?.int64Value ?? 0
            let modification = attributes[.modificationDate] as? Date
            return SystemFileReadHandle(url: url, file: file, byteCount: size, modificationDate: modification)
        } catch {
            throw FileAdapterError.classify(error)
        }
    }

    /// Streaming SHA-256 + byte count over bounded chunks. The whole file is
    /// never materialised: only `chunkBytes` (bounded) is resident at a time.
    func hashFile(at url: URL, chunkBytes: Int) throws -> HashAndByteCount {
        let requested = chunkBytes > 0 ? chunkBytes : FileAdapterDefaults.hashChunkBytes
        let chunkSize = min(requested, FileAdapterDefaults.maxHashChunkBytes)

        let file: FileHandle
        do {
            file = try FileHandle(forReadingFrom: url)
        } catch {
            throw FileAdapterError.classify(error)
        }

        var hasher = SHA256()
        var total: Int64 = 0
        do {
            while true {
                let chunk = try file.read(upToCount: chunkSize) ?? Data()
                if chunk.isEmpty { break }
                hasher.update(data: chunk)
                total += Int64(chunk.count)
            }
            try file.close()
        } catch {
            do { try file.close() } catch { /* already failing */ }
            throw FileAdapterError.classify(error)
        }
        let digest = try StorageCrypto.digestHex(hasher.finalize().map { $0 })
        return HashAndByteCount(digest: digest, byteCount: total)
    }

    /// Bounded breadth-first scan. Symlinks are reported but never followed, the
    /// caller's predicate can exclude subtrees, file contents are never read,
    /// and at most `maxEntries` entries are returned.
    func scan(
        root: URL,
        maxEntries: Int,
        shouldSkipRelativePath: @Sendable (String) -> Bool,
        shouldDescendRelativeDirectory: @Sendable (String) -> Bool,
        onProgress: (@Sendable (ScanProgress) -> Void)?
    ) throws -> [ScannedEntry] {
        let bound = max(0, maxEntries)
        let keys: [URLResourceKey] = [
            .isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey,
        ]
        let rootPath = root.standardizedFileURL.path
        if shouldSkipRelativePath("") {
            onProgress?(ScanProgress(entriesVisited: 0, directoriesVisited: 0,
                                     isComplete: true, currentRelativeDirectory: ""))
            return []
        }

        var queue: [URL] = [root]
        var entries: [ScannedEntry] = []
        var directoriesVisited = 0
        var entriesVisited = 0
        var complete = true

        while !queue.isEmpty {
            if entries.count >= bound {
                complete = false
                break
            }
            let directory = queue.removeFirst()
            directoriesVisited += 1
            let relativeDirectory = Self.relativeDirectory(of: directory, rootPath: rootPath)

            let children: [URL]
            do {
                children = try FileManager.default.contentsOfDirectory(
                    at: directory, includingPropertiesForKeys: keys, options: [])
            } catch {
                // Every queued directory passed the caller's subtree policy.
                // Omitting an unreadable one would turn inaccessible originals
                // into a falsely complete listing and replace the prior index.
                onProgress?(ScanProgress(entriesVisited: entriesVisited,
                                         directoriesVisited: directoriesVisited,
                                         isComplete: false,
                                         currentRelativeDirectory: relativeDirectory))
                throw FileAdapterError.classify(error)
            }

            for child in children.sorted(by: { $0.path < $1.path }) {
                if entries.count >= bound {
                    complete = false
                    break
                }
                entriesVisited += 1
                let relative = Self.relativePath(of: child, rootPath: rootPath)
                let isSkipped = shouldSkipRelativePath(relative)
                let values: URLResourceValues
                do {
                    values = try child.resourceValues(forKeys: Set(keys))
                } catch {
                    throw FileAdapterError.classify(error)
                }
                let isSymlink = values.isSymbolicLink ?? false
                let isDirectory = (values.isDirectory ?? false) && !isSymlink
                if !isSkipped {
                    entries.append(ScannedEntry(
                        relativePath: relative,
                        isDirectory: values.isDirectory ?? false,
                        isSymbolicLink: isSymlink,
                        byteCount: values.fileSize.map { Int64($0) },
                        modificationDate: values.contentModificationDate))
                }
                // A skipped entry may be an already-seen ancestor. Traversal
                // uses the real directory and independent subtree eligibility.
                if isDirectory && shouldDescendRelativeDirectory(relative) {
                    queue.append(child)
                }
            }

            onProgress?(ScanProgress(entriesVisited: entriesVisited,
                                     directoriesVisited: directoriesVisited,
                                     isComplete: queue.isEmpty && complete,
                                     currentRelativeDirectory: relativeDirectory))
        }

        if queue.isEmpty && entries.count < bound { complete = true }
        onProgress?(ScanProgress(entriesVisited: entriesVisited,
                                 directoriesVisited: directoriesVisited,
                                 isComplete: complete,
                                 currentRelativeDirectory: ""))
        return entries
    }

    func moveItem(at source: URL, to destination: URL) throws {
        do {
            try FileManager.default.moveItem(at: source, to: destination)
        } catch {
            throw FileAdapterError.classify(error)
        }
    }

    func copyItem(at source: URL, to destination: URL) throws {
        do {
            try FileManager.default.copyItem(at: source, to: destination)
        } catch {
            throw FileAdapterError.classify(error)
        }
    }

    /// Important-usage capacity first (the value iOS uses for "can I write
    /// this"), then the plain volume capacity. Nil means the provider does not
    /// expose a number, which callers treat as unknown rather than zero.
    func availableCapacity(at url: URL) -> Int64? {
        do {
            let values = try url.resourceValues(forKeys: [
                .volumeAvailableCapacityForImportantUsageKey,
                .volumeAvailableCapacityKey,
            ])
            if let important = values.volumeAvailableCapacityForImportantUsage {
                return important
            }
            if let plain = values.volumeAvailableCapacity {
                return Int64(plain)
            }
            return nil
        } catch {
            return nil
        }
    }

    // MARK: relative-path helpers

    private static func relativePath(of url: URL, rootPath: String) -> String {
        let path = url.standardizedFileURL.path
        guard path.hasPrefix(rootPath + "/") else { return url.lastPathComponent }
        return String(path.dropFirst(rootPath.count + 1))
    }

    private static func relativeDirectory(of url: URL, rootPath: String) -> String {
        let path = url.standardizedFileURL.path
        if path == rootPath { return "" }
        guard path.hasPrefix(rootPath + "/") else { return path }
        return String(path.dropFirst(rootPath.count + 1))
    }
}

/// Streaming exclusive-create handle.
///
/// INVARIANT: the wrapped `FileHandle` is only ever touched while holding the
/// internal `Mutex`, and the handle becomes unusable (`.closed`) after the first
/// `close()`/`closeAndDelete()`. That is what makes the type safely `Sendable`
/// without an `@unchecked` annotation: the lock is the only mutable state and it
/// serialises every access to the non-`Sendable` file object.
final class SystemFileWriteHandle: FileWriteHandle {
    private struct State {
        var file: FileHandle?
        var closed = false
        var bytesWritten: Int64 = 0
    }

    private let url: URL
    private let state: Mutex<State>

    init(url: URL, file: FileHandle) {
        self.url = url
        self.state = Mutex(State(file: file))
    }

    var bytesWritten: Int64 {
        state.withLock { $0.bytesWritten }
    }

    func write(_ data: Data) throws {
        try state.withLock { current in
            guard !current.closed, let file = current.file else {
                throw FileAdapterError.ioFailure(
                    "Write to an already closed handle for \(url.lastPathComponent)")
            }
            do {
                try file.write(contentsOf: data)
            } catch {
                throw FileAdapterError.classify(error)
            }
            current.bytesWritten += Int64(data.count)
        }
    }

    func close() throws {
        let (file, alreadyClosed) = state.withLock { current -> (FileHandle?, Bool) in
            guard !current.closed, let file = current.file else { return (nil, true) }
            current.closed = true
            current.file = nil
            return (file, false)
        }
        if alreadyClosed { return }
        guard let file else { return }
        do {
            // A silent close failure is exactly the crash window in
            // CONTRACTS.md, so both the flush and the close are surfaced.
            try file.synchronize()
            try file.close()
        } catch {
            throw FileAdapterError.classify(error)
        }
    }

    func closeAndDelete() throws {
        let (file, alreadyClosed) = state.withLock { current -> (FileHandle?, Bool) in
            guard !current.closed else { return (nil, true) }
            current.closed = true
            let file = current.file
            current.file = nil
            return (file, false)
        }

        var failure: Error?
        if !alreadyClosed, let file {
            do {
                try file.synchronize()
                try file.close()
            } catch {
                failure = FileAdapterError.classify(error)
            }
        }
        do {
            if FileManager.default.fileExists(atPath: url.path) {
                try FileManager.default.removeItem(at: url)
            }
        } catch {
            if failure == nil { failure = FileAdapterError.classify(error) }
        }
        if let failure { throw failure }
    }
}

/// Read handle. Same locking invariant as the write handle.
final class SystemFileReadHandle: FileReadHandle {
    private struct State {
        var file: FileHandle?
        var closed = false
    }

    private let url: URL
    private let state: Mutex<State>
    let byteCount: Int64
    let modificationDate: Date?

    init(url: URL, file: FileHandle, byteCount: Int64, modificationDate: Date?) {
        self.url = url
        self.state = Mutex(State(file: file))
        self.byteCount = byteCount
        self.modificationDate = modificationDate
    }

    func read(maxBytes: Int) throws -> Data {
        try state.withLock { current in
            guard !current.closed, let file = current.file else {
                throw FileAdapterError.ioFailure(
                    "Read from an already closed handle for \(url.lastPathComponent)")
            }
            guard maxBytes > 0 else { return Data() }
            do {
                return try file.read(upToCount: maxBytes) ?? Data()
            } catch {
                throw FileAdapterError.classify(error)
            }
        }
    }

    func close() throws {
        let (file, alreadyClosed) = state.withLock { current -> (FileHandle?, Bool) in
            guard !current.closed else { return (nil, true) }
            current.closed = true
            let file = current.file
            current.file = nil
            return (file, false)
        }
        if alreadyClosed { return }
        guard let file else { return }
        do {
            try file.close()
        } catch {
            throw FileAdapterError.classify(error)
        }
    }
}
