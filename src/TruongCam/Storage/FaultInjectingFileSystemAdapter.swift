#if DEBUG || TC_PORTABLE_VERIFIER
import Foundation
import Synchronization

// CONTRACTS.md "P0 creates narrow protocols for a camera fake, file-operation
// adapter/fault injection, and monotonic clock" and TEST_PLAN.md T10–T16.
//
// This adapter is the single fault-injection seam for the save pipeline. It wraps
// any `FileSystemAdapter` and can fail a named phase a configurable number of
// times, simulate a full device, record an ordered event log, and hand a
// deterministic callback to tests that need to mutate the destination between
// pipeline phases (T11/T12). Nothing here is random: a fault fires only when its
// remaining budget is positive.

/// A named save-pipeline phase a fault can be injected into.
enum FileFaultPhase: Hashable, Sendable {
    /// Creating a file or directory. The associated value matches the relative
    /// path (exactly, or as a path suffix such as `source.dng.partial`).
    case create(String)
    case write
    case close
    case move
    case remove
    /// Test seam for a provider that returns success without deleting.
    case removeIgnored

    var label: String {
        switch self {
        case .create(let path): return "create(\(path))"
        case .write: return "write"
        case .close: return "close"
        case .move: return "move"
        case .remove: return "remove"
        case .removeIgnored: return "removeIgnored"
        }
    }
}

/// One observed adapter operation, in order.
struct FileFaultEvent: Hashable, Sendable {
    enum Kind: Hashable, Sendable {
        case createDirectory
        case createFile
        case write
        case close
        case closeAndDelete
        case move
        case copy
        case remove
    }

    let kind: Kind
    let relativePath: String
    let destinationRelativePath: String?
    let byteCount: Int?
    /// True when this operation was replaced by an injected failure.
    let injected: Bool
}

final class FaultInjectingFileSystemAdapter: FileSystemAdapter {
    private struct State {
        var remaining: [FileFaultPhase: Int] = [:]
        var deviceFull = false
        var capacityOverride: Int64?
        var hasCapacityOverride = false
        var events: [FileFaultEvent] = []
        var moveDestinationSuffix: String?
        var observer: (@Sendable (FileFaultEvent) -> Void)?
        var injectedFailureCount = 0
    }

    private let base: FileSystemAdapter
    private let roots = Mutex<[URL]>([])
    private let state = Mutex(State())

    init(
        wrapping base: FileSystemAdapter = SystemFileSystemAdapter(),
        faultRoots: [URL] = [],
        plan: [FileFaultPhase: Int] = [:],
        deviceFull: Bool = false,
        capacityOverride: Int64? = nil
    ) {
        self.base = base
        self.roots.withLock { current in
            current = faultRoots.map(\.standardizedFileURL)
        }
        state.withLock { current in
            current.remaining = plan
            current.deviceFull = deviceFull
            current.capacityOverride = capacityOverride
        }
    }

    // MARK: fault control

    func registerRoot(_ url: URL) {
        roots.withLock { current in
            let standardized = url.standardizedFileURL
            if !current.contains(where: { $0.path == standardized.path }) {
                current.append(standardized)
            }
        }
    }

    func arm(_ phase: FileFaultPhase, times: Int = 1) {
        state.withLock { $0.remaining[phase] = max(0, times) }
    }

    /// Arms `.move` failures for one destination only. Removing/creating files
    /// and journal updates also move files, so a bare `.move` fault would fire on
    /// the first internal journal update instead of the publication move.
    func armMove(destinationSuffix: String, times: Int = 1) {
        state.withLock { current in
            current.remaining[.move] = max(0, times)
            current.moveDestinationSuffix = destinationSuffix
        }
    }

    func clearMoveFilter() {
        state.withLock { $0.moveDestinationSuffix = nil }
    }

    func disarm(_ phase: FileFaultPhase) {
        state.withLock { _ = $0.remaining.removeValue(forKey: phase) }
    }

    func setDeviceFull(_ flag: Bool) {
        state.withLock { $0.deviceFull = flag }
    }

    func setCapacityOverride(_ capacity: Int64?) {
        state.withLock { current in
            current.capacityOverride = capacity
            current.hasCapacityOverride = true
        }
    }

    func setObserver(_ observer: (@Sendable (FileFaultEvent) -> Void)?) {
        state.withLock { $0.observer = observer }
    }

    var remainingFailures: [FileFaultPhase: Int] {
        state.withLock { $0.remaining }
    }

    var injectedFailureCount: Int {
        state.withLock { $0.injectedFailureCount }
    }

    var events: [FileFaultEvent] {
        state.withLock { $0.events }
    }

    func clearEvents() {
        state.withLock { $0.events.removeAll() }
    }

    // MARK: FileSystemAdapter

