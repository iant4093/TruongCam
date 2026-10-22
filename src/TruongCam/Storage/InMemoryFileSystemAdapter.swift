#if DEBUG || TC_PORTABLE_VERIFIER
import CryptoKit
import Foundation
import Synchronization

// CONTRACTS.md "P0 creates narrow protocols for a camera fake, file-operation
// adapter/fault injection, and monotonic clock." + TEST_PLAN.md T10–T24.
//
// Complete in-memory implementation of the frozen `FileSystemAdapter` protocol.
// It has the same observable semantics as the real adapter — create is
// create-not-overwrite, hashing streams in bounded chunks, scans are bounded and
// never follow symlinks, capacity can be unknown — so the transaction state
// machine can be exercised without touching a provider.
//
// Xcode synchronizes this folder into the app target. Compile this fixture
// only for Debug tests/previews and the standalone verifier, never shipping Release.

/// Per-path access bookkeeping, used by tests to prove what the storage stack
/// did (and did not) read, create, hash or move.
struct InMemoryAccessCounters: Hashable, Sendable {
    var creates = 0
    var reads = 0
    var hashes = 0
    var removes = 0
    var moves = 0

    static func + (lhs: Self, rhs: Self) -> Self {
        var out = lhs
        out.creates += rhs.creates
        out.reads += rhs.reads
        out.hashes += rhs.hashes
        out.removes += rhs.removes
        out.moves += rhs.moves
        return out
    }
}

final class InMemoryFileSystemAdapter: FileSystemAdapter {
    private struct Node {
        var isDirectory: Bool
        var bytes: Data
        var symlinkTarget: String?
        var modificationDate: Date
    }

    private struct State {
        var nodes: [String: Node] = [:]
        var capacity: Int64? = 8 * 1024 * 1024 * 1024
        var inaccessible: Set<String> = []
        var counters: [String: InMemoryAccessCounters] = [:]
        var capacityProbes = 0
        var scanInvocations = 0
    }

    private let state = Mutex(State())

    init() {}

    // MARK: FileSystemAdapter

    func fileExists(at url: URL) -> Bool {
        state.withLock { $0.nodes[Self.key(url)] != nil }
    }

    func isDirectory(at url: URL) throws -> Bool {
        try state.withLock { current in
            guard let node = current.nodes[Self.key(url)] else {
                throw FileAdapterError.notFound(url.path)
            }
            return node.isDirectory
        }
    }

    func createDirectory(at url: URL, withIntermediateDirectories: Bool) throws {
        try state.withLock { current in
            let path = Self.key(url)
            try Self.requireReadable(path, in: current)
            if let existing = current.nodes[path] {
                if existing.isDirectory && existing.symlinkTarget == nil { return }
                throw FileAdapterError.alreadyExists(path)
            }
            var parents: [String] = []
            var cursor = Self.parentPath(of: path)
            while !cursor.isEmpty && cursor != "/" && current.nodes[cursor] == nil {
                parents.append(cursor)
                cursor = Self.parentPath(of: cursor)
            }
            if !withIntermediateDirectories {
                guard current.nodes[Self.parentPath(of: path)] != nil || Self.parentPath(of: path) == "/" else {
                    throw FileAdapterError.notFound(Self.parentPath(of: path))
                }
            }
            for parent in parents.reversed() {
                current.nodes[parent] = Node(isDirectory: true, bytes: Data(),
                                             symlinkTarget: nil, modificationDate: Date())
            }
            current.nodes[path] = Node(isDirectory: true, bytes: Data(),
                                       symlinkTarget: nil, modificationDate: Date())
        }
    }

    func removeItem(at url: URL) throws {
        try state.withLock { current in
            let path = Self.key(url)
            try Self.requireReadable(path, in: current)
            guard current.nodes[path] != nil else { throw FileAdapterError.notFound(path) }
            current.nodes.removeValue(forKey: path)
            let prefix = path + "/"
            let descendants = current.nodes.keys.filter { $0.hasPrefix(prefix) }
            for key in descendants {
                current.nodes.removeValue(forKey: key)
                current.inaccessible.remove(key)
            }
            current.inaccessible.remove(path)
            current.counters[path, default: InMemoryAccessCounters()].removes += 1
        }
    }

    func attributes(at url: URL) throws -> [FileAttributeKey: Any] {
        try state.withLock { current in
            let path = Self.key(url)
            try Self.requireReadable(path, in: current)
            guard let node = current.nodes[path] else { throw FileAdapterError.notFound(path) }
            return [
                .size: NSNumber(value: node.isDirectory ? 0 : node.bytes.count),
                .modificationDate: node.modificationDate,
                .type: node.isDirectory ? FileAttributeType.typeDirectory : FileAttributeType.typeRegular,
            ]
        }
    }

