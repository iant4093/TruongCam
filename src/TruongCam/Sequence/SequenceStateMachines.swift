import Foundation
import Synchronization

// CONTRACTS.md "Semantic interfaces", "Readiness and admission" and "Sequence
// rules and policy defaults".
//
// This file holds the injected seams and the value types the sequence state
// machines publish. Nothing here imports AVFoundation or touches a device.

// MARK: - Cancellation signal

/// Thread-safe stop flag shared with waits that live outside the coordinator
/// actor (baseline settlement, focus settling, deadline slices).
final class SequenceCancellationSignal: @unchecked Sendable {
    private let mutex = Mutex<Bool>(false)

    init() {}

    func request() {
        mutex.withLock { $0 = true }
    }

    func reset() {
        mutex.withLock { $0 = false }
    }

    var isRequested: Bool {
        mutex.withLock { $0 }
    }
}

/// A collaborator that wants the coordinator's visible run phase.
protocol SequencePhaseObserving: Sendable {
    func observe(phase: SequenceRunPhase) async
}

// MARK: - Single source execution

/// Named phases a single capture can fail in. Fakes fail at these names so the
/// coordinator's failure handling is exercised without a device.
enum SingleCapturePhase: String, Hashable, Sendable, CaseIterable {
    /// Native terminal error with no usable representation.
    case acquisition
    /// A representation arrived but was not durably staged.
    case representation
    /// Internal staging failed.
    case staging
    /// Provider commit failed.
    case commit
    /// Final verification of the published original failed.
    case verification
}

/// Terminal result of one submitted single capture, after staging/commit has
/// finished or failed.
struct SingleCaptureExecutionResult: Sendable {
    let captureID: CaptureID
    let terminalStatus: AcquisitionTerminalStatus
    let persistence: SourcePersistenceState
    let stagedHandle: StagedSourceHandle?
    let receipt: CommitReceipt?
    let failure: CaptureFailure?

    init(captureID: CaptureID,
         terminalStatus: AcquisitionTerminalStatus,
         persistence: SourcePersistenceState,
         stagedHandle: StagedSourceHandle? = nil,
         receipt: CommitReceipt? = nil,
         failure: CaptureFailure? = nil) {
        self.captureID = captureID
        self.terminalStatus = terminalStatus
        self.persistence = persistence
        self.stagedHandle = stagedHandle
        self.receipt = receipt
        self.failure = failure
    }
}

/// One serialized single-source capture: submit an intent, receive exactly one
/// terminal outcome after staging and commit.
protocol SingleCaptureExecuting: Sendable {
    func execute(_ intent: CaptureIntent) async -> SingleCaptureExecutionResult
}

/// Stages and commits one RAW representation that the native layer already
/// delivered for a known intent.
///
/// A native bracket delivers its burst through callbacks, not through
/// `beginCapture` per source; the coordinator maps each callback to the intent
/// that requested it by `NativeBracketIdentity` and hands both here. The bytes
/// are owned by the persistence port, never retained by the sequence layer.
protocol DeliveredSourcePersisting: Sendable {
    func persist(_ representation: DeliveredRAWRepresentation,
                 intent: CaptureIntent) async -> SingleCaptureExecutionResult
}

/// What one source of a sequence produced. Retained means the bytes are durable
/// somewhere we still own, committed means the original is published.
struct SequenceSourceOutcome: Sendable {
    let ordinal: SourceOrdinal?
    let intent: CaptureIntent
    let terminalStatus: AcquisitionTerminalStatus
    let persistence: SourcePersistenceState
    let stagedHandle: StagedSourceHandle?
    let receipt: CommitReceipt?
    let failure: CaptureFailure?

    var isCommitted: Bool { receipt != nil }
    var isRetained: Bool { receipt != nil || stagedHandle != nil }
}

