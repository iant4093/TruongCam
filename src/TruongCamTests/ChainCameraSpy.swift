import Foundation
import Synchronization

// The standalone verifier compiles the app sources into the same executable and cannot
// import a module; the native XCTest bundle reads the app's real types through the module.
#if canImport(XCTest)
@testable import TruongCam
#endif

/// Minimal `CaptureCameraSurface` used to drive the REAL `CaptureCoordinator` in the
/// portable verifier (AE02). It is a synthetic native boundary: it performs no capture and
/// proves nothing about device behaviour. Only the five surface members the coordinator
/// requires are implemented.
final class ChainCameraSpy: CaptureCameraSurface, StagingOwnershipReporting, @unchecked Sendable {
    /// The REAL gate this surface reports its retained staging obligations to (AF02).
    var ownershipGate: SubmissionDrainGate?

    private let stagingCounts = Mutex<(started: Int, finished: Int)>((0, 0))

    /// How many staging reports the COORDINATOR itself made, so a test can prove the drain came
    /// from the coordinator rather than from a hand-written fixture call.
    var stagingStartedCount: Int { stagingCounts.withLock { $0.started } }
    var stagingFinishedCount: Int { stagingCounts.withLock { $0.finished } }

    nonisolated func noteStagingStarted(_ captureID: CaptureID) {
        stagingCounts.withLock { $0.started += 1 }
        ownershipGate?.noteStagingStarted(captureID)
    }

    nonisolated func noteStagingFinished(_ captureID: CaptureID) {
        stagingCounts.withLock { $0.finished += 1 }
        ownershipGate?.noteStagingFinished(captureID)
    }

    private let mutex = Mutex<ChainCameraSpy.State>(State())

    /// The ticket registry, guarded by its own lock so a ticket OBJECT is stable per capture
    /// identity while the REQUEST it is backed by can be rebound on submission.
    ///
    /// AM03: this used to be a plain `private let ticket` that `ticket(for:)` returned whenever
    /// `captureID` matched, so a caller submitting a DIFFERENT intent received the pre-created
    /// ticket's `defaultIntent` — a new `LibraryID` and `root.zero` — and the real Core request
    /// never retained the submitted destination identity. The production
    /// `AVCaptureCameraService.beginCapture` mints a fresh `PerCaptureRequest` from the SUBMITTED
    /// intent on every submission; the fixture now does the same instead of reusing an unrelated
    /// precreated one.
    private let ticketLock = Mutex<[CaptureID: ChainCameraTicket]>([:])
    private let defaultTicket: ChainCameraTicket

    /// Records an intent CORRESPONDENCE event: the fixture observed a submission whose intent
    /// differed from the one already bound to that capture identity, and rebound the request to
    /// the submitted intent. Fixture-only instrumentation so a test can assert that the rebind
    /// happened rather than inferring it.
    struct IntentBinding: Sendable {
        let captureID: CaptureID
        let previous: CaptureIntent
        let submitted: CaptureIntent
        /// True when the request was rebound to the submitted intent. False when the old request
        /// already held delivered bytes, so its source could not be discarded.
        let rebound: Bool
    }
    private let bindings = Mutex<[IntentBinding]>([])
    var intentBindings: [IntentBinding] { bindings.withLock { $0 } }

    private struct State: Sendable {
        var lifecycle: CameraLifecycle = .idle
        var generation = ConfigurationGeneration.zero
        var lastReadback: AppliedControlSnapshot?
        var prepareCount = 0
        var attachCount = 0
        var recordedCondition: CameraLifecycle = .idle
    }

    init(captureID: CaptureID = CaptureID(), intent: CaptureIntent? = nil) {
        let created = ChainCameraTicket(
            captureID: captureID,
            intent: intent ?? ChainCameraSpy.defaultIntent(captureID: captureID))
        self.defaultTicket = created
        ticketLock.withLock { $0[captureID] = created }
    }

