import Foundation

// Native test bundles read the app's real types through the module; the
// standalone verifier compiles the app sources into the same executable and
// therefore cannot import a module. XCTest is only available in the native
// bundle, so it gates the import.
#if canImport(XCTest)
@testable import TruongCam
#endif


// TEST_PLAN.md T25–T30 (plus the interval/bracket/settlement checks the packets
// require) driven by `VirtualMonotonicClock` and deterministic fakes. No real
// sleeping, no device, no AVFoundation.
//
// Every fake is named with a `Seq` prefix so it cannot collide with another
// suite's fakes in the same compiled module.

// MARK: - Support

enum SeqTestSupport {
    static let libraryID = LibraryID(UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!)
    static let nowUTC = Date(timeIntervalSince1970: 1_790_000_000)
    static let configurationGeneration = ConfigurationGeneration(7)

    static let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()

    static let writableRoot = LibraryRootState.writable(
        libraryID: libraryID,
        generation: RootGeneration(1))
}

/// Lock-protected box for values observed across tasks.
final class SequenceTestBox<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: Value

    init(_ initial: Value) { storage = initial }

    var value: Value {
        lock.lock(); defer { lock.unlock() }
        return storage
    }

    func set(_ value: Value) {
        lock.lock(); storage = value; lock.unlock()
    }

    func mutate(_ body: (inout Value) -> Void) {
        lock.lock(); body(&storage); lock.unlock()
    }
}

/// Advances a `VirtualMonotonicClock` only while a coroutine is parked on it,
/// yielding between steps. This is what makes the interval/bracket/settlement
/// state machines testable without any real waiting.
@discardableResult
func driveVirtualClock(_ clock: VirtualMonotonicClock,
                       step: Double = 0.25,
                       maxSteps: Int = 80_000,
                       until isDone: @Sendable () async -> Bool) async -> Bool {
    var steps = 0
    while steps < maxSteps {
        if await isDone() { return true }
        if clock.pendingWaiterCount > 0 {
            clock.advance(by: step)
        }
        for _ in 0..<4 { await Task.yield() }
        steps += 1
    }
    return await isDone()
}

/// Runs a baseline settlement while driving the virtual clock, so the
/// duration-aware wait can be exercised without real time.
func tcSeqSettle(_ settler: any SequenceBaselineSettling,
                 clock: VirtualMonotonicClock,
                 request: BaselineSettlementRequest,
                 _ signal: SequenceCancellationSignal)
    async -> Result<SequenceBaselineSnapshot, BaselineSettlementFailure> {
    let box = SequenceTestBox<Result<SequenceBaselineSnapshot, BaselineSettlementFailure>?>(nil)
    let task = Task { box.set(await settler.settle(request, cancellation: signal)) }
    _ = await driveVirtualClock(clock) { box.value != nil }
    _ = await task.value
    return box.value ?? .failure(.cancelled)
}

/// A monotonic counter so each synthetic readback is a DISTINCT measurement within one
/// generation and application revision (REVIEW.md K01). Exempting fixtures from the
/// production rule was explicitly rejected.
private let tcSeqReadbackOrdinal = TcSeqOrdinalCounter()

final class TcSeqOrdinalCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value: UInt64 = 0
    func next() -> UInt64 { lock.lock(); defer { lock.unlock() }; value += 1; return value }
}

func tcSeqStableReadback(duration: Double = 0.01,
                         iso: Double = 100,
                         focus: Double = 0.5,
                         gains: WhiteBalanceGains = WhiteBalanceGains(red: 2.0, green: 1.0, blue: 1.5),
                         exposureAdjusting: Bool? = false,
                         focusAdjusting: Bool? = false,
                         wbAdjusting: Bool? = false) -> BaselineReadback {
    let ordinal = tcSeqReadbackOrdinal.next()
    return BaselineReadback(monotonicSeconds: 0,
                     measurementIdentity: BaselineReadback.MeasurementIdentity(
                        generationValue: 0,
                        requestRevision: 1,
                        sourceTimestamp: Date(timeIntervalSince1970: 1_700_000_000 + Double(ordinal))),
                     isExposureAdjusting: exposureAdjusting,
                     isFocusAdjusting: focusAdjusting,
                     isWhiteBalanceAdjusting: wbAdjusting,
                     durationSeconds: duration,
                     iso: iso,
                     focusPosition: focus,
                     whiteBalanceGains: gains,
                     provenance: .settledDeviceReadback)
}

func tcSeqCapability(minDuration: Double = 1.0 / 8000.0,
                     maxDuration: Double = 1.0,
                     minISO: Double = 32,
                     maxISO: Double = 3200,
                     supportsManualFocus: Bool = true) -> SequenceCapabilityContext {
    SequenceCapabilityContext(
        exposureLimits: ExposureLimits(minDurationSeconds: minDuration,
                                       maxDurationSeconds: maxDuration,
                                       minISO: minISO,
                                       maxISO: maxISO,
                                       minBiasEV: -8,
                                       maxBiasEV: 8),
        focusLimits: FocusLimits(supportsCustomLensPosition: supportsManualFocus,
                                 supportsPointOfInterest: true,
                                 supportsContinuousAutoFocus: true,
                                 supportsAutoFocus: true,
                                 positionZeroDirectionVerified: false),
        supportsCustomExposureMode: true,
        supportedExposureModes: [.auto, .shutterPriority, .isoPriority, .manual])
}

func tcSeqAdmission(testedBracketCounts: Set<Int>? = nil,
                    testedMinimumIntervalSeconds: Double? = nil,
                    testedMaximumBracketCount: Int? = nil) -> SequenceAdmissionPolicy {
    var policy = SequenceAdmissionPolicy.provisional
    if let testedBracketCounts {
        policy.testedNativeBracketCounts = .available(testedBracketCounts)
    }
    if let testedMinimumIntervalSeconds {
        policy.testedMinimumIntervalSeconds = .available(testedMinimumIntervalSeconds)
    }
    policy.testedMaximumBracketCount = testedMaximumBracketCount
    return policy
}

func tcSeqSettings(exposure: ExposureChoice = .auto,
                   biasEV: Double = 0,
                   focus: FocusIntent = FocusIntent(mode: .continuousAuto,
                                                    position: nil,
                                                    pointOfInterest: nil),
                   whiteBalance: WhiteBalanceIntent = WhiteBalanceIntent(mode: .auto,
                                                                        temperatureAndTint: nil))
    -> SequenceSettingsSnapshot {
    SequenceSettingsSnapshot(
        configurationGeneration: SeqTestSupport.configurationGeneration,
        revision: 1,
        exposure: exposure,
        biasEV: biasEV,
        focus: focus,
        whiteBalance: whiteBalance,
        maxDimensions: PixelDimensions(width: 4032, height: 3024))
}

let tcSeqManualSettings = tcSeqSettings(
    exposure: .manual(durationSeconds: 0.01, iso: 100),
    focus: FocusIntent(mode: .manual, position: 0.5, pointOfInterest: nil),
    whiteBalance: WhiteBalanceIntent(mode: .manual,
                                     temperatureAndTint: WhiteBalanceTemperatureAndTint(
                                        temperature: 5500, tint: 0)))

func tcSeqPlan(kind: SequencePlanKind,
               specification: SequenceSpecification,
               sequenceID: SequenceID = SequenceID(),
               camera: PhysicalCameraKind = .wide) -> SequencePlan {
    SequencePlan(sequenceID: sequenceID,
                 libraryID: SeqTestSupport.libraryID,
                 configurationGeneration: SeqTestSupport.configurationGeneration,
                 rootGeneration: RootGeneration(1),
                 physicalCameraKind: camera,
                 kind: kind,
                 specification: specification,
                 createdAtUTC: SeqTestSupport.nowUTC)
}

func tcSeqIntervalPlan(count: Int, intervalSeconds: Double, sequenceID: SequenceID = SequenceID()) -> SequencePlan {
    tcSeqPlan(kind: .interval,
              specification: .interval(IntervalPlan(count: count, intervalSeconds: intervalSeconds)),
              sequenceID: sequenceID)
}

func tcSeqTimerPlan(delaySeconds: Double, sequenceID: SequenceID = SequenceID()) -> SequencePlan {
    tcSeqPlan(kind: .timer,
              specification: .timer(TimerPlan(delaySeconds: delaySeconds)),
              sequenceID: sequenceID)
}

func tcSeqBracketPlan(count: Int = 3,
                      stepEV: Double = 1,
                      path: ExposureBracketPath = .native,
                      sequenceID: SequenceID = SequenceID()) -> SequencePlan {
    tcSeqPlan(kind: .exposureBracket,
              specification: .exposureBracket(ExposureBracketPlan(count: count,
                                                                  stepEV: stepEV,
                                                                  path: path)),
              sequenceID: sequenceID)
}

func tcSeqFocusPlan(count: Int = 5,
                    start: Double = 0.2,
                    end: Double = 0.8,
                    sequenceID: SequenceID = SequenceID()) -> SequencePlan {
    tcSeqPlan(kind: .focusBracket,
              specification: .focusBracket(FocusBracketPlan(count: count,
                                                            startPosition: start,
                                                            endPosition: end)),
              sequenceID: sequenceID)
}

// MARK: - Metadata / receipt fixtures

extension CaptureMode {
    /// Test-only projection used when building synthetic source metadata.
    var tcSeqSequenceKind: SequenceKind {
        switch self {
        case .exposureBracketSource: return .exposureBracket
        case .focusBracketSource: return .focusBracket
        case .intervalSource, .timer, .single: return .interval
        }
    }
}

func tcSeqMetadata(intent: CaptureIntent,
                   plannedCount: Int,
                   status: AcquisitionStatus) -> SourceCaptureMetadata {
    var sequenceLink: SourceSequenceLink?
    if let sequenceID = intent.sequenceID, let ordinal = intent.sequenceOrdinal {
        sequenceLink = SourceSequenceLink(id: sequenceID,
                                          kind: intent.mode.tcSeqSequenceKind,
                                          index: ordinal,
                                          plannedCount: plannedCount,
                                          requestedOffsetEV: intent.requestedOffsetEV,
                                          deadlineOrdinal: intent.deadlineOrdinal)
    }
    let focusObserved = FocusObservedRecord(
        position: intent.focus.position,
        provenance: intent.focus.position == nil ? .unknown : .requested)
    return SourceCaptureMetadata(
        captureID: intent.captureID,
        libraryID: intent.libraryID,
        capturedAtUTC: intent.createdAtUTC,
        capturedAtProvenance: intent.capturedAtProvenance,
        timezoneOffsetSeconds: intent.timezoneOffsetSeconds,
        format: SourceFormatRecord(rawPixelFormat: 0x4247_4734),
        deviceModel: "TEST-device-model",
        osVersion: "TEST-os",
        cameraDeviceType: "AVCaptureDeviceTypeBuiltInWideAngleCamera",
        requested: CaptureRequestRecord(
            maxDimensions: intent.requestedDimensions,
            exposure: ExposureRequestRecord(mode: intent.exposure.mode,
                                            durationSeconds: intent.exposure.durationTargetSeconds,
                                            iso: intent.exposure.isoTarget,
                                            biasEV: intent.biasEV),
            focus: FocusRequestRecord(mode: intent.focus.mode, position: intent.focus.position),
            whiteBalance: WhiteBalanceRequestRecord(
                mode: intent.whiteBalance.mode,
                temperatureKelvin: intent.whiteBalance.temperatureAndTint?.temperature,
                tint: intent.whiteBalance.temperatureAndTint?.tint)),
        observed: SourceObservedRecord(
            rawDimensions: PixelDimensions(width: 4032, height: 3024),
            durationSeconds: intent.exposure.durationTargetSeconds,
            iso: intent.exposure.isoTarget,
            aperture: 1.6,
            focalLengthMM: 6.765,
            orientation: 1,
            focus: focusObserved,
            whiteBalance: WhiteBalanceObservedRecord(gains: nil, provenance: .unknown)),
        acquisitionStatus: status,
        sequence: sequenceLink,
        equivalentFocalLengthMM: intent.equivalentFocalLengthMM)
}

