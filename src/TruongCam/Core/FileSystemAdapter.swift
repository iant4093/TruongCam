import Foundation

// CONTRACTS.md: "P0 creates narrow protocols for a camera fake,
// file-operation adapter/fault injection, and monotonic clock."
//
// The file adapter is the seam where TEST_PLAN.md T10–T19 inject failures. The
// real implementation wraps FileManager/FileHandle; the test implementation
// wraps an in-memory tree and can fail at a named phase.

/// Errors a file adapter can raise. `deviceFull` is separate so callers can show
/// a distinct, actionable storage failure.
enum FileAdapterError: Error, Hashable, Sendable, CustomStringConvertible {
    case notFound(String)
    case alreadyExists(String)
    case deviceFull(String)
    case permissionDenied(String)
    case ioFailure(String)
    case coordinationFailure(String)
    case cancelled(String)

    var description: String {
        switch self {
        case .notFound(let p): return "File not found: \(p)"
        case .alreadyExists(let p): return "File already exists: \(p)"
        case .deviceFull(let p): return "No space left for \(p)"
        case .permissionDenied(let p): return "Permission denied for \(p)"
        case .ioFailure(let d): return "I/O failure: \(d)"
        case .coordinationFailure(let d): return "File coordination failed: \(d)"
        case .cancelled(let d): return "Cancelled: \(d)"
        }
    }

    /// Maps the adapter error onto the normalized product failure vocabulary.
    var failureKind: FailureKind {
        switch self {
        case .notFound(let p): return .providerIOFailed(detail: "Missing file \(p)")
        case .alreadyExists(let p): return .conflict(detail: "Destination already exists: \(p)")
        case .deviceFull(let p): return .localStorageFull(detail: p)
        case .permissionDenied(let p): return .folderUnavailable(detail: "Permission denied for \(p)")
        case .ioFailure(let d): return .providerIOFailed(detail: d)
        case .coordinationFailure(let d): return .providerIOFailed(detail: d)
        case .cancelled(let d): return .cancelled(detail: d)
        }
    }

    static func classify(_ error: Error) -> FileAdapterError {
        let ns = error as NSError
        if ns.domain == NSCocoaErrorDomain {
            switch ns.code {
            case NSFileNoSuchFileError, NSFileReadNoSuchFileError:
                return .notFound(ns.localizedDescription)
            case NSFileWriteFileExistsError:
                return .alreadyExists(ns.localizedDescription)
            case NSFileWriteOutOfSpaceError:
                return .deviceFull(ns.localizedDescription)
            case NSFileWriteNoPermissionError, NSFileReadNoPermissionError:
                return .permissionDenied(ns.localizedDescription)
            default:
                break
            }
        }
        if ns.domain == NSPOSIXErrorDomain {
            switch ns.code {
            case Int(ENOSPC): return .deviceFull(ns.localizedDescription)
            case Int(EACCES), Int(EPERM): return .permissionDenied(ns.localizedDescription)
            case Int(ENOENT): return .notFound(ns.localizedDescription)
            case Int(EEXIST): return .alreadyExists(ns.localizedDescription)
            default: break
            }
        }
        return .ioFailure(ns.localizedDescription)
    }
}

/// A directory entry produced by a bounded scan. `relativePath` is always
/// relative to the scanned root.
struct ScannedEntry: Hashable, Sendable {
    let relativePath: String
    let isDirectory: Bool
    let isSymbolicLink: Bool
    let byteCount: Int64?
    let modificationDate: Date?
}

/// Progress of a bounded scan so the UI can show cancellable work.
struct ScanProgress: Hashable, Sendable {
    let entriesVisited: Int
    let directoriesVisited: Int
    let isComplete: Bool
    let currentRelativeDirectory: String
}