    /// A deterministic intent for tests that do not supply one.
    static func defaultIntent(captureID: CaptureID) -> CaptureIntent {
        CaptureIntent(
            captureID: captureID,
            libraryID: LibraryID(),
            requestedDimensions: PixelDimensions(width: 4_032, height: 3_024),
            exposure: .auto,
            biasEV: 0,
            focus: FocusIntent(mode: .continuousAuto, position: nil, pointOfInterest: nil),
            whiteBalance: WhiteBalanceIntent(mode: .auto, temperatureAndTint: nil),
            configurationGeneration: .zero,
            rootGeneration: .zero,
            physicalCameraKind: .wide,
            createdAtUTC: Date(timeIntervalSince1970: 0),
            timezoneOffsetSeconds: 0,
            mode: .single)
    }

    var prepareCount: Int { mutex.withLock { $0.prepareCount } }
    var attachCount: Int { mutex.withLock { $0.attachCount } }
    var lifecycleNow: CameraLifecycle { mutex.withLock { $0.lifecycle } }

    /// Records a native interruption/failure condition, as the service does when outstanding or
    /// failed work must not be presented as a healthy running camera (AJ03).
    func recordCondition(_ condition: CameraLifecycle) {
        mutex.withLock { $0.recordedCondition = condition }
    }

    /// The effective lifecycle the SHIPPING Core resolver derives from the recorded condition and
    /// the session state, so a consumer assertion is evaluated by production logic.
    var effectiveLifecycle: CameraLifecycle {
        let (recorded, running) = mutex.withLock { ($0.recordedCondition, $0.lifecycle == .running) }
        return CameraLifecycleResolver.effective(recorded: recorded, sessionIsRunning: running)
    }

    // MARK: - CaptureCameraSurface

    var lifecycle: CameraLifecycle {
        get async { mutex.withLock { $0.lifecycle } }
    }

    var capabilitySnapshot: CameraCapabilitySnapshot {
        get async {
            let generation = mutex.withLock { $0.generation }
            return CameraCapabilitySnapshot(
                generation: generation,
                hardwareModel: "synthetic-chain-camera",
                osVersion: "synthetic",
                sdkVersion: "synthetic",
                physicalCameras: [],
                selectedCameraKind: nil,
                configuredPhotoDimensions: nil,
                configuredPhotoDimensionsEvidence: "synthetic",
                previewAnalysisFormat: nil,
                bayerCaptureSupported: .available(true),
                probeTimestampUTC: Date(timeIntervalSince1970: 0),
                notes: [])
        }
    }

    /// The ticket for an EXACT capture identity. A request always receives the ticket bound to
    /// its OWN `intent.captureID`, so arrival order cannot swap or alias sources (AH04).
    ///
    /// AM03: the returned ticket is additionally REBOUND to the submitted intent. The ticket
    /// object identity is stable (a caller holding it still drives its own request), but the
    /// REAL `PerCaptureRequest` it runs is rebuilt from `intent` exactly as the shipping
    /// `AVCaptureCameraService` does, so the actual Core request always retains the immutable
    /// capture/library/root/sequence/native identity that was SUBMITTED rather than an unrelated
    /// precreated default selected only by `captureID`.
    func ticket(for intent: CaptureIntent) -> ChainCameraTicket {
        let captureID = intent.captureID
        // One critical section covers lookup AND rebind, so two concurrent submitters for the
        // same identity cannot interleave a lookup with the other's request exchange.
        let ticket = ticketLock.withLock { registry -> ChainCameraTicket in
            if let existing = registry[captureID] { return existing }
            let created = ChainCameraTicket(captureID: captureID, intent: intent)
            registry[captureID] = created
            lastCreated.withLock { $0 = created }
            return created
        }
        switch ticket.adopt(intent: intent) {
        case .alreadyBound:
            break
        case .rebound(let previous):
            bindings.withLock {
                $0.append(IntentBinding(
                    captureID: captureID, previous: previous, submitted: intent, rebound: true))
            }
        case .refusedToDiscardSource(let previous):
            // The old request already held delivered bytes, so its source cannot be silently
            // dropped. Keep it and report the mismatch instead of losing a RAW representation.
            bindings.withLock {
                $0.append(IntentBinding(
                    captureID: captureID, previous: previous, submitted: intent, rebound: false))
            }
        }
        ticket.ownershipGate = ownershipGate
        return ticket
    }

