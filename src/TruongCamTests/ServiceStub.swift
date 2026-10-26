import Foundation
import AVFoundation
import Synchronization

#if canImport(XCTest)
@testable import TruongCam
#endif

/// A narrow synthetic `CameraServicing` so the REAL `CameraViewModel` can be constructed without a
/// native camera.
///
/// AL01: `CameraServicing` has ~23 requirements, so the shipping model could not be exercised in
/// the portable verifier. This stub satisfies the CONTRACT so the actual model runs; it makes no
/// native claim, captures nothing and never reports Bayer capability.
actor SyntheticCameraService: CameraServicing, CaptureFormatPreparing {
    private(set) var formatPreparationRequests: [(format: CaptureFileFormat, generation: ConfigurationGeneration)] = []
    private var holdsFormatPreparation = false
    func setHoldsFormatPreparation(_ held: Bool) { holdsFormatPreparation = held }
    func prepareCaptureFormat(_ format: CaptureFileFormat, generation: ConfigurationGeneration) async {
        formatPreparationRequests.append((format, generation))
        while holdsFormatPreparation && !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(5))
        }
    }
    private var currentLifecycle: CameraLifecycle = .idle
    private var recordedCondition: CameraLifecycle = .idle
    private var lastSnapshot: AppliedControlSnapshot?
    private let preparationFailure: CaptureFailure?
    private let preparedCapability: CameraCapabilitySnapshot?
    private var currentFacingCapability: CameraCapabilitySnapshot?
    private var facingFixtures: [PhysicalCameraKind: CameraCapabilitySnapshot] = [:]
    func configureFacingFixtures(_ values: [PhysicalCameraKind: CameraCapabilitySnapshot]) { facingFixtures = values }
    private var startDelay: Duration = .zero
    private var heldStart: TerminalOutcomeBox<Bool>?
    func holdStart() { heldStart = TerminalOutcomeBox() }
    func releaseStart() { heldStart?.record(true); heldStart = nil }
    private(set) var readbackRequests = 0
    private var readbackTransform: (@Sendable (AppliedControlSnapshot) -> AppliedControlSnapshot)?
    func configureReadbackTransform(_ transform: (@Sendable (AppliedControlSnapshot) -> AppliedControlSnapshot)?) { readbackTransform = transform }
    private var heldReadback: TerminalOutcomeBox<Bool>?
    func holdReadback() { heldReadback = TerminalOutcomeBox() }
    func releaseReadback() { heldReadback?.record(true); heldReadback = nil }
    private var startOwner: UInt64 = 0
    private(set) var startRequests = 0
    private(set) var stopRequests = 0
    private var stopClearsCondition = false
    private var recoveryOutstandingCount = 0
    func configureRecoveryOutstanding(_ count: Int) { recoveryOutstandingCount = count }
    func configureStopClearsCondition() { stopClearsCondition = true }
    private var startFailures = 0
    func configureStartFailures(_ count: Int) { startFailures = count }
    private var heldStop: TerminalOutcomeBox<Bool>?
    func holdStop() { heldStop = TerminalOutcomeBox() }
    func releaseStop() { heldStop?.record(true); heldStop = nil }
    private(set) var prepareRequests = 0
    private(set) var previewGeometries: [PreviewGeometrySnapshot?] = []
    func configureStartDelay(_ delay: Duration) { startDelay = delay }
    private var controlDelay: Duration = .zero
    private var heldControls: TerminalOutcomeBox<Bool>?
    func holdControls() { heldControls = TerminalOutcomeBox() }
    func releaseControls() { heldControls?.record(true); heldControls = nil }
    func configureControlDelay(_ delay: Duration) { controlDelay = delay }
    private(set) var controlApplyCount = 0
    private(set) var analysisDemands: [AnalysisDemand] = []
    private(set) var analysisRequests: [AnalysisRequest?] = []
    private var heldAnalysisDemand: (call: Int, hold: PrepareHold)?
    /// Tightening-only suspension at the synthetic native boundary; no shipping delay.
    func holdAnalysisDemand(atCall call: Int, hold: PrepareHold) { heldAnalysisDemand = (call, hold) }

    private(set) var switchRequests: [PhysicalCameraKind] = []
    private var switchFailures: Set<PhysicalCameraKind> = []
    private var switchDelay: Duration = .zero
    private var heldSwitch: TerminalOutcomeBox<Bool>?
    func holdSwitch() { heldSwitch = TerminalOutcomeBox() }
    func releaseSwitch() { heldSwitch?.record(true); heldSwitch = nil }
    func configureSwitch(failures: Set<PhysicalCameraKind>, delay: Duration) {
        switchFailures = failures; switchDelay = delay
    }

    /// Inert by design: the stub exists so the model can be built and read, not to feed events.
    nonisolated let controlReadbackStream: AsyncStream<AppliedControlSnapshot> =
        AsyncStream { $0.finish() }
    nonisolated let sessionConditionStream: AsyncStream<CameraLifecycle> =
        AsyncStream { $0.finish() }
    private nonisolated let analysis = BoundedEventChannel<AnalysisOutput>(capacity: 4)
    nonisolated let analysisStream: BoundedOrderedSequence<AnalysisOutput>
    private nonisolated let displayBridge = PreviewDisplayBridge()
    // Match production ownership: the service retains its session; the display
    // bridge itself is deliberately weak and cannot own the native graph.
    private var retainedDisplaySession: AVCaptureSession?

    init(preparationFailure: CaptureFailure? = nil, capability: CameraCapabilitySnapshot? = nil) {
        self.preparationFailure = preparationFailure
        self.preparedCapability = capability
        self.analysisStream = analysis.subscribe()
    }

    func installDisplaySession(_ session: AVCaptureSession) {
        retainedDisplaySession = session
        displayBridge.install(session)
    }

    func recordCondition(_ value: CameraLifecycle) { recordedCondition = value }
    func markRunning() { currentLifecycle = .running }

    var lifecycle: CameraLifecycle { currentLifecycle }
    var capabilitySnapshot: CameraCapabilitySnapshot {
        currentFacingCapability ?? preparedCapability ?? .empty(generation: .zero, reason: "synthetic fixture; no native claim")
    }

    private(set) var preparedCameraRequests: [PhysicalCameraKind?] = []

    func prepare(desiredCamera: PhysicalCameraKind?) async -> Result<CameraCapabilitySnapshot, CaptureFailure> {
        prepareRequests += 1
        preparedCameraRequests.append(desiredCamera)
        if let preparationFailure { return .failure(preparationFailure) }
        return .success(capabilitySnapshot)
    }
    func start() async -> Result<Void, CaptureFailure> {
        startRequests += 1; startOwner &+= 1
        let owner = startOwner, delay = startDelay
        if let hold = heldStart { _ = await hold.wait() }
        if delay > .zero { try? await Task.sleep(for: delay) }
        guard owner == startOwner else {
            return .failure(CaptureFailure(kind: .operationStalled(detail: "synthetic superseded start"), operation: "start"))
        }
        if startFailures > 0 {
            startFailures -= 1
            return .failure(CaptureFailure(kind: .captureFailed(detail: "synthetic native start failure"), operation: "start"))
        }
        if stopClearsCondition { recordedCondition = .running }
        currentLifecycle = .running; return .success(())
    }
    func stop() async {
        stopRequests += 1; startOwner &+= 1
        let owner = startOwner
        if let hold = heldStop { _ = await hold.wait() }
        guard owner == startOwner else { return }
        currentLifecycle = .idle
        if stopClearsCondition { recordedCondition = .idle }
    }
    func switchPhysicalCamera(to kind: PhysicalCameraKind) async -> Result<CameraCapabilitySnapshot, CaptureFailure> {
        switchRequests.append(kind)
        if let hold = heldSwitch { _ = await hold.wait() }
        if switchDelay > .zero { try? await Task.sleep(for: switchDelay) }
        if switchFailures.contains(kind) {
            return .failure(CaptureFailure(kind: .unsupportedCapability(detail: "synthetic lens refusal"), operation: "switch"))
        }
        if let fixture = facingFixtures[kind] { currentFacingCapability = fixture }
        return .success(capabilitySnapshot)
    }

    func applyControls(
        revision: UInt64, exposure: ExposureChoice, biasEV: Double,
        focus: FocusIntent, whiteBalance: WhiteBalanceIntent, aperture: ApertureChoice = .auto
    ) async -> Result<AppliedControlSnapshot, CaptureFailure> {
        controlApplyCount += 1
        if let hold = heldControls { _ = await hold.wait() }
        if controlDelay > .zero { try? await Task.sleep(for: controlDelay) }
        var snapshot = AppliedControlSnapshot(
            generation: capabilitySnapshot.generation, requestRevision: revision, settlement: .settled,
            exposureChoice: exposure, biasEV: biasEV,
            observedDurationSeconds: nil, observedISO: nil, observedExposureTargetOffset: nil,
            focusMode: focus.mode, focusPosition: focus.position,
            whiteBalanceMode: whiteBalance.mode, whiteBalanceGains: nil,
            lensAperture: aperture.numericTarget ?? 1.8, videoZoomFactor: 1.0,
            photoConnectionScale: 1.0, photoConnectionCrop: 1.0,
            capturedAtUTC: Date(timeIntervalSince1970: 0))
        snapshot.apertureChoice = aperture
        snapshot.isApertureAutomatic = aperture.isAutomatic
        lastSnapshot = snapshot
        return .success(snapshot)
    }

    func setFocusPoint(normalizedDevicePoint: NormalizedDevicePoint, isTapToFocus: Bool) async -> Result<Void, CaptureFailure> {
        .success(())
    }
    func lastAppliedSnapshot() async -> AppliedControlSnapshot? { lastSnapshot }
    func currentControlReadback() async -> AppliedControlSnapshot? {
        readbackRequests += 1
        let reading = lastSnapshot.map { readbackTransform?($0) ?? $0 }
        if let hold = heldReadback { _ = await hold.wait() }
        return reading
    }
    func recordedSessionCondition() async -> CameraLifecycle { recordedCondition }
    func beginCapture(intent: CaptureIntent) async -> any CaptureRequestTicket {
        ChainCameraTicket(captureID: intent.captureID, intent: intent)
    }
    func setAnalysisDemand(_ demand: AnalysisDemand) async {
        analysisDemands.append(demand)
        if let held = heldAnalysisDemand, held.call == analysisDemands.count {
            heldAnalysisDemand = nil
            await held.hold.wait()
        }
    }
    func setAnalysisRequest(_ request: AnalysisRequest?) async { analysisRequests.append(request) }
    func updatePreviewGeometry(_ geometry: PreviewGeometrySnapshot?) async { previewGeometries.append(geometry) }
    func previewDisplayBridge() async -> PreviewDisplayBridge { displayBridge }
    func recordMeasuredRAWDimensions(_ dimensions: PixelDimensions, evidenceOrigin: String) async {}
}

