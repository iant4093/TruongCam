import Foundation

// CONTRACTS.md "Semantic interfaces" + "Readiness and admission".
// These value types are the bundled payloads handed across service boundaries.
// Ownership transfers the *handle* (identity + path), never an indefinitely
// retained full-file `Data`.

/// Per-source capture metadata snapshot taken at acquisition time. This is the
/// fourth truth alongside desired/applied/observed and is frozen with the intent.
struct SourceCaptureMetadata: Hashable, Sendable {
    let captureID: CaptureID
    let libraryID: LibraryID
    let capturedAtUTC: Date
    let capturedAtProvenance: CaptureTimeProvenance
    let timezoneOffsetSeconds: Int
    let format: SourceFormatRecord
    let deviceModel: String
    let osVersion: String
    let cameraDeviceType: String
    let requested: CaptureRequestRecord
    let observed: SourceObservedRecord
    let acquisitionStatus: AcquisitionStatus
    let sequence: SourceSequenceLink?
    let equivalentFocalLengthMM: Double?
}

/// Ownership transfer object for a source written into internal recovery
/// storage. The bytes are on disk; only identity and integrity live here.
struct StagedSourceHandle: Hashable, Sendable {
    let transactionID: TransactionID
    let captureID: CaptureID
    let libraryID: LibraryID
    /// Relative path inside the app's internal pending-capture storage.
    let pendingRelativePath: String
    let byteCount: Int64
    let sha256: SHA256Digest
    let metadata: SourceCaptureMetadata
    let acquisitionTerminalStatus: AcquisitionTerminalStatus
    let originRootGeneration: RootGeneration
    let intendedRelativeOriginalPath: String

    var isValid: Bool {
        byteCount > 0 && !pendingRelativePath.isEmpty && !intendedRelativeOriginalPath.isEmpty
    }
}

/// Terminal state of the native acquisition for a source. Kept separate from the
/// persistence status: a delivered intact source can outlive a terminal error.
enum AcquisitionTerminalStatus: Hashable, Sendable {
    /// Native terminal callback reported success.
    case success
    /// Terminal callback reported an error but the RAW representation was
    /// delivered and retained.
    case partialWithRetainedSource(errorDescription: String)
    /// Terminal callback reported an error and no usable representation arrived.
    case failed(errorDescription: String)

    var isRetained: Bool {
        switch self {
        case .success, .partialWithRetainedSource: return true
        case .failed: return false
        }
    }

    var description: String {
        switch self {
        case .success: return "success"
        case .partialWithRetainedSource(let d): return "partialWithRetainedSource(\(d))"
        case .failed(let d): return "failed(\(d))"
        }
    }
}

/// Immutable commit receipt for a verified final publication. The receipt is
/// immutable: a later index failure cannot revoke a file commit.
struct CommitReceipt: Hashable, Sendable {
    let transactionID: TransactionID
    let captureID: CaptureID
    let libraryID: LibraryID
    let rootGeneration: RootGeneration
    let relativeOriginalPath: String
    let relativeSidecarPath: String
    let verifiedByteCount: Int64
    let verifiedSHA256: SHA256Digest
    let isOriginalAvailable: Bool
    /// Local, post-verification commit-observed time. Distinct from the
    /// sidecar's `commitRecordedAtUTC`, which is marker-preparation time.
    let commitObservedAtUTC: Date
    let metadata: SourceCaptureMetadata
}

/// State of one source inside the save pipeline (CONTRACTS.md source lifecycle).
enum SourcePersistenceState: Hashable, Sendable {
    case reserved
    case nativeInFlight
    case representationReceived
    case stagingInternal
    case stagedInternal(relativePath: String)
    case stagingProvider
    case verifyingProvider
    case publishingOriginal
    case publishingSidecar
    case verifyingFinal
    case committed(CommitReceipt)
    case pendingRetry(failure: CaptureFailure, retained: RetainedSourceStatus)
    case failed(failure: CaptureFailure)

    var isCommitted: Bool {
        if case .committed = self { return true }
        return false
    }

    var isDurablyStaged: Bool {
        switch self {
        case .stagedInternal, .stagingProvider, .verifyingProvider, .publishingOriginal,
             .publishingSidecar, .verifyingFinal, .committed:
            return true
        case .pendingRetry(_, let retained):
            if case .durableInternalStaging = retained { return true }
            if case .externalStaging = retained { return true }
            return false
        default:
            return false
        }
    }