let tcSeqDigest = SHA256Digest(hex: String(repeating: "b", count: 64))!

func tcSeqRelativeOriginalPath(_ captureID: CaptureID, capturedAt: Date) -> String {
    LibraryLayout.relativeOriginalPath(for: captureID,
                                       capturedAt: capturedAt,
                                       calendar: SeqTestSupport.calendar)
}

func tcSeqReceipt(intent: CaptureIntent, plannedCount: Int) -> CommitReceipt {
    let relative = tcSeqRelativeOriginalPath(intent.captureID, capturedAt: intent.createdAtUTC)
    return CommitReceipt(
        transactionID: TransactionID(),
        captureID: intent.captureID,
        libraryID: intent.libraryID,
        rootGeneration: intent.rootGeneration,
        relativeOriginalPath: relative,
        relativeSidecarPath: LibraryLayout.relativeSidecarPath(alongside: relative),
        verifiedByteCount: 4096,
        verifiedSHA256: tcSeqDigest,
        isOriginalAvailable: true,
        commitObservedAtUTC: intent.createdAtUTC,
        metadata: tcSeqMetadata(intent: intent, plannedCount: plannedCount, status: .complete))
}

func tcSeqStagedHandle(intent: CaptureIntent, plannedCount: Int) -> StagedSourceHandle {
    let relative = tcSeqRelativeOriginalPath(intent.captureID, capturedAt: intent.createdAtUTC)
    return StagedSourceHandle(
        transactionID: TransactionID(),
        captureID: intent.captureID,
        libraryID: intent.libraryID,
        pendingRelativePath: "pending/\(intent.captureID.description).dng",
        byteCount: 4096,
        sha256: tcSeqDigest,
        metadata: tcSeqMetadata(intent: intent,
                                plannedCount: plannedCount,
                                status: .partialWithRetainedSource),
        acquisitionTerminalStatus: .partialWithRetainedSource(errorDescription: "retained"),
        originRootGeneration: intent.rootGeneration,
        intendedRelativeOriginalPath: relative)
}

// MARK: - Fakes

/// Executor + persister with named-phase failure injection, virtual-time cost
/// and an optional barrier so a test can observe an in-flight save.
actor SeqFakeExecutor: SingleCaptureExecuting, DeliveredSourcePersisting {
    private let clock: VirtualMonotonicClock
    private var acquisitionSeconds: Double
    private var saveSeconds: Double
    private var failurePhases: [SingleCapturePhase]
    private var failureOrdinals: Set<Int>
    private var plannedCount: Int

    private var submitted: [CaptureIntent] = []
    private var persisted: [CaptureIntent] = []
    private var inFlight = 0
    private var peakInFlight = 0

    private var isBlocking = false
    private var released = false
    private var blockContinuation: CheckedContinuation<Void, Never>?
    private var blockedWaiterCount = 0
    private var completedCount = 0

    init(clock: VirtualMonotonicClock,
         acquisitionSeconds: Double = 0,
         saveSeconds: Double = 0,
         failurePhases: [SingleCapturePhase] = [],
         failureOrdinals: Set<Int> = [],
         plannedCount: Int = 1) {
        self.clock = clock
        self.acquisitionSeconds = acquisitionSeconds
        self.saveSeconds = saveSeconds
        self.failurePhases = failurePhases
        self.failureOrdinals = failureOrdinals
        self.plannedCount = plannedCount
    }

    var submittedIntents: [CaptureIntent] { submitted }
    var submittedCount: Int { submitted.count }
    var persistedIntents: [CaptureIntent] { persisted }
    var persistedCount: Int { persisted.count }
    var peakConcurrency: Int { peakInFlight }
    var blockedCount: Int { blockedWaiterCount }
    var completed: Int { completedCount }

    func setSaveSeconds(_ seconds: Double) { saveSeconds = seconds }
    func setAcquisitionSeconds(_ seconds: Double) { acquisitionSeconds = seconds }
    func setFailurePhases(_ phases: [SingleCapturePhase]) { failurePhases = phases }
    func setFailureOrdinals(_ ordinals: Set<Int>) { failureOrdinals = ordinals }
    func setPlannedCount(_ count: Int) { plannedCount = count }

    func setBlocking(_ value: Bool) {
        isBlocking = value
        if !value {
            released = true
            blockContinuation?.resume()
            blockContinuation = nil
        }
    }

    func release() {
        released = true
        blockContinuation?.resume()
        blockContinuation = nil
    }

    func execute(_ intent: CaptureIntent) async -> SingleCaptureExecutionResult {
        submitted.append(intent)
        await performWork()
        return result(for: intent)
    }

    func persist(_ representation: DeliveredRAWRepresentation,
                 intent: CaptureIntent) async -> SingleCaptureExecutionResult {
        persisted.append(intent)
        await performWork()
        return result(for: intent)
    }

    private func performWork() async {
        inFlight += 1
        peakInFlight = max(peakInFlight, inFlight)
        if isBlocking, !released {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                if released {
                    continuation.resume()
                } else {
                    blockContinuation = continuation
                    blockedWaiterCount += 1
                }
            }
        }
        if acquisitionSeconds > 0 { clock.advance(by: acquisitionSeconds) }
        if saveSeconds > 0 { clock.advance(by: saveSeconds) }
        inFlight -= 1
        completedCount += 1
    }

    private func result(for intent: CaptureIntent) -> SingleCaptureExecutionResult {
        let ordinal = intent.sequenceOrdinal?.value ?? -1
        let shouldFail = !failurePhases.isEmpty
            && (failureOrdinals.isEmpty || failureOrdinals.contains(ordinal))
        guard shouldFail, let phase = failurePhases.first else {
            let receipt = tcSeqReceipt(intent: intent, plannedCount: plannedCount)
            return SingleCaptureExecutionResult(
                captureID: intent.captureID,
                terminalStatus: .success,
                persistence: .committed(receipt),
                stagedHandle: nil,
                receipt: receipt,
                failure: nil)
        }
        switch phase {
        case .acquisition:
            let failure = CaptureFailure(kind: .captureFailed(detail: "synthetic native terminal error"),
                                         operation: "test.acquisition")
            return SingleCaptureExecutionResult(
                captureID: intent.captureID,
                terminalStatus: .failed(errorDescription: "synthetic native terminal error"),
                persistence: .failed(failure: failure),
                stagedHandle: nil,
                receipt: nil,
                failure: failure)
        case .representation:
            let failure = CaptureFailure(kind: .representationUnavailable(detail: "synthetic unusable representation"),
                                         operation: "test.representation")
            return SingleCaptureExecutionResult(
                captureID: intent.captureID,
                terminalStatus: .partialWithRetainedSource(errorDescription: "representation unusable"),
                persistence: .representationReceived,
                stagedHandle: nil,
                receipt: nil,
                failure: failure)
        case .staging:
            let failure = CaptureFailure(kind: .localStorageFull(detail: "synthetic staging failure"),
                                         operation: "test.staging")
            return SingleCaptureExecutionResult(
                captureID: intent.captureID,
                terminalStatus: .partialWithRetainedSource(errorDescription: "staging failed"),
                persistence: .failed(failure: failure),
                stagedHandle: nil,
                receipt: nil,
                failure: failure)
        case .commit, .verification:
            let handle = tcSeqStagedHandle(intent: intent, plannedCount: plannedCount)
            let retained = RetainedSourceStatus.durableInternalStaging(
                relativePath: handle.pendingRelativePath)
            let failure = CaptureFailure(kind: .providerIOFailed(detail: "synthetic commit failure"),
                                         operation: "test.commit",
                                         retainedSourceStatus: retained)
            return SingleCaptureExecutionResult(
                captureID: intent.captureID,
                terminalStatus: .partialWithRetainedSource(errorDescription: "commit failed"),
                persistence: .pendingRetry(failure: failure, retained: retained),
                stagedHandle: handle,
                receipt: nil,
                failure: failure)
        }
    }
}

final class SeqFakeSettings: SequenceSettingsControlling, @unchecked Sendable {
    private let lock = NSLock()
    private var current: SequenceSettingsSnapshot?
    private var settledBaseline: ExposureBaseline?
    private var applyFails = false
    private var prepareFocusEnabled = false
    private var restoreFails = false
    private var resetFailure: CaptureFailure?
    private var applyCountValue = 0
    private var restoreCountValue = 0
    private var resetCountValue = 0
    private var appliedSnapshots: [SequenceSettingsSnapshot] = []
    private var restoredSnapshots: [SequenceSettingsSnapshot] = []

    init(current: SequenceSettingsSnapshot?, settledBaseline: ExposureBaseline? = nil) {
        self.current = current
        self.settledBaseline = settledBaseline
    }

    var applyCount: Int { locked { applyCountValue } }
    var restoreCount: Int { locked { restoreCountValue } }
    var resetCount: Int { locked { resetCountValue } }
    var applied: [SequenceSettingsSnapshot] { locked { appliedSnapshots } }
    var restored: [SequenceSettingsSnapshot] { locked { restoredSnapshots } }

    func setCurrent(_ settings: SequenceSettingsSnapshot?) { locked { current = settings } }
    func setSettledBaseline(_ baseline: ExposureBaseline?) { locked { settledBaseline = baseline } }
    func setApplyFailure(_ value: Bool) { locked { applyFails = value } }
    func setRestoreFailure(_ value: Bool) { locked { restoreFails = value } }
    func setResetFailure(_ failure: CaptureFailure?) { locked { resetFailure = failure } }

    func snapshotCurrentSettings() async -> SequenceSettingsSnapshot? { locked { current } }

    func currentExposureBaseline() async -> ExposureBaseline? { locked { settledBaseline } }

    func setFocusPreparationEnabled(_ enabled: Bool) { locked { prepareFocusEnabled = enabled } }
    func prepareFocusLockForBaseline(_ prior: SequenceSettingsSnapshot) async -> Result<Bool, CaptureFailure> {
        guard locked({ prepareFocusEnabled }), let target = SequenceBaselineFocusPreparation.lockedSettings(prior, observedPosition: 0.5) else { return .success(false) }
        switch await apply(target) {
        case .success: return .success(true)
        case .failure(let failure): return .failure(failure)
        }
    }

    func apply(_ settings: SequenceSettingsSnapshot) async -> Result<Void, CaptureFailure> {
        let fails = locked { () -> Bool in
            applyCountValue += 1
            appliedSnapshots.append(settings)
            return applyFails
        }
        if fails {
            return .failure(CaptureFailure(kind: .invalidSettings(detail: "synthetic apply failure"),
                                           operation: "test.apply"))
        }
        locked { current = settings }
        return .success(())
    }

    func restore(_ settings: SequenceSettingsSnapshot) async -> Result<Void, CaptureFailure> {
        let fails = locked { () -> Bool in
            restoreCountValue += 1
            restoredSnapshots.append(settings)
            return restoreFails
        }
        if fails {
            return .failure(CaptureFailure(kind: .restorationFailed(detail: "synthetic restore failure"),
                                           operation: "test.restore"))
        }
        locked { current = settings }
        return .success(())
    }

    func resetToAuto() async -> Result<Void, CaptureFailure> {
        let failure = locked { () -> CaptureFailure? in
            resetCountValue += 1
            return resetFailure
        }
        if let failure { return .failure(failure) }
        locked { current = tcSeqSettings(exposure: .auto) }
        return .success(())
    }

    private func locked<T>(_ body: () -> T) -> T {
        lock.lock(); defer { lock.unlock() }
        return body()
    }
}

