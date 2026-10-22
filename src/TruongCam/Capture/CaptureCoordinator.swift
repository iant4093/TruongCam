import Foundation
import ImageIO

// CONTRACTS.md "Semantic interfaces", "Readiness and admission", "Camera, source
// and library state".
//
// CaptureCoordinator owns admission and immutable intents. Only one ordinary
// native photo request may be in flight, and the next is not admitted until the
// native terminal callback AND the required source staging/commit have finished.
// A caller timeout never implies that native capture or file coordination ended.

/// Why the shutter is not currently enabled.
enum CaptureBlockReason: Hashable, Sendable {
    case cameraPermissionMissing
    case sceneInactive
    case cameraNotRunning(CameraLifecycle)
    case noUsableBayerTuple(String)
    case unsupportedControls(String)
    case libraryNotWritable(LibraryRootState)
    case pendingOriginalBacklog(count: Int)
    case sequenceOrTimerActive(kind: String)
    case reconfigurationInProgress
    case noFreeCapturePermit
    case restorationFailed(String)

    var userDescription: String {
        switch self {
        case .cameraPermissionMissing:
            return "Camera access is required before capturing."
        case .sceneInactive:
            return "The camera is not active."
        case .cameraNotRunning(let lifecycle):
            return "The camera is not ready (\(lifecycle.displayLabel))."
        case .noUsableBayerTuple(let detail):
            return "Genuine Bayer RAW is not available: \(detail)"
        case .unsupportedControls(let detail):
            return detail
        case .libraryNotWritable(let state):
            return "Originals cannot be saved yet (\(state.displayLabel))."
        case .pendingOriginalBacklog(let count):
            return "\(count) original(s) are still waiting to be saved to the folder."
        case .sequenceOrTimerActive(let kind):
            return "\(kind) is running; its controls are frozen."
        case .reconfigurationInProgress:
            return "The camera is being reconfigured."
        case .noFreeCapturePermit:
            return "The previous capture has not finished."
        case .restorationFailed(let detail):
            return "Camera settings could not be restored. Reset to Auto to continue. \(detail)"
        }
    }
}

/// Everything the coordinator needs from the rest of the app, as a value.
struct CaptureReadinessInputs: Hashable, Sendable {
    let isSceneActive: Bool
    let cameraLifecycle: CameraLifecycle
    let hasCameraPermission: Bool
    let bayerSupport: DiscoveryStatus<Bool>
    let controlsSupported: Bool
    let unsupportedControlsDetail: String?
    let rootState: LibraryRootState
    let pendingOriginalCount: Int
    let activeSequenceDescription: String?
    let isReconfiguring: Bool
    let restorationFailedDetail: String?
    var frontHEIFSupported = false
    var fileFormat: CaptureFileFormat = .bayerDNG
    var jpegSupported = false
}

/// Terminal result of one capture intent.
struct CaptureRequestResult: Hashable, Sendable {
    let captureID: CaptureID
    let acquisition: NativeRequestOutcome
    let committedReceipts: [CommitReceipt]
    let pendingTransactionIDs: [TransactionID]
    let failures: [CaptureFailure]
    /// Exact durable ownership for uncommitted sources, never inferred from an error.
    var pendingHandles: [StagedSourceHandle] = []

    var didCommitAnything: Bool { !committedReceipts.isEmpty }
    var didRetainAnything: Bool {
        !committedReceipts.isEmpty || !pendingTransactionIDs.isEmpty
    }

    /// UI truth: `Saved to folder` only when a verified final original plus its
    /// matching sidecar exist.
    var savedToFolderCount: Int { committedReceipts.count }
}

/// Narrow camera surface the coordinator depends on. `CameraServicing` conforms
/// structurally through the production service; tests use a fake.
@preconcurrency
protocol CaptureCameraSurface: Sendable {
    var lifecycle: CameraLifecycle { get async }
    var capabilitySnapshot: CameraCapabilitySnapshot { get async }
    func beginCapture(intent: CaptureIntent) async -> any CaptureRequestTicket
    func applyControls(
        revision: UInt64,
        exposure: ExposureChoice,
        biasEV: Double,
        focus: FocusIntent,
        whiteBalance: WhiteBalanceIntent
    ) async -> Result<AppliedControlSnapshot, CaptureFailure>
    func currentControlReadback() async -> AppliedControlSnapshot?
}

#if canImport(AVFoundation) && !TC_PORTABLE_VERIFIER
extension AVCaptureCameraService: CaptureCameraSurface {}
#endif

