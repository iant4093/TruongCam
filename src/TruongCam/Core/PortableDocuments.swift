import Foundation

// LIBRARY.md "Folder format, v1" + schemas/*.json + CONTRACTS.md bounds.
// These Codable models are the portable integration contract. Writers emit only
// known fields; readers ignore unknown fields, bound every allocation and
// refuse a newer major schema instead of silently migrating it.

/// Supported portable metadata major version. A newer major version is
/// read-only and never rewritten.
let truongCamSupportedSchemaVersion = 1

/// Parser/policy bounds. Product policy, never hardware capability.
enum MetadataBounds {
    static let maxSourceSidecarUTF8Bytes = 256 * 1024
    static let maxSequenceJSONUTF8Bytes = 2 * 1024 * 1024
    static let maxRelativePathUTF8Bytes = 1024
    static let maxUUIDStringLength = 36
    static let maxScanBatchEntries = 200
    static let maxIndexPageSize = 60
    static let maxSequenceSources = 999
    static let maxStringFieldLength = 4096
    static let maxDeviceModelLength = 128
    static let maxPathComponents = 32
}

/// Reserved file/folder names inside a library root.
enum LibraryLayout {
    static let libraryManifestName = "metadata/library.json"
    static let legacyLibraryManifestName = "library.json"
    static let metadataDirectoryName = "metadata"
    static let metadataOriginalsDirectory = "metadata/originals"
    static let metadataSequencesDirectory = "metadata/sequences"
    static let supportedLayoutVersion = 2
    static let originalsDirectoryName = "originals"
    static let sequencesDirectoryName = "sequences"
    static let stagingDirectoryName = ".staging"
    static let rootDisplayName = "TruongCam"
    static let sourceFilePrefix = "TC_"
    static let sequenceFilePrefix = "SEQ_"

    static func originalFileName(for captureID: CaptureID, format: SourceFormatRecord? = nil) -> String {
        "\(sourceFilePrefix)\(captureID.rawValue.uuidString.lowercased()).\(format?.fileExtension ?? "dng")"
    }

    static func sidecarFileName(for captureID: CaptureID) -> String {
        "\(sourceFilePrefix)\(captureID.rawValue.uuidString.lowercased()).json"
    }

    static func sequenceFileName(for sequenceID: SequenceID) -> String {
        "\(sequenceFilePrefix)\(sequenceID.rawValue.uuidString.lowercased()).json"
    }

    /// Dated organization path segment, from the local capture date. Organization
    /// aid only — identity is the UUID, never the folder name.
    static func datedDirectoryComponents(for date: Date, calendar: Calendar) -> [String] {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        let year = c.year ?? 1970
        let month = c.month ?? 1
        let day = c.day ?? 1
        return [String(format: "%04d", year), String(format: "%02d", month), String(format: "%02d", day)]
    }

    /// Relative original path for a capture, e.g.
    /// `originals/2026/10/06/TC_<uuid>.dng`.
    static func relativeOriginalPath(
        for captureID: CaptureID,
        capturedAt: Date,
        calendar: Calendar,
        format: SourceFormatRecord? = nil
    ) -> String {
        let components = [originalsDirectoryName]
            + datedDirectoryComponents(for: capturedAt, calendar: calendar)
            + [originalFileName(for: captureID, format: format)]
        return components.joined(separator: "/")
    }

    static func relativeSidecarPath(alongside originalRelativePath: String) -> String {
        guard originalRelativePath.hasSuffix(".dng") else {
            return (originalRelativePath as NSString).deletingPathExtension + ".json"
        }
        return String(originalRelativePath.dropLast(4)) + ".json"
    }

    /// Version-2 layout leaves the photo tree free of application JSON. The
    /// portable JSON schema stays v1; layout version is recorded in the manifest.
    static func metadataSidecarPath(for originalRelativePath: String) -> String {
        metadataDirectoryName + "/" + relativeSidecarPath(alongside: originalRelativePath)
    }
    static func metadataSequencePath(for sequenceID: SequenceID) -> String {
        metadataDirectoryName + "/" + relativeSequencePath(for: sequenceID)
    }

    static func relativeSequencePath(for sequenceID: SequenceID) -> String {
        "\(sequencesDirectoryName)/\(sequenceFileName(for: sequenceID))"
    }
}

// MARK: - Root manifest

struct LibraryManifest: Codable, Hashable, Sendable {
    var schemaVersion: Int
    var libraryID: UUID
    var createdAtUTC: Date
    var application: String
    var storagePolicy: String
    var layoutVersion: Int?

    static let applicationName = "TruongCam"
    static let localOnlyPolicy = "localOnly"