final class SeqFakeDocumentStore: SequenceDocumentStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var documents: [UUID: SequenceDocument] = [:]
    private var writes: [SequenceDocument] = []
    private var failedWriteCount = 0
    /// Writes with a zero-based index at or above this value fail.
    private var failWritesFromIndex: Int?
    private var rootStateValue: LibraryRootState
    private var readFailure: Error?

    init(rootState: LibraryRootState) {
        self.rootStateValue = rootState
    }

    var rootState: LibraryRootState { locked { rootStateValue } }
    var writeCount: Int { locked { writes.count } }
    var failedWrites: Int { locked { failedWriteCount } }
    var writtenDocuments: [SequenceDocument] { locked { writes } }

    func setRootState(_ state: LibraryRootState) { locked { rootStateValue = state } }
    func setFailWritesFromIndex(_ index: Int?) { locked { failWritesFromIndex = index } }
    func setReadFailure(_ error: Error?) { locked { readFailure = error } }

    func seed(_ document: SequenceDocument) {
        locked { documents[document.sequenceID] = document }
    }

    func latestDocument(_ sequenceID: SequenceID) -> SequenceDocument? {
        locked { documents[sequenceID.rawValue] }
    }

    func writeSequenceDocument(_ document: SequenceDocument) async throws {
        let shouldFail = locked { () -> Bool in
            if let limit = failWritesFromIndex, writes.count >= limit {
                failedWriteCount += 1
                return true
            }
            writes.append(document)
            documents[document.sequenceID] = document
            return false
        }
        if shouldFail { throw SeqTestError.documentWriteFailed }
    }

    func readSequenceDocument(_ sequenceID: SequenceID) async throws -> SequenceDocument {
        if let readFailure = locked({ readFailure }) { throw readFailure }
        guard let document = locked({ documents[sequenceID.rawValue] }) else {
            throw SeqTestError.documentMissing
        }
        return document
    }

    private func locked<T>(_ body: () -> T) -> T {
        lock.lock(); defer { lock.unlock() }
        return body()
    }
}

enum SeqTestError: Error, Hashable, Sendable {
    case documentWriteFailed
    case documentMissing
}

final class SeqFakeBracketSubmitter: BracketSubmitting, @unchecked Sendable {
    private let lock = NSLock()
    private var requests: [BracketSubmissionRequest] = []
    private var callbackContinuation: AsyncStream<BracketSourceCallback>.Continuation?
    private var terminalContinuation: AsyncStream<NativeRequestOutcome>.Continuation?
    private var submitFailure: CaptureFailure?
    private var submittedIdentitySets: [[NativeBracketIdentity]] = []

    var submittedRequests: [BracketSubmissionRequest] { locked { requests } }
    var submittedCount: Int { locked { requests.count } }
    var submittedIdentities: [[NativeBracketIdentity]] { locked { submittedIdentitySets } }

    func setSubmitFailure(_ failure: CaptureFailure?) { locked { submitFailure = failure } }

    func submit(_ request: BracketSubmissionRequest) async -> Result<BracketSubmission, CaptureFailure> {
        let identities = request.intents.enumerated().map { index, intent in
            NativeBracketIdentity(submittedIndex: index,
                                  kind: .manualExposure,
                                  requestedDurationSeconds: intent.exposure.durationTargetSeconds,
                                  requestedISO: intent.exposure.isoTarget,
                                  requestedBiasEV: nil)
        }
        let callbackStream = AsyncStream<BracketSourceCallback>.makeStream(bufferingPolicy: .unbounded)
        let terminalStream = AsyncStream<NativeRequestOutcome>.makeStream(bufferingPolicy: .unbounded)

        let failure: CaptureFailure? = locked { () -> CaptureFailure? in
            if let submitFailure { return submitFailure }
            requests.append(request)
            submittedIdentitySets.append(identities)
            callbackContinuation = callbackStream.continuation
            terminalContinuation = terminalStream.continuation
            return nil
        }
        if let failure { return .failure(failure) }
        return .success(BracketSubmission(submittedIdentities: identities,
                                          callbacks: callbackStream.stream,
                                          terminal: terminalStream.stream))
    }

    func push(_ callback: BracketSourceCallback) {
        locked { callbackContinuation }?.yield(callback)
    }

    func finishCallbacks() {
        locked { callbackContinuation }?.finish()
    }

    func finishTerminal(_ outcome: NativeRequestOutcome) {
        let continuation = locked { terminalContinuation }
        continuation?.yield(outcome)
        continuation?.finish()
    }

    private func locked<T>(_ body: () -> T) -> T {
        lock.lock(); defer { lock.unlock() }
        return body()
    }
}

func tcSeqRepresentation(_ intent: CaptureIntent,
                         captureIDOverride: CaptureID? = nil) -> DeliveredRAWRepresentation {
    DeliveredRAWRepresentation(
        bytes: Data([0x00, 0x01, 0x02, 0x03]),
        captureID: captureIDOverride ?? intent.captureID,
        resolvedSettingsUniqueID: 42,
        nativeBracketIdentity: nil,
        rawPixelFormatType: 0x4247_4734,
        rawFileType: "com.adobe.raw-image",
        rawPhotoDimensions: PixelDimensions(width: 4032, height: 3024),
        rawPixelBufferDimensions: nil,
        timestampSeconds: 0,
        metadata: [:])
}

final class SeqFakeFocusController: FocusPositionControlling, @unchecked Sendable {
    private let lock = NSLock()
    private var moves: [Double] = []
    private var readbacksInCurrentMove = 0
    private var settlePlan: [Int?] = []
    private var failureDetail: String?
    private var totalReadbacks = 0

    func setSettlePlan(_ plan: [Int?]) { locked { settlePlan = plan } }
    func setFailureDetail(_ detail: String?) { locked { failureDetail = detail } }
    var requestedPositions: [Double] { locked { moves } }
    var readbackCount: Int { locked { totalReadbacks } }

    func beginMove(to position: Double) async -> Result<Void, CaptureFailure> {
        locked {
            moves.append(position)
            readbacksInCurrentMove = 0
        }
        return .success(())
    }

    func readback() async -> FocusSettleReadback? {
        locked { () -> FocusSettleReadback? in
            totalReadbacks += 1
            readbacksInCurrentMove += 1
            if let failureDetail {
                return FocusSettleReadback(position: nil,
                                           state: .failed(detail: failureDetail),
                                           provenance: .unknown)
            }
            let moveIndex = moves.count - 1
            guard moveIndex >= 0 else {
                return FocusSettleReadback(position: nil, state: .notStarted, provenance: .unknown)
            }
            let planned = moveIndex < settlePlan.count ? settlePlan[moveIndex] : nil
            if let planned, readbacksInCurrentMove >= planned {
                return FocusSettleReadback(position: moves[moveIndex],
                                           state: .settled,
                                           provenance: .settledDeviceReadback)
            }
            return FocusSettleReadback(position: nil, state: .adjusting, provenance: .unknown)
        }
    }

    private func locked<T>(_ body: () -> T) -> T {
        lock.lock(); defer { lock.unlock() }
        return body()
    }
}

final class SeqFakeBaselineSampler: BaselineSampling, @unchecked Sendable {
    private let lock = NSLock()
    private let provider: @Sendable (Int) -> BaselineReadback?
    private var count = 0

    init(_ provider: @escaping @Sendable (Int) -> BaselineReadback?) {
        self.provider = provider
    }

    var readCount: Int { locked { count } }

    func readback() async -> BaselineReadback? {
        let index = locked { () -> Int in
            let current = count
            count += 1
            return current
        }
        return provider(index)
    }

    private func locked<T>(_ body: () -> T) -> T {
        lock.lock(); defer { lock.unlock() }
        return body()
    }
}

struct SeqFakeBaselineSettler: SequenceBaselineSettling {
    let result: Result<SequenceBaselineSnapshot, BaselineSettlementFailure>
    let recorder: SequenceTestBox<[BaselineSettlementRequest]>

    func settle(_ request: BaselineSettlementRequest,
                cancellation: SequenceCancellationSignal) async -> Result<SequenceBaselineSnapshot,
                                                                         BaselineSettlementFailure> {
        recorder.mutate { $0.append(request) }
        return result
    }
}

struct SeqFakeCapabilityProvider: SequenceCapabilityProviding {
    let context: SequenceCapabilityContext

    func capabilityContext() async -> SequenceCapabilityContext { context }
}

// MARK: - Harness

final class SeqHarness: @unchecked Sendable {
    let clock: VirtualMonotonicClock
    let executor: SeqFakeExecutor
    let pipeline: SequenceSourcePipeline
    let settings: SeqFakeSettings
    let store: SeqFakeDocumentStore
    let bracketSubmitter: SeqFakeBracketSubmitter
    let focusController: SeqFakeFocusController
    let sampler: any BaselineSampling
    let coordinator: SequenceCoordinator

    init(capability: SequenceCapabilityContext = tcSeqCapability(),
         admission: SequenceAdmissionPolicy = .provisional,
         priorSettings: SequenceSettingsSnapshot? = tcSeqSettings(),
         settledBaseline: ExposureBaseline? = nil,
         baselineSampler: (any BaselineSampling)? = nil,
         baselineSettlerOverride: (any SequenceBaselineSettling)? = nil,
         rootState: LibraryRootState = SeqTestSupport.writableRoot,
         plannedCount: Int = 1,
         executorClock: VirtualMonotonicClock? = nil,
         cancellationCheckIntervalSeconds: Double = 0.5) {
        let clock = executorClock ?? VirtualMonotonicClock()
        self.clock = clock
        let executor = SeqFakeExecutor(clock: clock, plannedCount: plannedCount)
        self.executor = executor
        let pipeline = SequenceSourcePipeline(executor: executor, persister: executor)
        self.pipeline = pipeline
        let settings = SeqFakeSettings(current: priorSettings, settledBaseline: settledBaseline)
        self.settings = settings
        let store = SeqFakeDocumentStore(rootState: rootState)
        self.store = store
        let bracketSubmitter = SeqFakeBracketSubmitter()
        self.bracketSubmitter = bracketSubmitter
        let focusController = SeqFakeFocusController()
        self.focusController = focusController
        let sampler: any BaselineSampling = baselineSampler
            ?? SeqFakeBaselineSampler { _ in tcSeqStableReadback() }
        self.sampler = sampler
        let settler: any SequenceBaselineSettling = baselineSettlerOverride
            ?? BaselineSettler(clock: clock, sampler: sampler)
        let focusDriver = FocusBracketDriver(clock: clock,
                                             controller: focusController,
                                             pipeline: pipeline)
        self.coordinator = SequenceCoordinator(environment: SequenceCoordinator.Environment(
            clock: clock,
            wallClock: FixedWallClock(instant: SeqTestSupport.nowUTC),
            storage: store,
            pipeline: pipeline,
            settings: settings,
            baselineSettler: settler,
            bracketSubmitter: bracketSubmitter,
            focusDriver: focusDriver,
            capability: SeqFakeCapabilityProvider(context: capability),
            admission: admission,
            cancellationCheckIntervalSeconds: cancellationCheckIntervalSeconds))
    }

    /// Runs `start` while driving the virtual clock until the run settles.
    func runToCompletion(_ plan: SequencePlan) async -> SequenceRunResult {
        let box = SequenceTestBox<SequenceRunResult?>(nil)
        let coordinator = self.coordinator
        let task = Task {
            let result = await coordinator.start(plan)
            box.set(result)
        }
        _ = await driveVirtualClock(clock) { box.value != nil }
        _ = await task.value
        if let result = box.value { return result }
        // The run never settled; fail the case loudly through a synthetic result.
        return await coordinator.start(plan)
    }

    /// Runs `start` while driving the clock, letting the caller observe the
    /// halfway point before the run settles.
    func runDriving(_ plan: SequencePlan,
                    observe: @Sendable (SequenceCoordinatorSnapshot) -> Void = { _ in })
        async -> SequenceRunResult {
        let box = SequenceTestBox<SequenceRunResult?>(nil)
        let coordinator = self.coordinator
        let task = Task {
            let result = await coordinator.start(plan)
            box.set(result)
        }
        _ = await driveVirtualClock(clock) {
            let snapshot = await coordinator.snapshot()
            observe(snapshot)
            return box.value != nil
        }
        _ = await task.value
        if let result = box.value { return result }
        return await coordinator.start(plan)
    }
}

// MARK: - Suite

