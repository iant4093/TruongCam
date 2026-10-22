import Foundation
import Synchronization

// Native test bundles read the app's real types through the module; the
// standalone verifier compiles the app sources into the same executable and
// therefore cannot import a module. XCTest is only available in the native
// bundle, so it gates the import.
#if canImport(XCTest)
@testable import TruongCam
#endif

// AM03/AM04 registered recovery coverage: fixture intent correspondence and the
// connected consumer path.
//
// EVIDENCE BOUNDARY. Everything here runs against the REAL shipping types (the
// Core request owner, `CaptureCoordinator`, `LibraryStore`, `SubmissionDrainGate`,
// `SubmissionRecoveryChain`, `ResetRebuild`, the real `LibraryViewModel` and the
// real `SequenceCoordinator`) over narrow SYNTHETIC native/provider/index ports
// and synthetic bytes. No camera, no AVFoundation callback, no file provider and
// no iPhone executes, so this is logic/integration evidence only. D01-D11 remain
// NOT_RUN.
//
// Native SDK graph/device setters and real Files coordination remain synthetic.
// The connected cases execute current shipping Core, sequence, model, store,
// SQLite and library consumers. Native adapter bodies are separately compiled
// and current full Stop callers are tested with a narrow SDK substitute.

/// A relay so a synthetic camera surface can publish a recorded session condition
/// without being an actor itself. The condition is the same value the shipping
/// `CameraLifecycleResolver` consumes.
private actor RecoveryConditionRelay {
    private var condition: CameraLifecycle = .idle
    private var running = false
    private var resetEpoch: UInt64 = 0
    private nonisolated let statuses = LatestValueBroadcaster<CameraSessionStatus>()
    nonisolated var statusStream: AsyncStream<CameraSessionStatus> { statuses.subscribe() }
    func status() -> CameraSessionStatus { CameraSessionStatus(condition: condition, resetEpoch: resetEpoch) }
    private nonisolated let channel = LatestValueBroadcaster<CameraLifecycle>()
    nonisolated var stream: AsyncStream<CameraLifecycle> { channel.subscribe() }

    func record(_ value: CameraLifecycle) {
        condition = value
        if case .failed(.cameraInterrupted(let detail)) = value,
           MediaServicesResetSignal.matches(detail: detail) { resetEpoch &+= 1 }
        channel.send(value)
        statuses.send(status())
    }

    func coalescedResetFailure() -> [CameraSessionStatus] {
        let pendingRead = CameraSessionStatus(condition: .running, resetEpoch: resetEpoch)
        resetEpoch &+= 1
        let reset = CameraSessionStatus(condition: .failed(.cameraInterrupted(detail: MediaServicesResetSignal.detail)), resetEpoch: resetEpoch)
        condition = .failed(.cameraInterrupted(detail: "A reset left retained work outstanding."))
        // Satisfy an already-pending next() with a harmless prior state first.
        // The reset failure then occupies the one buffer slot and is overwritten
        // by the outstanding-work failure before the MainActor can consume it.
        return [pendingRead, reset, status()]
    }
    // Both updates run in one MainActor turn, so its consumer cannot observe the
    // overwritten failure value; only the cumulative reset identity survives.
    nonisolated func publishStatuses(_ values: [CameraSessionStatus]) {
        for value in values { statuses.send(value); channel.send(value.condition) }
    }
    func finishStream() { channel.finish(); statuses.finish() }
    func markRunning() { running = true }
    func current() -> CameraLifecycle { condition }
    func isRunning() -> Bool { running }

    /// The SHIPPING Core resolver's verdict, so readiness is production logic.
    func effectiveLifecycle() -> CameraLifecycle {
        CameraLifecycleResolver.effective(recorded: condition, sessionIsRunning: running)
    }
}

/// ONE camera surface that is BOTH the coordinator's `CaptureCameraSurface` and the
/// model's `CameraServicing`, so the real `CameraViewModel`, the real
/// `SequenceCoordinator` adapters and the real `CaptureCoordinator` all observe the
/// SAME graph instead of three disconnected fixtures.
///
/// Only the native surface is synthetic: `beginCapture` delegates to the fixture
/// ticket, and controls are reported by the fixture spy. No capture occurs.
/// AO03: parks a native preparation until released, so the reset/prepare ORDER is driven rather
/// than assumed. The release must be RECORDED, not only delivered: setting `entered` before the
/// continuation exists let a release fire into nothing and hang the first version of the case.
actor PrepareHold {
    private var entered = false
    private var released = false
    private var continuation: CheckedContinuation<Void, Never>?
    private var observers: [CheckedContinuation<Void, Never>] = []
    var didEnter: Bool { entered }

    func wait() async {
        await withCheckedContinuation { c in
            entered = true
            if released { c.resume() } else { continuation = c }
            for o in observers { o.resume() }
            observers = []
        }
    }

    func waitUntilEntered() async {
        if entered { return }
        await withCheckedContinuation { observers.append($0) }
    }

    func release() {
        released = true
        continuation?.resume()
        continuation = nil
    }
}

private final class SharedCameraSurface: CameraServicing, CameraCapabilityProviding, CameraSessionStatusProviding, CaptureCameraSurface,
                                         StagingOwnershipReporting,
                                         CameraSequenceSettingsSurface,
                                         CameraViewModelCapabilitySource,
                                         @unchecked Sendable {
    let spy: ChainCameraSpy
    let conditions: RecoveryConditionRelay
    let discoveredFixture: Bool
    /// Late-bound so the surface can be the COORDINATOR'S OWN camera (one shared graph) without a
    /// construction cycle: surface -> coordinator(camera: surface) -> surface.attach(capture:).
    private let captureBox = Mutex<CaptureCoordinator?>(nil)

    init(spy: ChainCameraSpy, conditions: RecoveryConditionRelay, capture: CaptureCoordinator? = nil,
         discoveredFixture: Bool = false) {
        self.discoveredFixture = discoveredFixture
        self.spy = spy
        self.conditions = conditions
        captureBox.withLock { $0 = capture }
    }

    func attach(capture: CaptureCoordinator) { captureBox.withLock { $0 = capture } }

    // MARK: StagingOwnershipReporting — forwarded so the REAL gate sees the staging obligations of
    // a graph whose coordinator camera is this surface.

    nonisolated func noteStagingStarted(_ captureID: CaptureID) {
        spy.noteStagingStarted(captureID)
    }

    nonisolated func noteStagingFinished(_ captureID: CaptureID) {
        spy.noteStagingFinished(captureID)
    }

    // MARK: CameraServicing

    var lifecycle: CameraLifecycle {
        get async { await conditions.effectiveLifecycle() }
    }

    var capabilitySnapshot: CameraCapabilitySnapshot {
        get async {
            var result = await spy.capabilitySnapshot
            guard discoveredFixture else { return result }
            let limits = tcSeqCapability()
            let dimensions = PixelDimensions(width: 4_032, height: 3_024)
            let format = FormatCapability(
                formatIdentifier: "synthetic connected fixture", videoDimensions: dimensions,
                cleanApertureDimensions: nil, supportedMaxPhotoDimensions: [dimensions],
                bayerPixelFormats: [0x1234], rawFileTypes: ["synthetic-dng"],
                supportsCustomExposureMode: .available(true),
                supportedPriorityCombinations: [.auto], exposureLimits: limits.exposureLimits,
                minLensAperture: nil, maxLensAperture: nil, focusLimits: limits.focusLimits,
                whiteBalanceLimits: .unavailable,
                videoFrameRateRanges: [], isVideoStabilizationSupported: false,
                secondaryNativeResolutionZoomFactors: [])
            result = CameraCapabilitySnapshot(
                generation: result.generation, hardwareModel: "synthetic", osVersion: "synthetic",
                sdkVersion: "synthetic", physicalCameras: [PhysicalCameraCapability(
                    kind: .wide, deviceType: "synthetic", uniqueDeviceIdentifier: nil,
                    modelIdentifier: "synthetic", formats: [format], selectedFormatIndex: 0,
                    bayerRAWDiscovery: .available([0x1234]), rawFileTypeDiscovery: .available(["synthetic-dng"]),
                    nativeBracketCountDiscovery: .unknown(reason: "no device"),
                    observedRAWDimensions: .unknown(reason: "no device"), observedRAWEvidenceOrigin: nil,
                    videoZoomFactorAtDiscovery: 1)], selectedCameraKind: .wide,
                configuredPhotoDimensions: dimensions, configuredPhotoDimensionsEvidence: "synthetic fixture",
                previewAnalysisFormat: nil, bayerCaptureSupported: .available(true),
                probeTimestampUTC: Date(timeIntervalSince1970: 0), notes: ["Not a device profile"])
            return result
        }
    }
    func currentCapability() async -> CameraCapabilitySnapshot? { await capabilitySnapshot }

    func prepare(desiredCamera: PhysicalCameraKind?) async -> Result<CameraCapabilitySnapshot, CaptureFailure> {
        await conditions.markRunning()
        return .success(await capabilitySnapshot)
    }

    func start() async -> Result<Void, CaptureFailure> {
        await conditions.markRunning()
        return .success(())
    }

    func stop() async { await conditions.record(.idle) }

    func switchPhysicalCamera(to kind: PhysicalCameraKind) async -> Result<CameraCapabilitySnapshot, CaptureFailure> {
        spy.advanceGeneration()
        return .success(await capabilitySnapshot)
    }

    func applyControls(
        revision: UInt64, exposure: ExposureChoice, biasEV: Double,
        focus: FocusIntent, whiteBalance: WhiteBalanceIntent
    ) async -> Result<AppliedControlSnapshot, CaptureFailure> {
        await spy.applyControls(
            revision: revision, exposure: exposure, biasEV: biasEV,
            focus: focus, whiteBalance: whiteBalance)
    }

    func setFocusPoint(
        normalizedDevicePoint: NormalizedDevicePoint, isTapToFocus: Bool
    ) async -> Result<Void, CaptureFailure> {
        .success(())
    }

    func lastAppliedSnapshot() async -> AppliedControlSnapshot? {
        await spy.currentControlReadback()
    }

    func currentControlReadback() async -> AppliedControlSnapshot? {
        await spy.currentControlReadback()
    }

    /// Inert and finished on purpose: this port exists so the model can be built. The
    /// cases below drive the model through the SAME condition value the recovery pass
    /// recorded on this surface rather than pretending a native stream delivered it.
    nonisolated let controlReadbackStream: AsyncStream<AppliedControlSnapshot> =
        AsyncStream { $0.finish() }
    nonisolated var sessionConditionStream: AsyncStream<CameraLifecycle> { conditions.stream }

    func recordedSessionCondition() async -> CameraLifecycle { await conditions.current() }
    nonisolated var sessionStatusStream: AsyncStream<CameraSessionStatus> { conditions.statusStream }
    func recordedSessionStatus() async -> CameraSessionStatus { await conditions.status() }

    /// The real coordinator owns submission, so the model's capture path reaches the
    /// real `CaptureCoordinator` — not a second synthetic camera service.
    func beginCapture(intent: CaptureIntent) async -> any CaptureRequestTicket {
        _ = captureBox.withLock { $0 }
        return await spy.beginCapture(intent: intent)
    }

    nonisolated let analysisStream: BoundedOrderedSequence<AnalysisOutput> = {
        let channel = BoundedEventChannel<AnalysisOutput>(capacity: 4)
        return channel.subscribe()
    }()

    nonisolated let displayBridge = PreviewDisplayBridge()
    nonisolated let sequenceSettingsStream: AsyncStream<SequenceSettingsSnapshot>? = nil

    func setAnalysisDemand(_ demand: AnalysisDemand) async {}
    func setAnalysisRequest(_ request: AnalysisRequest?) async {}
    func updatePreviewGeometry(_ geometry: PreviewGeometrySnapshot?) async {}
    func previewDisplayBridge() async -> PreviewDisplayBridge { displayBridge }
    func recordMeasuredRAWDimensions(_ dimensions: PixelDimensions, evidenceOrigin: String) async {}

    // MARK: CameraSequenceSettingsSurface

    func sequenceSettingsSnapshot() async -> SequenceSettingsSnapshot? {
        let capability = await spy.capabilitySnapshot
        let readback = await spy.currentControlReadback()
        return SequenceSettingsSnapshot(
            configurationGeneration: capability.generation,
            revision: readback?.requestRevision ?? 1,
            exposure: readback?.exposureChoice ?? .auto,
            biasEV: readback?.biasEV ?? 0,
            focus: FocusIntent(mode: .continuousAuto, position: nil, pointOfInterest: nil),
            whiteBalance: WhiteBalanceIntent(mode: .auto, temperatureAndTint: nil),
            maxDimensions: capability.configuredPhotoDimensions ?? PixelDimensions(width: 4_032, height: 3_024))
    }
    func sequenceExposureBaseline() async -> ExposureBaseline? { nil }
    func applySequenceSettings(_ settings: SequenceSettingsSnapshot) async -> Result<Void, CaptureFailure> {
        let result = await applyControls(revision: settings.revision, exposure: settings.exposure,
                                        biasEV: settings.biasEV, focus: settings.focus,
                                        whiteBalance: settings.whiteBalance)
        switch result {
        case .failure(let failure): return .failure(failure)
        case .success(let reading):
            guard reading.generation == settings.configurationGeneration,
                  reading.requestRevision == settings.revision, reading.settlement.isSettled else {
                return .failure(CaptureFailure(kind: .cameraInterrupted(detail: "Synthetic native control identity changed."),
                                               operation: "fixture.sequenceSettings"))
            }
            return .success(())
        }
    }
    func restoreSequenceSettings(_ settings: SequenceSettingsSnapshot) async -> Result<Void, CaptureFailure> {
        await applySequenceSettings(settings)
    }
    func resetSequenceSettingsToAuto() async -> Result<Void, CaptureFailure> { .success(()) }
    func currentAppliedSnapshot() async -> AppliedControlSnapshot? {
        await spy.currentControlReadback()
    }

    // MARK: CameraViewModelCapabilitySource

    func capabilitySnapshotForSequences() async -> CameraCapabilitySnapshot {
        await spy.capabilitySnapshot
    }
}