    init(libraryID: LibraryID, createdAtUTC: Date = Date()) {
        self.schemaVersion = truongCamSupportedSchemaVersion
        self.libraryID = libraryID.rawValue
        self.createdAtUTC = createdAtUTC
        self.application = Self.applicationName
        self.storagePolicy = Self.localOnlyPolicy
        self.layoutVersion = LibraryLayout.supportedLayoutVersion
    }

    var declaredLibraryID: LibraryID { LibraryID(libraryID) }
    var declaresLocalOnly: Bool { storagePolicy == Self.localOnlyPolicy }
}

// MARK: - Source sidecar

struct ExposureRequestRecord: Codable, Hashable, Sendable {
    var mode: ExposureModeKind
    var durationSeconds: Double?
    var iso: Double?
    var biasEV: Double
    /// Absent in historical records: missing is unknown, never inferred Auto.
    var apertureMode: String? = nil
    var aperture: Double? = nil
}

struct FocusRequestRecord: Codable, Hashable, Sendable {
    var mode: FocusModeKind
    var position: Double?
}

struct WhiteBalanceRequestRecord: Codable, Hashable, Sendable {
    var mode: WhiteBalanceModeKind
    var temperatureKelvin: Double?
    var tint: Double?
}

struct CaptureRequestRecord: Codable, Hashable, Sendable {
    var maxDimensions: PixelDimensions
    var exposure: ExposureRequestRecord
    var focus: FocusRequestRecord
    var whiteBalance: WhiteBalanceRequestRecord
}

struct SourceFormatRecord: Codable, Hashable, Sendable {
    var kind: String
    var rawPixelFormat: UInt32
    var bayerClassification: Bool

    static let bayerRAWKind = "bayerRAW"

    init(rawPixelFormat: UInt32) {
        self.kind = Self.bayerRAWKind
        self.rawPixelFormat = rawPixelFormat
        self.bayerClassification = true
    }

    static var frontHEIF: SourceFormatRecord {
        var record = SourceFormatRecord(rawPixelFormat: 0)
        record.kind = "heif"
        record.bayerClassification = false
        return record
    }
    var isHEIFDeclaration: Bool { kind == "heif" && rawPixelFormat == 0 && !bayerClassification }
    static var jpeg: SourceFormatRecord {
        var record = SourceFormatRecord(rawPixelFormat: 0)
        record.kind = "jpeg"
        record.bayerClassification = false
        return record
    }
    var isJPEGDeclaration: Bool { kind == "jpeg" && rawPixelFormat == 0 && !bayerClassification }
    var fileExtension: String { isJPEGDeclaration ? "jpg" : (isHEIFDeclaration ? "heic" : "dng") }

    var isBayerRAWDeclaration: Bool {
        kind == Self.bayerRAWKind && bayerClassification
    }
}

struct FocusObservedRecord: Codable, Hashable, Sendable {
    var position: Double?
    var provenance: ValueProvenance
}

struct WhiteBalanceObservedRecord: Codable, Hashable, Sendable {
    var gains: WhiteBalanceGains?
    var provenance: ValueProvenance
}

struct SourceObservedRecord: Codable, Hashable, Sendable {
    var rawDimensions: PixelDimensions?
    var durationSeconds: Double?
    var iso: Double?
    var aperture: Double?
    var focalLengthMM: Double?
    /// EXIF orientation 1…8.
    var orientation: Int?
    var focus: FocusObservedRecord?
    var whiteBalance: WhiteBalanceObservedRecord?
}

struct SourceUIHints: Codable, Hashable, Sendable {
    var equivalentFocalLengthMM: Double?
    var cropGuide: String?
}

struct SourceSequenceLink: Codable, Hashable, Sendable {
    var id: UUID
    var kind: SequenceKind
    var index: Int
    var plannedCount: Int
    var requestedOffsetEV: Double?
    var actualOffsetEV: Double?
    var deadlineOrdinal: Int?

    init(id: SequenceID,
         kind: SequenceKind,
         index: SourceOrdinal,
         plannedCount: Int,
         requestedOffsetEV: Double? = nil,
         actualOffsetEV: Double? = nil,
         deadlineOrdinal: DeadlineOrdinal? = nil) {
        self.id = id.rawValue
        self.kind = kind
        self.index = index.value
        self.plannedCount = plannedCount
        self.requestedOffsetEV = requestedOffsetEV
        self.actualOffsetEV = actualOffsetEV
        self.deadlineOrdinal = deadlineOrdinal?.value
    }
}

enum AcquisitionStatus: String, Codable, Hashable, Sendable {
    case complete
    /// A delivered intact source from a request whose terminal callback errored.
    case partialWithRetainedSource
}

enum CaptureTimeProvenance: String, Codable, Hashable, Sendable {
    case captureMetadata
    case convertedCaptureClock
    case requestTimestamp
}