/// Coordinates a single capture from intent to durable commit.
actor CaptureCoordinator {
    private let camera: any CaptureCameraSurface
    private let store: any LibraryStoring
    private let clock: any MonotonicClock
    /// Decides whether a delivered pixel format is genuine Bayer RAW.
    ///
    /// REVIEW.md R05: this used to be a guessed FourCC-suffix test
    /// (`AVCapturePhotoOutputMarker`) that could accept a non-Bayer format. The
    /// production build injects `AVCapturePhotoOutput.isBayerRAWPixelFormat(_:)`;
    /// the fallback below is deliberately CONSERVATIVE (it refuses when unsure),
    /// because accepting a processed format as Bayer RAW is the unrecoverable error.
    private let bayerClassifier: any BayerRAWClassifying

    /// Latest UI cue only; RAW and verified receipts retain their loss-critical paths.
    nonisolated let shutterFeedback = LatestValueBroadcaster<CaptureShutterFeedback>()

    /// One capture at a time.
    private let permit = AsyncGate()
    private var activeCaptureID: CaptureID?
    private var admitNewRequests = true
    // Lifecycle admission is independent of an unresolved native-request fence.
    // A newer UI transition must win even if older async work arrives late.
    private var lifecycleAdmissionOpen = true
    private var lifecycleAdmissionRevision: UInt64 = 0

    /// Native-hang detection: a watchdog may surface a stall, but it can never
    /// pretend the native operation or the file coordination has terminated.
    private var lastSubmittedAt: Double?
    private var stalledCaptureIDs: Set<CaptureID> = []
    private let stallThresholdSeconds: Double

    /// Sources whose representation arrived but whose native terminal callback is
    /// still outstanding. Their bytes are staged as soon as they are delivered.
    private var stagedByCaptureID: [CaptureID: [StagedSourceHandle]] = [:]

    init(camera: any CaptureCameraSurface,
         store: any LibraryStoring,
         clock: any MonotonicClock,
         stallThresholdSeconds: Double = 30,
         bayerClassifier: any BayerRAWClassifying = ConservativeBayerClassifier()) {
        self.camera = camera
        self.store = store
        self.clock = clock
        self.stallThresholdSeconds = stallThresholdSeconds
        self.bayerClassifier = bayerClassifier
    }

    // MARK: - Readiness

    /// The single admission preflight. A preflight is useful but never guarantees
    /// a later provider write, and the camera permission and the library
    /// permission are independent states.
    nonisolated func blockReason(for inputs: CaptureReadinessInputs) -> CaptureBlockReason? {
        Self.admissionBlockReason(for: inputs)
    }

    /// The admission preflight as a pure static function.
    ///
    /// It reads only its value inputs, so it is evaluable without a camera or a
    /// store. Kept as the single implementation the instance method delegates to,
    /// so there is no second copy of the admission rules.
    nonisolated static func admissionBlockReason(
        for inputs: CaptureReadinessInputs
    ) -> CaptureBlockReason? {
        if let detail = inputs.restorationFailedDetail {
            return .restorationFailed(detail)
        }
        if !inputs.hasCameraPermission { return .cameraPermissionMissing }
        if !inputs.isSceneActive { return .sceneInactive }
        switch inputs.cameraLifecycle {
        case .running:
            break
        case .reconfiguring:
            return .reconfigurationInProgress
        case .requestingPermission, .configuring, .idle, .stopping, .interrupted,
             .unavailable, .failed:
            return .cameraNotRunning(inputs.cameraLifecycle)
        }
        if inputs.fileFormat == .jpeg && !inputs.jpegSupported {
            return .unsupportedControls("JPEG capture is unavailable on this camera.")
        }
        switch inputs.fileFormat == .jpeg ? .available(true) : (inputs.frontHEIFSupported ? .available(true) : inputs.bayerSupport) {
        case .available(true):
            break
        case .available(false):
            return .noUsableBayerTuple("the active format reports no Bayer RAW pixel format")
        case .unavailable(let reason):
            return .noUsableBayerTuple(reason)
        case .unknown(let reason):
            return .noUsableBayerTuple(reason)
        }
        if !inputs.controlsSupported {
            return .unsupportedControls(
                inputs.unsupportedControlsDetail
                    ?? "The current exposure, focus or white balance selection is not supported.")
        }
        if !inputs.rootState.isWritable {
            return .libraryNotWritable(inputs.rootState)
        }
        if inputs.pendingOriginalCount > 0 {
            // A failed pending original blocks further capture; it is never
            // evicted to make room.
            return .pendingOriginalBacklog(count: inputs.pendingOriginalCount)
        }
        if let description = inputs.activeSequenceDescription {
            return .sequenceOrTimerActive(kind: description)
        }
        if inputs.isReconfiguring { return .reconfigurationInProgress }
        return nil
    }

    func canAdmitCapture() -> Bool {
        admitNewRequests && lifecycleAdmissionOpen && activeCaptureID == nil
    }

    @discardableResult
    func setLifecycleAdmission(isOpen: Bool, revision: UInt64) -> Bool {
        guard revision >= lifecycleAdmissionRevision else { return false }
        lifecycleAdmissionRevision = revision
        lifecycleAdmissionOpen = isOpen
        return isOpen && admitNewRequests
    }

    /// Stops admitting new requests. Already-submitted native work still drains.
    func stopAdmittingNewRequests() {
        admitNewRequests = false
    }

    func resumeAdmittingNewRequests() {
        admitNewRequests = true
    }

    /// Marks a capture as stalled. This disables new captures and reports the
    /// condition; it does not fabricate a terminal result.
    func noteWatchdogFired(captureID: CaptureID) {
        stalledCaptureIDs.insert(captureID)
        admitNewRequests = false
    }

    func stalledCaptureIDsSnapshot() -> [CaptureID] { Array(stalledCaptureIDs).sorted { $0.description < $1.description } }

    // MARK: - Capture

    /// Runs one capture intent to a terminal result.
    func capture(
        intent: CaptureIntent,
        longestPlannedDurationSeconds: Double? = nil
    ) async -> CaptureRequestResult {
        // Failed/cancelled requests never enter the retained drain's cleanup.
        // Once native ownership begins, only that loss-critical drain retires it.
        var handedToNativeDrain = false
        defer {
            if !handedToNativeDrain {
                readbacksByCaptureID.removeValue(forKey: intent.captureID)
                verifiedSnapshotsByCaptureID.removeValue(forKey: intent.captureID)
            }
        }
        if Task.isCancelled { return Self.cancelledBeforeSubmission(intent: intent, stage: "capture.enter") }
        guard admitNewRequests else {
            let failure = CaptureFailure(
                kind: .operationStalled(detail: "New captures are paused while a previous native request is unresolved."),
                operation: "capture")
            return CaptureRequestResult(
                captureID: intent.captureID,
                acquisition: .failed(failure),
                committedReceipts: [],
                pendingTransactionIDs: [],
                failures: [failure])
        }
        guard lifecycleAdmissionOpen else {
            let failure = CaptureFailure(kind: .cameraInterrupted(detail: "Camera startup or a foreground transition is not complete yet."), operation: "capture.lifecycleAdmission")
            return CaptureRequestResult(captureID: intent.captureID, acquisition: .failed(failure), committedReceipts: [], pendingTransactionIDs: [], failures: [failure])
        }
        await permit.acquire()
        activeCaptureID = intent.captureID
        lastSubmittedAt = clock.now()
        defer {
            activeCaptureID = nil
            Task { await permit.release() }
        }
        // A queued request may lose admission or be cancelled while the prior
        // retained capture drains. Recheck before issuing any device settings.
        if Task.isCancelled { return Self.cancelledBeforeSubmission(intent: intent, stage: "capture.afterPermit") }
        guard admitNewRequests && lifecycleAdmissionOpen else {
            return Self.cancelledBeforeSubmission(intent: intent, stage: "capture.afterPermitAdmission")
        }

        if intent.fileFormat == .jpeg {
            let capability = await camera.capabilitySnapshot
            guard capability.jpegSupported, capability.generation == intent.configurationGeneration,
                  capability.selectedCameraKind == intent.physicalCameraKind,
                  let ceiling = capability.jpegMaximumDimensions, intent.requestedDimensions.isValid,
                  intent.requestedDimensions == ceiling,
                  intent.mode == .single || intent.mode == .timer,
                  intent.sequenceID == nil else {
                let failure = CaptureFailure(kind: .unsupportedCapability(detail: "The frozen JPEG request is not supported by the current camera configuration."), operation: "capture.formatAdmission")
                return CaptureRequestResult(captureID: intent.captureID, acquisition: .failed(failure), committedReceipts: [], pendingTransactionIDs: [], failures: [failure])
            }
            if Task.isCancelled { return Self.cancelledBeforeSubmission(intent: intent, stage: "capture.formatAdmissionCancelled") }
            guard admitNewRequests && lifecycleAdmissionOpen else {
                return Self.cancelledBeforeSubmission(intent: intent, stage: "capture.formatAdmissionReplaced")
            }
        }

        // Apply this request's frozen controls first. `CaptureIntent` is immutable, so
        // this can never overwrite a sequence step with newer user intent; and a FAILED
        // application submits nothing at all (REVIEW.md G03).
        #if DEBUG
        let controlsBegan = clock.now()
        #endif
        let application = await camera.applyControls(
            revision: Self.controlRevision(for: intent),
            exposure: intent.exposure,
            biasEV: intent.biasEV,
            focus: intent.focus,
            whiteBalance: intent.whiteBalance)
        #if DEBUG
        print("TruongCam timing control-application-ack=\(Int((clock.now() - controlsBegan) * 1000))ms capture=\(intent.captureID) exposure=\(intent.exposure.mode.rawValue) focus=\(intent.focus.mode.rawValue) wb=\(intent.whiteBalance.mode.rawValue)")
        #endif
        switch application {
        case .failure(let failure):
            return CaptureRequestResult(
                captureID: intent.captureID,
                acquisition: .failed(failure),
                committedReceipts: [],
                pendingTransactionIDs: [],
                failures: [failure])
        case .success(let acknowledgement):
            // H01: a setter ACKNOWLEDGEMENT is not a live observation. The real service returns
            // `.awaitingObservation` because it reports that the setter returned, not
            // that the device reached the request — and `intent.exposure` pins concrete
            // manual values the delivered source is supposed to carry. Submitting on the
            // acknowledgement would capture at the old exposure while the intent claims
            // the step.
            //
            // Manual/sequence convergence is observed with a bounded deadline.
            // An ordinary fully-Auto snapshot instead confirms fresh Auto modes
            // and measured values, without waiting for continuous 3A to freeze.
            guard let settled = await awaitControlSettlement(
                acknowledgement: acknowledgement,
                for: intent,
                longestPlannedDurationSeconds: longestPlannedDurationSeconds) else {
                if Task.isCancelled { return Self.cancelledBeforeSubmission(intent: intent, stage: "capture.settlementCancelled") }
                let failure = CaptureFailure(
                    kind: .operationStalled(
                        detail: "The requested exposure, focus or white balance did not converge before the settle deadline, so no frame was requested at the wrong settings."),
                    operation: "capture.awaitSettlement")
                return CaptureRequestResult(
                    captureID: intent.captureID,
                    acquisition: .failed(failure),
                    committedReceipts: [],
                    pendingTransactionIDs: [],
                    failures: [failure])
            }
            // J06: pin the actual observation for this request BEFORE submission.
            // A moving Auto reading stays moving, including in metadata provenance.
            recordVerifiedSnapshot(settled, for: intent.captureID)
        }
        #if DEBUG
        print("TruongCam timing controls-through-settled=\(Int((clock.now() - controlsBegan) * 1000))ms capture=\(intent.captureID)")
        #endif

        // H02: RE-CHECK admission after the application await. Closing admission while
        // the setter was suspended must cancel this unsubmitted request, not let it
        // through a gate that was evaluated before the suspension.
        // I02: the caller may have cancelled while the controls were being applied or
        // settled. Submitting then would capture a frame nobody is waiting for.
        if Task.isCancelled {
            return Self.cancelledBeforeSubmission(intent: intent, stage: "capture.preSubmitCancelled")
        }
        guard admitNewRequests && lifecycleAdmissionOpen else {
            let failure = CaptureFailure(
                kind: .cancelled(detail: "Admission closed while the controls were being applied, so this request was not submitted."),
                operation: "capture.admissionRecheck")
            return CaptureRequestResult(
                captureID: intent.captureID,
                acquisition: .failed(failure),
                committedReceipts: [],
                pendingTransactionIDs: [],
                failures: [failure])
        }

        // Final check immediately before the native submission: nothing above this line
        // has asked the hardware for a frame.
        if Task.isCancelled {
            return Self.cancelledBeforeSubmission(intent: intent, stage: "capture.preBeginCapture")
        }
        #if DEBUG
        let submissionBegan = clock.now()
        #endif
        handedToNativeDrain = true
        let ticket = await camera.beginCapture(intent: intent)
        #if DEBUG
        print("TruongCam timing native-submission=\(Int((clock.now() - submissionBegan) * 1000))ms capture=\(intent.captureID)")
        #endif
        return await drain(ticket: ticket, intent: intent)
    }



    /// Observes the device until the requested controls actually converge.
    ///
    /// Returns the request-ready reading, or nil when the deadline passes without one. The
    /// acknowledgement is consulted FIRST because a service that can already prove
    /// convergence should not be polled; anything else is observed through the live
    /// readback, which is the only thing that reports device state.
    ///
    /// The control-settling watchdog, per CONTRACTS.md.
    ///
    /// The contract requires an exposure-related wait to allow at least
    /// `max(5 seconds, 2 × longest selected/planned duration + 1 second)`, so a legal
    /// long exposure is never rejected merely because a fixed short timeout was too
    /// short. These are policy values, not device measurements.
    static let minimumSettleDeadlineSeconds: Double = 5.0
    static let settlePollIntervalNanoseconds: UInt64 = 20_000_000

    /// The duration-aware settle deadline for one frozen request.
    ///
    /// `longestPlannedDurationSeconds` is the longest exposure this sequence intends to
    /// take, so a step of a bracket is not judged against only its own short duration.
    static func settleDeadlineSeconds(
        for intent: CaptureIntent,
        longestPlannedDurationSeconds: Double? = nil
    ) -> Double {
        settleDeadlineSeconds(
            ownDurationSeconds: intent.exposure.durationTargetSeconds ?? 0,
            longestPlannedDurationSeconds: longestPlannedDurationSeconds)
    }

    /// The pure form of the same policy, so the formula is testable on its own.
    static func settleDeadlineSeconds(
        ownDurationSeconds: Double,
        longestPlannedDurationSeconds: Double? = nil
    ) -> Double {
        let planned = longestPlannedDurationSeconds ?? ownDurationSeconds
        let longest = max(ownDurationSeconds, planned)
        guard longest.isFinite, longest > 0 else { return minimumSettleDeadlineSeconds }
        return max(minimumSettleDeadlineSeconds, 2 * longest + 1)
    }

    private func awaitControlSettlement(
        acknowledgement: AppliedControlSnapshot,
        for intent: CaptureIntent,
        longestPlannedDurationSeconds: Double?
    ) async -> AppliedControlSnapshot? {
        if Self.applicationIsReadyForCapture(acknowledgement, for: intent) { return acknowledgement }

        let deadline = clock.now() + Self.settleDeadlineSeconds(
            for: intent, longestPlannedDurationSeconds: longestPlannedDurationSeconds)
        while clock.now() < deadline {
            guard !Task.isCancelled else { return nil }
            if let readback = await camera.currentControlReadback(),
               Self.applicationIsReadyForCapture(readback, for: intent) {
                return readback
            }
            try? await Task.sleep(nanoseconds: Self.settlePollIntervalNanoseconds)
        }
        return nil
    }

    /// A single, fully-Auto snapshot has no fixed numeric 3A endpoint. Confirm
    /// this request's live modes, bias and real measurements, then let the native
    /// photo request sample the current scene. Never promote it to "settled".
    /// Manual, priority, locked-focus, timer and sequence work retain the strict
    /// convergence policy below. Even a `.single` carrying sequence identity is
    /// refused this shortcut, so a malformed sequence cannot take the Auto path.
    static func applicationIsReadyForCapture(
        _ snapshot: AppliedControlSnapshot,
        for intent: CaptureIntent
    ) -> Bool {
        if applicationIsComplete(snapshot, for: intent) { return true }
        guard intent.mode == .single, intent.sequenceID == nil, intent.sequenceOrdinal == nil,
              intent.exposure.mode == .auto, intent.focus.mode == .continuousAuto,
              intent.whiteBalance.mode == .auto,
              snapshot.generation == intent.configurationGeneration,
              snapshot.requestRevision == controlRevision(for: intent),
              snapshot.settlement.isLiveObservation,
              snapshot.exposureChoice.mode == .auto,
              (snapshot.focusMode == .continuousAuto || (snapshot.isFixedFocusCamera && snapshot.isFocusAdjusting == false)), snapshot.whiteBalanceMode == .auto,
              closeEnough(snapshot.biasEV, intent.biasEV),
              let duration = snapshot.observedDurationSeconds, duration.isFinite, duration > 0,
              let iso = snapshot.observedISO, iso.isFinite, iso > 0,
              let position = snapshot.focusPosition, position.isFinite, (0...1).contains(position),
              let gains = snapshot.whiteBalanceGains,
              gains.red.isFinite, gains.green.isFinite, gains.blue.isFinite,
              gains.red > 0, gains.green > 0, gains.blue > 0 else { return false }
        return true
    }

    /// True when an observation actually satisfies the frozen request.
    ///
    /// H01: the device's own convergence signal is required, and every manual value the
    /// intent pins must be present and within tolerance. A reading that measures an
    /// unrelated field cannot stand in for a pinned one.
    static func applicationIsComplete(
        _ snapshot: AppliedControlSnapshot,
        for intent: CaptureIntent
    ) -> Bool {
        guard snapshot.generation == intent.configurationGeneration else { return false }
        // REVIEW.md I01: the reading must belong to THIS request. A snapshot carrying no
        // revision (or another request's) is evidence about some other application, so
        // it cannot authorize this submission.
        guard snapshot.requestRevision == controlRevision(for: intent) else { return false }
        guard snapshot.settlement.isSettled else { return false }
        // J01: the MODE must agree before any numeric comparison. A manual snapshot
        // cannot authorize an Auto request merely because Auto pins no number.
        guard snapshot.exposureChoice.mode == intent.exposure.mode else { return false }
        // Bias is an applied value too, so a reading taken under a different bias is not
        // this request's.
        guard closeEnough(snapshot.biasEV, intent.biasEV) else { return false }
        if let duration = intent.exposure.durationTargetSeconds {
            guard let observed = snapshot.observedDurationSeconds,
                  closeEnough(observed, duration) else { return false }
        }
        if let iso = intent.exposure.isoTarget {
            guard let observed = snapshot.observedISO, closeEnough(observed, iso) else {
                return false
            }
        }
        // Focus: the MODE must match, and a manual request must be confirmed by the
        // measured lens position.
        switch intent.focus.mode {
        case .manual:
            guard snapshot.focusMode == .manual, !snapshot.isFixedFocusCamera else { return false }
            guard let position = intent.focus.position,
                  let observed = snapshot.focusPosition, closeEnough(observed, position) else {
                return false
            }
        case .continuousAuto:
            guard snapshot.focusMode == .continuousAuto || (snapshot.isFixedFocusCamera && snapshot.isFocusAdjusting == false) else { return false }
        case .lockedAuto:
            // The request asked for a one-shot lock; the observation must not still be
            // reporting continuous autofocus.
            guard snapshot.focusMode != .continuousAuto else { return false }
        }
        // White balance: a manual request pins gains derived from its temperature and
        // tint, so an Auto reading — which reports no gains — cannot confirm it
        // (REVIEW.md I01). The resolved numeric target is checked by the caller that
        // holds the device limits; here the MODE and the PRESENCE of measured gains are
        // what separate a real manual reading from an unrelated Auto one.
        switch intent.whiteBalance.mode {
        case .manual:
            guard intent.whiteBalance.temperatureAndTint != nil else { return false }
            guard snapshot.whiteBalanceMode == .manual else { return false }
            guard let gains = snapshot.whiteBalanceGains,
                  gains.red.isFinite, gains.green.isFinite, gains.blue.isFinite,
                  gains.red > 0, gains.green > 0, gains.blue > 0 else { return false }
        case .auto:
            guard snapshot.whiteBalanceMode == .auto else { return false }
        }
        return true
    }

    /// Relative-plus-absolute tolerance, matching the settlement rule. An engineering
    /// tolerance, not a device measurement.
    static func closeEnough(_ measured: Double, _ requested: Double) -> Bool {
        guard measured.isFinite, requested.isFinite else { return false }
        return abs(measured - requested) <= max(0.05 * abs(requested), 1e-4)
    }

    /// The result for a request cancelled while it was still UNSUBMITTED.
    ///
    /// Nothing was asked of the hardware, so this reports no acquisition and no
    /// retained source (REVIEW.md I02).
    static func cancelledBeforeSubmission(
        intent: CaptureIntent,
        stage: String
    ) -> CaptureRequestResult {
        let failure = CaptureFailure(
            kind: .cancelled(detail: "The request was cancelled before it was submitted, so no frame was requested."),
            operation: stage)
        return CaptureRequestResult(
            captureID: intent.captureID,
            acquisition: .failed(failure),
            committedReceipts: [],
            pendingTransactionIDs: [],
            failures: [failure])
    }

    /// A timestamp decision: the instant, where it came from, and its offset.
    struct CaptureTimestamp: Sendable {
        let instant: Date
        let provenance: CaptureTimeProvenance
        let offsetSeconds: Int
    }

    /// Chooses the capture instant, its provenance and its offset as ONE decision.
    ///
    /// REVIEW.md I06:
    ///   * a trustworthy offset-bearing EXIF timestamp is `captureMetadata` with that
    ///     EXIF offset — never relabelled as a request or as proofless UTC;
    ///   * an EXIF timestamp WITHOUT a usable offset is timezone-free evidence, so it
    ///     falls back to the frozen request rather than being asserted as UTC;
    ///   * a verified device-to-Unix clock mapping is `convertedCaptureClock`;
    ///   * anything else is the frozen request's own stamp, `requestTimestamp`.
    static func captureTimestamp(
        exif: SourceEXIF,
        representation: DeliveredRAWRepresentation,
        captureClockOffset: TimeInterval?,
        intent: CaptureIntent
    ) -> CaptureTimestamp {
        if let instant = exif.capturedAt, let offset = exif.exifUTCOffsetSeconds {
            return CaptureTimestamp(
                instant: instant, provenance: .captureMetadata, offsetSeconds: offset)
        }
        if let offset = captureClockOffset, let deviceStamp = representation.timestampSeconds {
            // J06: the conversion uses the REPRESENTATION's own device-clock timestamp
            // and the mapping's documented relation (device stamp minus the mapping
            // offset). Using the request's creation time would claim a clock
            // relationship between two unrelated clocks.
            let deviceSeconds = deviceStamp
            return CaptureTimestamp(
                instant: Date(timeIntervalSince1970: deviceSeconds - offset),
                provenance: .convertedCaptureClock,
                offsetSeconds: intent.timezoneOffsetSeconds)
        }
        // No usable capture-clock evidence: the frozen request is the only honest
        // source, and its offset travels with it.
        return CaptureTimestamp(
            instant: intent.createdAtUTC,
            provenance: .requestTimestamp,
            offsetSeconds: intent.timezoneOffsetSeconds)
    }

    /// The revision a frozen intent is applied under.
    ///
    /// A `CaptureIntent` carries no UI revision. Using its own creation stamp keeps
    /// applications ordered without pretending the step is a newer user request
    /// (REVIEW.md G03).
    static func controlRevision(for intent: CaptureIntent) -> UInt64 {
        UInt64(max(0, intent.createdAtUTC.timeIntervalSince1970 * 1000))
    }

    /// Drains one submitted request: every delivered representation is staged
    /// promptly, then each staged source is committed. Partial acquisition keeps
    /// its intact sources.
    func drain(ticket: any CaptureRequestTicket, intent: CaptureIntent) async -> CaptureRequestResult {
        // REVIEW.md I02: the request has ALREADY been submitted by the time this runs, so
        // the acquisition is loss-critical and must outlive the caller. An unstructured
        // `Task` does NOT inherit the enclosing task's cancellation, unlike the
        // `withTaskGroup` reader inside `performDrain` — which previously exited while
        // the channel was empty and stranded a later RAW representation. The caller may
        // stop waiting; the bytes are still retained.
        // T02: the service's teardown gate is told that this submitted request still owns
        // bytes until the retained drain has actually finished staging them.
        if let reporting = camera as? any StagingOwnershipReporting {
            reporting.noteStagingStarted(intent.captureID)
        }
        let retained = Task { [weak self] in
            defer {
                if let reporting = self?.camera as? any StagingOwnershipReporting {
                    reporting.noteStagingFinished(intent.captureID)
                }
            }
            guard let self else {
                return CaptureRequestResult(
                    captureID: intent.captureID,
                    acquisition: .failed(CaptureFailure(
                        kind: .captureFailed(detail: "The coordinator was released before the drain completed."),
                        operation: "drain")),
                    committedReceipts: [], pendingTransactionIDs: [], failures: [])
            }
            return await self.performDrain(ticket: ticket, intent: intent)
        }
        return await retained.value
    }

    /// The actual drain. Never call this directly: it inherits cancellation, and a
    /// submitted request must not be abandoned (REVIEW.md I02).
    private func performDrain(ticket: any CaptureRequestTicket, intent: CaptureIntent) async -> CaptureRequestResult {
        #if DEBUG
        let drainBegan = clock.now()
        #endif
        let cueStream = ticket.shutterFeedbackEvents
        let cues = Task { [shutterFeedback] in
            for await cue in cueStream {
                guard !Task.isCancelled else { return }
                guard cue.captureID == intent.captureID, cue.generation == intent.configurationGeneration,
                      cue.sequenceID == intent.sequenceID else { continue }
                shutterFeedback.send(cue)
            }
        }
        defer { cues.cancel() }
        var handles: [StagedSourceHandle] = []
        var failures: [CaptureFailure] = []

        // Stage representations concurrently with the terminal wait so a source
        // delivered before an error is still written to durable storage.
        await withTaskGroup(of: Void.self) { group in
            group.addTask { [weak self] in
                guard let self else { return }
                // K02: the request-owned transfer admits ONE retained drain and
                // privately consumes every callback. There is no returned iterator a
                // copy could use to divert a record.
                let stream = ticket.representationStream()
                await stream.drainAll { representation in
                    do {
                        let handle = try await self.stage(
                            representation: representation,
                            intent: intent,
                            readback: await self.readback(for: intent.captureID))
                        await self.record(handle: handle, for: intent.captureID)
                    } catch let failure as CaptureFailure {
                        await self.appendFailure(failure, to: intent.captureID)
                    } catch {
                        await self.appendFailure(
                            CaptureFailure(kind: .captureFailed(detail: "\(error)"),
                                           operation: "stageRepresentation"),
                            to: intent.captureID)
                    }
                }
            }
            group.addTask {
                // Await the recorded outcome so both tasks finish only after the
                // native layer has actually reported. Any number of consumers may
                // await the same value.
                _ = await ticket.awaitTerminal()
            }
            await group.waitForAll()
        }
        #if DEBUG
        // Includes source delivery, native terminal and durable staging, which
        // overlap. It deliberately excludes the subsequent provider commit.
        print("TruongCam timing native-delivery-through-staging=\(Int((clock.now() - drainBegan) * 1000))ms capture=\(intent.captureID)")
        #endif

        handles = stagedByCaptureID.removeValue(forKey: intent.captureID) ?? []
        failures.append(contentsOf: failureLog.removeValue(forKey: intent.captureID) ?? [])

        // REVIEW.md C01: never infer success. The outcome is the recorded native
        // result; if a channel refused a representation, that is a real delivery
        // failure and is reported separately from a native error.
        let acquisition = await ticket.awaitTerminal()
        // Native failure and source persistence are independent. A retained
        // original must not turn a partial native request into sequence success,
        // and a zero-source error must keep the actual native diagnostic.
        let nativeFailure = ticket.terminalFailure()
        let overflowed = ticket.representationsOverflowed()
        if overflowed > 0 {
            failures.append(CaptureFailure(
                kind: .operationStalled(
                    detail: "\(overflowed) delivered RAW representation(s) exceeded the bounded staging backlog and were refused; the retained sources are incomplete."),
                operation: "drainRepresentations",
                retainedSourceStatus: handles.isEmpty ? .none : .inMemoryRepresentationUnstaged))
        }

        // Commit first, then reconcile against what is DURABLE. REVIEW.md S01:
        // the previous code computed `reconciled` and immediately discarded it
        // with `_ = reconciled`, so the returned result used the raw native
        // outcome and a native `.success` with no delivered bytes was reported as
        // success with no receipts and no failures.
        var receipts: [CommitReceipt] = []
        var pendingHandles: [StagedSourceHandle] = []
        #if DEBUG
        let commitBegan = clock.now()
        defer { print("TruongCam timing provider-verified-commit=\(Int((clock.now() - commitBegan) * 1000))ms") }
        #endif
        for handle in handles {
            // Serialize commits: one save at a time.
            do {
                let receipt = try await store.commit(handle: handle)
                receipts.append(receipt)
            } catch let failure as CaptureFailure {
                failures.append(failure)
                // A stage handle proves the bytes existed earlier. Only the
                // exact commit failure's fresh retention evidence establishes
                // that they still exist after this unsuccessful publication.
                if handle.isValid, handle.captureID == intent.captureID,
                   case .durableInternalStaging(let path) = failure.retainedSourceStatus,
                   path == handle.pendingRelativePath {
                    pendingHandles.append(handle)
                }
            } catch {
                // An untyped error establishes no current durable ownership.
                failures.append(CaptureFailure(
                    kind: .providerIOFailed(detail: "\(error)"), operation: "commit"))
            }
        }
        let pending = pendingHandles.map(\.transactionID)
        if let nativeFailure {
            // Native in-memory retention is historical by now. Only an exact
            // surviving pending handle may claim current internal ownership;
            // final folder ownership travels in the verified receipt instead.
            let retained: RetainedSourceStatus = pendingHandles.first.map {
                .durableInternalStaging(relativePath: $0.pendingRelativePath)
            } ?? .none
            failures.append(CaptureFailure(kind: nativeFailure.kind, operation: nativeFailure.operation,
                retainedSourceStatus: retained, nsErrorDomain: nativeFailure.nsErrorDomain,
                nsErrorCode: nativeFailure.nsErrorCode, underlyingDescription: nativeFailure.underlyingDescription))
        }

        // Actual durable evidence: a verified receipt, or bytes still held in
        // our own durable staging. A native callback's claimed count is NEVER
        // used as evidence of retention (CONTRACTS.md: the acquisition status is
        // not persistence truth).
        let durableRetainedCount = receipts.count + pending.count
        let reconciled = Self.reconcile(
            acquisition: acquisition,
            durableRetainedCount: durableRetainedCount,
            stagedSourceCount: handles.count,
            unexplainedFailureCount: failures.count)

        readbacksByCaptureID.removeValue(forKey: intent.captureID)
        verifiedSnapshotsByCaptureID.removeValue(forKey: intent.captureID)
        return CaptureRequestResult(
            captureID: intent.captureID,
            acquisition: reconciled,
            committedReceipts: receipts,
            pendingTransactionIDs: pending,
            failures: failures,
            pendingHandles: pendingHandles)
    }

    /// Reconciles a native outcome against ACTUAL durable retention.
    ///
    /// Rules (REVIEW.md S01):
    ///   * a native claim is never evidence of retention;
    ///   * a terminal error with retained bytes becomes
    ///     `partialWithRetainedSource`, so the sources survive while the request
    ///     is not reported as complete;
    ///   * native `.success` with nothing durable is a failure, so a zero-source
    ///     result cannot leave the UI showing "Saving" or let a sequence reach
    ///     complete;
    ///   * bytes that reached durable staging but failed to commit keep their real
    ///     failure detail instead of being flattened into a success.
    static func reconcile(
        acquisition: NativeRequestOutcome,
        durableRetainedCount: Int,
        stagedSourceCount: Int,
        unexplainedFailureCount: Int
    ) -> NativeRequestOutcome {
        switch acquisition {
        case .failed(let failure):
            if durableRetainedCount > 0 {
                return .partial(retainedSourceCount: durableRetainedCount,
                                description: failure.kind.userDescription)
            }
            // Staged-but-uncommitted bytes are still held and still a failure.
            return .failed(failure)
        case .partial(_, let description):
            if durableRetainedCount == 0 {
                return .failed(CaptureFailure(
                    kind: .representationUnavailable(detail: description),
                    operation: "capture"))
            }
            return .partial(retainedSourceCount: durableRetainedCount, description: description)
        case .success:
            if durableRetainedCount == 0 {
                let detail = stagedSourceCount > 0
                    ? "The camera reported success and \(stagedSourceCount) source(s) were staged, but none could be verified into the library folder."
                    : "The camera reported success but no RAW representation reached durable storage."
                return .failed(CaptureFailure(
                    kind: .representationUnavailable(detail: detail),
                    operation: "capture",
                    // Historical staging does not prove bytes remain on disk
                    // or in memory after an unsuccessful commit.
                    retainedSourceStatus: .none))
            }
            if unexplainedFailureCount > 0 {
                return .partial(
                    retainedSourceCount: durableRetainedCount,
                    description: "Some save operations failed; the retained sources are incomplete.")
            }
            return .success
        }
    }

    private var failureLog: [CaptureID: [CaptureFailure]] = [:]

    private func appendFailure(_ failure: CaptureFailure, to captureID: CaptureID) {
        failureLog[captureID, default: []].append(failure)
    }

    private func record(handle: StagedSourceHandle, for captureID: CaptureID) {
        stagedByCaptureID[captureID, default: []].append(handle)
    }

    /// Stages exact RAW bytes into internal recovery storage promptly, without
    /// decoding them, and computes the digest incrementally.
    private func readback(for captureID: CaptureID) -> AppliedControlSnapshot? {
        // J06: the request's OWN verified observation wins over any sampled cache.
        // A later or unrelated reading must not relabel an earlier source's evidence.
        verifiedSnapshotsByCaptureID[captureID] ?? readbacksByCaptureID[captureID]
    }

    /// Records the snapshot that was VERIFIED to satisfy this request, at the moment the
    /// request was authorized. This is the source of truth for the committed sidecar's
    /// focus/white-balance observation (REVIEW.md J06).
    private func recordVerifiedSnapshot(
        _ snapshot: AppliedControlSnapshot,
        for captureID: CaptureID
    ) {
        verifiedSnapshotsByCaptureID[captureID] = snapshot
    }

    private var verifiedSnapshotsByCaptureID: [CaptureID: AppliedControlSnapshot] = [:]
    /// Bounded request bookkeeping, exposed as counts for lifetime regression checks.
    var retainedReadbackCount: Int { readbacksByCaptureID.count }
    var retainedVerifiedSnapshotCount: Int { verifiedSnapshotsByCaptureID.count }

    private func stage(
        representation: DeliveredRAWRepresentation,
        intent: CaptureIntent,
        readback: AppliedControlSnapshot?
    ) async throws -> StagedSourceHandle {
        #if DEBUG
        let stageBegan = clock.now()
        defer { print("TruongCam timing durable-staging=\(Int((clock.now() - stageBegan) * 1000))ms") }
        #endif
        guard !representation.bytes.isEmpty else {
            throw CaptureFailure(
                kind: .representationUnavailable(detail: "The RAW representation was empty."),
                operation: "stageSource")
        }
        // A RAW-only request must never accept processed bytes.
        guard Self.acceptsRepresentation(representation, for: intent, classifier: bayerClassifier) else {
            throw CaptureFailure(
                kind: .unsupportedCapability(
                    detail: "The delivered photo was not a Bayer RAW representation (pixel format \(FourCC.string(from: representation.rawPixelFormatType)))."),
                operation: "stageSource")
        }

        let metadata = makeMetadata(representation: representation, intent: intent, readback: readback)
        return try await store.stageSource(bytes: representation.bytes, metadata: metadata)
    }

    static func acceptsRepresentation(_ representation: DeliveredRAWRepresentation, for intent: CaptureIntent, classifier: any BayerRAWClassifying) -> Bool {
        if intent.fileFormat == .jpeg {
            return representation.isJPEG
        } else if intent.fileFormat == .frontHEIF {
            return intent.physicalCameraKind == .front && representation.isHEIF
        }
        return !representation.isHEIF && classifier.isBayerRAW(representation.rawPixelFormatType)
    }

    /// How much a device readback may claim about the captured source.
    ///
    /// REVIEW.md R03/R04: `.settledDeviceReadback` asserts the setter finished and
    /// the device converged. A readback with no value is `.unknown`; a readback
    /// that is still moving (or that never reported a measurement) is only
    /// `.requested` — the user asked for it, and nothing has confirmed the source
    /// ever reached it.
    static func readbackProvenance(
        hasValue: Bool,
        settlement: ControlSettlementState?
    ) -> ValueProvenance {
        guard hasValue else { return .unknown }
        guard let settlement else { return .requested }
        return settlement.isSettled ? .settledDeviceReadback : .requested
    }

    private func makeMetadata(
        representation: DeliveredRAWRepresentation,
        intent: CaptureIntent,
        readback: AppliedControlSnapshot?
    ) -> SourceCaptureMetadata {
        // REVIEW.md C05: actual per-source exposure comes from the DELIVERED
        // image's own nested EXIF, not from a pre-capture device readback. The
        // readback is only a fallback for fields the image does not carry, and it
        // is labelled as such so desired/applied/observed/capture truth stay
        // distinguishable.
        let exif = SourceEXIF(metadata: representation.metadata)

        // REVIEW.md R04: this record describes the SOURCE IMAGE. When the delivered
        // image does not carry a field, the honest value is unknown — a pre-capture
        // device readback is not the image's exposure, and substituting it made an
        // absent EXIF field look like measured capture truth.
        //
        // The readback is therefore used ONLY for the two control values the still
        // does not carry at all (focus position and white-balance gains), and only
        // when its own settlement state supports the claim.
        let readbackFocusProvenance = Self.readbackProvenance(
            hasValue: readback?.focusPosition != nil,
            settlement: readback?.settlement)
        let readbackWhiteBalanceProvenance = Self.readbackProvenance(
            hasValue: readback?.whiteBalanceGains != nil,
            settlement: readback?.settlement)

        let observed = SourceObservedRecord(
            rawDimensions: representation.rawPhotoDimensions,
            durationSeconds: exif.exposureTimeSeconds,
            iso: exif.isoSpeed,
            aperture: exif.aperture,
            focalLengthMM: exif.focalLengthMM,
            orientation: exif.orientation,
            focus: FocusObservedRecord(
                position: readback?.focusPosition,
                provenance: readbackFocusProvenance),
            whiteBalance: WhiteBalanceObservedRecord(
                gains: readback?.whiteBalanceGains,
                provenance: readbackWhiteBalanceProvenance))

        // One decision, three consistent outputs (REVIEW.md I06).
        let stamp = Self.captureTimestamp(
            exif: exif, representation: representation,
            captureClockOffset: captureClockOffset, intent: intent)

        return SourceCaptureMetadata(
            captureID: intent.captureID,
            libraryID: intent.libraryID,
            capturedAtUTC: stamp.instant,
            capturedAtProvenance: stamp.provenance,
            timezoneOffsetSeconds: stamp.offsetSeconds,
            format: representation.isJPEG ? .jpeg : (representation.isHEIF ? .frontHEIF : SourceFormatRecord(rawPixelFormat: representation.rawPixelFormatType)),
            deviceModel: DeviceModelName.value,
            osVersion: OperatingSystemVersionName.value,
            cameraDeviceType: intent.physicalCameraKind.rawValue,
            requested: CaptureRequestRecord(
                maxDimensions: intent.requestedDimensions,
                exposure: ExposureRequestRecord(
                    mode: intent.exposure.mode,
                    durationSeconds: intent.exposure.durationTargetSeconds,
                    iso: intent.exposure.isoTarget,
                    biasEV: intent.biasEV),
                focus: FocusRequestRecord(mode: intent.focus.mode, position: intent.focus.position),
                whiteBalance: WhiteBalanceRequestRecord(
                    mode: intent.whiteBalance.mode,
                    temperatureKelvin: intent.whiteBalance.temperatureAndTint?.temperature,
                    tint: intent.whiteBalance.temperatureAndTint?.tint)),
            observed: observed,
            acquisitionStatus: representation.rawPhotoDimensions == nil
                ? .partialWithRetainedSource
                : .complete,
            sequence: sequenceLink(for: intent, sourceEXIF: exif),
            equivalentFocalLengthMM: intent.equivalentFocalLengthMM)
    }

    /// Captured per request. A readback taken after a later capture is not this
    /// image's observed state, so each request carries its own snapshot rather
    /// than sharing a mutable cache across concurrent work.
    private var readbacksByCaptureID: [CaptureID: AppliedControlSnapshot] = [:]
    private var captureClockOffset: TimeInterval?

    func noteReadback(_ snapshot: AppliedControlSnapshot?, for captureID: CaptureID) {
        if let snapshot {
            readbacksByCaptureID[captureID] = snapshot
        } else {
            readbacksByCaptureID.removeValue(forKey: captureID)
        }
    }

    func noteCaptureClockOffset(_ offset: TimeInterval?) {
        captureClockOffset = offset
    }

    private func captureTime(
        for representation: DeliveredRAWRepresentation,
        intent: CaptureIntent
    ) -> Date {
        if let offset = captureClockOffset, let seconds = representation.timestampSeconds {
            // Convert a capture-clock timestamp to wall clock through the measured
            // offset; never treat CMTime seconds as Unix time.
            return Date(timeIntervalSince1970: seconds - offset)
        }
        if let exifDate = SourceEXIF(metadata: representation.metadata).capturedAt {
            return exifDate
        }
        return intent.createdAtUTC
    }

    private func sequenceLink(
        for intent: CaptureIntent,
        sourceEXIF: SourceEXIF
    ) -> SourceSequenceLink? {
        guard let sequenceID = intent.sequenceID, let ordinal = intent.sequenceOrdinal else { return nil }
        return SourceSequenceLink(
            id: sequenceID,
            kind: intent.mode.sequenceKind,
            index: ordinal,
            plannedCount: intent.sequencePlannedCount ?? 1,
            requestedOffsetEV: intent.requestedOffsetEV,
            // From the delivered source's own EXIF, never a pre-capture readback.
            actualOffsetEV: Self.achievedOffsetEV(
                requestedOffsetEV: intent.requestedOffsetEV,
                baselineISO: intent.baselineISO,
                baselineDurationSeconds: intent.baselineDurationSeconds,
                sourceISO: sourceEXIF.isoSpeed,
                sourceDurationSeconds: sourceEXIF.exposureTimeSeconds),
            deadlineOrdinal: intent.deadlineOrdinal)
    }

    /// Achieved EV offset from the DELIVERED source's own EXIF exposure.
    ///
    /// REVIEW.md F03/F04: this used to combine the baseline with a PRE-CAPTURE device
    /// readback. A readback describes a different moment, so the achieved offset could
    /// disagree with the bytes actually stored. Only the source image's own ISO and
    /// exposure time may be used; when either is absent the achieved offset is
    /// UNKNOWN rather than copied from the request.
    static func achievedOffsetEV(
        requestedOffsetEV: Double?,
        baselineISO: Double?,
        baselineDurationSeconds: Double?,
        sourceISO: Double?,
        sourceDurationSeconds: Double?
    ) -> Double? {
        // No requested offset means the plan did not ask for one, so there is nothing
        // to compare against.
        guard requestedOffsetEV != nil else { return nil }
        guard let baselineISO, let baselineDuration = baselineDurationSeconds,
              let sourceISO, let sourceDuration = sourceDurationSeconds,
              baselineISO > 0, baselineDuration > 0,
              sourceISO > 0, sourceDuration > 0 else {
            // Absent source exposure stays unknown. Returning the requested value
            // would present the plan's intent as measured capture truth.
            return nil
        }
        let baselineProduct = baselineISO * baselineDuration
        let sourceProduct = sourceISO * sourceDuration
        guard baselineProduct > 0, sourceProduct > 0 else { return nil }
        let actual = log2(sourceProduct / baselineProduct)
        return actual.isFinite ? actual : nil
    }

    /// Parses the delivered image's own metadata.
    ///
    /// REVIEW.md C05: the previous helpers looked for flattened top-level keys
    /// (`kCGImagePropertyExifFocalLength as String`) in a dictionary that is
    /// actually nested under `kCGImagePropertyExifDictionary`. Nothing matched, so
    /// every sidecar recorded the pre-capture readback as if it were capture truth.
    /// This walks the real ImageIO structure.
    private func exifValue(_ key: CFString, in metadata: [String: Any]) -> Any? {
        if let direct = metadata[key as String] { return direct }
        if let exif = metadata[kCGImagePropertyExifDictionary as String] as? [String: Any],
           let nested = exif[key as String] {
            return nested
        }
        if let tiff = metadata[kCGImagePropertyTIFFDictionary as String] as? [String: Any],
           let nested = tiff[key as String] {
            return nested
        }
        return nil
    }

    private func exifDouble(_ key: CFString, in metadata: [String: Any], allowZero: Bool = false) -> Double? {
        let raw = exifValue(key, in: metadata)
        let value: Double?
        if let number = raw as? NSNumber {
            value = number.doubleValue
        } else if let text = raw as? String {
            value = Double(text)
        } else {
            value = nil
        }
        guard let value, value.isFinite else { return nil }
        if !allowZero, value <= 0 { return nil }
        return value
    }

    private func exifInt(_ key: CFString, in metadata: [String: Any]) -> Int? {
        if let number = exifValue(key, in: metadata) as? NSNumber { return number.intValue }
        if let text = exifValue(key, in: metadata) as? String { return Int(text) }
        return nil
    }


    /// Stages and commits one representation the native layer already delivered
    /// for a known intent. Used by the native bracket path, where bytes arrive
    /// through callbacks rather than through `beginCapture` per source.
    func persistDelivered(
        representation: DeliveredRAWRepresentation,
        intent: CaptureIntent
    ) async -> SingleCaptureExecutionResult {
        let readback = readbacksByCaptureID[intent.captureID]
        do {
            let handle = try await stage(
                representation: representation, intent: intent, readback: readback)
            do {
                let receipt = try await store.commit(handle: handle)
                return SingleCaptureExecutionResult(
                    captureID: intent.captureID,
                    terminalStatus: .success,
                    persistence: .committed(receipt),
                    stagedHandle: handle,
                    receipt: receipt,
                    failure: nil)
            } catch let failure as CaptureFailure {
                // A historical staging handle is not current retention proof.
                // Match the ordinary drain's exact post-commit evidence rule.
                let isStillOwned: Bool
                if handle.isValid, handle.captureID == intent.captureID,
                   case .durableInternalStaging(let path) = failure.retainedSourceStatus,
                   path == handle.pendingRelativePath {
                    isStillOwned = true
                } else { isStillOwned = false }
                return SingleCaptureExecutionResult(
                    captureID: intent.captureID,
                    terminalStatus: isStillOwned
                        ? .partialWithRetainedSource(errorDescription: failure.kind.userDescription)
                        : .failed(errorDescription: failure.kind.userDescription),
                    persistence: isStillOwned
                        ? .pendingRetry(failure: failure, retained: .durableInternalStaging(relativePath: handle.pendingRelativePath))
                        : .failed(failure: failure),
                    stagedHandle: isStillOwned ? handle : nil,
                    receipt: nil,
                    failure: failure)
            }
        } catch let failure as CaptureFailure {
            return SingleCaptureExecutionResult(
                captureID: intent.captureID,
                terminalStatus: .failed(errorDescription: failure.kind.userDescription),
                persistence: .failed(failure: failure),
                stagedHandle: nil,
                receipt: nil,
                failure: failure)
        } catch {
            let failure = CaptureFailure(kind: .captureFailed(detail: "\(error)"), operation: "persistDelivered")
            return SingleCaptureExecutionResult(
                captureID: intent.captureID,
                terminalStatus: .failed(errorDescription: failure.kind.userDescription),
                persistence: .failed(failure: failure),
                stagedHandle: nil,
                receipt: nil,
                failure: failure)
        }
    }

    // MARK: - Recovery

    /// Retries persistence of an already-staged source under its own identity.
    func retryPending(transactionID: TransactionID) async -> Result<CommitReceipt, CaptureFailure> {
        do {
            return .success(try await store.retry(transactionID: transactionID))
        } catch let failure as CaptureFailure {
            return .failure(failure)
        } catch {
            return .failure(CaptureFailure(kind: .providerIOFailed(detail: "\(error)"), operation: "retryPending"))
        }
    }
}