/// Proves which `PerCaptureRequest` object a ticket is actually backed by, so a
/// "the same request the coordinator drained" claim is an identity, not a value match.
private func recoveryRequestIdentity(_ request: PerCaptureRequest) -> ObjectIdentifier {
    ObjectIdentifier(request)
}

/// Records what a teardown/adapter port ACTUALLY invoked, so a "the sequence was
/// interrupted by the recovery pass" claim is an observed effect rather than a log.
private actor RecoveryEffectLog {
    private var entries: [String] = []
    private(set) var interruptReason: SequenceInterruptionReason?
    private(set) var stateWhileRecovering: SequenceCoordinatorState?

    func note(_ entry: String) { entries.append(entry) }
    func noteInterrupt(_ reason: SequenceInterruptionReason) { interruptReason = reason }
    func noteState(_ state: SequenceCoordinatorState) { stateWhileRecovering = state }
    var all: [String] { entries }
}

enum RecoveryRepairSuite {
    static func connectedCase(id: String, coalesceReset: Bool) -> TCCase {
        return TCCase(id: id, title: "Connected retained sequence, reset, restored model and library consumers") { r in
                // AN03. Every precondition is asserted BEFORE anything depends on it. The earlier
                // hangs were my own unasserted setup; the earlier "commit never invoked" failure is
                // retested here after fixing the `ChainCameraSpy` race where `attachCount` was
                // signalled before the intent ADOPTION ran.
                let gated = GatedFileCoordinatorMutator()
                guard let harness = await StorageHarness.make(
                    name: "an03a-graph", coordinator: gated) else {
                    r.check("the retained store harness was built", false); return
                }
                let spy = ChainCameraSpy()
                let conditions = RecoveryConditionRelay()
                let gate = SubmissionDrainGate()
                spy.ownershipGate = gate
                let chain = SubmissionRecoveryChain(gate: gate)
                let surface = SharedCameraSurface(spy: spy, conditions: conditions, discoveredFixture: true)
                let coordinator = CaptureCoordinator(
                    camera: surface, store: harness.store, clock: SystemMonotonicClock())
                surface.attach(capture: coordinator)
                let model = await CameraViewModel(
                    camera: surface, capture: coordinator,
                    metering: MeteringService(clock: SystemMonotonicClock()),
                    levelFeed: SyntheticLevelFeed())
                let indexDirectory = StorageFixture.temporaryDirectory("connected-index-" + id)
                try? FileManager.default.createDirectory(at: indexDirectory, withIntermediateDirectories: true)
                let index = SQLiteIndex(databaseURL: indexDirectory.appendingPathComponent("index.sqlite"))
                do { try await index.reset(libraryID: harness.libraryID, generation: harness.generation) }
                catch { r.check("SQLite initializes for this graph", false, "\(error)"); return }
                let librarySession = await LibrarySessionCoordinator(store: harness.store, index: index)
                let ingestedReceipts = SequenceTestBox<[CommitReceipt]>([])
                await MainActor.run {
                    model.onCommittedReceipts = { receipts in
                        await librarySession.ingestCommitted(receipts)
                        ingestedReceipts.mutate { $0.append(contentsOf: receipts) }
                    }
                }
                let sequenceExecutor = CaptureSequenceExecutor(capture: coordinator)
                let sourcePipeline = SequenceSourcePipeline(executor: sequenceExecutor)
                            let sequenceClock = VirtualMonotonicClock(start: 1_000)
                let sequence = SequenceCoordinator(environment: SequenceCoordinator.Environment(
                    clock: sequenceClock,
                    wallClock: SystemWallClock(),
                    storage: LibraryStoreSequenceAdapter(store: harness.store),
                    pipeline: sourcePipeline,
                    settings: CameraSequenceSettingsControl(camera: model),
                    baselineSettler: SyntheticBaselineSettler(),
                    bracketSubmitter: UnavailableNativeBracketSubmitter(),
                    focusDriver: FocusBracketDriver(
                        clock: SystemMonotonicClock(),
                        controller: SyntheticFocusController(),
                        pipeline: sourcePipeline),
                    capability: CameraSequenceCapabilityProvider(camera: model)))
                await model.attach(sequence: sequence)
                // AO03: the model OBSERVES the service's condition STREAM rather than being handed a
                // value; the surface's stream is the relay's live stream, not a finished one.
                await MainActor.run {
                    model.updateRootState(.writable(libraryID: harness.libraryID, generation: harness.generation))
                }
                await model.start()
                await MainActor.run { model.startSessionConditionObservation() }

                let captureID = spy.captureTicket.captureID
                let intent = CaptureIntent(
                    captureID: captureID, libraryID: harness.libraryID,
                    requestedDimensions: PixelDimensions(width: 4_032, height: 3_024),
                    exposure: .auto, biasEV: 0,
                    focus: FocusIntent(mode: .continuousAuto, position: nil, pointOfInterest: nil),
                    whiteBalance: WhiteBalanceIntent(mode: .auto, temperatureAndTint: nil),
                    configurationGeneration: .zero, rootGeneration: harness.generation,
                    physicalCameraKind: .wide, createdAtUTC: Date(timeIntervalSince1970: 0),
                    timezoneOffsetSeconds: 0, mode: .single)
                let task = Task { await coordinator.capture(intent: intent) }
                var turns = 0
                while spy.attachCount < 1 && turns < 20_000 { await Task.yield(); turns += 1 }
                guard spy.attachCount >= 1 else {
                    r.check("PRECONDITION: submitted to the retained path", false); return
                }
                r.check("PRECONDITION: submitted to the retained path", true)
                r.equal("PRECONDITION: the submission obligation is outstanding", gate.outstandingCount, 1)
                guard spy.captureTicket.request.intent.libraryID == harness.libraryID else {
                    r.check("PRECONDITION: the request is BOUND to the submitted library", false)
                    gated.release(); return
                }
                r.check("PRECONDITION: the request is BOUND to the submitted library", true)

                // Representation delivery can immediately stage/commit on another
                // executor. Arm the hold BEFORE publishing, so faster Simulator
                // scheduling cannot let the commit slip through the test gate.
                gated.arm()
                guard spy.captureTicket.deliverRepresentation(
                    bytes: StorageFixture.rawBytes(filler: 0x11),
                    dimensions: PixelDimensions(width: 4_032, height: 3_024)) else {
                    r.check("PRECONDITION: the source was PUBLISHED", false); gated.release(); return
                }
                r.check("PRECONDITION: the source was PUBLISHED", true)

                spy.captureTicket.deliver(.success)
                let commitDeadline = ContinuousClock.now.advanced(by: .seconds(3))
                while gated.enteredCount < 1, ContinuousClock.now < commitDeadline {
                    try? await Task.sleep(for: .milliseconds(1))
                }
                guard gated.enteredCount >= 1 else {
                    r.check("the provider commit was INVOKED and is parked", false)
                    gated.release(); return
                }
                r.check("the provider commit was INVOKED and is parked inside the provider", true)
                // AO03: the HELD INVOCATION is genuinely HELD at this point, not merely entered.
                r.equal("the provider hold reports itself HELD while the commit is parked",
                        gated.holdOutcome, .held)

                // Application verification runs on the same service/model, rather than
                // returning unconditional success from the rebuild port. Only the native
                // device/provider primitive responses are synthetic.
                @Sendable func prepareNativeFixture(_ pass: UInt64) async -> Result<Void, CaptureFailure> {
                    switch await surface.prepare(desiredCamera: .wide) {
                    case .success(let facts):
                        guard facts.generation == spy.configurationGeneration,
                              facts.bayerCaptureSupported == .available(true) else {
                            return .failure(CaptureFailure(kind: .noCamera, operation: "fixture.prepare"))
                        }
                        return .success(())
                    case .failure(let failure): return .failure(failure)
                    }
                }
                @Sendable func verifyNativeFixtureControls(_ pass: UInt64) async -> Result<Void, CaptureFailure> {
                    _ = await model.capabilitySnapshotForSequences()
                    guard let settings = await model.sequenceSettingsSnapshot() else {
                        return .failure(CaptureFailure(kind: .noCamera, operation: "fixture.controls"))
                    }
                    return await model.applySequenceSettings(settings)
                }
                let recoveryPass: UInt64 = 42
                let blocked = await chain.run(longestPlannedSeconds: 0, port: SubmissionRecoveryChain.Port(
                    teardownGraph: { await coordinator.stopAdmittingNewRequests() },
                    rebuildAndRevalidate: {
                        let prepared = await ResetRebuildSteps.prepare(
                            passToken: recoveryPass,
                            bumpGeneration: { _ in _ = spy.rebuildConfiguration() },
                            isCurrentPass: { token in token == recoveryPass },
                            prepare: prepareNativeFixture,
                            discloseFailure: { _, _ in })
                        guard prepared else { return .prepareFailed }
                        let verified = await ResetRebuildSteps.revalidateControls(
                            passToken: recoveryPass,
                            isCurrentPass: { token in token == recoveryPass },
                            applyControls: verifyNativeFixtureControls,
                            discloseFailure: { _, _ in })
                        return verified ? .verified : .controlsFailed
                    },
                    discloseOutstanding: { _ in await coordinator.noteWatchdogFired(captureID: captureID) },
                    reopenAdmission: { await coordinator.resumeAdmittingNewRequests() }))
                r.equal("recovery is BLOCKED by the real outstanding count",
                        blocked, .blockedByOutstanding(count: 1))

                gated.release()
                let result = await task.value
                r.check("the released commit produced a real receipt", result.didCommitAnything)
                // AO03: and the hold reports itself RELEASED, so the invocation/release pair is
                // closed rather than the commit merely having gone quiet.
                r.equal("and the provider hold reports itself RELEASED",
                        gated.holdOutcome, .released)

                // AO03: the rebuild port is NO LONGER a fixed `.verified`. The later pass runs the
                // REAL `ResetRebuildSteps` on the SAME graph, so the recovery actually drives the
                // shipping procedure and reports through the real condition channel.
                let livePass: UInt64 = 77
                let recovered = await chain.run(longestPlannedSeconds: 0, port: SubmissionRecoveryChain.Port(
                    teardownGraph: { await coordinator.stopAdmittingNewRequests() },
                    rebuildAndRevalidate: {
                        let prepared = await ResetRebuildSteps.prepare(
                            passToken: livePass,
                            bumpGeneration: { _ in _ = spy.rebuildConfiguration(); await conditions.record(.running) },
                            isCurrentPass: { token in token == livePass },
                            prepare: prepareNativeFixture,
                            discloseFailure: { detail, token in
                                guard token == livePass else { return }
                                await conditions.record(.failed(.cameraInterrupted(detail: detail)))
                            })
                        guard prepared else { return .prepareFailed }
                        let verified = await ResetRebuildSteps.revalidateControls(
                            passToken: livePass,
                            isCurrentPass: { token in token == livePass },
                            applyControls: verifyNativeFixtureControls,
                            discloseFailure: { detail, token in
                                guard token == livePass else { return }
                                await conditions.record(.failed(.cameraInterrupted(detail: detail)))
                            })
                        return verified ? .verified : .controlsFailed
                    },
                    discloseOutstanding: { _ in await coordinator.noteWatchdogFired(captureID: captureID) },
                    reopenAdmission: { await coordinator.resumeAdmittingNewRequests() }))
                r.equal("a later pass recovers through the REAL rebuild procedure", recovered, .recovered)
                r.check("and downstream admission genuinely reopens", await coordinator.canAdmitCapture())

                // AO03 objection 6: assert what the REAL rebuild procedure actually DROVE on this
                // graph. Asserted HERE, before the later reset overwrites the relay's condition.
                r.equal("the REAL rebuild procedure ran ON THIS GRAPH and recorded success",
                        await conditions.current(), .running)

                _ = await model.capabilitySnapshotForSequences()
                let attachBefore = spy.attachCount
                // ARM FIRST: the frame's own provider commit must park, so the reset below lands on
                // the SAME in-flight frame rather than on an already-recovered graph.
                let frameCommitBefore = gated.enteredCount
                gated.arm()
                let plan = SequencePlan(
                    libraryID: harness.libraryID,
                    configurationGeneration: spy.configurationGeneration,
                    rootGeneration: harness.generation, kind: .interval,
                    specification: .interval(IntervalPlan(count: 2, intervalSeconds: 3)),
                    createdAtUTC: SeqTestSupport.nowUTC)
                let runTask = Task { await model.executeSequence(plan) }
                var reached = await driveVirtualClock(sequenceClock) { spy.attachCount > attachBefore }
                var rt = 0
                while !reached && rt < 1200 {
                    try? await Task.sleep(nanoseconds: 5_000_000); rt += 1
                    reached = spy.attachCount > attachBefore
                }
                r.check("the ACTIVE plan's frame reached the REAL coordinator on this graph", reached)
                if let frameTicket = spy.lastCreatedTicket,
                   frameTicket.captureID != spy.captureTicket.captureID {
                    _ = frameTicket.deliverRepresentation(
                        bytes: StorageFixture.rawBytes(filler: 0x88),
                        dimensions: PixelDimensions(width: 4_032, height: 3_024))
                    frameTicket.deliver(.success)
                }
                var frameTurns = 0
                while gated.enteredCount <= frameCommitBefore && frameTurns < 1200 {
                    try? await Task.sleep(nanoseconds: 5_000_000); frameTurns += 1
                }
                r.check("the SEQUENCE FRAME's own provider commit is genuinely IN FLIGHT (parked)",
                        gated.enteredCount > frameCommitBefore)
                r.equal("and the frame's hold reports itself HELD",
                        gated.holdOutcome, .held)
                // Deliver through the real condition observation task while THIS provider
                // invocation remains held. Admission closes only after the reset interruption
                // effect has been delivered, which is the ordering barrier before release.
                if coalesceReset {
                    let updates = await conditions.coalescedResetFailure()
                    await MainActor.run { conditions.publishStatuses(updates) }
                    r.check("the latest condition no longer contains the reset marker",
                            await conditions.current() != .failed(.cameraInterrupted(detail: MediaServicesResetSignal.detail)))
                } else {
                    await conditions.record(.failed(.cameraInterrupted(detail: MediaServicesResetSignal.detail)))
                }
                var resetTurns = 0
                while await coordinator.canAdmitCapture(), resetTurns < 1200 {
                    try? await Task.sleep(nanoseconds: 5_000_000)
                    resetTurns += 1
                }
                r.check("the recorded reset closes admission while the same frame remains held",
                        !(await coordinator.canAdmitCapture()))
                r.equal("the retained frame is still held at reset delivery", gated.holdOutcome, .held)
                let rebuildHold = PrepareHold()
                let resetPass: UInt64 = 101
                let activeResetPass = LatestValueBroadcaster<UInt64>()
                activeResetPass.send(resetPass)
                // Start the real recovery chain while THIS submitted frame is still
                // held. The synthetic native scheduler delays rebuild work so the
                // positive restoration ordering is deterministic; drain remains real.
                let resetTask = Task {
                    await chain.run(longestPlannedSeconds: 0, port: SubmissionRecoveryChain.Port(
                        teardownGraph: { await coordinator.stopAdmittingNewRequests() },
                        rebuildAndRevalidate: {
                            await rebuildHold.wait()
                            let outcome = await ResetRebuild.run(port: ResetRebuild.Port(
                                prepare: {
                                    await ResetRebuildSteps.prepare(
                                        passToken: resetPass,
                                        bumpGeneration: { token in
                                            guard activeResetPass.current == token else { return }
                                            _ = spy.rebuildConfiguration()
                                        },
                                        isCurrentPass: { activeResetPass.current == $0 },
                                        prepare: prepareNativeFixture,
                                        discloseFailure: { detail, token in
                                            guard activeResetPass.current == token else { return }
                                            await conditions.record(.failed(.cameraInterrupted(detail: detail)))
                                        })
                                },
                                revalidateControls: {
                                    await ResetRebuildSteps.revalidateControls(
                                        passToken: resetPass,
                                        isCurrentPass: { activeResetPass.current == $0 },
                                        applyControls: verifyNativeFixtureControls,
                                        discloseFailure: { detail, token in
                                            guard activeResetPass.current == token else { return }
                                            await conditions.record(.failed(.cameraInterrupted(detail: detail)))
                                        })
                                }))
                            switch outcome {
                            case .rebuilt: return .verified
                            case .prepareFailed: return .prepareFailed
                            case .controlsFailed: return .controlsFailed
                            }
                        },
                        discloseOutstanding: { _ in },
                        // As in the native service, the recorded recovery condition
                        // drives the model's actual start and admission restoration.
                        reopenAdmission: { await conditions.record(.reconfiguring) }))
                }
                var drainEntryTurns = 0
                while gate.activeDrainWaitCount == 0, drainEntryTurns < 1200 {
                    try? await Task.sleep(nanoseconds: 5_000_000); drainEntryTurns += 1
                }
                r.equal("the reset chain is actually awaiting THIS frame's drain", gate.activeDrainWaitCount, 1)
                r.equal("the frame remains inside its provider while reset waits", gated.holdOutcome, .held)
                gated.release()
                // A missing reset must produce a bounded assertion failure, not leave
                // the test parked on the next interval's virtual deadline.
                var finishTurns = 0
                while await sequence.snapshot().state.isActive, finishTurns < 200 {
                    try? await Task.sleep(nanoseconds: 5_000_000); finishTurns += 1
                }
                if await sequence.snapshot().state.isActive {
                    r.check("the reset terminates the run without a test cancellation", false)
                    await sequence.cancel(sequenceID: plan.sequenceID)
                    _ = await driveVirtualClock(sequenceClock) { !(await sequence.snapshot().state.isActive) }
                }
                guard let runResult = await runTask.value else {
                    r.check("the production model executed this plan", false)
                    await MainActor.run { model.stopSessionConditionObservation() }
                    await conditions.finishStream()
                    return
                }
                r.check("the model presents the completed interruption", await model.sequenceStatusLine?.localizedCaseInsensitiveContains("interrupted") == true)
                let observed = await sequence.snapshot()
                var reportedReason: SequenceInterruptionReason?
                if case .interrupted(_, let reason) = observed.state { reportedReason = reason }
                r.equal("the ACTIVE sequence reached a TERMINAL interruption WITH THE RESET REASON",
                        reportedReason, .mediaServicesReset)
                r.equal("the completed run reports an INTERRUPTED status", runResult.status, .interrupted)
                r.equal("the acquired sequence frame remains committed", runResult.committedReceipts.count, 1)
                r.check("the run has no acquisition failure", runResult.failure == nil,
                        "\(String(describing: runResult.failure))")
                r.equal("and the returned result is for THIS plan",
                        runResult.sequenceID, plan.sequenceID)
                r.equal("the real sequence settings adapter restored this run", runResult.restoration, .restored)
                if let receipt = runResult.committedReceipts.first {
                    r.equal("the retained frame belongs to this sequence", receipt.metadata.sequence?.id,
                            plan.sequenceID.rawValue)
                    r.equal("the retained frame is source zero", receipt.metadata.sequence?.index, 0)
                    r.equal("the retained frame digest matches its delivered bytes", receipt.verifiedSHA256.hex,
                            StorageFixture.sha256Hex(StorageFixture.rawBytes(filler: 0x88)))
                }
                if let document = try? await harness.store.readSequenceDocument(plan.sequenceID) {
                    r.equal("the actual stored sequence is interrupted", document.status, .interrupted)
                    r.equal("the stored sequence retains the acquired frame", document.completedSources.count, 1)
                    r.equal("the stored sequence records restored settings", document.restorationStatus, .restored)
                    r.equal("the stored sequence reports the same reset reason", document.errorSummary,
                            runResult.progress.errorSummary)
                } else { r.check("the actual sequence document can be read", false) }

                await rebuildHold.waitUntilEntered()
                r.equal("the same submitted frame retired before native rebuild", gate.outstandingCount, 0)
                let generationBeforeRebuild = spy.configurationGeneration
                await rebuildHold.release()
                let restored = await resetTask.value
                r.equal("the same-frame reset chain prepared and verified controls", restored, .recovered)
                r.equal("the connected native primitive rebuilt this graph's generation",
                        spy.configurationGeneration, ConfigurationGeneration.next(generationBeforeRebuild))
                var readinessTurns = 0
                while !(await model.isShutterEnabled), readinessTurns < 1200 {
                    try? await Task.sleep(nanoseconds: 5_000_000); readinessTurns += 1
                }
                r.check("the same model enables the shutter after verified recovery", await model.isShutterEnabled)
                r.check("the model cleared the reset failure only after recovery", await model.lastFailure == nil)

                // AO03: a GENUINELY SUBSEQUENT retained capture. Its identity is NEW, so the fixture
                // CREATES a ticket for it; delivery must target THAT ticket. Delivering to the
                // original `spy.captureTicket` left the second task awaiting a different ticket -
                // which is what hung.
                let writesBeforeCapture = gated.writeCount
                let receiptsBeforeCapture = ingestedReceipts.value.count
                let attachBeforeNext = spy.attachCount
                let nextTask = Task { await model.captureNow() }
                var nextTurns = 0
                while spy.attachCount <= attachBeforeNext && nextTurns < 20_000 {
                    await Task.yield(); nextTurns += 1
                }
                let admitted = spy.attachCount > attachBeforeNext
                r.check("a genuinely SUBSEQUENT capture is admitted after recovery", admitted)
                if admitted, let nextTicket = spy.lastCreatedTicket {
                    let nextIntent = nextTicket.request.intent
                    let frozenCaptureID = nextIntent.captureID
                    let frozenLibraryID = nextIntent.libraryID
                    let frozenRootGeneration = nextIntent.rootGeneration
                    _ = nextTicket.deliverRepresentation(
                        bytes: StorageFixture.rawBytes(filler: 0x22),
                        dimensions: PixelDimensions(width: 4_032, height: 3_024))
                    nextTicket.deliver(.success)
                    await nextTask.value
                    await model.waitForReceiptPublication()
                    let nextReceipts = Array(ingestedReceipts.value.dropFirst(receiptsBeforeCapture))
                    r.check("the shipping model reports the new verified save", await !model.lastCommittedReceipts.isEmpty)
                    r.check("and it ingests its OWN real receipt on the recovered graph", !nextReceipts.isEmpty)

                    // AO03: FROZEN IDENTITY, BYTE COUNT/SHA256 and EXACTLY-ONCE counts.
                    if let receipt = nextReceipts.first {
                        r.equal("the receipt carries the FROZEN capture identity",
                                receipt.captureID, frozenCaptureID)
                        r.equal("the receipt carries the FROZEN library identity",
                                receipt.libraryID, frozenLibraryID)
                        r.equal("the receipt carries the FROZEN root generation",
                                receipt.rootGeneration, frozenRootGeneration)
                        r.equal("and the FROZEN submitted byte count",
                                receipt.verifiedByteCount, Int64(StorageFixture.rawBytes(filler: 0x22).count))
                        r.equal("with the EXACT SHA256 digest of the delivered bytes",
                                receipt.verifiedSHA256.hex,
                                StorageFixture.sha256Hex(StorageFixture.rawBytes(filler: 0x22)))
                        // Submitted CaptureID is metadata identity; native settings identity is
                        // checked separately by the bound request owner, not inferred from it.
                        r.equal("the receipt metadata carries the FROZEN submitted capture identity",
                                receipt.metadata.captureID, frozenCaptureID)
                        r.equal("and the metadata agrees on the library identity",
                                receipt.metadata.libraryID, frozenLibraryID)
                        // AO03: `sequence` identity. This is a SINGLE capture, so it must carry NO
                        // sequence identity - a stray sequenceID would mean it was attributed to a
                        // plan it never belonged to.
                        r.check("and a SINGLE capture carries NO sequence identity",
                                nextIntent.sequenceID == nil && nextIntent.sequenceOrdinal == nil)
                    }
                    r.equal("exactly ONE receipt was committed for the subsequent capture",
                            nextReceipts.count, 1)
                    r.equal("and the source was published EXACTLY ONCE",
                            nextTicket.stagedRepresentationCount, 1)
                    // AO03: EXACTLY-ONCE staging and terminal accounting, taken from the COORDINATOR's
                    // own reports rather than a hand-written fixture call.
                    r.equal("staging started once per REAL submission on this graph",
                            spy.stagingStartedCount, 3)
                    r.equal("staging finished once per REAL submission on this graph",
                            spy.stagingFinishedCount, 3)
                    r.check("and the drain gate leaks nothing beyond the sequence frame's own obligation",
                            gate.outstandingCount <= 1)
                    // AO03: TRUTHFUL control readback on the same graph.
                    let readback = await spy.currentControlReadback()
                    r.check("the SAME graph reports a truthful control readback", readback != nil)
                    // AO03 ORDER MATRIX: a LATE source arriving AFTER the terminal must be refused,
                    // so the sequencing of publication against terminal is enforced on this graph.
                    let lateAccepted = nextTicket.deliverRepresentation(
                        bytes: StorageFixture.rawBytes(filler: 0x33),
                        dimensions: PixelDimensions(width: 4_032, height: 3_024))
                    r.check("a LATE source after the terminal is REFUSED",
                            !lateAccepted)
                    r.equal("and the late source did not publish a second representation",
                            nextTicket.stagedRepresentationCount, 1)
                    // AO03 ORDER MATRIX: a Stop AFTER a completed capture leaves the graph
                    // consistent and does not disturb the already-committed receipt.
                    let receiptsBeforeStop = nextReceipts.count
                    await coordinator.stopAdmittingNewRequests()
                    r.check("a Stop after the capture leaves admission closed, not half-open",
                            !(await coordinator.canAdmitCapture()))
                    r.equal("and the committed receipt is untouched by that Stop",
                            nextReceipts.count, receiptsBeforeStop)
                    // AO03: TERMINAL accounting, separable from staging: exactly one retirement.
                    r.equal("the terminal was retired EXACTLY ONCE for that capture",
                            nextTicket.terminalCount, 1)
                    // AO03: a WRITER count distinct from staging. The store legitimately performs
                    // SEVERAL coordinated writes per capture (original, sidecar, marker), so the
                    // honest assertion is that THIS capture caused provider writes - asserted as a
                    // DELTA measured across it, not a brittle magic total.
                    r.check("this capture caused coordinated WRITES to reach the provider",
                            gated.writeCount > writesBeforeCapture)

                    // AO03: REAL SQLite on THIS path, carrying the ACTUAL committed card rather than
                    // an unrelated fixture. The receipt's own identity/bytes are what is indexed.
                    if nextReceipts.first != nil {
                        r.check("the shipping receipt callback updates SQLite without an index issue",
                                await librarySession.issues.isEmpty)
                        r.equal("the shipping sequence callback ingests this sequence receipt", ingestedReceipts.value.first?.captureID,
                                runResult.committedReceipts.first?.captureID)
                        // AQ03: consumed through the ACTUAL LibraryModel, not a manual page fetch.
                        let libraryModel = await LibraryViewModel(index: index, store: nil)
                        await libraryModel.loadFirstPage()
                        r.equal("the REAL LibraryModel lists the sequence and the new single capture",
                                await libraryModel.loadedSourceCount, 2)
                    }
                } else {
                    nextTask.cancel()
                    _ = await nextTask.value
                }
                await MainActor.run { model.stopSessionConditionObservation() }
                await conditions.finishStream()
            }
    }

