import Foundation
@preconcurrency import AVFoundation
import Synchronization

/// Sink for preview-analysis demand and geometry. Declared here so the camera
/// service depends on a protocol rather than a concrete UI type.
protocol PreviewAnalysisSink: AnalysisSampleConsumer {
    /// The analysis the UI wants, including the user's selected peaking and zebra
    /// thresholds and the loupe centre/magnification (REVIEW.md C08).
    func setAnalysisRequest(_ request: AnalysisRequest?) async
    func updateGeometry(_ geometry: PreviewGeometrySnapshot?) async
}

/// Ticket handed to the capture pipeline for one submitted native request.
/// One physical camera's passive enumeration and reusable input. RAW answers are
/// unknown here until this camera is actually selected and connected.
struct PhysicalCameraProbeFacts: @unchecked Sendable {
    let kind: PhysicalCameraKind
    let device: AVCaptureDevice
    let input: AVCaptureDeviceInput?
    let rawFormats: [UInt32]
    let rawFileTypes: [String]
    let bracketCount: Int
    let capability: PhysicalCameraCapability?
}

/// The enumerated rear cameras and any reason none could be used.
struct PreparedSession: @unchecked Sendable {
    let facts: [PhysicalCameraProbeFacts]
    let emptyReason: String?

    init(facts: [PhysicalCameraProbeFacts], emptyReason: String? = nil) {
        self.facts = facts
        self.emptyReason = emptyReason
    }

    static func empty(reason: String) -> PreparedSession {
        PreparedSession(facts: [], emptyReason: reason)
    }
}

/// The configured capture tuple recorded after the input was attached.
struct CaptureTupleSelection: Sendable {
    let formatIndex: Int
    let dimensions: PixelDimensions
    let rawFormats: [UInt32]
    let notes: [String]
    let bracketCount: Int
    /// Raw file-type facts requeried from the COMMITTED final configuration
    /// (REVIEW.md G04). Nil when the caller did not supply them.
    var commmittedRawFileTypes: [String]? = nil
    var configurationMode: CaptureConfigurationMode = .explicitFormat
    var frontHEIFSupported = false
    var jpegSupported = false
    var jpegMaximumDimensions: PixelDimensions? = nil
}