/// Typed view over one delivered image's own metadata.
///
/// Every accessor returns nil when the field is genuinely absent, so an unknown
/// value stays unknown rather than becoming zero (CONTRACTS.md).
/// Deliberately NOT `Sendable`: it wraps an ImageIO `[String: Any]` dictionary,
/// which cannot be. It is constructed and consumed synchronously inside one
/// capture path and never crosses an isolation boundary.
struct SourceEXIF {
    private let metadata: [String: Any]

    init(metadata: [String: Any]) {
        self.metadata = metadata
    }

    private func value(_ key: CFString) -> Any? {
        if let direct = metadata[key as String] { return direct }
        if let exif = metadata[kCGImagePropertyExifDictionary as String] as? [String: Any],
           let nested = exif[key as String] {
            return nested
        }
        if let tiff = metadata[kCGImagePropertyTIFFDictionary as String] as? [String: Any],
           let nested = tiff[key as String] {
            return nested
        }
        return nil
    }

    private func positiveDouble(_ key: CFString) -> Double? {
        let raw = value(key)
        let number: Double?
        if let nsNumber = raw as? NSNumber {
            number = nsNumber.doubleValue
        } else if let text = raw as? String {
            number = Double(text)
        } else {
            number = nil
        }
        guard let number, number.isFinite, number > 0 else { return nil }
        return number
    }