    private struct AttachHandshake: Sendable {
        var held = false
        var waiters: [CheckedContinuation<Void, Never>] = []
        /// Proves a request has ARRIVED at the handshake, independent of the held decision.
        var arrivals = 0
    }
    /// ONE lock holds the held flag, the arrivals count AND the waiters, so deciding, recording
    /// an arrival, registering a waiter and releasing are a single atomic handshake (AI04).
    private let handshake = Mutex<AttachHandshake>(AttachHandshake())

    /// How many requests have ARRIVED at the handshake (an owned arrival observable).
    var attachArrivals: Int { handshake.withLock { $0.arrivals } }

    /// Parks every `beginCapture` until `releaseAttachments()`, so a test can prove ordering.
    func holdAttachments() { handshake.withLock { $0.held = true } }

    func releaseAttachments() {
        let waiting = handshake.withLock { state -> [CheckedContinuation<Void, Never>] in
            state.held = false
            let pending = state.waiters
            state.waiters = []
            return pending
        }
        for waiter in waiting { waiter.resume() }
    }

    func beginCapture(intent: CaptureIntent) async -> any CaptureRequestTicket {
        // The native REQUEST owner reserves the submission obligation.
        ownershipGate?.noteSubmitted(intent.captureID)
        var needsWait = false
        await withCheckedContinuation { (resume: CheckedContinuation<Void, Never>) in
            var resumedImmediately = false
            let wait = handshake.withLock { state -> Bool in
                state.arrivals += 1
                guard state.held else { resumedImmediately = true; return false }
                state.waiters.append(resume)
                return true
            }
            if !wait || resumedImmediately { resume.resume() }
            needsWait = wait
        }
        _ = needsWait
        // Correlated by REQUESTED IDENTITY, never by call ordinal. The ticket is bound FIRST, so
        // `attachCount` reports "submitted AND adopted" rather than only "entered beginCapture".
        let bound = ticket(for: intent)
        mutex.withLock { $0.attachCount += 1 }
        return bound
    }

    func applyControls(
        revision: UInt64,
        exposure: ExposureChoice,
        biasEV: Double,
        focus: FocusIntent,
        whiteBalance: WhiteBalanceIntent
    ) async -> Result<AppliedControlSnapshot, CaptureFailure> {
        let generation = mutex.withLock { $0.generation }
        let snapshot = AppliedControlSnapshot(
            generation: generation,
            requestRevision: revision,
            settlement: .settled,
            exposureChoice: exposure,
            biasEV: biasEV,
            observedDurationSeconds: nil,
            observedISO: nil,
            observedExposureTargetOffset: nil,
            focusMode: focus.mode,
            focusPosition: focus.position,
            whiteBalanceMode: whiteBalance.mode,
            whiteBalanceGains: nil,
            lensAperture: 1.8,
            videoZoomFactor: 1.0,
            photoConnectionScale: 1.0,
            photoConnectionCrop: 1.0,
            capturedAtUTC: Date(timeIntervalSince1970: 0))
        mutex.withLock { $0.lastReadback = snapshot }
        return .success(snapshot)
    }

    func currentControlReadback() async -> AppliedControlSnapshot? {
        mutex.withLock { $0.lastReadback }
    }

    // MARK: - Test control

    /// Advances the synthetic configuration generation, modelling a topology change.
    /// AP03: aligns this graph's configuration generation with the value a plan baked into its
    /// intents, so `applicationIsComplete`'s generation condition can hold.
    func setConfigurationGeneration(_ value: ConfigurationGeneration) {
        mutex.withLock { $0.generation = value }
    }