/// An inert motion feed, so the model's level aid can be disabled without CoreMotion.
final class SyntheticLevelFeed: DeviceMotionLevelFeeding, @unchecked Sendable {
    private let lock = NSLock()
    private var running = false
    var isRunning: Bool { lock.lock(); defer { lock.unlock() }; return running }
    func start(onSample: @escaping @Sendable (DeviceGravitySample) -> Void) {
        lock.lock(); running = true; lock.unlock()
    }
    func stop() { lock.lock(); running = false; lock.unlock() }
}

extension SyntheticCameraService: CameraSequenceSettingsSurface {
    func sequenceSettingsSnapshot() async -> SequenceSettingsSnapshot? { nil }
    func sequenceExposureBaseline() async -> ExposureBaseline? { nil }
    func applySequenceSettings(_ settings: SequenceSettingsSnapshot) async -> Result<Void, CaptureFailure> {
        .success(())
    }
    func restoreSequenceSettings(_ settings: SequenceSettingsSnapshot) async -> Result<Void, CaptureFailure> {
        .success(())
    }
    func resetSequenceSettingsToAuto() async -> Result<Void, CaptureFailure> { .success(()) }
    func currentAppliedSnapshot() async -> AppliedControlSnapshot? { lastSnapshot }
}

extension SyntheticCameraService: CameraRecoveryStopping {
    func stopForTransientRecovery() async -> Result<Void, CaptureFailure> {
        guard recoveryOutstandingCount == 0 else {
            return .failure(CaptureFailure(kind: .cameraInterrupted(detail: "synthetic outstanding native/source obligations"), operation: "recovery.drain"))
        }
        await stop()
        return .success(())
    }
}

extension SyntheticCameraService: CameraViewModelCapabilitySource {
    func capabilitySnapshotForSequences() async -> CameraCapabilitySnapshot {
        .empty(generation: .zero, reason: "synthetic fixture; no native claim")
    }
}

/// Isolated preferences for UI/analysis regressions; never writes defaults.
struct SyntheticPreferenceStore: PreferenceStoring {
    var composition = CompositionPreferences()
    var captureFormat: CaptureFileFormat = .bayerDNG
    func loadPreferredCaptureFormat() -> CaptureFileFormat { captureFormat }
    func loadCompositionPreferences() -> CompositionPreferences? { composition }
    func storeCompositionPreferences(_ preferences: CompositionPreferences) {}
    func loadSequencePreferences() -> SequencePlanPreferences? { nil }
    func storeSequencePreferences(_ preferences: SequencePlanPreferences) {}
}