    func writeNewFile(at url: URL, bytes: Data) throws {
        let handle = try beginExclusiveCreate(at: url)
        do {
            try handle.write(bytes)
            try handle.close()
        } catch {
            do { try handle.closeAndDelete() } catch { /* already failing */ }
            throw error
        }
    }

    func beginExclusiveCreate(at url: URL) throws -> FileWriteHandle {
        try state.withLock { current in
            let path = Self.key(url)
            try Self.requireReadable(path, in: current)
            guard current.nodes[Self.parentPath(of: path)] != nil || Self.parentPath(of: path) == "/" else {
                throw FileAdapterError.notFound(Self.parentPath(of: path))
            }
            if current.nodes[path] != nil { throw FileAdapterError.alreadyExists(path) }
            current.nodes[path] = Node(isDirectory: false, bytes: Data(),
                                       symlinkTarget: nil, modificationDate: Date())
            current.counters[path, default: InMemoryAccessCounters()].creates += 1
            return InMemoryFileWriteHandle(adapter: self, path: path)
        }
    }

    func readAll(at url: URL, maxBytes: Int) throws -> Data {
        try state.withLock { current in
            let path = Self.key(url)
            try Self.requireReadable(path, in: current)
            guard let node = current.nodes[path], !node.isDirectory else {
                throw FileAdapterError.notFound(path)
            }
            current.counters[path, default: InMemoryAccessCounters()].reads += 1
            guard node.bytes.count <= maxBytes else {
                throw FileAdapterError.ioFailure("\(path) is larger than the \(maxBytes)-byte read bound")
            }
            return node.bytes
        }
    }

    func openRead(at url: URL) throws -> FileReadHandle {
        try state.withLock { current in
            let path = Self.key(url)
            try Self.requireReadable(path, in: current)
            guard let node = current.nodes[path], !node.isDirectory else {
                throw FileAdapterError.notFound(path)
            }
            current.counters[path, default: InMemoryAccessCounters()].reads += 1
            return InMemoryFileReadHandle(bytes: node.bytes,
                                          byteCount: Int64(node.bytes.count),
                                          modificationDate: node.modificationDate)
        }
    }

    func hashFile(at url: URL, chunkBytes: Int) throws -> HashAndByteCount {
        let requested = chunkBytes > 0 ? chunkBytes : FileAdapterDefaults.hashChunkBytes
        let chunkSize = min(requested, FileAdapterDefaults.maxHashChunkBytes)
        let data: Data = try state.withLock { current in
            let path = Self.key(url)
            try Self.requireReadable(path, in: current)
            guard let node = current.nodes[path], !node.isDirectory else {
                throw FileAdapterError.notFound(path)
            }
            current.counters[path, default: InMemoryAccessCounters()].hashes += 1
            return node.bytes
        }
        var hasher = SHA256Context()
        var offset = 0
        while offset < data.count {
            let end = min(offset + chunkSize, data.count)
            hasher.update(data.subdata(in: offset..<end))
            offset = end
        }
        let digest = try StorageCrypto.digestHex(hasher.finalize())
        return HashAndByteCount(digest: digest, byteCount: Int64(data.count))
    }

    func scan(
        root: URL,
        maxEntries: Int,
        shouldSkipRelativePath: @Sendable (String) -> Bool,
        shouldDescendRelativeDirectory: @Sendable (String) -> Bool,
        onProgress: (@Sendable (ScanProgress) -> Void)?
    ) throws -> [ScannedEntry] {
        struct Snapshot {
            let entries: [ScannedEntry]
            let complete: Bool
            let directories: Int
        }

        let rootPath = Self.key(root)
        let bound = max(0, maxEntries)
        let snapshot: Snapshot = try state.withLock { current in
            current.scanInvocations += 1
            guard current.nodes[rootPath] != nil else { throw FileAdapterError.notFound(rootPath) }
            if shouldSkipRelativePath("") {
                return Snapshot(entries: [], complete: true, directories: 0)
            }
            var queue: [String] = [rootPath]
            var entries: [ScannedEntry] = []
            var directoriesVisited = 0
            var complete = true
            while !queue.isEmpty {
                if entries.count >= bound { complete = false; break }
                let directory = queue.removeFirst()
                directoriesVisited += 1
                let childPaths = current.nodes.keys
                    .filter { Self.parentPath(of: $0) == directory && $0 != directory }
                    .sorted()
                for childPath in childPaths {
                    if entries.count >= bound { complete = false; break }
                    guard let node = current.nodes[childPath] else { continue }
                    let relative = Self.relativePath(childPath, rootPath: rootPath)
                    let isSkipped = shouldSkipRelativePath(relative)
                    let isSymlink = node.symlinkTarget != nil
                    if isSkipped {
                        if node.isDirectory && !isSymlink && shouldDescendRelativeDirectory(relative) {
                            queue.append(childPath)
                        }
                        continue
                    }
                    entries.append(ScannedEntry(
                        relativePath: relative,
                        isDirectory: node.isDirectory,
                        isSymbolicLink: isSymlink,
                        byteCount: node.isDirectory ? nil : Int64(node.bytes.count),
                        modificationDate: node.modificationDate))
                    if node.isDirectory && !isSymlink && shouldDescendRelativeDirectory(relative) { queue.append(childPath) }
                }
            }
            if queue.isEmpty && entries.count < bound { complete = true }
            return Snapshot(entries: entries, complete: complete, directories: directoriesVisited)
        }

        onProgress?(ScanProgress(entriesVisited: snapshot.entries.count,
                                 directoriesVisited: snapshot.directories,
                                 isComplete: snapshot.complete,
                                 currentRelativeDirectory: ""))
        return snapshot.entries
    }

