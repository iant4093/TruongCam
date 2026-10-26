import Foundation
import Observation

// P10/P4: the camera screen's model.
//
// The view model owns user intent and display state only. It forwards native
// configuration to the camera service and persistence to the capture pipeline,
// and it never touches a device or the file system itself.
//
// Remembered across launches: composition aids, preferred physical lens and file format.
// Deliberately NOT remembered: manual exposure/focus/white-balance choices. A
// fresh process starts Auto for exposure, focus and white balance.

@MainActor
@Observable
final class CameraViewModel {
    // MARK: Presentation

    private(set) var surface: CameraSurfaceState = .preparing
    /// The view model's own view of the camera lifecycle.
    ///
    /// REVIEW.md F02: this alone is NOT authoritative — the service records native
    /// interruptions, runtime errors and media-services resets that the view model
    /// cannot infer. `effectiveLifecycle` merges both, and every gate uses that.
    private(set) var lifecycle: CameraLifecycle = .idle

    /// The lifecycle the admission gates must use.
    ///
    /// Cached-start state and the service's recorded native condition are combined
    /// through one shared rule, so a native interruption closes the gate even though
    /// the view model never saw it happen.
    var effectiveLifecycle: CameraLifecycle {
        // REVIEW.md I03: `sessionIsRunning` must reflect the SERVICE, not this view
        // model's cache. Passing `lifecycle == .running` let a stale cached running
        // state outvote a service that had already stopped, so an idle camera was
        // admitted as running. The model's own cache is only trusted while the service
        // has NOT reported a settled condition.
        // I03: while THIS model is mid-operation it owns the truth. Letting a service
        // that currently records `.idle` collapse an in-flight `.configuring` into
        // `.idle` defeated `startIfNeeded`'s one-at-a-time guarantee — a duplicate
        // reveal then began a SECOND concurrent start.
        switch lifecycle {
        case .configuring, .requestingPermission, .stopping, .reconfiguring:
            if serviceRecordedCondition == nil { return lifecycle }
        case .idle, .running, .interrupted, .unavailable, .failed:
            break
        }
        return CameraLifecycleResolver.effective(
            recorded: serviceRecordedCondition ?? .idle,
            cachedLifecycle: lifecycle,
            sessionIsRunning: lifecycle == .running)
    }

    /// The most recent condition the SERVICE recorded, pushed here by its observer.
    private(set) var serviceRecordedCondition: CameraLifecycle?
    private var serviceConditionRevision: UInt64 = 0
    private var isRepairingTransientCamera = false
    private var automaticRecoveryAttempted = false
    @ObservationIgnored private var automaticRecoveryTask: Task<Void, Never>?
    // Only an explicit media-services reset reserves the existing enabled tool
    // topology through its rebuild/start. Processing and capture remain closed.
    // A real eligibility change or newer genuine failure revokes this reservation.
    private struct ResetAnalysisTopologyReservation: Equatable {
        let serial: UInt64
        let eligibilityEpoch: Int
    }
    private var resetAnalysisReservationSerial: UInt64 = 0
    private var resetAnalysisTopologyReservation: ResetAnalysisTopologyReservation?
    private var preservesResetAnalysisTopology: Bool {
        isCameraEligibleForCapture && resetAnalysisTopologyReservation?.eligibilityEpoch == eligibilityEpoch
    }
    private func reserveResetAnalysisTopology() {
        guard isCameraEligibleForCapture else { return }
        resetAnalysisReservationSerial &+= 1
        resetAnalysisTopologyReservation = ResetAnalysisTopologyReservation(
            serial: resetAnalysisReservationSerial, eligibilityEpoch: eligibilityEpoch)
        geometry = nil; histogram = nil; masks = nil; loupe = nil
        renderedPreviewLayout = nil
    }

    /// Applied when the service reports a native session condition change.
    ///
    /// This is the missing consumer: previously the service recorded a condition that
    /// nothing read, so an interrupted camera still reported `.running` to the gate.
    /// - Parameter isTransition: true for a condition the service PUSHED (a real
    ///   change), false for the initial read of its current condition. Only a pushed
    ///   stopped condition reconciles this model to idle: the initial read of a service
    ///   that simply reports `.idle` as its baseline must not stop a camera this model
    ///   has just started (REVIEW.md I03).
    func applyServiceCondition(_ condition: CameraLifecycle?, isTransition: Bool = true) async {
        serviceConditionRevision &+= 1
        let conditionRevision = serviceConditionRevision
        let previous = serviceRecordedCondition
        serviceRecordedCondition = condition
        switch condition {
        case .failed(.cameraInterrupted(let detail)) where MediaServicesResetSignal.matches(detail: detail):
            reserveResetAnalysisTopology()
        case .failed, .interrupted, .unavailable, .idle, .stopping, .none:
            resetAnalysisTopologyReservation = nil
        default: break
        }
        // I03: a service that reports it is idle/stopped is authoritative about not
        // running. Reconciling HERE (rather than in `effectiveLifecycle`) keeps a
        // just-started camera reported as running, while an externally stopped service
        // still cannot be admitted as running.
        if isTransition {
            switch condition {
            case .some(.idle), .some(.stopping):
                if case .running = lifecycle { lifecycle = .idle }
            default:
                break
            }
        }
        switch condition {
        case .interrupted(let reason):
            if isTransition { AppDiagnostics.record(reason, operation: "camera.interrupted") }
            lastNotice = "Camera interrupted. Please try again in a moment."
            // A native interruption invalidates the session, so unsubmitted sequence
            // steps are interrupted too (REVIEW.md H02). Already-submitted sources are
            // NOT discarded: the sequence's own drain keeps their bytes and terminal
            // callbacks alive, which is what makes this a stop, not a loss.
            await sequenceCoordinator?.interrupt(reason: .unknown)
            await suspendRuntimeAdmission(ownedByCondition: conditionRevision)
        case .failed(let kind):
            lastFailure = UserFacingFailure.from(
                CaptureFailure(kind: kind, operation: "sessionCondition"))
            if unfinishedStartAttempt == nil, !isSwitchingLens, !isRepairingTransientCamera {
                lifecycle = .failed(kind)
                surface = .cameraUnavailable(detail: kind.userDescription)
            }
            // AM03: a media-services reset invalidates the graph and is rebuilt, so an active
            // sequence must be told WHY. A generic `.unknown` would take the wrong recovery path.
            if case .cameraInterrupted(let detail) = kind, MediaServicesResetSignal.matches(detail: detail) {
                await sequenceCoordinator?.interrupt(reason: .mediaServicesReset)
            } else {
                await sequenceCoordinator?.interrupt(reason: .unknown)
            }
            await suspendRuntimeAdmission(ownedByCondition: conditionRevision)
            if isTransition, conditionRevision == serviceConditionRevision,
               Self.canRepairTransientCondition(condition), !automaticRecoveryAttempted,
               isCameraEligibleForCapture, !isRepairingTransientCamera {
                automaticRecoveryTask?.cancel()
                let epoch = eligibilityEpoch
                automaticRecoveryTask = Task { [weak self] in
                    try? await Task.sleep(for: .milliseconds(150))
                    guard let self else { return }
                    // Let the existing request/switch owner finish. Repeated
                    // observations of this same failure do not erase the retry.
                    while self.isCaptureBusy || self.isSwitchingLens || self.unfinishedStartAttempt != nil {
                        guard !Task.isCancelled, self.isCameraEligibleForCapture, self.eligibilityEpoch == epoch,
                              self.serviceRecordedCondition == condition, !self.automaticRecoveryAttempted else { return }
                        try? await Task.sleep(for: .milliseconds(50))
                    }
                    guard !Task.isCancelled, self.isCameraEligibleForCapture, self.eligibilityEpoch == epoch,
                          self.serviceRecordedCondition == condition, !self.automaticRecoveryAttempted else { return }
                    await self.startIfNeeded()
                }
            }
        case .reconfiguring:
            // REVIEW.md G02: this used to set a notice and stop, leaving
            // `.reconfiguring` absorbing — `startIfNeeded` then refused forever. The
            // interruption has ENDED, so the current in-process controls are
            // reapplied and the condition is cleared only once that succeeds.
            lastNotice = "Reconnecting the camera…"
            // A start already restores controls. A recovery notification arriving
            // during that await must not apply controls or launch another start
            // over its final native validation. Its owner reconciles on completion.
            guard unfinishedStartAttempt == nil, !isSwitchingLens else { return }
            // L03: the recovery start is an OWNED operation, not the guarded ordinary
            // entry point. `startIfNeeded` refuses `.reconfiguring` — which is exactly the
            // state a reset leaves behind — so calling it here could never recover.
            await completeRecoveryStart()
        case .idle, .running, .requestingPermission, .configuring, .stopping, .none:
            // J03: a transition from a failed/interrupted condition to a settled one is
            // a RECOVERY. The capability and readback are re-read from the rebuilt
            // service so the published generation matches the graph actually in force.
            let recovered: Bool
            switch previous {
            case .some(.failed), .some(.interrupted), .some(.unavailable):
                recovered = condition == .idle || condition == .running
            default:
                recovered = false
            }
            if recovered, isTransition {
                // K03: adopt the rebuilt configuration's capability FIRST. Otherwise
                // `applyReadback` rejects the new-generation reading against the old
                // capability and the model keeps describing the superseded graph.
                if let provider = camera as? any CameraCapabilityProviding,
                   let refreshed = await provider.currentCapability() {
                    capability = refreshed
                }
                await refreshReadback()
                await updateAnalysisDemand()
            }
        case .unavailable(let kind):
            lastFailure = UserFacingFailure.from(
                CaptureFailure(kind: kind, operation: "sessionCondition"))
            await suspendRuntimeAdmission(ownedByCondition: conditionRevision)
        }
    }

    /// Closes admission and stops sensor work while the camera is not trustworthy.
    ///
    /// L03: this now CLOSES the coordinator's capture admission, which previously had no
    /// lifecycle caller at all — an interrupted or ineligible camera left the gate open.
    /// Already-submitted requests keep draining; only NEW admission stops.
    private func suspendRuntimeAdmission(ownedByCondition revision: UInt64? = nil) async {
        let revision = revision ?? serviceConditionRevision
        guard revision == serviceConditionRevision else { return }
        cancelTimer()
        await closeRuntimeAdmission()
        guard revision == serviceConditionRevision else { return }
        // Do not race the typed reset owner's rebuilding graph with an ordinary
        // failed-state output detach. No old layout/request remains eligible.
        lastAppliedAnalysisDemand = nil
        if !preservesResetAnalysisTopology { await camera.setAnalysisDemand(.none) }
        guard revision == serviceConditionRevision else { return }
        await camera.setAnalysisRequest(nil)
    }

    private(set) var runtimeAdmissionReady = false
    private var runtimeAdmissionRevision: UInt64 = 0
    @ObservationIgnored private var formatPreparationTask: Task<Void, Never>?
    private var formatPreparationRevision: UInt64 = 0

    private func closeRuntimeAdmission() async {
        #if DEBUG
        let began = ProcessInfo.processInfo.systemUptime
        #endif
        stopContinuousCapture()
        formatPreparationRevision &+= 1
        formatPreparationTask?.cancel(); formatPreparationTask = nil
        runtimeAdmissionReady = false
        runtimeAdmissionRevision &+= 1
        let revision = runtimeAdmissionRevision
        #if DEBUG
        let localFinished = ProcessInfo.processInfo.systemUptime
        #endif
        await capture.setLifecycleAdmission(isOpen: false, revision: revision)
        #if DEBUG
        let finished = ProcessInfo.processInfo.systemUptime
        print("TruongCam timing admission-close-local=\(Int((localFinished - began) * 1000))ms actor-await=\(Int((finished - localFinished) * 1000))ms")
        #endif
    }

    /// The successful START owns reopening, including starts that outlive a
    /// permission/inactive transition. Duplicate reveal callbacks cannot guess it.
    private func resumeRuntimeAdmission(ownedBySwitch: Bool = false) async {
        guard unfinishedStartAttempt == nil, (!isSwitchingLens || ownedBySwitch), isCameraEligibleForCapture, lifecycle == .running, effectiveLifecycle == .running, !controlRestorationFailed else { return }
        runtimeAdmissionRevision &+= 1
        let revision = runtimeAdmissionRevision, epoch = eligibilityEpoch
        let opened = await capture.setLifecycleAdmission(isOpen: true, revision: revision)
        guard revision == runtimeAdmissionRevision, epoch == eligibilityEpoch,
              isCameraEligibleForCapture, lifecycle == .running, effectiveLifecycle == .running, !controlRestorationFailed else { return }
        runtimeAdmissionReady = opened
        if opened, effectiveCaptureFileFormat == .jpeg { scheduleFormatPreparation() }
    }

    /// The native service may allocate resources while the person is choosing
    /// a format. The shutter never waits for this optional hint or its result.
    private func scheduleFormatPreparation() {
        formatPreparationRevision &+= 1
        let revision = formatPreparationRevision
        formatPreparationTask?.cancel()
        guard let preparing = camera as? any CaptureFormatPreparing,
              runtimeAdmissionReady, isCameraEligibleForCapture else {
            formatPreparationTask = nil
            return
        }
        let format = effectiveCaptureFileFormat, generation = capability.generation, epoch = eligibilityEpoch
        formatPreparationTask = Task { [weak self] in
            guard let self, !Task.isCancelled, self.formatPreparationRevision == revision,
                  self.eligibilityEpoch == epoch, self.capability.generation == generation,
                  self.effectiveCaptureFileFormat == format, self.runtimeAdmissionReady,
                  self.isCameraEligibleForCapture else { return }
            await preparing.prepareCaptureFormat(format, generation: generation)
            if self.formatPreparationRevision == revision { self.formatPreparationTask = nil }
        }
    }
    private(set) var capability: CameraCapabilitySnapshot = .empty(generation: .zero, reason: "Not prepared") {
        didSet { reconcileApertureCapability() }
    }

    /// Adopts a capability published by the camera service after a graph change.
    ///
    /// L05: the reconfirmation consumer republishes readiness through this, so the model
    /// describes the configuration actually in force rather than the superseded one.
    func adoptCapability(_ snapshot: CameraCapabilitySnapshot) {
        capability = snapshot
    }

    @ObservationIgnored private var hardwareSelectionTask: Task<Void, Never>?
    @ObservationIgnored private var hardwareFullscreenTask: Task<Void, Never>?
    private(set) var hardwareInteractionID = UUID()
    private var lastHardwareConfiguration = HardwareControlConfiguration(enabled: false, selections: [])
    private struct HardwareLensIntent {
        let target: PhysicalCameraKind
        let interactionID: UUID
        let epoch: Int
    }
    private var pendingHardwareLens: HardwareLensIntent?
    private var hardwareLensOwner: (interactionID: UUID, epoch: Int)?
    @ObservationIgnored private var hardwareLensTask: Task<Void, Never>?
    private(set) var isHardwareControlFullscreen = false
    var openPanel: CameraPanel?
    var isToolsSheetPresented = false { didSet { if isToolsSheetPresented { stopContinuousCapture() } } }
    var isFolderSheetPresented = false { didSet { if isFolderSheetPresented { stopContinuousCapture() } } }
    var isRecoverySheetPresented = false { didSet { if isRecoverySheetPresented { stopContinuousCapture() } } }

    enum CameraSheet: String, Identifiable { case tools, folder, recovery; var id: String { rawValue } }
    var presentedCameraSheet: CameraSheet? {
        get {
            if isRecoverySheetPresented { return .recovery }
            if isFolderSheetPresented { return .folder }
            return isToolsSheetPresented ? .tools : nil
        }
        set {
            isToolsSheetPresented = newValue == .tools
            isFolderSheetPresented = newValue == .folder
            isRecoverySheetPresented = newValue == .recovery
        }
    }

    func showPendingRecovery() {
        openPanel = nil
        presentedCameraSheet = .recovery
    }

    // MARK: Desired controls (user intent)

    private(set) var exposure: ExposureChoice = .auto
    private(set) var aperture: ApertureChoice = .auto
    private(set) var biasEV: Double = 0
    private(set) var focus: FocusIntent = FocusIntent(mode: .continuousAuto, position: nil, pointOfInterest: nil)
    private(set) var whiteBalance: WhiteBalanceIntent = WhiteBalanceIntent(mode: .auto, temperatureAndTint: nil)

    // MARK: Applied and observed (device truth)

    private(set) var applied: AppliedControlSnapshot?
    private(set) var observedDurationSeconds: Double?
    private(set) var observedISO: Double?
    private(set) var observedExposureTargetOffset: Double?
    private(set) var observedFocusPosition: Double?
    private(set) var observedWhiteBalanceGains: WhiteBalanceGains?

    // MARK: Aids

    var composition: CompositionPreferences {
        didSet {
            if oldValue.loupeCenter != composition.loupeCenter || oldValue.loupeMagnification != composition.loupeMagnification
                || oldValue.loupeEnabled != composition.loupeEnabled { loupe = nil }
            if composition.timerSeconds > 0, oldValue.timerSeconds != composition.timerSeconds {
                stopContinuousCapture(); captureSpeed = .single; preferences.storeCaptureSpeed(.single)
            }
            persistComposition()
        }
    }
    private(set) var histogram: HistogramSnapshot?
    private(set) var masks: MaskSnapshot?
    private(set) var loupe: LoupeSnapshot?
    private(set) var pausedAids: [PausedPreviewAid] = []
    private(set) var analysisUnavailableReason: String?

    // MARK: Save status

    private(set) var pendingOriginalCount = 0
    private(set) var captureSpeed: CaptureSpeed = .single
    private(set) var continuousCapturedCount = 0
    private var continuousRunID: UUID?
    private var continuousAdmissionID: UUID?
    private var continuousHoldID: UUID?
    @ObservationIgnored private var continuousTask: Task<Void, Never>?
    var isContinuousCaptureActive: Bool { continuousRunID != nil }
    var isContinuousCaptureHeld: Bool { continuousHoldID != nil }

    func setCaptureSpeed(_ speed: CaptureSpeed) {
        guard !isSequenceRunning, !isResettingControls, captureSpeed != speed else { return }
        #if DEBUG
        let began = ProcessInfo.processInfo.systemUptime
        defer { print("TruongCam timing drive-setting=\(Int((ProcessInfo.processInfo.systemUptime - began) * 1000))ms speed=\(speed.rawValue)") }
        #endif
        stopContinuousCapture()
        captureSpeed = speed
        preferences.storeCaptureSpeed(speed)
        if speed != .single {
            cancelTimer()
            queuedSequenceRequest = nil
            if composition.timerSeconds != 0 { composition.timerSeconds = 0 }
            if sequencePreferences.shutterMode != .single { sequencePreferences.shutterMode = .single }
        }
    }