    var displayLabel: String {
        switch self {
        case .reserved: return "Reserved"
        case .nativeInFlight: return "Capturing"
        case .representationReceived: return "Received (not yet durable)"
        case .stagingInternal: return "Staging in app"
        case .stagedInternal: return "Staged in app (pending)"
        case .stagingProvider: return "Saving to folder"
        case .verifyingProvider: return "Verifying folder copy"
        case .publishingOriginal: return "Publishing original"
        case .publishingSidecar: return "Publishing sidecar"
        case .verifyingFinal: return "Verifying final original"
        case .committed: return "Saved to folder"
        case .pendingRetry: return "Save failed — original retained in app"
        case .failed: return "Save failed"
        }
    }
}

/// One capture request. Frozen value snapshot; never mutated after submission.
enum CaptureFileFormat: String, Hashable, Sendable { case bayerDNG, frontHEIF, jpeg }

struct CaptureIntent: Hashable, Sendable {
    let fileFormat: CaptureFileFormat
    init(captureID: CaptureID,
         libraryID: LibraryID,
         sequenceID: SequenceID? = nil,
         sequenceOrdinal: SourceOrdinal? = nil,
         requestedDimensions: PixelDimensions,
         exposure: ExposureChoice,
         biasEV: Double,
         focus: FocusIntent,
         whiteBalance: WhiteBalanceIntent,
         configurationGeneration: ConfigurationGeneration,
         rootGeneration: RootGeneration,
         physicalCameraKind: PhysicalCameraKind,
         createdAtUTC: Date,
         capturedAtProvenance: CaptureTimeProvenance = .requestTimestamp,
         timezoneOffsetSeconds: Int,
         mode: CaptureMode,
         deadlineOrdinal: DeadlineOrdinal? = nil,
         focusBracketTarget: Double? = nil,
         requestedOffsetEV: Double? = nil,
         equivalentFocalLengthMM: Double? = nil,
         sequencePlannedCount: Int? = nil,
         baselineISO: Double? = nil,
         baselineDurationSeconds: Double? = nil,
         fileFormat: CaptureFileFormat = .bayerDNG,
         aperture: ApertureChoice = .auto,
         baselineAperture: Double? = nil) {
        self.fileFormat = fileFormat
        self.aperture = aperture
        self.baselineAperture = baselineAperture
        self.captureID = captureID
        self.libraryID = libraryID
        self.sequenceID = sequenceID
        self.sequenceOrdinal = sequenceOrdinal
        self.requestedDimensions = requestedDimensions
        self.exposure = exposure
        self.biasEV = biasEV
        self.focus = focus
        self.whiteBalance = whiteBalance
        self.configurationGeneration = configurationGeneration
        self.rootGeneration = rootGeneration
        self.physicalCameraKind = physicalCameraKind
        self.createdAtUTC = createdAtUTC
        self.capturedAtProvenance = capturedAtProvenance
        self.timezoneOffsetSeconds = timezoneOffsetSeconds
        self.mode = mode
        self.deadlineOrdinal = deadlineOrdinal
        self.focusBracketTarget = focusBracketTarget
        self.requestedOffsetEV = requestedOffsetEV
        self.equivalentFocalLengthMM = equivalentFocalLengthMM
        self.sequencePlannedCount = sequencePlannedCount
        self.baselineISO = baselineISO
        self.baselineDurationSeconds = baselineDurationSeconds
    }

    let captureID: CaptureID
    let libraryID: LibraryID
    let sequenceID: SequenceID?
    let sequenceOrdinal: SourceOrdinal?
    let requestedDimensions: PixelDimensions
    let exposure: ExposureChoice
    let aperture: ApertureChoice
    let baselineAperture: Double?
    let biasEV: Double
    let focus: FocusIntent
    let whiteBalance: WhiteBalanceIntent
    let configurationGeneration: ConfigurationGeneration
    let rootGeneration: RootGeneration
    let physicalCameraKind: PhysicalCameraKind
    let createdAtUTC: Date
    let capturedAtProvenance: CaptureTimeProvenance
    let timezoneOffsetSeconds: Int
    let mode: CaptureMode
    /// Serialized countdown origin for an interval source, when applicable.
    let deadlineOrdinal: DeadlineOrdinal?
    /// Focus-bracket target position, when this intent is a focus-bracket step.
    let focusBracketTarget: Double?
    let requestedOffsetEV: Double?
    let equivalentFocalLengthMM: Double?
    /// Planned source count of the owning sequence, when applicable.
    let sequencePlannedCount: Int?
    /// Frozen baseline used to compute the achieved EV offset of this source.
    let baselineISO: Double?
    let baselineDurationSeconds: Double?
}

extension CaptureMode {
    /// The sequence kind this capture mode belongs to, if any.
    var sequenceKind: SequenceKind {
        switch self {
        case .exposureBracketSource: return .exposureBracket
        case .focusBracketSource: return .focusBracket
        case .intervalSource: return .interval
        case .single, .timer: return .interval
        }
    }
}