    func moveItem(at source: URL, to destination: URL) throws {
        try transfer(from: source, to: destination, copying: false)
    }

    func copyItem(at source: URL, to destination: URL) throws {
        try transfer(from: source, to: destination, copying: true)
    }

    func availableCapacity(at url: URL) -> Int64? {
        state.withLock { current in
            current.capacityProbes += 1
            return current.capacity
        }
    }

    // MARK: test inspection and manipulation

    /// Every path currently in the tree, sorted. Used to prove that no
    /// duplicate source was created.
    func allPaths() -> [String] {
        state.withLock { $0.nodes.keys.sorted() }
    }

    func fileBytes(at url: URL) -> Data? {
        state.withLock { $0.nodes[Self.key(url)]?.bytes }
    }

    /// Writes bytes directly, bypassing the create-not-overwrite contract. Only
    /// used to stage a pre-existing destination or to simulate out-of-band
    /// mutation (TEST_PLAN.md T11/T12/T17).
    func setBytes(_ data: Data, at url: URL) {
        state.withLock { current in
            let path = Self.key(url)
            var cursor = Self.parentPath(of: path)
            var missing: [String] = []
            while !cursor.isEmpty && cursor != "/" && current.nodes[cursor] == nil {
                missing.append(cursor)
                cursor = Self.parentPath(of: cursor)
            }
            for parent in missing.reversed() {
                current.nodes[parent] = Node(isDirectory: true, bytes: Data(),
                                             symlinkTarget: nil, modificationDate: Date())
            }
            current.nodes[path] = Node(isDirectory: false, bytes: data,
                                       symlinkTarget: nil, modificationDate: Date())
        }
    }

    func markInaccessible(_ url: URL) {
        state.withLock { _ = $0.inaccessible.insert(Self.key(url)) }
    }

    func clearInaccessible(_ url: URL) {
        state.withLock { _ = $0.inaccessible.remove(Self.key(url)) }
    }

    func addSymlink(at url: URL, toRelativePath target: String) {
        state.withLock { current in
            let path = Self.key(url)
            current.nodes[path] = Node(isDirectory: false, bytes: Data(),
                                       symlinkTarget: target, modificationDate: Date())
        }
    }

    func counters(at url: URL) -> InMemoryAccessCounters {
        state.withLock { $0.counters[Self.key(url)] ?? InMemoryAccessCounters() }
    }

    func totalCounters() -> InMemoryAccessCounters {
        state.withLock { current in
            current.counters.values.reduce(InMemoryAccessCounters(), +)
        }
    }

    func resetCounters() {
        state.withLock { current in
            current.counters.removeAll()
            current.scanInvocations = 0
            current.capacityProbes = 0
        }
    }

    var scanInvocations: Int {
        state.withLock { $0.scanInvocations }
    }

    var capacityProbes: Int {
        state.withLock { $0.capacityProbes }
    }

    func setCapacity(_ capacity: Int64?) {
        state.withLock { $0.capacity = capacity }
    }

    // MARK: internals

    private func transfer(from source: URL, to destination: URL, copying: Bool) throws {
        try state.withLock { current in
            let sourcePath = Self.key(source)
            let destinationPath = Self.key(destination)
            try Self.requireReadable(sourcePath, in: current)
            guard current.nodes[sourcePath] != nil else {
                throw FileAdapterError.notFound(sourcePath)
            }
            guard current.nodes[destinationPath] == nil else {
                throw FileAdapterError.alreadyExists(destinationPath)
            }
            let parent = Self.parentPath(of: destinationPath)
            guard current.nodes[parent] != nil || parent == "/" else {
                throw FileAdapterError.notFound(parent)
            }

            var moved: [String: Node] = [:]
            for (key, node) in current.nodes {
                if key == sourcePath {
                    moved[destinationPath] = node
                } else if key.hasPrefix(sourcePath + "/") {
                    let suffix = String(key.dropFirst(sourcePath.count))
                    moved[destinationPath + suffix] = node
                }
            }
            guard !moved.isEmpty else { throw FileAdapterError.notFound(sourcePath) }
            if !copying {
                for key in moved.keys { current.nodes.removeValue(forKey: key) }
                current.nodes.removeValue(forKey: sourcePath)
            }
            for (key, var node) in moved {
                node.modificationDate = Date()
                current.nodes[key] = node
            }
            current.counters[destinationPath, default: InMemoryAccessCounters()].moves += 1
        }
    }

