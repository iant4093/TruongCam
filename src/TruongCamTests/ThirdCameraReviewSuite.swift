import Foundation
#if canImport(XCTest)
@testable import TruongCam
#endif

/// One synthetic camera boundary shared by the real view model and capture
/// coordinator. Held setters and recorded invocations discriminate ordering;
/// no native camera, original, phone timing or capability is inferred.
private actor ThirdReviewCamera: CameraServicing, CaptureCameraSurface {
    struct Application: Sendable {
        let revision: UInt64
        let exposure: ExposureChoice
    }
    let capabilitySnapshot = StartupRepairSuite.controlFixture(modes: [.auto, .manual])
    private(set) var lifecycle: CameraLifecycle = .idle
    private(set) var applications: [Application] = []
    private(set) var submitted: [CaptureIntent] = []
    private var reading: AppliedControlSnapshot?
    private var nextApplicationHold: PrepareHold?
    private var converges = true
    nonisolated let controlReadbackStream: AsyncStream<AppliedControlSnapshot> = AsyncStream { $0.finish() }
    nonisolated let sessionConditionStream: AsyncStream<CameraLifecycle> = AsyncStream { $0.finish() }
    nonisolated let analysisStream: BoundedOrderedSequence<AnalysisOutput>
    private let analysis = BoundedEventChannel<AnalysisOutput>(capacity: 4)
    private let display = PreviewDisplayBridge()

    init() { analysisStream = analysis.subscribe() }
    func holdNextApplication(_ hold: PrepareHold) { nextApplicationHold = hold }
    func setConvergence(_ value: Bool) { converges = value }
    func prepare(desiredCamera: PhysicalCameraKind?) async -> Result<CameraCapabilitySnapshot, CaptureFailure> { .success(capabilitySnapshot) }
    func start() async -> Result<Void, CaptureFailure> { lifecycle = .running; return .success(()) }
    func stop() async { lifecycle = .idle }
    func switchPhysicalCamera(to kind: PhysicalCameraKind) async -> Result<CameraCapabilitySnapshot, CaptureFailure> { .success(capabilitySnapshot) }
    func recordedSessionCondition() async -> CameraLifecycle { lifecycle }
    func setFocusPoint(normalizedDevicePoint: NormalizedDevicePoint, isTapToFocus: Bool) async -> Result<Void, CaptureFailure> { .success(()) }
    func lastAppliedSnapshot() async -> AppliedControlSnapshot? { reading }
    func setAnalysisDemand(_ demand: AnalysisDemand) async {}
    func setAnalysisRequest(_ request: AnalysisRequest?) async {}
    func updatePreviewGeometry(_ geometry: PreviewGeometrySnapshot?) async {}
    func previewDisplayBridge() async -> PreviewDisplayBridge { display }
    func recordMeasuredRAWDimensions(_ dimensions: PixelDimensions, evidenceOrigin: String) async {}

    func applyControls(revision: UInt64, exposure: ExposureChoice, biasEV: Double,
                       focus: FocusIntent, whiteBalance: WhiteBalanceIntent) async -> Result<AppliedControlSnapshot, CaptureFailure> {
        applications.append(Application(revision: revision, exposure: exposure))
        let invocation = applications.count
        let hold = nextApplicationHold
        nextApplicationHold = nil
        if let hold { await hold.wait() }
        guard invocation == applications.count else {
            return .failure(CaptureFailure(kind: .operationStalled(detail: "synthetic application superseded"), operation: "thirdReview.apply"))
        }
        let snapshot = AppliedControlSnapshot(generation: capabilitySnapshot.generation,
            requestRevision: revision, settlement: converges ? .settled : .awaitingObservation,
            isExposureAdjusting: !converges, isFocusAdjusting: !converges, isWhiteBalanceAdjusting: !converges,
            exposureChoice: exposure, biasEV: biasEV,
            observedDurationSeconds: exposure.durationTargetSeconds ?? 0.01,
            observedISO: exposure.isoTarget ?? 100, observedExposureTargetOffset: 0,
            focusMode: focus.mode, focusPosition: focus.position ?? 0.4,
            whiteBalanceMode: whiteBalance.mode, whiteBalanceGains: WhiteBalanceGains(red: 1.4, green: 1, blue: 1.6),
            lensAperture: 1.6, videoZoomFactor: 1, photoConnectionScale: 1, photoConnectionCrop: 1, capturedAtUTC: Date())
        reading = snapshot
        return .success(snapshot)
    }

    func currentControlReadback() async -> AppliedControlSnapshot? {
        guard var result = reading else { return nil }
        result.settlement = converges ? .settled : .moving
        result.isExposureAdjusting = !converges
        result.isFocusAdjusting = !converges
        result.isWhiteBalanceAdjusting = !converges
        return result
    }

    func beginCapture(intent: CaptureIntent) async -> any CaptureRequestTicket {
        submitted.append(intent)
        let ticket = ChainCameraTicket(captureID: intent.captureID, intent: intent)
        ticket.deliver(.failed(CaptureFailure(kind: .captureFailed(detail: "synthetic terminal: no photo acquired"), operation: "thirdReview.capture")))
        return ticket
    }
}