    /// A press owns admission, not the lifetime of an already submitted photo.
    /// A quick normal release still takes its first photo; cancellation revokes
    /// that unsubmitted first photo too. Neither path cancels native persistence.
    @discardableResult func beginShutterHold(id: UUID) -> Bool {
        guard captureSpeed != .single, isShutterEnabled, presentedCameraSheet == nil,
              timerSeconds == nil, activeShutterMode == .single else { return false }
        let speed = captureSpeed, epoch = eligibilityEpoch, generation = capability.generation
        let root = currentRootState, format = effectiveCaptureFileFormat, revision = controlRevision
        continuousRunID = id; continuousAdmissionID = id; continuousHoldID = id
        continuousCapturedCount = 0
        #if DEBUG
        print("TruongCam drive-begin run=\(id) speed=\(speed.rawValue) camera=\(capability.selectedCameraKind?.rawValue ?? "none") format=\(format.rawValue)")
        #endif
        continuousTask = Task { [weak self] in
            guard let self else { return }
            defer {
                if self.continuousRunID == id {
                    #if DEBUG
                    print("TruongCam drive-end run=\(id) verified=\(self.continuousCapturedCount)")
                    #endif
                    self.continuousRunID = nil; self.continuousAdmissionID = nil
                    self.continuousHoldID = nil; self.continuousTask = nil
                }
            }
            @MainActor func isCurrent() -> Bool {
                self.continuousAdmissionID == id && self.eligibilityEpoch == epoch
                    && self.capability.generation == generation && self.currentRootState == root
                    && self.effectiveCaptureFileFormat == format && self.controlRevision == revision
                    && self.captureSpeed == speed && self.presentedCameraSheet == nil
                    && self.isCameraEligibleForCapture && self.runtimeAdmissionReady && !self.isResettingControls && !self.isSequenceRunning
                    && self.activeShutterMode == .single && self.timerSeconds == nil
            }
            var first = true, deadline = self.clock.now()
            while isCurrent() {
                if !first {
                    guard self.continuousHoldID == id else { break }
                    while isCurrent(), self.continuousHoldID == id, self.clock.now() < deadline {
                        let remaining = deadline - self.clock.now()
                        guard remaining.isFinite else { return }
                        // Short bounded waits observe release even when the selected
                        // cadence is slow; no task cancellation reaches a photo.
                        try? await Task.sleep(for: .seconds(min(0.04, max(0, remaining))))
                    }
                }
                guard isCurrent(), (first || self.continuousHoldID == id),
                      self.singleShutterAdmissionReady else { break }
                let start = self.clock.now()
                guard start.isFinite else { break }
                let saved = await self.captureOnePhoto(admission: { isCurrent() && (first || self.continuousHoldID == id) })
                if saved { self.continuousCapturedCount += 1 }
                guard saved, let next = speed.nextStart(after: start, finishedAt: self.clock.now()) else { break }
                first = false; deadline = next
            }
        }
        return true
    }

    func endShutterHold(id: UUID) {
        guard continuousHoldID == id else { return }
        continuousHoldID = nil
    }
    func cancelShutterHold(id: UUID) {
        guard continuousRunID == id else { return }
        continuousAdmissionID = nil; continuousHoldID = nil
    }
    func stopContinuousCapture() {
        hardwareShutterPress.removeAll()
        if let id = continuousRunID { cancelShutterHold(id: id) }
    }
    private(set) var lastCommittedReceipts: [CommitReceipt] = []
    private(set) var lastCaptureWasExposureBracket = false
    var isSequenceRunning: Bool { activeSequenceID != nil || isExecutingSequence }
    var isCaptureBusy: Bool { isCapturing || isSequenceRunning || isResettingControls }
    var activeShutterMode: SequenceShutterMode { isSequenceCaptureAvailable ? sequencePreferences.shutterMode : .single }
    var isSequenceCaptureAvailable: Bool {
        effectiveCaptureFileFormat == .bayerDNG && capability.bayerCaptureSupported.value == true
    }
    var isExposureBracketActive: Bool { activeShutterMode == .exposureBracket }
    private(set) var shutterPulse: UInt64 = 0
    private(set) var sequenceFrameOrdinal = 0
    private(set) var sequencePlannedCount = 0
    private(set) var sequencePhase: SequenceRunPhase = .idle
    @ObservationIgnored private var shutterFeedbackTask: Task<Void, Never>?
    private var lastFeedbackCaptureID: CaptureID?

    func setShutterMode(_ mode: SequenceShutterMode, enabled: Bool) {
        guard !isSequenceRunning, !enabled || isSequenceCaptureAvailable else { return }
        if enabled { sequencePreferences.shutterMode = mode }
        else if sequencePreferences.shutterMode == mode { sequencePreferences.shutterMode = .single }
    }
    func setExposureBracketEnabled(_ enabled: Bool) { setShutterMode(.exposureBracket, enabled: enabled) }

    deinit {
        analysisTask?.cancel(); readbackTask?.cancel(); sessionConditionTask?.cancel()
        shutterFeedbackTask?.cancel(); hardwareSelectionTask?.cancel(); hardwareFullscreenTask?.cancel()
        automaticRecoveryTask?.cancel(); formatPreparationTask?.cancel()
        levelFeed.stop(); resourceMonitor?.stop()
    }

    /// Set by the coordinator so a verified commit reaches the derived index.
    var onCommittedReceipts: (@MainActor ([CommitReceipt]) async -> Void)?
    /// Called after a sequence finishes, so the application can refresh the pending
    /// recovery list and library state (REVIEW.md F06).
    var onSequenceFinished: (@MainActor (Int) async -> Void)?
    private(set) var lastFinishedSequenceDocumentID: SequenceID?
    /// Called after ANY capture result that changed the pending-original set, so the
    /// application's recovery list is refreshed for ordinary captures too
    /// (REVIEW.md F06).
    var onPendingOriginalsChanged: (@MainActor (Int) async -> Void)?
    private(set) var isCapturing = false
    private(set) var isResettingControls = false
    @ObservationIgnored private var controlsResetTask: Task<Void, Never>?

    // MARK: Sequence status

    /// The terminal status retained for display. This is informational text, NOT
    /// activity: REVIEW.md S14 found the shutter and lens switch gated on this
    /// string, so a finished sequence permanently blocked ordinary capture.
    private(set) var sequenceStatusLine: String?
    /// A restoration failure is a TYPED block that survives until an explicit
    /// reset, rather than being inferred from a message.
    private(set) var sequenceBlockedByRestorationFailure: String?
    private(set) var timerCountdownSeconds: Int?

    // MARK: Dependencies

    private let camera: any CameraServicing
    private let capture: CaptureCoordinator
    private let metering: MeteringService
    private let clock: any MonotonicClock
    private let preferences: PreferenceStoring
    @ObservationIgnored private let resourceMonitor: (any CameraResourcePressureMonitoring)?
    private(set) var resourcePressureSnapshot = CameraResourcePressureSnapshot()
    @ObservationIgnored private var lastAppliedAnalysisDemand: (demand: AnalysisDemand, generation: ConfigurationGeneration, eligibilityEpoch: Int)?
    @ObservationIgnored private var resourcePressureNeedsReconciliation = false
    @ObservationIgnored private var analysisUpdateRevision: UInt64 = 0
    @ObservationIgnored private var analysisTask: Task<Void, Never>?
    private var controlRevision: UInt64 = 0
    private var applyTask: Task<Void, Never>?
    private var geometry: PreviewGeometrySnapshot?
    /// Attached by the coordinator once the sequence stack is available.
    /// The user's remembered sequence settings (REVIEW.md C11). Persisted on
    /// every change; validated against plan bounds before use.
    var sequencePreferences: SequencePlanPreferences {
        didSet {
            if sequencePreferences.shutterMode != .single {
                stopContinuousCapture(); captureSpeed = .single; preferences.storeCaptureSpeed(.single)
            }
            preferences.storeSequencePreferences(sequencePreferences)
        }
    }
    @ObservationIgnored private var readbackTask: Task<Void, Never>?
    @ObservationIgnored private var sessionConditionTask: Task<Void, Never>?
    private var isExecutingSequence = false
    /// The most recent snapshot, kept so the settlement state can be shown
    /// (REVIEW.md S06).
    private(set) var lastReadback: AppliedControlSnapshot?
    /// Readbacks refused because they described a superseded request. Non-zero is
    /// expected during rapid adjustment; it is reported for diagnostics.
    private(set) var staleReadbackCount = 0
    /// The revision of the newest control request this view issued, so a readback can
    /// be checked for relevance rather than only for generation (REVIEW.md F03).
    private(set) var lastAppliedRequestRevision: UInt64 = 0
    private var timerTask: Task<Void, Never>?
    private var timerDeadline: Double?
    /// False while the scene is inactive/background. Gates submission.
    private(set) var isSceneActive = true
    /// Transient user-facing notice (timer cancelled, camera not ready, ...).
    private(set) var lastNotice: String?

    /// Dismisses the current notice.
    func clearLastNotice() { lastNotice = nil }
    private var sequenceCoordinator: SequenceCoordinator?
    private var sequenceTask: Task<Void, Never>?
    private var sequenceAdmissionCancelled = false
    private(set) var activeSequenceID: SequenceID?

    init(camera: any CameraServicing,
         capture: CaptureCoordinator,
         metering: MeteringService,
         clock: any MonotonicClock = SystemMonotonicClock(),
         preferences: PreferenceStoring = UserDefaultsPreferenceStore(),
         levelFeed: any DeviceMotionLevelFeeding,
         resourceMonitor: (any CameraResourcePressureMonitoring)? = nil) {
        self.levelFeed = levelFeed
        self.resourceMonitor = resourceMonitor
        self.camera = camera
        self.capture = capture
        self.metering = metering
        self.clock = clock
        self.preferences = preferences
        self.composition = preferences.loadCompositionPreferences() ?? CompositionPreferences()
        self.sequencePreferences = preferences.loadSequencePreferences() ?? SequencePlanPreferences()
        self.preferredCaptureFormat = preferences.loadPreferredCaptureFormat() == .jpeg ? .jpeg : .bayerDNG
        let storedSpeed = preferences.loadCaptureSpeed()
        captureSpeed = composition.timerSeconds > 0 || sequencePreferences.shutterMode != .single ? .single : storedSpeed
        if captureSpeed != storedSpeed { preferences.storeCaptureSpeed(captureSpeed) }
        startAnalysisConsumption()
        startShutterFeedbackConsumption()
        resourceMonitor?.start { [weak self] snapshot in
            Task { @MainActor [weak self] in await self?.receiveResourcePressure(snapshot) }
        }
    }

    /// Resource events are independent of sensor permission/capture admission.
    /// During a real photo or switch, retain the newest value for its owner to
    /// reconcile afterward; no optional graph work competes with acquisition.
    func receiveResourcePressure(_ snapshot: CameraResourcePressureSnapshot) async {
        guard snapshot.revision > resourcePressureSnapshot.revision else { return }
        resourcePressureSnapshot = snapshot
        resourcePressureNeedsReconciliation = true
        await reconcileResourcePressureIfNeeded()
    }
    private func reconcileResourcePressureIfNeeded() async {
        guard resourcePressureNeedsReconciliation, isPreviewConnectionStable, !isCaptureBusy else { return }
        await updateAnalysisDemand()
    }

    // MARK: Lifecycle

    private var startAttemptSerial: UInt64 = 0
    private var unfinishedStartAttempt: UInt64?
    private var unfinishedStartEpoch: Int?
    func start() async {
        // REVIEW.md R02: `start` never moved the lifecycle out of its previous
        // state before awaiting `prepare`, so two concurrent entry points could both
        // prepare and both start the session. Marking `configuring` here — before the
        // first suspension — makes `startIfNeeded` one-at-a-time. A scene that is not
        // eligible must not start the sensor at all.
        guard isCameraEligibleForCapture, !isSwitchingLens,
              unfinishedStartAttempt == nil || unfinishedStartEpoch != eligibilityEpoch else { return }
        // Only an actual eligibility change can replace a draining obsolete
        // attempt. Same-session recovery/layout callbacks share its current owner.
        switch lifecycle {
        case .configuring, .reconfiguring, .requestingPermission, .running:
            return
        case .idle, .interrupted, .unavailable, .failed, .stopping:
            break
        }
        startAttemptSerial &+= 1
        let attemptSerial = startAttemptSerial
        let resetReservationAtAttempt = resetAnalysisTopologyReservation
        unfinishedStartAttempt = attemptSerial
        unfinishedStartEpoch = eligibilityEpoch
        defer {
            if unfinishedStartAttempt == attemptSerial {
                unfinishedStartAttempt = nil
                unfinishedStartEpoch = nil
                // One queued reconciliation after this owner drains. Do not
                // restart a newer running/failed/interrupted or ineligible graph.
                if serviceRecordedCondition == .reconfiguring, isCameraEligibleForCapture,
                   !isCompletingRecoveryStart {
                    Task { [weak self] in await self?.completeRecoveryStart() }
                }
            }
            if resourcePressureNeedsReconciliation {
                Task { [weak self] in await self?.reconcileResourcePressureIfNeeded() }
            }
        }
        controlRestorationFailed = false
        lifecycle = .configuring
        surface = .preparing
        lastFailure = nil
        // H02: stamp the EPOCH this attempt belongs to. Any eligibility change bumps it,
        // so work that started before the change can be recognized as stale after its
        // awaits instead of leaving the sensor running.
        let attemptEpoch = eligibilityEpoch
        await closeRuntimeAdmission()
        guard attemptSerial == startAttemptSerial else { return }
        guard attemptEpoch == eligibilityEpoch, isCameraEligibleForCapture else {
            lifecycle = .idle
            if isCameraEligibleForCapture, !isRetryingAfterStaleAbort {
                isRetryingAfterStaleAbort = true
                defer { isRetryingAfterStaleAbort = false }
                // The stale native await has drained; release only this owner
                // before the single eligibility retry acquires a new one.
                unfinishedStartAttempt = nil
                await startIfNeeded()
            }
            return
        }
        #if DEBUG
        let prepareBegan = clock.now()
        #endif
        // Reserve enabled preview-tool topology before native preparation. The
        // initial graph can then start once with its real outputs, instead of
        // attaching analysis to an already-running sensor. A nil geometry still
        // means no analysis request and no frame processing.
        let initialAnalysis = AnalysisDemandPolicy.decide(configuration: aidConfiguration,
            lifecycle: .activeCameraView,
            pressure: resourcePressureSnapshot.analysisPressure(pendingOriginalCount: pendingOriginalCount),
            geometry: nil)
        lastAppliedAnalysisDemand = nil
        await camera.setAnalysisDemand(initialAnalysis.demand)
        guard attemptSerial == startAttemptSerial else { return }
        guard attemptEpoch == eligibilityEpoch, isCameraEligibleForCapture else {
            lifecycle = .idle
            surface = .ready
            if isCameraEligibleForCapture, !isRetryingAfterStaleAbort {
                isRetryingAfterStaleAbort = true
                defer { isRetryingAfterStaleAbort = false }
                unfinishedStartAttempt = nil
                await startIfNeeded()
            }
            return
        }
        let prepared = await camera.prepare(desiredCamera: composition.preferredLens)
        #if DEBUG
        print("TruongCam timing prepare=\(Int((clock.now() - prepareBegan) * 1000))ms")
        #endif
        guard attemptSerial == startAttemptSerial else { return }

        // Recheck AFTER the suspension: both the epoch AND current eligibility must
        // still hold. If either changed, this attempt is invalidated.
        guard attemptEpoch == eligibilityEpoch, isCameraEligibleForCapture else {
            lifecycle = .idle
            surface = .ready
            // L03: this attempt is stale and must NOT start the sensor itself. But the
            // activation that superseded it saw `.configuring` and returned, so without
            // one eventual retry the camera would stay idle while eligible. The retry is
            // scheduled only when the scene is eligible NOW, and it is a single deferred
            // attempt rather than a backlog.
            if isCameraEligibleForCapture, !isRetryingAfterStaleAbort {
                isRetryingAfterStaleAbort = true
                defer { isRetryingAfterStaleAbort = false }
                // The stale native await has drained; release only this owner
                // before the single eligibility retry acquires a new one.
                unfinishedStartAttempt = nil
                await startIfNeeded()
            }
            return
        }
        // A newer typed reset may own the graph without changing scene
        // eligibility or starting another UI attempt. Its late predecessor may
        // not publish a result, clear its reservation or reapply old controls.
        guard resetAnalysisTopologyReservation == resetReservationAtAttempt else { return }
        switch prepared {
        case .success(let snapshot):
            capability = snapshot
            switch snapshot.photoCaptureSupport {
            case .available(true):
                break
            case .available(false):
                AppDiagnostics.record("The active format reports no Bayer RAW pixel format.", operation: "camera.prepare")
                resetAnalysisTopologyReservation = nil
                lifecycle = .unavailable(.unsupportedCapability(
                    detail: "The active format reports no Bayer RAW pixel format."))
                surface = .unsupportedBayer(
                    detail: "The active format reports no Bayer RAW pixel format.")
                lastAppliedAnalysisDemand = nil
                await camera.setAnalysisDemand(.none)
                return
            case .unavailable(let reason), .unknown(let reason):
                AppDiagnostics.record(reason, operation: "camera.prepare")
                resetAnalysisTopologyReservation = nil
                lifecycle = .unavailable(.unsupportedCapability(detail: reason))
                surface = .unsupportedBayer(detail: reason)
                lastAppliedAnalysisDemand = nil
                await camera.setAnalysisDemand(.none)
                return
            }
            guard attemptEpoch == eligibilityEpoch, isCameraEligibleForCapture else {
                lifecycle = .idle
                surface = .ready
                return
            }
            #if DEBUG
            let startBegan = clock.now()
            #endif
            let started = await camera.start()
            #if DEBUG
            print("TruongCam timing session-start=\(Int((clock.now() - startBegan) * 1000))ms")
            #endif
            // A newer UI attempt already reopened the camera. This obsolete
            // completion may neither stop its sensor nor reset its surface.
            guard attemptSerial == startAttemptSerial else { return }
            // H02: the START itself may have been held while the app backgrounded. A
            // stale completion must not leave the sensor running: stop it and report the
            // neutral state instead.
            guard attemptEpoch == eligibilityEpoch, isCameraEligibleForCapture else {
                // The start itself was held while eligibility changed. The sensor is
                // stopped, and exactly ONE awaited retry re-establishes it if the scene
                // is eligible again — the same rule as the prepare await, so a stale
                // abort at either suspension cannot leave an eligible camera stopped
                // (REVIEW.md M03).
                await camera.stop()
                lifecycle = .idle
                surface = .ready
                if isCameraEligibleForCapture, !isRetryingAfterStaleAbort {
                    isRetryingAfterStaleAbort = true
                    defer { isRetryingAfterStaleAbort = false }
                    unfinishedStartAttempt = nil
                    await startIfNeeded()
                }
                return
            }
            guard resetAnalysisTopologyReservation == resetReservationAtAttempt else { return }
            switch started {
            case .success:
                lifecycle = .running
                surface = .ready
                // Publish the display bridge now that the session exists, so the
                // preview layer has something to render (REVIEW.md C02/C03).
                await loadDisplayBridge()
                guard attemptSerial == startAttemptSerial,
                      resetAnalysisTopologyReservation == resetReservationAtAttempt else { return }
                // P01: THIS operation's typed control result, not a comparison of shared
                // failure state before and after.
                let application = await applyCurrentControls()
                guard attemptSerial == startAttemptSerial,
                      resetAnalysisTopologyReservation == resetReservationAtAttempt else { return }
                controlRestorationFailed = (application != .applied)
                await refreshReadback(ownedByCameraOperation: true)
                guard attemptSerial == startAttemptSerial, attemptEpoch == eligibilityEpoch, isCameraEligibleForCapture,
                      resetAnalysisTopologyReservation == resetReservationAtAttempt else { return }
                // Backgrounding can revoke the reset's topology reservation.
                // A later fresh verified start still clears that transient aid
                // disclosure; a genuine unsupported reason is retained.
                if !controlRestorationFailed,
                   serviceRecordedCondition == nil || serviceRecordedCondition == .running || serviceRecordedCondition == .reconfiguring,
                   analysisUnavailableReason == MediaServicesResetSignal.analysisUnavailableReason {
                    analysisUnavailableReason = nil
                }
                await updateAnalysisDemand(ownedByCameraOperation: true)
                guard attemptSerial == startAttemptSerial, attemptEpoch == eligibilityEpoch, isCameraEligibleForCapture,
                      resetAnalysisTopologyReservation == resetReservationAtAttempt else { return }
                unfinishedStartAttempt = nil
                if serviceRecordedCondition == .reconfiguring, !isCompletingRecoveryStart {
                    await completeRecoveryStart()
                } else if !controlRestorationFailed { await resumeRuntimeAdmission() }
            case .failure(let failure):
                resetAnalysisTopologyReservation = nil
                lifecycle = .failed(failure.kind)
                report(failure)
                if case .permissionDenied = failure.kind {
                    surface = .cameraPermissionDenied
                } else {
                    surface = .cameraUnavailable(detail: failure.kind.userDescription)
                }
            }
        case .failure(let failure):
            resetAnalysisTopologyReservation = nil
            // A failed `prepare` must leave a TERMINAL lifecycle, not `configuring`,
            // or `startIfNeeded` would refuse every later retry (REVIEW.md R02).
            lifecycle = .failed(failure.kind)
            report(failure)
            switch failure.kind {
            case .permissionDenied:
                surface = .cameraPermissionDenied
            case .noCamera, .unsupportedCapability:
                surface = .unsupportedBayer(detail: failure.kind.userDescription)
            default:
                surface = .cameraUnavailable(detail: failure.kind.userDescription)
            }
            lastAppliedAnalysisDemand = nil
            await camera.setAnalysisDemand(.none)
        }
    }