/// Narrow file-operation boundary. All provider access goes through this so the
/// security-scope lease, coordination and fault injection have one owner.
protocol FileSystemAdapter: Sendable {
    func fileExists(at url: URL) -> Bool
    func isDirectory(at url: URL) throws -> Bool
    func createDirectory(at url: URL, withIntermediateDirectories: Bool) throws
    func removeItem(at url: URL) throws
    func attributes(at url: URL) throws -> [FileAttributeKey: Any]

    /// Exact-byte write with an explicit create-not-overwrite contract. The
    /// adapter must fail with `.alreadyExists` rather than replacing a file.
    func writeNewFile(at url: URL, bytes: Data) throws

    /// Streaming write used for large sources: the caller writes chunks and owns
    /// closing. Implementations must never buffer the whole file.
    func beginExclusiveCreate(at url: URL) throws -> FileWriteHandle

    func readAll(at url: URL, maxBytes: Int) throws -> Data
    func openRead(at url: URL) throws -> FileReadHandle

    /// Streaming SHA-256 + byte count over bounded chunks.
    func hashFile(at url: URL, chunkBytes: Int) throws -> HashAndByteCount

    /// Bounded breadth-first scan. `maxEntries` bounds the batch;
    /// Entry exclusion and directory traversal are separate: seen ancestors may
    /// still contain new entries, and traversal must never use synthetic paths.
    func scan(
        root: URL,
        maxEntries: Int,
        shouldSkipRelativePath: @Sendable (String) -> Bool,
        shouldDescendRelativeDirectory: @Sendable (String) -> Bool,
        onProgress: (@Sendable (ScanProgress) -> Void)?
    ) throws -> [ScannedEntry]

    /// Moves/renames within the same provider. Callers must have already proven
    /// the destination does not exist.
    func moveItem(at source: URL, to destination: URL) throws
    func copyItem(at source: URL, to destination: URL) throws

    /// Available capacity for the volume backing `url`, when the provider
    /// exposes it. Nil means "not exposed"; callers treat it as unknown.
    func availableCapacity(at url: URL) -> Int64?
}

/// Handle for a streaming exclusive create. Closing is mandatory and reports
/// errors, because a silent close failure is exactly the crash window described
/// in CONTRACTS.md.
protocol FileWriteHandle: AnyObject, Sendable {
    var bytesWritten: Int64 { get }
    func write(_ data: Data) throws
    /// Flushes to the provider and closes. Throws on failure; the caller must
    /// treat a throwing close as "not durably staged".
    func close() throws
    /// Closes and deletes the partial file. Used only for a transaction's own
    /// partial bytes.
    func closeAndDelete() throws
}

protocol FileReadHandle: AnyObject, Sendable {
    var byteCount: Int64 { get }
    func read(maxBytes: Int) throws -> Data
    func close() throws
}

/// Boundary for a security-scoped root grant. Balanced lease acquisition is the
/// caller's responsibility; this type only reports whether the system granted
/// access and provides the URL.
protocol SecurityScopedRootGrant: Sendable {
    /// Stable identity of this grant, so a reader's lease is balanced against the
    /// exact grant it opened rather than whichever grant is current later
    /// (REVIEW.md S09).
    var leaseIdentity: UUID { get }
    var url: URL { get }
    var isStale: Bool { get }
    /// Number of currently balanced access leases. A caller uses this to decide
    /// whether it is the one that must close the lease it opens.
    var activeLeaseCount: Int { get }
    /// Returns true when the system actually started access.
    func beginAccess() -> Bool
    func endAccess()
}

/// Coordinates a file operation through `NSFileCoordinator`. Splitting this out
/// lets tests observe that no asynchronous work escapes the accessor.
protocol CoordinatedFileMutator: Sendable {
    /// Runs `body` inside a coordinated write at `url`.
    func coordinatedWrite<T>(at url: URL, _ body: (URL) throws -> T) throws -> T
    /// Runs `body` inside a coordinated read at `url`.
    func coordinatedRead<T>(at url: URL, _ body: (URL) throws -> T) throws -> T
}