struct SourceSidecar: Codable, Hashable, Sendable {
    var schemaVersion: Int
    var captureID: UUID
    var libraryID: UUID
    var capturedAtUTC: Date
    var timezoneOffsetSeconds: Int
    var relativeOriginalPath: String
    var byteCount: Int64
    var sha256: String
    var format: SourceFormatRecord
    var deviceModel: String
    var osVersion: String
    var cameraDeviceType: String
    var requested: CaptureRequestRecord
    var observed: SourceObservedRecord
    var ui: SourceUIHints?
    var sequence: SourceSequenceLink?
    var acquisitionStatus: AcquisitionStatus
    var commitRecordedAtUTC: Date
    var capturedAtProvenance: CaptureTimeProvenance
}

// MARK: - Sequence document

enum SequenceKind: String, Codable, Hashable, Sendable, CaseIterable {
    case exposureBracket
    case focusBracket
    case interval

    var displayName: String {
        switch self {
        case .exposureBracket: return "Exposure bracket"
        case .focusBracket: return "Focus bracket"
        case .interval: return "Interval"
        }
    }
}

enum SequenceStatus: String, Codable, Hashable, Sendable {
    case running
    case complete
    case cancelled
    case interrupted
    case failed
}

enum RestorationStatus: String, Codable, Hashable, Sendable {
    case pending
    case restored
    case failed
    case notApplicable
}

struct SequenceSourcePlanEntry: Codable, Hashable, Sendable {
    var index: Int
    var offsetEV: Double?
    var focusPosition: Double?
}

struct SequenceBaseline: Codable, Hashable, Sendable {
    var maxDimensions: PixelDimensions
    var exposure: ExposureRequestRecord
    var focus: FocusRequestRecord
    var whiteBalance: WhiteBalanceRequestRecord
}

struct SequenceCompletedSource: Codable, Hashable, Sendable {
    var index: Int
    var captureID: UUID
}

struct SequenceDocument: Codable, Hashable, Sendable {
    var schemaVersion: Int
    var sequenceID: UUID
    var libraryID: UUID
    var kind: SequenceKind
    var plannedCount: Int
    var sourcePlan: [SequenceSourcePlanEntry]
    var intervalSeconds: Double?
    var baseline: SequenceBaseline?
    var completedSources: [SequenceCompletedSource]
    var missingIndices: [Int]
    var failedIndices: [Int]
    var skippedDeadlineCount: Int
    var status: SequenceStatus
    var startedAtUTC: Date
    var endedAtUTC: Date?
    var errorSummary: String?
    var restorationStatus: RestorationStatus

    init(sequenceID: SequenceID,
         libraryID: LibraryID,
         kind: SequenceKind,
         plannedCount: Int,
         sourcePlan: [SequenceSourcePlanEntry],
         intervalSeconds: Double?,
         baseline: SequenceBaseline?,
         startedAtUTC: Date) {
        self.schemaVersion = truongCamSupportedSchemaVersion
        self.sequenceID = sequenceID.rawValue
        self.libraryID = libraryID.rawValue
        self.kind = kind
        self.plannedCount = plannedCount
        self.sourcePlan = sourcePlan
        self.intervalSeconds = intervalSeconds
        self.baseline = baseline
        self.completedSources = []
        self.missingIndices = []
        self.failedIndices = []
        self.skippedDeadlineCount = 0
        self.status = .running
        self.startedAtUTC = startedAtUTC
        self.endedAtUTC = nil
        self.errorSummary = nil
        self.restorationStatus = .pending
    }
}

// MARK: - Internal transaction journal

enum TransactionPhase: String, Codable, Hashable, Sendable, CaseIterable {
    case reserved
    case stagedInternal
    case stagingProvider
    case verifyingProvider
    case publishingOriginal
    case publishingSidecar
    case verifyingFinal
    case committed
    case cleanup
    case failed

    /// Ordering used to reason about crash recovery progress.
    var progressOrder: Int {
        switch self {
        case .reserved: return 0
        case .stagedInternal: return 1
        case .stagingProvider: return 2
        case .verifyingProvider: return 3
        case .publishingOriginal: return 4
        case .publishingSidecar: return 5
        case .verifyingFinal: return 6
        case .committed: return 7
        case .cleanup: return 8
        case .failed: return -1
        }
    }
}

struct TransactionRecord: Codable, Hashable, Sendable {
    var schemaVersion: Int
    var transactionID: UUID
    var captureID: UUID
    var libraryID: UUID
    var rootGeneration: UInt64
    var phase: TransactionPhase
    var expectedByteCount: Int64
    var expectedSHA256: String
    var relativeOriginalPath: String
    var createdAtUTC: Date
    var updatedAtUTC: Date
    var lastError: String?
}