enum SequenceSuite {
    static let suite = TCSuite(
        id: "Sequence-T25-T30",
        title: "Sequence coordination state machines (timer, interval, brackets, restoration)",
        cases: [

            TCCase(id: "BL36", title: "Active baseline measurement catches genuinely converged short windows without dropping five-readback proof") { r in
                for interval in [0.25, SequenceSettlementPolicy().readbackPollIntervalSeconds] {
                    let clock = VirtualMonotonicClock()
                    // A real continuous Auto mode may resume metering after a
                    // quiet window. Polling at UI cadence cannot prove that window.
                    let sampler = SeqFakeBaselineSampler { _ in
                        let quiet = clock.now() >= 0.09 && clock.now() < 0.46
                        return tcSeqStableReadback(wbAdjusting: !quiet)
                    }
                    var policy = BaselineSettlementPolicy.initial
                    policy.settlement.readbackPollIntervalSeconds = interval
                    let settler = BaselineSettler(clock: clock, sampler: sampler, policy: policy)
                    let request = BaselineSettlementRequest(sequenceID: SequenceID(), intent: .freezeNumeric,
                        requirements: [.exposure, .focus, .whiteBalance], longestPlannedDurationSeconds: 0.01,
                        fallbackExposure: .auto, fallbackFocus: FocusIntent(mode: .manual, position: 0.5, pointOfInterest: nil),
                        fallbackWhiteBalance: WhiteBalanceIntent(mode: .auto, temperatureAndTint: nil),
                        maxDimensions: PixelDimensions(width: 4032, height: 3024), explicitBaseline: nil)
                    let box = SequenceTestBox<Result<SequenceBaselineSnapshot, BaselineSettlementFailure>?>(nil)
                    let task = Task { box.set(await settler.settle(request, cancellation: SequenceCancellationSignal())) }
                    _ = await driveVirtualClock(clock, step: 0.01) { box.value != nil }
                    await task.value
                    if interval < 0.1 {
                        if case .success(let snapshot) = box.value {
                            r.equal("all five distinct converged samples retained", snapshot.stableSampleCount, 5)
                            r.equal("native exposure remains the measured numeric value", snapshot.exposure, .manual(durationSeconds: 0.01, iso: 100))
                            r.equal("settled provenance only after proof", snapshot.provenance, .settledDeviceReadback)
                            r.check("no imposed one-second baseline floor", clock.now() < 0.46)
                        } else { r.check("active sampler catches the stable window", false, String(describing: box.value)) }
                    } else {
                        if case .failure = box.value { r.check("previous slow cadence reproduces baseline failure", true) }
                        else { r.check("previous slow cadence reproduces baseline failure", false) }
                    }
                }
                let moving = (0..<5).map { _ in tcSeqStableReadback(wbAdjusting: true) }
                let report = BaselineSettler.stabilityReport(window: moving, requirements: [.whiteBalance], policy: .initial)
                r.check("ongoing AWB cannot be called settled", !report.isStable)
                r.check("failure names the adjusting component", report.summary.contains("WB=5"))
            },

            TCCase(id: "BL35", title: "A real Auto-focus lock precedes baseline measurement; failed preparation or settlement restores prior settings") { r in
                let surface = BaselineLockRecordingSurface()
                let adapter = CameraSequenceSettingsControl(camera: surface)
                let prior = tcSeqSettings(focus: FocusIntent(mode: .continuousAuto, position: nil, pointOfInterest: nil))
                let prepared = await adapter.prepareFocusLockForBaseline(prior)
                if case .success(let changed) = prepared { r.check("shipping adapter reports native settings change", changed) }
                else { r.check("shipping adapter prepares focus", false) }
                let nativeTarget = await surface.applied.first
                r.equal("shipping adapter locks actual measured target", nativeTarget?.focus.mode, .manual)
                r.equal("shipping adapter uses fresh native position", nativeTarget?.focus.position, 0.47)
                r.equal("exposure intent stays unchanged until measured", nativeTarget?.exposure, prior.exposure)
                for bad in [BaselineLockRecordingSurface(age: 2), BaselineLockRecordingSurface(position: nil),
                            BaselineLockRecordingSurface(revisionOffset: 1), BaselineLockRecordingSurface(generationOffset: 1)] {
                    let refused = await CameraSequenceSettingsControl(camera: bad).prepareFocusLockForBaseline(prior)
                    if case .failure = refused { r.check("stale/missing/foreign seed refused", true) }
                    else { r.check("stale/missing/foreign seed refused", false) }
                    r.equal("no invented native focus target", await bad.applied.count, 0)
                }
                for prepare in [false, true] {
                    let relay = SequenceTestBox<SeqFakeSettings?>(nil)
                    let sampler = SeqFakeBaselineSampler { _ in
                        let locked = relay.value?.applied.first?.focus.mode == .manual
                        return tcSeqStableReadback(focus: locked ? 0.5 : 0.51569, focusAdjusting: !locked)
                    }
                    let h = SeqHarness(priorSettings: tcSeqSettings(), baselineSampler: sampler, plannedCount: 3)
                    relay.set(h.settings); h.settings.setFocusPreparationEnabled(prepare)
                    let result = await h.runToCompletion(tcSeqBracketPlan(count: 3, stepEV: 1, path: .serial))
                    r.equal("AF preparation discriminates the reported timeout", result.status, prepare ? .complete : .failed)
                    r.equal("only locked baseline submits", await h.executor.submittedCount, prepare ? 3 : 0)
                    if prepare {
                        r.equal("real measured focus target locked first", h.settings.applied.first?.focus.mode, .manual)
                        r.equal("fake native measurement supplies target", h.settings.applied.first?.focus.position, 0.5)
                        r.equal("restoration follows successful run", result.restoration, .restored)
                        r.equal("original Auto focus restored", h.settings.restored.last?.focus.mode, .continuousAuto)
                    }
                }
                let failed = SeqHarness(priorSettings: tcSeqSettings(), baselineSampler: SeqFakeBaselineSampler { _ in nil }, plannedCount: 3)
                failed.settings.setFocusPreparationEnabled(true)
                let result = await failed.runToCompletion(tcSeqBracketPlan(count: 3, stepEV: 1, path: .serial))
                r.equal("missing post-lock readings still fail", result.status, .failed)
                r.equal("failed settlement restores touched settings", result.restoration, .restored)
                r.equal("no photo without settled baseline", await failed.executor.submittedCount, 0)
                r.equal("restore happens once", failed.settings.restoreCount, 1)
            },
            TCCase(id: "EB33", title: "Serial exposure bracket on fixed-focus hardware never requests unsupported focus positions") { r in
                let h = SeqHarness(capability: tcSeqCapability(supportsManualFocus: false),
                    priorSettings: tcSeqSettings(), plannedCount: 3)
                let result = await h.runToCompletion(tcSeqBracketPlan(count: 3, stepEV: 1, path: .serial))
                r.equal("all original sources complete", result.status, .complete)
                r.equal("all commits retained", result.progress.committedCount, 3)
                let intents = await h.executor.submittedIntents
                r.equal("distinct exposure offsets", intents.compactMap(\.requestedOffsetEV), [-1,0,1])
                r.check("fixed lens not asked for custom position", intents.allSatisfy { $0.focus.mode != .manual && $0.focus.position == nil })
                r.equal("prior settings restored", result.restoration, .restored)
            },
            TCCase(id: "FC32", title: "Sequence sources retain the frozen native nominal equivalent without model guesses") { r in
                for equivalent: Double? in [120, 77, nil, 0, -.infinity, .nan] {
                    let h = SeqHarness(priorSettings: tcSeqSettings(), plannedCount: 1)
                    let plan = SequencePlan(libraryID: SeqTestSupport.libraryID,
                        configurationGeneration: SeqTestSupport.configurationGeneration,
                        rootGeneration: RootGeneration(1), physicalCameraKind: .telephoto,
                        kind: .timer, specification: .timer(TimerPlan(delaySeconds: 0)),
                        createdAtUTC: SeqTestSupport.nowUTC,
                        nominalEquivalentFocalLengthMM: equivalent)
                    let result = await h.runToCompletion(plan)
                    r.equal("timer source completed", result.status, .complete)
                    let intents = await h.executor.submittedIntents
                    r.equal("one source", intents.count, 1)
                    let expected = equivalent.flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
                    r.equal("source uses only frozen valid equivalent", intents.first?.equivalentFocalLengthMM, expected)
                    r.equal("physical action is independent of focal label", intents.first?.physicalCameraKind, .telephoto)
                }
            },

            TCCase(id: "UX06", title: "Missing initial bracket baseline settles fresh samples before three serial RAW sources") { r in
                let h = SeqHarness(priorSettings: tcSeqSettings(), settledBaseline: nil, plannedCount: 3)
                let result = await h.runToCompletion(tcSeqBracketPlan(count: 3,stepEV:1,path:.serial))
                r.equal("complete after settlement", result.status, .complete)
                let intents = await h.executor.submittedIntents
                r.equal("three separate sources", intents.count, 3)
                r.equal("explicit offsets retained", intents.compactMap(\.requestedOffsetEV), [-1,0,1])
                r.check("unique original identities", Set(intents.map(\.captureID)).count == 3)
                r.equal("committed sources", result.progress.committedCount, 3)
                r.equal("settings restored", result.restoration, .restored)
            },
            TCCase(id: "UX07", title: "Deferring a missing baseline never bypasses the settled bracket's exposure limits") { r in
                let h = SeqHarness(capability: tcSeqCapability(minDuration: 0.000125,maxDuration: 0.015,minISO:32,maxISO:3200),
                    priorSettings:tcSeqSettings(),settledBaseline:nil,plannedCount:3)
                let result = await h.runToCompletion(tcSeqBracketPlan(count:3,stepEV:1,path:.serial))
                r.equal("illegal settled positive offset refused",result.status,.failed)
                r.check("range reason retained",result.validationErrors.contains { if case .bracketDurationOutOfRange = $0 { return true }; return false })
                r.equal("no originals acquired",await h.executor.submittedCount,0)
                r.equal("no illegal settings applied",h.settings.applyCount,0)
            },
            // MARK: T25 — timer cancellation before/after submission

            TCCase(id: "T25a",
                   title: "Sequence timer: user cancel just before the deadline means zero frames") { r in
                let h = SeqHarness(priorSettings: tcSeqSettings())
                let plan = tcSeqTimerPlan(delaySeconds: 3)
                let box = SequenceTestBox<SequenceRunResult?>(nil)
                let coordinator = h.coordinator
                let task = Task { box.set(await coordinator.start(plan)) }

                let countdownSeen = await driveVirtualClock(h.clock) {
                    let snapshot = await coordinator.snapshot()
                    if case .running(let progress) = snapshot.state,
                       case .countdown = progress.phase {
                        return true
                    }
                    return false
                }
                r.check("timer publishes a visible countdown deadline", countdownSeen)

                await coordinator.cancel(sequenceID: plan.sequenceID)
                _ = await driveVirtualClock(h.clock) { box.value != nil }
                _ = await task.value

                let result = box.value
                r.equal("zero frames submitted", await h.executor.submittedCount, 0)
                r.equal("terminal status is cancelled", result?.status, .cancelled)
                r.equal("nothing committed", result?.progress.committedCount, 0)
                let finalState = await coordinator.snapshot().state
                if case .cancelled = finalState {
                    r.check("state is cancelled", true)
                } else {
                    r.check("state is cancelled", false, "state was \(finalState)")
                }
            },

            TCCase(id: "T25b",
                   title: "Sequence timer: backgrounding just before the deadline means zero frames") { r in
                let h = SeqHarness(priorSettings: tcSeqSettings())
                let plan = tcSeqTimerPlan(delaySeconds: 3)
                let box = SequenceTestBox<SequenceRunResult?>(nil)
                let coordinator = h.coordinator
                let task = Task { box.set(await coordinator.start(plan)) }

                _ = await driveVirtualClock(h.clock) {
                    let snapshot = await coordinator.snapshot()
                    if case .running(let progress) = snapshot.state, case .countdown = progress.phase {
                        return true
                    }
                    return false
                }
                await coordinator.interrupt(reason: .background)
                _ = await driveVirtualClock(h.clock) { box.value != nil }
                _ = await task.value

                r.equal("zero frames submitted", await h.executor.submittedCount, 0)
                r.equal("terminal status is interrupted", box.value?.status, .interrupted)
                if case .interrupted(_, let reason) = await coordinator.snapshot().state {
                    r.equal("interruption reason recorded", reason, .background)
                } else {
                    r.check("state is interrupted", false)
                }
            },

            TCCase(id: "T25c",
                   title: "Sequence timer: lens switch just before the deadline cancels the countdown") { r in
                let h = SeqHarness(priorSettings: tcSeqSettings())
                let plan = tcSeqTimerPlan(delaySeconds: 3)
                let box = SequenceTestBox<SequenceRunResult?>(nil)
                let coordinator = h.coordinator
                let task = Task { box.set(await coordinator.start(plan)) }

                _ = await driveVirtualClock(h.clock) {
                    let snapshot = await coordinator.snapshot()
                    if case .running(let progress) = snapshot.state, case .countdown = progress.phase {
                        return true
                    }
                    return false
                }
                await coordinator.interrupt(reason: .lensSwitch)
                _ = await driveVirtualClock(h.clock) { box.value != nil }
                _ = await task.value

                r.equal("zero frames submitted", await h.executor.submittedCount, 0)
                r.equal("terminal status is interrupted", box.value?.status, .interrupted)
            },

            TCCase(id: "T25d",
                   title: "Sequence timer: an already-submitted frame is allowed and saved, with no later burst") { r in
                let h = SeqHarness(priorSettings: tcSeqSettings())
                await h.executor.setBlocking(true)
                let plan = tcSeqTimerPlan(delaySeconds: 3)
                let box = SequenceTestBox<SequenceRunResult?>(nil)
                let coordinator = h.coordinator
                let task = Task { box.set(await coordinator.start(plan)) }

                let submitted = await driveVirtualClock(h.clock) {
                    await h.executor.submittedCount == 1
                }
                r.check("the frame was submitted at the deadline", submitted)
                r.equal("exactly one frame is in flight", await h.executor.submittedCount, 1)

                await coordinator.cancel(sequenceID: plan.sequenceID)
                await h.executor.release()
                _ = await driveVirtualClock(h.clock) { box.value != nil }
                _ = await task.value

                let result = box.value
                r.equal("the submitted frame is saved", result?.progress.committedCount, 1)
                r.equal("status reflects the user cancel", result?.status, .cancelled)
                r.equal("no later frame is submitted", await h.executor.submittedCount, 1)
                r.equal("cancelled but every acquired source retained", result?.progress.retainedCount, 1)
            },

            // MARK: T26 — interval arithmetic

            TCCase(id: "T26a",
                   title: "Interval schedule: skipped deadlines are counted separately from source ordinals") { r in
                var schedule = IntervalSchedule(originMonotonic: 0, intervalSeconds: 5, plannedCount: 3)
                r.equal("first source is eligible at the origin", schedule.nextEligibleDeadlineTime, 0)
                r.equal("first deadline ordinal", schedule.currentDeadlineOrdinal, 0)

                // The first source is committed 12 s after the origin: two
                // deadlines elapsed while the pipeline was busy.
                schedule.recordCommitted(now: 12)
                r.equal("one committed source", schedule.committedSourceCount, 1)
                r.equal("deadlines 1 and 2 were skipped", schedule.skippedDeadlineCount, 2)
                r.equal("next eligible deadline is the third", schedule.currentDeadlineOrdinal, 3)
                r.equal("next eligible time", schedule.nextEligibleDeadlineTime, 15)

                // A delayed commit after the second source skips two more.
                schedule.recordCommitted(now: 27)
                r.equal("two committed sources", schedule.committedSourceCount, 2)
                r.equal("four deadlines skipped in total", schedule.skippedDeadlineCount, 4)
                r.equal("next eligible deadline ordinal", schedule.currentDeadlineOrdinal, 6)

                schedule.recordCommitted(now: 42)
                r.check("run finished at the requested source count", schedule.isFinished)
                r.equal("deadline ordinals actually used", schedule.usedDeadlineOrdinals, [0, 3, 6])
                r.equal("final skipped count", schedule.skippedDeadlineCount, 6)
                r.equal("planned count honoured", schedule.plannedCount, 3)
            },

            TCCase(id: "T26",
                   title: "Interval: a save lasting several periods causes no catch-up burst and finishes at the source count") { r in
                let h = SeqHarness(priorSettings: tcSeqSettings(), plannedCount: 3)
                await h.executor.setSaveSeconds(12)
                let plan = tcSeqIntervalPlan(count: 3, intervalSeconds: 5)

                let result = await h.runToCompletion(plan)

                r.equal("status is complete", result.status, .complete)
                r.equal("exactly the requested source count was committed", result.progress.committedCount, 3)
                r.equal("no source failed", result.progress.failedOrdinals, [])
                r.equal("deadline ordinals used", result.progress.deadlineOrdinalsUsed, [0, 3, 6])
                r.equal("skipped deadlines logged separately", result.progress.skippedDeadlineCount, 6)
                r.equal("only one frame per eligible deadline", await h.executor.submittedCount, 3)

                let document = h.store.latestDocument(plan.sequenceID)
                r.equal("document records the run as complete", document?.status, .complete)
                r.equal("document records the skipped deadlines", document?.skippedDeadlineCount, 6)
                r.equal("document records every committed source", document?.completedSources.count, 3)
                r.check("document records an end time", document?.endedAtUTC != nil)
                if let document {
                    let problems = SequenceDocumentSemanticValidator().validate(document)
                    r.check("interval document is semantically valid", problems.isEmpty,
                            problems.joined(separator: "; "))
                } else {
                    r.check("interval document is semantically valid", false, "no document")
                }

                // No two sources may start at the same virtual instant, and each
                // source must wait for its own eligible deadline.
                let submissionOrdinals = await h.executor.submittedIntents.compactMap { $0.deadlineOrdinal?.value }
                r.equal("each source carries its own deadline ordinal", submissionOrdinals, [0, 3, 6])
            },

            TCCase(id: "T26b",
                   title: "Interval: first source is at start and a fast pipeline keeps the cadence") { r in
                let h = SeqHarness(priorSettings: tcSeqSettings(), plannedCount: 3)
                await h.executor.setSaveSeconds(1)
                let plan = tcSeqIntervalPlan(count: 3, intervalSeconds: 5)
                let result = await h.runToCompletion(plan)

                r.equal("complete", result.status, .complete)
                r.equal("no deadlines skipped", result.progress.skippedDeadlineCount, 0)
                r.equal("deadline ordinals used", result.progress.deadlineOrdinalsUsed, [0, 1, 2])
                r.equal("three sources", await h.executor.submittedCount, 3)
                r.close("virtual time reached the last deadline", h.clock.now(), 11, tolerance: 1.5)
            },

            // MARK: T27 — cancel during a native burst

            TCCase(id: "T27",
                   title: "Sequence cancel during a native burst and in-flight save drains submitted sources") { r in
                let h = SeqHarness(admission: tcSeqAdmission(testedBracketCounts: [3]),
                                   priorSettings: tcSeqManualSettings,
                                   settledBaseline: ExposureBaseline(durationSeconds: 0.01, iso: 100),
                                   plannedCount: 3)
                await h.executor.setPlannedCount(3)
                await h.executor.setBlocking(true)
                let plan = tcSeqBracketPlan(count: 3, stepEV: 1, path: .native)
                let box = SequenceTestBox<SequenceRunResult?>(nil)
                let coordinator = h.coordinator
                let task = Task { box.set(await coordinator.start(plan)) }

                let submitted = await driveVirtualClock(h.clock) {
                    h.bracketSubmitter.submittedCount == 1
                }
                r.check("one native bracket was submitted", submitted)
                let request = h.bracketSubmitter.submittedRequests[0]
                let identities = h.bracketSubmitter.submittedIdentities[0]

                // Step 0 arrives and its save is in flight when the user cancels.
                h.bracketSubmitter.push(BracketSourceCallback(
                    identity: identities[0],
                    representation: tcSeqRepresentation(request.intents[0]),
                    terminalStatus: .success))
                let blocked = await driveVirtualClock(h.clock) {
                    await h.executor.blockedCount >= 1
                }
                r.check("a save is in flight", blocked)

                await coordinator.cancel(sequenceID: plan.sequenceID)
                await h.executor.setBlocking(false)

                // The already-submitted burst must still drain to storage.
                h.bracketSubmitter.push(BracketSourceCallback(
                    identity: identities[1],
                    representation: tcSeqRepresentation(request.intents[1]),
                    terminalStatus: .success))
                h.bracketSubmitter.push(BracketSourceCallback(
                    identity: identities[2],
                    representation: tcSeqRepresentation(request.intents[2]),
                    terminalStatus: .success))
                h.bracketSubmitter.finishCallbacks()
                h.bracketSubmitter.finishTerminal(.partial(retainedSourceCount: 3,
                                                           description: "burst delivered after cancel"))

                _ = await driveVirtualClock(h.clock) { box.value != nil }
                _ = await task.value

                let result = box.value
                r.equal("no second native request was submitted", h.bracketSubmitter.submittedCount, 1)
                r.equal("status is cancelled", result?.status, .cancelled)
                r.equal("every delivered source was retained", result?.progress.retainedCount, 3)
                r.equal("every delivered source was committed", result?.progress.committedCount, 3)
                r.equal("nothing is reported failed", result?.progress.failedOrdinals, [])
                r.check("no unresolved acquisition error blocks the count",
                        result?.progress.isSourceComplete == true)
            },

            // MARK: Bracket callback identity

            TCCase(id: "T28c",
                   title: "Bracket callbacks delivered reversed and duplicated are attributed by identity") { r in
                let h = SeqHarness(admission: tcSeqAdmission(testedBracketCounts: [3, 5]),
                                   priorSettings: tcSeqManualSettings,
                                   settledBaseline: ExposureBaseline(durationSeconds: 0.01, iso: 100),
                                   plannedCount: 3)
                await h.executor.setPlannedCount(3)
                let plan = tcSeqBracketPlan(count: 3, stepEV: 1, path: .native)

                let box = SequenceTestBox<SequenceRunResult?>(nil)
                let coordinator = h.coordinator
                let task = Task { box.set(await coordinator.start(plan)) }

                let submitted = await driveVirtualClock(h.clock) {
                    h.bracketSubmitter.submittedCount == 1
                }
                r.check("native bracket submitted", submitted)
                let request = h.bracketSubmitter.submittedRequests[0]
                let identities = h.bracketSubmitter.submittedIdentities[0]
                r.equal("three submitted identities", identities.count, 3)

                // Arrival order 2, 1, 2, 0, 1. Every representation deliberately
                // carries the *last* intent's capture ID, so an implementation
                // that labelled by arrival order or by representation.captureID
                // would attribute all three sources to the same ordinal.
                let sentinel = request.intents[2].captureID
                let order = [2, 1, 2, 0, 1]
                for index in order {
                    h.bracketSubmitter.push(BracketSourceCallback(
                        identity: identities[index],
                        representation: tcSeqRepresentation(request.intents[index],
                                                            captureIDOverride: sentinel),
                        terminalStatus: .success))
                }
                h.bracketSubmitter.finishCallbacks()
                h.bracketSubmitter.finishTerminal(.success)

                _ = await driveVirtualClock(h.clock) { box.value != nil }
                _ = await task.value

                let result = box.value
                r.equal("status is complete", result?.status, .complete)
                r.equal("each unique source persisted exactly once", await h.executor.persistedCount, 3)
                r.equal("duplicates did not create extra sources", result?.committedReceipts.count, 3)

                var expected: [CaptureID: Double] = [:]
                for intent in request.intents {
                    if let offset = intent.requestedOffsetEV { expected[intent.captureID] = offset }
                }
                var attributedCorrectly = true
                var detail = ""
                for receipt in result?.committedReceipts ?? [] {
                    let actualOffset = receipt.metadata.sequence?.requestedOffsetEV
                    let expectedOffset = expected[receipt.captureID]
                    if expectedOffset == nil || actualOffset != expectedOffset {
                        attributedCorrectly = false
                        detail += "\(receipt.captureID) got \(String(describing: actualOffset)) "
                            + "expected \(String(describing: expectedOffset)); "
                    }
                }
                r.check("every source is labelled by its native bracket identity, not arrival order",
                        attributedCorrectly, detail)
                let offsets = Set((result?.committedReceipts ?? []).compactMap {
                    $0.metadata.sequence?.requestedOffsetEV
                })
                r.equal("all three offsets are represented", offsets, Set([-1.0, 0.0, 1.0]))
            },

            TCCase(id: "T28d",
                   title: "An unmappable bracket identity is recorded and never labelled by arrival order") { r in
                let h = SeqHarness(admission: tcSeqAdmission(testedBracketCounts: [3]),
                                   priorSettings: tcSeqManualSettings,
                                   settledBaseline: ExposureBaseline(durationSeconds: 0.01, iso: 100),
                                   plannedCount: 3)
                await h.executor.setPlannedCount(3)
                let plan = tcSeqBracketPlan(count: 3, stepEV: 1, path: .native)
                let box = SequenceTestBox<SequenceRunResult?>(nil)
                let coordinator = h.coordinator
                let task = Task { box.set(await coordinator.start(plan)) }

                _ = await driveVirtualClock(h.clock) { h.bracketSubmitter.submittedCount == 1 }
                let request = h.bracketSubmitter.submittedRequests[0]
                let identities = h.bracketSubmitter.submittedIdentities[0]

                let bogus = NativeBracketIdentity(submittedIndex: 9,
                                                  kind: .manualExposure,
                                                  requestedDurationSeconds: 0.5,
                                                  requestedISO: 100,
                                                  requestedBiasEV: nil)
                h.bracketSubmitter.push(BracketSourceCallback(
                    identity: bogus,
                    representation: tcSeqRepresentation(request.intents[0]),
                    terminalStatus: .success))
                for identity in identities {
                    h.bracketSubmitter.push(BracketSourceCallback(
                        identity: identity,
                        representation: tcSeqRepresentation(request.intents[identity.submittedIndex]),
                        terminalStatus: .success))
                }
                h.bracketSubmitter.finishCallbacks()
                h.bracketSubmitter.finishTerminal(.success)

                _ = await driveVirtualClock(h.clock) { box.value != nil }
                _ = await task.value

                let result = box.value
                r.equal("the unmappable callback was recorded", result?.progress.unattributedCallbackCount, 1)
                r.notEqual("the run is not reported complete", result?.status, .complete)
                r.check("no source was labelled from the unmappable callback",
                        result?.committedReceipts.count == 3)
            },

            TCCase(id: "T28e",
                   title: "A partial native bracket retains the good sources and is never complete") { r in
                let h = SeqHarness(admission: tcSeqAdmission(testedBracketCounts: [3]),
                                   priorSettings: tcSeqManualSettings,
                                   settledBaseline: ExposureBaseline(durationSeconds: 0.01, iso: 100),
                                   plannedCount: 3)
                await h.executor.setPlannedCount(3)
                let plan = tcSeqBracketPlan(count: 3, stepEV: 1, path: .native)
                let box = SequenceTestBox<SequenceRunResult?>(nil)
                let coordinator = h.coordinator
                let task = Task { box.set(await coordinator.start(plan)) }

                _ = await driveVirtualClock(h.clock) { h.bracketSubmitter.submittedCount == 1 }
                let request = h.bracketSubmitter.submittedRequests[0]
                let identities = h.bracketSubmitter.submittedIdentities[0]

                h.bracketSubmitter.push(BracketSourceCallback(
                    identity: identities[0],
                    representation: tcSeqRepresentation(request.intents[0]),
                    terminalStatus: .success))
                h.bracketSubmitter.push(BracketSourceCallback(
                    identity: identities[1],
                    representation: nil,
                    terminalStatus: .failed(errorDescription: "synthetic step error")))
                h.bracketSubmitter.push(BracketSourceCallback(
                    identity: identities[2],
                    representation: tcSeqRepresentation(request.intents[2]),
                    terminalStatus: .success))
                h.bracketSubmitter.finishCallbacks()
                h.bracketSubmitter.finishTerminal(.partial(retainedSourceCount: 2,
                                                           description: "one step failed"))

                _ = await driveVirtualClock(h.clock) { box.value != nil }
                _ = await task.value

                let result = box.value
                r.equal("the two good sources are retained", result?.progress.committedCount, 2)
                r.equal("the failed ordinal is recorded", result?.progress.failedOrdinals, [1])
                r.notEqual("never reported complete", result?.status, .complete)
                r.check("no unresolved acquisition error is hidden",
                        result?.progress.isSourceComplete == false)
                let document = h.store.latestDocument(plan.sequenceID)
                r.equal("the document records the failed ordinal", document?.failedIndices, [1])
                r.notEqual("the document is not complete", document?.status, .complete)
            },

            // MARK: T28 — range error and focus settle timeout

            TCCase(id: "T28a",
                   title: "Exposure bracket range error is rejected after settlement and before any capture") { r in
                let priorBaseline = ExposureBaseline(durationSeconds: 0.0025, iso: 100)
                let settled = SequenceBaselineSnapshot(
                    exposure: .manual(durationSeconds: 0.01, iso: 100),
                    biasEV: 0,
                    focus: FocusIntent(mode: .continuousAuto, position: nil, pointOfInterest: nil),
                    whiteBalance: WhiteBalanceIntent(mode: .auto, temperatureAndTint: nil),
                    maxDimensions: PixelDimensions(width: 4032, height: 3024),
                    provenance: .settledDeviceReadback,
                    stableSampleCount: 5,
                    longestPlannedDurationSeconds: 0.04)
                let recorder = SequenceTestBox<[BaselineSettlementRequest]>([])
                let h = SeqHarness(capability: tcSeqCapability(minDuration: 1.0 / 8000.0,
                                                               maxDuration: 0.02,
                                                               minISO: 32,
                                                               maxISO: 3200),
                                   admission: tcSeqAdmission(testedBracketCounts: [3, 5]),
                                   priorSettings: tcSeqManualSettings,
                                   settledBaseline: priorBaseline,
                                   baselineSettlerOverride: SeqFakeBaselineSettler(
                                    result: .success(settled),
                                    recorder: recorder),
                                   plannedCount: 5)
                await h.executor.setPlannedCount(5)
                let plan = tcSeqBracketPlan(count: 5, stepEV: 1, path: .native)

                let result = await h.runToCompletion(plan)

                r.equal("no frame was ever submitted", await h.executor.submittedCount, 0)
                r.equal("no settings were applied", h.settings.applyCount, 0)
                r.equal("terminal status is failed", result.status, .failed)
                let rangeError = result.validationErrors.first { error in
                    if case .bracketDurationOutOfRange = error { return true }
                    return false
                }
                r.check("the rejection names the out-of-range duration targets", rangeError != nil)
                var suggestion: BracketSpanSuggestion?
                for error in result.validationErrors {
                    if case .bracketDurationOutOfRange(_, _, _, _, let proposed) = error {
                        suggestion = proposed
                    }
                }
                r.check("a smaller span is proposed instead of silently clamping",
                        suggestion != nil, "no suggestion")
                r.close("suggested span", suggestion?.spanEV ?? -1, 1.0, tolerance: 1e-9)
                r.equal("suggested count", suggestion?.sourceCount, 3)
                r.equal("settlement ran before the rejection", recorder.value.count, 1)
            },

            TCCase(id: "T28b",
                   title: "Focus settle timeout stops before an illegal capture and keeps prior sources") { r in
                let h = SeqHarness(priorSettings: tcSeqManualSettings,
                                   settledBaseline: ExposureBaseline(durationSeconds: 0.01, iso: 100),
                                   plannedCount: 3)
                await h.executor.setPlannedCount(3)
                h.focusController.setSettlePlan([1, nil, 1])
                let plan = tcSeqFocusPlan(count: 3)

                let caught: SequenceTestBox<Bool> = SequenceTestBox(false)
                let result = await h.runDriving(plan) { snapshot in
                    if case .running(let progress) = snapshot.state,
                       case .settlingFocus = progress.phase {
                        caught.set(true)
                    }
                }

                r.check("the settling state is visible while the watchdog runs", caught.value)
                r.equal("exactly one frame was acquired", await h.executor.submittedCount, 1)
                r.equal("the acquired frame is retained", result.progress.committedCount, 1)
                r.equal("terminal status is failed", result.status, .failed)
                r.equal("the failure is a settle timeout", result.failure?.kind.stableCode, "operationStalled")
                r.equal("the user's prior settings were restored", h.settings.restoreCount, 1)
                r.equal("restoration was reported as restored", result.restoration, .restored)
                r.equal("only two focus moves were attempted", h.focusController.requestedPositions.count, 2)
            },

            TCCase(id: "T28f",
                   title: "Focus bracket positions are linear normalized positions labelled Position only") { r in
                let context = SequenceValidationContext(capability: tcSeqCapability(),
                                                        admission: .provisional)
                let plan = FocusBracketPlan()
                r.equal("default focus count", plan.count, 5)
                let positions = plan.positions
                r.equal("positions", positions.count, 5)
                r.close("first endpoint", positions[0], 0.2, tolerance: 1e-12)
                r.close("second position", positions[1], 0.35, tolerance: 1e-12)
                r.close("centre", positions[2], 0.5, tolerance: 1e-12)
                r.close("fourth position", positions[3], 0.65, tolerance: 1e-12)
                r.close("last endpoint", positions[4], 0.8, tolerance: 1e-12)
                r.check("the plan validates", plan.validate(context: context).isEmpty)

                let label = plan.label(forIndex: 2)
                r.check("labels say Position", label.contains("Position"), label)
                r.check("labels never say Near", !label.lowercased().contains("near"), label)
                r.check("labels never say Far", !label.lowercased().contains("far"), label)
                r.check("labels never state a distance in metres", !label.contains(" m"), label)

                let identical = FocusBracketPlan(count: 3, startPosition: 0.4, endPosition: 0.4)
                let identicalErrors = identical.validate(context: context)
                r.check("identical endpoints are rejected",
                        identicalErrors.contains { if case .focusEndpointsIdentical = $0 { return true }
                                                    return false })
                let outOfRange = FocusBracketPlan(count: 3, startPosition: -0.1, endPosition: 1.4)
                r.check("out-of-range endpoints are rejected", !outOfRange.validate(context: context).isEmpty)
                let badCount = FocusBracketPlan(count: 10)
                r.check("count outside 2...9 is rejected",
                        badCount.validate(context: context).contains {
                            if case .focusCountOutOfRange = $0 { return true }
                            return false
                        })
            },

            // MARK: T29 — restoration failure

            TCCase(id: "T29",
                   title: "Settings restoration failure is a visible state that blocks the shutter until Reset to Auto") { r in
                let h = SeqHarness(priorSettings: tcSeqSettings(), plannedCount: 2)
                await h.executor.setPlannedCount(2)
                h.settings.setRestoreFailure(true)
                let plan = tcSeqIntervalPlan(count: 2, intervalSeconds: 5)

                let result = await h.runToCompletion(plan)

                r.equal("the sources were still retained", result.progress.committedCount, 2)
                r.equal("restoration is recorded as failed", result.restoration, .failed)
                let snapshot = await h.coordinator.snapshot()
                r.check("the coordinator shows a visible recovery state",
                        snapshot.offersResetToAuto, "state \(snapshot.state)")
                r.check("the shutter is blocked", snapshot.isShutterBlocked)
                r.equal("restoration status is failed", snapshot.restoration, .failed)

                let document = h.store.latestDocument(plan.sequenceID)
                r.equal("the document records the failed restoration",
                        document?.restorationStatus, .failed)

                let blocked = await h.coordinator.start(tcSeqIntervalPlan(count: 1, intervalSeconds: 5))
                r.equal("a new sequence is refused", blocked.failure?.kind.stableCode, "restorationFailed")

                let reset = await h.coordinator.resetToAuto()
                switch reset {
                case .success: r.check("Reset to Auto succeeds", true)
                case .failure(let failure): r.check("Reset to Auto succeeds", false, failure.description)
                }
                r.equal("Reset to Auto was offered and executed", h.settings.resetCount, 1)
                let afterReset = await h.coordinator.snapshot()
                r.check("the shutter is unblocked after the reset", !afterReset.isShutterBlocked)
                r.check("Reset to Auto is no longer offered", !afterReset.offersResetToAuto)
            },

            TCCase(id: "T29b",
                   title: "A failed Reset to Auto keeps the recovery state visible") { r in
                let h = SeqHarness(priorSettings: tcSeqSettings(), plannedCount: 1)
                h.settings.setRestoreFailure(true)
                h.settings.setResetFailure(CaptureFailure(kind: .invalidSettings(detail: "synthetic reset failure"),
                                                                operation: "test.reset"))
                let plan = tcSeqIntervalPlan(count: 1, intervalSeconds: 5)
                _ = await h.runToCompletion(plan)

                let reset = await h.coordinator.resetToAuto()
                switch reset {
                case .failure: r.check("the reset failure is surfaced", true)
                case .success: r.check("the reset failure is surfaced", false, "reset unexpectedly succeeded")
                }
                let snapshot = await h.coordinator.snapshot()
                r.check("the shutter stays blocked", snapshot.isShutterBlocked)
                r.check("Reset to Auto is still offered", snapshot.offersResetToAuto)
            },

            // MARK: T30 — manifest write failure

            TCCase(id: "T30",
                   title: "A sequence document write failure after a source commit keeps sources browsable but incomplete") { r in
                let h = SeqHarness(priorSettings: tcSeqSettings(), plannedCount: 2)
                await h.executor.setPlannedCount(2)
                // The initial running document succeeds, the first commit update
                // succeeds, then every later write fails.
                h.store.setFailWritesFromIndex(2)
                let plan = tcSeqIntervalPlan(count: 2, intervalSeconds: 5)

                let result = await h.runToCompletion(plan)

                r.equal("both sources are committed", result.committedReceipts.count, 2)
                r.check("the document write failure is recorded", result.documentWriteFailed)
                r.equal("the failure was counted by the store", h.store.failedWrites >= 1, true)
                r.equal("the run is still reported complete from its own bookkeeping",
                        result.progress.committedCount, 2)

                var addressable = true
                for receipt in result.committedReceipts {
                    if !receipt.isOriginalAvailable
                        || !receipt.relativeOriginalPath.hasPrefix(LibraryLayout.originalsDirectoryName + "/") {
                        addressable = false
                    }
                }
                r.check("every committed source stays browsable and exportable", addressable)

                // Membership is recoverable from the sidecars even without the
                // manifest, and the rebuilt group is never claimed complete.
                let metadata = result.committedReceipts.map(\.metadata)
                let summary = SequenceGroupRebuilder.rebuild(sequenceID: plan.sequenceID,
                                                             metadata: metadata)
                r.check("the group rebuilds from sidecars", summary != nil)
                r.equal("the rebuilt group counts both sources", summary?.committedCount, 2)
                r.check("the rebuilt group is not claimed complete", summary?.isComplete == false)
                r.notEqual("the rebuilt group status is not complete", summary?.status, .complete)
            },

            // MARK: Restart reconciliation

            TCCase(id: "T32",
                   title: "A stale running sequence is reconciled to interrupted and is never auto-resumed") { r in
                let h = SeqHarness(priorSettings: tcSeqSettings(), plannedCount: 3)
                let sequenceID = SequenceID()
                var document = SequenceDocument(
                    sequenceID: sequenceID,
                    libraryID: SeqTestSupport.libraryID,
                    kind: .interval,
                    plannedCount: 3,
                    sourcePlan: [],
                    intervalSeconds: 5,
                    baseline: nil,
                    startedAtUTC: SeqTestSupport.nowUTC)
                document.completedSources = [SequenceCompletedSource(index: 0, captureID: UUID())]
                document.status = .running
                h.store.seed(document)

                switch await h.coordinator.reconcileAfterRestart(sequenceID: sequenceID) {
                case .success(let reconciliation):
                    r.equal("previous status was running", reconciliation.previousStatus, .running)
                    r.equal("run is reported interrupted", reconciliation.document.status, .interrupted)
                    r.check("an end time is recorded", reconciliation.document.endedAtUTC != nil)
                    r.equal("missing ordinals are identified", reconciliation.document.missingIndices, [1, 2])
                    r.check("the update was persisted to the writable root", reconciliation.didPersist)
                    r.check("the summary is not complete", !reconciliation.summary.isComplete)
                case .failure(let failure):
                    r.check("reconciliation succeeded", false, failure.description)
                }
                r.equal("no source was submitted during recovery", await h.executor.submittedCount, 0)

                // A read-only root keeps the truthful state in memory only.
                h.store.setRootState(.readOnly(reason: "read-only root", libraryID: SeqTestSupport.libraryID))
                h.store.seed(document)
                switch await h.coordinator.reconcileAfterRestart(sequenceID: sequenceID) {
                case .success(let reconciliation):
                    r.equal("still reported interrupted", reconciliation.document.status, .interrupted)
                    r.check("nothing was written to a read-only root", !reconciliation.didPersist)
                case .failure(let failure):
                    r.check("read-only reconciliation succeeded", false, failure.description)
                }
            },

            // MARK: Plan validation

            TCCase(id: "T33a",
                   title: "Interval validation uses product bounds plus the injected tested admission minimum") { r in
                let provisional = SequenceAdmissionPolicy.provisional
                let context = SequenceValidationContext(capability: tcSeqCapability(),
                                                        admission: provisional)
                r.check("the default interval plan validates",
                        IntervalPlan().validate(admission: provisional).isEmpty)
                r.equal("default count", IntervalPlan().count, 10)
                r.close("default cadence", IntervalPlan().intervalSeconds, 5)

                let tooMany = IntervalPlan(count: 1000, intervalSeconds: 5)
                r.check("count above 999 is rejected",
                        tooMany.validate(admission: provisional).contains {
                            if case .intervalCountOutOfRange = $0 { return true }
                            return false
                        })
                let tooFew = IntervalPlan(count: 0, intervalSeconds: 5)
                r.check("count below 1 is rejected", !tooFew.validate(admission: provisional).isEmpty)
                let fast = IntervalPlan(count: 2, intervalSeconds: 0.5)
                r.check("cadence below the product floor is rejected",
                        fast.validate(admission: provisional).contains {
                            if case .intervalOutOfRange = $0 { return true }
                            return false
                        })
                let slow = IntervalPlan(count: 2, intervalSeconds: 4000)
                r.check("cadence above the product ceiling is rejected",
                        !slow.validate(admission: provisional).isEmpty)
                let infinite = IntervalPlan(count: 2, intervalSeconds: .infinity)
                r.check("non-finite cadence is rejected",
                        infinite.validate(admission: provisional).contains {
                            if case .intervalNonFinite = $0 { return true }
                            return false
                        })

                let tested = tcSeqAdmission(testedMinimumIntervalSeconds: 2.5)
                let belowTested = IntervalPlan(count: 2, intervalSeconds: 1.5)
                r.check("cadence below the device-tested minimum is rejected",
                        belowTested.validate(admission: tested).contains {
                            if case .intervalBelowTestedAdmission = $0 { return true }
                            return false
                        })
                r.check("a cadence at the tested minimum is accepted",
                        IntervalPlan(count: 2, intervalSeconds: 2.5).validate(admission: tested).isEmpty)
                r.check("the tested minimum never loosens the product floor",
                        tested.effectiveMinimumIntervalSeconds == 2.5)
                r.check("a tested minimum below 1 s does not loosen the product floor",
                        tcSeqAdmission(testedMinimumIntervalSeconds: 0.25)
                            .effectiveMinimumIntervalSeconds == 1)
                let unknown = SeqValidationContextProbe.unknownMinimum
                r.check("an unknown measurement falls back to the product floor", unknown == 1)
                _ = context
            },

            TCCase(id: "T33b",
                   title: "Exposure bracket validation uses tested counts, allowed steps and offset shape") { r in
                let baseline = ExposureBaseline(durationSeconds: 0.01, iso: 100)
                let capability = tcSeqCapability()
                let untested = SequenceValidationContext(capability: capability,
                                                         admission: .provisional,
                                                         bracketBaseline: baseline)
                let native = ExposureBracketPlan()
                r.equal("default bracket count", native.count, 3)
                r.check("native bracketing is refused while untested",
                        native.validate(baseline: baseline, context: untested).contains {
                            if case .nativeBracketPathUnverified = $0 { return true }
                            return false
                        })

                let testedContext = SequenceValidationContext(
                    capability: capability,
                    admission: tcSeqAdmission(testedBracketCounts: [3, 5]),
                    bracketBaseline: baseline)
                let three = ExposureBracketPlan(count: 3, stepEV: 1, path: .native)
                r.equal("three offsets for count 3", three.offsetsEV, [-1, 0, 1])
                r.check("a tested 3-source native bracket validates",
                        three.validate(baseline: baseline, context: testedContext).isEmpty)
                let five = ExposureBracketPlan(count: 5, stepEV: 2, path: .native)
                r.equal("five offsets for count 5", five.offsetsEV, [-4, -2, 0, 2, 4])
                let onlyThree = SequenceValidationContext(
                    capability: capability,
                    admission: tcSeqAdmission(testedBracketCounts: [3]),
                    bracketBaseline: baseline)
                r.check("an untested count is refused",
                        ExposureBracketPlan(count: 5, stepEV: 1, path: .native)
                            .validate(baseline: baseline, context: onlyThree).contains {
                                if case .nativeBracketCountNotTested = $0 { return true }
                                return false
                            })
                r.check("a count above the tested maximum is refused",
                        ExposureBracketPlan(count: 5, stepEV: 1, path: .native)
                            .validate(baseline: baseline,
                                      context: SequenceValidationContext(
                                        capability: capability,
                                        admission: tcSeqAdmission(testedBracketCounts: [3, 5],
                                                                   testedMaximumBracketCount: 3),
                                        bracketBaseline: baseline)).contains {
                                            if case .bracketCountExceedsTestedMaximum = $0 { return true }
                                            return false
                                        })
                r.check("an unsupported count is refused",
                        ExposureBracketPlan(count: 4, stepEV: 1, path: .serial)
                            .validate(baseline: baseline, context: untested).contains {
                                if case .bracketCountUnsupported = $0 { return true }
                                return false
                            })
                r.check("an unsupported step is refused",
                        ExposureBracketPlan(count: 3, stepEV: 0.5, path: .serial)
                            .validate(baseline: baseline, context: untested).contains {
                                if case .bracketStepUnsupported = $0 { return true }
                                return false
                            })
                r.check("the serial path is selectable without a native measurement",
                        ExposureBracketPlan(count: 3, stepEV: 1.0 / 3.0, path: .serial)
                            .validate(baseline: baseline, context: untested).isEmpty)
                r.check("a bracket without a baseline is refused",
                        three.validate(baseline: nil, context: testedContext).contains {
                            if case .bracketBaselineMissing = $0 { return true }
                            return false
                        })
                r.close("target duration at +1 EV",
                        three.targetDurationSeconds(offsetEV: 1, baselineSeconds: 0.01), 0.02, tolerance: 1e-12)
                r.close("target duration at -1 EV",
                        three.targetDurationSeconds(offsetEV: -1, baselineSeconds: 0.01), 0.005, tolerance: 1e-12)
            },

            TCCase(id: "T33c",
                   title: "Timer validation accepts only Off/3/10 seconds") { r in
                for value in TimerPlan.supportedDelaySeconds {
                    r.check("\(value) s is accepted", TimerPlan(delaySeconds: value).validate().isEmpty)
                }
                r.check("5 s is refused", !TimerPlan(delaySeconds: 5).validate().isEmpty)
                r.check("a non-finite delay is refused", !TimerPlan(delaySeconds: .nan).validate().isEmpty)
                r.check("Off means zero delay", TimerPlan(delaySeconds: 0).isOff)
            },

            // MARK: Baseline settlement

            TCCase(id: "T34a",
                   title: "Automatic baseline settlement requires five consecutive stable readbacks") { r in
                let policy = BaselineSettlementPolicy.initial
                let stable = (0..<5).map { _ in tcSeqStableReadback() }
                let report = BaselineSettler.stabilityReport(window: stable,
                                                             requirements: [.exposure, .focus, .whiteBalance],
                                                             policy: policy)
                r.check("a stable window is stable", report.isStable, report.summary)
                r.equal("five samples", report.sampleCount, 5)
                r.check("adjusting indicators stopped", report.indicatorsStopped)

                let stillAdjusting = (0..<5).map { _ in tcSeqStableReadback(exposureAdjusting: true) }
                let adjustingReport = BaselineSettler.stabilityReport(
                    window: stillAdjusting,
                    requirements: [.exposure],
                    policy: policy)
                r.check("native adjusting indicators block stability", !adjustingReport.isStable)

                let driftingExposure = [
                    tcSeqStableReadback(duration: 0.01, iso: 100),
                    tcSeqStableReadback(duration: 0.01, iso: 100),
                    tcSeqStableReadback(duration: 0.01, iso: 100),
                    tcSeqStableReadback(duration: 0.01, iso: 100),
                    tcSeqStableReadback(duration: 0.01 * 1.2, iso: 100),
                ]
                let driftReport = BaselineSettler.stabilityReport(window: driftingExposure,
                                                                  requirements: [.exposure],
                                                                  policy: policy)
                r.check("an exposure-product drift above 1/6 EV blocks stability",
                        !driftReport.isStable, driftReport.summary)

                let goodGains = WhiteBalanceGains(red: 2.0, green: 1.0, blue: 1.5)
                let driftingGains = WhiteBalanceGains(red: 2.2, green: 1.0, blue: 1.5)
                let wbWindow = (0..<4).map { _ in tcSeqStableReadback(gains: goodGains) }
                    + [tcSeqStableReadback(gains: driftingGains)]
                let wbReport = BaselineSettler.stabilityReport(window: wbWindow,
                                                               requirements: [.whiteBalance],
                                                               policy: policy)
                r.check("a per-channel WB gain spread above 2 % blocks stability",
                        !wbReport.isStable, wbReport.summary)

                let focusWindow = (0..<4).map { _ in tcSeqStableReadback(focus: 0.5) }
                    + [tcSeqStableReadback(focus: 0.52)]
                let focusReport = BaselineSettler.stabilityReport(window: focusWindow,
                                                                  requirements: [.focus],
                                                                  policy: policy)
                r.check("a focus-position spread above 0.01 blocks stability",
                        !focusReport.isStable, focusReport.summary)

                r.close("short-exposure watchdog is 5 s",
                        policy.settlement.watchdogSeconds(longestPlannedDurationSeconds: 0.01), 5)
                r.close("a 30 s exposure gets a duration-aware watchdog",
                        policy.settlement.watchdogSeconds(longestPlannedDurationSeconds: 30), 61)
            },

            TCCase(id: "T34b",
                   title: "Baseline settlement freezes settled numeric values and suggests Manual when unsettled") { r in
                let clock = VirtualMonotonicClock()
                let stableSampler = SeqFakeBaselineSampler { _ in tcSeqStableReadback(duration: 0.25, iso: 400) }
                let settler = BaselineSettler(clock: clock, sampler: stableSampler)
                let request = BaselineSettlementRequest(
                    sequenceID: SequenceID(),
                    intent: .freezeNumeric,
                    requirements: [.exposure, .focus, .whiteBalance],
                    longestPlannedDurationSeconds: 30,
                    fallbackExposure: .auto,
                    fallbackFocus: FocusIntent(mode: .continuousAuto, position: nil, pointOfInterest: nil),
                    fallbackWhiteBalance: WhiteBalanceIntent(mode: .auto, temperatureAndTint: nil),
                    maxDimensions: PixelDimensions(width: 4032, height: 3024),
                    explicitBaseline: nil)
                let signal = SequenceCancellationSignal()
                switch await tcSeqSettle(settler, clock: clock, request: request, signal) {
                case .success(let snapshot):
                    r.equal("exposure froze to the settled manual value",
                            snapshot.exposure, .manual(durationSeconds: 0.25, iso: 400))
                    r.equal("five stable samples were required", snapshot.stableSampleCount, 5)
                    r.equal("provenance is the settled device readback",
                            snapshot.provenance, .settledDeviceReadback)
                    r.equal("focus froze to the settled position", snapshot.focus.position, 0.5)
                case .failure(let failure):
                    r.check("settlement succeeded", false, failure.description)
                }

                // An interval keeps the chosen Auto mode instead of pretending a
                // numeric exposure was frozen.
                let autoRequest = BaselineSettlementRequest(
                    sequenceID: SequenceID(),
                    intent: .retainAutomatic,
                    requirements: [],
                    longestPlannedDurationSeconds: 0,
                    fallbackExposure: .auto,
                    fallbackFocus: FocusIntent(mode: .continuousAuto, position: nil, pointOfInterest: nil),
                    fallbackWhiteBalance: WhiteBalanceIntent(mode: .auto, temperatureAndTint: nil),
                    maxDimensions: PixelDimensions(width: 4032, height: 3024),
                    explicitBaseline: nil)
                switch await tcSeqSettle(settler, clock: clock, request: autoRequest, signal) {
                case .success(let snapshot):
                    r.equal("an interval retains Auto", snapshot.exposure, .auto)
                case .failure(let failure):
                    r.check("interval baseline succeeded", false, failure.description)
                }

                // Never-stable readbacks must stop with an unsettled failure.
                let unstableClock = VirtualMonotonicClock()
                let unstableSampler = SeqFakeBaselineSampler { index in
                    tcSeqStableReadback(duration: index.isMultiple(of: 2) ? 0.01 : 0.02, iso: 100)
                }
                let unstableSettler = BaselineSettler(clock: unstableClock, sampler: unstableSampler)
                let unstableSignal = SequenceCancellationSignal()
                let unstableResult = await tcSeqSettle(unstableSettler,
                                                       clock: unstableClock,
                                                       request: request,
                                                       unstableSignal)
                switch unstableResult {
                case .failure(let failure):
                    r.check("an unstable baseline fails", true)
                    r.check("the failure suggests Manual", failure.suggestsManual)
                    r.check("the failure is a stalled operation",
                            failure.captureFailure.kind.stableCode == "operationStalled")
                    if case .unsettled = failure {
                        r.check("the failure is reported as unsettled", true)
                    } else {
                        r.check("the failure is reported as unsettled", false, "\(failure)")
                    }
                default:
                    r.check("an unstable baseline fails", false, "settlement unexpectedly succeeded")
                }
            },

            TCCase(id: "T34c",
                   title: "The settling watchdog never rejects a legal long exposure") { r in
                let policy = SequenceSettlementPolicy()
                r.close("short exposure uses the 5 s floor",
                        policy.watchdogSeconds(longestPlannedDurationSeconds: 0.001), 5)
                r.close("1 s exposure", policy.watchdogSeconds(longestPlannedDurationSeconds: 1), 5)
                r.close("2 s exposure", policy.watchdogSeconds(longestPlannedDurationSeconds: 2), 5)
                r.close("10 s exposure", policy.watchdogSeconds(longestPlannedDurationSeconds: 10), 21)
                r.close("30 s exposure", policy.watchdogSeconds(longestPlannedDurationSeconds: 30), 61)
                r.check("a non-finite duration does not explode the watchdog",
                        policy.watchdogSeconds(longestPlannedDurationSeconds: .infinity) == 5)
            },

            // MARK: Pipeline serialization

            TCCase(id: "T35",
                   title: "The source pipeline keeps at most one acquisition and save in flight") { r in
                let clock = VirtualMonotonicClock()
                let executor = SeqFakeExecutor(clock: clock, plannedCount: 1)
                await executor.setBlocking(true)
                let pipeline = SequenceSourcePipeline(executor: executor, persister: executor)
                let plan = tcSeqIntervalPlan(count: 2, intervalSeconds: 5)
                let intentsBox = SequenceTestBox<[CaptureIntent]>([])
                // Build two intents without a coordinator.
                let makeIntent: (Int) -> CaptureIntent = { index in
                    CaptureIntent(
                        captureID: CaptureID(),
                        libraryID: SeqTestSupport.libraryID,
                        sequenceID: plan.sequenceID,
                        sequenceOrdinal: SourceOrdinal(index),
                        requestedDimensions: PixelDimensions(width: 4032, height: 3024),
                        exposure: .auto,
                        biasEV: 0,
                        focus: FocusIntent(mode: .continuousAuto, position: nil, pointOfInterest: nil),
                        whiteBalance: WhiteBalanceIntent(mode: .auto, temperatureAndTint: nil),
                        configurationGeneration: SeqTestSupport.configurationGeneration,
                        rootGeneration: RootGeneration(1),
                        physicalCameraKind: .wide,
                        createdAtUTC: SeqTestSupport.nowUTC,
                        capturedAtProvenance: .requestTimestamp,
                        timezoneOffsetSeconds: 0,
                        mode: .intervalSource,
                        deadlineOrdinal: DeadlineOrdinal(index),
                        focusBracketTarget: nil,
                        requestedOffsetEV: nil,
                        equivalentFocalLengthMM: 26)
                }
                intentsBox.set([makeIntent(0), makeIntent(1)])

                let first = Task { await pipeline.run(intentsBox.value[0]) }
                let second = Task { await pipeline.run(intentsBox.value[1]) }
                let blocked = await driveVirtualClock(clock) { await executor.blockedCount >= 1 }
                r.check("the first acquisition is in flight", blocked)
                // The second run must be waiting for the gate, not inside execute.
                let startedBeforeRelease = await executor.submittedCount
                r.check("the second acquisition has not started",
                        startedBeforeRelease == 1,
                        "submitted \(startedBeforeRelease)")
                await executor.release()
                let firstOutcome = await first.value
                let secondOutcome = await second.value

                r.equal("the first source committed", firstOutcome.isCommitted, true)
                r.equal("the second source committed", secondOutcome.isCommitted, true)
                r.equal("the pipeline never ran two acquisitions at once",
                        await pipeline.observedPeakConcurrency, 1)
                r.equal("exactly two sources were submitted", await executor.submittedCount, 2)
            },
        ])
}