/// Serializes acquisition → staging → commit. At most one acquisition and one
/// save are ever in flight, because a second `run` waits for the first to finish
/// rather than interleaving on the actor's suspension points.
actor SequenceSourcePipeline {
    private let executor: SingleCaptureExecuting
    /// Used for a native bracket's already-delivered representations. Nil means
    /// native bracket persistence was not wired, which fails loudly rather than
    /// dropping source bytes.
    private let persister: DeliveredSourcePersisting?
    private var isRunning = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var inFlight = 0
    private var peakInFlight = 0

    init(executor: SingleCaptureExecuting, persister: DeliveredSourcePersisting? = nil) {
        self.executor = executor
        self.persister = persister
    }

    /// Highest number of `execute` calls that were ever in flight at once.
    /// Always at most one; exposed so a test can prove it.
    var observedPeakConcurrency: Int { peakInFlight }

    func run(_ intent: CaptureIntent) async -> SequenceSourceOutcome {
        await acquire()
        inFlight += 1
        peakInFlight = max(peakInFlight, inFlight)
        let result = await executor.execute(intent)
        inFlight -= 1
        release()
        return SequenceSourceOutcome(
            ordinal: intent.sequenceOrdinal,
            intent: intent,
            terminalStatus: result.terminalStatus,
            persistence: result.persistence,
            stagedHandle: result.stagedHandle,
            receipt: result.receipt,
            failure: result.failure)
    }

    /// Persists one already-delivered native representation. Serialized with
    /// `run` so at most one save is ever in flight.
    func persist(_ representation: DeliveredRAWRepresentation,
                 intent: CaptureIntent) async -> SequenceSourceOutcome {
        await acquire()
        inFlight += 1
        peakInFlight = max(peakInFlight, inFlight)
        let result: SingleCaptureExecutionResult
        if let persister {
            result = await persister.persist(representation, intent: intent)
        } else {
            result = SingleCaptureExecutionResult(
                captureID: intent.captureID,
                terminalStatus: .failed(errorDescription: "Native bracket persistence is not wired"),
                persistence: .failed(failure: CaptureFailure(
                    kind: .notImplemented(detail: "Native bracket persistence is not wired."),
                    operation: "sequence.pipeline.persist")),
                failure: CaptureFailure(
                    kind: .notImplemented(detail: "Native bracket persistence is not wired."),
                    operation: "sequence.pipeline.persist"))
        }
        inFlight -= 1
        release()
        return SequenceSourceOutcome(
            ordinal: intent.sequenceOrdinal,
            intent: intent,
            terminalStatus: result.terminalStatus,
            persistence: result.persistence,
            stagedHandle: result.stagedHandle,
            receipt: result.receipt,
            failure: result.failure)
    }

    private func acquire() async {
        if !isRunning {
            isRunning = true
            return
        }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            waiters.append(continuation)
        }
    }

    private func release() {
        if waiters.isEmpty {
            isRunning = false
        } else {
            // Ownership of the gate transfers directly to the next waiter.
            waiters.removeFirst().resume()
        }
    }
}

// MARK: - Sequence document storage

/// The narrow storage surface a sequence needs.
protocol SequenceDocumentStoring: Sendable {
    var rootState: LibraryRootState { get }
    func writeSequenceDocument(_ document: SequenceDocument) async throws
    func readSequenceDocument(_ sequenceID: SequenceID) async throws -> SequenceDocument
}

/// Adapts the frozen `LibraryStoring` boundary to the narrow requirement.
struct LibraryStoreSequenceAdapter: SequenceDocumentStoring {
    let store: any LibraryStoring

    var rootState: LibraryRootState { store.rootState }

    func writeSequenceDocument(_ document: SequenceDocument) async throws {
        try await store.writeSequenceDocument(document)
    }

    func readSequenceDocument(_ sequenceID: SequenceID) async throws -> SequenceDocument {
        try await store.readSequenceDocument(sequenceID)
    }
}

// MARK: - Capability

protocol SequenceCapabilityProviding: Sendable {
    func capabilityContext() async -> SequenceCapabilityContext
}

// MARK: - Settings control

/// The prior/desired control state a sequence freezes and restores.
struct SequenceSettingsSnapshot: Hashable, Sendable {
    let configurationGeneration: ConfigurationGeneration
    let revision: UInt64
    let exposure: ExposureChoice
    let biasEV: Double
    let focus: FocusIntent
    let whiteBalance: WhiteBalanceIntent
    let maxDimensions: PixelDimensions
    var aperture: ApertureChoice = .auto

