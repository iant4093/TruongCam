import Foundation

// CONTRACTS.md "Concrete capability and error snapshots": typed failures carry
// operation + request/root/generation identity, retryability, retained-source
// status and underlying NSError domain/code for diagnostics. Suppressing errors
// with `try?` can never manufacture success.

/// Normalized failure kinds. Provider-specific quota codes are never invented;
/// unknown native errors become `.providerIOFailed` with the raw domain/code
/// preserved for diagnostics.
enum FailureKind: Hashable, Sendable {
    case permissionDenied(domain: String)
    case noCamera
    case unsupportedCapability(detail: String)
    case invalidSettings(detail: String)
    case cameraInterrupted(detail: String)
    case captureFailed(detail: String)
    case representationUnavailable(detail: String)
    case localStorageFull(detail: String)
    case folderUnavailable(detail: String)
    case providerIOFailed(detail: String)
    case integrityMismatch(detail: String)
    case conflict(detail: String)
    case metadataInvalid(detail: String)
    case unsupportedSchema(detail: String)
    case operationStalled(detail: String)
    case restorationFailed(detail: String)
    case cancelled(detail: String)
    case notImplemented(detail: String)

    var stableCode: String {
        switch self {
        case .permissionDenied: return "permissionDenied"
        case .noCamera: return "noCamera"
        case .unsupportedCapability: return "unsupportedCapability"
        case .invalidSettings: return "invalidSettings"
        case .cameraInterrupted: return "cameraInterrupted"
        case .captureFailed: return "captureFailed"
        case .representationUnavailable: return "representationUnavailable"
        case .localStorageFull: return "localStorageFull"
        case .folderUnavailable: return "folderUnavailable"
        case .providerIOFailed: return "providerIOFailed"
        case .integrityMismatch: return "integrityMismatch"
        case .conflict: return "conflict"
        case .metadataInvalid: return "metadataInvalid"
        case .unsupportedSchema: return "unsupportedSchema"
        case .operationStalled: return "operationStalled"
        case .restorationFailed: return "restorationFailed"
        case .cancelled: return "cancelled"
        case .notImplemented: return "notImplemented"
        }
    }

    var userDescription: String {
        switch self {
        case .permissionDenied(let d): return "Camera access is not available (\(d))."
        case .noCamera: return "No usable rear camera was found on this device."
        case .unsupportedCapability(let d): return d
        case .invalidSettings(let d): return d
        case .cameraInterrupted(let d): return "The camera was interrupted. \(d)"
        case .captureFailed(let d): return "The capture failed. \(d)"
        case .representationUnavailable(let d): return "The camera returned no usable RAW data. \(d)"
        case .localStorageFull(let d): return "There is not enough local storage. \(d)"
        case .folderUnavailable(let d): return "The selected library folder is unavailable. \(d)"
        case .providerIOFailed(let d): return "A file operation failed. \(d)"
        case .integrityMismatch(let d): return "A file did not match its expected checksum. \(d)"
        case .conflict(let d): return "A conflicting original already exists. \(d)"
        case .metadataInvalid(let d): return "Stored metadata could not be read safely. \(d)"
        case .unsupportedSchema(let d): return "This library uses a newer metadata version. \(d)"
        case .operationStalled(let d): return "An operation did not report completion. \(d)"
        case .restorationFailed(let d): return "Camera settings could not be restored. \(d)"
        case .cancelled(let d): return "Cancelled. \(d)"
        case .notImplemented(let d): return d
        }
    }

    /// Whether retrying the same logical operation could plausibly succeed.
    var isRetryable: Bool {
        switch self {
        case .permissionDenied, .noCamera, .unsupportedCapability, .invalidSettings,
             .notImplemented, .unsupportedSchema:
            return false
        case .cancelled:
            return false
        case .cameraInterrupted, .captureFailed, .representationUnavailable, .localStorageFull,
             .providerIOFailed, .folderUnavailable, .operationStalled, .integrityMismatch,
             .conflict, .metadataInvalid, .restorationFailed:
            return true
        }
    }
}

/// A complete, diagnosable failure. Never loses the originating identity.
struct CaptureFailure: Error, Hashable, Sendable, CustomStringConvertible {
    let kind: FailureKind
    let operation: String
    /// Retained-source status: bytes we still hold for this operation, if any.
    let retainedSourceStatus: RetainedSourceStatus
    let nsErrorDomain: String?
    let nsErrorCode: Int?
    let underlyingDescription: String?

    init(kind: FailureKind,
         operation: String,
         retainedSourceStatus: RetainedSourceStatus = .none,
         nsErrorDomain: String? = nil,
         nsErrorCode: Int? = nil,
         underlyingDescription: String? = nil) {
        self.kind = kind
        self.operation = operation
        self.retainedSourceStatus = retainedSourceStatus
        self.nsErrorDomain = nsErrorDomain
        self.nsErrorCode = nsErrorCode
        self.underlyingDescription = underlyingDescription
    }

    init(kind: FailureKind, operation: String, underlying: Error) {
        let ns = underlying as NSError
        self.init(kind: kind,
                  operation: operation,
                  nsErrorDomain: ns.domain,
                  nsErrorCode: ns.code,
                  underlyingDescription: ns.localizedDescription)
    }

    var description: String {
        var parts = ["[\(kind.stableCode)] \(operation): \(kind.userDescription)"]
        if let d = nsErrorDomain, let c = nsErrorCode { parts.append("(\(d) \(c))") }
        if let u = underlyingDescription { parts.append("— \(u)") }
        parts.append("retryable=\(kind.isRetryable)")
        parts.append("retained=\(retainedSourceStatus.description)")
        return parts.joined(separator: " ")
    }
}

/// What durable evidence we still hold when an operation fails.
enum RetainedSourceStatus: Hashable, Sendable {
    /// Nothing was acquired or staged.
    case none
    /// Bytes reached a closed durable file inside the app's pending storage.
    case durableInternalStaging(relativePath: String)
    /// A complete representation was received but not yet durably staged. This
    /// is the documented non-loss-proof window (CONTRACTS.md).
    case inMemoryRepresentationUnstaged
    /// An intact external staging copy exists.
    case externalStaging(relativePath: String)

    var description: String {
        switch self {
        case .none: return "none"
        case .durableInternalStaging(let p): return "durableInternal(\(p))"
        case .inMemoryRepresentationUnstaged: return "inMemoryUnstaged"
        case .externalStaging(let p): return "externalStaging(\(p))"
        }
    }
}