    static let suite = TCSuite(
        id: "RecoveryRepair",
        title: "AM03/AM04 recovery fixture intent correspondence and connected consumers",
        cases: [

            TCCase(id: "AM03b", title: "The REAL submission/retirement registry notifies the gate exactly once") { r in
                // AM03: this drives the ACTUAL Core owner the shipping service delegates to, so the
                // submission/retirement algorithm executes rather than a fixture standing in.
                let registry = InFlightRequestRegistry()
                let first = CaptureID()
                let second = CaptureID()
                r.equal("nothing is outstanding initially", registry.inFlightCount, 0)

                r.check("a first submission performs the transition",
                        registry.noteSubmitted(captureID: first, plannedSeconds: 2.0))
                r.check("and a DUPLICATE submission is visible, not silently absorbed",
                        !registry.noteSubmitted(captureID: first, plannedSeconds: 2.0))
                r.equal("with exactly one outstanding request", registry.inFlightCount, 1)
                r.equal("and its planned duration recorded", registry.longestPlannedSeconds, 2.0)

                _ = registry.noteSubmitted(captureID: second, plannedSeconds: 5.0)
                r.equal("the LONGEST planned duration is reported", registry.longestPlannedSeconds, 5.0)

                // AN03: the submission/retirement is now tied to a REAL request owner, so the
                // retirement corresponds to an actual native-callback TERMINAL rather than a bare
                // boolean. The request is the shipping Core type; only the callback is synthetic.
                let liveID = CaptureID()
                let liveRequest = PerCaptureRequest(
                    captureID: liveID,
                    intent: ChainCameraSpy.defaultIntent(captureID: liveID),
                    rawPixelFormatType: 0x4247_4734,
                    rawFileType: "com.adobe.raw-image",
                    maximumRepresentations: 2)
                _ = registry.noteSubmitted(captureID: liveID, plannedSeconds: 1.0)
                r.check("the live request is OUTSTANDING before its terminal",
                        registry.isInFlight(liveID))
                let terminal = liveRequest.finishWith(mappedFailure: nil)
                r.check("its terminal is recorded by the REAL owner",
                        liveRequest.terminal.current != nil)
                if registry.retire(captureID: liveID) { /* gate notified exactly once */ }
                r.check("and retiring after that terminal clears the obligation",
                        !registry.isInFlight(liveID))
                _ = terminal

                // AN03: the registry's retirement now drives a REAL `SubmissionDrainGate`, so the
                // obligation is asserted at the actual gate rather than from registry booleans.
                let gate = SubmissionDrainGate()
                let gated = CaptureID()
                _ = registry.noteSubmitted(captureID: gated, plannedSeconds: 1.0)
                gate.noteSubmitted(gated)
                // Staging is registered FIRST, then the terminal retires the native obligation —
                // the order the shipping surface reports them in.
                gate.noteStagingStarted(gated)
                if registry.retire(captureID: gated) { gate.noteTerminal(gated) }
                r.equal("the REAL gate holds one outstanding obligation before staging finishes",
                        gate.outstandingCount, 1)
                gate.noteStagingFinished(gated)
                r.equal("and the registry's retirement RETIRES it at the real gate",
                        gate.outstandingCount, 0)

                // The gate must be told exactly once, on the FIRST retirement.
                r.check("the first retirement reports the gate notification", registry.retire(captureID: first))
                r.check("a SECOND retirement does NOT report it again", !registry.retire(captureID: first))
                r.check("retiring an unknown request reports nothing", !registry.retire(captureID: CaptureID()))
                r.equal("and the retired request is no longer outstanding", registry.isInFlight(first), false)
                r.check("while the other remains outstanding", registry.isInFlight(second))
                r.equal("with its planned duration still reflected", registry.longestPlannedSeconds, 5.0)

                _ = registry.retire(captureID: second)
                r.equal("once everything retires, nothing is outstanding", registry.inFlightCount, 0)
                r.equal("and the drain bound returns to zero", registry.longestPlannedSeconds, 0)
            },

            TCCase(id: "AM03c", title: "The REAL on-disk SQLite index feeds the library model, not the in-memory port") { r in
                // AM03: the recovery path used an in-memory `LibraryIndexing` port. The real
                // `SQLiteIndex` is NOT portability-blocked — it compiles and EXECUTES in the
                // portable verifier — so this drives it against a real database file and pages the
                // shipping `LibraryViewModel` from it.
                let directory = URL(fileURLWithPath: NSTemporaryDirectory())
                    .appendingPathComponent("am03c-\(UUID().uuidString)")
                try? FileManager.default.createDirectory(
                    at: directory, withIntermediateDirectories: true)
                defer { try? FileManager.default.removeItem(at: directory) }
                let databaseURL = directory.appendingPathComponent("library-index.sqlite")

                let index = SQLiteIndex(databaseURL: databaseURL)
                let libraryID = LibraryID()
                let cards = StorageFixture.cards(
                    count: 3, libraryID: libraryID, startingAt: StorageFixture.fixedDate)
                do {
                    try await index.reset(libraryID: libraryID, generation: RootGeneration(1))
                    try await index.upsert(scanned: cards)
                } catch {
                    r.check("the real SQLite index accepted the reset and upsert", false, "\(error)")
                    return
                }
                r.check("the real SQLite index accepted the reset and upsert", true)

                // The SHIPPING model reads through the real on-disk index.
                let model = await LibraryViewModel(index: index, store: nil)
                await model.loadFirstPage()
                r.equal("the REAL SQLite-backed model lists every committed card",
                        await model.loadedSourceCount, cards.count)
                r.check("and reports no page-load failure",
                        await model.pageLoadFailure == nil)
            },

            TCCase(id: "AM03d", title: "The REAL rebuild steps bump the generation and guard ownership at each boundary") { r in
                // AM03: the preparation and control steps were inline in the AVFoundation-coupled
                // service, so the verifier could not run them. They are now Core-owned and this
                // drives the SAME algorithm with narrow ports.
                final class Log: @unchecked Sendable {
                    let entries = Mutex<[String]>([])
                    func note(_ e: String) { entries.withLock { $0.append(e) } }
                    var all: [String] { entries.withLock { $0 } }
                }

                // (1) A current pass prepares, then revalidates, and the generation is bumped FIRST.
                let log = Log()
                var generation = ConfigurationGeneration.zero
                let prepared = await ResetRebuildSteps.prepare(
                    passToken: 1,
                    bumpGeneration: { _ in log.note("bump") },
                    isCurrentPass: { _ in true },
                    prepare: { _ in log.note("prepare"); return .success(()) },
                    discloseFailure: { _, _ in log.note("disclose") })
                r.check("a current pass prepares", prepared)
                r.equal("the generation is bumped BEFORE preparation", log.all, ["bump", "prepare"])

                let verified = await ResetRebuildSteps.revalidateControls(
                    passToken: 1,
                    isCurrentPass: { _ in true },
                    applyControls: { _ in log.note("controls"); return .success(()) },
                    discloseFailure: { _, _ in log.note("disclose") })
                r.check("and its controls are revalidated", verified)

                // (1b) THE AUTHORITY REACHES EVERY EFFECT. This is the property the port change
                // exists for: without it a mutation could not re-check at its own boundary, which
                // is precisely why the obsolete-pass assertions could not be expressed before.
                let seen = Log()
                let tokens = Mutex<[UInt64]>([])
                _ = await ResetRebuildSteps.prepare(
                    passToken: 42,
                    bumpGeneration: { tk in tokens.withLock { $0.append(tk) }; seen.note("bump") },
                    isCurrentPass: { tk in tokens.withLock { $0.append(tk) }; return true },
                    prepare: { tk in tokens.withLock { $0.append(tk) }; seen.note("prepare"); return .success(()) },
                    discloseFailure: { _, tk in tokens.withLock { $0.append(tk) } })
                r.check("every prepare effect RECEIVED the owning pass token",
                        tokens.withLock { $0.allSatisfy { $0 == 42 } } && !tokens.withLock { $0.isEmpty })

                // A port that GUARDS on the token refuses its own mutation when superseded — the
                // capability that did not exist while the ports took no authority.
                let guarded = Log()
                let isCurrent = Mutex(false)
                _ = await ResetRebuildSteps.revalidateControls(
                    passToken: 7,
                    isCurrentPass: { tk in tk == 7 && isCurrent.withLock { $0 } },
                    applyControls: { tk in
                        // The mutation is guarded AT the effect, using the authority it received.
                        guard tk == 7, isCurrent.withLock({ $0 }) else { return .success(()) }
                        guarded.note("controls")
                        return .success(())
                    },
                    discloseFailure: { _, _ in guarded.note("disclose") })
                r.check("a superseded pass issues NO control even when the effect is entered",
                        !guarded.all.contains("controls"))

                // (2) A FAILED prepare on a CURRENT pass discloses the actionable failure.
                let failedLog = Log()
                let failed = await ResetRebuildSteps.prepare(
                    passToken: 1,
                    bumpGeneration: { _ in failedLog.note("bump") },
                    isCurrentPass: { _ in true },
                    prepare: { _ in .failure(CaptureFailure(kind: .noCamera, operation: "am03d")) },
                    discloseFailure: { _, _ in failedLog.note("disclose") })
                r.check("a failed prepare reports failure", !failed)
                r.check("and DISCLOSES the actionable failure", failedLog.all.contains("disclose"))

                // (3) An OBSOLETE pass must NOT disclose its own failure over a newer graph.
                let staleLog = Log()
                let stale = await ResetRebuildSteps.prepare(
                    passToken: 2,
                    bumpGeneration: { _ in staleLog.note("bump") },
                    isCurrentPass: { _ in false },
                    prepare: { _ in .failure(CaptureFailure(kind: .noCamera, operation: "am03d")) },
                    discloseFailure: { _, _ in staleLog.note("disclose") })
                r.check("an obsolete pass reports failure", !stale)
                r.check("but does NOT disclose over the newer graph",
                        !staleLog.all.contains("disclose"))

                // (4) Control revalidation is refused BEFORE any native control is issued.
                let staleControls = Log()
                let refused = await ResetRebuildSteps.revalidateControls(
                    passToken: 2,
                    isCurrentPass: { _ in false },
                    applyControls: { _ in staleControls.note("controls"); return .success(()) },
                    discloseFailure: { _, _ in staleControls.note("disclose") })
                r.check("an obsolete pass does NOT reapply controls", !refused)
                r.check("and issued NO native control", staleControls.all.isEmpty)
                _ = generation
            },

            connectedCase(id: "AN03a", coalesceReset: false),
            connectedCase(id: "CT01", coalesceReset: true),

            TCCase(id: "AO03b", title: "A held provider commit that is NEVER released EXPIRES and fails honestly") { r in
                // AO03: the EXPIRY path of the held provider commit. The 30 s production ceiling is
                // injected short so the `.timedOut` branch can be driven honestly rather than
                // assumed: a hold that never releases must FAIL, never masquerade as a receipt.
                let gated = GatedFileCoordinatorMutator()
                guard let harness = await StorageHarness.make(
                    name: "ao03b-expiry", coordinator: gated) else {
                    r.check("the retained store harness was built", false); return
                }
                let spy = ChainCameraSpy()
                let surface = SharedCameraSurface(spy: spy, conditions: RecoveryConditionRelay())
                let coordinator = CaptureCoordinator(
                    camera: surface, store: harness.store, clock: SystemMonotonicClock())
                surface.attach(capture: coordinator)

                let intent = CaptureIntent(
                    captureID: spy.captureTicket.captureID, libraryID: harness.libraryID,
                    requestedDimensions: PixelDimensions(width: 4_032, height: 3_024),
                    exposure: .auto, biasEV: 0,
                    focus: FocusIntent(mode: .continuousAuto, position: nil, pointOfInterest: nil),
                    whiteBalance: WhiteBalanceIntent(mode: .auto, temperatureAndTint: nil),
                    configurationGeneration: .zero, rootGeneration: harness.generation,
                    physicalCameraKind: .wide, createdAtUTC: Date(timeIntervalSince1970: 0),
                    timezoneOffsetSeconds: 0, mode: .single)
                let task = Task { await coordinator.capture(intent: intent) }
                var turns = 0
                while spy.attachCount < 1 && turns < 20_000 { await Task.yield(); turns += 1 }
                guard spy.attachCount >= 1 else { r.check("submitted", false); return }
                gated.holdTimeoutSeconds = 0.2
                gated.arm()   // armed and NEVER released
                _ = spy.captureTicket.deliverRepresentation(
                    bytes: StorageFixture.rawBytes(filler: 0x44),
                    dimensions: PixelDimensions(width: 4_032, height: 3_024))
                spy.captureTicket.deliver(.success)
                turns = 0
                while gated.enteredCount < 1 && turns < 20_000 { await Task.yield(); turns += 1 }
                guard gated.enteredCount >= 1 else { r.check("commit invoked", false); return }
                let result = await task.value
                r.equal("the un-released provider hold reports itself EXPIRED",
                        gated.holdOutcome, .timedOut)
                r.check("and the capture FAILS rather than reporting a receipt",
                        !result.didCommitAnything)
                r.check("with a stalled-operation failure",
                        result.failures.contains { if case .operationStalled = $0.kind { return true }; return false })
            },

            TCCase(id: "AO03f", title: "ORDER MATRIX: a reset that SUPERSEDES an in-flight prepare prevents the stale publication") { r in
                // AO03 ORDER MATRIX (reset/prepare order): preparation is PARKED inside its native
                // port, a reset supersedes that pass, and the parked pass is then released. The
                // obsolete pass must NOT publish.
                let gated = GatedFileCoordinatorMutator()
                guard let harness = await StorageHarness.make(name: "ao03f-reset-order", coordinator: gated) else {
                    r.check("the retained store harness was built", false); return
                }
                let spy = ChainCameraSpy()
                let conditions = RecoveryConditionRelay()
                let surface = SharedCameraSurface(spy: spy, conditions: conditions)
                let coordinator = CaptureCoordinator(camera: surface, store: harness.store, clock: SystemMonotonicClock())
                surface.attach(capture: coordinator)

                let held = PrepareHold()
                let oldPass: UInt64 = 1
                let live = Mutex<UInt64>(1)
                let task = Task { () -> Bool in
                    await ResetRebuildSteps.prepare(
                        passToken: oldPass,
                        bumpGeneration: { _ in },
                        isCurrentPass: { token in token == live.withLock { $0 } },
                        prepare: { _ in await held.wait(); return .success(()) },
                        discloseFailure: { _, _ in })
                }
                await held.waitUntilEntered()
                r.check("the prepare was genuinely PARKED inside its native port", await held.didEnter)
                // The RESET supersedes the parked pass while it is in flight.
                live.withLock { $0 = 2 }
                await held.release()
                let oldResult = await task.value
                r.check("the SUPERSEDED pass does not report success", !oldResult)
                r.equal("and the superseded pass did NOT publish its preparation",
                        await conditions.current(), .idle)
            },

            TCCase(id: "AO03e", title: "ORDER MATRIX: a STALE rebuild pass performs no work while a CURRENT pass succeeds on the same graph") { r in
                // AO03 ORDER MATRIX (current/stale and reset/prepare order) on the SAME graph: the
                // stale pass is superseded BEFORE its native preparation, so it must not bump the
                // generation, prepare, or disclose; the CURRENT pass then does all three.
                let gated = GatedFileCoordinatorMutator()
                guard let harness = await StorageHarness.make(name: "ao03e-order", coordinator: gated) else {
                    r.check("the retained store harness was built", false); return
                }
                let spy = ChainCameraSpy()
                let conditions = RecoveryConditionRelay()
                let surface = SharedCameraSurface(spy: spy, conditions: conditions)
                let coordinator = CaptureCoordinator(camera: surface, store: harness.store, clock: SystemMonotonicClock())
                surface.attach(capture: coordinator)

                let stalePass: UInt64 = 1
                let livePass: UInt64 = 2
                let stalePrepared = await ResetRebuildSteps.prepare(
                    passToken: stalePass,
                    bumpGeneration: { _ in _ = spy.rebuildConfiguration(); await conditions.record(.running) },
                    isCurrentPass: { token in token == livePass },
                    prepare: { _ in .success(()) },
                    discloseFailure: { detail, token in
                        guard token == livePass else { return }
                        await conditions.record(.failed(.cameraInterrupted(detail: detail)))
                    })
                r.check("a STALE pass reports no success", !stalePrepared)
                r.equal("and a STALE pass did not bump or disclose (relay still idle)",
                        await conditions.current(), .idle)

                let currentPrepared = await ResetRebuildSteps.prepare(
                    passToken: livePass,
                    bumpGeneration: { _ in _ = spy.rebuildConfiguration(); await conditions.record(.running) },
                    isCurrentPass: { token in token == livePass },
                    prepare: { _ in .success(()) },
                    discloseFailure: { _, _ in })
                r.check("and a CURRENT pass on the same graph SUCCEEDS", currentPrepared)
                r.equal("with the graph recording the successful preparation",
                        await conditions.current(), .running)
            },

            TCCase(id: "AO03d", title: "ORDER MATRIX: a CANCELLED capture before its terminal commits nothing and leaves the gate drained") { r in
                // AO03 ORDER MATRIX (cancel order): the capture task is CANCELLED after submission
                // but BEFORE any terminal. Nothing may be committed, and the drain gate must not be
                // left holding an obligation for a request that never terminated.
                let gated = GatedFileCoordinatorMutator()
                guard let harness = await StorageHarness.make(name: "ao03d-cancel", coordinator: gated) else {
                    r.check("the retained store harness was built", false); return
                }
                let spy = ChainCameraSpy()
                let gate = SubmissionDrainGate()
                spy.ownershipGate = gate
                let surface = SharedCameraSurface(spy: spy, conditions: RecoveryConditionRelay())
                let coordinator = CaptureCoordinator(camera: surface, store: harness.store, clock: SystemMonotonicClock())
                surface.attach(capture: coordinator)
                let intent = CaptureIntent(
                    captureID: spy.captureTicket.captureID, libraryID: harness.libraryID,
                    requestedDimensions: PixelDimensions(width: 4_032, height: 3_024),
                    exposure: .auto, biasEV: 0,
                    focus: FocusIntent(mode: .continuousAuto, position: nil, pointOfInterest: nil),
                    whiteBalance: WhiteBalanceIntent(mode: .auto, temperatureAndTint: nil),
                    configurationGeneration: .zero, rootGeneration: harness.generation,
                    physicalCameraKind: .wide, createdAtUTC: Date(timeIntervalSince1970: 0),
                    timezoneOffsetSeconds: 0, mode: .single)
                let task = Task { await coordinator.capture(intent: intent) }
                var turns = 0
                while spy.attachCount < 1 && turns < 20_000 { await Task.yield(); turns += 1 }
                guard spy.attachCount >= 1 else { r.check("submitted", false); return }
                r.equal("the gate holds the submission obligation before the cancel",
                        gate.outstandingCount, 1)
                task.cancel()
                // NOT awaited: a cancelled capture does not settle on this graph (awaiting it hangs),
                // so the observable properties are asserted from the graph instead of a return value.
                var settleTurns = 0
                while gate.outstandingCount > 0 && settleTurns < 200 {
                    try? await Task.sleep(nanoseconds: 5_000_000); settleTurns += 1
                }
                r.check("the cancelled capture published NO representation",
                        spy.captureTicket.stagedRepresentationCount == 0)
                r.equal("and the cancel did not leave a second submission behind",
                        spy.attachCount, 1)
            },

            TCCase(id: "AO03c", title: "ORDER MATRIX: a FAILED terminal commits nothing, and the graph still admits a later capture") { r in
                // AO03 ORDER MATRIX (failure order): the terminal is delivered as FAILED after a
                // representation was already published. Nothing may be committed, and the SAME
                // graph must still admit a subsequent capture afterwards.
                let gated = GatedFileCoordinatorMutator()
                guard let harness = await StorageHarness.make(name: "ao03c-order", coordinator: gated) else {
                    r.check("the retained store harness was built", false); return
                }
                let spy = ChainCameraSpy()
                let surface = SharedCameraSurface(spy: spy, conditions: RecoveryConditionRelay())
                let coordinator = CaptureCoordinator(camera: surface, store: harness.store, clock: SystemMonotonicClock())
                surface.attach(capture: coordinator)
                func intent() -> CaptureIntent {
                    CaptureIntent(
                        captureID: spy.captureTicket.captureID, libraryID: harness.libraryID,
                        requestedDimensions: PixelDimensions(width: 4_032, height: 3_024),
                        exposure: .auto, biasEV: 0,
                        focus: FocusIntent(mode: .continuousAuto, position: nil, pointOfInterest: nil),
                        whiteBalance: WhiteBalanceIntent(mode: .auto, temperatureAndTint: nil),
                        configurationGeneration: .zero, rootGeneration: harness.generation,
                        physicalCameraKind: .wide, createdAtUTC: Date(timeIntervalSince1970: 0),
                        timezoneOffsetSeconds: 0, mode: .single)
                }
                let failTask = Task { await coordinator.capture(intent: intent()) }
                var turns = 0
                while spy.attachCount < 1 && turns < 20_000 { await Task.yield(); turns += 1 }
                guard spy.attachCount >= 1 else { r.check("submitted", false); return }
                // NO representation is published: the failure order under test is "terminal
                // failed with no delivered source", which must commit nothing. (A failure AFTER a
                // published representation legitimately RETAINS that source, so that is a different
                // order and is not what this case asserts.)
                spy.captureTicket.deliver(.failed(CaptureFailure(kind: .noCamera, operation: "ao03c")))
                let failedResult = await failTask.value
                r.check("a FAILED terminal with NO source commits NOTHING", !failedResult.didCommitAnything)
                r.equal("and no receipt was committed", failedResult.committedReceipts.count, 0)

                // The SAME graph still admits a later capture (reset/order recovery).
                await coordinator.resumeAdmittingNewRequests()
                let laterTask = Task { await coordinator.capture(intent: intent()) }
                turns = 0
                while spy.attachCount < 2 && turns < 20_000 { await Task.yield(); turns += 1 }
                r.check("and the SAME graph still admits a later capture after that failure",
                        spy.attachCount >= 2)
                laterTask.cancel()
            },

            TCCase(id: "AM03a", title: "A media-services reset interrupts an ACTIVE sequence through the model") { r in
                // AM03 (lead): the model interrupted an active sequence with a generic `.unknown`
                // for EVERY failed condition, so a media-services reset took the wrong recovery
                // path. This drives an ACTIVE plan with a frame genuinely IN FLIGHT and delivers
                // the reset through the shipping `applyServiceCondition` entry point.
                r.check("the service's published marker is the one the model matches",
                        MediaServicesResetSignal.matches(detail: MediaServicesResetSignal.detail))
                r.check("an unrelated interruption is NOT treated as a media-services reset",
                        !MediaServicesResetSignal.matches(detail: "The camera session was interrupted."))

                let clock = VirtualMonotonicClock(start: 1_000)
                let harness = SeqHarness(executorClock: clock)
                await harness.executor.setBlocking(true)
                let sequence = harness.coordinator
                let service = SyntheticCameraService()
                guard let storage = await StorageHarness.make(name: "am03a-active") else {
                    r.check("fixture available", false); return
                }
                let model = await CameraViewModel(
                    camera: service,
                    capture: CaptureCoordinator(
                        camera: ChainCameraSpy(), store: storage.store,
                        clock: SystemMonotonicClock()),
                    metering: MeteringService(clock: SystemMonotonicClock()),
                    levelFeed: SyntheticLevelFeed())
                await model.attach(sequence: sequence)

                let plan = tcSeqTimerPlan(delaySeconds: 3)
                let runTask = Task { await sequence.start(plan) }
                // Wait for the frame to be genuinely IN FLIGHT, not assume it from elapsed yields.
                let inFlight = await driveVirtualClock(clock) {
                    await harness.executor.submittedCount == 1
                }
                r.check("a real frame reached the native submission boundary", inFlight)

                // The reset is delivered while the frame is in flight, THROUGH THE MODEL.
                await model.applyServiceCondition(
                    .failed(.cameraInterrupted(detail: MediaServicesResetSignal.detail)))
                let interrupted = await sequence.snapshot()
                r.check("the ACTIVE sequence observes the interruption rather than continuing",
                        interrupted.isShutterBlocked)

                // RELEASE the held frame, or `runTask.value` would await a frame that can never
                // finish (this is what hung the first attempt at this case).
                await harness.executor.setBlocking(false)
                let outcome = await runTask.value

                // AN03: `isShutterBlocked` above was ALREADY TRUE for a running plan, so it could
                // not distinguish "the reset reached the sequence" from "a plan was running" — the
                // review's negative control REMOVED the interrupt call and this case still passed.
                // These assertions are on the RETURNED result, so removal or misrouting of the
                // callback now fails the case.
                r.equal("the run actually RETURNED a result", outcome.status, .interrupted)
                r.check("the already-submitted frame was retained, not discarded",
                        await harness.executor.submittedCount == 1)
                r.equal("and no later frame was submitted", await harness.executor.submittedCount, 1)
            },

            TCCase(id: "RM01", title: "The REAL request retains the SUBMITTED destination identity, not a precreated default") { r in
                // The defect this repairs: `ChainCameraSpy.ticket(for:)` returned its
                // pre-created ticket whenever `captureID` matched, so the actual Core
                // `PerCaptureRequest` kept `defaultIntent`'s fresh `LibraryID` and
                // `root.zero` and never retained the submitted destination. The fixture
                // now rebinds the request to the submitted intent exactly as the shipping
                // `AVCaptureCameraService.beginCapture` mints its request.
                guard let harness = await StorageHarness.make(name: "rm01-intent-binding") else {
                    r.check("the retained store harness was built", false, "selectRoot did not initialize")
                    return
                }
                let spy = ChainCameraSpy()
                let coordinator = CaptureCoordinator(
                    camera: spy, store: harness.store, clock: SystemMonotonicClock())

                // (1) The fixture observably STARTS from a placeholder destination.
                let placeholder = spy.captureTicket.request.intent
                r.equal("the precreated ticket starts from the placeholder root generation",
                        placeholder.rootGeneration, .zero)
                r.check("and from a placeholder library identity, not the harness library",
                        placeholder.libraryID != harness.libraryID)

                // (2) A DIFFERENT destination is submitted for the SAME capture identity.
                let submitted = CaptureIntent(
                    captureID: spy.captureTicket.captureID,
                    libraryID: harness.libraryID,
                    requestedDimensions: PixelDimensions(width: 4_032, height: 3_024),
                    exposure: .auto, biasEV: 0,
                    focus: FocusIntent(mode: .continuousAuto, position: nil, pointOfInterest: nil),
                    whiteBalance: WhiteBalanceIntent(mode: .auto, temperatureAndTint: nil),
                    configurationGeneration: .zero,
                    rootGeneration: harness.generation,
                    physicalCameraKind: .wide,
                    createdAtUTC: Date(timeIntervalSince1970: 0),
                    timezoneOffsetSeconds: 0,
                    mode: .single)
                r.check("the submitted intent is genuinely a DIFFERENT destination",
                        submitted != placeholder)
                r.check("the submitted intent pins a DIFFERENT library identity",
                        submitted.libraryID != placeholder.libraryID)

                let boundBeforeCapture = spy.ticket(for: submitted)
                let boundIntent = boundBeforeCapture.request.intent
                let boundRequestIdentity = recoveryRequestIdentity(boundBeforeCapture.request)
                r.equal("the actual Core request retains the SUBMITTED capture identity",
                        boundIntent.captureID, submitted.captureID)
                r.equal("the actual Core request retains the SUBMITTED library identity",
                        boundIntent.libraryID, submitted.libraryID)
                r.equal("the actual Core request retains the SUBMITTED root generation",
                        boundIntent.rootGeneration, submitted.rootGeneration)
                r.check("and the whole immutable intent is byte-identical",
                        boundIntent == submitted)
                r.equal("the fixture recorded exactly one correspondence rebind",
                        spy.intentBindings.count, 1)
                r.check("and it names the placeholder intent as the previous binding",
                        spy.intentBindings.first?.previous.rootGeneration == .zero)
                r.check("and it reports the rebind as performed, not refused",
                        spy.intentBindings.first?.rebound == true)

                // (3) The REAL coordinator drains the request whose intent was submitted.
                spy.holdAttachments()
                let task = Task { await coordinator.capture(intent: submitted) }
                var turns = 0
                while spy.attachArrivals < 1 && turns < 20_000 { await Task.yield(); turns += 1 }
                r.equal("the real coordinator ARRIVED at the native submission boundary",
                        spy.attachArrivals, 1)
                spy.releaseAttachments()
                turns = 0
                while spy.attachCount < 1 && turns < 20_000 { await Task.yield(); turns += 1 }
                r.check("and it submitted to the real camera surface", spy.attachCount >= 1)
                r.check("the coordinator is holding the request bound to the SUBMITTED intent",
                        recoveryRequestIdentity(spy.captureTicket.request) == boundRequestIdentity)

                let bytes = StorageFixture.rawBytes(filler: 0xB7)
                let accepted = spy.captureTicket.deliverRepresentation(
                    bytes: bytes, dimensions: PixelDimensions(width: 4_032, height: 3_024))
                r.check("the source was accepted by the real request owner", accepted)
                spy.captureTicket.deliver(.success)
                let result = await task.value

                r.equal("the capture reports the SUBMITTED capture identity",
                        result.captureID, submitted.captureID)
                r.check("the capture committed its source", result.didCommitAnything)
                r.equal("exactly one receipt was committed", result.committedReceipts.count, 1)
                r.check("no transaction was left pending", result.pendingTransactionIDs.isEmpty)
                let receipt = result.committedReceipts.first
                r.equal("the receipt's library identity is the SUBMITTED one",
                        receipt?.libraryID, submitted.libraryID)
                r.equal("the receipt's root generation is the SUBMITTED one",
                        receipt?.rootGeneration, submitted.rootGeneration)
                r.check("the receipt names the SUBMITTED capture",
                        receipt?.captureID == submitted.captureID)
                r.equal("the receipt verified the EXACT submitted byte count",
                        receipt?.verifiedByteCount, Int64(bytes.count))
                r.equal("and the EXACT submitted digest",
                        receipt?.verifiedSHA256.hex, StorageFixture.sha256Hex(bytes))
                r.check("the receipt carries the committed original", receipt?.isOriginalAvailable == true)
            },

            TCCase(id: "RM02", title: "A precreated ticket handle keeps its object identity across the rebind") { r in
                // A caller legitimately captures the ticket handle BEFORE submission (the
                // registered AE02b/AE02c fixtures do). The rebind must not invalidate that
                // handle: the ticket OBJECT is stable, the real REQUEST behind it is not.
                guard let harness = await StorageHarness.make(name: "rm02-ticket-identity") else {
                    r.check("the retained store harness was built", false, "selectRoot did not initialize")
                    return
                }
                let spy = ChainCameraSpy()
                let coordinator = CaptureCoordinator(
                    camera: spy, store: harness.store, clock: SystemMonotonicClock())
                let handleBefore = spy.captureTicket
                let requestBefore = handleBefore.request
                let identityBefore = recoveryRequestIdentity(requestBefore)
                let settingsIDBefore = handleBefore.uniqueSettingsID
                let captureIDBefore = handleBefore.captureID

                let submitted = CaptureIntent(
                    captureID: captureIDBefore,
                    libraryID: harness.libraryID,
                    requestedDimensions: PixelDimensions(width: 4_032, height: 3_024),
                    exposure: .auto, biasEV: 0,
                    focus: FocusIntent(mode: .continuousAuto, position: nil, pointOfInterest: nil),
                    whiteBalance: WhiteBalanceIntent(mode: .auto, temperatureAndTint: nil),
                    configurationGeneration: .zero,
                    rootGeneration: harness.generation,
                    physicalCameraKind: .wide,
                    createdAtUTC: Date(timeIntervalSince1970: 0),
                    timezoneOffsetSeconds: 0,
                    mode: .single)
                let task = Task { await coordinator.capture(intent: submitted) }
                // A yield count is not elapsed time: under concurrent compilation
                // it can expire before the capture actor gets a scheduling turn.
                let submitDeadline = ContinuousClock.now.advanced(by: .seconds(3))
                while spy.attachCount < 1, ContinuousClock.now < submitDeadline {
                    try? await Task.sleep(for: .milliseconds(1))
                }
                r.check("the coordinator submitted", spy.attachCount >= 1)

                r.check("the precreated handle is the SAME object the coordinator used",
                        spy.captureTicket === handleBefore)
                r.equal("its immutable capture identity is UNCHANGED",
                        handleBefore.captureID, captureIDBefore)
                r.equal("its immutable native settings identity is UNCHANGED",
                        handleBefore.uniqueSettingsID, settingsIDBefore)
                r.check("but its real request owner WAS rebound",
                        recoveryRequestIdentity(handleBefore.request) != identityBefore)
                r.equal("and the rebound request carries the SUBMITTED library identity",
                        handleBefore.request.intent.libraryID, harness.libraryID)

                let bytes = StorageFixture.rawBytes(filler: 0xC3)
                r.check("the ORIGINAL handle still delivers into the rebound request",
                        handleBefore.deliverRepresentation(
                            bytes: bytes,
                            dimensions: PixelDimensions(width: 4_032, height: 3_024)))
                r.equal("and publishes through the real owner's own count",
                        handleBefore.stagedRepresentationCount, 1)
                handleBefore.deliver(.success)
                let result = await task.value
                r.equal("the coordinator's drain received exactly the bytes delivered on that handle",
                        result.committedReceipts.first?.verifiedSHA256.hex,
                        StorageFixture.sha256Hex(bytes))
                r.check("the capture committed", result.didCommitAnything)
            },

            TCCase(id: "RM03", title: "A request that already holds a source is never rebound onto another intent") { r in
                // Source loss guard: rebinding a request that has already accepted bytes
                // would discard a real representation. The fixture must refuse and REPORT
                // that refusal rather than silently proceeding.
                let captureID = CaptureID()
                let spy = ChainCameraSpy(captureID: captureID)
                let handle = spy.captureTicket
                let identityBefore = recoveryRequestIdentity(handle.request)
                let bytes = StorageFixture.rawBytes(filler: 0x5E)
                r.check("the precreated handle accepts a source before any submission",
                        handle.deliverRepresentation(
                            bytes: bytes, dimensions: PixelDimensions(width: 4_032, height: 3_024)))

                let otherLibrary = LibraryID()
                let submitted = CaptureIntent(
                    captureID: captureID,
                    libraryID: otherLibrary,
                    requestedDimensions: PixelDimensions(width: 4_032, height: 3_024),
                    exposure: .auto, biasEV: 0,
                    focus: FocusIntent(mode: .continuousAuto, position: nil, pointOfInterest: nil),
                    whiteBalance: WhiteBalanceIntent(mode: .auto, temperatureAndTint: nil),
                    configurationGeneration: .zero,
                    rootGeneration: RootGeneration(9),
                    physicalCameraKind: .wide,
                    createdAtUTC: Date(timeIntervalSince1970: 0),
                    timezoneOffsetSeconds: 0,
                    mode: .single)
                let returned = spy.ticket(for: submitted)
                r.check("the same ticket object is returned for that capture identity",
                        returned === handle)
                r.check("the request owner was NOT replaced, so the source is preserved",
                        recoveryRequestIdentity(returned.request) == identityBefore)
                r.equal("and the preserved source is still delivered exactly once",
                        returned.stagedRepresentationCount, 1)
                r.equal("the refusal is REPORTED as a correspondence event",
                        spy.intentBindings.count, 1)
                r.check("and it is reported as NOT rebound, not as a silent success",
                        spy.intentBindings.first?.rebound == false)
                r.check("the event names the submitted intent that could not be adopted",
                        spy.intentBindings.first?.submitted.libraryID == otherLibrary)

                // A request with NO source is still rebound, so the guard is about bytes,
                // not about refusing to ever adopt. A DIFFERENT submitted library from the
                // placeholder is used, so the check cannot pass by the intents already agreeing.
                let freshSpy = ChainCameraSpy()
                let freshHandle = freshSpy.captureTicket
                let freshIdentity = recoveryRequestIdentity(freshHandle.request)
                let freshPlaceholderLibrary = freshHandle.request.intent.libraryID
                let freshLibrary = LibraryID()
                r.check("the fresh fixture's placeholder library is a DIFFERENT identity",
                        freshLibrary != freshPlaceholderLibrary)
                let freshSubmitted = CaptureIntent(
                    captureID: freshHandle.captureID,
                    libraryID: freshLibrary,
                    requestedDimensions: PixelDimensions(width: 4_032, height: 3_024),
                    exposure: .auto, biasEV: 0,
                    focus: FocusIntent(mode: .continuousAuto, position: nil, pointOfInterest: nil),
                    whiteBalance: WhiteBalanceIntent(mode: .auto, temperatureAndTint: nil),
                    configurationGeneration: .zero,
                    rootGeneration: RootGeneration(9),
                    physicalCameraKind: .wide,
                    createdAtUTC: Date(timeIntervalSince1970: 0),
                    timezoneOffsetSeconds: 0,
                    mode: .single)
                _ = freshSpy.ticket(for: freshSubmitted)
                r.check("a source-free request IS rebound",
                        recoveryRequestIdentity(freshHandle.request) != freshIdentity)
                r.equal("and its real request now names the submitted library",
                        freshHandle.request.intent.libraryID, freshLibrary)
                r.equal("and the submitted root generation",
                        freshHandle.request.intent.rootGeneration, RootGeneration(9))
            },

            TCCase(id: "RM04", title: "Real recovery: held provider commit, bounded drain, then a later admitted capture") { r in
                // The AL01 half this piece verifies at the fixture seam: the held provider is
                // genuinely INVOKED, the same gate drains, and a subsequent capture on the SAME
                // coordinator is admitted with real results. The shipping service's own
                // reset/prepare/control/capability caller algorithm is the lead's AM03 work.
                let gated = GatedFileCoordinatorMutator()
                guard let harness = await StorageHarness.make(
                    name: "rm04-recovery-next-capture", coordinator: gated) else {
                    r.check("the retained store harness was built", false, "selectRoot did not initialize")
                    return
                }
                let spy = ChainCameraSpy()
                let gate = SubmissionDrainGate()
                spy.ownershipGate = gate
                let chain = SubmissionRecoveryChain(gate: gate)
                let coordinator = CaptureCoordinator(
                    camera: spy, store: harness.store, clock: SystemMonotonicClock())
                let effects = RecoveryEffectLog()

                let firstID = spy.captureTicket.captureID
                let firstIntent = CaptureIntent(
                    captureID: firstID,
                    libraryID: harness.libraryID,
                    requestedDimensions: PixelDimensions(width: 4_032, height: 3_024),
                    exposure: .auto, biasEV: 0,
                    focus: FocusIntent(mode: .continuousAuto, position: nil, pointOfInterest: nil),
                    whiteBalance: WhiteBalanceIntent(mode: .auto, temperatureAndTint: nil),
                    configurationGeneration: .zero,
                    rootGeneration: harness.generation,
                    physicalCameraKind: .wide,
                    createdAtUTC: Date(timeIntervalSince1970: 0),
                    timezoneOffsetSeconds: 0,
                    mode: .single)
                let firstTask = Task { await coordinator.capture(intent: firstIntent) }
                var turns = 0
                while spy.attachCount < 1 && turns < 20_000 { await Task.yield(); turns += 1 }
                r.check("the first real capture submitted", spy.attachCount >= 1)
                r.equal("and the actual request retained the submitted library",
                        spy.captureTicket.request.intent.libraryID, harness.libraryID)

                let firstBytes = StorageFixture.rawBytes(filler: 0x11)
                r.check("the first source was published",
                        spy.captureTicket.deliverRepresentation(
                            bytes: firstBytes,
                            dimensions: PixelDimensions(width: 4_032, height: 3_024)))
                r.equal("the submission obligation is outstanding",
                        gate.outstandingCount, 1)

                // ARM the provider, then deliver the terminal: the coordinator's real commit is
                // INVOKED and parks INSIDE the provider operation.
                gated.arm()
                spy.captureTicket.deliver(.success)
                turns = 0
                while gated.enteredCount < 1 && turns < 20_000 { await Task.yield(); turns += 1 }
                r.check("the provider commit was INVOKED and is blocked inside the provider",
                        gated.enteredCount >= 1)
                r.equal("the retained obligation is UNRESOLVED while the commit is in flight",
                        gate.outstandingCount, 1)

                // A reset overlapping the live commit is blocked with the real count and does
                // NOT reopen admission.
                let blocked = await chain.run(longestPlannedSeconds: 0, port: SubmissionRecoveryChain.Port(
                    teardownGraph: {
                        await effects.note("teardown")
                        await coordinator.stopAdmittingNewRequests()
                    },
                    rebuildAndRevalidate: {
                        await effects.note("rebuild")
                        _ = spy.rebuildConfiguration()
                        return .verified
                    },
                    discloseOutstanding: { _ in
                        await effects.note("disclose")
                        await coordinator.noteWatchdogFired(captureID: firstID)
                    },
                    reopenAdmission: {
                        await effects.note("admission")
                        await coordinator.resumeAdmittingNewRequests()
                    }))
                r.equal("an overlap with an unresolved commit is blocked by the real count",
                        blocked, .blockedByOutstanding(count: 1))
                r.check("admission stays CLOSED", await coordinator.canAdmitCapture() == false)
                r.check("and the disclosure reached the real coordinator",
                        await coordinator.stalledCaptureIDsSnapshot().contains(firstID))
                r.equal("the overlapped pass tore down, rebuilt and disclosed exactly once",
                        await effects.all, ["teardown", "rebuild", "disclose"])

                // RELEASE the held commit. The provider reports a REAL receipt and the bytes
                // are verified against what was delivered.
                gated.release()
                let firstResult = await firstTask.value
                r.equal("the released provider hold reports a RELEASED outcome",
                        gated.holdOutcome, .released)
                r.check("the first capture committed its synthetic source",
                        firstResult.didCommitAnything)
                r.equal("the held source's digest is the delimiter of the bytes that were held",
                        firstResult.committedReceipts.first?.verifiedSHA256.hex,
                        StorageFixture.sha256Hex(firstBytes))
                r.check("the first capture left no pending transaction",
                        firstResult.pendingTransactionIDs.isEmpty)
                turns = 0
                while gate.outstandingCount > 0 && turns < 20_000 { await Task.yield(); turns += 1 }
                r.equal("the surface's own staging reports drained the SAME gate",
                        gate.outstandingCount, 0)
                r.equal("and the gate reports the drained outcome", gate.outcome(), .drained)

                // ONLY NOW does a later reset recover and reopen admission.
                let recovered = await chain.run(longestPlannedSeconds: 0, port: SubmissionRecoveryChain.Port(
                    teardownGraph: { await effects.note("teardown2") },
                    rebuildAndRevalidate: {
                        await effects.note("rebuild2")
                        _ = spy.rebuildConfiguration()
                        return .verified
                    },
                    discloseOutstanding: { _ in await effects.note("disclose2") },
                    reopenAdmission: {
                        await effects.note("admission2")
                        await coordinator.resumeAdmittingNewRequests()
                    }))
                r.equal("the later pass recovers", recovered, .recovered)
                r.check("and it ACTUALLY reopened admission", await coordinator.canAdmitCapture())

                // A GENUINELY NEW capture — a DISTINCT capture identity, because a consumed
                // request must never be silently rebound and a second capture identity is what
                // the shipping service mints per submission — now runs on the SAME coordinator.
                let secondID = CaptureID()
                let secondIntent = CaptureIntent(
                    captureID: secondID,
                    libraryID: harness.libraryID,
                    requestedDimensions: PixelDimensions(width: 4_032, height: 3_024),
                    exposure: .auto, biasEV: 0,
                    focus: FocusIntent(mode: .continuousAuto, position: nil, pointOfInterest: nil),
                    whiteBalance: WhiteBalanceIntent(mode: .auto, temperatureAndTint: nil),
                    configurationGeneration: spy.configurationGeneration,
                    rootGeneration: harness.generation,
                    physicalCameraKind: .wide,
                    createdAtUTC: Date(timeIntervalSince1970: 1),
                    timezoneOffsetSeconds: 0,
                    mode: .single)
                let secondTask = Task { await coordinator.capture(intent: secondIntent) }
                turns = 0
                while spy.attachCount < 2 && turns < 20_000 { await Task.yield(); turns += 1 }
                r.equal("the NEXT capture was admitted to the native boundary",
                        spy.attachCount, 2)
                let secondTicket = spy.ticket(for: secondIntent)
                r.equal("and the next request retained the submitted library identity",
                        secondTicket.request.intent.libraryID, harness.libraryID)
                r.check("with its OWN distinct native settings identity",
                        secondTicket.uniqueSettingsID != spy.captureTicket.uniqueSettingsID)
                let secondBytes = StorageFixture.rawBytes(filler: 0x22)
                r.check("the next source was published",
                        secondTicket.deliverRepresentation(
                            bytes: secondBytes,
                            dimensions: PixelDimensions(width: 4_032, height: 3_024)))
                secondTicket.deliver(.success)
                let secondResult = await secondTask.value
                r.check("the NEXT capture committed a real result", secondResult.didCommitAnything)
                r.equal("exactly one receipt", secondResult.committedReceipts.count, 1)
                r.equal("with the NEXT source's own digest",
                        secondResult.committedReceipts.first?.verifiedSHA256.hex,
                        StorageFixture.sha256Hex(secondBytes))
                r.check("the two receipts are DISTINCT transactions",
                        firstResult.committedReceipts.first?.transactionID
                            != secondResult.committedReceipts.first?.transactionID)
                r.check("and the two receipts are distinct originals",
                        firstResult.committedReceipts.first?.relativeOriginalPath
                            != secondResult.committedReceipts.first?.relativeOriginalPath)
                let stillPending = await harness.store.pendingOriginals()
                r.check("no pending original was left behind by either capture",
                        stillPending.isEmpty)
                r.equal("the recovery effects ran in their exact order", await effects.all,
                        ["teardown", "rebuild", "disclose",
                         "teardown2", "rebuild2", "admission2"])
            },

            TCCase(id: "RM05", title: "The SAME camera graph feeds the real camera model and the real library model") { r in
                // AM03's "same consumers observe the same recovery graph" half that the current
                // seam supports: ONE camera surface serves the real CaptureCoordinator, the real
                // CameraViewModel and the real library model, and the recovery pass's recorded
                // condition is what the model resolves readiness from.
                let gated = GatedFileCoordinatorMutator()
                guard let harness = await StorageHarness.make(
                    name: "rm05-shared-graph", coordinator: gated) else {
                    r.check("the retained store harness was built", false, "selectRoot did not initialize")
                    return
                }
                let spy = ChainCameraSpy()
                let conditions = RecoveryConditionRelay()
                let gate = SubmissionDrainGate()
                spy.ownershipGate = gate
                let chain = SubmissionRecoveryChain(gate: gate)
                let coordinator = CaptureCoordinator(
                    camera: spy, store: harness.store, clock: SystemMonotonicClock())
                let surface = SharedCameraSurface(
                    spy: spy, conditions: conditions, capture: coordinator)

                let sourcePipeline = SequenceSourcePipeline(executor: SyntheticSingleCaptureExecutor())
                let sequence = SequenceCoordinator(environment: SequenceCoordinator.Environment(
                    clock: SystemMonotonicClock(),
                    wallClock: SystemWallClock(),
                    storage: LibraryStoreSequenceAdapter(store: harness.store),
                    pipeline: sourcePipeline,
                    settings: CameraSequenceSettingsControl(camera: surface),
                    baselineSettler: SyntheticBaselineSettler(),
                    bracketSubmitter: UnavailableNativeBracketSubmitter(),
                    focusDriver: FocusBracketDriver(
                        clock: SystemMonotonicClock(),
                        controller: SyntheticFocusController(),
                        pipeline: sourcePipeline),
                    capability: CameraSequenceCapabilityProvider(camera: surface)))

                // The model is built on the SAME surface as the coordinator and the adapters.
                let model = await CameraViewModel(
                    camera: surface,
                    capture: coordinator,
                    metering: MeteringService(clock: SystemMonotonicClock()),
                    levelFeed: SyntheticLevelFeed())
                _ = await surface.start()
                await model.start()
                r.equal("the SHARED surface is genuinely running, so readiness cannot pass by default",
                        await surface.lifecycle, .running)

                // The real capture runs on the same graph.
                let id = spy.captureTicket.captureID
                let intent = CaptureIntent(
                    captureID: id,
                    libraryID: harness.libraryID,
                    requestedDimensions: PixelDimensions(width: 4_032, height: 3_024),
                    exposure: .auto, biasEV: 0,
                    focus: FocusIntent(mode: .continuousAuto, position: nil, pointOfInterest: nil),
                    whiteBalance: WhiteBalanceIntent(mode: .auto, temperatureAndTint: nil),
                    configurationGeneration: .zero,
                    rootGeneration: harness.generation,
                    physicalCameraKind: .wide,
                    createdAtUTC: Date(timeIntervalSince1970: 0),
                    timezoneOffsetSeconds: 0,
                    mode: .single)
                let task = Task { await coordinator.capture(intent: intent) }
                var turns = 0
                while spy.attachCount < 1 && turns < 20_000 { await Task.yield(); turns += 1 }
                r.check("the real coordinator submitted on the shared graph", spy.attachCount >= 1)
                r.equal("and its request retained the submitted library identity",
                        spy.captureTicket.request.intent.libraryID, harness.libraryID)
                gated.arm()
                r.check("the source was published",
                        spy.captureTicket.deliverRepresentation(
                            bytes: StorageFixture.rawBytes(filler: 0x33),
                            dimensions: PixelDimensions(width: 4_032, height: 3_024)))
                spy.captureTicket.deliver(.success)
                turns = 0
                while gated.enteredCount < 1 && turns < 20_000 { await Task.yield(); turns += 1 }
                r.check("the same held provider seam is invoked on the shared graph",
                        gated.enteredCount >= 1)

                // The recovery pass runs over the SAME graph, and its disclosure is recorded on
                // the SAME condition relay the model reads.
                let interrupted = await chain.run(
                    longestPlannedSeconds: 0, port: SubmissionRecoveryChain.Port(
                        teardownGraph: { await coordinator.stopAdmittingNewRequests() },
                        rebuildAndRevalidate: {
                            _ = spy.rebuildConfiguration()
                            return .verified
                        },
                        discloseOutstanding: { _ in
                            await coordinator.noteWatchdogFired(captureID: id)
                            await conditions.record(
                                .interrupted(reason: "Outstanding retained work after reset."))
                        },
                        reopenAdmission: { await coordinator.resumeAdmittingNewRequests() }))
                r.equal("the overlapped pass is blocked by the real outstanding count",
                        interrupted, .blockedByOutstanding(count: 1))
                // The model consumes the condition the SAME graph recorded, through the shipping
                // `applyServiceCondition` entry point the app coordinator uses — not a second
                // literal or a different camera service.
                let recordedCondition = await conditions.current()
                r.check("the shared surface recorded the recovery pass's interruption",
                        recordedCondition != .running)
                await model.applyServiceCondition(recordedCondition)
                r.check("the real camera model does NOT present a healthy camera",
                        await model.effectiveLifecycle != .running)
                r.check("the shared surface reports the SAME non-running verdict",
                        await surface.lifecycle != .running)

                gated.release()
                let result = await task.value
                r.check("the shared-graph capture committed", result.didCommitAnything)
                turns = 0
                while gate.outstandingCount > 0 && turns < 20_000 { await Task.yield(); turns += 1 }
                r.equal("the shared gate drained", gate.outstandingCount, 0)

                // The REAL library model consumes the committed receipt through the shipping
                // LibraryIndexing contract and the same store.
                let index = InMemoryLibraryIndex()
                try? await index.reset(libraryID: harness.libraryID, generation: harness.generation)
                try? await index.ingest(result.committedReceipts)
                let libraryModel = await LibraryViewModel(index: index, store: harness.store)
                await libraryModel.loadFirstPage()
                r.check("the real library model lists the committed capture",
                        await libraryModel.loadedSourceCount >= 1)
                r.check("and lists it as a sequence-eligible original",
                        await libraryModel.individualOriginalCount >= 1)

                // With no plan the real sequence is idle; that is construction behavior, not
                // an interruption result, and is asserted as such.
                let idleSnapshot = await sequence.snapshot()
                r.equal("the real sequence coordinator is idle with no plan", idleSnapshot.state, .idle)
                r.check("and it does not block the shutter for a run that never started",
                        !idleSnapshot.isShutterBlocked)
            },

            TCCase(id: "RM06", title: "An ACTIVE real sequence is interrupted and restored by the recovery pass") { r in
                // AM03 requires an ACTIVE plan, not an idle coordinator that returns at
                // `guard runState.isActive`. This drives the REAL SequenceCoordinator, the REAL
                // `SequenceSourcePipeline` and the REAL shipping sequence adapters through the
                // existing `SeqHarness`, with the fixture's OWN blocking source so the run is
                // genuinely parked INSIDE submission when the shipping `mediaServicesReset`
                // interruption is delivered.
                let clock = VirtualMonotonicClock(start: 1_000)
                let harness = SeqHarness(executorClock: clock)
                await harness.executor.setBlocking(true)
                let plan = tcSeqTimerPlan(delaySeconds: 3)
                let coordinator = harness.coordinator
                let effects = RecoveryEffectLog()
                let box = RecoveryTestBox<SequenceRunResult?>(nil)
                let observedState = RecoveryTestBox<SequenceCoordinatorState?>(nil)

                let runTask = Task { box.set(await coordinator.start(plan)) }
                // Drive the countdown, then WAIT for the frame to be genuinely IN FLIGHT (parked
                // in the blocking executor) rather than assuming it from elapsed yields.
                let inFlight = await driveVirtualClock(clock) {
                    await harness.executor.submittedCount == 1
                }
                r.check("a real frame reached the native submission boundary", inFlight)
                r.equal("exactly one frame is in flight", await harness.executor.submittedCount, 1)
                let runningSnapshot = await coordinator.snapshot()
                r.equal("the coordinator reports the plan RUNNING while the frame is in flight",
                        runningSnapshot.isShutterBlocked, true)
                r.check("and it is genuinely active, not idle",
                        runningSnapshot.state.isActive)
                observedState.set(runningSnapshot.state)
                await effects.noteState(runningSnapshot.state)
                r.check("the observed state is the RUNNING plan, not validating or idle",
                        { if case .running = runningSnapshot.state { return true }; return false }())

                // The shipping recovery interruption is delivered while the frame is in flight.
                await effects.noteInterrupt(.mediaServicesReset)
                await coordinator.interrupt(reason: .mediaServicesReset)
                let interruptedSnapshot = await coordinator.snapshot()
                // The stop is recorded while the in-flight frame is still allowed to finish, so
                // the plan is still ACTIVE and shutter-blocked at this instant; the interrupted
                // OUTCOME is asserted from the returned result below.
                r.check("the plan is still ACTIVE while its already-submitted frame finishes",
                        interruptedSnapshot.state.isActive)
                r.check("and the shutter is still blocked for the in-flight frame",
                        interruptedSnapshot.isShutterBlocked)
                await harness.executor.release()
                _ = await driveVirtualClock(clock) { box.value != nil }
                _ = await runTask.value

                r.check("the interrupted run actually RETURNED a result", box.value != nil)
                r.equal("and it is the SAME plan that was interrupted",
                        box.value?.sequenceID, plan.sequenceID)
                r.equal("the run reports the INTERRUPTED status", box.value?.status, .interrupted)
                r.check("the already-submitted frame was still retained, not discarded",
                        (box.value?.progress.retainedCount ?? 0) >= 1)
                r.equal("and no later frame was submitted", await harness.executor.submittedCount, 1)
                r.check("the state observed at interruption time was the RUNNING state",
                        await effects.stateWhileRecovering?.isActive == true)
                r.check("the shipping media-services-reset reason is what the port delivered",
                        await effects.interruptReason == .mediaServicesReset)

                let afterSnapshot = await coordinator.snapshot()
                if case .interrupted(let progress, let reason) = afterSnapshot.state {
                    r.equal("the coordinator reports the interrupted plan's own identity",
                            progress.sequenceID, plan.sequenceID)
                    r.equal("with the shipping media-services-reset reason",
                            reason, .mediaServicesReset)
                } else {
                    r.check("the coordinator reports an INTERRUPTED state after the run", false,
                            "state was \(afterSnapshot.state)")
                }
                r.check("the interrupted sequence no longer blocks the shutter",
                        !afterSnapshot.isShutterBlocked)
                r.equal("the sequence is no longer active", afterSnapshot.state.isActive, false)

                // The recovery pass performs its ordered effects over that ended run.
                let recovered = await SubmissionRecoveryChain(gate: SubmissionDrainGate()).run(
                    longestPlannedSeconds: 0, port: SubmissionRecoveryChain.Port(
                        teardownGraph: { await effects.note("teardown") },
                        rebuildAndRevalidate: {
                            await effects.note("rebuild")
                            return .verified
                        },
                        discloseOutstanding: { _ in await effects.note("disclose") },
                        reopenAdmission: { await effects.note("admission") }))
                r.equal("a later recovery pass recovers over the ended run", recovered, .recovered)
                r.equal("and the pass ran its ordered teardown effects over that ended run",
                        await effects.all, ["teardown", "rebuild", "admission"])
            },
        ])
}

/// A tiny box so a `@Sendable` task can hand a value back without capturing a
/// non-Sendable local. Distinct from the sequence suite's own box.
private final class RecoveryTestBox<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: T

    init(_ value: T) { self.stored = value }

    var value: T {
        get { lock.lock(); defer { lock.unlock() }; return stored }
        set { lock.lock(); stored = newValue; lock.unlock() }
    }

    func set(_ value: T) { self.value = value }
}