    init(configurationGeneration: ConfigurationGeneration,
         revision: UInt64,
         exposure: ExposureChoice,
         biasEV: Double,
         focus: FocusIntent,
         whiteBalance: WhiteBalanceIntent,
         maxDimensions: PixelDimensions,
         aperture: ApertureChoice = .auto) {
        self.configurationGeneration = configurationGeneration
        self.revision = revision
        self.exposure = exposure
        self.biasEV = biasEV
        self.focus = focus
        self.whiteBalance = whiteBalance
        self.maxDimensions = maxDimensions
        self.aperture = aperture
    }
}

/// Camera-side effects a sequence needs. Injected so the coordinator never reads
/// or writes a device itself.
protocol SequenceSettingsControlling: Sendable {
    /// Current desired/applied controls, before the plan freezes anything. Nil
    /// when the camera has no valid state yet.
    func snapshotCurrentSettings() async -> SequenceSettingsSnapshot?
    /// Last settled exposure baseline, when the device has produced one.
    func currentExposureBaseline() async -> ExposureBaseline?
    /// Optionally lock a real Auto focus mode before measuring a bracket baseline.
    /// True means settings changed; failure may have changed them and requires restoration.
    func prepareFocusLockForBaseline(_ prior: SequenceSettingsSnapshot) async -> Result<Bool, CaptureFailure>
    /// Applies the sequence's frozen controls as one revision.
    func apply(_ settings: SequenceSettingsSnapshot) async -> Result<Void, CaptureFailure>
    /// Restores the prior valid user settings after all submitted native work.
    func restore(_ settings: SequenceSettingsSnapshot) async -> Result<Void, CaptureFailure>
    /// Recovery from a failed restoration: return exposure/focus/WB to Auto.
    func resetToAuto() async -> Result<Void, CaptureFailure>
}

// MARK: - Native bracket submission

/// One callback from a submitted native bracket. Always carries the native
/// identity the SDK reported; the coordinator maps by that identity and never by
/// arrival order.
struct BracketSourceCallback: Sendable {
    let identity: NativeBracketIdentity
    let representation: DeliveredRAWRepresentation?
    let terminalStatus: AcquisitionTerminalStatus?

    init(identity: NativeBracketIdentity,
         representation: DeliveredRAWRepresentation? = nil,
         terminalStatus: AcquisitionTerminalStatus? = nil) {
        self.identity = identity
        self.representation = representation
        self.terminalStatus = terminalStatus
    }
}

struct BracketSubmissionRequest: Sendable {
    let sequenceID: SequenceID
    let libraryID: LibraryID
    let configurationGeneration: ConfigurationGeneration
    let rootGeneration: RootGeneration
    let plan: ExposureBracketPlan
    let baseline: ExposureBaseline
    /// One intent per submitted step, in submitted order:
    /// `intents[index]` belongs to `NativeBracketIdentity.submittedIndex == index`.
    let intents: [CaptureIntent]
}

/// A submitted native bracket request.
///
/// Contract: `callbacks` finishes only after every callback for the submission
/// has been delivered, including late ones. `terminal` yields exactly one
/// outcome. A caller drains both; cancelling a sequence never assumes the native
/// burst stopped, so the delivered sources must still reach storage.
struct BracketSubmission: Sendable {
    let submittedIdentities: [NativeBracketIdentity]
    let callbacks: AsyncStream<BracketSourceCallback>
    let terminal: AsyncStream<NativeRequestOutcome>
}

protocol BracketSubmitting: Sendable {
    func submit(_ request: BracketSubmissionRequest) async -> Result<BracketSubmission, CaptureFailure>
}

// MARK: - Stop reasons and phases

enum SequenceInterruptionReason: String, Hashable, Sendable, Codable, CaseIterable {
    case background
    /// The camera screen stopped being the visible surface (for example the library
    /// was opened). Distinct from `background`: the app is still foreground
    /// (REVIEW.md F02).
    case screenIneligible
    case lensSwitch
    case mediaServicesReset
    case processDeath
    case permissionLoss
    case settingsConflict
    case unknown