enum CaptureMode: String, Hashable, Sendable, Codable {
    case single
    case exposureBracketSource
    case focusBracketSource
    case intervalSource
    case timer
}

/// A normalized device point in the capture device's coordinate space.
struct NormalizedDevicePoint: Hashable, Sendable {
    let x: Double
    let y: Double

    init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }

    var tcPoint: TCPoint { TCPoint(x: x, y: y) }
    var isFinite: Bool { x.isFinite && y.isFinite }
    var isInsideUnitSquare: Bool {
        isFinite && x >= 0 && x <= 1 && y >= 0 && y <= 1
    }
}

struct FocusIntent: Hashable, Sendable {
    let mode: FocusModeKind
    /// Normalized [0, 1] lens position, required when mode is `.manual`.
    let position: Double?
    /// Normalized device point of interest applied for AF, when the user tapped.
    let pointOfInterest: NormalizedDevicePoint?
}


struct WhiteBalanceIntent: Hashable, Sendable {
    let mode: WhiteBalanceModeKind
    let temperatureAndTint: WhiteBalanceTemperatureAndTint?
}

/// Terminal result of one native photo request.
enum NativeRequestOutcome: Hashable, Sendable {
    case success
    /// Request finished but some delivered sources carried errors.
    case partial(retainedSourceCount: Int, description: String)
    case failed(CaptureFailure)

    var isSuccessOrPartial: Bool {
        if case .failed = self { return false }
        return true
    }
}

/// What a caller learns about one capture request. Exactly one of these is
/// delivered per intent.
struct CaptureCompletion: Hashable, Sendable {
    let captureID: CaptureID
    let outcome: NativeRequestOutcome
    let committedSources: [CommitReceipt]
    let pendingSourceCount: Int
    let failure: CaptureFailure?
}

/// A pending (not yet committed) original held in internal recovery storage.
struct PendingOriginal: Hashable, Sendable, Identifiable {
    var id: TransactionID { transactionID }
    let transactionID: TransactionID
    let captureID: CaptureID
    let libraryID: LibraryID
    let pendingRelativePath: String
    let intendedRelativeOriginalPath: String
    let byteCount: Int64
    let sha256: SHA256Digest
    let phase: TransactionPhase
    let createdAtUTC: Date
    let updatedAtUTC: Date
    let lastError: String?
    let originRootGeneration: RootGeneration

    /// Pending sources are explicitly *not* reinstall-safe.
    var reinstallSafe: Bool { false }
}

/// Root availability state (CONTRACTS.md "Camera, source and library state").
enum LibraryRootState: Hashable, Sendable {
    case unselected
    case resolving
    case writable(libraryID: LibraryID, generation: RootGeneration)
    case readOnly(reason: String, libraryID: LibraryID?)
    case unavailable(reason: String, libraryID: LibraryID?)
    case reconciling(libraryID: LibraryID, generation: RootGeneration)

    var libraryID: LibraryID? {
        switch self {
        case .writable(let id, _), .reconciling(let id, _): return id
        case .readOnly(_, let id), .unavailable(_, let id): return id
        case .unselected, .resolving: return nil
        }
    }

    var generation: RootGeneration? {
        switch self {
        case .writable(_, let g), .reconciling(_, let g): return g
        default: return nil
        }
    }

    var isWritable: Bool {
        if case .writable = self { return true }
        return false
    }

    var displayLabel: String {
        switch self {
        case .unselected: return "Waiting for folder"
        case .resolving: return "Resolving folder"
        case .writable: return "Library ready"
        case .readOnly(let reason, _): return "Read-only — \(reason)"
        case .unavailable(let reason, _): return "Folder unavailable — \(reason)"
        case .reconciling: return "Reading library"
        }
    }
}

/// How a scanned source was classified. Drives truthful gallery cards.
enum SourceClassification: Hashable, Sendable {
    /// DNG plus a valid matching sidecar.
    case verifiedOriginal
    /// DNG with no sidecar, or a sidecar that could not be trusted.
    case recoveredRAW(metadataIssue: String?)
    /// A sidecar whose DNG is missing or unreadable.
    case missingOriginal(reason: String)
    /// External staged DNG with a matching transaction record.
    case stagedExternal
    /// Bytes exist but the DNG identity/hash conflicts with the sidecar.
    case conflict(reason: String)

    var isBrowsableOriginal: Bool {
        switch self {
        case .verifiedOriginal, .recoveredRAW, .conflict: return true
        case .missingOriginal, .stagedExternal: return false
        }
    }
}

/// Where a source's file currently is.
enum SourceAvailability: Hashable, Sendable {
    case local
    case missing
    case inaccessible(reason: String)
    case unknown
}