    func stop() async {
        // Revoke model/format admission before waiting for the native stop.
        // A stopped graph cannot retain a cached running model's selectors.
        await closeRuntimeAdmission()
        await camera.stop()
        lifecycle = await camera.lifecycle
        // Keep the one metering consumer alive across an ordinary stop/restart.
        // Cancelling its AsyncStream iterator permanently closes that stream.
        // No work is produced while demand is stopped; deinit cancels the waiter.
        await metering.stop()
    }

    // MARK: Lens selection

    var availableLenses: [PhysicalCameraKind] {
        guard capability.selectedCameraKind != .front else { return [] }
        // The selector reflects the actual physical topology, including a Pro
        // telephoto, without fabricated digital-crop or duplicate-kind buttons.
        return PhysicalCameraKind.rearSelectionOrder.filter { capability.camera($0) != nil }
    }

    private var lastRearLens: PhysicalCameraKind = .wide
    var canSwitchCamera: Bool {
        !isContinuousCaptureActive && runtimeAdmissionReady && isCameraEligibleForCapture && unfinishedStartAttempt == nil && surface == .ready && effectiveLifecycle == .running
            && !isPreviewTransitionVisible && hasRenderedCurrentPreview
            && !isSwitchingLens && !isCaptureBusy && timerCountdownSeconds == nil
            && !isSequenceRunning && pendingOriginalCount == 0 && sequenceBlockedByRestorationFailure == nil
    }
    func rotateCamera() async {
        await selectLens(capability.selectedCameraKind == .front ? lastRearLens : .front)
    }
    private(set) var isSwitchingLens = false
    func selectLens(_ kind: PhysicalCameraKind, hardwareInteraction: UUID? = nil) async {
        guard canSwitchCamera,
              kind != capability.selectedCameraKind || surface != .ready else { return }
        if hardwareInteraction == nil { pendingHardwareLens = nil; hardwareLensOwner = nil }
        let previous = capability.selectedCameraKind ?? .wide
        if previous != .front { lastRearLens = previous }
        let epoch = eligibilityEpoch
        #if DEBUG
        let switchBegan = clock.now()
        defer { print("TruongCam timing camera-switch=\(Int((clock.now() - switchBegan) * 1000))ms from=\(previous.rawValue) to=\(kind.rawValue)") }
        var phaseBegan = switchBegan
        func finishSwitchPhase(_ phase: String) {
            let now = clock.now()
            print("TruongCam timing switch-\(phase)=\(Int((now - phaseBegan) * 1000))ms to=\(kind.rawValue)")
            phaseBegan = now
        }
        switchPreviewBegan = clock.now()
        #endif
        frozenSwitchPreview = displayBridge?.frozenFrame(for: geometry)
            ?? displayBridge?.decorativeTransitionFrame(for: geometry)
        isPreviewTransitionVisible = true
        isSwitchingLens = true
        geometry = nil; masks = nil; loupe = nil; histogram = nil
        lifecycle = .reconfiguring
        defer {
            isSwitchingLens = false
            if resourcePressureNeedsReconciliation {
                Task { [weak self] in await self?.reconcileResourcePressureIfNeeded() }
            }
            if previewSessionBox == nil || surface != .ready { finishPreviewTransition() }
            // A real cover/background transition still cancels this switch. If
            // eligibility returned while it drained, restart only after releasing it.
            if epoch != eligibilityEpoch, isCameraEligibleForCapture {
                lifecycle = .idle
                Task { [weak self] in await self?.startIfNeeded() }
            } else if serviceRecordedCondition == .reconfiguring, isCameraEligibleForCapture {
                Task { [weak self] in
                    await self?.completeRecoveryStart()
                }
            }
        }
        await closeRuntimeAdmission()
        #if DEBUG
        finishSwitchPhase("admission-close")
        #endif
        guard epoch == eligibilityEpoch, isCameraEligibleForCapture else { return }
        composition.preferredLens = kind
        surface = .preparing
        var result = await camera.switchPhysicalCamera(to: kind)
        #if DEBUG
        finishSwitchPhase("prepare")
        #endif
        guard epoch == eligibilityEpoch, isCameraEligibleForCapture else { return }
        if case .failure(let failure) = result {
            // A failed facing change restores the prior usable input, without
            // dispatching a new startup or overwriting a newer lifecycle.
            lastNotice = UserFacingFailure.message(for: failure)
            composition.preferredLens = previous
            result = await camera.switchPhysicalCamera(to: previous)
        }
        guard epoch == eligibilityEpoch, isCameraEligibleForCapture else { return }
        switch result {
        case .success(let snapshot):
            capability = snapshot
            let started = await camera.start()
            #if DEBUG
            finishSwitchPhase("start-validation")
            #endif
            guard epoch == eligibilityEpoch, isCameraEligibleForCapture else { return }
            if case .failure(let failure) = started {
                lifecycle = .failed(failure.kind)
                surface = .cameraUnavailable(detail: failure.kind.userDescription)
                return
            }
            capability = await camera.capabilitySnapshot
            await loadDisplayBridge()
            #if DEBUG
            finishSwitchPhase("display-binding")
            #endif
            guard epoch == eligibilityEpoch, isCameraEligibleForCapture else { return }
            surface = .ready
            let applied = await applyCurrentControls()
            await refreshReadback(ownedByCameraOperation: true)
            #if DEBUG
            finishSwitchPhase("controls-readback")
            #endif
            guard epoch == eligibilityEpoch, isCameraEligibleForCapture else { return }
            controlRestorationFailed = applied != .applied
            await updateAnalysisDemand(ownedByCameraOperation: true)
            #if DEBUG
            finishSwitchPhase("analysis")
            #endif
            let confirmedLifecycle = await camera.lifecycle
            guard epoch == eligibilityEpoch, isCameraEligibleForCapture else { return }
            guard confirmedLifecycle == .running else {
                lifecycle = confirmedLifecycle
                surface = .cameraUnavailable(detail: "The camera changed state during the switch. Retry when it is available.")
                return
            }
            lifecycle = .running
            if !controlRestorationFailed { await resumeRuntimeAdmission(ownedBySwitch: true) }
            #if DEBUG
            finishSwitchPhase("admission-open")
            #endif
        case .failure(let failure):
            lifecycle = .failed(failure.kind)
            surface = .cameraUnavailable(detail: failure.kind.userDescription)
        }
    }

    /// Equivalent millimetre labels select a physical device. They never set a digital zoom
    /// factor: native video zoom stays exactly 1 for Bayer RAW.
    var lensButtons: [(kind: PhysicalCameraKind, label: String, isSelected: Bool, accessibility: String)] {
        availableLenses.map { kind in
            (kind,
             capability.camera(kind)?.lensDisplayLabel ?? kind.displayLabel,
             kind == capability.selectedCameraKind,
             capability.camera(kind)?.lensAccessibilityLabel ?? kind.accessibilityLabel)
        }
    }

    // MARK: Exposure

    /// JPEG is an explicit user choice. The existing front HEIF fallback remains
    /// visibly distinct when a RAW preference reaches a front camera without Bayer.
    private(set) var preferredCaptureFormat: CaptureFileFormat
    var effectiveCaptureFileFormat: CaptureFileFormat {
        if preferredCaptureFormat == .jpeg { return .jpeg }
        if capability.bayerCaptureSupported.value != true, capability.frontHEIFSupported,
           capability.selectedCameraKind == .front { return .frontHEIF }
        return .bayerDNG
    }
    var isCaptureFormatSelectionEnabled: Bool {
        canSwitchCamera && presentedCameraSheet == nil && sequenceTask == nil
            && queuedSequenceRequest == nil && !isRepairingTransientCamera && !controlRestorationFailed
    }
    func selectCaptureFormat(_ format: CaptureFileFormat) {
        guard isCaptureFormatSelectionEnabled else { return }
        switch format {
        case .jpeg: guard capability.jpegSupported, capability.jpegMaximumDimensions != nil else { return }
        case .bayerDNG: guard capability.bayerCaptureSupported.value == true else { return }
        case .frontHEIF:
            guard capability.frontHEIFSupported, capability.selectedCameraKind == .front,
                  capability.bayerCaptureSupported.value != true else { return }
        }
        let preference: CaptureFileFormat = format == .jpeg ? .jpeg : .bayerDNG
        guard preference != preferredCaptureFormat else { return }
        preferredCaptureFormat = preference
        preferences.storePreferredCaptureFormat(preference)
        scheduleFormatPreparation()
        #if DEBUG
        print("TruongCam capture-format selected=\(effectiveCaptureFileFormat.rawValue) generation=\(capability.generation)")
        #endif
        // A settings event queued before this mode change cannot act afterward.
        // Rebind the existing native controls without rebuilding the camera graph.
        hardwareInteractionID = UUID()
        pendingHardwareLens = nil; hardwareLensOwner = nil
        if let hardware = camera as? any HardwareCameraControlling {
            hardware.configureHardwareControls(lastHardwareConfiguration, interactionID: hardwareInteractionID)
        }
    }

    var captureFormatLabel: String {
        switch effectiveCaptureFileFormat {
        case .jpeg: return capability.jpegSupported ? "JPEG" : "JPEG unavailable"
        case .frontHEIF: return "HEIF · Front"
        case .bayerDNG:
            return surface == .preparing || (surface == .ready && capability.bayerCaptureSupported.value == true)
                ? "RAW" : "RAW unavailable"
        }
    }

    var captureFormatAccessibilityLabel: String {
        switch effectiveCaptureFileFormat {
        case .jpeg:
            return capability.jpegSupported ? "JPEG. Processed photo, no RAW original." : "JPEG is unavailable on this camera."
        case .frontHEIF: return "Front camera HEIF. Processed photo, not RAW."
        case .bayerDNG: break
        }
        guard surface == .ready, case .available(true) = capability.bayerCaptureSupported else {
            return surface.userDescription
        }
        if let camera = capability.physicalCameras.first(where: { $0.kind == capability.selectedCameraKind }),
           case .available(let measured) = camera.observedRAWDimensions {
            return "RAW at the measured native size \(measured.width) by \(measured.height)"
        }
        if let ceiling = capability.configuredPhotoDimensions {
            return "Bayer RAW requested ceiling \(ceiling.width) by \(ceiling.height). Actual RAW dimensions have not been measured."
        }
        return "Bayer RAW. Actual RAW dimensions have not been measured."
    }

    var exposureReadout: String {
        let duration = exposure.durationTargetSeconds
            ?? observedDurationSeconds
        let iso = exposure.isoTarget ?? observedISO
        let shutter = duration.map(ExposureFormatting.duration) ?? "—"
        let isoText = iso.map(ExposureFormatting.iso) ?? "—"
        return "\(exposure.mode == .auto ? "Auto" : shutter) · ISO \(isoText)"
    }

    var shutterReadout: String {
        if let target = exposure.durationTargetSeconds {
            return ExposureFormatting.duration(target)
        }
        return "Auto · \(observedDurationSeconds.map(ExposureFormatting.duration) ?? "—")"
    }

    var isoReadout: String {
        if let target = exposure.isoTarget {
            return ExposureFormatting.iso(target)
        }
        return "Auto · \(observedISO.map(ExposureFormatting.iso) ?? "—")"
    }

    var isShutterManual: Bool { exposure.durationTargetSeconds != nil }
    var isISOManual: Bool { exposure.isoTarget != nil }

    var exposureLimits: ExposureLimits {
        activeFormat?.exposureLimits
            ?? ExposureLimits(minDurationSeconds: .nan, maxDurationSeconds: .nan,
                              minISO: .nan, maxISO: .nan, minBiasEV: .nan, maxBiasEV: .nan)
    }

    var activeFormat: FormatCapability? {
        guard let kind = capability.selectedCameraKind,
              let camera = capability.camera(kind),
              !camera.formats.isEmpty else { return nil }
        let index = camera.selectedFormatIndex ?? camera.formats.startIndex
        return camera.formats.indices.contains(index) ? camera.formats[index] : nil
    }

    var isBiasAvailable: Bool { exposure.mode != .manual || (aperture.isAutomatic && activeFormat?.apertureCapability?.isVariable == true) }

    var availableExposureModes: [ExposureModeKind] {
        ExposureModeKind.allCases.filter { supportsExposureMode($0) }
    }

    func supportsExposureMode(_ mode: ExposureModeKind) -> Bool {
        supportsAperture(aperture, exposureMode: mode)
    }

    private func supportsAperture(_ choice: ApertureChoice, exposureMode: ExposureModeKind) -> Bool {
        if exposureMode == .auto && choice.isAutomatic { return true }
        guard let format = activeFormat, format.supportsCustomExposureMode.value == true else { return false }
        if let capability = format.apertureCapability {
            return capability.supports(choice, exposureMode: exposureMode)
        }
        return choice.isAutomatic && format.supportedPriorityCombinations.contains(exposureMode)
    }

    var isApertureAvailable: Bool {
        activeFormat?.supportsCustomExposureMode.value == true
            && activeFormat?.apertureCapability?.isVariable == true
            && activeFormat?.apertureCapability?.manualExposureModes.isEmpty == false
    }
    var canAdjustAperture: Bool {
        isApertureAvailable && activeFormat?.apertureCapability?.manualExposureModes.contains(exposure.mode) == true
    }
    var isApertureManual: Bool { !aperture.isAutomatic }
    var apertureStops: [Double] { activeFormat?.apertureCapability?.selectableStops ?? [] }
    var selectedApertureValue: Double {
        aperture.numericTarget ?? currentApertureReading ?? apertureStops.first ?? 1
    }
    private var currentApertureReading: Double? {
        guard let reading = applied, reading.generation == capability.generation,
              let value = reading.lensAperture, value.isFinite, value > 0 else { return nil }
        return value
    }
    var apertureReadout: String {
        guard let value = aperture.numericTarget ?? currentApertureReading else { return "—" }
        return ApertureFormatting.fNumber(value)
    }
    func setAperture(_ value: Double) {
        let choice = ApertureChoice.manual(fNumber: value)
        guard supportsAperture(choice, exposureMode: exposure.mode) else {
            lastNotice = "That aperture is unavailable with these settings."
            return
        }
        aperture = choice
        scheduleApply()
    }
    func setApertureManual(_ enabled: Bool) {
        if enabled { setAperture(selectedApertureValue) }
        else if supportsAperture(.auto, exposureMode: exposure.mode) {
            aperture = .auto
            scheduleApply()
        }
    }
    private func reconcileApertureCapability() {
        guard capability.selectedCameraKind != nil else { return }
        if !isApertureAvailable {
            aperture = .auto
            if openPanel == .aperture { openPanel = nil }
        } else if !supportsAperture(aperture, exposureMode: exposure.mode) {
            aperture = .auto
        }
    }

    private var manualDurationStart: Double {
        clampDuration(exposure.durationTargetSeconds ?? observedDurationSeconds ?? exposureLimits.maxDurationSeconds)
    }
    private var manualISOStart: Double {
        clampISO(exposure.isoTarget ?? observedISO ?? exposureLimits.minISO)
    }

    var canToggleShutterManual: Bool {
        supportsExposureMode(shutterSelection(!isShutterManual).mode)
    }
    var canToggleISOManual: Bool {
        supportsExposureMode(isoSelection(!isISOManual).mode)
    }

    private func shutterSelection(_ enabled: Bool) -> ExposureChoice {
        enabled ? .settingDurationManual(manualDurationStart, from: exposure) : .settingDurationAuto(from: exposure)
    }
    private func isoSelection(_ enabled: Bool) -> ExposureChoice {
        enabled ? .settingISOManual(manualISOStart, from: exposure) : .settingISOAuto(from: exposure)
    }

    /// Select both parameters as one explicit action, so full Manual remains
    /// reachable when neither independent priority mode is supported.
    func setExposureMode(_ mode: ExposureModeKind) {
        let choice: ExposureChoice
        switch mode {
        case .auto: choice = .auto
        case .manual: choice = .manual(durationSeconds: manualDurationStart, iso: manualISOStart)
        case .shutterPriority: choice = .shutterPriority(durationSeconds: manualDurationStart)
        case .isoPriority: choice = .isoPriority(iso: manualISOStart)
        }
        selectExposure(choice)
    }

    private func selectExposure(_ choice: ExposureChoice) {
        // A known configuration must never retain an unsupported UI selection.
        // Before preparation we may retain intent, but scheduleApply issues no SDK work.
        if activeFormat != nil, !supportsExposureMode(choice.mode) {
            lastNotice = "\(choice.mode.displayName) is unavailable on this camera configuration. Choose Auto or a supported exposure mode."
            return
        }
        exposure = choice
        scheduleApply()
    }

    func setShutterManual(_ enabled: Bool) { selectExposure(shutterSelection(enabled)) }
    func setISOManual(_ enabled: Bool) { selectExposure(isoSelection(enabled)) }
    func setDuration(_ seconds: Double) {
        selectExposure(.settingDurationManual(clampDuration(seconds), from: exposure))
    }
    func setISO(_ value: Double) {
        selectExposure(.settingISOManual(clampISO(value), from: exposure))
    }