    var displayName: String {
        switch self {
        case .background: return "App went to the background"
        case .screenIneligible: return "The camera screen was closed"
        case .lensSwitch: return "Physical camera changed"
        case .mediaServicesReset: return "Camera services were reset"
        case .processDeath: return "The app stopped during the run"
        case .permissionLoss: return "Camera access was lost"
        case .settingsConflict: return "A conflicting setting changed"
        case .unknown: return "Interrupted"
        }
    }
}

/// Why a run stopped admitting new work. The first reason wins.
enum SequenceStopReason: Hashable, Sendable {
    case userCancelled
    case interrupted(SequenceInterruptionReason)
    case failed(CaptureFailure)

    var status: SequenceStatus {
        switch self {
        case .userCancelled: return .cancelled
        case .interrupted: return .interrupted
        case .failed: return .failed
        }
    }

    var failure: CaptureFailure? {
        if case .failed(let failure) = self { return failure }
        return nil
    }

    var interruptionReason: SequenceInterruptionReason? {
        if case .interrupted(let reason) = self { return reason }
        return nil
    }

    var summary: String {
        switch self {
        case .userCancelled:
            return "Cancelled by the user."
        case .interrupted(let reason):
            return "Interrupted: \(reason.displayName)."
        case .failed(let failure):
            return failure.description
        }
    }
}

/// Visible phase of a run. The settling and countdown phases are the cancellable
/// states the UI must show.
enum SequenceRunPhase: Hashable, Sendable {
    case idle
    case validating
    case countdown(deadlineMonotonic: Double)
    case settlingBaseline
    case settlingFocus(ordinal: Int, watchdogSeconds: Double)
    case capturing(ordinal: Int)
    case waitingForDeadline(deadlineMonotonic: Double, deadlineOrdinal: Int)
    case drainingSubmittedWork
    case restoringSettings
    case finished
}

// MARK: - Progress and coordinator state

struct SequenceProgress: Hashable, Sendable {
    let sequenceID: SequenceID
    let kind: SequencePlanKind
    let plannedCount: Int
    var committedCount: Int
    /// Committed plus durably staged sources: every acquired source retained.
    var retainedCount: Int
    var failedOrdinals: [Int]
    var missingOrdinals: [Int]
    var skippedDeadlineCount: Int
    var deadlineOrdinalsUsed: [Int]
    var unattributedCallbackCount: Int
    var phase: SequenceRunPhase
    var status: SequenceStatus
    var restoration: RestorationStatus
    var errorSummary: String?
    /// True when the last sequence-document write failed. A document failure can
    /// never revoke an already committed original.
    var documentWriteFailed: Bool
    /// Label of the tested bracket path actually used, when applicable.
    var bracketPath: ExposureBracketPath?
    /// The settled baseline actually applied, when one was frozen.
    var baseline: SequenceBaselineSnapshot?

    var isRunnable: Bool { status == .running }

    var isSourceComplete: Bool {
        committedCount == plannedCount && failedOrdinals.isEmpty
            && unattributedCallbackCount == 0
    }
}

enum SequenceCoordinatorState: Hashable, Sendable {
    case idle
    case validating(sequenceID: SequenceID)
    case running(SequenceProgress)
    case complete(SequenceProgress)
    case cancelled(SequenceProgress)
    case interrupted(SequenceProgress, reason: SequenceInterruptionReason)
    case failed(SequenceProgress, failure: CaptureFailure)
    /// Restoration failed: visible, shutter blocked, Reset to Auto offered.
    case restorationFailed(SequenceProgress, failure: CaptureFailure)
    case resettingToAuto

    var progress: SequenceProgress? {
        switch self {
        case .idle, .resettingToAuto: return nil
        case .validating: return nil
        case .running(let p), .complete(let p), .cancelled(let p),
             .interrupted(let p, _), .failed(let p, _), .restorationFailed(let p, _):
            return p
        }
    }

    var isActive: Bool {
        switch self {
        case .validating, .running, .resettingToAuto: return true
        case .idle, .complete, .cancelled, .interrupted, .failed, .restorationFailed:
            return false
        }
    }

    /// New captures are refused while a run is active or settings are
    /// unreconciled. A restoration failure must never be silently reported as
    /// restored.
    var isShutterBlocked: Bool {
        switch self {
        case .running, .validating, .restorationFailed, .resettingToAuto: return true
        case .idle, .complete, .cancelled, .interrupted, .failed: return false
        }
    }