    var exposureTimeSeconds: Double? { positiveDouble(kCGImagePropertyExifExposureTime) }
    var isoSpeed: Double? {
        // EXIF stores ISO as an array of ratings. A zero or non-finite entry is an
        // absent measurement, not a valid reading, so it must not be returned.
        if let direct = positiveDouble(kCGImagePropertyExifISOSpeedRatings) { return direct }
        if let ratings = value(kCGImagePropertyExifISOSpeedRatings) as? [NSNumber] {
            for rating in ratings {
                let value = rating.doubleValue
                if value.isFinite, value > 0 { return value }
            }
        }
        if let text = value(kCGImagePropertyExifISOSpeedRatings) as? String,
           let parsed = Double(text), parsed.isFinite, parsed > 0 {
            return parsed
        }
        return nil
    }
    var aperture: Double? { positiveDouble(kCGImagePropertyExifFNumber) }
    var focalLengthMM: Double? { positiveDouble(kCGImagePropertyExifFocalLength) }
    var orientation: Int? {
        let raw = value(kCGImagePropertyOrientation)
        let intValue = (raw as? NSNumber)?.intValue ?? (raw as? String).flatMap(Int.init)
        guard let intValue, (1...8).contains(intValue) else { return nil }
        return intValue
    }
    /// The capture instant, honouring an EXIF UTC offset when the image carries one.
    ///
    /// REVIEW.md H01: `DateTimeOriginal` is LOCAL wall-clock time. Parsing it alone and
    /// treating the result as UTC misreports the instant. When
    /// `OffsetTimeOriginal` (or the TIFF `OffsetTime`) is present and valid, the wall
    /// clock is interpreted in that offset. A timezone-free timestamp is returned as
    /// the naive instant the formatter produces, and the CALLER decides provenance —
    /// it is never silently relabelled as UTC-proven.
    var capturedAt: Date? {
        let text = value(kCGImagePropertyExifDateTimeOriginal) as? String
            ?? value(kCGImagePropertyTIFFDateTime) as? String
        guard let text, let wallClock = EXIFDateFormatter.shared.date(from: text) else {
            return nil
        }
        guard let offsetSeconds = exifUTCOffsetSeconds else { return wallClock }
        // `wallClock` was built as if the text were UTC, so shifting by the declared
        // offset yields the true instant.
        return wallClock.addingTimeInterval(-Double(offsetSeconds))
    }