    /// Auto preserves peer settings whenever that transition is supported.
    /// When no manual parameter can independently return to Auto, an explicitly
    /// labelled whole-program reset prevents trapping the user in Manual.
    private func supportsIndependentAutomatic(_ panel: CameraPanel) -> Bool {
        switch panel {
        case .shutter: return supportsExposureMode(ExposureChoice.settingDurationAuto(from: exposure).mode)
        case .iso: return supportsExposureMode(ExposureChoice.settingISOAuto(from: exposure).mode)
        case .aperture: return supportsAperture(.auto, exposureMode: exposure.mode)
        case .focus, .whiteBalance, .exposureBias: return true
        }
    }
    private var needsExposureReset: Bool {
        (isShutterManual || isISOManual || isApertureManual)
            && !(isShutterManual && supportsIndependentAutomatic(.shutter))
            && !(isISOManual && supportsIndependentAutomatic(.iso))
            && !(isApertureAvailable && isApertureManual && supportsIndependentAutomatic(.aperture))
    }
    func canSetStripAutomatic(_ panel: CameraPanel) -> Bool {
        supportsIndependentAutomatic(panel) || (needsExposureReset && [.shutter, .iso, .aperture].contains(panel))
    }
    func stripAutomaticLabel(_ panel: CameraPanel) -> String {
        if panel == .exposureBias { return "Reset" }
        if !supportsIndependentAutomatic(panel), needsExposureReset {
            return aperture.isAutomatic ? "Auto both" : "Auto all"
        }
        return "Auto"
    }
    func stripManualHint(_ panel: CameraPanel) -> String {
        let paired: Bool
        switch panel {
        case .shutter: paired = !supportsExposureMode(shutterSelection(true).mode)
        case .iso: paired = !supportsExposureMode(isoSelection(true).mode)
        default: paired = false
        }
        return paired ? "Sets both shutter and ISO manually." : "Sets \(panel.title.lowercased()) manually."
    }
    func adjustShutterFromStrip(_ seconds: Double) {
        let value = clampDuration(seconds)
        let proposed = ExposureChoice.settingDurationManual(value, from: exposure)
        if supportsExposureMode(proposed.mode) { selectExposure(proposed) }
        else if supportsExposureMode(.manual) { selectExposure(.manual(durationSeconds: value, iso: manualISOStart)) }
    }
    func adjustISOFromStrip(_ iso: Double) {
        let value = clampISO(iso)
        let proposed = ExposureChoice.settingISOManual(value, from: exposure)
        if supportsExposureMode(proposed.mode) { selectExposure(proposed) }
        else if supportsExposureMode(.manual) { selectExposure(.manual(durationSeconds: manualDurationStart, iso: value)) }
    }
    func setStripAutomatic(_ panel: CameraPanel) {
        if [.shutter, .iso, .aperture].contains(panel),
           !supportsIndependentAutomatic(panel), needsExposureReset {
            exposure = .auto
            aperture = .auto
            scheduleApply()
            return
        }
        switch panel {
        case .shutter:
            if canSetStripAutomatic(panel) { setShutterManual(false) }
        case .iso:
            if canSetStripAutomatic(panel) { setISOManual(false) }
        case .aperture: setApertureManual(false)
        case .focus: setFocusManual(false)
        case .whiteBalance: setWhiteBalanceManual(false)
        case .exposureBias: setBias(0)
        }
    }

    func setBias(_ value: Double) {
        let limits = exposureLimits
        biasEV = limits.isValid ? min(max(value, limits.minBiasEV), limits.maxBiasEV) : value
        scheduleApply()
    }

    private func clampDuration(_ seconds: Double) -> Double {
        let limits = exposureLimits
        guard limits.isValid, seconds.isFinite else { return seconds }
        return min(max(seconds, limits.minDurationSeconds), limits.maxDurationSeconds)
    }

    private func clampISO(_ value: Double) -> Double {
        let limits = exposureLimits
        guard limits.isValid, value.isFinite else { return value }
        return min(max(value, limits.minISO), limits.maxISO)
    }

    // MARK: Focus

    var focusReadout: String {
        switch focus.mode {
        case .manual:
            return "M · \(String(format: "%.2f", focus.position ?? 0))"
        case .continuousAuto:
            return "AF"
        case .lockedAuto:
            return "AF-L"
        }
    }

    var focusLimits: FocusLimits {
        activeFormat?.focusLimits
            ?? FocusLimits(supportsCustomLensPosition: false,
                           supportsPointOfInterest: false,
                           supportsContinuousAutoFocus: false,
                           supportsAutoFocus: false,
                           positionZeroDirectionVerified: false)
    }

    /// Manual focus is only offered when the camera actually supports a custom
    /// lens position.
    var isManualFocusAvailable: Bool { focusLimits.supportsCustomLensPosition }

    func setFocusManual(_ enabled: Bool) {
        if enabled {
            let start = clampPosition(focus.position ?? observedFocusPosition ?? 0.5)
            focus = FocusIntent(mode: .manual, position: start, pointOfInterest: nil)
        } else {
            focus = FocusIntent(mode: .continuousAuto, position: nil, pointOfInterest: focus.pointOfInterest)
        }
        scheduleApply()
    }

    func setManualFocusPosition(_ position: Double) {
        focus = FocusIntent(mode: .manual, position: clampPosition(position), pointOfInterest: nil)
        scheduleApply()
    }

    func lockFocus() {
        guard focus.mode != .manual else { return }
        focus = FocusIntent(mode: .lockedAuto, position: nil, pointOfInterest: focus.pointOfInterest)
        scheduleApply()
    }

    private func clampPosition(_ value: Double) -> Double {
        guard value.isFinite else { return 0.5 }
        return min(max(value, 0), 1)
    }

    /// A tap inside the visible image focuses. In manual mode a tap must not
    /// silently unlock focus, so it only happens in an autofocus mode.
    var canAdjustFocusPoint: Bool {
        isCameraEligibleForCapture && presentedCameraSheet == nil && runtimeAdmissionReady
            && isPreviewConnectionStable && hasRenderedCurrentPreview && hasCurrentDisplayGeometry
            && !isCaptureBusy && !isTimerRunning && !controlRestorationFailed
            && sequenceBlockedByRestorationFailure == nil && focus.mode != .manual
            && focusLimits.supportsPointOfInterest
            && (focus.mode == .continuousAuto ? focusLimits.supportsContinuousAutoFocus : focusLimits.supportsAutoFocus)
    }
    func handleFocusTap(atViewPoint point: TCPoint, mapper: PreviewGeometryMapper) async {
        guard canAdjustFocusPoint,
              mapper == previewGeometryMapper(fallbackContentRect: mapper.contentRect),
              let devicePoint = mapper.devicePoint(forViewPoint: point) else { return }
        // A focus tap is a normal owned control revision. It must not bypass
        // generation/settlement ownership or change a submitted sequence's focus.
        focus = FocusIntent(mode: focus.mode, position: nil, pointOfInterest: devicePoint)
        scheduleApply()
    }

    // MARK: White balance

    var whiteBalanceReadout: String {
        switch whiteBalance.mode {
        case .auto:
            return "AWB"
        case .manual:
            guard let value = whiteBalance.temperatureAndTint else { return "M" }
            return "M · \(Int(value.temperature.rounded()))K \(String(format: "%+.0f", value.tint))"
        }
    }

    var isManualWhiteBalanceAvailable: Bool {
        if case .available = activeFormat?.whiteBalanceLimits { return true }
        return false
    }

    func setWhiteBalanceManual(_ enabled: Bool) {
        if enabled {
            let existing = whiteBalance.temperatureAndTint
                ?? WhiteBalanceTemperatureAndTint(temperature: 5500, tint: 0)
            whiteBalance = WhiteBalanceIntent(mode: .manual, temperatureAndTint: existing)
        } else {
            whiteBalance = WhiteBalanceIntent(mode: .auto, temperatureAndTint: nil)
        }
        scheduleApply()
    }

    func setWhiteBalanceTemperature(_ kelvin: Double) {
        let current = whiteBalance.temperatureAndTint ?? WhiteBalanceTemperatureAndTint(temperature: 5500, tint: 0)
        guard kelvin.isFinite, kelvin > 0 else { return }
        whiteBalance = WhiteBalanceIntent(
            mode: .manual,
            temperatureAndTint: WhiteBalanceTemperatureAndTint(temperature: kelvin, tint: current.tint))
        scheduleApply()
    }

    func setWhiteBalanceTint(_ tint: Double) {
        let current = whiteBalance.temperatureAndTint ?? WhiteBalanceTemperatureAndTint(temperature: 5500, tint: 0)
        guard tint.isFinite else { return }
        whiteBalance = WhiteBalanceIntent(
            mode: .manual,
            temperatureAndTint: WhiteBalanceTemperatureAndTint(temperature: current.temperature, tint: tint))
        scheduleApply()
    }

    // MARK: Applying controls

    /// Coalesces rapid changes: at most one application is in flight and the
    /// newest desired state wins. A rejected combination leaves the last valid
    /// applied state and the original sources untouched.
    private func scheduleApply() {
        controlRevision += 1
        // Retain the user's intent, but never issue setters against a failed or
        // unprepared graph. That replaced the useful startup error with noCamera.
        guard isPreviewConnectionStable, !isCaptureBusy else { return }
        let revision = controlRevision
        let previous = applyTask
        previous?.cancel()
        applyTask = Task { [weak self] in
            // Small settle window so a slider drag does not queue one device
            // operation per touch event.
            try? await Task.sleep(nanoseconds: 60_000_000)
            // Native setters already issued by a cancelled predecessor still
            // own their callbacks. Preserve that drain in the latest task so a
            // later shutter can await the entire interactive application chain.
            await previous?.value
            guard !Task.isCancelled, let self, self.isPreviewConnectionStable,
                  !self.isCaptureBusy, revision == self.controlRevision else { return }
            await self.applyCurrentControls(revision: revision)
        }
    }

    /// A debounced UI setter must not become a newer native application while
    /// the shutter or a sequence is settling its own frozen controls. Cancellation
    /// skips an unissued debounce; an already-issued setter drains before the
    /// capture owner starts. The owner's application still applies current intent.
    private func drainInteractiveControlApplication() async {
        let pending = applyTask
        applyTask = nil
        pending?.cancel()
        await pending?.value
    }

    /// Whether THIS control application actually reached the camera.
    enum ControlApplication: Equatable, Sendable {
        /// Every native setter was acknowledged and the readback was published.
        case applied
        /// The request was rejected or failed; `lastFailure` describes it.
        case refused
        /// A newer application superseded this one, so its result was not published.
        case superseded
    }

    @discardableResult
    func applyCurrentControls(revision: UInt64? = nil) async -> ControlApplication {
        let effectiveRevision = revision ?? controlRevision
        lastAppliedRequestRevision = effectiveRevision
        let result = await camera.applyControls(
            revision: effectiveRevision,
            exposure: exposure,
            biasEV: biasEV,
            focus: focus,
            whiteBalance: whiteBalance, aperture: aperture)
        switch result {
        case .success(let snapshot):
            // R01: a stale completion must not overwrite a newer readback. Omitting the
            // revision does NOT exempt a result: `effectiveRevision` is the revision this
            // invocation captured at call time, so a default call whose result arrives
            // after a newer explicit application is superseded like any other.
            guard effectiveRevision >= controlRevision else { return .superseded }
            lastReadback = snapshot
            applied = snapshot
            observedDurationSeconds = snapshot.observedDurationSeconds
            observedISO = snapshot.observedISO
            observedExposureTargetOffset = snapshot.observedExposureTargetOffset
            observedFocusPosition = snapshot.focusPosition
            observedWhiteBalanceGains = snapshot.whiteBalanceGains
            if let controlFailure, lastFailure == controlFailure { lastFailure = nil }
            controlFailure = nil
            return .applied
        case .failure(let failure):
            guard effectiveRevision >= controlRevision else { return .superseded }
            // Keep the previous applied state; surface the rejection.
            report(failure)
            controlFailure = lastFailure
            return .refused
        }
    }

    func refreshReadback(ownedByCameraOperation: Bool = false) async {
        // A readback publication advances native identity. Polling during start's
        // final validation can obsolete that same start, despite no sensor change.
        guard ownedByCameraOperation || isPreviewConnectionStable else { return }
        guard let snapshot = await camera.currentControlReadback() else { return }
        applyReadback(snapshot)
    }

    /// Observes the device's own readings so automatic parameters move on screen.
    ///
    /// REVIEW.md C05: this used to poll `currentControlReadback`, which returned
    /// the setter's snapshot unchanged, so "observed" values never changed. It now
    /// consumes the service's published live readings and is restartable, and it
    /// also asks the service for a fresh read on demand.
    /// A human-readable statement of how trustworthy the last readback is.
    ///
    /// Starts the lifecycle-owned readback producer.
    ///
    /// REVIEW.md R03: this primed once and then waited on `controlReadbackStream`,
    /// which nothing produced during an ordinary Auto session — `currentControlReadback`
    /// only ran when a caller asked. Live ISO, shutter, exposure offset, focus
    /// position and white-balance gains therefore froze until an unrelated action
    /// happened. There are now two cooperating sources:
    ///
    ///   * a RECURRING sampler on a monotonic interval, which is what makes the Auto
    ///     readouts actually live, and
    ///   * the sink stream, which delivers the setter's own acknowledgement promptly
    ///     after a control change instead of waiting for the next tick.
    ///
    /// Both end with the same task, so stopping the observation stops sampling.
    /// Starts consuming the service's native session conditions.
    ///
    /// REVIEW.md F02: `handleMediaServicesReset` and the recorded condition had no
    /// caller, so an interruption or media-services reset never closed the shutter
    /// gate. This is that caller.
    func startSessionConditionObservation() {
        sessionConditionTask?.cancel()
        let camera = self.camera
        sessionConditionTask = Task { [weak self, camera] in
            if let provider = camera as? any CameraSessionStatusProviding {
                let initial = await provider.recordedSessionStatus()
                var resetEpoch = initial.resetEpoch
                guard !Task.isCancelled else { return }
                await self?.applyServiceCondition(initial.condition, isTransition: false)
                for await status in provider.sessionStatusStream {
                    guard !Task.isCancelled, let self else { return }
                    if status.resetEpoch != resetEpoch {
                        resetEpoch = status.resetEpoch
                        self.reserveResetAnalysisTopology()
                        let conditionRevision = self.serviceConditionRevision
                        // The lifecycle stream may have skipped the transient reset failure.
                        // The cumulative reset identity still delivers the loss-critical effect.
                        await self.sequenceCoordinator?.interrupt(reason: .mediaServicesReset)
                        await self.suspendRuntimeAdmission(ownedByCondition: conditionRevision)
                    }
                    await self.applyServiceCondition(status.condition)
                }
            } else {
                await self?.applyServiceCondition(
                    await camera.recordedSessionCondition(), isTransition: false)
                for await condition in camera.sessionConditionStream {
                    guard !Task.isCancelled, let self else { return }
                    await self.applyServiceCondition(condition)
                }
            }
        }
    }

    func stopSessionConditionObservation() {
        sessionConditionTask?.cancel()
        sessionConditionTask = nil
    }

    func startReadbackObservation() {
        stopReadbackObservation()
        let camera = self.camera
        readbackTask = Task { [weak self, camera] in
            await self?.refreshReadback()
            await withTaskGroup(of: Void.self) { group in
                group.addTask { [weak self, camera] in
                    for await snapshot in camera.controlReadbackStream {
                        guard !Task.isCancelled else { return }
                        await self?.applyReadback(snapshot)
                    }
                }
                group.addTask { [weak self] in
                    while !Task.isCancelled {
                        try? await Task.sleep(nanoseconds: Self.readbackSamplingIntervalNanoseconds)
                        guard !Task.isCancelled else { return }
                        await self?.refreshReadback()
                    }
                }
                await group.waitForAll()
            }
        }
    }

    /// How often the live control readback is sampled while the camera view is
    /// active. This is a sampling cadence for display, not a device capability.
    static let readbackSamplingIntervalNanoseconds: UInt64 = 250_000_000

    private func applyReadback(_ snapshot: AppliedControlSnapshot) {
        // A readback from an older configuration must not relabel the controls.
        guard snapshot.generation == capability.generation else { return }
        // REVIEW.md F03: generation alone is not request relevance. A live reading
        // tagged with a request revision OLDER than the newest one we issued
        // describes settings the user has already replaced, so its measured values
        // must not be presented as the current state.
        if let readingRevision = snapshot.requestRevision, readingRevision < controlRevision {
            staleReadbackCount += 1
            return
        }
        lastReadback = snapshot
        applied = snapshot
        observedDurationSeconds = snapshot.observedDurationSeconds
        observedISO = snapshot.observedISO
        observedExposureTargetOffset = snapshot.observedExposureTargetOffset
        observedFocusPosition = snapshot.focusPosition
        observedWhiteBalanceGains = snapshot.whiteBalanceGains
    }

    func stopReadbackObservation() {
        readbackTask?.cancel()
        readbackTask = nil
    }

    // MARK: Capture

    var readinessInputs: CaptureReadinessInputs {
        let bayerSupport: DiscoveryStatus<Bool>
        if let format = activeFormat {
            switch format.supportsCustomExposureMode {
            case .available:
                bayerSupport = capability.bayerCaptureSupported
            case .unavailable(let reason):
                bayerSupport = .unavailable(reason: reason)
            case .unknown(let reason):
                bayerSupport = .unknown(reason: reason)
            }
        } else {
            bayerSupport = capability.bayerCaptureSupported
        }
        return CaptureReadinessInputs(
            // REVIEW.md R02: this was hardcoded `true`, so readiness claimed an
            // active screen even while the app was in the background.
            // REVIEW.md G02: the gate needs the COMBINED eligibility. Passing only
            // the scene flag let the shutter open while the library covered the
            // camera screen.
            isSceneActive: isCameraEligibleForCapture,
            cameraLifecycle: effectiveLifecycle,
            hasCameraPermission: surface != .cameraPermissionDenied,
            bayerSupport: bayerSupport,
            controlsSupported: appliesLegally(),
            unsupportedControlsDetail: nil,
            rootState: currentRootState,
            pendingOriginalCount: pendingOriginalCount,
            activeSequenceDescription: activeSequenceID != nil ? sequenceStatusLine : nil,
            isReconfiguring: effectiveLifecycle == .reconfiguring,
            restorationFailedDetail: sequenceBlockedByRestorationFailure,
            frontHEIFSupported: effectiveCaptureFileFormat == .frontHEIF && capability.frontHEIFSupported && capability.selectedCameraKind == .front,
            fileFormat: effectiveCaptureFileFormat,
            jpegSupported: capability.jpegSupported && capability.jpegMaximumDimensions != nil)
    }

    /// True when the current desired selection is legal on the active format.
    func appliesLegally() -> Bool {
        let limits = exposureLimits
        let supportsCustom = activeFormat?.supportsCustomExposureMode.value ?? false
        let failures = ExposureValidator.validate(
            choice: exposure,
            limits: limits,
            supportsCustomExposureMode: supportsCustom,
            supportsCombination: { choice in
                guard activeFormat != nil else { return false }
                switch choice.mode {
                case .auto: return true
                case .shutterPriority, .isoPriority, .manual:
                    return supportsAperture(aperture, exposureMode: choice.mode)
                }
            })
        if !failures.isEmpty || !supportsAperture(aperture, exposureMode: exposure.mode) { return false }
        if let failure = ExposureValidator.validateBias(biasEV, limits: limits) {
            _ = failure
            return !isBiasAvailable
        }
        return true
    }