    var offersResetToAuto: Bool {
        if case .restorationFailed = self { return true }
        return false
    }

    var restoration: RestorationStatus {
        switch self {
        case .restorationFailed: return .failed
        case .idle: return .notApplicable
        default: return progress?.restoration ?? .notApplicable
        }
    }
}

struct SequenceCoordinatorSnapshot: Hashable, Sendable {
    let state: SequenceCoordinatorState
    let progress: SequenceProgress?
    let isShutterBlocked: Bool
    let offersResetToAuto: Bool
    let restoration: RestorationStatus
}

/// Everything a caller learns from one run, including the retained sources.
struct SequenceRunResult: Sendable {
    let sequenceID: SequenceID
    let kind: SequencePlanKind
    let status: SequenceStatus
    let progress: SequenceProgress
    let committedReceipts: [CommitReceipt]
    let retainedHandles: [StagedSourceHandle]
    let focusReadbacks: [FocusSettleRecord]
    let restoration: RestorationStatus
    let failure: CaptureFailure?
    let validationErrors: [SequencePlanValidationError]
    let documentWriteFailed: Bool
}

/// Result of reconciling a stale `running` document after a restart.
struct SequenceReconciliation: Sendable {
    let sequenceID: SequenceID
    let previousStatus: SequenceStatus
    let document: SequenceDocument
    let didPersist: Bool
    let summary: SequenceSummary
    let note: String?
}

// MARK: - File-derived group rebuild

enum SequenceGroupRebuilder {
    /// Rebuilds sequence membership from committed source metadata when the
    /// sequence document is missing or failed to write.
    ///
    /// A source's sidecar proves which group it belongs to, not that the run
    /// reached its planned count, so the rebuilt summary is never reported
    /// complete. `skippedDeadlineCount` is not recoverable from sidecars and is
    /// reported as 0.
    static func rebuild(sequenceID: SequenceID,
                        metadata: [SourceCaptureMetadata]) -> SequenceSummary? {
        var members: [(index: Int, plannedCount: Int, kind: SequenceKind, capturedAtUTC: Date)] = []
        for entry in metadata {
            guard let link = entry.sequence, link.id == sequenceID.rawValue else { continue }
            guard (1...MetadataBounds.maxSequenceSources).contains(link.plannedCount),
                  (0..<link.plannedCount).contains(link.index) else { return nil }
            members.append((link.index, link.plannedCount, link.kind, entry.capturedAtUTC))
        }
        guard let first = members.first else { return nil }

        let indices = Set(members.map(\.index))
        let plannedCount = max(members.map(\.plannedCount).max() ?? first.plannedCount,
                               first.plannedCount)
        let missing = (0..<max(plannedCount, 1)).filter { !indices.contains($0) }

        return SequenceSummary(
            sequenceID: sequenceID,
            kind: first.kind,
            plannedCount: plannedCount,
            committedCount: indices.count,
            missingIndices: missing,
            failedIndices: [],
            skippedDeadlineCount: 0,
            status: .interrupted,
            startedAtUTC: members.map(\.capturedAtUTC).min() ?? first.capturedAtUTC)
    }
}

extension SequenceSettingsControlling {
    func prepareFocusLockForBaseline(_ prior: SequenceSettingsSnapshot) async -> Result<Bool, CaptureFailure> { .success(false) }
}

/// Uses a real native focus lock rather than waiting for continuous AF to stop
/// changing on its own. No numeric position or settled provenance is invented.
enum SequenceBaselineFocusPreparation {
    static func lockedSettings(_ prior: SequenceSettingsSnapshot, observedPosition: Double) -> SequenceSettingsSnapshot? {
        guard prior.focus.mode != .manual, observedPosition.isFinite, (0...1).contains(observedPosition) else { return nil }
        return SequenceSettingsSnapshot(configurationGeneration: prior.configurationGeneration,
            revision: prior.revision &+ 1, exposure: prior.exposure, biasEV: prior.biasEV,
            focus: FocusIntent(mode: .manual, position: observedPosition, pointOfInterest: nil),
            whiteBalance: prior.whiteBalance, maxDimensions: prior.maxDimensions, aperture: prior.aperture)
    }
}