    func advanceGeneration() {
        mutex.withLock { $0.generation = ConfigurationGeneration.next($0.generation) }
    }

    /// The REAL rebuild step: advances the configuration generation using the SAME shipping Core
    /// expression the service's `rebuildAfterReset` uses, so the recovery chain's rebuild port has
    /// an observable effect rather than a log line (AH03).
    func rebuildConfiguration() -> ConfigurationGeneration {
        mutex.withLock { state in
            state.generation = ConfigurationGeneration.next(state.generation)
            return state.generation
        }
    }

    var configurationGeneration: ConfigurationGeneration {
        mutex.withLock { $0.generation }
    }

    /// The ticket handed to the coordinator, so a test can drive the terminal outcome.
    ///
    /// AM03: this returns the STABLE ticket object for the spy's own capture identity. Its backing
    /// request is rebound to the submitted intent when the coordinator submits, so a test that
    /// captured this handle before submission still drives the request the coordinator drains.
    var captureTicket: ChainCameraTicket { defaultTicket }

    /// AP03: the ticket most recently CREATED by a submission, so a caller can end the wait of a
    /// frame whose capture identity it does not know in advance (e.g. a sequence frame).
    private let lastCreated = Mutex<ChainCameraTicket?>(nil)
    var lastCreatedTicket: ChainCameraTicket? { lastCreated.withLock { $0 } }
}

/// A minimal ticket with no delivered representations. Synthetic: it is not a capture.
final class ChainCameraTicket: CaptureRequestTicket, @unchecked Sendable {
    let captureID: CaptureID
    let uniqueSettingsID: Int64

    /// AL01: the ticket is now backed by the REAL shipping request owner. `PerCaptureRequest` and
    /// `CameraCaptureTicket` are Core types, so this fixture no longer MODELS the submission /
    /// representation / retirement algorithm — it runs it. Only the test-only extras below
    /// (the ownership gate and the published counter) remain fixture state.
    ///
    /// AM03: the active request is REBINDABLE but the ticket object is not. `captureID` and
    /// `uniqueSettingsID` are fixed at construction, so a request identity can never be swapped or
    /// aliased by a rebind; only the IMMUTABLE intent the request owner was created from is
    /// aligned with what was actually submitted.
    private struct Active: Sendable {
        var request: PerCaptureRequest
        var published: Int
    }
    private let active: Mutex<Active>

    /// What a submission did to this ticket's bound intent.
    enum Adoption: Sendable, Equatable {
        /// The request owner already carried exactly this intent.
        case alreadyBound
        /// The request owner was rebuilt from the submitted intent. Carries the intent it had.
        case rebound(previous: CaptureIntent)
        /// The old request owner already held delivered bytes, so rebinding would have discarded a
        /// real source. The old request is preserved and the mismatch is reported instead.
        case refusedToDiscardSource(previous: CaptureIntent)
    }

    private static let nextSettingsID = Mutex<Int64>(1_000)
    private static func mintSettingsID() -> Int64 { nextSettingsID.withLock { $0 += 1; return $0 } }

    init(captureID: CaptureID, intent: CaptureIntent) {
        self.captureID = captureID
        self.uniqueSettingsID = Self.mintSettingsID()
        self.active = Mutex(Active(
            request: Self.makeRequest(captureID: captureID, intent: intent, settingsID: self.uniqueSettingsID), published: 0))
    }

    /// The REAL Core request owner for one immutable intent, created exactly as the shipping
    /// `AVCaptureCameraService.beginCapture` creates it.
    private static func makeRequest(captureID: CaptureID, intent: CaptureIntent, settingsID: Int64) -> PerCaptureRequest {
        let request = PerCaptureRequest(
            captureID: captureID,
            intent: intent,
            rawPixelFormatType: 0x4247_4734,
            rawFileType: "com.adobe.raw-image",
            maximumRepresentations: 4)
        _ = request.bindNativeSettingsID(settingsID)
        return request
    }