enum ThirdCameraReviewSuite {
    private static func waitUntil(_ predicate: @escaping @Sendable () async -> Bool) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while !(await predicate()), ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(2)) }
        return await predicate()
    }

    @MainActor
    private static func makeModel(_ camera: ThirdReviewCamera, _ h: StorageHarness) -> (CameraViewModel, CaptureCoordinator) {
        let capture = CaptureCoordinator(camera: camera, store: h.store, clock: SystemMonotonicClock())
        let model = CameraViewModel(camera: camera, capture: capture,
            metering: MeteringService(clock: SystemMonotonicClock()), preferences: SyntheticPreferenceStore(), levelFeed: SyntheticLevelFeed())
        model.updateRootState(h.store.rootState)
        return (model, capture)
    }

    @MainActor
    private static func attachSequence(_ model: CameraViewModel, capture: CaptureCoordinator, h: StorageHarness) -> SequenceCoordinator {
        let clock = SystemMonotonicClock()
        let pipeline = SequenceSourcePipeline(executor: CaptureSequenceExecutor(capture: capture))
        let coordinator = SequenceCoordinator(environment: SequenceCoordinator.Environment(
            clock: clock, wallClock: SystemWallClock(), storage: LibraryStoreSequenceAdapter(store: h.store),
            pipeline: pipeline, settings: CameraSequenceSettingsControl(camera: model),
            baselineSettler: SyntheticBaselineSettler(), bracketSubmitter: UnavailableNativeBracketSubmitter(),
            focusDriver: FocusBracketDriver(clock: clock, controller: model, pipeline: pipeline),
            capability: CameraSequenceCapabilityProvider(camera: model)))
        model.attach(sequence: coordinator)
        return coordinator
    }

    private static func intervalPlan(_ h: StorageHarness) -> SequencePlan {
        SequencePlan(libraryID: h.libraryID, configurationGeneration: .zero, rootGeneration: h.generation,
            physicalCameraKind: .wide, kind: .interval, specification: .interval(IntervalPlan(count: 1, intervalSeconds: 5)), createdAtUTC: Date())
    }

    static let suite = TCSuite(id: "ThirdCameraReview", title: "Interactive setter drain before owned capture and sequence controls", cases: [
        TCCase(id: "TC45D", title: "Immediate shutter cancels a pending paired Auto debounce without superseding its owned application") { r in
            guard let h = await StorageHarness.make(name: "tc45-debounce") else { r.check("fixture", false); return }
            let camera = ThirdReviewCamera(), (model, _) = await makeModel(camera, h)
            await model.start()
            let hold = PrepareHold()
            await camera.holdNextApplication(hold)
            await MainActor.run {
                model.setExposureMode(.manual)
                model.setDuration(0.02)
                model.setStripAutomatic(.shutter)
            }
            let shot = Task { await model.captureNow() }
            r.check("owned single control application really enters", await waitUntil { await hold.didEnter })
            try? await Task.sleep(for: .milliseconds(120))
            r.equal("pending UI debounce cannot issue during owned application", await camera.applications.count, 2)
            r.equal("paired Auto intention reaches the owned application", await camera.applications.last?.exposure, .auto)
            r.equal("held native setter submits no photo", await camera.submitted.count, 0)
            await hold.release()
            await shot.value
            r.equal("current matching reading permits one native submission", await camera.submitted.count, 1)
            r.equal("frozen paired Auto intention preserved", await camera.submitted.last?.exposure, .auto)
            await model.handleCameraScreenCovered()
        },
        TCCase(id: "TC45I", title: "Single capture drains an issued setter even when a newer debounce already replaced its task") { r in
            guard let h = await StorageHarness.make(name: "tc45-inflight") else { r.check("fixture", false); return }
            let camera = ThirdReviewCamera(), (model, _) = await makeModel(camera, h)
            await model.start()
            let hold = PrepareHold()
            await camera.holdNextApplication(hold)
            await model.setExposureMode(.manual)
            r.check("interactive setter is really in flight", await waitUntil { await hold.didEnter })
            await model.setDuration(0.02)
            let shot = Task { await model.captureNow() }
            r.check("shutter owns busy before waiting", await waitUntil { await model.isCapturing })
            try? await Task.sleep(for: .milliseconds(100))
            r.equal("no capture or replacement setter overtakes the issued setter", await camera.applications.count, 2)
            r.equal("no native request overtakes the setter", await camera.submitted.count, 0)
            await camera.setConvergence(false)
            await hold.release()
            r.check("owned manual application starts after the drain", await waitUntil { await camera.applications.count == 3 })
            try? await Task.sleep(for: .milliseconds(100))
            r.equal("moving manual readings still submit no photo", await camera.submitted.count, 0)
            await camera.setConvergence(true)
            await shot.value
            r.equal("only the shutter applies the newest manual intention", await camera.applications.count, 3)
            r.equal("latest manual value reaches native intent", await camera.submitted.last?.exposure, .manual(durationSeconds: 0.02, iso: 100))
            r.equal("one native request after drain", await camera.submitted.count, 1)
            await model.handleCameraScreenCovered()
        },
        TCCase(id: "TC45S", title: "Real interval settings, source admission and restoration start after the whole interactive drain") { r in
            guard let h = await StorageHarness.make(name: "tc45-sequence") else { r.check("fixture", false); return }
            let camera = ThirdReviewCamera(), (model, capture) = await makeModel(camera, h)
            await model.start()
            let coordinator = await attachSequence(model, capture: capture, h: h)
            let hold = PrepareHold()
            await camera.holdNextApplication(hold)
            await model.setExposureMode(.manual)
            r.check("interactive setter is held", await waitUntil { await hold.didEnter })
            await model.setDuration(0.02)
            let run = Task { await model.executeSequence(intervalPlan(h)) }
            r.check("sequence owns busy while draining", await waitUntil { await model.isSequenceRunning })
            try? await Task.sleep(for: .milliseconds(100))
            r.equal("coordinator has not started settings or validation", await coordinator.snapshot().state, .idle)
            r.equal("no sequence setter races the interactive setter", await camera.applications.count, 2)
            await hold.release()
            let result = await run.value
            r.equal("one ordinary source reaches native admission", await camera.submitted.count, 1)
            r.equal("source uses the newest manual intention", await camera.submitted.last?.exposure, .manual(durationSeconds: 0.02, iso: 100))
            r.equal("strict real model restoration succeeds", result?.restoration, .restored)
            r.equal("startup, interactive, baseline, source and restoration only", await camera.applications.count, 5)
            r.check("expected synthetic terminal is not a convergence failure", result?.failure?.operation != "sequence.verifySettings")
            await model.handleCameraScreenCovered()
        },
        TCCase(id: "TC45C", title: "Stop while a sequence waits for the interactive drain cannot be lost before coordinator start") { r in
            guard let h = await StorageHarness.make(name: "tc45-stop") else { r.check("fixture", false); return }
            let camera = ThirdReviewCamera(), (model, capture) = await makeModel(camera, h)
            await model.start()
            let coordinator = await attachSequence(model, capture: capture, h: h)
            let hold = PrepareHold()
            await camera.holdNextApplication(hold)
            await model.setExposureMode(.manual)
            r.check("interactive setter is held", await waitUntil { await hold.didEnter })
            let run = Task { await model.executeSequence(intervalPlan(h)) }
            r.check("sequence owns pending start", await waitUntil { await model.isSequenceRunning })
            await model.cancelSequenceNow()
            await hold.release()
            r.check("cancelled admission returns before coordinator start", await run.value == nil)
            r.equal("no owned sequence control application", await camera.applications.count, 2)
            r.equal("no native source", await camera.submitted.count, 0)
            r.equal("coordinator remains idle", await coordinator.snapshot().state, .idle)
            r.check("busy owner released", await model.isSequenceRunning == false)
            await model.handleCameraScreenCovered()
        },
        TCCase(id: "TC45E", title: "Covering the camera during a held interactive drain revokes single admission") { r in
            guard let h = await StorageHarness.make(name: "tc45-eligibility") else { r.check("fixture", false); return }
            let camera = ThirdReviewCamera(), (model, _) = await makeModel(camera, h)
            await model.start()
            let hold = PrepareHold()
            await camera.holdNextApplication(hold)
            await model.setExposureMode(.manual)
            r.check("interactive setter is held", await waitUntil { await hold.didEnter })
            let shot = Task { await model.captureNow() }
            r.check("capture waits for drain", await waitUntil { await model.isCapturing })
            await model.handleCameraScreenCovered()
            await hold.release()
            await shot.value
            r.equal("no post-cover owned control application", await camera.applications.count, 2)
            r.equal("no post-cover native source", await camera.submitted.count, 0)
            r.check("admission stays closed", await model.runtimeAdmissionReady == false)
        },
        TCCase(id: "TC45H", title: "Queued hardware Auto-to-manual seeding cannot apply after shutter ownership begins") { r in
            guard let h = await StorageHarness.make(name: "tc45-hardware") else { r.check("fixture", false); return }
            let camera = ThirdReviewCamera(), (model, _) = await makeModel(camera, h)
            await model.start()
            let hold = PrepareHold()
            await camera.holdNextApplication(hold)
            await MainActor.run { model.openPanel = .shutter; model.setStripAutomatic(.shutter) }
            r.check("Auto application is really held", await waitUntil { await hold.didEnter })
            let configuration = await model.hardwareConfiguration(enabled: true)
            await model.updateHardwareControls(configuration)
            guard let selection = configuration.selections.first else {
                r.check("hardware shutter fixture", false); await hold.release(); return
            }
            let seed = Task { await model.receiveHardwareSelection(HardwareControlSelection(domain: selection.domain, index: 1)) }
            // Let the command enter its already-existing owned Auto drain.
            for _ in 0..<10 { await Task.yield() }
            let shot = Task { await model.captureNow() }
            r.check("shutter busy owner acquired", await waitUntil { await model.isCapturing })
            let captureHold = PrepareHold()
            await camera.holdNextApplication(captureHold)
            await hold.release()
            r.check("owned single setter really holds the busy owner", await waitUntil { await captureHold.didEnter })
            await seed.value
            r.check("owned single is applying", await waitUntil { await camera.applications.count >= 3 })
            try? await Task.sleep(for: .milliseconds(100))
            r.equal("queued hardware command never issues a new setter", await camera.applications.count, 3)
            r.equal("hardware command does not change desired Auto", await model.exposure, .auto)
            await captureHold.release()
            await shot.value
            r.equal("exactly one ordinary native submission", await camera.submitted.count, 1)
            await model.handleCameraScreenCovered()
        }
    ])
}