    private(set) var currentRootState: LibraryRootState = .unselected

    func updateRootState(_ state: LibraryRootState) {
        if state != currentRootState { stopContinuousCapture() }
        if state != currentRootState {
            switch state {
            case .readOnly(let reason, _), .unavailable(let reason, _):
                AppDiagnostics.record(reason, operation: "camera.libraryRoot")
            default: break
            }
        }
        currentRootState = state
    }

    func updatePendingOriginalCount(_ count: Int) {
        pendingOriginalCount = max(0, count)
    }

    /// The shutter. Never reports a save before a verified commit.
    func captureNow() async {
        guard !isContinuousCaptureActive else { return }
        _ = await captureOnePhoto()
    }

    private func captureOnePhoto(admission: @MainActor () -> Bool = { true }) async -> Bool {
        guard admission(), !isCaptureBusy, !isSwitchingLens, runtimeAdmissionReady else { return false }
        if previewSessionBox != nil, geometry?.configurationGeneration != capability.generation { return false }
        let block = capture.blockReason(for: readinessInputs)
        if let block {
            report(CaptureFailure(kind: .invalidSettings(detail: block.userDescription), operation: "capture"))
            return false
        }
        let rootState = currentRootState
        guard case .writable(let libraryID, let rootGeneration) = rootState,
              let kind = capability.selectedCameraKind,
              let format = activeFormat else { return false }

        // Freeze the chosen container and its proven ceiling together. JPEG's
        // output ceiling never substitutes for the Bayer configuration's ceiling.
        let fileFormat = effectiveCaptureFileFormat
        let selectedDimensions = fileFormat == .jpeg ? capability.jpegMaximumDimensions
            : format.supportedMaxPhotoDimensions.max(by: { $0.pixelCount < $1.pixelCount })
        guard let dimensions = selectedDimensions else {
            report(CaptureFailure(
                kind: .unsupportedCapability(
                    detail: "The active format did not advertise a maximum photo dimension for the chosen capture format."),
                operation: "capture"))
            return false
        }

        isCapturing = true
        let captureEpoch = eligibilityEpoch, captureGeneration = capability.generation
        lastCaptureWasExposureBracket = false
        defer {
            isCapturing = false
            if resourcePressureNeedsReconciliation {
                Task { [weak self] in await self?.reconcileResourcePressureIfNeeded() }
            }
        }
        await drainInteractiveControlApplication()
        guard admission(), !Task.isCancelled, captureEpoch == eligibilityEpoch,
              captureGeneration == capability.generation, currentRootState == rootState,
              fileFormat == effectiveCaptureFileFormat,
              runtimeAdmissionReady, isCameraEligibleForCapture,
              capture.blockReason(for: readinessInputs) == nil else { return false }
        #if DEBUG
        let responsivenessBegan = ProcessInfo.processInfo.systemUptime
        let responsiveness = Task { @MainActor in
            var previous = responsivenessBegan
            while !Task.isCancelled {
                do { try await Task.sleep(for: .milliseconds(100)) } catch { return }
                let now = ProcessInfo.processInfo.systemUptime
                let gap = Int((now - previous) * 1000)
                previous = now
                if gap > 250 { print("TruongCam timing main-actor-gap=\(gap)ms context=capture") }
            }
        }
        defer { responsiveness.cancel() }
        #endif

        let intent = CaptureIntent(
            captureID: CaptureID(),
            libraryID: libraryID,
            requestedDimensions: dimensions,
            exposure: exposure,
            biasEV: biasEV,
            focus: focus,
            whiteBalance: whiteBalance,
            configurationGeneration: capability.generation,
            rootGeneration: rootGeneration,
            physicalCameraKind: kind,
            createdAtUTC: Date(),
            timezoneOffsetSeconds: TimeZone.current.secondsFromGMT(),
            mode: .single,
            equivalentFocalLengthMM: capability.camera(kind)?.validNominalEquivalentFocalLengthMM,
            fileFormat: fileFormat, aperture: aperture)

        #if DEBUG
        if let run = continuousRunID {
            print("TruongCam drive-frame run=\(run) ordinal=\(continuousCapturedCount + 1) speed=\(captureSpeed.rawValue) capture=\(intent.captureID)")
        }
        #endif

        // Snapshot the readback for THIS request so a later readback cannot
        // relabel this image's observed state.
        await capture.noteReadback(applied, for: intent.captureID)
        guard admission(), captureEpoch == eligibilityEpoch, captureGeneration == capability.generation,
              rootState == currentRootState, runtimeAdmissionReady, isCameraEligibleForCapture else {
            await capture.noteReadback(nil, for: intent.captureID)
            return false
        }
        #if DEBUG
        let captureBegan = clock.now()
        #endif
        let result = await capture.capture(intent: intent)
        #if DEBUG
        print("TruongCam timing capture-through-verified-commit=\(Int((clock.now() - captureBegan) * 1000))ms")
        #endif
        lastCommittedReceipts = result.committedReceipts
        updatePendingOriginalCount(result.pendingTransactionIDs.count)
        // G06: notify for BOTH outcomes. A retained failure leaves sources pending in
        // durable staging, and the application's recovery list must show them; a
        // successful commit may also have cleared pending entries.
        let pendingAfterCapture = result.pendingTransactionIDs.count
        await onPendingOriginalsChanged?(pendingAfterCapture)
        // A verified commit is durable already; the index update is separate and
        // an index failure must never look like a save failure (CONTRACTS.md).
        if !result.committedReceipts.isEmpty {
            enqueueReceiptPublication(result.committedReceipts)
        }

        if !result.committedReceipts.isEmpty {
            // Measure the real RAW size; this is the only path that moves
            // observed dimensions off "unknown".
            if fileFormat == .bayerDNG,
               let measured = result.committedReceipts.first?.metadata.observed.rawDimensions {
                await camera.recordMeasuredRAWDimensions(
                    measured,
                    evidenceOrigin: "measured from a captured RAW source on this device")
            }
            capability = await camera.capabilitySnapshot
        }
        if let failure = result.failures.first {
            report(failure)
        }
        return result.failures.isEmpty && result.pendingTransactionIDs.isEmpty && result.committedReceipts.count == 1
    }

    // Verified folder commits remain serialized by CaptureCoordinator. The
    // disposable index/gallery refresh is ordered but no longer holds the shutter.
    private var receiptPublicationTask: Task<Void, Never>?
    private func enqueueReceiptPublication(_ receipts: [CommitReceipt]) {
        let previous = receiptPublicationTask
        let publish = onCommittedReceipts
        receiptPublicationTask = Task {
            await previous?.value
            await publish?(receipts)
        }
    }
    func waitForReceiptPublication() async { await receiptPublicationTask?.value }

    /// One action for touch and hardware shutter; timers keep identical semantics.
    func activateShutter() async {
        guard isShutterEnabled else { return }
        if isTimerRunning { cancelTimer() }
        else if let seconds = timerSeconds, seconds > 0 { startTimerCountdown(seconds: seconds) }
        else { await captureConfiguredMode() }
    }

    private func captureConfiguredMode() async {
        switch activeShutterMode {
        case .single: await captureNow()
        case .exposureBracket: requestSequence(.exposureBracket)
        case .focusBracket: requestSequence(.focusBracket)
        case .interval: requestSequence(.interval)
        }
    }
    var isHardwareShutterEnabled: Bool {
        isCameraEligibleForCapture && (isShutterEnabled || isContinuousCaptureHeld) && presentedCameraSheet == nil
    }
    private var hardwareShutterPress: [HardwareShutterSource: HardwareShutterPress] = [:]
    private enum HardwareShutterPress { case single, continuous(UUID) }
    func handleHardwareShutter(_ phase: ShutterPressPhase, source: HardwareShutterSource = .primary) {
        switch phase {
        case .began:
            guard hardwareShutterPress[source] == nil, isHardwareShutterEnabled else { return }
            if captureSpeed == .single { hardwareShutterPress[source] = .single }
            else {
                let id = UUID()
                if beginShutterHold(id: id) { hardwareShutterPress[source] = .continuous(id) }
            }
        case .ended, .cancelled:
            let press = hardwareShutterPress.removeValue(forKey: source)
            switch press {
            case .continuous(let id):
                if phase == .ended { endShutterHold(id: id) }
                else { cancelShutterHold(id: id) }
            case .single:
                guard phase == .ended, captureSpeed == .single, isHardwareShutterEnabled else { return }
                Task { await activateShutter() }
            case nil: break
            }
        }
    }
    /// System event registration follows the visible camera, while each actual
    /// shutter/setting command still passes its stricter admission checks.
    var isHardwareInteractionEligible: Bool {
        isCameraEligibleForCapture && presentedCameraSheet == nil
            && ((surface == .ready && effectiveLifecycle == .running) || ownsHardwareLensTransition)
    }

    private func startShutterFeedbackConsumption() {
        let events = capture.shutterFeedback.subscribe()
        shutterFeedbackTask = Task { [weak self] in
            for await event in events {
                guard !Task.isCancelled else { return }
                self?.receiveShutterFeedback(event)
            }
        }
    }
    func receiveShutterFeedback(_ event: CaptureShutterFeedback) {
        guard isCameraEligibleForCapture, runtimeAdmissionReady, !isSwitchingLens, event.generation == capability.generation,
              event.captureID != lastFeedbackCaptureID,
              event.sequenceID == nil || event.sequenceID == activeSequenceID,
              Date().timeIntervalSince(event.capturedAtUTC) >= -0.01,
              Date().timeIntervalSince(event.capturedAtUTC) < 0.75 else { return }
        lastFeedbackCaptureID = event.captureID
        if event.sequenceID != nil {
            sequenceFrameOrdinal = (event.ordinal ?? 0) + 1
            sequencePlannedCount = event.plannedCount ?? sequencePlannedCount
        }
        shutterPulse &+= 1
    }

    // MARK: Analysis wiring

    /// Fixed bitmap captured before the input swap, never the changing live layer.
    private(set) var frozenSwitchPreview: PreviewTransitionFrame?
    private(set) var isPreviewTransitionVisible = false
    #if DEBUG
    @ObservationIgnored private var switchPreviewBegan: Double?
    #endif
    private var renderedPreviewLayout: (ConfigurationGeneration, UInt64)?
    var hasRenderedCurrentPreview: Bool {
        previewSessionBox == nil || (renderedPreviewLayout?.0 == capability.generation
            && renderedPreviewLayout?.1 == geometry?.layoutGeneration)
    }
    func finishPreviewTransition() {
        isPreviewTransitionVisible = false
        frozenSwitchPreview = nil
        #if DEBUG
        switchPreviewBegan = nil
        #endif
    }
    @discardableResult
    func previewDidResume(generation: ConfigurationGeneration, layout: UInt64) -> Bool {
        guard isPreviewConnectionStable, geometry?.configurationGeneration == generation,
              geometry?.layoutGeneration == layout else { return false }
        // When a prior analysis still existed, wait for a frame under the new
        // camera/layout too. Disabled/unsupported analysis uses native previewing.
        let wantsFrames = composition.histogramEnabled || composition.peakingEnabled
            || composition.zebrasEnabled || composition.loupeEnabled
        if isPreviewTransitionVisible, frozenSwitchPreview != nil, wantsFrames,
           analysisUnavailableReason == nil, displayBridge?.hasCurrentFrame(for:geometry) != true { return false }
        renderedPreviewLayout = (generation, layout)
        #if DEBUG
        if let switchPreviewBegan {
            print("TruongCam timing switch-preview-ready=\(Int((clock.now() - switchPreviewBegan) * 1000))ms generation=\(generation.value) layout=\(layout) camera=\(capability.selectedCameraKind?.rawValue ?? "none")")
        }
        #endif
        finishPreviewTransition()
        // A genuinely rendered usable generation ends the previous failure
        // episode. A failing restart before this point gets no retry loop.
        automaticRecoveryAttempted = false
        drainHardwareLensIntent()
        return true
    }

    var hasCurrentDisplayGeometry: Bool { previewSessionBox == nil || geometry?.configurationGeneration == capability.generation }

    var isPreviewConnectionStable: Bool {
        unfinishedStartAttempt == nil && !isSwitchingLens && lifecycle == .running && effectiveLifecycle == .running && surface == .ready
    }
    func updateGeometry(_ geometry: PreviewGeometrySnapshot?) {
        if let geometry {
            guard isPreviewConnectionStable, geometry.configurationGeneration == capability.generation else { return }
        }
        self.geometry = geometry
        masks = nil; loupe = nil
        if let orientation = geometry?.interfaceOrientation { setLevelOrientation(orientation) }
        Task { [weak self] in
            guard let self else { return }
            await camera.updatePreviewGeometry(geometry)
            guard self.geometry == geometry else { return }
            // The first layout may arrive AFTER the startup request was nil.
            // Rebuild the full user's request, rather than just moving a nil one.
            await updateAnalysisDemand()
        }
    }

    func updateAnalysisDemand(ownedByCameraOperation: Bool = false) async {
        guard ownedByCameraOperation || (unfinishedStartAttempt == nil && !isSwitchingLens) else { return }
        // Ordinary layout/tool/lifecycle callbacks cannot replace the typed
        // reset owner's reserved output while its native rebuild is in flight.
        // The owner already cleared processing; its start refreshes real demand.
        if preservesResetAnalysisTopology, !ownedByCameraOperation { return }
        // A callback that cannot own this operation must not invalidate the
        // actual start/switch owner's in-flight analysis publication.
        analysisUpdateRevision &+= 1
        let updateRevision = analysisUpdateRevision, epoch = eligibilityEpoch
        let generationAtUpdate = capability.generation
        let admissionRevisionAtUpdate = runtimeAdmissionRevision
        let startSerialAtUpdate = startAttemptSerial
        let startAtUpdate = unfinishedStartAttempt
        let switchingAtUpdate = isSwitchingLens
        let resources = resourcePressureSnapshot
        func isCurrent() -> Bool {
            updateRevision == analysisUpdateRevision && epoch == eligibilityEpoch && resources == resourcePressureSnapshot
                && generationAtUpdate == capability.generation && admissionRevisionAtUpdate == runtimeAdmissionRevision
                && startSerialAtUpdate == startAttemptSerial && startAtUpdate == unfinishedStartAttempt
                && switchingAtUpdate == isSwitchingLens
        }
        let pressure = resources.analysisPressure(pendingOriginalCount: pendingOriginalCount)
        let reservingResetStart = preservesResetAnalysisTopology && ownedByCameraOperation
        let lifecycleState: PreviewLifecycleState = reservingResetStart ? .activeCameraView : analysisUnavailableReason.map {
            .analysisUnsupported(reason: $0)
        } ?? (isCameraEligibleForCapture && surface == .ready
              && (isPreviewConnectionStable || ownedByCameraOperation) ? .activeCameraView : .cameraNotRunning)
        let decision = AnalysisDemandPolicy.decide(
            configuration: aidConfiguration,
            lifecycle: lifecycleState,
            pressure: pressure,
            geometry: reservingResetStart ? nil : geometry)
        pausedAids = decision.pausedAids
        // The union demand gates the video output; the complete request carries
        // the user's thresholds and loupe settings through to the analyser.
        let unchangedNativeDemand = !ownedByCameraOperation && lastAppliedAnalysisDemand.map {
            $0.demand == decision.demand && $0.generation == generationAtUpdate && $0.eligibilityEpoch == epoch
        } == true
        // A loupe drag, threshold/geometry change or rate-only resource event
        // needs only a new processing request when the exact output demand was
        // acknowledged for this sensor and eligibility epoch. Owned start/switch
        // paths always visit the native boundary; they establish that proof.
        if !unchangedNativeDemand {
            // Once replacement native work starts, the older acknowledgement
            // cannot authorize another no-op: a quick toggle back must supersede
            // that in-flight detach/change instead of trusting its old cache.
            lastAppliedAnalysisDemand = nil
            await camera.setAnalysisDemand(decision.demand)
        }
        guard isCurrent() else { return }
        await camera.setAnalysisRequest(decision.request)
        guard isCurrent() else { return }
        await metering.setRateLimits(decision.rateLimits)
        guard isCurrent() else { return }
        // R03: the attach/detach may have REVOKED RAW support, so the model re-reads the
        // capability now in force rather than continuing to advertise the stale one.
        if !unchangedNativeDemand, let provider = camera as? any CameraCapabilityProviding,
           let current = await provider.currentCapability() {
            guard isCurrent(), current.generation == generationAtUpdate else { return }
            adoptCapability(current)
        }
        lastAppliedAnalysisDemand = (decision.demand, generationAtUpdate, epoch)
        resourcePressureNeedsReconciliation = false
    }

    var aidConfiguration: PreviewAidConfiguration {
        PreviewAidConfiguration(
            isHistogramEnabled: composition.histogramEnabled,
            isPeakingEnabled: composition.peakingEnabled,
            peakingThreshold: composition.peakingThreshold,
            isZebrasEnabled: composition.zebrasEnabled,
            zebraThreshold: composition.zebraThreshold,
            isLoupeEnabled: composition.loupeEnabled,
            loupeMagnification: composition.loupeMagnification,
            loupeCenter: composition.loupeCenter)
    }

    private func startAnalysisConsumption() {
        // One consumer owns this stream. Retain the model only for a delivered
        // update, never across an indefinite wait for the next frame.
        let metering = self.metering
        analysisTask = Task { [weak self, metering] in
            for await output in metering.output {
                guard !Task.isCancelled, let self else { return }
                await self.consumeAnalysisOutput(output)
            }
        }
    }

    func consumeAnalysisOutput(_ output: AnalysisOutput) async {
        switch output {
        case .geometryChanged(let geometry):
            guard isPreviewConnectionStable, geometry.configurationGeneration == capability.generation else { return }
            self.geometry = geometry
        case .histogram(let snapshot):
            guard isPreviewConnectionStable, snapshot.configurationGeneration == capability.generation,
                  snapshot.geometryGeneration == geometry?.layoutGeneration else { return }
            histogram = snapshot
        case .masks(let snapshot):
            guard isPreviewConnectionStable, snapshot.configurationGeneration == capability.generation,
                  snapshot.geometryGeneration == geometry?.layoutGeneration else { return }
            masks = snapshot
        case .loupe(let snapshot):
            guard isPreviewConnectionStable, snapshot.configurationGeneration == capability.generation,
                  snapshot.geometryGeneration == geometry?.layoutGeneration else { return }
            if let center = snapshot.sampledCenter {
                guard composition.loupeEnabled, center == composition.loupeCenter,
                      snapshot.magnification == LoupeRenderer.effectiveMagnification(composition.loupeMagnification) else { return }
            }
            loupe = snapshot
        case .analysisUnavailable(let reason):
            guard isPreviewConnectionStable else { return }
            if analysisUnavailableReason != reason { AppDiagnostics.record(reason, operation: "camera.previewTools") }
            analysisUnavailableReason = reason
            // This disclosure can arrive before the typed lifecycle stream.
            // It pauses processing but is never permission to detach a graph
            // that the separate reset owner may already be rebuilding.
            if reason == MediaServicesResetSignal.analysisUnavailableReason { return }
            await updateAnalysisDemand()
        }
    }

    // MARK: Preferences

    private func persistComposition() {
        preferences.storeCompositionPreferences(composition)
    }

    private func report(_ failure: CaptureFailure) {
        #if DEBUG
        print("TruongCam failure: \(failure)")
        #endif
        lastFailure = UserFacingFailure.from(failure)
    }