    func fileExists(at url: URL) -> Bool { base.fileExists(at: url) }

    func isDirectory(at url: URL) throws -> Bool { try base.isDirectory(at: url) }

    func createDirectory(at url: URL, withIntermediateDirectories: Bool) throws {
        let relative = relativePath(of: url)
        if let failure = takeFault(.create(relative), relativePath: relative) {
            note(.createDirectory, relativePath: relative, destination: nil, byteCount: nil, injected: true)
            throw failure
        }
        try base.createDirectory(at: url, withIntermediateDirectories: withIntermediateDirectories)
        note(.createDirectory, relativePath: relative, destination: nil, byteCount: nil, injected: false)
    }

    func removeItem(at url: URL) throws {
        let relative = relativePath(of: url)
        if takeFault(.removeIgnored, relativePath: relative) != nil {
            note(.remove, relativePath: relative, destination: nil, byteCount: nil, injected: true)
            return
        }
        if let failure = takeFault(.remove, relativePath: relative) {
            note(.remove, relativePath: relative, destination: nil, byteCount: nil, injected: true)
            throw failure
        }
        try base.removeItem(at: url)
        note(.remove, relativePath: relative, destination: nil, byteCount: nil, injected: false)
    }

    func attributes(at url: URL) throws -> [FileAttributeKey: Any] { try base.attributes(at: url) }

    /// Composed from the phase-aware primitives so `.create`, `.write` and
    /// `.close` each stay individually injectable.
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
        let relative = relativePath(of: url)
        if let failure = takeFault(.create(relative), relativePath: relative) {
            note(.createFile, relativePath: relative, destination: nil, byteCount: nil, injected: true)
            throw failure
        }
        let handle = try base.beginExclusiveCreate(at: url)
        note(.createFile, relativePath: relative, destination: nil, byteCount: nil, injected: false)
        return FaultInjectingWriteHandle(owner: self, base: handle, relativePath: relative)
    }

    func readAll(at url: URL, maxBytes: Int) throws -> Data {
        try base.readAll(at: url, maxBytes: maxBytes)
    }

    func openRead(at url: URL) throws -> FileReadHandle {
        try base.openRead(at: url)
    }

    func hashFile(at url: URL, chunkBytes: Int) throws -> HashAndByteCount {
        try base.hashFile(at: url, chunkBytes: chunkBytes)
    }

    func scan(
        root: URL,
        maxEntries: Int,
        shouldSkipRelativePath: @Sendable (String) -> Bool,
        shouldDescendRelativeDirectory: @Sendable (String) -> Bool,
        onProgress: (@Sendable (ScanProgress) -> Void)?
    ) throws -> [ScannedEntry] {
        try base.scan(root: root, maxEntries: maxEntries,
                      shouldSkipRelativePath: shouldSkipRelativePath,
                      shouldDescendRelativeDirectory: shouldDescendRelativeDirectory, onProgress: onProgress)
    }

    func moveItem(at source: URL, to destination: URL) throws {
        let relative = relativePath(of: source)
        let destinationRelative = relativePath(of: destination)
        if let failure = takeFault(.move, relativePath: "\(relative) -> \(destinationRelative)") {
            note(.move, relativePath: relative, destination: destinationRelative, byteCount: nil, injected: true)
            throw failure
        }
        try base.moveItem(at: source, to: destination)
        note(.move, relativePath: relative, destination: destinationRelative, byteCount: nil, injected: false)
    }

    func copyItem(at source: URL, to destination: URL) throws {
        let relative = relativePath(of: source)
        let destinationRelative = relativePath(of: destination)
        if let failure = takeFault(.create(destinationRelative), relativePath: destinationRelative) {
            note(.copy, relativePath: relative, destination: destinationRelative, byteCount: nil, injected: true)
            throw failure
        }
        try base.copyItem(at: source, to: destination)
        note(.copy, relativePath: relative, destination: destinationRelative, byteCount: nil, injected: false)
    }

    func availableCapacity(at url: URL) -> Int64? {
        let (isSet, override, isFull) = state.withLock {
            ($0.hasCapacityOverride, $0.capacityOverride, $0.deviceFull)
        }
        if isFull { return 0 }
        if isSet { return override }
        return base.availableCapacity(at: url)
    }

    // MARK: internals used by the write handle

    fileprivate func takeWriteFault(_ phase: FileFaultPhase, relativePath: String) -> FileAdapterError? {
        takeFault(phase, relativePath: relativePath)
    }

    fileprivate func noteWrite(relativePath: String, byteCount: Int, injected: Bool) {
        note(.write, relativePath: relativePath, destination: nil,
             byteCount: byteCount, injected: injected)
    }

    fileprivate func noteClose(relativePath: String, kind: FileFaultEvent.Kind, injected: Bool) {
        note(kind, relativePath: relativePath, destination: nil, byteCount: nil, injected: injected)
    }

    private func takeFault(_ phase: FileFaultPhase, relativePath: String) -> FileAdapterError? {
        state.withLock { current in
            if current.deviceFull {
                current.injectedFailureCount += 1
                return .deviceFull(relativePath)
            }
            // A `.create` fault names a file, not a whole path, so it is matched
            // by suffix ("source.dng" matches
            // "PendingCaptures/<uuid>/source.dng"). Candidate ordering is sorted
            // by label so fault selection is deterministic.
            let candidates = current.remaining.keys
                .sorted { $0.label < $1.label }
                .filter { candidate in
                    guard Self.sameKind(candidate, phase),
                          let remaining = current.remaining[candidate], remaining > 0 else { return false }
                    return Self.faultMatches(candidate,
                                             relativePath: relativePath,
                                             moveDestinationSuffix: current.moveDestinationSuffix)
                }
            guard let key = candidates.first, let remaining = current.remaining[key] else { return nil }
            current.remaining[key] = remaining - 1
            current.injectedFailureCount += 1
            return .ioFailure("Injected \(key.label) failure for \(relativePath)")
        }
    }

    private static func sameKind(_ lhs: FileFaultPhase, _ rhs: FileFaultPhase) -> Bool {
        switch (lhs, rhs) {
        case (.create, .create), (.write, .write), (.close, .close), (.move, .move), (.remove, .remove), (.removeIgnored, .removeIgnored):
            return true
        default:
            return false
        }
    }

    private static func faultMatches(_ phase: FileFaultPhase,
                                     relativePath: String,
                                     moveDestinationSuffix: String?) -> Bool {
        switch phase {
        case .create(let name):
            return relativePath == name || relativePath.hasSuffix("/" + name) || relativePath.hasSuffix(name)
        case .move:
            guard let moveDestinationSuffix else { return true }
            return relativePath.hasSuffix(moveDestinationSuffix)
        case .write, .close, .remove, .removeIgnored:
            return true
        }
    }

    private func note(_ kind: FileFaultEvent.Kind,
                      relativePath: String,
                      destination: String?,
                      byteCount: Int?,
                      injected: Bool) {
        let (observer, event) = state.withLock { current -> ((@Sendable (FileFaultEvent) -> Void)?, FileFaultEvent) in
            let event = FileFaultEvent(kind: kind,
                                       relativePath: relativePath,
                                       destinationRelativePath: destination,
                                       byteCount: byteCount,
                                       injected: injected)
            current.events.append(event)
            return (current.observer, event)
        }
        observer?(event)
    }

    private func relativePath(of url: URL) -> String {
        let path = url.standardizedFileURL.path
        let registered = roots.withLock { $0 }
        for root in registered {
            if path == root.path { return "" }
            if path.hasPrefix(root.path + "/") {
                return String(path.dropFirst(root.path.count + 1))
            }
        }
        return path
    }
}