enum SeqValidationContextProbe {
    /// Product floor when no device measurement exists.
    static let unknownMinimum = SequenceAdmissionPolicy.provisional.effectiveMinimumIntervalSeconds
}

private actor BaselineLockRecordingSurface: CameraSequenceSettingsSurface {
    let age: Double
    let position: Double?
    let revisionOffset: UInt64
    let generationOffset: UInt64
    init(age: Double = 0, position: Double? = 0.47, revisionOffset: UInt64 = 0, generationOffset: UInt64 = 0) {
        self.age = age; self.position = position; self.revisionOffset = revisionOffset; self.generationOffset = generationOffset
    }
    private(set) var applied: [SequenceSettingsSnapshot] = []
    func sequenceSettingsSnapshot() async -> SequenceSettingsSnapshot? { nil }
    func sequenceExposureBaseline() async -> ExposureBaseline? { nil }
    func applySequenceSettings(_ settings: SequenceSettingsSnapshot) async -> Result<Void, CaptureFailure> { applied.append(settings); return .success(()) }
    func restoreSequenceSettings(_ settings: SequenceSettingsSnapshot) async -> Result<Void, CaptureFailure> { .success(()) }
    func resetSequenceSettingsToAuto() async -> Result<Void, CaptureFailure> { .success(()) }
    func currentAppliedSnapshot() async -> AppliedControlSnapshot? {
        let prior = tcSeqSettings()
        return AppliedControlSnapshot(generation: ConfigurationGeneration(prior.configurationGeneration.value &+ generationOffset), requestRevision: prior.revision &+ revisionOffset,
            settlement: .moving, isExposureAdjusting: false, isFocusAdjusting: true, isWhiteBalanceAdjusting: false,
            exposureChoice: prior.exposure, biasEV: prior.biasEV, observedDurationSeconds: 0.01, observedISO: 100,
            observedExposureTargetOffset: 0, focusMode: .continuousAuto, focusPosition: position,
            whiteBalanceMode: .auto, whiteBalanceGains: WhiteBalanceGains(red: 2, green: 1, blue: 1.5),
            lensAperture: 1.6, videoZoomFactor: 1, photoConnectionScale: 1, photoConnectionCrop: 1, capturedAtUTC: Date().addingTimeInterval(-age))
    }
}