    private(set) var lastFailure: UserFacingFailure?
    private var controlFailure: UserFacingFailure?

    /// Re-runs capability discovery for the diagnostics route. Ordinary launch
    /// does not shoot hidden self-test RAWs; this only re-reads advertised facts.
    func refreshCapabilityForDiagnostics() async {
        if let snapshot = try? await camera.prepare(desiredCamera: composition.preferredLens).get() {
            capability = snapshot
        }
    }

    func clearLastFailure() {
        lastFailure = nil
    }

    // MARK: Preview bridge

    /// Display-only session access. The preview layer may render this session but
    /// must never configure it.
    /// Display-only bridge for the preview layer, published by the camera
    /// service through a real async hop (REVIEW.md C02).
    private(set) var displayBridge: PreviewDisplayBridge?

    /// Fetches and caches the display bridge. Called once when the camera starts.
    func loadDisplayBridge() async {
        displayBridge = await camera.previewDisplayBridge()
    }

    var previewSessionBox: PreviewSessionBox? {
        displayBridge?.displayBox
    }

    private var fallbackContentRect = TCRect(x: 0, y: 0, width: 1, height: 1)

    func setPreviewContentRect(_ rect: TCRect) {
        fallbackContentRect = rect
    }

    /// The coordinate mapper for focus taps and overlay alignment.
    func previewGeometryMapper(fallbackContentRect: TCRect) -> PreviewGeometryMapper {
        let rect = geometry?.previewLayerContentRect ?? fallbackContentRect
        return PreviewGeometryMapper(
            imageDimensions: geometry?.imageDimensions
                ?? PixelDimensions(width: 4, height: 3),
            contentRect: rect,
            isMirrored: geometry?.isMirrored ?? false,
            rotationDegrees: geometry?.analysisRotationDegrees ?? 0,
            bufferOrientation: geometry?.bufferOrientation ?? 1)
    }

    // MARK: Composition aids

    func cycleGrid() {
        let modes = GridMode.allCases
        let index = modes.firstIndex(of: composition.gridMode) ?? 0
        composition.gridMode = modes[(index + 1) % modes.count]
    }

    /// Gravity reading for the level overlay. Supplied by the level service; the
    /// overlay draws whatever the current reading is and never fakes one.
    var levelGravity: GravityReading? { currentGravity }
    private var currentGravity: GravityReading?

    /// Starts the real motion feed while the level is enabled and the scene is
    /// active. REVIEW.md C08/C09: nothing fed this before, and nothing stopped it
    /// when the level was hidden or the app went inactive.
    func startLevelFeed() {
        guard composition.levelEnabled else {
            stopLevelFeed()
            return
        }
        levelService.setVisible(true)
        levelService.setSceneActive(true)
        levelFeed.start { [weak self] sample in
            guard let self else { return }
            Task { await self.consumeGravity(sample) }
        }
    }

    func stopLevelFeed() {
        levelFeed.stop()
        levelService.setVisible(false)
        levelService.setSceneActive(false)
        levelState = nil
    }

    private func consumeGravity(_ sample: DeviceGravitySample) async {
        guard composition.levelEnabled else { return }
        let gravity = GravityReading(x: sample.x, y: sample.y, z: sample.z)
        currentGravity = gravity
        levelState = levelService.update(gravity: gravity)
    }

    /// Test seam: injects a gravity reading without a sensor.
    func updateLevel(gravity: GravityReading?) async {
        currentGravity = gravity
        guard composition.levelEnabled, let gravity else {
            levelState = nil
            return
        }
        levelState = levelService.update(gravity: gravity)
    }

    func setLevelOrientation(_ orientation: DeviceOrientation) {
        levelService.setOrientation(orientation)
        if let currentGravity { levelState = levelService.update(gravity: currentGravity) }
    }

    private var levelService = LevelService()
    /// Real sensor feed; a fake is injected in tests.
    /// AL01: injected rather than defaulted, so the model compiles without the
    /// CoreMotion-backed feed; the App layer supplies `CoreMotionLevelFeed()`.
    @ObservationIgnored private var levelFeed: any DeviceMotionLevelFeeding
    private(set) var levelState: LevelState?

    func setLevelVisible(_ visible: Bool) async {
        levelService.setVisible(visible)
        if visible {
            startLevelFeed()
        } else {
            stopLevelFeed()
        }
        levelState = visible ? levelService.state : nil
        await updateAnalysisDemand()
    }

    /// Replaces the motion feed. Used by tests to drive the level deterministically.
    func installLevelFeed(_ feed: any DeviceMotionLevelFeeding) {
        levelFeed.stop()
        levelFeed = feed
        if composition.levelEnabled { startLevelFeed() }
    }

    // MARK: Shutter admission

    /// The shutter is enabled only when every admission condition holds.
    var isShutterEnabled: Bool { !isContinuousCaptureActive && singleShutterAdmissionReady }
    private var singleShutterAdmissionReady: Bool {
        if activeShutterMode == .focusBracket, !isManualFocusAvailable { return false }
        guard !isCaptureBusy, !isSwitchingLens, runtimeAdmissionReady else { return false }
        // The display owner must bind this camera's real connection before a
        // capture can freeze its angle. Synthetic/no-display services have no
        // view geometry obligation; physical capture does.
        if previewSessionBox != nil, geometry?.configurationGeneration != capability.generation { return false }
        if surface != .ready { return false }
        switch currentRootState {
        case .writable: break
        default: return false
        }
        if pendingOriginalCount > 0 { return false }
        // An ineligible scene OR a covered camera screen must not admit a capture.
        // These are separate conditions: the app can be foreground with the library
        // open, which is not the same as being backgrounded (REVIEW.md F02).
        guard isCameraEligibleForCapture else { return false }
        // Only a genuinely RUNNING sequence blocks the shutter. A finished
        // sequence keeps its status text for display but must not block ordinary
        // capture (REVIEW.md S14).
        if isSequenceRunning { return false }
        if sequenceBlockedByRestorationFailure != nil { return false }
        if timerCountdownSeconds != nil { return false }
        return capture.blockReason(for: readinessInputs) == nil
    }

    // MARK: Timer

    var timerSeconds: Int? {
        composition.timerSeconds > 0 ? composition.timerSeconds : nil
    }

    var timerBadgeText: String? {
        if let countdown = timerCountdownSeconds { return "Timer \(countdown)s" }
        guard composition.timerSeconds > 0 else { return nil }
        return "Timer \(composition.timerSeconds)s"
    }

    func setTimerSeconds(_ seconds: Int) {
        if seconds > 0 { stopContinuousCapture(); captureSpeed = .single; preferences.storeCaptureSpeed(.single) }
        composition.timerSeconds = max(0, seconds)
    }

    /// Starts the camera only when it is not already running or preparing.
    ///
    /// REVIEW.md S03: the view could call `start()` more than once (its task, a
    /// graph attach, and a scene reactivation), which would rebuild the session.
    /// This is the single idempotent entry point the UI uses.
    func startIfNeeded() async {
        guard !isSwitchingLens, !isRepairingTransientCamera,
              unfinishedStartAttempt == nil || unfinishedStartEpoch != eligibilityEpoch else { return }
        if preservesResetAnalysisTopology, serviceRecordedCondition != .reconfiguring { return }
        if Self.canRepairTransientCondition(serviceRecordedCondition) {
            await repairTransientCamera()
            return
        }
        switch effectiveLifecycle {
        case .running, .configuring, .reconfiguring, .requestingPermission, .stopping:
            return
        case .idle, .interrupted, .unavailable, .failed:
            break
        }
        await start()
    }

    private static func canRepairTransientCondition(_ condition: CameraLifecycle?) -> Bool {
        guard case .failed(let kind) = condition else { return false }
        switch kind {
        case .cameraInterrupted(let detail): return !MediaServicesResetSignal.matches(detail: detail)
        case .captureFailed, .operationStalled: return true
        default: return false
        }
    }

    /// Reconcile an authoritative failed native service with a cached running
    /// model. Stop preserves submitted sources; prepare/start keep all native
    /// drain/final-tuple/control fences. No request or pending original is reset.
    private func repairTransientCamera() async {
        guard isCameraEligibleForCapture, unfinishedStartAttempt == nil, !isSwitchingLens,
              !isCaptureBusy, !isRepairingTransientCamera, !preservesResetAnalysisTopology else { return }
        isRepairingTransientCamera = true
        automaticRecoveryAttempted = true
        let epoch = eligibilityEpoch, reservation = resetAnalysisTopologyReservation
        lifecycle = .reconfiguring; surface = .preparing
        pendingHardwareLens = nil; hardwareLensOwner = nil
        finishPreviewTransition()
        defer {
            isRepairingTransientCamera = false
            if epoch != eligibilityEpoch, isCameraEligibleForCapture {
                lifecycle = .idle
                Task { [weak self] in await self?.startIfNeeded() }
            } else if lifecycle == .reconfiguring, isCameraEligibleForCapture {
                let detail = "The camera could not recover yet. Retry when it is available."
                lifecycle = .failed(.cameraInterrupted(detail: detail))
                surface = .cameraUnavailable(detail: detail)
            }
        }
        await closeRuntimeAdmission()
        guard epoch == eligibilityEpoch, isCameraEligibleForCapture else { return }
        if let recovery = camera as? any CameraRecoveryStopping {
            if case .failure(let failure) = await recovery.stopForTransientRecovery() {
                guard epoch == eligibilityEpoch, isCameraEligibleForCapture else { return }
                lifecycle = .failed(failure.kind)
                surface = .cameraUnavailable(detail: failure.kind.userDescription)
                report(failure)
                return
            }
        } else { await camera.stop() }
        guard epoch == eligibilityEpoch, isCameraEligibleForCapture,
              reservation == resetAnalysisTopologyReservation else { return }
        let revision = serviceConditionRevision
        let stopped = await camera.recordedSessionCondition()
        guard epoch == eligibilityEpoch, isCameraEligibleForCapture,
              revision == serviceConditionRevision, reservation == resetAnalysisTopologyReservation else { return }
        guard stopped == .idle || stopped == .stopping else {
            AppDiagnostics.record(stopped.displayLabel, operation: "camera.recoveryStop")
            lifecycle = stopped
            surface = .cameraUnavailable(detail: stopped.displayLabel)
            return
        }
        // This is a fresh post-stop condition, not a blanket failure clear.
        serviceConditionRevision &+= 1
        serviceRecordedCondition = stopped
        lifecycle = .idle
        await start()
        if runtimeAdmissionReady, effectiveLifecycle == .running, !controlRestorationFailed {
            lastFailure = nil; lastNotice = nil
        }
    }

    /// Opens the system Settings page for this app so a denied camera grant has a
    /// real recovery route (REVIEW.md S03).
    func openSystemSettings() {
        guard let openSettingsPage else {
            // No route is installed (or the platform refused to open it). The user
            // still gets exact instructions rather than a dead button.
            lastNotice = "Open Settings, then Privacy & Security > Camera, and allow TruongCam."
            return
        }
        openSettingsPage()
    }

    /// Installed by the view so the view model never imports UIKit directly and
    /// remains testable off-device.
    var openSettingsPage: (() -> Void)?

    /// Re-evaluates camera access after the app returns to the foreground, so a
    /// grant made in Settings takes effect without a relaunch.
    func reevaluatePermissionAfterSettings() async {
        guard lastFailure?.origin == FailureKind.permissionDenied(domain: "").stableCode else { return }
        await startIfNeeded()
    }