/// The production camera service.
///
/// ARCHITECTURE.md concurrency rules:
///   * one dedicated serial session/configuration queue;
///   * never run blocking session start on MainActor;
///   * delegate lifetime lasts through the terminal callback and transfer;
///   * version every configuration snapshot and ignore old-generation control
///     callbacks while still routing old-generation acquired bytes to their
///     original transaction.
///
/// `AVCaptureCameraService` is an actor, but AVFoundation objects are only
/// touched inside `SerialSessionQueue.perform`, whose ownership invariant is
/// documented on that type. Nothing in this file mutates a session from the
/// actor's executor.
actor AVCaptureCameraService: CameraServicing, CameraCapabilityProviding, StagingOwnershipReporting, HardwareCameraControlling, CameraRecoveryStopping, CaptureFormatPreparing {
    private let sessionQueue = SerialSessionQueue()
    private let session = AVCaptureSession()
    private let hardwareControls = HardwareSessionControls()
    private let hardwareControlsSupported = Mutex<Bool?>(nil)
    private let desiredHardwareControls = Mutex<(configuration: HardwareControlConfiguration, owner: UUID, revision: UInt64)?>(nil)
    private let hardwareWhiteBalanceObservationRequested = Mutex(false)
    private let hardwareSelections = LatestValueBroadcaster<HardwareControlEvent>()
    private let hardwareFullscreen = LatestValueBroadcaster<Bool>()
    nonisolated var hardwareControlSelections: AsyncStream<HardwareControlEvent> { hardwareSelections.subscribe(replayLatest: false) }
    nonisolated var hardwareControlFullscreen: AsyncStream<Bool> { hardwareFullscreen.subscribe() }
    nonisolated func configureHardwareControls(_ configuration: HardwareControlConfiguration, interactionID: UUID) {
        let revision = desiredHardwareControls.withLock { desired in
            let revision = (desired?.revision ?? 0) &+ 1
            desired = (configuration, interactionID, revision)
            hardwareWhiteBalanceObservationRequested.withLock {
                $0 = configuration.enabled && configuration.selections.contains { $0.domain.kind == .temperature || $0.domain.kind == .tint }
            }
            return revision
        }
        guard hardwareControlsSupported.withLock({ $0 }) != false else { return }
        Task { [weak self] in await self?.installHardwareControls(configuration, revision: revision, interactionID: interactionID) }
    }
    private func reconcileHardwareControlsAfterNativeChange() {
        guard let desired = desiredHardwareControls.withLock({ $0 }) else { return }
        // Reconcile the saved revision; never republish an old snapshot as a new
        // user intent over a concurrent parameter/eligibility change.
        Task { [weak self] in await self?.installHardwareControls(desired.configuration,
            revision: desired.revision, interactionID: desired.owner) }
    }
    private func installHardwareControls(_ configuration: HardwareControlConfiguration, revision: UInt64, interactionID: UUID, retry: Int = 0) async {
        guard desiredHardwareControls.withLock({ $0?.revision == revision }) else { return }
        // Picker state is serialized on the session queue, but changes no native
        // input/output/connection or device setting. It need not drain pixel reads.
        let attached = await sessionQueue.perform { [self] in
            guard desiredHardwareControls.withLock({ $0?.revision == revision }) else { return true }
            let supported = session.supportsControls
            hardwareControlsSupported.withLock { $0 = supported }
            guard supported else { return true }
            // Settings belong to one sensor generation. A lens chooser instead
            // retains its screen interaction across its OWN serialized switches;
            // the model revalidates every target before a graph operation.
            guard !configuration.enabled || configuration.selections.allSatisfy({ $0.domain.kind == .lenses || $0.domain.generation == generationBox.withLock { $0 } }) else { return true }
            return hardwareControls.update(session: session, configuration: configuration, interactionID: interactionID, queue: sessionQueue.queue,
                emit: { [hardwareSelections] in hardwareSelections.send($0) },
                fullscreen: { [hardwareFullscreen] in hardwareFullscreen.send($0) })
        }
        if !attached, retry == 0 {
            try? await Task.sleep(for: .milliseconds(100))
            guard !Task.isCancelled, desiredHardwareControls.withLock({ $0?.revision == revision }) else { return }
            await installHardwareControls(configuration, revision: revision, interactionID: interactionID, retry: 1)
        }
    }
    // Session-lifetime discovery only. Final selected RAW/ceiling facts are ALWAYS
    // queried again after attachment. Reset-owned preparation discards this cache.
    private let preparedSessions = Mutex<[String: PreparedSession]>([:])
    private let processedFallbackCheckedTopologies = Mutex<Set<String>>([])
    private let warmPhotoCeilings = Mutex<[String: WarmPhotoCeilingEvidence]>([:])
    /// The configuration-order port. Defaults to the real session, and is replaceable
    /// so the ordering contract can be exercised without a device (REVIEW.md H03).
    /// The owned final-tuple operation, held for the service's lifetime so its configuration
    /// depth reflects the adapter's REAL configuration activity (Y03).
    private let finalTupleOperation = FinalTupleOperation()
    private let configurer: any SessionConfiguring
    private let photoOutput = AVCapturePhotoOutput()
    /// Optional prepared settings survive topology commits in AVFoundation.
    /// Keep their actual request identity separate from capability/admission.
    private let photoResourcePreparation = PhotoResourcePreparationOwner()
    /// Format selection is independent of graph configuration. A later RAW choice
    /// must obsolete an already-enqueued JPEG hint even on the same generation.
    private let formatPreparationIntent = Mutex<(revision: UInt64, format: CaptureFileFormat, generation: ConfigurationGeneration)?>(nil)
    private var captureConfigurationMode: CaptureConfigurationMode = .explicitFormat
    private let videoOutput = AVCaptureVideoDataOutput()
    private let analysisSink: any PreviewAnalysisSink
    /// Display-only handle for the preview layer; established once, read on main.
    private let displayBridge = PreviewDisplayBridge()
    private let sensorRotations = Mutex<CameraRotationAngles?>(nil)
    /// The serial analysis queue that owns the video-data delegate.
    private let analysisQueue = DispatchQueue(label: "com.iantruong.TruongCam.analysis", qos: .utility)
    /// Retained for the session's lifetime. REVIEW.md C08: no
    /// `setSampleBufferDelegate` call existed anywhere, so the analysis pipeline
    /// never received a frame and every preview aid stayed blank.
    private var analysisHandler: AnalysisSampleBufferHandler?
    /// Shared with the analysis queue and the analysis bridge: the generation
    /// stamp for incoming frames. Exposed so one owner publishes it.
    let analysisGeneration = SessionGenerationSource()
    /// Live control readings for the UI. Latest-value only.
    private let readbackBroadcaster = LatestValueBroadcaster<AppliedControlSnapshot>()
    /// One tracker per configuration generation. Reset whenever a setter runs, so a
    /// settle verdict always refers to the current control application.
    /// The settlement window now lives in `applicationOwner`; the adapter delegates to it
    /// so one component owns issue → target → settlement → publication (P01).
    private var lastBoundApplication: ControlApplicationOwner.Application?

    /// The configuration generation, in a Sendable box so the native ISSUE boundary can read it
    /// without crossing actor isolation (AF01).
    private let generationBox = Mutex<ConfigurationGeneration>(.zero)
    private var generation: ConfigurationGeneration {
        get { generationBox.withLock { $0 } }
        set { generationBox.withLock { $0 = newValue } }
    }
    /// The physical camera the current graph was built for, so a media-services reset
    /// can rebuild the SAME graph rather than a default one (REVIEW.md H02).
    private var lastDesiredCamera: PhysicalCameraKind?
    /// The last controls the application asked for, re-applied under the NEW generation
    /// after a successful rebuild (REVIEW.md H02).
    private var lastAppliedInstruction: NativeControlInstruction?
    /// Records any configuration-ORDER violation: a camera fact queried while a
    /// configuration was still open. Non-nil is a real defect (REVIEW.md H03).
    private let orderViolation = Mutex<String?>(nil)
    var configurationOrderViolation: String? { orderViolation.withLock { $0 } }
    /// The revision namespace for control applications. Owned here so it is coherent
    /// rather than derived from wall-clock milliseconds (REVIEW.md H01).
    private var controlRevision: UInt64 = 0
    /// The revision of the most recent issued application, stamped onto live
    /// observations so they can be correlated with their request (REVIEW.md K01).
    /// App-owned correlation between issued applications and their observations
    /// (REVIEW.md L01). The adapter holds no private revision scheme of its own.
    private let applicationOwner = ControlApplicationOwner()
    /// Submitted requests that have not yet reported their terminal outcome. Used to let
    /// in-flight drains finish before a graph teardown (REVIEW.md M03).
    /// Monotonic identity of the most recent control invocation, in the SERVICE's own actor.
    /// W01: checked synchronously with the final writes, so a later invocation that completed
    /// while this one awaited a remote verdict makes this one superseded.
    /// AB01: the service-owned publication/invocation identity, in Core so the delayed
    /// lifecycle regressions execute against the shipping counters.
    private let identity = PublicationIdentity()
    private var controlInvocationSequence: UInt64 { identity.controlSequence }
    /// Bumped by EVERY publication the service commits (control application OR readback), so
    /// a reading that began before a newer publication can refuse to overwrite it. X01.
    private var servicePublicationSequence: UInt64 { identity.publicationSequence }
    /// AM03: the submission/retirement bookkeeping is a Core owner, so the REAL algorithm can be
    /// executed by the portable verifier instead of a fixture standing in for it.
    private let inFlightRegistry = InFlightRequestRegistry()
    /// Capture IDs whose submission the production gate is currently counting.

    /// The planned duration of each submitted request, so the drain bound reflects what is
    /// ACTUALLY outstanding rather than a fixed constant (REVIEW.md Q02).
    /// The true result of the most recent pre-teardown drain (P02).
    private(set) var lastDrainOutcome: DrainOutcome = .drained
    /// Monotonic token identifying the newest reset/recovery pass. A newer pass starting makes
    /// an older one obsolete, while a pass's OWN generation bump does not (AC02).
    private var recoveryPassToken: UInt64 = 0
    /// AO02: synchronous mirror of `recoveryPassToken`, readable from a SYNC native body. The
    /// teardown's actor-level guard runs BEFORE the `sessionQueue.perform` hop, so a supersession
    /// during that hop still stopped the newer graph and stripped its video delegate. Native
    /// mutations now re-check the live pass AT the mutation.
    private let liveRecoveryPass = Mutex<UInt64>(0)

    /// Monotonic token advanced by EVERY lifecycle operation (start and stop) at its entry, so
    /// an operation suspended at an await can tell whether a NEWER lifecycle operation has taken
    /// over and must therefore be a no-effect failure (AH01/AH02).
    /// The Core-owned lifecycle TOKEN (AL01/AL02). A newer start does not change
    /// `PublicationIdentity`, so this is what makes an obsolete operation distinguishable.
    private let lifecycleOwnership = LifecycleOwnership()

    /// What the last reset/recovery pass concluded, readable by the recovery owner (AB02).
    private(set) var lastRecoveryOutcome: SubmissionRecoveryChain.Outcome = .recovered
    private var activeResetRecoveryPasses: Set<UInt64> = []
    /// The PRODUCTION teardown gate (Core), shared with the registered suite so the gate the
    /// tests exercise is the one that actually guards a teardown (U02).
    private let drainGate = SubmissionDrainGate()
    nonisolated func noteStagingStarted(_ captureID: CaptureID) {
        drainGate.noteStagingStarted(captureID)
    }
    nonisolated func noteStagingFinished(_ captureID: CaptureID) {
        drainGate.noteStagingFinished(captureID)
    }
    private var selectedKind: PhysicalCameraKind?
    private var snapshot: CameraCapabilitySnapshot = .empty(generation: .zero, reason: "Not prepared")
    private var lastApplied: AppliedControlSnapshot?
    private var analysisDemand: AnalysisDemand = .none
    private var currentAnalysisRequest: AnalysisRequest?
    private let analysisDemandOwnership = LifecycleOwnership()
    private var previewGeometry: PreviewGeometrySnapshot?
    private var isConfigured = false
    private var observersInstalled = false
    private let preparationOwnership = LifecycleOwnership()
    /// The condition the session notification path recorded (REVIEW.md R02).
    let sessionCondition = SessionCondition()
    /// Publishes each recorded condition so the owner of admission can consume it.
    ///
    /// REVIEW.md F02: the condition used to be recorded where nothing read it, so an
    /// interrupted camera still reported `.running` to the shutter gate.
    private let conditionBroadcaster = LatestValueBroadcaster<CameraLifecycle>()
    private let statusBroadcaster = LatestValueBroadcaster<CameraSessionStatus>()
    private var sessionResetEpoch: UInt64 = 0

    nonisolated var sessionStatusStream: AsyncStream<CameraSessionStatus> { statusBroadcaster.subscribe() }
    func recordedSessionStatus() async -> CameraSessionStatus {
        CameraSessionStatus(condition: sessionCondition.lifecycle, resetEpoch: sessionResetEpoch)
    }

    /// A stream of recorded session conditions, for the admission owner.
    nonisolated var sessionConditionStream: AsyncStream<CameraLifecycle> {
        conditionBroadcaster.subscribe()
    }

    /// The condition currently recorded, for a caller that joins late.
    func recordedSessionCondition() async -> CameraLifecycle { sessionCondition.lifecycle }
    /// Retained observer tokens, so the observers can actually be removed and are
    /// scoped to THIS session rather than any session in the process.
    ///
    /// Ownership invariant for the narrow `@unchecked Sendable`: `tokens` is only
    /// read or written while `lock` is held. `NSObjectProtocol` is not `Sendable`,
    /// so a `Mutex` cannot carry it, but the box never exposes the array outside
    /// these two methods.
    final class ObserverTokens: @unchecked Sendable {
        private let lock = NSLock()
        private var tokens: [NSObjectProtocol] = []

        func add(_ token: NSObjectProtocol) {
            lock.lock(); tokens.append(token); lock.unlock()
        }

        func takeAll() -> [NSObjectProtocol] {
            lock.lock(); defer { lock.unlock() }
            let copy = tokens
            tokens.removeAll()
            return copy
        }
    }

    private let observerTokens = ObserverTokens()

    /// Available Bayer pixel formats discovered while an input was attached.
    private var availableBayerFormats: [UInt32] = []
    private var availableRawFileTypes: [String] = []
    private var maximumBracketCount = 0

    /// Retained per request until the terminal callback arrives.
    private var delegatesByUniqueID: [Int64: PerCapturePhotoDelegate] = [:]
    private var requestsByUniqueID: [Int64: PerCaptureRequest] = [:]
    private var uniqueIDByCaptureID: [CaptureID: Int64] = [:]

    private let analysisOutput: BoundedEventChannel<AnalysisOutput>

    private let permission: any CameraPermissionPort

    init(analysisSink: any PreviewAnalysisSink,
         permission: any CameraPermissionPort = SystemCameraPermissionPort(),
         configurer: (any SessionConfiguring)? = nil) {
        self.permission = permission
        self.analysisSink = analysisSink
        self.analysisOutput = BoundedEventChannel(capacity: 4, overflow: .dropOldest)
        if let configurer {
            self.configurer = configurer
        } else {
            self.configurer = AVCaptureSessionConfigurer(session: session)
        }
        sessionQueue.activate()
    }

    // MARK: - CameraServicing

    var lifecycle: CameraLifecycle {
        get async {
            // REVIEW.md R02: this only asked whether the session was running, so an
            // interrupted or errored session still reported `.running` and admission
            // stayed open. The recorded condition now takes precedence.
            let recorded = sessionCondition.lifecycle
            let isRunning = await sessionQueue.perform { [session] in session.isRunning }
            // One shared rule, so the service and the portable tests cannot drift.
            return CameraLifecycleResolver.effective(
                recorded: recorded, sessionIsRunning: isRunning)
        }
    }

    /// The condition the notification path recorded, if any.
    ///
    /// `@unchecked Sendable` invariant: `condition` is only read or written while
    /// `conditionLock` is held.
    final class SessionCondition: @unchecked Sendable {
        private let lock = NSLock()
        private var condition: CameraLifecycle = .idle

        var lifecycle: CameraLifecycle {
            lock.lock(); defer { lock.unlock() }
            return condition
        }

        func set(_ value: CameraLifecycle) {
            lock.lock(); condition = value; lock.unlock()
        }

        /// Clears a recorded condition so a fresh start can run.
        func clear() {
            lock.lock(); condition = .idle; lock.unlock()
        }
    }

    var capabilitySnapshot: CameraCapabilitySnapshot { snapshot }

    nonisolated var analysisStream: BoundedOrderedSequence<AnalysisOutput> { analysisOutput.subscribe() }

    func prepare(desiredCamera: PhysicalCameraKind?) async -> Result<CameraCapabilitySnapshot, CaptureFailure> {
        await prepare(desiredCamera: desiredCamera, ownedByReset: nil)
    }

    /// AP01: the reset-owned variant. The authority travels WITH the call, so it cannot be
    /// substituted or cleared by a concurrent operation.
    private func prepare(
        desiredCamera: PhysicalCameraKind?,
        ownedByReset: UInt64?
    ) async -> Result<CameraCapabilitySnapshot, CaptureFailure> {
        let operationResetPass = ownedByReset ?? recoveryPassToken
        guard resetAuthorityIsCurrent(operationResetPass) else {
            return .failure(CaptureFailure(kind: .cameraInterrupted(detail: "Preparation belongs to an obsolete recovery pass."), operation: "prepare.entry"))
        }
        let preparationToken = preparationOwnership.begin()
        // An ordinary camera change supersedes an older Start/Stop as well as a
        // prior preparation. A reset-owned preparation retains its parent lifecycle.
        let lifecycleAtPreparation = ownedByReset == nil ? lifecycleOwnership.begin() : lifecycleOwnership.current
        // AQ01: authority FIRST. These are reset-owned mutations, and a stale pass reaching this
        // actor after a prior Core check must not clear a NEWER failure nor overwrite the newer
        // desired camera before we have established that this pass is still the live one.
        guard lifecycleOwnership.isCurrent(lifecycleAtPreparation), preparationOwnership.isCurrent(preparationToken), resetAuthorityIsCurrent(operationResetPass) else {
            return .failure(CaptureFailure(kind: .cameraInterrupted(
                detail: "The camera was rebuilt by a newer recovery pass."), operation: "prepare"))
        }
        let analysisPriority = displayBridge.prioritizeCameraPreparation()
        defer { analysisPriority.release() }
        // Preparing rebuilds the graph, so any previously recorded interruption or
        // media-services failure is superseded by the new result (REVIEW.md R02).
        sessionCondition.clear()
        // The desire is recorded so a media-services reset can rebuild the SAME graph
        // (REVIEW.md H02).
        lastDesiredCamera = desiredCamera
        // Explicit permission handling (REVIEW.md C03): a denied/unavailable
        // grant is reported before any session work is attempted.
        // REVIEW.md S03: a fresh install could never grant permission because
        // `.notDetermined` was treated as denial and nothing ever called the
        // public request API. The decision is now explicit and the real request is
        // made before giving up.
        #if DEBUG
        let permissionBegan = ProcessInfo.processInfo.systemUptime
        #endif
        let observed = await permission.currentAuthorization()
        #if DEBUG
        print("TruongCam timing prepare-permission=\(Int((ProcessInfo.processInfo.systemUptime - permissionBegan) * 1000))ms")
        #endif
        // AO02: a reset superseded while we awaited permission must not proceed to mutate.
        guard lifecycleOwnership.isCurrent(lifecycleAtPreparation), preparationOwnership.isCurrent(preparationToken), resetAuthorityIsCurrent(operationResetPass) else {
            return .failure(CaptureFailure(kind: .cameraInterrupted(
                detail: "The camera was rebuilt by a newer recovery pass."), operation: "prepare"))
        }
        var decision = CameraPermissionDecision.decide(observed)
        if case .request = decision {
            let answered = await permission.requestAuthorization()
            guard lifecycleOwnership.isCurrent(lifecycleAtPreparation), preparationOwnership.isCurrent(preparationToken), resetAuthorityIsCurrent(operationResetPass) else {
                return .failure(CaptureFailure(kind: .cameraInterrupted(
                    detail: "The camera was rebuilt by a newer recovery pass."), operation: "prepare"))
            }
            decision = CameraPermissionDecision.decideAfterRequest(answered)
        }
        if case .refuse(let reason) = decision {
            snapshot = .empty(generation: generation, reason: reason)
            return .failure(CaptureFailure(kind: .permissionDenied(domain: "AVCaptureDevice"),
                                           operation: "prepare"))
        }

        guard lifecycleOwnership.isCurrent(lifecycleAtPreparation), preparationOwnership.isCurrent(preparationToken), resetAuthorityIsCurrent(operationResetPass) else {
            return .failure(CaptureFailure(kind: .cameraInterrupted(
                detail: "The camera was rebuilt by a newer recovery pass."), operation: "prepare"))
        }
        if ownedByReset != nil {
            preparedSessions.withLock { $0.removeAll() }
            processedFallbackCheckedTopologies.withLock { $0.removeAll() }
            warmPhotoCeilings.withLock { $0.removeAll() }
        }
        let wantsFront = desiredCamera == .front
        let wantsInitialAnalysis = analysisDemand.wantsVideoOutput
        let discoveryKey = "\(wantsFront)-\(wantsInitialAnalysis)"
        let passiveKey = "\(wantsFront)"
        #if DEBUG
        let previewPauseBegan = ProcessInfo.processInfo.systemUptime
        #endif
        let previewPause = await displayBridge.nativeAccessGate.pauseAndDrainFrames()
        defer { previewPause.release() }
        #if DEBUG
        print("TruongCam timing prepare-preview-pause=\(Int((ProcessInfo.processInfo.systemUptime - previewPauseBegan) * 1000))ms")
        let selectionQueuedAt = ProcessInfo.processInfo.systemUptime
        #endif
        let selection: PreparedSession = await sessionQueue.perform { [session, photoOutput, videoOutput] () -> PreparedSession in
            #if DEBUG
            let began = ProcessInfo.processInfo.systemUptime
            print("TruongCam timing prepare-selection-queue=\(Int((began - selectionQueuedAt) * 1000))ms")
            defer { print("TruongCam timing prepare-discovery-and-probe=\(Int((ProcessInfo.processInfo.systemUptime - began) * 1000))ms") }
            #endif
            guard self.lifecycleOwnership.isCurrent(lifecycleAtPreparation), self.preparationOwnership.isCurrent(preparationToken), self.resetAuthorityAllowsNativeMutation(operationResetPass) else {
                return PreparedSession.empty(reason: "Preparation was superseded by a newer recovery pass.")
            }
            let topologyMatches = session.outputs.contains { $0 === videoOutput } == wantsInitialAnalysis
            let needsTopologyMutation = !topologyMatches || !session.outputs.contains { $0 === photoOutput }
                || !CapturePipelinePreparation.outputChanges(Self.photoPipelineOutputState(photoOutput, videoOutput)).isEmpty
                || photoOutput.isAppleProRAWEnabled || session.sessionPreset != .photo
            FinalTupleOperation.configureIfNeeded(needsTopologyMutation,begin:self.beginConfigure,commit:self.commitConfigure) {
                // iOS 26+ defaults the photo output to deferred resource preparation.
                // We need its capability facts during startup, before admitting a shot.
                if !wantsInitialAnalysis, session.outputs.contains(where: { $0 === videoOutput }) {
                    videoOutput.setSampleBufferDelegate(nil, queue: nil)
                    session.removeOutput(videoOutput)
                }
                if !session.outputs.contains(where: { $0 === photoOutput }), session.canAddOutput(photoOutput) {
                    session.addOutput(photoOutput)
                }
                if wantsInitialAnalysis, !session.outputs.contains(where: { $0 === videoOutput }), session.canAddOutput(videoOutput) {
                    session.addOutput(videoOutput)
                    // REVIEW.md R01: the initially attached analysis output must be
                    // given a supported luma format here. Previously the first enabled
                    // demand found the output already attached, took the `.unchanged`
                    // path, and never installed a delegate or settings, so no aid had a
                    // frame producer on a first launch.
                    if let selected = Self.selectAnalysisPixelFormat(videoOutput) {
                        videoOutput.videoSettings = [
                            kCVPixelBufferPixelFormatTypeKey as String: selected,
                        ]
                    }
                }
                // Bootstrap a PHOTO pipeline. Explicit format selection later moves
                // the session to inputPriority; do not start in its default video preset.
                if session.sessionPreset != .photo, session.canSetSessionPreset(.photo) { session.sessionPreset = .photo }
                // Bayer-only v1: ProRAW must be off before RAW formats are read.
                if photoOutput.isAppleProRAWEnabled {
                    photoOutput.isAppleProRAWEnabled = false
                }
                Self.preparePhotoPipelineOptions(photoOutput, videoOutput, isCurrent: {
                    self.lifecycleOwnership.isCurrent(lifecycleAtPreparation)
                        && self.preparationOwnership.isCurrent(preparationToken)
                        && self.resetAuthorityAllowsNativeMutation(operationResetPass)
                })
            }
            if let cached = self.preparedSessions.withLock({ $0[passiveKey] }) { return cached }
            let discoverySession = AVCaptureDevice.DiscoverySession(
                deviceTypes: wantsFront ? [.builtInWideAngleCamera, .builtInTrueDepthCamera] : CameraCapabilityProbe.physicalRearDeviceTypes,
                mediaType: .video,
                position: wantsFront ? .front : .back)
            let devices: [AVCaptureDevice]
            if wantsFront {
                // Prefer the RGB front camera; discover only when explicitly requested.
                let front = discoverySession.devices.filter { $0.position == .front }
                devices = Array((front.first { $0.deviceType == .builtInWideAngleCamera } ?? front.first).map { [$0] } ?? [])
            } else {
                devices = CameraCapabilityProbe.discoverDevices(discoverySession: discoverySession)
            }
            #if DEBUG
            print("TruongCam prepare: front=\(wantsFront), discovered=\(discoverySession.devices.count), physical=\(devices.count), types=\(discoverySession.devices.map { $0.deviceType.rawValue })")
            #endif
            guard !devices.isEmpty else {
                return PreparedSession.empty(reason: "No rear physical camera was discovered.")
            }


            var facts: [PhysicalCameraProbeFacts] = []
            // Only enumerate passive format/control facts here. Attaching every
            // other lens just to probe RAW repeatedly restarts a live sensor.
            // Unselected Bayer/container/bracket support stays explicitly unknown;
            // the actual selected camera is attached and validated below.
            for device in devices {
                let input = try? AVCaptureDeviceInput(device:device)
                let capability = CameraCapabilityProbe.capability(for:device,selectedFormatIndex:nil,
                    rawFormats:nil,rawFileTypes:nil,nativeBracketCount:nil)
                facts.append(PhysicalCameraProbeFacts(kind:CameraCapabilityProbe.kind(for:device.deviceType,position:device.position),
                    device:device,input:input,rawFormats:[],rawFileTypes:[],bracketCount:0,capability:capability))
            }
            let prepared = PreparedSession(facts: facts)
            self.preparedSessions.withLock { $0[passiveKey] = prepared }
            return prepared
        }

        let prepared = selection

        // AQ01: re-checked AFTER the selection suspension and BEFORE the mutation. A pass superseded
        // while queued must not advance the newer graph's generation.
        guard lifecycleOwnership.isCurrent(lifecycleAtPreparation), preparationOwnership.isCurrent(preparationToken), resetAuthorityIsCurrent(operationResetPass) else {
            return .failure(CaptureFailure(kind: .cameraInterrupted(
                detail: "The camera was rebuilt by a newer recovery pass."), operation: "prepare"))
        }
        generation = ConfigurationGeneration.next(generation)
        previewGeometry = nil
        displayBridge.setGeometry(nil)
        refreshAnalysisGeneration()

        guard !prepared.facts.isEmpty else {
            snapshot = .empty(generation: generation, reason: prepared.emptyReason ?? "No rear physical camera was discovered.")
            return .failure(CaptureFailure(kind: .noCamera, operation: "prepare"))
        }

        // Choose the physical camera and then ACTUALLY attach + configure it.
        let chosenKind = desiredCamera
            ?? prepared.facts.first(where: { $0.kind == .wide })?.kind
            ?? prepared.facts[0].kind
        guard let chosenIndex = prepared.facts.firstIndex(where: { $0.kind == chosenKind }) else {
            snapshot = .empty(generation: generation, reason: "The requested physical camera is not present.")
            return .failure(CaptureFailure(kind: .noCamera, operation: "prepare"))
        }

        #if DEBUG
        let tupleQueuedAt = ProcessInfo.processInfo.systemUptime
        #endif
        let attachOutcome = await sessionQueue.perform { [session, photoOutput, videoOutput] () -> Result<CaptureTupleSelection, CaptureFailure> in
            #if DEBUG
            let began = ProcessInfo.processInfo.systemUptime
            print("TruongCam timing prepare-tuple-queue=\(Int((began - tupleQueuedAt) * 1000))ms")
            defer { print("TruongCam timing prepare-selected-tuple=\(Int((ProcessInfo.processInfo.systemUptime - began) * 1000))ms") }
            #endif
            guard self.lifecycleOwnership.isCurrent(lifecycleAtPreparation), self.preparationOwnership.isCurrent(preparationToken), self.resetAuthorityAllowsNativeMutation(operationResetPass) else {
                return .failure(CaptureFailure(kind: .cameraInterrupted(detail: "Preparation was superseded by a newer recovery pass."), operation: "prepare.attachInput"))
            }
            let chosen = prepared.facts[chosenIndex]
            guard let input = chosen.input else {
                return .failure(CaptureFailure(
                    kind: .captureFailed(detail: "The selected physical camera could not be opened."),
                    operation: "prepare.attachInput"))
            }

            let sameInput = session.inputs.count == 1 && session.inputs.first === input
            let needsAttach = !sameInput || session.sessionPreset != .photo
                || !session.outputs.contains(where: { $0 === photoOutput })
                || photoOutput.maxPhotoQualityPrioritization != .speed
            if needsAttach {
                self.beginConfigure()
                self.retirePreparedPhotoResourcesIfCurrent(photoOutput) {
                    self.lifecycleOwnership.isCurrent(lifecycleAtPreparation)
                        && self.preparationOwnership.isCurrent(preparationToken)
                        && self.resetAuthorityAllowsNativeMutation(operationResetPass)
                }
                if !sameInput { for existing in session.inputs { session.removeInput(existing) } }
                guard sameInput || session.canAddInput(input) else {
                    self.commitConfigure()
                    return .failure(CaptureFailure(
                        kind: .unsupportedCapability(detail: "The selected physical camera cannot be attached to the session."),
                        operation: "prepare.attachInput"))
                }
                if !sameInput { session.addInput(input) }
                if session.sessionPreset != .photo, session.canSetSessionPreset(.photo) { session.sessionPreset = .photo }
                if photoOutput.maxPhotoQualityPrioritization != .speed { photoOutput.maxPhotoQualityPrioritization = .speed }
                if !session.outputs.contains(where: { $0 === photoOutput }) {
                    guard session.canAddOutput(photoOutput) else {
                        session.removeInput(input)
                        self.commitConfigure()
                        return .failure(CaptureFailure(kind: .unsupportedCapability(
                            detail: "The rear camera was opened, but the photo output could not be connected."),
                            operation: "prepare.attachPhotoOutput"))
                    }
                    session.addOutput(photoOutput)
                }

                if wantsInitialAnalysis, !session.outputs.contains(where: { $0 === videoOutput }),
                   session.canAddOutput(videoOutput) {
                    session.addOutput(videoOutput)
                }

                // Normalize output connections only. A preview connection can
                // synchronously notify its UIKit-backed layer and belongs to the
                // MainActor display owner, even during an input swap.
                let current = {
                    self.lifecycleOwnership.isCurrent(lifecycleAtPreparation)
                        && self.preparationOwnership.isCurrent(preparationToken)
                        && self.resetAuthorityAllowsNativeMutation(operationResetPass)
                }
                Self.preparePhotoPipelineOptions(photoOutput, videoOutput, isCurrent: current)
                Self.prepareAnalysisConnection(videoOutput, isCurrent: current)
                Self.prepareOriginalConnection(photoOutput, isCurrent: current)

                // Reserve a legal ceiling in the input-swap commit even on a
                // first visit, when fresh passive dimensions prove the actual
                // NEW activeFormat supports the complete advertised maximum.
                // This is only a setter plan: no RAW/container fact is borrowed
                // from the detached lens, and final committed queries below
                // still select and authorize the actual capture tuple.
                if session.sessionPreset == .photo, current() {
                    let matrix = Self.nativePhotoDimensionMatrix(chosen.device)
                    let activeDimensions = chosen.device.activeFormat.supportedMaxPhotoDimensions.map {
                        PixelDimensions(width: Int($0.width), height: Int($0.height))
                    }
                    let freshCeiling = FreshPhotoCeilingReservation.plannedCeiling(
                        candidateDimensions: matrix, currentFormatDimensions: activeDimensions)
                    let warmCeiling = self.warmPhotoCeilings.withLock { $0[chosen.device.uniqueID] }?.plannedCeiling(
                        deviceIdentity: chosen.device.uniqueID,
                        formatIdentity: String(describing: ObjectIdentifier(chosen.device.activeFormat)),
                        analysisOutputAttached: session.outputs.contains { $0 === videoOutput },
                        candidateDimensions: matrix, currentFormatDimensions: activeDimensions)
                    if let ceiling = freshCeiling ?? warmCeiling, current() {
                        if photoOutput.maxPhotoDimensions.width != Int32(clamping: ceiling.width)
                            || photoOutput.maxPhotoDimensions.height != Int32(clamping: ceiling.height) {
                            photoOutput.maxPhotoDimensions = CMVideoDimensions(
                                width: Int32(clamping: ceiling.width), height: Int32(clamping: ceiling.height))
                        }
                    }
                }

                // G04: complete the input/output TOPOLOGY and commit it before any
                // per-candidate discovery. Leaving this block open made every inner
                // begin/commit a nested no-op, so the output was queried for a
                // configuration the session had not adopted.
                self.commitConfigure()
            }
            guard photoOutput.connection(with: .video) != nil else {
                self.beginConfigure()
                session.removeInput(input)
                self.commitConfigure()
                return .failure(CaptureFailure(kind: .unsupportedCapability(
                    detail: "The photo output has no video connection to the selected rear camera."),
                    operation: "prepare.photoConnection"))
            }
            #if DEBUG
            print("TruongCam photo bootstrap: preset=\(session.sessionPreset.rawValue), running=\(session.isRunning), deferred=\(photoOutput.isDeferredStartEnabled), connectionEnabled=\(photoOutput.connection(with: .video)?.isEnabled ?? false), processedFiles=\(photoOutput.availablePhotoFileTypes.map(\.rawValue)), rawFiles=\(photoOutput.availableRawPhotoFileTypes.map(\.rawValue)), rawPixels=\(photoOutput.availableRawPhotoPixelFormatTypes), analysisAttached=\(session.outputs.contains { $0 === videoOutput })")
            #endif

            let rotation = AVCaptureDevice.RotationCoordinator(device: chosen.device, previewLayer: nil)
            self.sensorRotations.withLock { $0 = CameraRotationAngles(
                portrait: Int(rotation.videoRotationAngleRelative(toDeviceOrientation: .portrait).rounded()),
                portraitUpsideDown: Int(rotation.videoRotationAngleRelative(toDeviceOrientation: .portraitUpsideDown).rounded()),
                landscapeLeft: Int(rotation.videoRotationAngleRelative(toDeviceOrientation: .landscapeLeft).rounded()),
                landscapeRight: Int(rotation.videoRotationAngleRelative(toDeviceOrientation: .landscapeRight).rounded())) }
            func processedSelection() -> Result<CaptureTupleSelection, CaptureFailure> {
                guard self.lifecycleOwnership.isCurrent(lifecycleAtPreparation), self.preparationOwnership.isCurrent(preparationToken), self.resetAuthorityAllowsNativeMutation(operationResetPass) else {
                    return .failure(CaptureFailure(kind: .cameraInterrupted(detail: "Processed photo preparation was superseded."), operation: "prepare.processed.owner"))
                }
                // Return to a committed photo graph after the explicit RAW sweep.
                guard session.sessionPreset == .photo || session.canSetSessionPreset(.photo) else {
                    return .failure(CaptureFailure(kind: .unsupportedCapability(detail: "Processed photo mode is unavailable."), operation: "prepare.processed"))
                }
                FinalTupleOperation.configureIfNeeded(session.sessionPreset != .photo,begin:self.beginConfigure,commit:self.commitConfigure) {
                    self.retirePreparedPhotoResourcesIfCurrent(photoOutput) {
                        self.lifecycleOwnership.isCurrent(lifecycleAtPreparation)
                            && self.preparationOwnership.isCurrent(preparationToken)
                            && self.resetAuthorityAllowsNativeMutation(operationResetPass)
                    }
                    session.sessionPreset = .photo
                }
                let supportsFrontHEIF = chosen.kind == .front && Self.supportsHEIF(photoOutput)
                let supportsJPEG = Self.supportsJPEG(photoOutput)
                guard supportsFrontHEIF || supportsJPEG,
                      let max = chosen.device.activeFormat.supportedMaxPhotoDimensions.max(by: { Int64($0.width) * Int64($0.height) < Int64($1.width) * Int64($1.height) }) else {
                    return .failure(CaptureFailure(kind: .unsupportedCapability(detail: "This camera exposes no usable Bayer RAW DNG or supported processed photo format."), operation: "prepare.processed"))
                }
                let needsMutation = photoOutput.maxPhotoDimensions.width != max.width
                    || photoOutput.maxPhotoDimensions.height != max.height
                    || !CapturePipelinePreparation.outputChanges(Self.photoPipelineOutputState(photoOutput, videoOutput)).isEmpty
                FinalTupleOperation.configureIfNeeded(needsMutation, begin: self.beginConfigure, commit: self.commitConfigure) {
                    self.retirePreparedPhotoResourcesIfCurrent(photoOutput) {
                        self.lifecycleOwnership.isCurrent(lifecycleAtPreparation)
                            && self.preparationOwnership.isCurrent(preparationToken)
                            && self.resetAuthorityAllowsNativeMutation(operationResetPass)
                    }
                    if photoOutput.maxPhotoDimensions.width != max.width || photoOutput.maxPhotoDimensions.height != max.height {
                        photoOutput.maxPhotoDimensions = max
                    }
                    let current = {
                        self.lifecycleOwnership.isCurrent(lifecycleAtPreparation)
                            && self.preparationOwnership.isCurrent(preparationToken)
                            && self.resetAuthorityAllowsNativeMutation(operationResetPass)
                    }
                    Self.preparePhotoPipelineOptions(photoOutput, videoOutput, isCurrent: current)
                    Self.prepareAnalysisConnection(videoOutput, isCurrent: current)
                    Self.prepareOriginalConnection(photoOutput, isCurrent: current)
                }
                let finalJPEG = Self.supportsJPEG(photoOutput)
                let finalFrontHEIF = chosen.kind == .front && Self.supportsHEIF(photoOutput)
                guard finalJPEG || finalFrontHEIF,
                      self.lifecycleOwnership.isCurrent(lifecycleAtPreparation),
                      self.preparationOwnership.isCurrent(preparationToken),
                      self.resetAuthorityAllowsNativeMutation(operationResetPass),
                      photoOutput.maxPhotoDimensions.width == max.width,
                      photoOutput.maxPhotoDimensions.height == max.height,
                      chosen.device.activeFormat.supportedMaxPhotoDimensions.contains(where: {
                          $0.width == max.width && $0.height == max.height
                      }) else {
                    return .failure(CaptureFailure(kind: .unsupportedCapability(
                        detail: "The committed processed photo tuple is no longer usable."), operation: "prepare.processed.final"))
                }
                return .success(CaptureTupleSelection(
                    formatIndex: chosen.device.formats.firstIndex(of: chosen.device.activeFormat) ?? 0,
                    dimensions: PixelDimensions(width: Int(max.width), height: Int(max.height)),
                    rawFormats: [], notes: ["Processed-only preview after Bayer discovery; capture requires the user's explicit supported format."],
                    bracketCount: 0, commmittedRawFileTypes: [], configurationMode: .photoPreset,
                    frontHEIFSupported: finalFrontHEIF, jpegSupported: finalJPEG,
                    jpegMaximumDimensions: finalJPEG ? PixelDimensions(width: Int(max.width), height: Int(max.height)) : nil))
            }
            // A complete negative RAW sweep is reusable only for this session/topology.
            // Processed container/codec support and the legal ceiling stay fresh.
            let processedTopologyKey = "\(chosen.device.uniqueID)-\(discoveryKey)"
            if self.processedFallbackCheckedTopologies.withLock({ $0.contains(processedTopologyKey) }),
               photoOutput.supportedRawPhotoPixelFormatTypes(for: .dng).filter({ AVCapturePhotoOutput.isBayerRAWPixelFormat($0) }).isEmpty {
                return processedSelection()
            }

            // C04 / REVIEW.md S04: RAW support must be measured PER FORMAT.
            //
            // The previous code read `supportedRawPhotoPixelFormatTypes(for:)` once
            // with whatever format happened to be active and copied that one list
            // into every `CaptureFormatFacts`, so a format that cannot shoot RAW
            // looked RAW-capable. The list is now obtained after setting each
            // candidate `activeFormat`, because the photo output's answer is only
            // meaningful for the format the device is actually using.
            //
            // REVIEW.md F04: each candidate configuration is COMMITTED before its
            // output facts are read. The photo output's RAW answers describe a
            // committed session state, so querying them while one long configuration
            // stayed open returned facts for a configuration the session never
            // adopted.
            // Read the current matrix after the topology commit, including warm
            // switches. Cached setter evidence cannot hide a newly larger format.
            let currentDimensionMatrix = Self.nativePhotoDimensionMatrix(chosen.device)
            let candidates = currentDimensionMatrix.enumerated().map {
                CaptureFormatDiscovery.Candidate(index: $0.offset, dimensions: $0.element)
            }
            var photoFacts: CaptureFormatFacts?
            let probeConnection = photoOutput.connection(with: .video)
            let needsProbeMutation = session.sessionPreset != .photo || chosen.device.videoZoomFactor != 1
                || photoOutput.maxPhotoQualityPrioritization != .speed || probeConnection?.videoScaleAndCropFactor != 1
            do {
                try FinalTupleOperation.configureIfNeeded(needsProbeMutation, begin:self.beginConfigure, commit:self.commitConfigure) {
                    self.retirePreparedPhotoResourcesIfCurrent(photoOutput) {
                        self.lifecycleOwnership.isCurrent(lifecycleAtPreparation)
                            && self.preparationOwnership.isCurrent(preparationToken)
                            && self.resetAuthorityAllowsNativeMutation(operationResetPass)
                    }
                    if session.sessionPreset != .photo, session.canSetSessionPreset(.photo) { session.sessionPreset = .photo }
                    if chosen.device.videoZoomFactor != 1 {
                        try chosen.device.lockForConfiguration()
                        chosen.device.videoZoomFactor = 1
                        chosen.device.unlockForConfiguration()
                    }
                    if photoOutput.maxPhotoQualityPrioritization != .speed { photoOutput.maxPhotoQualityPrioritization = .speed }
                    if probeConnection?.videoScaleAndCropFactor != 1 { probeConnection?.videoScaleAndCropFactor = 1 }
                }
            } catch {
                return .failure(AVFoundationFailureMapper.failure(error, operation: "prepare.photoProbe"))
            }
            self.recordConfigurationOrderIfNeeded(operation: "photoPresetRawQuery")
            if session.sessionPreset == .photo,
               let index = chosen.device.formats.firstIndex(of: chosen.device.activeFormat),
               photoOutput.availableRawPhotoFileTypes.contains(.dng) {
                photoFacts = CaptureFormatFacts(index: index,
                    advertisedMaxPhotoDimensions: chosen.device.activeFormat.supportedMaxPhotoDimensions.map {
                        PixelDimensions(width: Int($0.width), height: Int($0.height))
                    },
                    bayerPixelFormatsForDNG: photoOutput.supportedRawPhotoPixelFormatTypes(for: .dng)
                        .filter { bayerClassifierForDiscovery.isBayerRAW($0) },
                    configurationMode: .photoPreset)
            }
            let discovery: CaptureFormatDiscovery.Result
            if CaptureFormatDiscovery.photoReachesAdvertisedCeiling(photoFacts, candidates: candidates) {
                discovery = .init(facts: [], activationFailures: [], dngCandidateCount: 0)
                #if DEBUG
                print("TruongCam prepare: verified photo Bayer tuple reaches device-wide advertised ceiling; no format sweep")
                #endif
            } else {
                discovery = CaptureFormatDiscovery.probe(
                candidates: candidates,
                activateAndCommit: { index in
                    guard self.lifecycleOwnership.isCurrent(lifecycleAtPreparation),
                          self.preparationOwnership.isCurrent(preparationToken),
                          self.resetAuthorityAllowsNativeMutation(operationResetPass) else {
                        throw CaptureFailure(kind: .cameraInterrupted(detail: "Format discovery was superseded."),
                                             operation: "prepare.candidate")
                    }
                    self.beginConfigure()
                    defer { self.commitConfigure() }
                    self.retirePreparedPhotoResourcesIfCurrent(photoOutput) {
                        self.lifecycleOwnership.isCurrent(lifecycleAtPreparation)
                            && self.preparationOwnership.isCurrent(preparationToken)
                            && self.resetAuthorityAllowsNativeMutation(operationResetPass)
                    }
                    try chosen.device.lockForConfiguration()
                    defer { chosen.device.unlockForConfiguration() }
                    chosen.device.activeFormat = chosen.device.formats[index]
                    // RAW discovery must run under legal zoom/speed settings too,
                    // rather than fixing them only after selection has succeeded.
                    chosen.device.videoZoomFactor = 1.0
                    photoOutput.maxPhotoQualityPrioritization = .speed
                    if let connection = photoOutput.connection(with: .video) {
                        connection.videoScaleAndCropFactor = 1.0
                if connection.isVideoMirroringSupported {
                    connection.automaticallyAdjustsVideoMirroring = false
                    connection.isVideoMirrored = false
                }
                    }
                },
                dngIsAvailable: { photoOutput.availableRawPhotoFileTypes.contains(.dng) },
                bayerFormatsForDNG: {
                    self.recordConfigurationOrderIfNeeded(operation: "supportedRawPhotoPixelFormatTypes")
                    return photoOutput.supportedRawPhotoPixelFormatTypes(for: .dng)
                        .filter { bayerClassifierForDiscovery.isBayerRAW($0) }
                })
            photoFacts = nil
            self.beginConfigure()
            if session.canSetSessionPreset(.photo) { session.sessionPreset = .photo }
            self.commitConfigure()
            if session.sessionPreset == .photo,
               let index = chosen.device.formats.firstIndex(of: chosen.device.activeFormat),
               photoOutput.availableRawPhotoFileTypes.contains(.dng) {
                photoFacts = CaptureFormatFacts(index: index,
                    advertisedMaxPhotoDimensions: chosen.device.activeFormat.supportedMaxPhotoDimensions.map {
                        PixelDimensions(width: Int($0.width), height: Int($0.height))
                    },
                    bayerPixelFormatsForDNG: photoOutput.supportedRawPhotoPixelFormatTypes(for: .dng)
                        .filter { bayerClassifierForDiscovery.isBayerRAW($0) },
                    configurationMode: .photoPreset)
            }
            }
            // Prefer photo mode on an equal ceiling, while retaining any larger
            // explicit configuration that really exposes Bayer RAW.
            let formatFacts = (photoFacts.map { [$0] } ?? []) + discovery.facts
            #if DEBUG
            print("TruongCam prepare: \(chosen.kind), explicitFormats=\(discovery.facts.count), explicitDNG=\(discovery.dngCandidateCount), photoBayer=\(photoFacts?.bayerPixelFormatsForDNG ?? []), activation failures=\(discovery.activationFailures)")
            #endif
            guard let tuple = CaptureTupleSelector.select(from: formatFacts) else {
                if chosen.kind == .front || Self.supportsJPEG(photoOutput) {
                    let result = processedSelection()
                    if discovery.activationFailures.isEmpty, discovery.facts.count == candidates.count,
                       self.lifecycleOwnership.isCurrent(lifecycleAtPreparation), self.preparationOwnership.isCurrent(preparationToken),
                       self.resetAuthorityAllowsNativeMutation(operationResetPass), case .success = result {
                        _ = self.processedFallbackCheckedTopologies.withLock { $0.insert(processedTopologyKey) }
                    }
                    return result
                }
                self.beginConfigure()
                session.removeInput(input)
                self.commitConfigure()
                return .failure(CaptureFailure(kind: .unsupportedCapability(
                    detail: "Neither the photo preset nor the \(discovery.facts.count) explicit formats exposed a usable Bayer RAW DNG."),
                    operation: "prepare.selectTuple"))
            }

            guard self.lifecycleOwnership.isCurrent(lifecycleAtPreparation),
                  self.preparationOwnership.isCurrent(preparationToken),
                  self.resetAuthorityAllowsNativeMutation(operationResetPass) else {
                return .failure(CaptureFailure(kind: .cameraInterrupted(detail: "Tuple configuration was superseded."),
                                               operation: "prepare.configureTuple"))
            }
            let ceiling = tuple.requestedDimensions
            let finalConnection = photoOutput.connection(with: .video)
            let targetDimensions = CMVideoDimensions(width:Int32(clamping:ceiling.width),height:Int32(clamping:ceiling.height))
            let dimensionsChanged = photoOutput.maxPhotoDimensions.width != targetDimensions.width
                || photoOutput.maxPhotoDimensions.height != targetDimensions.height
            let requestedAnalysisFormat = wantsInitialAnalysis && session.outputs.contains(where: { $0 === videoOutput })
                ? Self.selectAnalysisPixelFormat(videoOutput) : nil
            let analysisFormatChanged = requestedAnalysisFormat.map {
                videoOutput.videoSettings[kCVPixelBufferPixelFormatTypeKey as String] as? OSType != $0
            } ?? false
            let needsFinalMutation = tuple.configurationMode == .explicitFormat || session.sessionPreset != .photo
                || chosen.device.videoZoomFactor != 1 || photoOutput.maxPhotoQualityPrioritization != .speed
                || finalConnection?.videoScaleAndCropFactor != 1 || dimensionsChanged || analysisFormatChanged
                || !CapturePipelinePreparation.outputChanges(Self.photoPipelineOutputState(photoOutput, videoOutput)).isEmpty
            do {
                try FinalTupleOperation.configureIfNeeded(needsFinalMutation, begin:self.beginConfigure, commit:self.commitConfigure) {
                    self.retirePreparedPhotoResourcesIfCurrent(photoOutput) {
                        self.lifecycleOwnership.isCurrent(lifecycleAtPreparation)
                            && self.preparationOwnership.isCurrent(preparationToken)
                            && self.resetAuthorityAllowsNativeMutation(operationResetPass)
                    }
                    if tuple.configurationMode == .photoPreset, session.sessionPreset != .photo {
                        guard session.canSetSessionPreset(.photo) else {
                            throw CaptureFailure(kind:.unsupportedCapability(detail:"The selected photo configuration is no longer available."),operation:"prepare.photoPreset")
                        }
                        session.sessionPreset = .photo
                    }
                    if tuple.configurationMode == .explicitFormat || chosen.device.videoZoomFactor != 1 {
                        try chosen.device.lockForConfiguration()
                        defer { chosen.device.unlockForConfiguration() }
                        // Assigning even the same activeFormat would lose photo-preset RAW.
                        if tuple.configurationMode == .explicitFormat { chosen.device.activeFormat = chosen.device.formats[tuple.formatIndex] }
                        if chosen.device.videoZoomFactor != 1 { chosen.device.videoZoomFactor = 1 }
                    }
                    if finalConnection?.videoScaleAndCropFactor != 1 { finalConnection?.videoScaleAndCropFactor = 1 }
                    if photoOutput.maxPhotoQualityPrioritization != .speed { photoOutput.maxPhotoQualityPrioritization = .speed }
                    if dimensionsChanged { photoOutput.maxPhotoDimensions = targetDimensions }
                    if analysisFormatChanged, let requestedAnalysisFormat {
                        videoOutput.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: requestedAnalysisFormat]
                    }
                    let current = {
                        self.lifecycleOwnership.isCurrent(lifecycleAtPreparation)
                            && self.preparationOwnership.isCurrent(preparationToken)
                            && self.resetAuthorityAllowsNativeMutation(operationResetPass)
                    }
                    Self.preparePhotoPipelineOptions(photoOutput, videoOutput, isCurrent: current)
                    Self.prepareAnalysisConnection(videoOutput, isCurrent: current)
                    Self.prepareOriginalConnection(photoOutput, isCurrent: current)
                }
            } catch {
                self.beginConfigure(); session.removeInput(input); self.commitConfigure()
                return .failure((error as? CaptureFailure) ?? AVFoundationFailureMapper.failure(error,operation:"prepare.configureTuple"))
            }

            // G04: requery the FINAL committed configuration. The facts published to
            // the capability snapshot must describe the tuple actually in force, not
            // the initial prepared guesses nor a candidate's borrowed evidence.
            guard let committedIndex = chosen.device.formats.firstIndex(of: chosen.device.activeFormat),
                  chosen.device.activeFormat.supportedMaxPhotoDimensions.contains(where: {
                      Int($0.width) == ceiling.width && Int($0.height) == ceiling.height
                  }) else {
                self.beginConfigure()
                session.removeInput(input)
                self.commitConfigure()
                return .failure(CaptureFailure(kind: .unsupportedCapability(
                    detail: "The committed native format no longer supports the selected photo ceiling."),
                    operation: "prepare.finalFormat"))
            }
            self.recordConfigurationOrderIfNeeded(operation: "finalRawQuery")
            #if DEBUG
            print("TruongCam selected tuple: mode=\(tuple.configurationMode.rawValue), preset=\(session.sessionPreset.rawValue), index=\(tuple.formatIndex), requestedCeiling=\(ceiling.width)x\(ceiling.height), rawFiles=\(photoOutput.availableRawPhotoFileTypes.map(\.rawValue))")
            #endif
            let finalQuery = FinalTupleValidation.validate(
                finalBayerFormats: photoOutput
                    .supportedRawPhotoPixelFormatTypes(for: .dng)
                    .filter { bayerClassifierForDiscovery.isBayerRAW($0) },
                finalFileTypes: photoOutput.availableRawPhotoFileTypes.map(\.rawValue),
                candidateFileTypes: tuple.activeDNGPixelFormats.isEmpty ? [] : [AVFileType.dng.rawValue])

            // I04/J04: the SHARED policy owns the decision, so the rule the tests drive
            // is the rule that ships. An empty final Bayer answer is a real failure and
            // never falls back to the candidate's earlier evidence.
            let publishedBayer: [UInt32]
            let publishedFileTypes: [String]
            switch finalQuery {
            case .rejectNoBayerRAW:
                // L04: the rollback has its OWN balanced pair. The enclosing block was
                // already committed above, so committing again here was unpaired.
                self.beginConfigure()
                session.removeInput(input)
                self.commitConfigure()
                return .failure(CaptureFailure(
                    kind: .unsupportedCapability(
                        detail: "The committed configuration cannot produce a Bayer RAW DNG, so this tuple is not usable."),
                    operation: "prepare.finalRawQuery"))
            case .publish(let bayer, let fileTypes):
                publishedBayer = bayer
                publishedFileTypes = fileTypes
            }

            if tuple.configurationMode == .photoPreset,
               self.lifecycleOwnership.isCurrent(lifecycleAtPreparation),
               self.preparationOwnership.isCurrent(preparationToken),
               self.resetAuthorityAllowsNativeMutation(operationResetPass) {
                self.warmPhotoCeilings.withLock { $0[chosen.device.uniqueID] = WarmPhotoCeilingEvidence(
                    deviceIdentity: chosen.device.uniqueID,
                    formatIdentity: String(describing: ObjectIdentifier(chosen.device.activeFormat)),
                    analysisOutputAttached: session.outputs.contains { $0 === videoOutput },
                    candidateDimensions: currentDimensionMatrix, ceiling: ceiling) }
            }

            // Keep ordinary native preparation (deferred=false), but do not issue
            // optional prepared-settings arrays while repeatedly replacing inputs.
            // Phone evidence shows fast delivery once admitted, plus native resets
            // during these handoffs; an unmeasured hint must not add driver work.
            let finalJPEG = Self.supportsJPEG(photoOutput)
            return .success(CaptureTupleSelection(
                formatIndex: committedIndex,
                dimensions: ceiling,
                rawFormats: publishedBayer,
                notes: tuple.notes + discovery.activationFailures + ["Selected RAW configuration mode: \(tuple.configurationMode.rawValue)."],
                bracketCount: Int(photoOutput.maxBracketedCapturePhotoCount),
                commmittedRawFileTypes: publishedFileTypes,
                configurationMode: tuple.configurationMode,
                jpegSupported: finalJPEG,
                jpegMaximumDimensions: finalJPEG ? ceiling : nil))
        }

        guard lifecycleOwnership.isCurrent(lifecycleAtPreparation), preparationOwnership.isCurrent(preparationToken), resetAuthorityIsCurrent(operationResetPass) else {
            return .failure(CaptureFailure(kind: .cameraInterrupted(detail: "Preparation was superseded by a newer recovery pass."), operation: "prepare.publish"))
        }
        let tuple: CaptureTupleSelection
        switch attachOutcome {
        case .success(let value): tuple = value
        case .failure(let failure):
            preparedSessions.withLock { $0.removeAll() }; processedFallbackCheckedTopologies.withLock { $0.removeAll() }
            warmPhotoCeilings.withLock { $0.removeAll() }
            snapshot = .empty(generation: generation, reason: failure.kind.userDescription)
            return .failure(failure)
        }

        captureConfigurationMode = tuple.configurationMode
        let updatedFacts: [PhysicalCameraCapability] = await sessionQueue.perform {
            #if DEBUG
            let began = ProcessInfo.processInfo.systemUptime
            defer { print("TruongCam timing prepare-capability-publication=\(Int((ProcessInfo.processInfo.systemUptime - began) * 1000))ms") }
            #endif
            guard self.lifecycleOwnership.isCurrent(lifecycleAtPreparation), self.preparationOwnership.isCurrent(preparationToken),
                  self.resetAuthorityAllowsNativeMutation(operationResetPass) else { return [] }
            return prepared.facts.enumerated().compactMap { index, fact in
                guard let baseline = fact.capability else { return nil }
                if index != chosenIndex { return baseline }
                return CameraCapabilityProbe.capability(for:fact.device,selectedFormatIndex:tuple.formatIndex,
                    rawFormats:tuple.rawFormats,rawFileTypes:tuple.commmittedRawFileTypes ?? fact.rawFileTypes,
                    nativeBracketCount:tuple.bracketCount,baseline:baseline)
            }
        }
        guard lifecycleOwnership.isCurrent(lifecycleAtPreparation), preparationOwnership.isCurrent(preparationToken),
              resetAuthorityIsCurrent(operationResetPass), !updatedFacts.isEmpty else {
            return .failure(CaptureFailure(kind:.cameraInterrupted(detail:"Preparation publication was superseded."),operation:"prepare.publish"))
        }

        availableBayerFormats = tuple.rawFormats
        // The final REQUERIED file types describe the configuration actually in force.
        // Falling back to the initial prepared facts would publish evidence for a
        // configuration the session may no longer be using (REVIEW.md H03).
        availableRawFileTypes = tuple.commmittedRawFileTypes ?? prepared.facts[chosenIndex].rawFileTypes
        maximumBracketCount = tuple.bracketCount
        selectedKind = chosenKind

        let bayerSupported: DiscoveryStatus<Bool> = tuple.rawFormats.isEmpty
            ? .unavailable(reason: "The selected format exposes no Bayer RAW pixel format.")
            : .available(true)

        // Discovery choices are not capture authorization. Keep passive rear
        // choices visible on Front, including a process launched directly there.
        // Do not attach/probe those unselected sensors or reuse their RAW facts.
        let rearChoices: [PhysicalCameraCapability] = wantsFront ? await sessionQueue.perform { [self] in
            if let rear = preparedSessions.withLock({ $0["false"] }) {
                return rear.facts.compactMap(\.capability)
            }
            let discovery = AVCaptureDevice.DiscoverySession(deviceTypes: CameraCapabilityProbe.physicalRearDeviceTypes,
                mediaType: .video, position: .back)
            return CameraCapabilityProbe.discoverDevices(discoverySession: discovery).map {
                CameraCapabilityProbe.capability(for: $0, selectedFormatIndex: nil,
                    rawFormats: nil, rawFileTypes: nil, nativeBracketCount: nil)
            }
        } : []

        guard lifecycleOwnership.isCurrent(lifecycleAtPreparation), preparationOwnership.isCurrent(preparationToken),
              resetAuthorityIsCurrent(operationResetPass) else {
            return .failure(CaptureFailure(kind: .operationStalled(detail: "A newer camera operation owns discovery."), operation: "prepare.choices"))
        }
        snapshot = CameraCapabilitySnapshot(
            generation: generation,
            hardwareModel: DeviceProvenance.hardwareModel,
            osVersion: DeviceProvenance.osVersion,
            sdkVersion: DeviceProvenance.sdkVersion,
            physicalCameras: updatedFacts + rearChoices,
            selectedCameraKind: chosenKind,
            configuredPhotoDimensions: tuple.dimensions,
            configuredPhotoDimensionsEvidence: "requested ceiling from the selected format's supportedMaxPhotoDimensions; the actual RAW output size is measured after a capture",
            previewAnalysisFormat: nil,
            bayerCaptureSupported: bayerSupported,
            probeTimestampUTC: Date(),
            notes: tuple.notes + [
                "The advertised ceiling is a request policy, never a measured RAW output size.",
                "Actual RAW dimensions stay unknown until a capture on this device is inspected.",
            ])

        snapshot.frontHEIFSupported = tuple.frontHEIFSupported
        snapshot.jpegSupported = tuple.jpegSupported
        snapshot.jpegMaximumDimensions = tuple.jpegMaximumDimensions
        installObservers()
        return .success(snapshot)
    }

    func start() async -> Result<Void, CaptureFailure> {
        // AG01: the lifecycle identity this start belongs to, captured BEFORE any suspension.
        // A stop/reset that completes while this start is in flight makes it obsolete, and the
        // obsolete start must not set isConfigured, install the preview or report success.
        let startIdentity = identity.snapshot()
        let startToken = lifecycleOwnership.begin()
        let modeAtStart = captureConfigurationMode
        let previewPause = await displayBridge.nativeAccessGate.pauseAndDrainFrames()
        defer { previewPause.release() }
        let outcome: Result<Void, CaptureFailure> = await sessionQueue.perform { [session, photoOutput, videoOutput] in
            guard self.identity.isCurrent(startIdentity), self.lifecycleOwnership.isCurrent(startToken) else {
                return .failure(CaptureFailure(kind: .operationStalled(detail: "Start was superseded before native execution."), operation: "start.native"))
            }
            guard session.inputs.contains(where: { $0 is AVCaptureDeviceInput }) else {
                return .failure(CaptureFailure(
                    kind: .unsupportedCapability(detail: "No camera input is attached."),
                    operation: "start"))
            }
            do {
                // Configure and commit the block first...
                #if DEBUG
                let configurationBegan = ProcessInfo.processInfo.systemUptime
                #endif
                let configurationBefore = self.finalTupleOperation.currentTransaction
                defer {
                    // A throwing configuration still commits its balanced native
                    // block. Invalidate old preview bindings on that path too.
                    if self.finalTupleOperation.currentTransaction != configurationBefore {
                        self.displayBridge.nativeAccessGate.noteNativeMutation()
                    }
                }
                try Self.configureForBayerRAW(
                    session: session, photoOutput: photoOutput, videoOutput: videoOutput,
                    accounting: self.finalTupleOperation, configurationMode: modeAtStart,
                    retirePhotoResources: { self.retirePreparedPhotoResourcesIfCurrent(photoOutput) {
                        self.identity.isCurrent(startIdentity) && self.lifecycleOwnership.isCurrent(startToken)
                    } },
                    isCurrent: { self.identity.isCurrent(startIdentity) && self.lifecycleOwnership.isCurrent(startToken) })
                #if DEBUG
                print("TruongCam timing start-configuration=\(Int((ProcessInfo.processInfo.systemUptime - configurationBegan) * 1000))ms")
                #endif
                // ...and only then start, outside any open configuration.
                Self.startSessionAfterConfiguration(session)
            } catch {
                return .failure(AVFoundationFailureMapper.failure(error, operation: "start"))
            }
            return .success(())
        }
        if case .success = outcome {
            // AG01: re-validated AFTER the native await and BEFORE the effects. An explicit
            // stop (or a newer lifecycle) that completed meanwhile remains authoritative.
            guard identity.isCurrent(startIdentity), lifecycleOwnership.isCurrent(startToken) else {
                // AI01: validated at the FIRST admission/mutation boundary, not only at the
                // final return. A newer start does not change PublicationIdentity, so the token
                // is what makes stale A a no-effect failure here.
                return .failure(CaptureFailure(
                    kind: .operationStalled(
                        detail: "The camera start was superseded before it could be admitted."),
                    operation: "start.admission"))
            }
            isConfigured = true
            // The preview layer needs the display handle once the session exists.
            displayBridge.install(session, rotationAngles: sensorRotations.withLock { $0 })
            // J04/M04: revalidate the RAW facts against the configuration now in force.
            // This runs OUTSIDE any open configuration and only after the topology
            // settled. A configuration that can no longer produce a Bayer RAW DNG makes
            // the start FAIL rather than reporting success with a stale snapshot.
            let startDisposition = await FinalTupleAdmission.validateCurrentTuple(
                isCurrent: { self.identity.isCurrent(startIdentity) && self.lifecycleOwnership.isCurrent(startToken) },
                query: { await self.refreshConfirmedFactsAfterTopologyChange() })
            switch FinalTupleAdmission.action(
                for: CapabilityRevocation.decision(for: startDisposition)) {
            case .failWithoutStopping:
                // A newer configuration took over while this start was validating: this
                // older start neither stops the newer graph nor revokes its capability.
                return .failure(CaptureFailure(
                    kind: .operationStalled(
                        detail: "Camera configuration changed while starting. Retry camera."),
                    operation: "start.finalTuple"))
            case .proceed:
                break
            case .stopAndFail:
                // AH01: validated BEFORE the stop/readiness effects. A refusal that was valid
                // for THIS start before the await must not stop a newer start B afterwards.
                guard identity.isCurrent(startIdentity), lifecycleOwnership.isCurrent(startToken) else {
                    return .failure(CaptureFailure(
                        kind: .operationStalled(
                            detail: "The camera start was superseded before it could be reported."),
                        operation: "start.finalReturn"))
                }
                let nestedStopToken = lifecycleOwnership.current
                await stopAsNestedOperation()
                // AJ02: the nested Stop belongs to THIS start, so it does not obsolete it. Only a
                // DIFFERENT lifecycle operation taking over (which advances the token further)
                // makes this start obsolete; otherwise the genuine invalid tuple is reported.
                guard lifecycleOwnership.isCurrent(nestedStopToken) else {
                    return .failure(CaptureFailure(
                        kind: .operationStalled(
                            detail: "The camera start was superseded before it could be reported."),
                        operation: "start.finalReturn"))
                }
                isConfigured = false
                return .failure(CaptureFailure(
                    kind: .unsupportedCapability(
                        detail: "The running configuration no longer supports a Bayer RAW DNG."),
                    operation: "start.finalTuple"))
            }
            // AG01: the FINAL query is itself an await. A Stop (or newer lifecycle) that
            // completed during it remains authoritative, so this start must not report the
            // earlier success over a graph that is no longer running.
            guard identity.isCurrent(startIdentity), lifecycleOwnership.isCurrent(startToken) else {
                // AH01: an obsolete start is a NO-EFFECT failure. It must not clear the
                // configured flag, because that state now belongs to a newer start B.
                return .failure(CaptureFailure(
                    kind: .operationStalled(
                        detail: "The camera start was superseded before it could be reported."),
                    operation: "start.finalReturn"))
            }
        }
        if case .success = outcome { reconcileHardwareControlsAfterNativeChange() }
        return outcome
    }

    /// Republishes the PUBLIC capability with the facts the final query just confirmed.
    ///
    /// P03: this is the publication the model/readiness/admission consumers read, so a
    /// topology change cannot leave them on a stale snapshot.
    /// Revokes the published capability ONLY if the captured configuration is still current.
    ///
    /// AC03: the transaction is re-validated synchronously in this actor turn, immediately
    /// before the revocation, so a newer configuration that finished while the rejection
    /// callback was in flight is not revoked by the obsolete pass.
    private func revokeIfCurrent(transactionAtQuery: UInt64) -> Bool {
        guard finalTupleOperation.currentTransaction == transactionAtQuery else { return false }
        revokePublishedCapability(
            reason: "The running configuration cannot produce a Bayer RAW DNG.")
        return true
    }

    /// Publishes the committed facts ONLY if no newer configuration has taken over.
    ///
    /// AB03: the transaction is re-validated synchronously in this actor turn, immediately
    /// before the mutation, so a configuration that finished while the callback was in flight
    /// cannot be overwritten by the older pass.
    private func publishConfirmedFactsIfCurrent(
        from facts: FinalTupleOperation.FinalFacts,
        transactionAtQuery: UInt64
    ) -> Bool {
        guard finalTupleOperation.currentTransaction == transactionAtQuery else { return false }
        publishConfirmedFacts(from: facts)
        return true
    }

    /// Publishes exactly the facts the final query reported for the committed tuple (X03).
    private func publishConfirmedFacts(from facts: FinalTupleOperation.FinalFacts) {
        maximumBracketCount = facts.bracketCount
        publishConfirmedFacts(
            bayerFormats: facts.bayer,
            fileTypes: facts.fileTypes,
            activeDimensions: facts.dimensions,
            bracketCount: facts.bracketCount,
            activeFormatSubType: facts.formatSubType,
            activeRequestCeiling: facts.requestCeiling,
            activeExposureLimits: facts.exposureLimits,
            activePriorityCombinations: facts.priorityCombinations,
            activeCleanAperture: facts.cleanAperture,
            activeFrameRates: facts.frameRates)
    }

    private func publishConfirmedFacts(
        bayerFormats: [UInt32],
        fileTypes: [String],
        activeDimensions: PixelDimensions? = nil,
        bracketCount: Int? = nil,
        activeFormatSubType: String? = nil,
        activeRequestCeiling: [PixelDimensions]? = nil,
        activeExposureLimits: ExposureLimits? = nil,
        activePriorityCombinations: Set<ExposureModeKind>? = nil,
        activeCleanAperture: PixelDimensions?? = nil,
        activeFrameRates: [ClosedRange<Double>]? = nil
    ) {
        availableBayerFormats = bayerFormats
        availableRawFileTypes = fileTypes
        guard let chosen = snapshot.selectedCameraKind,
              let index = snapshot.physicalCameras.firstIndex(where: { $0.kind == chosen })
        else { return }
        snapshot.physicalCameras[index].bayerRAWDiscovery = .available(bayerFormats)
        snapshot.physicalCameras[index].rawFileTypeDiscovery = .available(fileTypes)
        if let formatIndex = snapshot.physicalCameras[index].selectedFormatIndex,
           snapshot.physicalCameras[index].formats.indices.contains(formatIndex) {
            snapshot.physicalCameras[index].formats[formatIndex].bayerPixelFormats = bayerFormats
            snapshot.physicalCameras[index].formats[formatIndex].rawFileTypes = fileTypes
            // R03: the ACTIVE format's dimensions are republished with the other facts.
            // T03: the row ADOPTS the active format's identity, dimensions and request
            // ceiling, rather than keeping an older format's identity under new dimensions.
            if let activeDimensions, let activeFormatSubType {
                snapshot.physicalCameras[index].formats[formatIndex].formatIdentifier =
                    "active:\(activeDimensions.width)x\(activeDimensions.height):\(activeFormatSubType)"
                snapshot.physicalCameras[index].formats[formatIndex].videoDimensions =
                    activeDimensions
            }
            if let activeRequestCeiling {
                snapshot.physicalCameras[index].formats[formatIndex].supportedMaxPhotoDimensions =
                    activeRequestCeiling
            }
            if let activeExposureLimits {
                // U03: the row adopts the ACTIVE format's own limits instead of keeping the
                // previous format's ISO/duration claims under a changed identity.
                snapshot.physicalCameras[index].formats[formatIndex].exposureLimits =
                    activeExposureLimits
            }
            if let activePriorityCombinations {
                snapshot.physicalCameras[index].formats[formatIndex]
                    .supportedPriorityCombinations = activePriorityCombinations
            }
            if let activeCleanAperture {
                snapshot.physicalCameras[index].formats[formatIndex]
                    .cleanApertureDimensions = activeCleanAperture
            }
            if let activeFrameRates {
                snapshot.physicalCameras[index].formats[formatIndex]
                    .videoFrameRateRanges = activeFrameRates
            }
        }
        if let bracketCount {
            // S03: the PUBLIC discovery is what downstream consumers read, so the confirmed
            // native bracket limit is published there rather than only in the adapter field.
            snapshot.physicalCameras[index].nativeBracketCountDiscovery = .available(bracketCount)
        }
        snapshot.bayerCaptureSupported = bayerFormats.isEmpty
            ? .unavailable(reason: "The current configuration exposes no Bayer RAW pixel format.")
            : .available(true)
    }

    /// Withdraws the published capability so consumers cannot see stale support.
    ///
    /// P03: an empty/again-rejected final answer after a topology change must reach the
    /// model and admission, not only the private arrays.
    private func revokePublishedCapability(reason: String) {
        availableBayerFormats = []
        availableRawFileTypes = []
        maximumBracketCount = 0
        snapshot.bayerCaptureSupported = .unavailable(reason: reason)
        guard let chosen = snapshot.selectedCameraKind,
              let index = snapshot.physicalCameras.firstIndex(where: { $0.kind == chosen })
        else { return }
        snapshot.physicalCameras[index].bayerRAWDiscovery =
            .unavailable(reason: reason)
        snapshot.physicalCameras[index].rawFileTypeDiscovery =
            .unavailable(reason: reason)
        snapshot.physicalCameras[index].nativeBracketCountDiscovery =
            .unavailable(reason: reason)
    }

    /// Re-queries the committed configuration's RAW facts after a topology/speed change.
    ///
    /// REVIEW.md J04: `configureForBayerRAW` sets the preset and output topology inside
    /// `start`, so the facts confirmed during `prepare` described an earlier
    /// configuration. They are requeried here, and an empty answer REVOKES the published
    /// RAW support rather than silently reusing the superseded facts.
    @discardableResult
    private func refreshConfirmedFactsAfterTopologyChange() async -> FinalTupleOperation.Disposition {
        // AD03: the configuration identity this pass is acting for, captured BEFORE the run so
        // the consumer below can tell whether a newer configuration has taken over by the time
        // the disposition is acknowledged.
        let owner = identity.snapshot()
        let generationAtQuery = generation
        let transactionAtProcessedQuery = finalTupleOperation.currentTransaction
        let processed = await sessionQueue.perform { [session, photoOutput] in
            guard let device = session.inputs.compactMap({ ($0 as? AVCaptureDeviceInput)?.device }).first,
                  photoOutput.connection(with: .video) != nil else {
                return (jpeg: false, frontHEIF: false, dimensions: Optional<PixelDimensions>.none)
            }
            let maximum = photoOutput.maxPhotoDimensions
            let legalMaximum = maximum.width > 0 && maximum.height > 0
                && device.activeFormat.supportedMaxPhotoDimensions.contains {
                    $0.width == maximum.width && $0.height == maximum.height
                }
            let jpeg = legalMaximum && Self.supportsJPEG(photoOutput)
            return (jpeg: jpeg,
                frontHEIF: legalMaximum && device.position == .front && Self.supportsHEIF(photoOutput),
                dimensions: jpeg ? PixelDimensions(width: Int(maximum.width), height: Int(maximum.height)) : nil)
        }
        guard identity.isCurrent(owner), generation == generationAtQuery,
              finalTupleOperation.currentTransaction == transactionAtProcessedQuery else { return .superseded }
        snapshot.jpegSupported = processed.jpeg
        snapshot.jpegMaximumDimensions = processed.dimensions
        snapshot.frontHEIFSupported = availableBayerFormats.isEmpty && processed.frontHEIF
        if availableBayerFormats.isEmpty {
            return processed.jpeg || snapshot.frontHEIFSupported ? .published : .refused
        }
        let transactionBeforeRun = finalTupleOperation.currentTransaction
        let disposition = await finalTupleOperation.run(port: FinalTupleOperation.Port(
            beginConfiguration: {},
            commitConfiguration: {},
            queryFinalTuple: { [weak self] in
                await self?.nativeFinalFacts() ?? FinalTupleOperation.FinalFacts()
            },
            // The real rollback: a refusal revokes the published capability rather than
            // leaving the previous claim in force (Y03).
            rollbackConfiguration: { [weak self] transactionAtQuery in
                await self?.revokeIfCurrent(transactionAtQuery: transactionAtQuery) ?? false
            },
            publish: { [weak self] facts, transactionAtQuery in
                await self?.publishConfirmedFactsIfCurrent(
                    from: facts, transactionAtQuery: transactionAtQuery) ?? false
            },
            fail: { _, _ in }
        ), candidateFileTypes: availableRawFileTypes)
        switch disposition {
        case .published:
            return .published
        case .superseded:
            // AA03/AC03: a newer configuration owns the capability, so this obsolete query
            // neither publishes NOR revokes it — B's valid facts survive A's late return.
            return .superseded
        case .refused, .configureFailed:
            // AD03: re-validated SYNCHRONOUSLY here, immediately before the mutation. If a newer
            // configuration registered while this pass was awaiting its Core verdict, this pass
            // is obsolete and must not revoke the newer capability.
            guard finalTupleOperation.currentTransaction == transactionBeforeRun else {
                return .superseded
            }
            // A genuinely invalid tuple REVOKES rather than retaining the previous claim.
            revokePublishedCapability(
                reason: "The running configuration cannot produce a Bayer RAW DNG.")
            // RAW remains revoked. A valid independent processed capability can
            // keep preview running, but can authorize only its explicit intent.
            snapshot.frontHEIFSupported = processed.frontHEIF
            return snapshot.jpegSupported || snapshot.frontHEIFSupported ? .published : .refused
        }
    }

    /// The native final query, on the session queue, reporting the WHOLE committed tuple.
    private func nativeFinalFacts() async -> FinalTupleOperation.FinalFacts {
        await sessionQueue.perform { [session, photoOutput] in
            // Never query inside an open configuration.
            guard let device = session.inputs
                .compactMap({ ($0 as? AVCaptureDeviceInput)?.device })
                .first else {
                return FinalTupleOperation.FinalFacts()
            }
            let bayer = photoOutput
                .supportedRawPhotoPixelFormatTypes(for: .dng)
                .filter { bayerClassifierForDiscovery.isBayerRAW($0) }
            // R03: the ACTIVE configuration's own bracket limit, requeried with the RAW
            // facts rather than assumed from the pre-start answer.
            let bracketCount = Int(photoOutput.maxBracketedCapturePhotoCount)
            // The ACTIVE format's real dimensions, requeried with the other final facts.
            let activeFormat = device.activeFormat
            let dimensions = CMVideoFormatDescriptionGetDimensions(
                activeFormat.formatDescription)
            // The active format's own identity components and its REQUEST CEILING (the max
            // photo dimensions this format supports — not a measured RAW size).
            let subType = FourCC.string(
                from: activeFormat.formatDescription.mediaSubType.rawValue)
            let ceiling = activeFormat.supportedMaxPhotoDimensions.map {
                PixelDimensions(width: Int($0.width), height: Int($0.height))
            }
            // U03: the ACTIVE format's own exposure limits, so a changed format cannot keep
            // the previous format's ISO/duration claims.
            var activeCombinations: Set<ExposureModeKind> = [.auto]
            if device.isExposureModeSupported(.custom) {
                if activeFormat.supportsExposureModeCustom(
                    lensAperture: AVCaptureDevice.currentLensAperture,
                    duration: AVCaptureDevice.currentExposureDuration,
                    iso: AVCaptureDevice.autoISO) {
                    activeCombinations.insert(.shutterPriority)
                }
                if activeFormat.supportsExposureModeCustom(
                    lensAperture: AVCaptureDevice.currentLensAperture,
                    duration: AVCaptureDevice.autoExposureDuration,
                    iso: AVCaptureDevice.currentISO) {
                    activeCombinations.insert(.isoPriority)
                }
                if activeFormat.supportsExposureModeCustom(
                    lensAperture: AVCaptureDevice.currentLensAperture,
                    duration: AVCaptureDevice.currentExposureDuration,
                    iso: AVCaptureDevice.currentISO) {
                    activeCombinations.insert(.manual)
                }
            }
            let activeCleanAperture: PixelDimensions? = {
                let aperture = CMVideoFormatDescriptionGetCleanAperture(
                    activeFormat.formatDescription, originIsAtTopLeft: true)
                return PixelDimensions(width: Int(aperture.width),
                                       height: Int(aperture.height))
            }()
            let activeFrameRates = activeFormat.videoSupportedFrameRateRanges.map {
                Double($0.minFrameRate)...Double($0.maxFrameRate)
            }
            let activeLimits = ExposureLimits(
                minDurationSeconds: activeFormat.minExposureDuration.seconds,
                maxDurationSeconds: activeFormat.maxExposureDuration.seconds,
                minISO: Double(activeFormat.minISO),
                maxISO: Double(activeFormat.maxISO),
                minBiasEV: Double(device.minExposureTargetBias),
                maxBiasEV: Double(device.maxExposureTargetBias))
            return FinalTupleOperation.FinalFacts(bayer: bayer,
                    fileTypes: photoOutput.availableRawPhotoFileTypes.map(\.rawValue),
                    bracketCount: bracketCount,
                    dimensions: PixelDimensions(width: Int(dimensions.width),
                                                height: Int(dimensions.height)),
                    formatSubType: subType,
                    requestCeiling: ceiling,
                    exposureLimits: activeLimits,
                    priorityCombinations: activeCombinations,
                    cleanAperture: activeCleanAperture,
                    frameRates: activeFrameRates)
        }

    }

    /// Prepares only the explicitly selected JPEG request on an already-running,
    /// quiescent graph. This is an optional allocation hint, never capture or
    /// readiness evidence, and the shutter never awaits its completion.
    func prepareCaptureFormat(_ format: CaptureFileFormat, generation requestedGeneration: ConfigurationGeneration) async {
        let revision = formatPreparationIntent.withLock { value in
            let revision = (value?.revision ?? 0) &+ 1
            value = (revision, format, requestedGeneration)
            return revision
        }
        if format != .jpeg {
            // Keep ownership so a later topology replacement still retires the
            // actual SDK hint. Mark this optional preparation unusable to allow
            // a fresh JPEG choice to reserve a new completion identity.
            if let pending = photoResourcePreparation.snapshot, pending.phase == .preparing {
                _ = photoResourcePreparation.complete(pending.token, prepared: false)
            }
            return
        }
        guard format == .jpeg, !Task.isCancelled, requestedGeneration == generation,
              isConfigured, snapshot.jpegSupported,
              let camera = selectedKind, let dimensions = snapshot.jpegMaximumDimensions,
              inFlightRegistry.inFlightCount == 0 else { return }
        let lifecycle = lifecycleOwnership.current, preparation = preparationOwnership.current
        let resetPass = recoveryPassToken
        // Resource preparation can briefly take native graph locks. Keep the
        // main-thread preview connection synchronizer out of the SDK issue only;
        // do not wait for allocation or suppress live frames through completion.
        let previewPause = await displayBridge.nativeAccessGate.pauseAndDrainFrames()
        defer { previewPause.release() }
        guard !Task.isCancelled else { return }
        await sessionQueue.perform { [self, session, photoOutput] in
            let isCurrent: @Sendable () -> Bool = {
                self.formatPreparationIntent.withLock { value in
                    value?.revision == revision && value?.format == .jpeg
                        && value?.generation == requestedGeneration
                } && self.generationBox.withLock { $0 } == requestedGeneration
                    && self.lifecycleOwnership.isCurrent(lifecycle)
                    && self.preparationOwnership.isCurrent(preparation)
                    && self.resetAuthorityAllowsNativeMutation(resetPass)
                    && self.inFlightRegistry.inFlightCount == 0
            }
            guard isCurrent(), session.isRunning,
                  self.finalTupleOperation.configurationDepth == 0,
                  let device = session.inputs.compactMap({ ($0 as? AVCaptureDeviceInput)?.device }).first,
                  CameraCapabilityProbe.kind(for: device.deviceType, position: device.position) == camera else { return }
            let committed = PixelDimensions(width: Int(photoOutput.maxPhotoDimensions.width),
                                             height: Int(photoOutput.maxPhotoDimensions.height))
            guard let settings = try? NativeJPEGPhotoSettings.make(requestedDimensions: dimensions,
                maximumDimensions: committed, supportedFileTypes: photoOutput.availablePhotoFileTypes,
                supportedCodecs: photoOutput.supportedPhotoCodecTypes(for: .jpg)) else { return }
            let signature = PhotoResourcePreparationOwner.Signature(
                deviceIdentity: device.uniqueID,
                formatIdentity: "\(requestedGeneration):\(ObjectIdentifier(device.activeFormat))",
                rawPixelFormat: 0, rawFileType: AVFileType.jpg.rawValue, dimensions: dimensions)
            NativeJPEGPhotoSettings.prepareResources(settings, signature: signature,
                owner: self.photoResourcePreparation, isCurrent: isCurrent) { settings, completion in
                photoOutput.setPreparedPhotoSettingsArray(settings, completionHandler: completion)
            }
        }
    }

    /// Opens a native configuration AND records it in the owned operation, so the depth the
    /// final query validates against is the configuration the adapter actually opened.
    nonisolated private func beginConfigure() {
        displayBridge.nativeAccessGate.noteNativeMutation()
        configurer.beginConfiguration()
        finalTupleOperation.noteConfigurationOpened()
    }

    /// This runs on the session queue inside an already-needed configuration.
    /// The SDK retains prepared settings through commits; an old lens's RAW
    /// pixel type/ceiling must not participate in the replacement graph build.
    @discardableResult
    nonisolated private func retirePreparedPhotoResourcesIfCurrent(_ output: AVCapturePhotoOutput, _ isCurrent: () -> Bool) -> Bool {
        Self.retirePreparedPhotoResources(output, owner: photoResourcePreparation,
            isCurrent: isCurrent)
    }

    @discardableResult
    static func retirePreparedPhotoResources(_ output: AVCapturePhotoOutput,
                                             owner: PhotoResourcePreparationOwner,
                                             isCurrent: () -> Bool) -> Bool {
        guard isCurrent() else { return false }
        // Invalidate before SDK issue: cancellation can invoke the outgoing
        // callback immediately. A late callback then has no current ownership.
        let hadOwnedHint = owner.retire()
        // A new output normally has default processed-photo preparation. Leave
        // that alone on cold startup; only outgoing app-owned or untracked RAW
        // preparation needs retirement before replacing a RAW tuple.
        if hadOwnedHint || output.preparedPhotoSettingsArray.contains(where: { $0.rawPhotoPixelFormatType != 0 }) {
            guard isCurrent() else { return false }
            output.setPreparedPhotoSettingsArray([], completionHandler: nil)
            #if DEBUG
            print("TruongCam raw-resources: retired outgoing tuple hint")
            #endif
        }
        return isCurrent()
    }

    /// Balances `beginConfigure` and records the commit in the owned operation.
    nonisolated private func commitConfigure() {
        #if DEBUG
        let began=ProcessInfo.processInfo.systemUptime
        defer {
            let ms=Int((ProcessInfo.processInfo.systemUptime-began)*1000)
            if ms>=16 { print("TruongCam timing graph-commit=\(ms)ms main=\(Thread.isMainThread)") }
        }
        #endif
        #if DEBUG
        print("TruongCam native-graph-commit begin")
        #endif
        configurer.commitConfiguration()
        finalTupleOperation.noteConfigurationCommitted()
    }

    /// Rebuilds the graph after a reset through the SAME production path a first-time prepare
    /// uses, revalidating the controls under the NEW generation (Z02).
    private func rebuildAfterReset(
        passToken: UInt64
    ) async -> SubmissionRecoveryChain.RebuildResult {
        // AC02: an obsolete pass must not prepare again over a newer verified graph.
        guard recoveryPassToken == passToken else { return .prepareFailed }
        // AJ03: the rebuild SEQUENCE is Core-owned; this method supplies the native port.
        let outcome = await ResetRebuild.run(port: ResetRebuild.Port(
            prepare: { [weak self] in await self?.prepareForRebuild(passToken: passToken) ?? false },
            revalidateControls: { [weak self] in
                await self?.revalidateControlsAfterRebuild(passToken: passToken) ?? false
            }))
        switch outcome {
        case .rebuilt: return .verified
        case .prepareFailed: return .prepareFailed
        case .controlsFailed: return .controlsFailed
        }
    }

    /// Native preparation for a rebuild. Reports success; the FAILURE disclosure is published
    /// here because it is actionable, but the SEQUENCE is owned by `ResetRebuild` (AJ03).
    /// The generation bump performed ON the actor's executor (AM02/AM03).
    /// AO02: the initiating RESET pass when this call is reset-owned; `nil` for an ORDINARY user
    /// AP01: the initiating reset pass is a PER-CALL value, never ambient actor state. `nil` means
    /// the call is ORDINARY and must be authorized independently of any other call's context.
    private func resetAuthorityIsCurrent(_ ownedByReset: UInt64?) -> Bool {
        guard let pass = ownedByReset else { return true }
        return recoveryPassToken == pass
    }

    nonisolated private func resetAuthorityAllowsNativeMutation(_ pass: UInt64?) -> Bool {
        guard let pass else { return true }
        return liveRecoveryPass.withLock { $0 == pass }
    }

    private func bumpConfigurationGeneration(ownedBy passToken: UInt64) async {
        guard recoveryPassToken == passToken else { return }
        generation = ConfigurationGeneration.next(generation)
    }

    /// Whether `passToken` still owns the recovery lifecycle, read ON the actor's executor.
    private func isCurrentRecoveryPass(_ passToken: UInt64) async -> Bool {
        recoveryPassToken == passToken
    }

    /// Publishes the actionable rebuild failure ON the actor's executor.
    private func discloseRebuildFailure(_ detail: String, ownedBy passToken: UInt64) async {
        guard recoveryPassToken == passToken else { return }
        setCondition(.failed(.cameraInterrupted(detail: detail)))
    }

    private func prepareForRebuild(passToken: UInt64) async -> Bool {
        // AM03: the ORDERING and ownership guards are Core-owned, so the verifier runs this
        // algorithm; the native preparation is supplied as a narrow port.
        return await ResetRebuildSteps.prepare(
            passToken: passToken,
            bumpGeneration: { [self] _ in
                await self.bumpConfigurationGeneration(ownedBy: passToken)
            },
            isCurrentPass: { [self] _ in await self.isCurrentRecoveryPass(passToken) },
            prepare: { [self] _ in
                switch await self.prepare(desiredCamera: self.lastDesiredCamera, ownedByReset: passToken) {
                case .success: return .success(())
                case .failure(let failure): return .failure(failure)
                }
            },
            discloseFailure: { [self] detail, token in
                await self.discloseRebuildFailure(detail, ownedBy: token)
            })
    }

    /// Re-applies and verifies the in-process controls under the NEW generation.
    private func revalidateControlsAfterRebuild(passToken: UInt64) async -> Bool {
        let applied = lastAppliedInstruction ?? NativeControlInstruction(
            exposure: .auto,
            biasEV: 0,
            focus: FocusIntent(mode: .continuousAuto, position: nil, pointOfInterest: nil),
            whiteBalance: WhiteBalanceIntent(mode: .auto, temperatureAndTint: nil))
        let revision = controlRevision
        return await ResetRebuildSteps.revalidateControls(
            passToken: passToken,
            isCurrentPass: { [self] _ in await self.isCurrentRecoveryPass(passToken) },
            applyControls: { [self] _ in
                switch await self.applyControls(
                    revision: revision,
                    exposure: applied.exposure,
                    biasEV: applied.biasEV,
                    focus: applied.focus,
                    whiteBalance: applied.whiteBalance, ownedByReset: passToken) {
                case .success: return .success(())
                case .failure(let failure): return .failure(failure)
                }
            },
            discloseFailure: { [self] detail, token in
                await self.discloseRebuildFailure(detail, ownedBy: token)
            })
    }

    /// Publishes the actionable disclosure for work still outstanding after a rebuild.
    /// Whether `passToken` still owns the recovery lifecycle (AD02).
    private func isCurrentRecoveryPass(_ passToken: UInt64) -> Bool {
        recoveryPassToken == passToken
    }

    private func reopenAdmissionAfterReset(passToken: UInt64) {
        guard recoveryPassToken == passToken else { return }
        setCondition(.reconfiguring)
    }

    private func discloseOutstandingAfterReset(_ count: Int, passToken: UInt64) {
        // An obsolete pass must not disclose a stale count over a newer state.
        guard recoveryPassToken == passToken else { return }
        setCondition(.failed(.cameraInterrupted(
            detail: "The media-services reset left \(count) submitted capture(s) outstanding; the camera rebuilt without them.")))
    }

    func stop() async {
        // Z01/Y01: terminal invalidation is SYNCHRONOUS AT THE STOP ENTRY, before the first
        // suspension below. Bumping both sequences here makes every in-flight command and
        // readback obsolete immediately, so neither can commit a stale result through the
        // session-queue hop or any later await, even with an unchanged generation.
        identity.noteTerminal()
        // AF02: an explicit stop also obsoletes any IN-FLIGHT recovery pass. Without this, a
        // reset suspended inside native prepare still matched its own pass token after stop
        // completed, then issued controls and reopened the condition over a stopped camera.
        recoveryPassToken &+= 1
        liveRecoveryPass.withLock { $0 = recoveryPassToken }
        let stopEntryToken = lifecycleOwnership.current
        // AQ01: the RESET/publication authority captured at Stop ENTRY. A reset does not begin a
        // lifecycle operation, so the lifecycle token alone cannot tell this Stop that a newer reset
        // has taken over. Carried into each native and actor cleanup effect below.
        let resetPassAtStopEntry = recoveryPassToken
        let ownerAtStopEntry = await applicationOwner.ownershipSnapshot
        // AJ01: re-validated immediately AFTER the owner await and BEFORE any native mutation.
        // A newer start that took over during that await makes this Stop obsolete here, so it
        // never enqueues its native stop over B.
        guard lifecycleOwnership.isCurrent(stopEntryToken), recoveryPassToken == resetPassAtStopEntry else { return }
        let stopToken = lifecycleOwnership.begin()
        // AL01/AL02: the ORDERED cleanup is Core-owned, so the shipping Stop and a registered test
        // run the same algorithm. Ownership is re-validated at EVERY boundary inside the sequencer;
        // no mutation can belong to an operation that has already been superseded.
        _ = await StopSequencer.run(
            ownership: lifecycleOwnership,
            token: stopToken,
            effects: StopSequencer.Effects(
                performNativeStop: { [session, self] in
                    let previewPause = await self.displayBridge.nativeAccessGate.pauseAndDrainFrames()
                    defer { previewPause.release() }
                    // The token is re-validated INSIDE the native-queue hop, at the mutation.
                    await self.sessionQueue.perform {
                        guard self.lifecycleOwnership.isCurrent(stopToken) else { return }
                        // AQ01: the RESET authority too, so an obsolete Stop cannot stop the newer
                        // graph after a reset has taken over.
                        guard self.liveRecoveryPass.withLock({ $0 }) == resetPassAtStopEntry else { return }
                        if session.isRunning { session.stopRunning() }
                    }
                },
                clearServiceState: { [self] in
                    guard self.liveRecoveryPass.withLock({ $0 }) == resetPassAtStopEntry else { return }
                    await self.clearStoppedGraphState(ownedBy: stopToken, resetPass: resetPassAtStopEntry)
                },
                settleOwner: { [self] in
                    // AN01: conditional AT the owner mutation, not merely checked around it.
                    await self.applicationOwner.endSettlement(
                        ifOwnedBy: ownerAtStopEntry.current,
                        authorityIsCurrent: { [self] in
                            self.lifecycleOwnership.isCurrent(stopToken) && self.liveRecoveryPass.withLock { $0 == resetPassAtStopEntry }
                        })
                },
                // AI02/AJ02: finished only if the FULL ownership (accepted AND pending) is
                // unchanged, so neither a newer accepted NOR a newer pending application dies.
                finishOwnerIfUnchanged: { [self] in
                    await self.applicationOwner.finish(ifUnchangedSince: ownerAtStopEntry,
                        authorityIsCurrent: { [self] in
                            self.lifecycleOwnership.isCurrent(stopToken) && self.liveRecoveryPass.withLock { $0 == resetPassAtStopEntry }
                        })
                },
                clearConfigured: { [self] in
                    await self.clearConfiguredState(ownedBy: stopToken, resetPass: resetPassAtStopEntry)
                }))
    }

    /// Stops the graph on behalf of the CURRENT lifecycle operation without obsoleting it.
    ///
    /// AJ02: a nested Stop is part of the operation that invoked it, so it must not advance the
    /// lifecycle token — otherwise that operation's own ownership check necessarily fails and a
    /// genuinely invalid tuple is misreported as supersession.
    /// Clears the stopped graph's service state ON the actor's executor (AM02).
    private func clearStoppedGraphState(ownedBy token: UInt64, resetPass: UInt64) async {
        guard lifecycleOwnership.isCurrent(token) else { return }
        // AQ01: an obsolete Stop must not clear the NEWER reset's recorded failure condition.
        guard liveRecoveryPass.withLock({ $0 }) == resetPass else { return }
        removeObservers()
        // An explicit stop clears any recorded interruption: the caller has asked for a known
        // state. Publish it too: a newly attached observer must not replay the
        // pre-stop failure from the broadcaster over a successfully reopened graph.
        setCondition(.idle)
        displayBridge.clear()
    }

    /// AG01: a stopped graph is not configured. Leaving this true advertised readiness for a
    /// camera that is no longer running. Performed ON the actor's executor (AM02).
    private func clearConfiguredState(ownedBy token: UInt64, resetPass: UInt64) async {
        guard lifecycleOwnership.isCurrent(token) else { return }
        guard liveRecoveryPass.withLock({ $0 }) == resetPass else { return }
        lastBoundApplication = nil
        isConfigured = false
    }

    private func stopAsNestedOperation() async {
        // AL01/AL02: a nested Stop belongs to the PARENT operation, so it does NOT mint a new
        // token — it runs the SAME Core-owned sequence under the parent's ownership. Not advancing
        // a counter was never sufficient: the sequence re-validates at every boundary, so a newer
        // B that took over during any suspension is never torn down.
        let parentToken = lifecycleOwnership.current
        let resetPassBeforeOwnerHop = recoveryPassToken

        // The owner state this helper observed, so cleanup is conditional on it still being current.
        let ownerAtEntry = await applicationOwner.ownershipSnapshot
        guard lifecycleOwnership.isCurrent(parentToken), recoveryPassToken == resetPassBeforeOwnerHop else { return }

        identity.noteTerminal()
        recoveryPassToken &+= 1
        liveRecoveryPass.withLock { $0 = recoveryPassToken }
        let resetPassAtStopEntry = recoveryPassToken

        _ = await StopSequencer.run(
            ownership: lifecycleOwnership,
            token: parentToken,
            effects: StopSequencer.Effects(
                performNativeStop: { [session, self] in
                    let previewPause = await self.displayBridge.nativeAccessGate.pauseAndDrainFrames()
                    defer { previewPause.release() }
                    // The token is re-validated INSIDE the native-queue hop, at the mutation.
                    await self.sessionQueue.perform {
                        guard self.lifecycleOwnership.isCurrent(parentToken),
                              self.liveRecoveryPass.withLock({ $0 }) == resetPassAtStopEntry else { return }
                        if session.isRunning { session.stopRunning() }
                    }
                },
                clearServiceState: { [self] in
                    await self.clearStoppedGraphState(ownedBy: parentToken, resetPass: resetPassAtStopEntry)
                },
                settleOwner: { [self] in
                    // AN01: conditional AT the owner mutation, not merely checked around it.
                    await self.applicationOwner.endSettlement(
                        ifOwnedBy: ownerAtEntry.current,
                        authorityIsCurrent: { [self] in
                            self.lifecycleOwnership.isCurrent(parentToken) && self.liveRecoveryPass.withLock { $0 == resetPassAtStopEntry }
                        })
                },
                // Cleared only if the owner state this helper observed is still in force, so a
                // newer pending/accepted/published application is preserved.
                finishOwnerIfUnchanged: { [self] in
                    await self.applicationOwner.finish(ifUnchangedSince: ownerAtEntry,
                        authorityIsCurrent: { [self] in
                            self.lifecycleOwnership.isCurrent(parentToken) && self.liveRecoveryPass.withLock { $0 == resetPassAtStopEntry }
                        })
                },
                clearConfigured: { [self] in
                    await self.clearConfiguredState(ownedBy: parentToken, resetPass: resetPassAtStopEntry)
                }))
    }

    func switchPhysicalCamera(to kind: PhysicalCameraKind) async -> Result<CameraCapabilitySnapshot, CaptureFailure> {
        await prepare(desiredCamera: kind)
    }

    func applyControls(
        revision: UInt64,
        exposure: ExposureChoice,
        biasEV: Double,
        focus: FocusIntent,
        whiteBalance: WhiteBalanceIntent
    ) async -> Result<AppliedControlSnapshot, CaptureFailure> {
        await applyControls(
            revision: revision, exposure: exposure, biasEV: biasEV,
            focus: focus, whiteBalance: whiteBalance, ownedByReset: nil)
    }

    /// AP01: the reset-owned variant. Ordinary callers use the protocol-shaped entry point above,
    /// which passes `nil` - so an ordinary call is authorized on its OWN terms, never by another
    /// call's ambient context.
    private func applyControls(
        revision: UInt64,
        exposure: ExposureChoice,
        biasEV: Double,
        focus: FocusIntent,
        whiteBalance: WhiteBalanceIntent,
        ownedByReset: UInt64?
    ) async -> Result<AppliedControlSnapshot, CaptureFailure> {
        let operationResetPass = ownedByReset ?? recoveryPassToken
        guard resetAuthorityIsCurrent(operationResetPass) else {
            return .failure(CaptureFailure(kind: .cameraInterrupted(detail: "Controls were superseded by a newer recovery pass."), operation: "applyControls"))
        }

        // R01: the previous settlement window is NOT cleared here. A request that turns out
        // to be rejected must leave the accepted operation's target, window and bound
        // application exactly as they were; the window is replaced only once THIS operation
        // is acknowledged and bound, below.
        // W01: captured synchronously BEFORE any suspension.
        identity.noteControlInvocation()
        let thisInvocation = controlInvocationSequence
        // AE01: the generation in force when this operation STARTED, captured before any
        // suspension. Every later effect is validated against THIS value, not against whatever
        // generation happens to be live when the native result returns.
        let generationAtIssue = generation
        let instruction = NativeControlInstruction(
            exposure: exposure, biasEV: biasEV, focus: focus, whiteBalance: whiteBalance)
        let limits = activeFormatExposureLimits()
        let focusLimits = activeFormatFocusLimits()
        let whiteBalanceLimits = activeFormatWhiteBalanceLimits()
        let generationAtRequest = generation

        // H01: the native setter completion handlers are the framework's own statement
        // that the device applied the values. The group is created OUTSIDE the queue so
        // the callbacks can be awaited after the queue hop, with no device lock held.
        // AQ01: authority BEFORE the revision mutation. A stale call reaching this actor after a
        // prior Core check must not invalidate newer work even though it later returns failure.
        guard resetAuthorityIsCurrent(operationResetPass) else {
            return .failure(CaptureFailure(kind: .cameraInterrupted(
                detail: "The camera was rebuilt by a newer recovery pass."), operation: "applyControls"))
        }
        controlRevision &+= 1
        // L01: the identity is minted by the OWNER, and the previous valid application
        // stays in force until this one is known to have succeeded.
        // Carries the native result out of the port. Lock-guarded, so the transfer is
        // safe and the closure itself remains Sendable.
        final class NativeResultBox: @unchecked Sendable {
            private let lock = NSLock()
            private var value: ControlApplicationResult = .failed(CaptureFailure(
                kind: .noCamera, operation: "applyControls"))
            func set(_ newValue: ControlApplicationResult) {
                lock.lock(); value = newValue; lock.unlock()
            }
            var current: ControlApplicationResult {
                lock.lock(); defer { lock.unlock() }; return value
            }
        }
        let nativeResultBox = NativeResultBox()
        // R01: the OWNER runs the whole algorithm — issue, callback wait, acceptance, target
        // binding and the settlement window. The adapter supplies only the thin native port
        // below (the SDK binding) and maps the owner's typed outcome to failures, so no
        // second ordering of this sequence exists here.
        guard resetAuthorityIsCurrent(operationResetPass) else {
            return .failure(CaptureFailure(kind: .cameraInterrupted(
                detail: "The camera was rebuilt by a newer recovery pass."), operation: "applyControls"))
        }
        let outcome = await applicationOwner.runOperation(
            revision: revision,
            generation: generationAtRequest,
            timeoutSeconds: max(5.0, 2 * max(0, instruction.exposure.durationTargetSeconds ?? 0) + 1)
        ) { completions in
            #if DEBUG
            let queueBegan = ProcessInfo.processInfo.systemUptime
            #endif
            let issued: ControlApplicationResult = await sessionQueue.perform { [session] in
                #if DEBUG
                print("TruongCam timing control-queue=\(Int((ProcessInfo.processInfo.systemUptime - queueBegan) * 1000))ms")
                let bindingBegan = ProcessInfo.processInfo.systemUptime
                defer { print("TruongCam timing control-binding=\(Int((ProcessInfo.processInfo.systemUptime - bindingBegan) * 1000))ms") }
                #endif
                guard self.resetAuthorityAllowsNativeMutation(operationResetPass) else {
                    return .failed(CaptureFailure(kind: .cameraInterrupted(detail: "Controls were superseded by a newer recovery pass."), operation: "applyControls.issue"))
                }
                guard let device = session.inputs
                    .compactMap({ ($0 as? AVCaptureDeviceInput)?.device })
                    .first else {
                    return .failed(CaptureFailure(kind: .noCamera, operation: "applyControls"))
                }
                // AF01: an OBSOLETE request must not run its native setters at all. Both the
                // configuration generation and the concrete invocation are validated HERE, at
                // the issue boundary, before any setter runs. Rejecting only the RESULT still
                // let an old-generation binding mutate the device.
                guard ControlIssueGate.mayIssue(
                    generationAtIssue: generationAtIssue,
                    currentGeneration: self.generationBox.withLock { $0 },
                    invocationAtIssue: thisInvocation,
                    currentInvocation: self.identity.controlSequence
                ) else {
                    return .failed(CaptureFailure(
                        kind: .operationStalled(
                            detail: "An obsolete control application was not issued to the device."),
                        operation: "applyControls.issue"))
                }
                return CameraControlBinding.apply(
                    instruction,
                    to: device,
                    generation: generationAtRequest,
                    limits: limits,
                    focusLimits: focusLimits,
                    whiteBalanceLimits: whiteBalanceLimits,
                    configuredPhotoDimensions: nil,
                    completions: completions)
            }
            nativeResultBox.set(issued)
            // The target comes from the request's OWN validated/clamped gains, returned by
            // the binding that did the conversion (REVIEW.md M01), and is bound only when
            // the owner accepts the operation.
            var target = Self.settlementTarget(for: instruction)
            if case .applied(let applied) = issued,
               let gains = applied.resolvedWhiteBalanceTarget {
                target.redGain = gains.red
                target.greenGain = gains.green
                target.blueGain = gains.blue
            }
            switch issued {
            case .applied: return (decision: .applied, target: target)
            case .rejected: return (decision: .rejected, target: target)
            case .failed: return (decision: .failed, target: target)
            }
        }
        let result = nativeResultBox.current
        switch outcome {
        case .bound(let receipt):
            // S01: the receipt identifies the operation that actually completed. Looking up
            // `currentApplication` here could attach a NEWER operation's identity to this
            // result, so only the receipt is bound — and currentness is re-checked AFTER the
            // operation returned, because a supersession can interleave at that seam.
            // The applied snapshot published by THIS operation is supplied by the outcome's
            // own native result; the owner publishes it atomically with the receipt.
            // AE01: the GENERATION is validated before ANY effect — including the owner
            // publication below, which previously ran first. A result from an older
            // configuration must not publish or bind, let alone mutate and then fail.
            guard resetAuthorityIsCurrent(operationResetPass),
                  case .applied(let appliedSnapshot) = result,
                  generationAtIssue == generation,
                  appliedSnapshot.generation == generation else {
                return .failure(CaptureFailure(
                    kind: .operationStalled(
                        detail: "A control application from an older camera generation was ignored."),
                    operation: "applyControls.publish"))
            }
            guard await applicationOwner.publish(receipt, snapshot: appliedSnapshot) else {
                return .failure(CaptureFailure(
                    kind: .operationStalled(
                        detail: "The control application was superseded before it could be published."),
                    operation: "applyControls.publish"))
            }
            // U01: the owner is the single source of the published state. If a newer
            // operation has published since, this one must not write its local applied
            // state over B's — it reports superseded instead.
            // W01: validated SYNCHRONOUSLY in this actor turn, immediately before the writes.
            // A later invocation that completed during the remote publish makes this one
            // obsolete, so it must not report success or touch B's published state.
            // AE01: re-validated AFTER the owner publication, which is itself an await. The
            // generation can advance inside it, and the check must share a turn with the write.
            guard resetAuthorityIsCurrent(operationResetPass),
                  generationAtIssue == generation, appliedSnapshot.generation == generation else {
                return .failure(CaptureFailure(
                    kind: .operationStalled(
                        detail: "A control application from an older camera generation was ignored."),
                    operation: "applyControls.publish"))
            }
            let commit = ConsumerCommit.commitControl(
                identity: identity,
                invocation: thisInvocation
            ) {
                lastAppliedInstruction = instruction
                lastBoundApplication = receipt
            }
            guard commit == .committed else {
                return .failure(CaptureFailure(
                    kind: .operationStalled(
                        detail: "The control application was superseded before it could be published."),
                    operation: "applyControls.publish"))
            }
        case .rejected:
            // The typed rejections the validator produced, so the caller reports the SAME
            // reason the validation found rather than a generic message.
            var reasons: [String] = []
            if case .rejected(let exposure, let focus, let whiteBalance) = result {
                for failure in exposure { reasons.append(failure.userDescription) }
                if let focus { reasons.append(focus.userDescription) }
                if let whiteBalance { reasons.append(whiteBalance.userDescription) }
            }
            let detail: String = reasons.joined(separator: " ")
            return .failure(CaptureFailure(
                kind: .unsupportedCapability(
                    detail: detail.isEmpty
                        ? "The requested controls were rejected before any native setter ran."
                        : detail),
                operation: "applyControls.validation"))
        case .issueFailed:
            if case .failed(let failure) = result { return .failure(failure) }
            return .failure(CaptureFailure(
                kind: .noCamera, operation: "applyControls"))
        case .timedOut:
            return .failure(CaptureFailure(
                kind: .operationStalled(
                    detail: "The camera did not acknowledge every control change within the settle deadline."),
                operation: "applyControls.setterDeadline"))
        case .obsolete:
            return .failure(CaptureFailure(
                kind: .operationStalled(
                    detail: "The control application was superseded before it completed."),
                operation: "applyControls.obsolete"))
        }
        switch result {
        case .applied(let applied):
            // A stale generation must not relabel the current control state.
            // AE01: the GENERATION is validated FIRST, before any effect. Previously the
            // commit ran before this check, so a latest invocation from an older configuration
            // mutated lastApplied and only then returned failure.
            guard generationAtIssue == generation else {
                return .failure(CaptureFailure(
                    kind: .operationStalled(
                        detail: "A control application from an older camera generation was ignored."),
                    operation: "applyControls"))
            }
            // AD01/AE01: and the INVOCATION identity must still hold. The check and the write
            // share one synchronous turn, so neither a newer operation nor a generation change
            // can slip between them.
            let appliedCommit = ConsumerCommit.commitControl(
                identity: identity,
                invocation: thisInvocation
            ) {
                lastApplied = applied
            }
            guard appliedCommit == .committed else {
                return .failure(CaptureFailure(
                    kind: .operationStalled(
                        detail: "A control application from a superseded invocation was ignored."),
                    operation: "applyControls"))
            }
            // REVIEW.md S05: applying must publish a completion for THIS revision,
            // otherwise the UI cannot tell a successful setter from a live reading
            // and had to poll or guess. The state is `awaitingObservation`: the
            // setter returned, but the device has not been observed yet.
            var acknowledged = applied
            acknowledged.requestRevision = revision
            // Only the binding's unchanged-Auto path carries an actual native
            // observation. All real setter changes still require later readback.
            acknowledged.settlement = applied.settlement.isLiveObservation ? .moving : .awaitingObservation
            readbackBroadcaster.send(acknowledged)
            return .success(acknowledged)
        case .rejected(let exposureFailures, let focusFailure, let whiteBalanceFailure):
            let parts = exposureFailures.map(\.userDescription)
                + [focusFailure?.userDescription, whiteBalanceFailure?.userDescription].compactMap { $0 }
            let detail = parts.isEmpty
                ? "The requested control combination is not supported by the active format."
                : parts.joined(separator: " ")
            return .failure(CaptureFailure(kind: .invalidSettings(detail: detail), operation: "applyControls"))
        case .failed(let failure):
            return .failure(failure)
        }
    }

    func setFocusPoint(
        normalizedDevicePoint: NormalizedDevicePoint,
        isTapToFocus: Bool
    ) async -> Result<Void, CaptureFailure> {
        let limits = activeFormatFocusLimits()
        let generationAtIssue = generation, lifecycleAtIssue = lifecycleOwnership.current
        let resetAtIssue = recoveryPassToken, invocationAtIssue = identity.controlSequence
        guard isConfigured else {
            return .failure(CaptureFailure(kind: .operationStalled(detail: "The camera is not ready for focus."), operation: "setFocusPoint.owner"))
        }
        return await sessionQueue.perform { [session] in
            CameraControlBinding.applyFocusPointIfCurrent(isCurrent: {
                self.lifecycleOwnership.isCurrent(lifecycleAtIssue)
                    && self.resetAuthorityAllowsNativeMutation(resetAtIssue)
                    && ControlIssueGate.mayIssue(generationAtIssue: generationAtIssue,
                        currentGeneration: self.generationBox.withLock { $0 },
                        invocationAtIssue: invocationAtIssue, currentInvocation: self.identity.controlSequence)
            }) {
                guard session.isRunning,
                      let device = session.inputs.compactMap({ ($0 as? AVCaptureDeviceInput)?.device }).first else {
                    return .failure(CaptureFailure(kind: .noCamera, operation: "setFocusPoint"))
                }
                return CameraControlBinding.setFocusPoint(normalizedDevicePoint,
                    isTapToFocus: isTapToFocus, on: device, focusLimits: limits)
            }
        }
    }

    /// The last snapshot the service applied or read. Cheap, cached, and NOT a
    /// live device reading — REVIEW.md C05: replaying this as "observed" made the
    /// UI show stale numbers forever.
    func lastAppliedSnapshot() async -> AppliedControlSnapshot? { lastApplied }

    /// The capability of the configuration currently in force, including after a rebuild.
    func currentCapability() async -> CameraCapabilitySnapshot? {
        guard !snapshot.physicalCameras.isEmpty else { return nil }
        return snapshot
    }

    nonisolated var controlReadbackStream: AsyncStream<AppliedControlSnapshot> {
        readbackBroadcaster.subscribe()
    }

    /// Reads the device's ACTUAL current control values.
    ///
    /// Every field comes from the live `AVCaptureDevice` on the session queue, so
    /// automatic parameters (ISO, exposure duration, metering offset, focus
    /// position, white-balance gains) move on screen. The applied choice is
    /// carried forward because the device does not report which semantic mode the
    /// user selected; that is intent, not observation.
    func currentControlReadback() async -> AppliedControlSnapshot? {
        let generationAtRead = generation
        // L01: the revision is read from the OWNER, so an observation can only be
        // correlated with the application actually in force.
        // Q01: BOTH the revision and the concrete OPERATION TOKEN are captured here,
        // before the session-queue suspension below.
        let operationAtRead = await applicationOwner.currentApplication
        let revisionAtRead = operationAtRead?.revision
        // X01: captured BEFORE every suspension below, and re-validated synchronously with
        // the local writes, so an older reading cannot publish over newer accepted state.
        let publicationAtRead = servicePublicationSequence
        let wantsTemperatureAndTint = hardwareWhiteBalanceObservationRequested.withLock { $0 }
        let observed: AppliedControlSnapshot? = await sessionQueue.perform { [session] in
            guard let device = session.inputs
                .compactMap({ ($0 as? AVCaptureDeviceInput)?.device })
                .first else { return nil }
            let exposure = device.exposureMode == .custom
                ? Self.semanticChoice(device: device)
                : .auto
            // One native struct read keeps this observation's channel gains
            // together and avoids repeating the native getter for every channel.
            let observedGains = device.deviceWhiteBalanceGains
            var snapshot = AppliedControlSnapshot(
                generation: generationAtRead,
                requestRevision: revisionAtRead,
                settlement: .moving,
                isExposureAdjusting: device.isAdjustingExposure,
                isFocusAdjusting: device.isAdjustingFocus,
                isWhiteBalanceAdjusting: device.isAdjustingWhiteBalance,
                exposureChoice: exposure,
                biasEV: Double(device.exposureTargetBias),
                observedDurationSeconds: device.exposureDuration.validatedSeconds,
                observedISO: Double(device.iso),
                observedExposureTargetOffset: Double(device.exposureTargetOffset),
                focusMode: Self.semanticFocusMode(device.focusMode),
                focusPosition: Double(device.lensPosition),
                whiteBalanceMode: device.whiteBalanceMode == .locked ? .manual : .auto,
                whiteBalanceGains: AppWhiteBalanceGains(
                    red: Double(observedGains.redGain),
                    green: Double(observedGains.greenGain),
                    blue: Double(observedGains.blueGain)),
                lensAperture: Double(device.lensAperture),
                videoZoomFactor: Double(device.videoZoomFactor),
                photoConnectionScale: 1.0,
                photoConnectionCrop: 1.0,
                capturedAtUTC: Date(),
                isFixedFocusCamera: !device.isLockingFocusWithCustomLensPositionSupported
                    && !device.isFocusModeSupported(.autoFocus) && !device.isFocusModeSupported(.continuousAutoFocus))
            if wantsTemperatureAndTint {
                snapshot.observedWhiteBalanceTemperatureAndTint = CameraControlBinding.observedTemperatureAndTint(gains: observedGains, device: device)
            }
            return snapshot
        }
        if var observed {
            // A readback from an older configuration generation must not relabel
            // the current camera's state.
            guard observed.generation == generation else { return lastApplied }
            // Q01: the SAME operation TOKEN captured before the hop is validated here. A
            // newer operation with an identical revision/generation cannot confirm an older
            // reading, because the token — not the revision — identifies the operation.
            let stillCurrent = await applicationOwner.observationBelongs(operationAtRead)
            guard stillCurrent else { return lastApplied }
            // REVIEW.md S06: a live reading is not a settled value. Consecutive
            // identical readings are required before the UI may say "settled", and
            // non-convergence is reported rather than hidden.
            // X01: settlement uses the reading's OWN token.
            guard let reading = operationAtRead,
                  let settled = await applicationOwner.settleIfCurrent(observed, for: reading)
            else { return lastApplied }
            // X01: the last check is SYNCHRONOUS, in this actor turn, immediately before the
            // writes and broadcast. A newer publication during the awaits above — or a
            // generation change — makes this reading stale, so it is NOT published and the
            // newer state stays intact.
            let readbackCommit = ConsumerCommit.commitReadback(
                identity: identity,
                snapshot: PublicationIdentity.Snapshot(
                    publication: publicationAtRead, control: controlInvocationSequence),
                generationMatches: generationAtRead == generation
            ) {
                observed.settlement = settled
                lastApplied = observed
                readbackBroadcaster.send(observed)
            }
            guard readbackCommit == .committed else { return lastApplied }
            return observed
        }
        return observed
    }

    /// The settlement target for one instruction, from the request's OWN values.
    ///
    /// K01: manual/locked focus supplies the position it asked for, and manual WB
    /// supplies the gains the resolver derived from the requested Kelvin/tint — never an
    /// inference from whatever gains happen to be present.
    static func settlementTarget(
        for instruction: NativeControlInstruction
    ) -> ControlSettlementPolicy.Target {
        var target = ControlSettlementPolicy.Target()
        if instruction.exposure.mode == .manual {
            target.durationSeconds = instruction.exposure.durationTargetSeconds
            target.iso = instruction.exposure.isoTarget
        }
        if let position = instruction.focus.position, instruction.focus.mode == .manual {
            target.focusPosition = position
        }
        return target
    }

    /// Reconstructs the semantic exposure choice from the device's own auto flags.
    private static func semanticChoice(device: AVCaptureDevice) -> ExposureChoice {
        let durationAuto = device.automaticallyAdjustsExposureDuration
        let isoAuto = device.automaticallyAdjustsISO
        let duration = device.exposureDuration.validatedSeconds ?? 0
        let iso = Double(device.iso)
        switch (durationAuto, isoAuto) {
        case (false, false): return .manual(durationSeconds: duration, iso: iso)
        case (true, false): return .isoPriority(iso: iso)
        case (false, true): return .shutterPriority(durationSeconds: duration)
        case (true, true): return .auto
        }
    }

    private static func semanticFocusMode(_ mode: AVCaptureDevice.FocusMode) -> FocusModeKind {
        switch mode {
        case .locked: return .manual
        case .autoFocus: return .lockedAuto
        default: return .continuousAuto
        }
    }

    /// The immutable display bridge for the preview layer. The layer renders the
    /// session; it never configures it.
    func previewDisplayBridge() async -> PreviewDisplayBridge {
        displayBridge.install(session, rotationAngles: sensorRotations.withLock { $0 })
        return displayBridge
    }

    /// Records the RAW dimensions measured from a real capture. This is the only
    /// path that moves `observedRAWDimensions` off `unknown`.
    func recordMeasuredRAWDimensions(_ dimensions: PixelDimensions, evidenceOrigin: String) {
        guard case .available(true) = snapshot.bayerCaptureSupported else { return }
        guard let kind = selectedKind, let camera = snapshot.camera(kind) else { return }
        let updated = PhysicalCameraCapability(
            kind: camera.kind,
            deviceType: camera.deviceType,
            uniqueDeviceIdentifier: camera.uniqueDeviceIdentifier,
            modelIdentifier: camera.modelIdentifier,
            formats: camera.formats,
            selectedFormatIndex: camera.selectedFormatIndex,
            bayerRAWDiscovery: camera.bayerRAWDiscovery,
            rawFileTypeDiscovery: camera.rawFileTypeDiscovery,
            nativeBracketCountDiscovery: camera.nativeBracketCountDiscovery,
            observedRAWDimensions: .available(dimensions),
            observedRAWEvidenceOrigin: evidenceOrigin,
            videoZoomFactorAtDiscovery: camera.videoZoomFactorAtDiscovery,
            nominalEquivalentFocalLengthMM: camera.validNominalEquivalentFocalLengthMM)
        var cameras = snapshot.physicalCameras
        if let index = cameras.firstIndex(where: { $0.kind == kind }) {
            cameras[index] = updated
        }
        let previous = snapshot
        snapshot = CameraCapabilitySnapshot(
            generation: snapshot.generation,
            hardwareModel: snapshot.hardwareModel,
            osVersion: snapshot.osVersion,
            sdkVersion: snapshot.sdkVersion,
            physicalCameras: cameras,
            selectedCameraKind: snapshot.selectedCameraKind,
            configuredPhotoDimensions: dimensions,
            configuredPhotoDimensionsEvidence: evidenceOrigin,
            previewAnalysisFormat: snapshot.previewAnalysisFormat,
            bayerCaptureSupported: snapshot.bayerCaptureSupported,
            probeTimestampUTC: snapshot.probeTimestampUTC,
            notes: snapshot.notes)
        snapshot.frontHEIFSupported = previous.frontHEIFSupported
        snapshot.jpegSupported = previous.jpegSupported
        snapshot.jpegMaximumDimensions = previous.jpegMaximumDimensions
    }

    func beginCapture(intent: CaptureIntent) async -> any CaptureRequestTicket {
        #if DEBUG
        let entryBegan = ProcessInfo.processInfo.systemUptime
        var phaseBegan = entryBegan
        var snapshotMS = 0, ownershipMS = 0, requestMS = 0, handleMS = 0, enqueueMS = 0
        defer {
            let elapsedMS = Int((ProcessInfo.processInfo.systemUptime - entryBegan) * 1000)
            print("TruongCam timing native-ticket=\(elapsedMS)ms capture=\(intent.captureID)")
            print("TruongCam timing native-ticket-phases snapshot=\(snapshotMS)ms ownership=\(ownershipMS)ms request=\(requestMS)ms handle=\(handleMS)ms enqueue=\(enqueueMS)ms capture=\(intent.captureID)")
        }
        #endif
        let photoRotation = previewGeometry.flatMap { $0.configurationGeneration == generation ? $0.analysisRotationDegrees : nil }
        // The frozen intent owns output format. Capability discovery never
        // substitutes JPEG/HEIF for an unavailable Bayer request.
        let rawFormat = intent.fileFormat == .bayerDNG ? availableBayerFormats.first ?? 0 : 0
        let rawFileType: String?
        switch intent.fileFormat {
        case .jpeg: rawFileType = AVFileType.jpg.rawValue
        case .frontHEIF: rawFileType = AVFileType.heic.rawValue
        case .bayerDNG:
            rawFileType = availableRawFileTypes.contains(AVFileType.dng.rawValue)
                ? AVFileType.dng.rawValue : availableRawFileTypes.first
        }
        #if DEBUG
        snapshotMS = Int((ProcessInfo.processInfo.systemUptime - phaseBegan) * 1000)
        phaseBegan = ProcessInfo.processInfo.systemUptime
        #endif
        inFlightRegistry.noteSubmitted(
            captureID: intent.captureID,
            plannedSeconds: intent.exposure.durationTargetSeconds ?? 0)
        drainGate.noteSubmitted(intent.captureID)
        #if DEBUG
        ownershipMS = Int((ProcessInfo.processInfo.systemUptime - phaseBegan) * 1000)
        phaseBegan = ProcessInfo.processInfo.systemUptime
        #endif
        let request = PerCaptureRequest(
            captureID: intent.captureID,
            intent: intent,
            rawPixelFormatType: rawFormat,
            rawFileType: rawFileType,
            maximumRepresentations: 1)
        #if DEBUG
        requestMS = Int((ProcessInfo.processInfo.systemUptime - phaseBegan) * 1000)
        phaseBegan = ProcessInfo.processInfo.systemUptime
        #endif
        let ticket = CameraCaptureTicket(
            captureID: intent.captureID,
            uniqueSettingsID: 0,
            request: request)
        uniqueIDByCaptureID[intent.captureID] = 0
        #if DEBUG
        handleMS = Int((ProcessInfo.processInfo.systemUptime - phaseBegan) * 1000)
        phaseBegan = ProcessInfo.processInfo.systemUptime
        #endif
        guard let photoRotation, intent.configurationGeneration == generation, intent.physicalCameraKind == selectedKind else {
            _ = request.finishWith(mappedFailure: CaptureFailure(kind: .operationStalled(detail: "The selected camera is still aligning its preview."), operation: "beginCapture.geometry"))
            releaseRequest(captureID: intent.captureID)
            retireInFlight(intent.captureID)
            return ticket
        }
        let photoPriority = displayBridge.prioritizePhotoWork()
        Task { [weak self] in
            defer { photoPriority.release() }
            await self?.submit(ticket: ticket, intent: intent, rawFormat: rawFormat, rawFileType: rawFileType, photoRotation: photoRotation)
            // P02: retirement waits for the REAL native terminal. `submit` returns after
            // merely ISSUING the request, with the delegate retained and the terminal
            // still pending, so retiring there let a teardown proceed over a live request.
            _ = await ticket.awaitTerminal()
            await self?.retireInFlight(intent.captureID)
            await self?.reconcileHardwareControlsAfterNativeChange()
        }
        #if DEBUG
        enqueueMS = Int((ProcessInfo.processInfo.systemUptime - phaseBegan) * 1000)
        #endif
        return ticket
    }

    /// Records that a submitted request has reached its native boundary.
    private func retireInFlight(_ captureID: CaptureID) {
        // Exactly ONE terminal notification: `retire` reports whether this call performed the
        // transition for a gate-tracked request.
        if inFlightRegistry.retire(captureID: captureID) {
            drainGate.noteTerminal(captureID)
        }
    }

    /// What a pre-teardown drain actually achieved.
    ///
    /// P02: a plain `void` return could not distinguish a completed drain from a timeout,
    /// so a reset could rebuild the graph while requests were still outstanding.
    /// The teardown gate's own outcome type (Core), so there is exactly one.
    typealias DrainOutcome = SubmissionDrainGate.Outcome

    /// Waits a bounded, duration-appropriate time for already-submitted requests to reach
    /// their native terminal before a graph teardown.
    ///
    /// P02: the bound scales with the LONGEST planned capture rather than a fixed five
    /// seconds, so a long exposure is not cut short, and the result names what remains.
    private func drainInFlightBeforeTeardown() async -> DrainOutcome {
        // X02/Y02: the bounded reconciliation is the GATE's own tested loop — the shipping
        // teardown and the registered execution run the same code, with no second ordering
        // here. The bound comes from the longest plan still outstanding.
        return await drainGate.awaitDrain(
            longestPlannedSeconds: inFlightRegistry.longestPlannedSeconds)
    }

    func stopForTransientRecovery() async -> Result<Void, CaptureFailure> {
        guard activeResetRecoveryPasses.isEmpty, lastRecoveryOutcome == .recovered else {
            return .failure(CaptureFailure(kind: .cameraInterrupted(detail: "Native reset recovery still owns the camera or has unresolved work."), operation: "recovery.nativeOwner"))
        }
        let owner = lifecycleOwnership.current, reset = recoveryPassToken
        let drain = await drainInFlightBeforeTeardown()
        guard lifecycleOwnership.isCurrent(owner), recoveryPassToken == reset,
              activeResetRecoveryPasses.isEmpty, lastRecoveryOutcome == .recovered else {
            return .failure(CaptureFailure(kind: .operationStalled(detail: "A newer camera operation owns recovery."), operation: "recovery.drain"))
        }
        if case .outstanding(let count) = drain {
            return .failure(CaptureFailure(kind: .cameraInterrupted(detail: "Waiting for \(count) submitted capture(s) and their retained sources before camera recovery."), operation: "recovery.drain"))
        }
        await stop()
        return .success(())
    }

    /// Applies a capture's frozen control intent immediately before submission.
    ///
    /// This is deliberately separate from the UI's "current desired" state: a frozen
    /// sequence step must not be replaced by newer user intent, and a step that cannot
    /// be applied must fail rather than silently capturing at the wrong exposure.
    private func applyCaptureIntentControls(
        _ intent: CaptureIntent
    ) async -> Result<AppliedControlSnapshot, CaptureFailure> {
        await applyControls(
            // The frozen intent has no UI revision of its own. A step is applied
            // under the monotonic creation stamp, so it is ordered against other
            // applications without pretending to be a newer user request.
            revision: UInt64(max(0, intent.createdAtUTC.timeIntervalSince1970 * 1000)),
            exposure: intent.exposure,
            biasEV: intent.biasEV,
            focus: intent.focus,
            whiteBalance: intent.whiteBalance)
    }

    /// Forwards the UI's complete analysis request. The bridge preserves every
    /// tool setting; only the generation stamp is refreshed on geometry change.
    func setAnalysisRequest(_ request: AnalysisRequest?) async {
        currentAnalysisRequest = request
        refreshAnalysisGeneration()
        await analysisSink.setAnalysisRequest(request)
    }

    func setAnalysisDemand(_ demand: AnalysisDemand) async {
        let demandToken = analysisDemandOwnership.begin()
        analysisDemand = demand
        refreshAnalysisGeneration()
        let generationAtDemand = generation
        let lifecycleAtDemand = lifecycleOwnership.current

        // The camera service only tracks whether analysis is wanted; the request's
        // tool settings come from the UI so they are never replaced by defaults.
        await analysisSink.updateGeometry(previewGeometry)
        // Output attachment and delegate installation are decided on the session
        // queue, but the delegate is owned by this actor, so the decision is
        // returned and applied here. REVIEW.md S07: the delegate used to be
        // installed unconditionally, including after the output was removed.
        let previewPause = await displayBridge.nativeAccessGate.pauseAndDrainFrames()
        defer { previewPause.release() }
        enum OutputAction { case attached, alreadyAttached, updatedFormat, detached, unchanged, unsupportedFormat }
        // M04: `defer` below revalidates the confirmed facts after this topology change.
        let action: OutputAction = await sessionQueue.perform { [session, videoOutput] in
            let current = {
                self.generationBox.withLock { $0 } == generationAtDemand
                    && self.lifecycleOwnership.isCurrent(lifecycleAtDemand)
                    && self.analysisDemandOwnership.isCurrent(demandToken)
            }
            guard current() else { return .unchanged }
            // An owned startup may reserve tool demand before its first input is
            // attached. No connected format exists yet: retain that desire for
            // prepare(), rather than publishing a false unsupported verdict or
            // adding a separate half-configured output before preparation.
            guard session.inputs.contains(where: { $0 is AVCaptureDeviceInput }) else { return .unchanged }
            // Adding or removing the analysis output is serialized with capture
            // configuration. Capabilities are revalidated by the caller after
            // any tuple change; merely hiding an overlay never changes RAW zoom.
            let isAttached = session.outputs.contains { $0 === videoOutput }
            // Usually already normalized in the owned input-swap commit. Keep
            // this conditional fallback for a connection created only at commit.
            if isAttached { Self.prepareAnalysisConnection(videoOutput, isCurrent: current) }
            if demand.wantsVideoOutput, !isAttached, session.canAddOutput(videoOutput) {
                // A supported 8-bit bi-planar YCbCr format is required before the
                // output produces frames the analysis path can read.
                guard let selected = Self.selectAnalysisPixelFormat(videoOutput) else {
                    return .unsupportedFormat
                }
                videoOutput.videoSettings = [
                    kCVPixelBufferPixelFormatTypeKey as String: selected,
                ]
                self.beginConfigure()
                session.addOutput(videoOutput)
                Self.prepareAnalysisConnection(videoOutput, isCurrent: current)
                self.commitConfigure()
                Self.prepareAnalysisConnection(videoOutput, isCurrent: current)
                return .attached
            } else if demand.wantsVideoOutput, isAttached {
                // Already attached (for example by `prepare`). REVIEW.md F04: an
                // EXISTING pixel format must be validated against what the connection
                // supports, not merely checked for a missing dictionary key — a
                // previously set but unsupported format would otherwise be accepted.
                let configured = videoOutput.videoSettings[
                    kCVPixelBufferPixelFormatTypeKey as String] as? OSType
                let supported = videoOutput.availableVideoPixelFormatTypes
                let isUsable = configured.map { supported.contains($0) && Self.analysisLumaPixelFormats.contains($0) } ?? false
                if !isUsable {
                    guard let selected = Self.selectAnalysisPixelFormat(videoOutput) else {
                        return .unsupportedFormat
                    }
                    self.displayBridge.nativeAccessGate.noteNativeMutation()
                    videoOutput.videoSettings = [
                        kCVPixelBufferPixelFormatTypeKey as String: selected,
                    ]
                    return .updatedFormat
                }
                return .alreadyAttached
            } else if !demand.wantsVideoOutput, isAttached {
                videoOutput.setSampleBufferDelegate(nil, queue: nil)
                self.beginConfigure()
                session.removeOutput(videoOutput)
                self.commitConfigure()
                return .detached
            }
            return .unchanged
        }

        guard generation == generationAtDemand, lifecycleOwnership.isCurrent(lifecycleAtDemand),
              analysisDemandOwnership.isCurrent(demandToken) else { return }
        #if DEBUG
        switch action {
        case .attached, .detached, .updatedFormat, .unsupportedFormat:
            print("TruongCam analysis-output: action=\(action) geometry=\(previewGeometry != nil) wanted=\(demand.wantsVideoOutput)")
        default: break
        }
        #endif
        switch action {
        case .attached, .alreadyAttached, .updatedFormat:
            // Both paths need a delegate: `.attached` just added the output, and
            // `.alreadyAttached` means an earlier configuration (or `prepare`)
            // added it, which is exactly the first-launch case R01 identified.
            // `installAnalysisDelegate` is idempotent.
            await installAnalysisDelegate(videoOutput, generation: generationAtDemand,
                lifecycle: lifecycleAtDemand, demandToken: demandToken)
        case .detached:
            // The retained handler must not outlive the output it served.
            analysisHandler = nil
        case .unsupportedFormat:
            // No analysis frame producer is available. Reported as an unsupported
            // analysis outcome so the UI explains why no aid appears, instead of
            // showing stale overlays.
            await analysisSink.consume(
                outcome: .unsupported(
                    format: .unknown(fourCC: 0),
                    reason: "This camera format does not offer a supported 8-bit luma format for preview aids."),
                geometry: previewGeometry)
        case .unchanged:
            break
        }

        guard generation == generationAtDemand, lifecycleOwnership.isCurrent(lifecycleAtDemand),
              analysisDemandOwnership.isCurrent(demandToken) else { return }
        // M04: attaching or detaching the analysis output is a session TOPOLOGY change,
        // so the confirmed RAW facts are revalidated against the configuration now in
        // force. A configuration that can no longer produce a Bayer RAW DNG revokes the
        // published support rather than leaving stale facts behind.
        let tupleChanged: Bool
        switch action {
        case .attached, .detached, .updatedFormat: tupleChanged = true
        default: tupleChanged = false
        }
        if isConfigured && tupleChanged {
            // AF03: the caller's order is owned by Core, so a superseded pass cannot revoke.
            _ = await CapabilityRevalidation.run(port: CapabilityRevalidation.Port(
                revalidate: { [weak self] in
                    await self?.refreshConfirmedFactsAfterTopologyChange() ?? .superseded
                },
                revoke: { [weak self] transactionAtStart in
                    // AG03: the revoke re-validates the SAME configuration identity this pass
                    // started under, immediately before mutating.
                    _ = await self?.revokeIfCurrent(transactionAtQuery: transactionAtStart)
                },
                currentTransaction: { [weak self] in
                    self?.finalTupleOperation.currentTransaction ?? 0
                },
                stopGraph: {},
                stopsOnInvalid: false))
        }
    }

    func updatePreviewGeometry(_ geometry: PreviewGeometrySnapshot?) async {
        if let geometry {
            guard geometry.configurationGeneration == generation else { return }
            if let current = previewGeometry, current.configurationGeneration == geometry.configurationGeneration,
               geometry.layoutGeneration < current.layoutGeneration { return }
        }
        previewGeometry = geometry
        displayBridge.setGeometry(geometry)
        refreshAnalysisGeneration()
        if let geometry { analysisOutput.send(.geometryChanged(geometry)) }
        await analysisSink.updateGeometry(geometry)
    }

    // MARK: - Submission

    private func submit(
        ticket: CameraCaptureTicket,
        intent: CaptureIntent,
        rawFormat: UInt32,
        rawFileType: String?,
        photoRotation: Int
    ) async {
        enum SubmissionStep: Sendable {
            case submitted(uniqueID: Int64, delegate: PerCapturePhotoDelegate)
            case failed(NativeRequestOutcome)
        }

        // A cold synchronous capturePhoto call can hold native graph locks too.
        // Keep layout/connection polling out of it without pausing live frames,
        // waiting for the photo callback or changing capture settings/quality.
        let previewPause = await displayBridge.nativeAccessGate.pauseAndDrainFrames()
        defer { previewPause.release() }
        let step: SubmissionStep = await sessionQueue.perform { [session, photoOutput] in
            #if DEBUG
            let queuedBegan = ProcessInfo.processInfo.systemUptime
            defer { print("TruongCam timing native-settings-and-issue=\(Int((ProcessInfo.processInfo.systemUptime - queuedBegan) * 1000))ms main=\(Thread.isMainThread) capture=\(intent.captureID)") }
            #endif
            guard let device = session.inputs
                .compactMap({ ($0 as? AVCaptureDeviceInput)?.device })
                .first else {
                return .failed(.failed(CaptureFailure(kind: .noCamera, operation: "beginCapture")))
            }
            guard self.generationBox.withLock({ $0 }) == intent.configurationGeneration,
                  CameraCapabilityProbe.kind(for: device.deviceType, position: device.position) == intent.physicalCameraKind else {
                return .failed(.failed(CaptureFailure(kind: .operationStalled(detail: "Another camera configuration superseded this capture."), operation: "beginCapture.configuration")))
            }
            if let failure = CameraControlBinding.enforceRAWNativeZoom(on: device) {
                return .failed(.failed(failure))
            }
            let isFrontHEIF = intent.fileFormat == .frontHEIF && intent.physicalCameraKind == .front
                && rawFileType == AVFileType.heic.rawValue && rawFormat == 0
            let isJPEG = intent.fileFormat == .jpeg && rawFileType == AVFileType.jpg.rawValue && rawFormat == 0
            let validFormat: Bool
            switch intent.fileFormat {
            case .bayerDNG:
                validFormat = rawFormat != 0 && rawFileType == AVFileType.dng.rawValue
                    && photoOutput.availableRawPhotoFileTypes.contains(.dng)
                    && photoOutput.supportedRawPhotoPixelFormatTypes(for: .dng).contains(rawFormat)
                    && AVCapturePhotoOutput.isBayerRAWPixelFormat(rawFormat)
            case .frontHEIF:
                validFormat = isFrontHEIF && device.position == .front && Self.supportsHEIF(photoOutput)
            case .jpeg:
                validFormat = isJPEG && Self.supportsJPEG(photoOutput)
            }
            guard validFormat else {
                return .failed(.failed(CaptureFailure(
                    kind: .unsupportedCapability(detail: "The frozen capture format is not offered by the connected photo output."),
                    operation: "beginCapture.format")))
            }

            #if DEBUG
            let connectionBegan = ProcessInfo.processInfo.systemUptime
            #endif
            if let connection = photoOutput.connection(with: .video),
               connection.isVideoRotationAngleSupported(CGFloat(photoRotation)),
               connection.videoRotationAngle != CGFloat(photoRotation) {
                connection.videoRotationAngle = CGFloat(photoRotation)
            }
            let settings: AVCapturePhotoSettings
            #if DEBUG
            print("TruongCam timing native-connection-setup=\(Int((ProcessInfo.processInfo.systemUptime - connectionBegan) * 1000))ms capture=\(intent.captureID)")
            let settingsBegan = ProcessInfo.processInfo.systemUptime
            #endif
            do {
                switch intent.fileFormat {
                case .jpeg:
                    settings = try NativeJPEGPhotoSettings.make(
                        requestedDimensions: intent.requestedDimensions,
                        maximumDimensions: PixelDimensions(width: Int(photoOutput.maxPhotoDimensions.width),
                            height: Int(photoOutput.maxPhotoDimensions.height)),
                        supportedFileTypes: photoOutput.availablePhotoFileTypes,
                        supportedCodecs: photoOutput.supportedPhotoCodecTypes(for: .jpg))
                case .frontHEIF:
                    settings = try Self.makeHEIFSettings(requestedDimensions: intent.requestedDimensions, photoOutput: photoOutput)
                case .bayerDNG:
                    settings = try Self.makeRAWOnlySettings(rawFormat: rawFormat,
                        rawFileType: rawFileType, requestedDimensions: intent.requestedDimensions,
                        photoOutput: photoOutput)
                }
            } catch {
                return .failed(.failed(AVFoundationFailureMapper.failure(error, operation: "makeCaptureSettings")))
            }
            #if DEBUG
            print("TruongCam timing native-settings-construction=\(Int((ProcessInfo.processInfo.systemUptime - settingsBegan) * 1000))ms capture=\(intent.captureID)")
            print("TruongCam photo-request format=\(intent.fileFormat.rawValue) camera=\(intent.physicalCameraKind.rawValue) generation=\(intent.configurationGeneration) requested=\(intent.requestedDimensions.width)x\(intent.requestedDimensions.height) nativeCeiling=\(photoOutput.maxPhotoDimensions.width)x\(photoOutput.maxPhotoDimensions.height) quality=speed capture=\(intent.captureID)")
            print("TruongCam photo-live duration=\(device.exposureDuration.validatedSeconds.map { String($0) } ?? "unknown") iso=\(device.iso) adjustingExposure=\(device.isAdjustingExposure) adjustingFocus=\(device.isAdjustingFocus) capture=\(intent.captureID)")
            #endif

            // Native files are unmirrored even when the front preview is mirrored.
            Self.prepareOriginalConnection(photoOutput, isCurrent: { true })

            let request = ticket.request
            let delegate = PerCapturePhotoDelegate(request: request, bracketIdentities: [])
            let uniqueID = settings.uniqueID
            guard request.bindNativeSettingsID(uniqueID) else {
                return .failed(.failed(CaptureFailure(kind: .operationStalled(detail: "The native request identity was already retired or bound to other settings."), operation: "beginCapture.bindNativeIdentity")))
            }
            #if DEBUG
            let issueBegan = ProcessInfo.processInfo.systemUptime
            #endif
            photoOutput.capturePhoto(with: settings, delegate: delegate)
            #if DEBUG
            print("TruongCam timing native-capture-issue=\(Int((ProcessInfo.processInfo.systemUptime - issueBegan) * 1000))ms capture=\(intent.captureID)")
            #endif
            return .submitted(uniqueID: uniqueID, delegate: delegate)
        }

        switch step {
        case .submitted(let uniqueID, let delegate):
            retainForCallback(
                delegate: delegate, uniqueID: uniqueID, request: ticket.request, captureID: intent.captureID)
        case .failed(let outcome):
            if case .failed(let failure) = outcome {
                _ = ticket.request.finishWith(mappedFailure: failure)
            } else {
                _ = ticket.request.finishWith(mappedFailure: nil)
            }
            releaseRequest(captureID: intent.captureID)
        }

        // Release the delegate once the recorded terminal outcome exists. Any
        // number of parties may await the same value, so this cleanup can no
        // longer race the coordinator into a missing result.
        Task { [weak self] in
            _ = await ticket.request.terminal.wait()
            await self?.releaseRequest(captureID: intent.captureID)
        }
    }

    private func retainForCallback(
        delegate: PerCapturePhotoDelegate,
        uniqueID: Int64,
        request: PerCaptureRequest,
        captureID: CaptureID
    ) {
        // A synchronous/early terminal may have completed before the native queue
        // returns. Its source/terminal owners still drain; do not resurrect retired
        // delegate-map entries after that terminal watcher has already run.
        guard request.terminal.current == nil, inFlightRegistry.isInFlight(captureID) else { return }
        delegatesByUniqueID[uniqueID] = delegate
        requestsByUniqueID[uniqueID] = request
        uniqueIDByCaptureID[captureID] = uniqueID
    }

    private func releaseRequest(captureID: CaptureID) {
        guard let uniqueID = uniqueIDByCaptureID.removeValue(forKey: captureID) else { return }
        delegatesByUniqueID.removeValue(forKey: uniqueID)
        requestsByUniqueID.removeValue(forKey: uniqueID)
    }

    /// Picks a supported 8-bit luma-carrying format from what the connection
    /// actually advertises. Never assumes a format the device did not offer, and
    /// never falls back to BGRA, which the luma math explicitly rejects.
    private static var analysisLumaPixelFormats: [OSType] {
        [
            kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
            kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            kCVPixelFormatType_420YpCbCr8PlanarFullRange,
            kCVPixelFormatType_420YpCbCr8Planar,
        ]
    }

    private static func selectAnalysisPixelFormat(_ output: AVCaptureVideoDataOutput) -> OSType? {
        let supported = output.availableVideoPixelFormatTypes
        for candidate in analysisLumaPixelFormats where supported.contains(candidate) {
            return candidate
        }
        // REVIEW.md R01: an unsupported connection must be refused explicitly. The
        // previous fallback returned a format the connection had not advertised,
        // which is a silent downgrade presented as configuration.
        return nil
    }

    /// Installs the retained sample-buffer delegate on the analysis queue.
    ///
    /// The generation source is a closure over this actor's own published state
    /// rather than a second actor hop, so a frame is stamped with the
    /// configuration/layout in effect when it was acquired (REVIEW.md C08).
    private func installAnalysisDelegate(_ output: AVCaptureVideoDataOutput, generation: ConfigurationGeneration,
                                         lifecycle: UInt64, demandToken: UInt64) async {
        let handler = analysisHandler ?? AnalysisSampleBufferHandler(
            consumer: analysisSink, generationProvider: analysisGeneration, displayBridge: displayBridge)
        let installed = await sessionQueue.perform { [session, analysisQueue] in
            guard session.outputs.contains(where: { $0 === output }) else { return false }
            return Self.bindAnalysisDelegate(output, handler: handler, queue: analysisQueue, isCurrent: {
                self.generationBox.withLock { $0 } == generation
                    && self.lifecycleOwnership.isCurrent(lifecycle)
                    && self.analysisDemandOwnership.isCurrent(demandToken)
            })
        }
        guard installed, self.generation == generation, lifecycleOwnership.isCurrent(lifecycle),
              analysisDemandOwnership.isCurrent(demandToken) else { return }
        analysisHandler = handler
    }

    /// The native binding is serialized with output replacement, even when the
    /// actor resumes after a newer demand or lens change has taken ownership.
    @discardableResult
    static func bindAnalysisDelegate(_ output: AVCaptureVideoDataOutput,
                                    handler: any AVCaptureVideoDataOutputSampleBufferDelegate,
                                    queue: DispatchQueue, isCurrent: () -> Bool) -> Bool {
        guard isCurrent() else { return false }
        if output.sampleBufferDelegate !== handler || output.sampleBufferCallbackQueue !== queue {
            output.setSampleBufferDelegate(handler, queue: queue)
        }
        return isCurrent()
    }

    /// Republishes the stamp the analysis queue reads for the next frame.
    private func refreshAnalysisGeneration() {
        analysisGeneration.update(
            configuration: generation,
            layout: previewGeometry?.layoutGeneration ?? 0,
            histogramEnabled: analysisDemand.histogramEnabled,
            masksEnabled: analysisDemand.peakingEnabled || analysisDemand.zebrasEnabled,
            request: analysisDemand.loupeEnabled ? currentAnalysisRequest : nil)
    }

    static func photoPipelineOutputState(_ photoOutput: AVCapturePhotoOutput,
                                         _ videoOutput: AVCaptureVideoDataOutput) -> CapturePipelinePreparation.OutputState {
        CapturePipelinePreparation.OutputState(
            photoDeferred: photoOutput.isDeferredStartEnabled,
            videoDeferred: videoOutput.isDeferredStartEnabled,
            speedPrioritization: photoOutput.maxPhotoQualityPrioritization == .speed,
            responsiveSupported: photoOutput.isResponsiveCaptureSupported,
            responsiveEnabled: photoOutput.isResponsiveCaptureEnabled,
            zeroLagSupported: photoOutput.isZeroShutterLagSupported,
            zeroLagEnabled: photoOutput.isZeroShutterLagEnabled,
            deferredDeliverySupported: photoOutput.isAutoDeferredPhotoDeliverySupported,
            deferredDeliveryEnabled: photoOutput.isAutoDeferredPhotoDeliveryEnabled,
            discardsLateFrames: videoOutput.alwaysDiscardsLateVideoFrames)
    }

    /// Called only on the session queue inside the caller's existing owned
    /// configuration. The same conditional plan serves preparation and start's
    /// fallback, before any representative resource-preparation request.
    @discardableResult
    static func preparePhotoPipelineOptions(_ photoOutput: AVCapturePhotoOutput,
                                            _ videoOutput: AVCaptureVideoDataOutput,
                                            isCurrent: () -> Bool) -> Bool {
        guard isCurrent() else { return false }
        let changes = CapturePipelinePreparation.outputChanges(photoPipelineOutputState(photoOutput, videoOutput))
        return CapturePipelinePreparation.applyOutputChanges(changes, isCurrent: isCurrent) { change in
            switch change {
            case .disablePhotoDeferred:
                if photoOutput.isDeferredStartEnabled { photoOutput.isDeferredStartEnabled = false }
            case .disableVideoDeferred:
                if videoOutput.isDeferredStartEnabled { videoOutput.isDeferredStartEnabled = false }
            case .prioritizeSpeed:
                if photoOutput.maxPhotoQualityPrioritization != .speed { photoOutput.maxPhotoQualityPrioritization = .speed }
            case .disableResponsive:
                if photoOutput.isResponsiveCaptureSupported && photoOutput.isResponsiveCaptureEnabled { photoOutput.isResponsiveCaptureEnabled = false }
            case .disableZeroLag:
                if photoOutput.isZeroShutterLagSupported && photoOutput.isZeroShutterLagEnabled { photoOutput.isZeroShutterLagEnabled = false }
            case .disableDeferredDelivery:
                if photoOutput.isAutoDeferredPhotoDeliverySupported && photoOutput.isAutoDeferredPhotoDeliveryEnabled { photoOutput.isAutoDeferredPhotoDeliveryEnabled = false }
            case .discardLateFrames:
                if !videoOutput.alwaysDiscardsLateVideoFrames { videoOutput.alwaysDiscardsLateVideoFrames = true }
            }
        }
    }

    /// The analysis buffer always remains in native unmirrored sensor axes.
    /// Preview/photo orientation is owned separately and is never changed here.
    @discardableResult
    static func prepareAnalysisConnection(_ output: AVCaptureVideoDataOutput,
                                          isCurrent: () -> Bool) -> Bool {
        guard isCurrent(), let connection = output.connection(with: .video) else { return false }
        return prepareUnmirroredConnection(connection, zeroRotation: true, isCurrent: isCurrent)
    }

    /// Only mirror/crop policy is prepared for originals. A photo's orientation
    /// remains the per-capture frozen sensor rotation, applied at submission.
    @discardableResult
    static func prepareOriginalConnection(_ output: AVCapturePhotoOutput,
                                          isCurrent: () -> Bool) -> Bool {
        guard isCurrent(), let connection = output.connection(with: .video) else { return false }
        guard prepareUnmirroredConnection(connection, zeroRotation: false, isCurrent: isCurrent), isCurrent() else { return false }
        if connection.videoScaleAndCropFactor != 1 { connection.videoScaleAndCropFactor = 1 }
        return isCurrent()
    }

    private static func prepareUnmirroredConnection(_ connection: AVCaptureConnection,
                                                    zeroRotation: Bool,
                                                    isCurrent: () -> Bool) -> Bool {
        let changes = CapturePipelinePreparation.analysisConnectionChanges(.init(
            mirrorsSupported: connection.isVideoMirroringSupported,
            automaticMirroring: connection.automaticallyAdjustsVideoMirroring,
            mirrored: connection.isVideoMirrored,
            zeroRotationSupported: zeroRotation && connection.isVideoRotationAngleSupported(0),
            rotationDegrees: Double(connection.videoRotationAngle)))
        #if DEBUG
        let began = ProcessInfo.processInfo.systemUptime
        defer {
            if !changes.isEmpty {
                print("TruongCam timing native-connection-normalization=\(Int((ProcessInfo.processInfo.systemUptime - began) * 1000))ms analysis=\(zeroRotation) changes=\(changes.count) main=\(Thread.isMainThread)")
            }
        }
        #endif
        return CapturePipelinePreparation.applyAnalysisConnectionChanges(changes, isCurrent: isCurrent) { change in
            switch change {
            case .disableAutomaticMirroring:
                if connection.isVideoMirroringSupported && connection.automaticallyAdjustsVideoMirroring {
                    connection.automaticallyAdjustsVideoMirroring = false
                }
            case .disableMirroring:
                if connection.isVideoMirroringSupported && !connection.automaticallyAdjustsVideoMirroring && connection.isVideoMirrored {
                    connection.isVideoMirrored = false
                }
            case .zeroRotation:
                if connection.isVideoRotationAngleSupported(0) && connection.videoRotationAngle != 0 { connection.videoRotationAngle = 0 }
            }
        }
    }

    private static func configureForBayerRAW(
        session: AVCaptureSession,
        photoOutput: AVCapturePhotoOutput,
        videoOutput: AVCaptureVideoDataOutput,
        accounting operation: FinalTupleOperation,
        configurationMode: CaptureConfigurationMode,
        retirePhotoResources: () -> Void,
        isCurrent: () -> Bool
    ) throws {
        let requiredPreset: AVCaptureSession.Preset = configurationMode == .photoPreset ? .photo : .inputPriority
        // A live input swap already committed this topology. Recommitting unchanged
        // output options can restart resource preparation and block another frame.
        let needsMutation = session.sessionPreset != requiredPreset
            || !CapturePipelinePreparation.outputChanges(photoPipelineOutputState(photoOutput, videoOutput)).isEmpty
        guard needsMutation else { return }
        guard isCurrent() else {
            throw CaptureFailure(kind: .operationStalled(detail: "Camera start was superseded before native configuration."), operation: "start.configuration")
        }
        // AC03: this static path opens a REAL native configuration, so it records the
        // open/commit in the SAME held operation the rest of the service uses. Without this the
        // owned depth was a partial counter and could not account for the start path.
        operation.noteConfigurationOpened()
        session.beginConfiguration()
        defer {
            #if DEBUG
            let commitBegan = ProcessInfo.processInfo.systemUptime
            #endif
            session.commitConfiguration()
            operation.noteConfigurationCommitted()
            #if DEBUG
            print("TruongCam timing start-fallback-commit=\(Int((ProcessInfo.processInfo.systemUptime - commitBegan) * 1000))ms main=\(Thread.isMainThread)")
            #endif
        }
        retirePhotoResources()
        // Preserve the mode whose committed graph actually exposed Bayer RAW.
        // Forcing inputPriority here undoes a valid photo-preset preparation.
        if session.sessionPreset != requiredPreset {
            guard session.canSetSessionPreset(requiredPreset) else {
                throw CaptureFailure(kind: .unsupportedCapability(
                    detail: "The selected RAW configuration mode is no longer supported."), operation: "start.preset")
            }
            session.sessionPreset = requiredPreset
        }
        guard preparePhotoPipelineOptions(photoOutput, videoOutput, isCurrent: isCurrent) else {
            throw CaptureFailure(kind: .operationStalled(detail: "Camera start was superseded during native configuration."), operation: "start.configuration")
        }
        // `startRunning` is deliberately NOT called here. REVIEW.md C03: the
        // previous code started the session while a configuration block was still
        // open, which AVCaptureSession's documentation says raises
        // NSGenericException. That is an Objective-C exception, so Swift's `catch`
        // cannot repair it. Configuration commits here; the caller starts after.
    }

    /// Commits configuration, then starts the session. Kept separate so the
    /// ordering is explicit and testable.
    private static func startSessionAfterConfiguration(_ session: AVCaptureSession) {
        if !session.isRunning {
            session.startRunning()
        }
    }

    private static func supportsJPEG(_ output: AVCapturePhotoOutput) -> Bool {
        output.availablePhotoFileTypes.contains(.jpg) && output.supportedPhotoCodecTypes(for: .jpg).contains(.jpeg)
    }

    private static func supportsHEIF(_ output: AVCapturePhotoOutput) -> Bool {
        output.availablePhotoFileTypes.contains(.heic) && output.supportedPhotoCodecTypes(for: .heic).contains(.hevc)
    }

    private static func makeHEIFSettings(requestedDimensions: PixelDimensions, photoOutput: AVCapturePhotoOutput) throws -> AVCapturePhotoSettings {
        guard supportsHEIF(photoOutput) else {
            throw CaptureFailure(kind: .unsupportedCapability(detail: "HEIF capture is unavailable."), operation: "makeHEIFSettings")
        }
        let settings = AVCapturePhotoSettings(rawPixelFormatType: 0, rawFileType: nil, processedFormat: [AVVideoCodecKey: AVVideoCodecType.hevc], processedFileType: .heic)
        settings.maxPhotoDimensions = CMVideoDimensions(width: Int32(requestedDimensions.width), height: Int32(requestedDimensions.height))
        settings.photoQualityPrioritization = .speed
        settings.flashMode = .off
        return settings
    }

    private static func makeRAWOnlySettings(
        rawFormat: UInt32,
        rawFileType: String?,
        requestedDimensions: PixelDimensions,
        photoOutput: AVCapturePhotoOutput
    ) throws -> AVCapturePhotoSettings {
        let supportedFileTypes = photoOutput.availableRawPhotoFileTypes
        let preferredFileType: AVFileType? = {
            if let rawFileType, supportedFileTypes.contains(where: { $0.rawValue == rawFileType }) {
                return AVFileType(rawValue: rawFileType)
            }
            return supportedFileTypes.contains(.dng) ? .dng : nil
        }()

        let settings: AVCapturePhotoSettings
        // REVIEW.md F04: this used to fall back to
        // `AVCapturePhotoSettings(rawPixelFormatType:)` for an UNVALIDATED container.
        // Refuse instead, so an unsupported tuple is reported as unsupported rather
        // than silently producing a request with no proven DNG container.
        guard let preferredFileType,
              photoOutput.supportedRawPhotoPixelFormatTypes(for: preferredFileType).contains(rawFormat) else {
            throw CaptureFailure(
                kind: .unsupportedCapability(
                    detail: "The selected RAW pixel format is not offered for the DNG container on this committed configuration, so no settings were constructed."),
                operation: "makeRAWOnlySettings")
        }
        settings = AVCapturePhotoSettings(
            rawPixelFormatType: rawFormat,
            rawFileType: preferredFileType,
            processedFormat: nil,
            processedFileType: nil)

        settings.photoQualityPrioritization = .speed
        // Maximum dimensions are a request ceiling, not a guarantee.
        if requestedDimensions.isValid {
            settings.maxPhotoDimensions = CMVideoDimensions(
                width: Int32(clamping: requestedDimensions.width),
                height: Int32(clamping: requestedDimensions.height))
        }
        // Human-requested thumbnail-free DNGs. This applies to new native
        // requests; existing originals are never rewritten. The representation
        // customizer also strips any SDK-provided embedded thumbnail.
        settings.rawEmbeddedThumbnailPhotoFormat = nil
        settings.embeddedThumbnailPhotoFormat = nil
        settings.previewPhotoFormat = nil
        return settings
    }

    /// A bounded embedded-thumbnail size for a RAW request.
    ///
    /// A thumbnail is a preview, so it is capped well below the RAW ceiling. Returns
    /// nil for degenerate input rather than requesting a nonsense size.
    static func boundedEmbeddedThumbnailDimensions(
        for rawDimensions: PixelDimensions
    ) -> (width: Int, height: Int)? {
        guard rawDimensions.isValid, rawDimensions.width > 0, rawDimensions.height > 0 else {
            return nil
        }
        let longEdge = max(rawDimensions.width, rawDimensions.height)
        let targetLongEdge = min(longEdge, 1024)
        let scale = Double(targetLongEdge) / Double(longEdge)
        let width = max(1, Int((Double(rawDimensions.width) * scale).rounded()))
        let height = max(1, Int((Double(rawDimensions.height) * scale).rounded()))
        return (width, height)
    }

    // MARK: - Active format helpers

    private static func nativePhotoDimensionMatrix(_ device: AVCaptureDevice) -> [[PixelDimensions]] {
        device.formats.map { format in
            format.supportedMaxPhotoDimensions.map {
                PixelDimensions(width: Int($0.width), height: Int($0.height))
            }
        }
    }

    private var activeFormatIndex: Int? {
        guard let kind = selectedKind,
              let camera = snapshot.camera(kind),
              !camera.formats.isEmpty else { return nil }
        return camera.selectedFormatIndex ?? camera.formats.startIndex
    }

    private func activeFormatExposureLimits() -> ExposureLimits {
        guard let kind = selectedKind,
              let camera = snapshot.camera(kind),
              let index = activeFormatIndex,
              camera.formats.indices.contains(index) else {
            return ExposureLimits(minDurationSeconds: .nan, maxDurationSeconds: .nan,
                                  minISO: .nan, maxISO: .nan, minBiasEV: .nan, maxBiasEV: .nan)
        }
        return camera.formats[index].exposureLimits
    }

    private func activeFormatFocusLimits() -> FocusLimits {
        guard let kind = selectedKind,
              let camera = snapshot.camera(kind),
              let index = activeFormatIndex,
              camera.formats.indices.contains(index) else {
            return FocusLimits(supportsCustomLensPosition: false,
                               supportsPointOfInterest: false,
                               supportsContinuousAutoFocus: false,
                               supportsAutoFocus: false,
                               positionZeroDirectionVerified: false)
        }
        return camera.formats[index].focusLimits
    }

    private func activeFormatWhiteBalanceLimits() -> WhiteBalanceLimits {
        guard let kind = selectedKind,
              let camera = snapshot.camera(kind),
              let index = activeFormatIndex,
              camera.formats.indices.contains(index) else {
            return WhiteBalanceLimits.unavailable
        }
        return camera.formats[index].whiteBalanceLimits
    }

    /// The largest advertised legal photo-dimension ceiling for the active
    /// format. This is a request policy, not a measured output size.
    func largestAdvertisedPhotoDimensions() -> PixelDimensions? {
        guard let kind = selectedKind,
              let camera = snapshot.camera(kind),
              let index = activeFormatIndex,
              camera.formats.indices.contains(index) else { return nil }
        return camera.formats[index].supportedMaxPhotoDimensions.max { lhs, rhs in
            lhs.pixelCount < rhs.pixelCount
        }
    }

    // MARK: - Notifications

    private func installObservers() {
        guard !observersInstalled else { return }
        observersInstalled = true
        let center = NotificationCenter.default
        // Tokens are retained so these can be removed, and `object: session` scopes
        // them to THIS session: a process-wide observer would react to any other
        // session's interruption and misreport this camera's condition.
        let registrations: [(Notification.Name, String)] = [
            (AVCaptureSession.runtimeErrorNotification, "runtimeError"),
            (AVCaptureSession.interruptionEndedNotification, "interruptionEnded"),
            (AVCaptureSession.wasInterruptedNotification, "wasInterrupted"),
            (AVCaptureSession.didStartRunningNotification, "didStartRunning"),
            (AVCaptureSession.didStopRunningNotification, "didStopRunning"),
        ]
        var tokens: [NSObjectProtocol] = []
        for (name, label) in registrations {
            let token = center.addObserver(forName: name, object: session, queue: nil) { [weak self] notification in
                // Extract Sendable values here, on the notification thread, so the
                // actor hop carries no framework objects.
                // REVIEW.md G02: extract the typed code, not just prose. A
                // media-services reset arrives on this same notification and needs the
                // real rebuild path, which matching a localized string could never
                // reliably select.
                let error = notification.userInfo?[AVCaptureSessionErrorKey] as? Error
                let nsError = error as NSError?
                let isMediaServicesReset = nsError?.code == AVError.Code.mediaServicesWereReset.rawValue
                let description = error
                    .map { AVFoundationFailureMapper.failure($0, operation: "sessionRuntimeError")
                        .kind.userDescription }
                Task { await self?.handleNotification(
                    label: label,
                    errorDescription: description,
                    isMediaServicesReset: isMediaServicesReset) }
            }
            tokens.append(token)
        }
        for token in tokens { observerTokens.add(token) }
    }

    /// Removes the observers. Called from `stop`, which is the only place that can
    /// run without an actor hop.
    private func removeObservers() {
        let center = NotificationCenter.default
        for token in observerTokens.takeAll() { center.removeObserver(token) }
        observersInstalled = false
    }

    private func handleNotification(
        label: String,
        errorDescription: String?,
        isMediaServicesReset: Bool = false
    ) async {
        #if DEBUG
        print("TruongCam session-event: \(label) mediaServicesReset=\(isMediaServicesReset) detail=\(errorDescription ?? "none")")
        #endif
        if isMediaServicesReset {
            // The typed reset code is authoritative: the whole capture graph is
            // invalid and must be rebuilt (REVIEW.md G02).
            Task { await handleMediaServicesReset() }
            return
        }
        switch label {
        case "wasInterrupted":
            setCondition(.interrupted(
                reason: "The camera session was interrupted; capture is suspended until it resumes."))
            analysisOutput.send(.analysisUnavailable(
                reason: "The camera session was interrupted; preview analysis is suspended until it resumes."))
        case "runtimeError":
            // A recoverable runtime error still means the session cannot be trusted
            // until it is running again, so admission stays closed either way. A
            // media-services reset arrives on this same path, and it invalidates the
            // whole graph, so the recorded condition points at re-preparing.
            setCondition(.failed(.cameraInterrupted(
                detail: errorDescription ?? "The camera session reported a runtime error.")))
            analysisOutput.send(.analysisUnavailable(
                reason: errorDescription ?? "The camera session reported a runtime error."))
        case "interruptionEnded":
            // The interruption is over, but controls were reset by the system and
            // must be reapplied before capture, so the condition records that.
            setCondition(.reconfiguring)
            analysisOutput.send(.analysisUnavailable(
                reason: "Camera interruption ended; controls must be reapplied before capture."))
        case "didStartRunning":
            // Only a real start clears a recorded interruption.
            setCondition(.running)
        case "didStopRunning":
            // Input swaps can enqueue a stop notification that reaches this actor
            // after the replacement graph is already live. It must not demote a
            // successful switch or cause the UI to restart the session again.
            let owner = lifecycleOwnership.current
            let running = await sessionQueue.perform { [session] in session.isRunning }
            guard lifecycleOwnership.isCurrent(owner), !running else { return }
            setCondition(.stopping)
        default:
            break
        }
    }

    /// Records a condition AND publishes it, so the admission owner reacts.
    private func setCondition(_ condition: CameraLifecycle) {
        if case .running = condition {
            sessionCondition.clear()
        } else {
            sessionCondition.set(condition)
        }
        conditionBroadcaster.send(condition)
        statusBroadcaster.send(CameraSessionStatus(condition: condition, resetEpoch: sessionResetEpoch))
    }

    /// A media-services reset invalidates every capture object in the process.
    /// Records a configuration-ORDER violation when a camera fact is queried while a
    /// configuration is open (REVIEW.md H03).
    nonisolated private func recordConfigurationOrderIfNeeded(operation: String) {
        guard configurer.configurationDepth != 0 else { return }
        let depth = configurer.configurationDepth
        orderViolation.withLock { existing in
            if existing == nil {
                existing = "queried \(operation) at configuration depth \(depth); "
                    + "the session has not adopted it yet"
            }
        }
    }

    private func handleMediaServicesReset() async {
        // AC01: a media-services reset invalidates the service-owned identity at ENTRY, before
        // any suspension, so a command or readback already in flight cannot commit its result
        // across the reset. Previously only stop did this.
        identity.noteTerminal()
        sessionResetEpoch &+= 1
        // H02: a media-services reset invalidates the entire capture graph. The service
        // must REBUILD it, not merely record that something went wrong, or every later
        // capture runs against a graph the framework already discarded.
        setCondition(.failed(.cameraInterrupted(
            detail: MediaServicesResetSignal.detail)))
        analysisOutput.send(.analysisUnavailable(
            reason: MediaServicesResetSignal.analysisUnavailableReason))

        // 1. Let already-submitted requests reach their terminal outcome FIRST, so their
        //    retained source ownership drains before the graph they belong to is
        //    destroyed (REVIEW.md M03/P02). The TYPED result is consumed below: a timeout
        //    is disclosed rather than reported as a completed drain.
        // Z02: the reset runs the CORE-OWNED recovery chain, so the sequence the suite
        // executes is the one the adapter performs. The native work is supplied by the port
        // below; the ORDER (bounded drain → teardown → rebuild → admission) and the admission
        // gate belong to the chain.
        final class RebuildBox: @unchecked Sendable {
            private let mutex = Mutex<Bool>(true)
            func set(_ v: Bool) { mutex.withLock { $0 = v } }
            var value: Bool { mutex.withLock { $0 } }
        }
        let recoveryChain = SubmissionRecoveryChain(gate: drainGate)
        // The pass token this pass owns. A newer pass starting makes this one obsolete, so it
        // must not rebuild over, relabel or replace the newer graph.
        recoveryPassToken &+= 1
        liveRecoveryPass.withLock { $0 = recoveryPassToken }
        let passToken = recoveryPassToken
        activeResetRecoveryPasses.insert(passToken)
        defer { activeResetRecoveryPasses.remove(passToken) }
        let chainOutcome = await recoveryChain.run(
            longestPlannedSeconds: inFlightRegistry.longestPlannedSeconds,
            port: SubmissionRecoveryChain.Port(
                teardownGraph: { [weak self, photoOutput, videoOutput, session] in
                    // AD02: an obsolete pass must not stop a newer graph. The token is
                    // re-checked synchronously on the actor before the teardown is issued.
                    guard let self, await self.isCurrentRecoveryPass(passToken) else { return }
                    let previewPause = await self.displayBridge.nativeAccessGate.pauseAndDrainFrames()
                    defer { previewPause.release() }
                    await self.sessionQueue.perform {
                        // AO02: the actor guard above cannot protect the NATIVE effect, because the
                        // pass can be superseded during this queue hop. Re-checked here, AT the
                        // mutation, through the synchronous mirror.
                        guard self.liveRecoveryPass.withLock({ $0 }) == passToken else { return }
                        self.retirePreparedPhotoResourcesIfCurrent(photoOutput) {
                            self.liveRecoveryPass.withLock { $0 } == passToken
                        }
                        photoOutput.isAppleProRAWEnabled = false
                        videoOutput.setSampleBufferDelegate(nil, queue: nil)
                        if session.isRunning { session.stopRunning() }
                    }
                },
                rebuildAndRevalidate: { [weak self] in
                    await self?.rebuildAfterReset(passToken: passToken) ?? .prepareFailed
                },
                discloseOutstanding: { [weak self] count in
                    await self?.discloseOutstandingAfterReset(count, passToken: passToken)
                },
                reopenAdmission: { [weak self] in
                    await self?.reopenAdmissionAfterReset(passToken: passToken)
                }
            ))
        lastDrainOutcome = drainGate.outcome()
        // AB02: the outcome is CONSUMED, not discarded. A blocked pass leaves the graph
        // reconfiguring with admission closed (the port already published the disclosure);
        // only genuine recovery may be treated as a clean rebuild.
        // Only the pass that still owns the graph may publish its outcome.
        if recoveryPassToken == passToken {
            lastRecoveryOutcome = chainOutcome
        }

    }

}
struct SystemCameraPermissionPort: CameraPermissionPort {
    func currentAuthorization() async -> CameraAuthorization {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: return .authorized
        case .denied: return .denied
        case .restricted: return .restricted
        case .notDetermined: return .notDetermined
        @unknown default: return .restricted
        }
    }
    func requestAuthorization() async -> CameraAuthorization {
        _ = await AVCaptureDevice.requestAccess(for: .video)
        return await currentAuthorization()
    }
}