    /// The ACTIVE real request owner, so a test can assert the submitted destination identity it
    /// actually retains.
    var request: PerCaptureRequest { active.withLock { $0.request } }

    /// How many representations were PUBLISHED, so a test can wait for the source to be handed
    /// over before delivering the terminal (AG02). Preserved across a rebind, because the
    /// representations themselves are carried over.
    var stagedRepresentationCount: Int { active.withLock { $0.published } }

    /// Aligns this ticket's request owner with the intent that was actually SUBMITTED.
    ///
    /// A ticket is often pre-created (via `ChainCameraSpy.captureTicket` or `ticket(for:)`) before
    /// the coordinator submits, so its request starts from a placeholder intent. The submitted
    /// intent is the authoritative one: the request must retain its capture/library/root/generation
    /// /sequence/native identity, not the placeholder's.
    @discardableResult
    func adopt(intent: CaptureIntent) -> Adoption {
        let decision = active.withLock {
            (state: inout Active) -> Adoption? in
            guard state.request.intent != intent else { return nil }
            guard state.request.recordedRepresentationCount == 0 else { return nil }
            let previous = state.request.intent
            state.request = Self.makeRequest(captureID: captureID, intent: intent, settingsID: uniqueSettingsID)
            return .rebound(previous: previous)
        }
        if let decision { return decision }
        let existing = active.withLock { $0.request.intent }
        if existing == intent { return .alreadyBound }
        // The old request already holds delivered bytes: keep it so the source is not discarded,
        // and report the mismatch rather than silently claiming the submitted intent was bound.
        return .refusedToDiscardSource(previous: existing)
    }

    func representationStream() -> BoundedOrderedSequence<DeliveredRAWRepresentation> {
        active.withLock { $0.request }.reserveRepresentationConsumer()
    }

    func representationsOverflowed() -> Int {
        active.withLock { $0.request }.refusedRepresentationCount
    }

    func awaitTerminal() async -> NativeRequestOutcome {
        await active.withLock { $0.request }.terminal.wait()
    }

    func currentTerminal() -> NativeRequestOutcome? {
        active.withLock { $0.request }.terminal.current
    }

    func terminalFailure() -> CaptureFailure? {
        let request = active.withLock { $0.request }
        if let failure = request.terminalFailure { return failure }
        if case .failed(let failure) = request.terminal.current { return failure }
        return nil
    }

    var resolvedDimensions: AsyncStream<PixelDimensions?> {
        active.withLock { $0.request }.resolvedDimensionsChannel.subscribe()
    }

    /// Delivery routes through the REAL owner's recording path, so acceptance, the count and
    /// publication are one atomic handoff exactly as in production.
    @discardableResult
    func deliverRepresentation(
        bytes: Data,
        dimensions: PixelDimensions,
        rawPixelFormatType: UInt32 = 0x4247_4734,
        rawFileType: String? = "com.adobe.raw-image"
    ) -> Bool {
        let representation = DeliveredRAWRepresentation(
            bytes: bytes,
            captureID: captureID,
            resolvedSettingsUniqueID: uniqueSettingsID,
            nativeBracketIdentity: nil,
            rawPixelFormatType: rawPixelFormatType,
            rawFileType: rawFileType,
            rawPhotoDimensions: dimensions,
            rawPixelBufferDimensions: dimensions,
            timestampSeconds: 0,
            metadata: [:])
        // ONE critical section: the acceptance decision and the publication count that reports it
        // are the same handoff, so a rebind cannot observe a half-recorded source.
        return active.withLock { state in
            guard state.request.recordRepresentation(representation) else { return false }
            state.published += 1
            return true
        }
    }