    /// Starts the countdown as an owned, cancellable task with a monotonic
    /// deadline.
    ///
    /// REVIEW.md C09: the countdown used to be a local `while` loop with a
    /// `Task.sleep` and `cancelTimer()` only cleared the displayed integer, so it
    /// neither stopped the loop nor prevented the eventual capture. The deadline is
    /// monotonic (immune to wall-clock changes), the task is retained, and the
    /// countdown is re-checked against the scene before anything is submitted.
    func startTimerCountdown(seconds: Int) {
        guard seconds > 0, !isCapturing else { return }
        timerTask?.cancel()
        let deadline = clock.now() + Double(seconds)
        timerDeadline = deadline
        timerCountdownSeconds = seconds
        timerTask = Task { [weak self] in
            guard let self else { return }
            while true {
                if Task.isCancelled {
                    self.timerCountdownSeconds = nil
                    self.timerDeadline = nil
                    return
                }
                let remaining = deadline - self.clock.now()
                if remaining <= 0 { break }
                self.timerCountdownSeconds = max(1, Int(remaining.rounded(.up)))
                // Poll the monotonic clock rather than counting fixed ticks, so a
                // suspended process cannot shorten or extend the deadline.
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
            self.timerCountdownSeconds = nil
            self.timerDeadline = nil
            self.timerTask = nil

            // Re-check the scene and readiness at submission time. Backgrounding
            // before submission means zero frames.
            guard self.isSceneActive else {
                self.lastNotice = "The timer was cancelled because the app is no longer active."
                return
            }
            guard self.isShutterEnabled else {
                self.lastNotice = "The timer expired but the camera is not ready to capture."
                return
            }
            await self.captureConfiguredMode()
        }
    }

    /// Cancels a running countdown. Nothing has been submitted yet, so this
    /// produces zero frames — unlike the previous implementation, which only
    /// cleared the displayed value.
    func cancelTimer() {
        timerTask?.cancel()
        timerTask = nil
        timerCountdownSeconds = nil
        timerDeadline = nil
    }

    var isTimerRunning: Bool { timerTask != nil }

    // MARK: Scene lifecycle

    /// Called when the scene becomes inactive or enters the background.
    ///
    /// Stops new acquisitions and interrupts any countdown, while preserving the
    /// current process's manual settings. Sources already submitted keep draining
    /// to storage through the capture and sequence pipelines.
    func handleSceneBecameInactive() async {
        stopContinuousCapture()
        // I03: only a REAL change invalidates in-flight work. Repeating an identical
        // transition must be idempotent, or a duplicate reveal kills the startup that is
        // already running. The assignment is unconditional (the body below still runs);
        // only the invalidation is conditional.
        if isSceneActive != false { eligibilityEpoch += 1; automaticRecoveryAttempted = false }
        isSceneActive = false
        resetAnalysisTopologyReservation = nil
        // REVIEW.md F02: an ineligible scene must stop the SENSOR too, not just the
        // readback and motion producers. Already-submitted sources keep draining
        // through the capture/sequence pipelines.
        cancelTimer()
        suspendRuntimeWork()
        await sequenceCoordinator?.interrupt(reason: .background)
        await stopCameraForIneligibleScene()
    }

    /// The camera screen is covered (for example the library is open).
    ///
    /// Distinct from scene inactivity: the app is still foreground, but the camera
    /// surface is not visible, so it is not eligible to capture.
    func handleCameraScreenCovered() async {
        stopContinuousCapture()
        // I03: only a REAL change invalidates in-flight work. Repeating an identical
        // transition must be idempotent, or a duplicate reveal kills the startup that is
        // already running. The assignment is unconditional (the body below still runs);
        // only the invalidation is conditional.
        if isCameraScreenEligible != false { eligibilityEpoch += 1; automaticRecoveryAttempted = false }
        isCameraScreenEligible = false
        resetAnalysisTopologyReservation = nil
        cancelTimer()
        suspendRuntimeWork()
        await sequenceCoordinator?.interrupt(reason: .screenIneligible)
        await stopCameraForIneligibleScene()
    }

    /// The camera screen is visible again.
    func handleCameraScreenRevealed() async {
        // I03: only a REAL change invalidates in-flight work. Repeating an identical
        // transition must be idempotent, or a duplicate reveal kills the startup that is
        // already running. The assignment is unconditional (the body below still runs);
        // only the invalidation is conditional.
        if isCameraScreenEligible != true { eligibilityEpoch += 1 }
        isCameraScreenEligible = true
        guard isSceneActive else { return }
        await startIfNeeded()
        // M03: the camera is eligible again and running, so new captures are admitted.
        if case .running = lifecycle { await resumeRuntimeAdmission() }
        startReadbackObservation()
        startLevelFeed()
        startSessionConditionObservation()
        await updateAnalysisDemand()
    }

    /// Completes a recovery by starting the rebuilt graph, only when eligible.
    ///
    /// L03: this is deliberately NOT `startIfNeeded`, whose guard refuses
    /// `.reconfiguring`. Success is decided from THIS operation's result, never from an
    /// unrelated global failure.
    private var isCompletingRecoveryStart = false
    private func completeRecoveryStart() async {
        guard !isSwitchingLens, unfinishedStartAttempt == nil, !isCompletingRecoveryStart,
              serviceRecordedCondition == .reconfiguring else { return }
        isCompletingRecoveryStart = true
        let resetReservation = resetAnalysisTopologyReservation
        defer {
            isCompletingRecoveryStart = false
            if resourcePressureNeedsReconciliation {
                Task { [weak self] in await self?.reconcileResourcePressureIfNeeded() }
            }
            // A newer reset may have reached its verified rebuild while this
            // older start was still draining. Reconcile that owner once, after
            // releasing this start; do not turn an unchanged failure into a loop.
            if resetAnalysisTopologyReservation != resetReservation,
               resetAnalysisTopologyReservation != nil,
               serviceRecordedCondition == .reconfiguring, isCameraEligibleForCapture {
                Task { [weak self] in await self?.completeRecoveryStart() }
            }
        }
        guard isCameraEligibleForCapture else {
            // Ineligible: do not run the sensor behind a covered screen or background.
            lifecycle = .idle
            surface = .ready
            return
        }
        // `start()` refuses `.running`/`.configuring`/`.reconfiguring` (its own re-entry
        // guard), so the recovery clears the cached state before asking it to run. The
        // cache is NOT trusted here: the sensor may have been stopped natively while the
        // model still believed it was running.
        if case .running = serviceRecordedCondition { return }
        lifecycle = .idle
        controlRestorationFailed = false
        await start()
        guard resetAnalysisTopologyReservation == resetReservation else { return }
        if case .running = lifecycle, !controlRestorationFailed,
           serviceRecordedCondition == nil || serviceRecordedCondition == .running || serviceRecordedCondition == .reconfiguring {
            lastFailure = nil
            lastNotice = nil
            // M03: the stale service condition is cleared from THIS operation's own
            // result. Leaving `.reconfiguring` in place kept `effectiveLifecycle`
            // reporting a block even though the sensor had started.
            serviceRecordedCondition = .running
            if let resetReservation, resetReservation.eligibilityEpoch == eligibilityEpoch,
               resetAnalysisTopologyReservation == resetReservation, isCameraEligibleForCapture {
                resetAnalysisTopologyReservation = nil
                // A genuine unsupported-format result is not transient and
                // survives recovery. Clear only the shared reset disclosure.
                if analysisUnavailableReason == MediaServicesResetSignal.analysisUnavailableReason {
                    analysisUnavailableReason = nil
                }
                await updateAnalysisDemand()
            }
            // The service recovery has completed its bounded drain and verified rebuild.
            await capture.resumeAdmittingNewRequests()
            await resumeRuntimeAdmission()
        } else if controlRestorationFailed {
            resetAnalysisTopologyReservation = nil
            // The controls could not be restored, so the failure stays actionable and
            // admission remains closed.
            lastNotice = "Reset camera settings to Auto to continue."
            lifecycle = .failed(.cameraInterrupted(
                detail: "The camera was rebuilt but its controls could not be restored."))
            serviceRecordedCondition = .failed(.cameraInterrupted(
                detail: "The camera was rebuilt but its controls could not be restored."))
            await updateAnalysisDemand()
        } else {
            lastNotice = "The camera couldn’t restart. Please try again."
        }
    }

    /// Stops the sensor when no surface is eligible to use it.
    private func stopCameraForIneligibleScene() async {
        // M03: an ineligible scene or a covered screen must close NEW capture admission,
        // not just stop the sensor. Already-submitted work keeps draining.
        guard !isCameraEligibleForCapture else { return }
        finishPreviewTransition()
        let stopEpoch = eligibilityEpoch
        await closeRuntimeAdmission()
        guard stopEpoch == eligibilityEpoch, !isCameraEligibleForCapture else { return }
        lifecycle = .stopping
        await camera.stop()
        guard stopEpoch == eligibilityEpoch, !isCameraEligibleForCapture else { return }
        lifecycle = .idle
        surface = .ready
    }

    /// True while the camera screen is the visible surface.
    private(set) var isCameraScreenEligible = true

    /// Guards the single awaited retry after a stale attempt aborts, so the retry cannot
    /// recurse indefinitely while eligibility keeps changing (REVIEW.md L03).
    private var isRetryingAfterStaleAbort = false

    /// Set when the most recent start could not apply the in-process controls.
    ///
    /// N02: a sensor that started is NOT a camera whose controls were restored. The
    /// recovery owner reads this so a control failure stays actionable and admission
    /// stays closed instead of being cleared by a successful sensor start.
    private var controlRestorationFailed = false

    /// Bumped whenever eligibility changes, so work authorized under an older
    /// eligibility can be recognized as stale after its awaits (REVIEW.md H02).
    private var eligibilityEpoch = 0

    /// Identity of this installed owner. A late/replaced model replays eligibility;
    /// changing lenses on the same owner must not replay scene/screen startup.
    var graphIdentity: ObjectIdentifier { ObjectIdentifier(self) }

    /// Both scene AND screen must be eligible for a capture.
    var isCameraEligibleForCapture: Bool { isSceneActive && isCameraScreenEligible }

    /// Called when the scene returns to the foreground. Camera, analysis and
    /// motion are restarted; an interrupted sequence is NOT auto-resumed, and
    /// manual settings are untouched.
    func handleSceneBecameActive() async {
        // I03: only a REAL change invalidates in-flight work. Repeating an identical
        // transition must be idempotent, or a duplicate reveal kills the startup that is
        // already running. The assignment is unconditional (the body below still runs);
        // only the invalidation is conditional.
        if isSceneActive != true { eligibilityEpoch += 1 }
        isSceneActive = true
        // REVIEW.md G02: returning to the foreground must not restart the sensor while
        // the camera screen is covered (for example the library is open). Producer
        // ownership belongs to the COMBINED eligibility.
        guard isCameraEligibleForCapture else {
            await stopCameraForIneligibleScene()
            return
        }
        await startIfNeeded()
        startReadbackObservation()
        startLevelFeed()
        startSessionConditionObservation()
        await updateAnalysisDemand()
        // O02: an eligible, running foreground camera reopens admission. The reveal path
        // already did this; the scene-active path did not, so a background→active cycle
        // left an eligible camera permanently unable to capture.
        if case .running = lifecycle, isCameraEligibleForCapture {
            await resumeRuntimeAdmission()
        }
    }

    /// Stops the sensor and analysis work that must not run while inactive.
    private func suspendRuntimeWork() {
        stopReadbackObservation()
        stopLevelFeed()
        // The stopped sensor produces no analysis frames. Keep its topology intact:
        // detached fire-and-forget work could otherwise arrive AFTER the next reveal,
        // invalidate that start and force another expensive format discovery.
    }

    // MARK: Recovery

    /// Requests a sequence. The plan is validated before anything is submitted;
    /// an invalid plan is reported instead of being silently clamped.
    private(set) var queuedSequenceRequest: SequenceRequest?
    func launchQueuedSequence() {
        guard let request = queuedSequenceRequest else { return }
        queuedSequenceRequest = nil
        guard isCameraEligibleForCapture else { return }
        requestSequence(request)
    }
    func requestSequence(_ request: SequenceRequest) {
        guard isSequenceCaptureAvailable else {
            lastNotice = "Choose RAW to take a series of photos."
            isToolsSheetPresented = false
            return
        }
        if isToolsSheetPresented {
            queuedSequenceRequest = request
            isToolsSheetPresented = false
            return
        }
        guard !isContinuousCaptureActive, !isExecutingSequence, sequenceTask == nil else { return }
        guard let sequenceCoordinator else {
            AppDiagnostics.record("No sequence coordinator installed for \(request.displayName)", operation: "camera.sequence")
            lastFailure = UserFacingFailure(
                title: "Sequence unavailable",
                detail: "This shooting mode isn’t available right now. Please try again.",
                actions: [.dismiss])
            return
        }
        _ = sequenceCoordinator
        guard case .writable(let libraryID, let rootGeneration) = currentRootState,
              let kind = capability.selectedCameraKind else {
            lastFailure = UserFacingFailure(
                title: "Sequence unavailable",
                detail: "Reconnect your library folder before taking a series of photos.",
                actions: [.reconnect, .dismiss])
            return
        }

        // Plan values come from the user's stored settings; the coordinator still
        // validates every duration and count before anything is submitted.
        let prefs = sequencePreferences.validated()
        let specification: SequenceSpecification
        let planKind: SequencePlanKind
        switch request {
        case .exposureBracket:
            specification = .exposureBracket(ExposureBracketPlan(
                count: prefs.exposureBracketCount,
                stepEV: prefs.exposureBracketStepEV,
                // Native brackets stay gated until a device test records a
                // measured count; until then the labelled serial path is used.
                path: .serial))
            planKind = .exposureBracket
        case .focusBracket:
            specification = .focusBracket(FocusBracketPlan(
                count: prefs.focusBracketCount,
                startPosition: prefs.focusBracketStart,
                endPosition: prefs.focusBracketEnd))
            planKind = .focusBracket
        case .interval:
            specification = .interval(IntervalPlan(
                count: prefs.intervalCount,
                intervalSeconds: prefs.intervalSeconds))
            planKind = .interval
        }

        let plan = SequencePlan(
            libraryID: libraryID,
            configurationGeneration: capability.generation,
            rootGeneration: rootGeneration,
            physicalCameraKind: kind,
            kind: planKind,
            specification: specification,
            createdAtUTC: Date(),
            nominalEquivalentFocalLengthMM: capability.camera(kind)?.validNominalEquivalentFocalLengthMM)
        activeSequenceID = plan.sequenceID
        startSequence(plan)
    }

    func cancelSequence() {
        cancelSequenceNow()
    }

    /// Returns exposure, focus and white balance to Auto. Offered after a
    /// restoration failure; shutter stays blocked until this succeeds.
    /// Moves the loupe's inspection centre from a tap or drag in the preview.
    ///
    /// REVIEW.md S07: the loupe centre was hardcoded, so the required centre
    /// interaction was missing. The point is the user's intent (a normalized
    /// position), not a measured device value, so it is clamped into the frame and
    /// triggers one coherent analysis request.
    func setLoupeCenter(_ point: NormalizedDevicePoint) {
        guard point.isFinite else { return }
        let clamped = NormalizedDevicePoint(
            x: min(max(point.x, 0), 1),
            y: min(max(point.y, 0), 1))
        guard clamped != composition.loupeCenter else { return }
        composition.loupeCenter = clamped
        // Display inspection never changes native capture controls or settlement.
        Task { await updateAnalysisDemand() }
    }

    /// The loupe centre clamped for display, or nil when the loupe is off.
    var activeLoupeCenter: NormalizedDevicePoint? {
        composition.loupeEnabled ? composition.loupeCenter : nil
    }

    func resetControlsToAuto() {
        guard !isCaptureBusy, !isSwitchingLens, unfinishedStartAttempt == nil,
              isCameraEligibleForCapture, isPreviewConnectionStable else { return }
        // The visible recovery action owns the same strict reset used by the
        // coordinator. Merely clearing the view's block leaves its restoration
        // latch set and makes every later sequence fail again.
        isResettingControls = true
        let epoch = eligibilityEpoch, generation = capability.generation
        controlsResetTask = Task { [weak self] in
            guard let self else { return }
            defer {
                self.isResettingControls = false
                self.controlsResetTask = nil
                if self.resourcePressureNeedsReconciliation {
                    Task { [weak self] in await self?.reconcileResourcePressureIfNeeded() }
                }
            }
            await self.drainInteractiveControlApplication()
            guard !Task.isCancelled, epoch == self.eligibilityEpoch,
                  generation == self.capability.generation, self.isCameraEligibleForCapture,
                  self.isPreviewConnectionStable else { return }
            let result: Result<Void, CaptureFailure>
            if let coordinator = self.sequenceCoordinator {
                result = await coordinator.resetToAuto()
            } else {
                result = await self.resetSequenceSettingsToAuto()
            }
            guard !Task.isCancelled, epoch == self.eligibilityEpoch,
                  generation == self.capability.generation, self.isCameraEligibleForCapture,
                  self.isPreviewConnectionStable else { return }
            switch result {
            case .success:
                self.sequenceBlockedByRestorationFailure = nil
                self.sequenceStatusLine = nil
                if self.lastFailure?.actions.contains(.resetToAuto) == true { self.lastFailure = nil }
            case .failure(let failure):
                let detail = "The camera controls could not be reset. \(failure.kind.userDescription)"
                self.sequenceBlockedByRestorationFailure = detail
                AppDiagnostics.record(failure, operation: "camera.resetSettings")
                self.lastFailure = UserFacingFailure(title: "Settings not reset", detail: "Try Reset to Auto again before taking another photo.",
                    actions: [.resetToAuto, .dismiss], origin: failure.kind.stableCode)
                self.lastNotice = "The camera controls could not be reset, so capture stays blocked until a successful reset."
            }
        }
    }
}

// MARK: - Sequences

/// A sequence request from the tools sheet. The coordinator validates the plan
/// before anything is submitted; an invalid plan is reported, never silently
/// clamped.
enum SequenceRequest: String, Hashable, Sendable, CaseIterable {
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

// MARK: - Sequence integration (P8/P9)

extension CameraViewModel: CameraViewModelCapabilitySource {
    func capabilitySnapshotForSequences() async -> CameraCapabilitySnapshot {
        // R03: planning must use the capability CURRENTLY in force, not the model's cached
        // value copy — a topology change may have revoked RAW support since it was adopted.
        if let provider = camera as? any CameraCapabilityProviding,
           let current = await provider.currentCapability() {
            adoptCapability(current)
            return current
        }
        return capability
    }
}

extension CameraViewModel: CameraSequenceSettingsSurface {
    func sequenceSettingsSnapshot() async -> SequenceSettingsSnapshot? {
        guard let format = activeFormat else { return nil }
        // A sequence must not plan against an invented ceiling; without an
        // advertised maximum there is nothing honest to snapshot (REVIEW.md R05).
        guard let dimensions = format.supportedMaxPhotoDimensions.max(by: {
            $0.pixelCount < $1.pixelCount
        }) else {
            return nil
        }
        return SequenceSettingsSnapshot(
            configurationGeneration: capability.generation,
            revision: controlRevision,
            exposure: exposure,
            biasEV: biasEV,
            focus: focus,
            whiteBalance: whiteBalance,
            maxDimensions: dimensions, aperture: aperture)
    }

    /// The last settled exposure baseline. Reported only when the device has
    /// produced real observed values; otherwise the coordinator must settle.
    func sequenceExposureBaseline() async -> ExposureBaseline? {
        await refreshReadback()
        guard let snapshot = applied else { return nil }
        // H01: a MOVING or unmeasured reading cannot supply a settled baseline, and a
        // reading from an older configuration is not relevant to this one. Returning
        // nil here makes the caller settle for real rather than plan against a cached
        // value that the device never confirmed.
        guard snapshot.generation == capability.generation else { return nil }
        guard snapshot.settlement.isSettled else { return nil }
        guard let duration = snapshot.observedDurationSeconds,
              let iso = snapshot.observedISO,
              duration.isFinite, duration > 0, iso.isFinite, iso > 0 else { return nil }
        return ExposureBaseline(
            durationSeconds: duration,
            iso: iso,
            biasEV: snapshot.biasEV,
            // Only a converged reading may claim this provenance.
            provenance: BaselineReadback.provenance(for: snapshot.settlement), aperture: snapshot.lensAperture)
    }

    func applySequenceSettings(_ settings: SequenceSettingsSnapshot) async -> Result<Void, CaptureFailure> {
        let expectedGeneration = await capabilitySnapshotForSequences().generation
        exposure = settings.exposure
        aperture = settings.aperture
        biasEV = settings.biasEV
        focus = settings.focus
        whiteBalance = settings.whiteBalance
        controlRevision += 1
        let revision = controlRevision
        let result = await camera.applyControls(
            revision: revision, exposure: settings.exposure, biasEV: settings.biasEV,
            focus: settings.focus, whiteBalance: settings.whiteBalance, aperture: settings.aperture)
        switch result {
        case .success(let acknowledgement):
            let deadline = clock.now() + max(5, 2 * (settings.exposure.durationTargetSeconds ?? 0) + 1)
            var reading: AppliedControlSnapshot? = acknowledgement
            while true {
                // A later control application or graph owns its own state. Do not relabel it
                // or borrow its settled readings to certify this restoration.
                let currentGeneration = await capabilitySnapshotForSequences().generation
                guard revision == controlRevision, currentGeneration == expectedGeneration else {
                    return .failure(CaptureFailure(kind: .restorationFailed(detail: "Settings restoration was superseded by a newer camera operation."), operation: "sequence.verifySettings"))
                }
                if let reading, SequenceControlVerification.matches(
                    reading, settings: settings, generation: expectedGeneration, revision: revision,
                    whiteBalanceTarget: settings.whiteBalance.mode == .manual ? acknowledgement.resolvedWhiteBalanceTarget : nil) {
                    applyReadback(reading)
                    return .success(())
                }
                guard !Task.isCancelled, clock.now() < deadline else {
                    return .failure(CaptureFailure(kind: .restorationFailed(detail: "The requested sequence settings did not produce a matching settled readback."), operation: "sequence.verifySettings"))
                }
                try? await Task.sleep(nanoseconds: CaptureCoordinator.settlePollIntervalNanoseconds)
                reading = await camera.currentControlReadback()
            }
        case .failure(let failure):
            return .failure(failure)
        }
    }

    func restoreSequenceSettings(_ settings: SequenceSettingsSnapshot) async -> Result<Void, CaptureFailure> {
        await applySequenceSettings(settings)
    }

    func resetSequenceSettingsToAuto() async -> Result<Void, CaptureFailure> {
        // Reset-to-Auto still needs the real ceiling; it must not invent one.
        guard let dimensions = await sequenceSettingsSnapshot()?.maxDimensions else {
            return .failure(CaptureFailure(
                kind: .unsupportedCapability(
                    detail: "The active format did not advertise a maximum photo dimension, so sequence settings cannot be reset to a known size."),
                operation: "resetSequenceSettingsToAuto"))
        }
        let auto = SequenceSettingsSnapshot(
            configurationGeneration: capability.generation,
            revision: controlRevision + 1,
            exposure: .auto,
            biasEV: 0,
            focus: FocusIntent(mode: .continuousAuto, position: nil, pointOfInterest: nil),
            whiteBalance: WhiteBalanceIntent(mode: .auto, temperatureAndTint: nil),
            maxDimensions: dimensions, aperture: .auto)
        return await applySequenceSettings(auto)
    }

    func currentAppliedSnapshot() async -> AppliedControlSnapshot? {
        // Sequence settlement owns active sampling; it cannot depend on whether
        // an on-screen readout observer happens to be running behind a sheet.
        await refreshReadback()
        return applied
    }
}

extension CameraViewModel: FocusPositionControlling {
    func beginMove(to position: Double) async -> Result<Void, CaptureFailure> {
        let target = clampPosition(position)
        focus = FocusIntent(mode: .manual, position: target, pointOfInterest: nil)
        controlRevision += 1
        let result = await camera.applyControls(
            revision: controlRevision,
            exposure: exposure,
            biasEV: biasEV,
            focus: focus,
            whiteBalance: whiteBalance, aperture: aperture)
        switch result {
        case .success:
            return .success(())
        case .failure(let failure):
            return .failure(failure)
        }
    }

    func readback() async -> FocusSettleReadback? {
        let requestedPosition = focus.position
        guard let snapshot = await camera.currentControlReadback() else {
            return FocusSettleReadback(position: nil, state: .notStarted, provenance: .unknown)
        }
        let position = snapshot.focusPosition
        let state = FocusMoveSettlement.state(
            requestedPosition: requestedPosition,
            observedPosition: position,
            observedSettlement: snapshot.settlement,
            isManualFocus: focus.mode == .manual)
        return FocusSettleReadback(
            position: position,
            state: state,
            provenance: FocusMoveSettlement.provenance(for: state))
    }
}

extension CameraViewModel {
    /// Attaches the sequence coordinator. Until it is attached, a sequence
    /// request is reported as unavailable rather than silently ignored.
    func attach(sequence: SequenceCoordinator) {
        sequenceCoordinator = sequence
    }

    /// Runs a sequence and surfaces its progress. Individual sources are always
    /// retained; nothing is merged.
    func startSequence(_ plan: SequencePlan) {
        guard !isContinuousCaptureActive, sequenceTask == nil, !isExecutingSequence else { return }
        sequenceTask = Task { [weak self] in
            _ = await self?.executeSequence(plan)
        }
    }