/// Write handle that injects `.write` and `.close` faults and mirrors the base
/// handle's durability contract: a throwing `close()` means the bytes are not
/// durably staged.
final class FaultInjectingWriteHandle: FileWriteHandle {
    private let owner: FaultInjectingFileSystemAdapter
    private let base: FileWriteHandle
    private let relativePath: String
    private let state = Mutex<Bool>(false)

    init(owner: FaultInjectingFileSystemAdapter, base: FileWriteHandle, relativePath: String) {
        self.owner = owner
        self.base = base
        self.relativePath = relativePath
    }

    var bytesWritten: Int64 { base.bytesWritten }

    func write(_ data: Data) throws {
        if let failure = owner.takeWriteFault(.write, relativePath: relativePath) {
            owner.noteWrite(relativePath: relativePath, byteCount: 0, injected: true)
            throw failure
        }
        try base.write(data)
        owner.noteWrite(relativePath: relativePath, byteCount: data.count, injected: false)
    }

    func close() throws {
        if let failure = owner.takeWriteFault(.close, relativePath: relativePath) {
            owner.noteClose(relativePath: relativePath, kind: .close, injected: true)
            throw failure
        }
        try base.close()
        owner.noteClose(relativePath: relativePath, kind: .close, injected: false)
    }

    func closeAndDelete() throws {
        // Cleanup of this transaction's own partial bytes must not be blocked by
        // an armed `.close`, otherwise injected close faults would be untestable
        // beyond the first attempt.
        if let failure = owner.takeWriteFault(.remove, relativePath: relativePath) {
            owner.noteClose(relativePath: relativePath, kind: .closeAndDelete, injected: true)
            throw failure
        }
        try base.closeAndDelete()
        owner.noteClose(relativePath: relativePath, kind: .closeAndDelete, injected: false)
    }
}

#endif