    /// Called by the write handle on a successful close.
    fileprivate func commitOpenWrite(path: String, bytes: Data) throws {
        try state.withLock { current in
            guard var node = current.nodes[path] else { throw FileAdapterError.notFound(path) }
            node.bytes = bytes
            node.modificationDate = Date()
            current.nodes[path] = node
        }
    }

    /// Called by the write handle on `closeAndDelete`.
    fileprivate func abortOpenWrite(path: String) {
        state.withLock { current in
            _ = current.nodes.removeValue(forKey: path)
        }
    }

    private static func requireReadable(_ path: String, in state: State) throws {
        if state.inaccessible.contains(path) {
            throw FileAdapterError.permissionDenied(path)
        }
        // A parent directory that was marked inaccessible also blocks children.
        var cursor = parentPath(of: path)
        while !cursor.isEmpty && cursor != "/" {
            if state.inaccessible.contains(cursor) {
                throw FileAdapterError.permissionDenied(path)
            }
            cursor = parentPath(of: cursor)
        }
    }

    fileprivate static func key(_ url: URL) -> String {
        url.standardizedFileURL.path
    }

    fileprivate static func parentPath(of path: String) -> String {
        let parent = (path as NSString).deletingLastPathComponent
        return parent.isEmpty ? "/" : parent
    }

    fileprivate static func relativePath(_ path: String, rootPath: String) -> String {
        guard path.hasPrefix(rootPath + "/") else { return (path as NSString).lastPathComponent }
        return String(path.dropFirst(rootPath.count + 1))
    }
}

/// Minimal incrementally-fed SHA-256 so the in-memory adapter streams in
/// bounded chunks exactly like the real adapter instead of hashing one blob.
struct SHA256Context {
    private var hasher = SHA256()
    mutating func update(_ data: Data) { hasher.update(data: data) }
    mutating func finalize() -> [UInt8] { hasher.finalize().map { $0 } }
}

/// Write handle for the in-memory tree. Bytes become visible only on `close()`,
/// which is what makes "a throwing close means not durably staged" testable.
final class InMemoryFileWriteHandle: FileWriteHandle {
    private struct HandleState {
        var bytes = Data()
        var closed = false
    }

    private let adapter: InMemoryFileSystemAdapter
    private let path: String
    private let state = Mutex(HandleState())

    init(adapter: InMemoryFileSystemAdapter, path: String) {
        self.adapter = adapter
        self.path = path
    }

    var bytesWritten: Int64 {
        state.withLock { Int64($0.bytes.count) }
    }

    func write(_ data: Data) throws {
        try state.withLock { current in
            guard !current.closed else {
                throw FileAdapterError.ioFailure("Write to an already closed handle for \(path)")
            }
            current.bytes.append(data)
        }
    }

    func close() throws {
        let payload: Data? = state.withLock { current in
            guard !current.closed else { return nil }
            current.closed = true
            return current.bytes
        }
        guard let payload else { return }
        try adapter.commitOpenWrite(path: path, bytes: payload)
    }

    func closeAndDelete() throws {
        let shouldAbort = state.withLock { current -> Bool in
            guard !current.closed else { return false }
            current.closed = true
            return true
        }
        if shouldAbort { adapter.abortOpenWrite(path: path) }
    }
}

final class InMemoryFileReadHandle: FileReadHandle {
    private struct HandleState {
        var offset = 0
        var closed = false
    }

    private let bytes: Data
    private let state = Mutex(HandleState())
    let byteCount: Int64
    let modificationDate: Date?

    init(bytes: Data, byteCount: Int64, modificationDate: Date?) {
        self.bytes = bytes
        self.byteCount = byteCount
        self.modificationDate = modificationDate
    }

    func read(maxBytes: Int) throws -> Data {
        try state.withLock { current in
            guard !current.closed else { throw FileAdapterError.ioFailure("Read from a closed handle") }
            guard maxBytes > 0 else { return Data() }
            guard current.offset < bytes.count else { return Data() }
            let end = min(current.offset + maxBytes, bytes.count)
            let chunk = bytes.subdata(in: current.offset..<end)
            current.offset = end
            return chunk
        }
    }

    func close() throws {
        state.withLock { $0.closed = true }
    }
}

#endif