    /// The awaited production run includes result presentation and downstream receipt ingestion.
    /// UI tasks and the connected verifier use this same path.
    func executeSequence(_ plan: SequencePlan) async -> SequenceRunResult? {
        guard !isContinuousCaptureActive, isSequenceCaptureAvailable, let sequenceCoordinator, !isCapturing, !isResettingControls, !isExecutingSequence,
              activeSequenceID == nil || activeSequenceID == plan.sequenceID else { return nil }
        isExecutingSequence = true
        sequenceAdmissionCancelled = false
        let sequenceEpoch = eligibilityEpoch
        defer {
            isExecutingSequence = false
            if resourcePressureNeedsReconciliation {
                Task { [weak self] in await self?.reconcileResourcePressureIfNeeded() }
            }
        }
        activeSequenceID = plan.sequenceID
        sequenceFrameOrdinal = 0
        sequencePlannedCount = plan.plannedSourceCount
        sequencePhase = .validating
        sequenceStatusLine = "\(plan.kind.displayName): starting"
        await drainInteractiveControlApplication()
        guard !Task.isCancelled, !sequenceAdmissionCancelled,
              sequenceEpoch == eligibilityEpoch, isCameraEligibleForCapture else {
            activeSequenceID = nil
            sequenceTask = nil
            sequenceStatusLine = sequenceAdmissionCancelled ? "\(plan.kind.displayName): cancelled before capture" : nil
            return nil
        }
        let observing = Task { [weak self] in
            while !Task.isCancelled {
                let snapshot = await sequenceCoordinator.snapshot()
                if let progress = snapshot.progress, progress.sequenceID == plan.sequenceID {
                    self?.sequencePhase = progress.phase
                }
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
        defer { observing.cancel() }
        let result = await sequenceCoordinator.start(plan)
        #if DEBUG
        print("TruongCam sequence result: kind=\(result.kind) status=\(result.status) committed=\(result.progress.committedCount) restoration=\(result.restoration) failure=\(result.failure?.kind.userDescription ?? "none")")
        #endif
        await finishSequence(result)
        return result
    }

    private func finishSequence(_ result: SequenceRunResult) async {
        sequenceTask = nil
        lastFinishedSequenceDocumentID = result.kind.documentKind == nil ? nil : result.sequenceID
        // The sequence is no longer active, whatever its outcome. The status text
        // remains for display only (REVIEW.md S14).
        activeSequenceID = nil

        // REVIEW.md F06: a sequence's verified commits are durable, but the derived
        // index and the pending-original list were never told about them, so new
        // sequence sources could be missing from the gallery until a rescan and the
        // recovery list could stay empty. Every verified receipt is ingested and the
        // pending count/state refreshed, exactly as the single-capture path does.
        let receipts = result.committedReceipts
        // A retained handle that produced no receipt is a source still pending in
        // durable staging, which is exactly what the recovery list must show.
        let pendingCount = result.retainedHandles.count
        updatePendingOriginalCount(pendingCount)
        switch result.status {
        case .complete:
            sequenceStatusLine = nil
        case .cancelled:
            sequenceStatusLine = "Stopped · \(result.progress.committedCount) saved"
        case .interrupted:
            sequenceStatusLine = "Interrupted · \(result.progress.committedCount) saved"
        case .failed:
            sequenceStatusLine = "Stopped · \(result.progress.committedCount) saved"
        case .running:
            sequenceStatusLine = "\(result.kind.displayName): still running"
        }
        if pendingCount > 0, result.status != .complete {
            sequenceStatusLine = (sequenceStatusLine ?? "") + " · \(pendingCount) waiting to save"
        }
        if result.restoration == .failed {
            // A typed, persistent block: the camera's controls are in an unknown
            // state, so ordinary capture stays refused until the user resets.
            var detail = "The camera settings could not be returned to their previous values, so the controls are in an unknown state. Reset to Auto to capture again."
            if let failure = result.failure { detail += " \(failure.kind.userDescription)" }
            sequenceBlockedByRestorationFailure = detail
            AppDiagnostics.record(detail, operation: "camera.sequenceRestoration")
            if let failure = result.failure { AppDiagnostics.record(failure, operation: "camera.sequenceAcquisition") }
            lastFailure = UserFacingFailure(
                title: "Settings not restored",
                detail: "Reset to Auto before taking another photo. Saved photos are available in the library.",
                actions: [.resetToAuto, .dismiss])
        } else {
            sequenceBlockedByRestorationFailure = nil
        }
        if result.restoration != .failed, let failure = result.failure {
            lastFailure = UserFacingFailure.from(failure)
        }
        if !receipts.isEmpty { await onCommittedReceipts?(receipts) }
        await onSequenceFinished?(pendingCount)
        // Publish verified sequence receipts after downstream reconciliation.
        if !receipts.isEmpty {
            lastCaptureWasExposureBracket = result.kind == .exposureBracket && result.status == .complete
                && result.restoration != .failed && result.failure == nil
            lastCommittedReceipts = receipts
        }
    }

    /// Cancels a running sequence. New requests stop; sources already delivered
    /// by a submitted native burst are still saved.
    func cancelSequenceNow() {
        sequenceAdmissionCancelled = true
        guard let sequenceCoordinator else {
            sequenceStatusLine = nil
            return
        }
        let id = activeSequenceID
        Task { await sequenceCoordinator.cancel(sequenceID: id ?? SequenceID()) }
        sequenceStatusLine = "Cancelling; already-captured sources are still saved"
    }
}

extension CameraViewModel {
    private var hardwareLensSafetyEligible: Bool {
        isCameraEligibleForCapture && presentedCameraSheet == nil && currentRootState.isWritable
            && unfinishedStartAttempt == nil && !isCaptureBusy && timerCountdownSeconds == nil
            && pendingOriginalCount == 0 && sequenceBlockedByRestorationFailure == nil && !controlRestorationFailed
    }
    private var ownsHardwareLensTransition: Bool {
        hardwareLensOwner?.interactionID == hardwareInteractionID && hardwareLensOwner?.epoch == eligibilityEpoch
            && (isSwitchingLens || isPreviewTransitionVisible)
    }
    private var currentHardwareObservation: AppliedControlSnapshot? {
        guard let reading = applied, reading.generation == capability.generation,
              reading.requestRevision == controlRevision, reading.settlement.isLiveObservation,
              Date().timeIntervalSince(reading.capturedAtUTC) >= 0,
              Date().timeIntervalSince(reading.capturedAtUTC) <= 1 else { return nil }
        return reading
    }
    func hardwareConfiguration(enabled: Bool) -> HardwareControlConfiguration {
        let generation = capability.generation
        let observation = currentHardwareObservation
        func numbers(_ kind: HardwareControlKind, _ title: String, _ symbol: String,
                     _ values: [Double], selected: Double?, observed: Double? = nil, automatic: Bool = true) -> HardwareControlSelection? {
            let values = values.filter { $0.isFinite }
            guard !values.isEmpty else { return nil }
            // Picker identity must survive Auto-to-Manual seeding. Base the
            // reset label on format support, not the currently selected values.
            let resetTitle = supportsAperture(aperture, exposureMode: .auto) ? "Auto both" : "Auto all"
            let automaticTitle: String
            switch kind {
            case .shutter: automaticTitle = supportsExposureMode(.isoPriority) ? "Auto" : resetTitle
            case .iso: automaticTitle = supportsExposureMode(.shutterPriority) ? "Auto" : resetTitle
            case .aperture: automaticTitle = supportsIndependentAutomatic(.aperture) ? "Auto" : "Auto all"
            default: automaticTitle = "Auto"
            }
            let options = (automatic ? [HardwareControlOption(title: automaticTitle, value: .automatic)] : []) + values.map { value in
                let label: String
                switch kind {
                case .shutter: label = ExposureFormatting.duration(value)
                case .iso: label = "ISO \(Int(value.rounded()))"
                case .aperture: label = ApertureFormatting.fNumber(value)
                case .focus: label = String(format: "Position %.2f", value)
                case .temperature: label = "\(Int(value)) K"
                case .tint: label = String(format: "Tint %+.0f", value)
                case .exposureBias: label = ExposureFormatting.bias(value)
                case .lenses: label = ""
                }
                return HardwareControlOption(title: label, value: .number(value))
            }
            let nearest = (selected ?? observed).flatMap { target in values.indices.min { abs(values[$0] - target) < abs(values[$1] - target) } }
            let index = nearest.map { $0 + (automatic ? 1 : 0) } ?? 0
            return HardwareControlSelection(domain: HardwareControlDomain(generation: generation,
                kind: kind, title: title, symbol: symbol, options: options), index: index,
                isAutomatic: automatic && selected == nil)
        }
        var selections: [HardwareControlSelection] = []
        switch openPanel {
        case nil:
            let kinds = PhysicalCameraKind.rearSelectionOrder.filter { capability.camera($0) != nil } + [.front]
            let options = kinds.map { kind in HardwareControlOption(title: kind == .front ? "Front" : (capability.camera(kind)?.lensDisplayLabel ?? kind.displayLabel), value: .lens(kind)) }
            if options.count > 1 {
                // The chooser owns a screen interaction, not a sensor setting.
                // Keep its identity while its own physical switches finish.
                let anchor = lastHardwareConfiguration.enabled
                    ? lastHardwareConfiguration.selections.first(where: { $0.domain.kind == .lenses })?.domain.generation : nil
                selections = [HardwareControlSelection(domain: HardwareControlDomain(generation: anchor ?? generation,
                    kind: .lenses, title: "Camera", symbol: "camera.rotate", options: options),
                    index: kinds.firstIndex(of: capability.selectedCameraKind ?? .wide) ?? 0)]
            }
        case .shutter:
            if exposureLimits.isValid, supportsExposureMode(.manual) || supportsExposureMode(.shutterPriority),
               let picker = numbers(.shutter, "Shutter", "timer", PhotographicExposureSteps.legal(PhotographicExposureSteps.durations,
                minimum: exposureLimits.minDurationSeconds, maximum: exposureLimits.maxDurationSeconds), selected: exposure.durationTargetSeconds,
                observed: observation?.observedDurationSeconds, automatic: canSetStripAutomatic(.shutter)) { selections = [picker] }
        case .iso:
            if exposureLimits.isValid, supportsExposureMode(.manual) || supportsExposureMode(.isoPriority),
               let picker = numbers(.iso, "ISO", "camera.aperture", PhotographicExposureSteps.legal(PhotographicExposureSteps.iso,
                minimum: exposureLimits.minISO, maximum: exposureLimits.maxISO), selected: exposure.isoTarget,
                observed: observation?.observedISO, automatic: canSetStripAutomatic(.iso)) { selections = [picker] }
        case .aperture:
            if canAdjustAperture, let picker = numbers(.aperture, "Aperture", "camera.aperture", apertureStops,
                selected: aperture.numericTarget, observed: observation?.lensAperture,
                automatic: canSetStripAutomatic(.aperture)) { selections = [picker] }
        case .focus:
            if isManualFocusAvailable, let picker = numbers(.focus, "Focus", "viewfinder", (0...50).map { Double($0) / 50 },
                selected: focus.mode == .manual ? focus.position : nil, observed: observation?.focusPosition) { selections = [picker] }
        case .whiteBalance:
            if isManualWhiteBalanceAvailable {
                let d = WhiteBalanceSliderDomain.productPolicy
                selections = [numbers(.temperature, "Temperature", "thermometer.medium", stride(from: d.minKelvin, through: d.maxKelvin, by: 100).map { $0 }, selected: whiteBalance.temperatureAndTint?.temperature,
                    observed: observation?.observedWhiteBalanceTemperatureAndTint?.temperature),
                    numbers(.tint, "Tint", "t.circle", stride(from: d.minTint, through: d.maxTint, by: 5).map { $0 }, selected: whiteBalance.temperatureAndTint?.tint,
                    observed: observation?.observedWhiteBalanceTemperatureAndTint?.tint)].compactMap { $0 }
            }
        case .exposureBias:
            if exposureLimits.isValid, isBiasAvailable,
               let picker = numbers(.exposureBias, "Exposure", "plusminus", stride(from: ceil(exposureLimits.minBiasEV * 3), through: floor(exposureLimits.maxBiasEV * 3), by: 1).map { $0 / 3 }, selected: biasEV, automatic: false) { selections = [picker] }
        }
        let eligible = openPanel == nil ? hardwareLensSafetyEligible && (canSwitchCamera || ownsHardwareLensTransition)
            : isHardwareShutterEnabled && !isCaptureBusy
        return HardwareControlConfiguration(enabled: enabled && eligible, selections: selections,
            preservesPresentation: enabled && isHardwareInteractionEligible && isCaptureBusy && !selections.isEmpty)
    }

    func updateHardwareControls(_ configuration: HardwareControlConfiguration) {
        guard configuration != lastHardwareConfiguration else { return }
        if lastHardwareConfiguration.enabled != configuration.enabled
            || lastHardwareConfiguration.selections.map(\.domain) != configuration.selections.map(\.domain) {
            hardwareInteractionID = UUID()
            pendingHardwareLens = nil; hardwareLensOwner = nil
        }
        lastHardwareConfiguration = configuration
        guard let hardware = camera as? any HardwareCameraControlling else { return }
        if hardwareSelectionTask == nil {
            let events = hardware.hardwareControlSelections
            hardwareSelectionTask = Task { [weak self] in
                for await event in events {
                    guard !Task.isCancelled else { return }
                    await self?.receiveHardwareEvent(event)
                }
            }
            let appearances = hardware.hardwareControlFullscreen
            hardwareFullscreenTask = Task { [weak self] in
                for await fullscreen in appearances {
                    guard !Task.isCancelled else { return }
                    self?.isHardwareControlFullscreen = fullscreen && self?.lastHardwareConfiguration.enabled == true
                }
            }
        }
        if !configuration.enabled { isHardwareControlFullscreen = false }
        hardware.configureHardwareControls(configuration, interactionID: hardwareInteractionID)
    }

    func receiveHardwareEvent(_ event: HardwareControlEvent) async {
        guard event.interactionID == hardwareInteractionID else { return }
        await receiveHardwareSelection(event.selection)
    }

    func receiveHardwareSelection(_ selection: HardwareControlSelection) async {
        if case .lens(let kind) = selection.domain.value(at: selection.index) {
            guard lastHardwareConfiguration.enabled, openPanel == nil, hardwareLensSafetyEligible,
                  hardwareConfiguration(enabled: true).enabled,
                  hardwareConfiguration(enabled: true).selections.contains(where: { $0.domain == selection.domain }) else { return }
            hardwareLensOwner = (hardwareInteractionID, eligibilityEpoch)
            pendingHardwareLens = HardwareLensIntent(target: kind, interactionID: hardwareInteractionID, epoch: eligibilityEpoch)
            drainHardwareLensIntent()
            return
        }
        guard lastHardwareConfiguration.enabled, isHardwareShutterEnabled, !isCaptureBusy,
              let current = hardwareConfiguration(enabled: true).selections.first(where: { $0.domain == selection.domain }),
              current.index != selection.index, let value = selection.domain.value(at: selection.index) else { return }
        switch value {
        case .lens: break
        case .automatic:
            if let panel = openPanel { setStripAutomatic(panel) }
        case .number(let value):
            if current.isAutomatic {
                await seedHardwareManualFromAuto(selection.domain)
                return
            }
            switch selection.domain.kind {
            case .shutter: adjustShutterFromStrip(value)
            case .iso: adjustISOFromStrip(value)
            case .aperture: setAperture(value)
            case .focus: setManualFocusPosition(value)
            case .temperature: setWhiteBalanceTemperature(value)
            case .tint: setWhiteBalanceTint(value)
            case .exposureBias: setBias(value)
            case .lenses: break
            }
        }
    }

    /// One active switch plus one latest target. A new sensor must render under
    /// current geometry before the next graph operation can be admitted.
    private func drainHardwareLensIntent() {
        guard hardwareLensTask == nil, let intent = pendingHardwareLens else { return }
        guard intent.interactionID == hardwareInteractionID, intent.epoch == eligibilityEpoch,
              lastHardwareConfiguration.enabled, openPanel == nil, hardwareLensSafetyEligible else {
            pendingHardwareLens = nil; hardwareLensOwner = nil; return
        }
        guard canSwitchCamera else { return }
        pendingHardwareLens = nil
        if intent.target == capability.selectedCameraKind { hardwareLensOwner = nil; return }
        guard intent.target == .front || capability.camera(intent.target) != nil else { hardwareLensOwner = nil; return }
        hardwareLensTask = Task { [weak self] in
            guard let self else { return }
            if intent.interactionID == self.hardwareInteractionID, intent.epoch == self.eligibilityEpoch,
               self.lastHardwareConfiguration.enabled, self.openPanel == nil, self.hardwareLensSafetyEligible {
                await self.selectLens(intent.target, hardwareInteraction: intent.interactionID)
            }
            self.hardwareLensTask = nil
            if self.surface != .ready { self.pendingHardwareLens = nil; self.hardwareLensOwner = nil }
            if !self.isPreviewTransitionVisible { self.drainHardwareLensIntent() }
        }
    }

    /// The first numeric swipe leaves Auto at a fresh value from THIS sensor and
    /// request. Subsequent swipes use detents. No minimum/default substitutes for
    /// a missing, stale or out-of-range measurement.
    private struct HardwareManualSeedRequest {
        let domain: HardwareControlDomain
        let interactionID: UUID
        let epoch: Int
        let revision: UInt64
        let generation: ConfigurationGeneration
        let root: LibraryRootState
    }
    private func maySeedHardwareManual(_ request: HardwareManualSeedRequest) -> Bool {
        !Task.isCancelled && request.interactionID == hardwareInteractionID
            && request.epoch == eligibilityEpoch && request.revision == controlRevision
            && request.generation == capability.generation && request.root == currentRootState
            && lastHardwareConfiguration.enabled && isHardwareShutterEnabled && !isCaptureBusy
            && hardwareConfiguration(enabled: true).selections.contains(where: {
                $0.domain == request.domain && $0.isAutomatic
            })
    }
    private func seedHardwareManualFromAuto(_ domain: HardwareControlDomain) async {
        let request = HardwareManualSeedRequest(domain: domain, interactionID: hardwareInteractionID,
            epoch: eligibilityEpoch, revision: controlRevision, generation: capability.generation, root: currentRootState)
        // A just-selected Auto mode may still be in the short setter coalescing
        // window. Finish that owned application before asking for its live value.
        await applyTask?.value
        guard maySeedHardwareManual(request) else { return }
        guard var reading = await camera.currentControlReadback(), maySeedHardwareManual(request),
              reading.generation == request.generation else { return }
        if reading.requestRevision != request.revision {
            // A frozen single capture applies controls under its own request
            // identity. Rebind current UI intent before using any measured value;
            // a merely recent capture reading cannot stand in for that authority.
            // Track this application with other interactive work, so the shutter
            // drains an issued rebind instead of superseding it. The native binding
            // leaves already-matching continuous Auto modes untouched.
            let rebind = Task { [weak self] in
                guard let self, self.maySeedHardwareManual(request) else { return }
                await self.applyCurrentControls(revision: request.revision)
            }
            applyTask = rebind
            await rebind.value
            guard maySeedHardwareManual(request) else { return }
            guard let fresh = await camera.currentControlReadback(), maySeedHardwareManual(request) else { return }
            reading = fresh
        }
        guard reading.generation == request.generation, reading.requestRevision == request.revision,
              reading.settlement.isLiveObservation,
              (0...1).contains(Date().timeIntervalSince(reading.capturedAtUTC)) else { return }
        func legal(_ value: Double?, _ minimum: Double, _ maximum: Double) -> Double? {
            guard let value, value.isFinite, value >= minimum, value <= maximum else { return nil }
            return value
        }
        switch domain.kind {
        case .shutter, .iso:
            guard let duration = legal(reading.observedDurationSeconds, exposureLimits.minDurationSeconds, exposureLimits.maxDurationSeconds),
                  let iso = legal(reading.observedISO, exposureLimits.minISO, exposureLimits.maxISO) else { return }
            applyReadback(reading)
            if domain.kind == .shutter { adjustShutterFromStrip(duration) } else { adjustISOFromStrip(iso) }
        case .aperture:
            guard let capability = activeFormat?.apertureCapability,
                  let value = legal(reading.lensAperture, capability.minFNumber, capability.maxFNumber) else { return }
            applyReadback(reading)
            setAperture(value)
        case .focus:
            guard let position = legal(reading.focusPosition, 0, 1) else { return }
            setManualFocusPosition(position)
        case .temperature, .tint:
            guard let value = reading.observedWhiteBalanceTemperatureAndTint, value.isFinite, value.temperature > 0 else { return }
            whiteBalance = WhiteBalanceIntent(mode: .manual, temperatureAndTint: value)
            scheduleApply()
        case .lenses, .exposureBias: break
        }
    }
}