    /// The EXIF-declared UTC offset in seconds, when present and well formed.
    ///
    /// Accepts `±HH:MM` and `±HHMM`, which are the documented forms.
    var exifUTCOffsetSeconds: Int? {
        let candidates = [
            value(kCGImagePropertyExifOffsetTimeOriginal) as? String,
            value(kCGImagePropertyExifOffsetTime) as? String,
        ]
        for candidate in candidates {
            guard let text = candidate?.trimmingCharacters(in: .whitespaces), !text.isEmpty else {
                continue
            }
            if let seconds = SourceEXIF.parseUTCOffset(text) { return seconds }
        }
        return nil
    }

    /// Parses `±HH:MM` / `±HHMM`, returning nil for anything not exactly that shape.
    static func parseUTCOffset(_ text: String) -> Int? {
        guard let sign = text.first, sign == "+" || sign == "-" else { return nil }
        let body = text.dropFirst()
        let digits = body.replacingOccurrences(of: ":", with: "")
        guard digits.count == 4, digits.allSatisfy({ $0.isNumber }) else { return nil }
        let hours = Int(digits.prefix(2)) ?? 0
        let minutes = Int(digits.suffix(2)) ?? 0
        guard hours <= 14, minutes < 60 else { return nil }
        let magnitude = hours * 3600 + minutes * 60
        return sign == "-" ? -magnitude : magnitude
    }
}