    /// The gate this ticket's TERMINAL retires against (AJ03).
    nonisolated(unsafe) weak var ownershipGate: SubmissionDrainGate?

    /// Retires the terminal through the REAL owner, so an empty capture cannot be reported as a
    /// success and a duplicate cannot replace the recorded outcome.
    /// AO03: how many TERMINALS this ticket retired, separable from staging reports.
    private let terminalCountBox = Mutex<Int>(0)
    var terminalCount: Int { terminalCountBox.withLock { $0 } }

    func deliver(_ outcome: NativeRequestOutcome) {
        let mapped: CaptureFailure? = if case .failed(let failure) = outcome { failure } else { nil }
        let request = active.withLock { $0.request }
        guard request.recordNativeTerminal(settingsID: uniqueSettingsID, mappedFailure: mapped) != nil else { return }
        let firstTerminal = terminalCountBox.withLock { count in
            guard count == 0 else { return false }
            count = 1
            return true
        }
        if firstTerminal { ownershipGate?.noteTerminal(captureID) }
    }
}

/// Test seam that lets a test hold a REAL provider commit **in flight** (AG02a/AE02a).
///
/// It forwards coordinated writes to the real mutator but, once armed, parks the FIRST write
/// inside the provider operation on an owned handshake. The commit has genuinely been INVOKED —
/// it is blocked inside the store's own commit pipeline — rather than the call being withheld.
/// A bounded wait is used so a mistake cannot wedge the verifier.
final class GatedFileCoordinatorMutator: CoordinatedFileMutator, @unchecked Sendable {
    private let inner = DirectFileCoordinatorMutator()
    enum HoldOutcome: Equatable, Sendable { case none, held, released, timedOut }
    var holdTimeoutSeconds: Double = 30

    private final class Hold: @unchecked Sendable {
        let gate = DispatchSemaphore(value: 0)
        private let released = Mutex<Bool>(false)
        func release() {
            let signal = released.withLock { value in
                if value { return false }
                value = true
                return true
            }
            if signal { gate.signal() }
        }
    }
    private struct State {
        var pending: [Hold] = []
        var active: Hold?
        var entered = 0
        var outcome: HoldOutcome = .none
    }
    private let state = Mutex<State>(State())
    private let writeCountBox = Mutex<Int>(0)
    var holdOutcome: HoldOutcome { state.withLock { $0.outcome } }
    var enteredCount: Int { state.withLock { $0.entered } }
    var writeCount: Int { writeCountBox.withLock { $0 } }

    /// Each arm owns a separate semaphore. Releases from an earlier invocation cannot
    /// provide credit for a later hold, and arming alone does not claim provider entry.
    func arm() {
        state.withLock { value in
            value.pending.append(Hold())
            if value.active == nil { value.outcome = .none }
        }
    }
    func release() {
        let hold = state.withLock { $0.active ?? $0.pending.first }
        hold?.release()
    }
    func coordinatedWrite<T>(at url: URL, _ body: (URL) throws -> T) throws -> T {
        let hold: Hold? = state.withLock { value in
            guard !value.pending.isEmpty else { return nil }
            let hold = value.pending.removeFirst()
            value.active = hold
            value.entered += 1
            value.outcome = .held
            return hold
        }
        if let hold {
            let outcome: HoldOutcome = hold.gate.wait(timeout: .now() + holdTimeoutSeconds) == .success
                ? .released : .timedOut
            state.withLock { value in
                if value.active === hold { value.active = nil }
                value.outcome = outcome
            }
            if outcome == .timedOut {
                throw CaptureFailure(kind: .operationStalled(
                    detail: "The gated provider hold expired without being released."),
                    operation: "providerHold")
            }
        }
        writeCountBox.withLock { $0 += 1 }
        return try inner.coordinatedWrite(at: url, body)
    }
    func coordinatedRead<T>(at url: URL, _ body: (URL) throws -> T) throws -> T {
        try inner.coordinatedRead(at: url, body)
    }
}