/// The framework's own Bayer answer, used by the native build.
///
/// `AVCapturePhotoOutput.isBayerRAWPixelFormat(_:)` is the documented classifier;
/// this exists so the capture coordinator never has to guess a FourCC pattern.
/// The one classifier the native target uses, for discovery facts AND for
/// delivered-source acceptance (REVIEW.md F04). A file-scope constant so both call
/// sites provably share one implementation.
let bayerClassifierForDiscovery: any BayerRAWClassifying = SystemBayerRAWClassifier()

struct SystemBayerRAWClassifier: BayerRAWClassifying {
    func isBayerRAW(_ pixelFormat: UInt32) -> Bool {
        AVCapturePhotoOutput.isBayerRAWPixelFormat(pixelFormat)
    }
}

/// The real session as a configuration-order port.
///
/// REVIEW.md H03: the port exists so the ordering contract (a query may only happen at
/// depth zero) can be exercised by a fake; in production it forwards to the session.
final class AVCaptureSessionConfigurer: SessionConfiguring, @unchecked Sendable {
    private let session: AVCaptureSession
    /// Guarded because the depth is read from the test's queue as well as the session
    /// queue.
    private let depth = Mutex(0)

    init(session: AVCaptureSession) { self.session = session }

    func beginConfiguration() {
        depth.withLock { $0 += 1 }
        session.beginConfiguration()
    }

    func commitConfiguration() {
        depth.withLock { $0 = max(0, $0 - 1) }
        session.commitConfiguration()
    }

    var configurationDepth: Int { depth.withLock { $0 } }
}

extension AVCaptureCameraService: CameraSessionStatusProviding {}