/// Decides whether a pixel format is genuine Bayer RAW.
///
/// REVIEW.md R05 requires the framework's own answer. The native build supplies
/// `AVCapturePhotoOutput.isBayerRAWPixelFormat(_:)` through this port, so the
/// decision is never a guess about FourCC spelling.
protocol BayerRAWClassifying: Sendable {
    func isBayerRAW(_ pixelFormat: UInt32) -> Bool
}

/// The best answer available to a target that cannot import AVFoundation.
///
/// It accepts ONLY the documented packed-Bayer families and refuses anything it
/// cannot positively identify. A wrong "yes" would let a processed format be
/// stored and labelled genuine Bayer RAW, which the product forbids, so the
/// uncertainty resolves to "no".
struct ConservativeBayerClassifier: BayerRAWClassifying {
    func isBayerRAW(_ pixelFormat: UInt32) -> Bool {
        guard pixelFormat != 0 else { return false }
        let code = FourCC.string(from: pixelFormat).lowercased()
        guard code.count == 4 else { return false }
        // Documented packed-Bayer patterns: a packing marker byte followed by a
        // GG/YY Bayer pair and a bit-depth digit.
        let descriptors = ["gg4", "gg6", "gg8", "ggb", "yy4", "yy6", "yy8", "yyb"]
        let hasBayerPair = descriptors.contains { code.hasSuffix($0) }
        let hasPackingMarker = code.hasPrefix("b") || code.hasPrefix("p") || code.hasPrefix("m")
        return hasBayerPair && hasPackingMarker
    }
}

/// Process-wide model/OS strings used in sidecars. No device identifiers.
enum DeviceModelName {
    static var value: String {
        var systemInfo = utsname()
        uname(&systemInfo)
        let identifier = withUnsafeBytes(of: &systemInfo.machine) { raw -> String in
            let bytes = raw.prefix { $0 != 0 }
            return String(decoding: bytes, as: UTF8.self)
        }
        return identifier.isEmpty ? "unknown" : identifier
    }
}

enum OperatingSystemVersionName {
    static var value: String {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        return "\(version.majorVersion).\(version.minorVersion).\(version.patchVersion)"
    }
}

/// EXIF `DateTimeOriginal` parsing. The EXIF format is fixed-width and local to
/// the capture time zone, so the offset is recorded separately in the sidecar.
final class EXIFDateFormatter: @unchecked Sendable {
    static let shared = EXIFDateFormatter()

    private let lock = NSLock()
    private let formatter: DateFormatter

    private init() {
        formatter = DateFormatter()
        formatter.dateFormat = "yyyy:MM:dd HH:mm:ss"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
    }

    func date(from text: String) -> Date? {
        lock.lock(); defer { lock.unlock() }
        return formatter.date(from: text)
    }
}
