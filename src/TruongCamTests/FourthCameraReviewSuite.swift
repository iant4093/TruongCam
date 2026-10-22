import Foundation
#if canImport(XCTest)
@testable import TruongCam
#endif

/// Synthetic native controls/tickets underneath the real model, capture and
/// sequence coordinators. No image is acquired or used as device evidence.
private actor FourthReviewCamera: CameraServicing, CaptureCameraSurface {
    let capabilitySnapshot = StartupRepairSuite.controlFixture(modes: [.auto, .manual])
    private(set) var lifecycle: CameraLifecycle = .idle
    private(set) var applications = 0
    private(set) var applicationRevisions: [UInt64] = []
    private(set) var submitted = 0
    private(set) var reads = 0
    private var reading: AppliedControlSnapshot?
    private var nextFailure = false
    private var nextHold: PrepareHold?
    private var converges = true
    private var terminalSuccess = false
    nonisolated let controlReadbackStream: AsyncStream<AppliedControlSnapshot> = AsyncStream { $0.finish() }
    nonisolated let sessionConditionStream: AsyncStream<CameraLifecycle> = AsyncStream { $0.finish() }
    nonisolated let analysisStream: BoundedOrderedSequence<AnalysisOutput>
    private let analysis = BoundedEventChannel<AnalysisOutput>(capacity: 4)
    private let display = PreviewDisplayBridge()

    init() { analysisStream = analysis.subscribe() }
    func failNextApplication() { nextFailure = true }
    func holdNextApplication(_ hold: PrepareHold) { nextHold = hold }
    func setConvergence(_ value: Bool) { converges = value }
    func setTerminalSuccess(_ value: Bool) { terminalSuccess = value }
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
        applications += 1
        applicationRevisions.append(revision)
        let invocation = applications
        let fails = nextFailure, hold = nextHold
        nextFailure = false; nextHold = nil
        if let hold { await hold.wait() }
        guard invocation == applications, !fails else {
            return .failure(CaptureFailure(kind: .restorationFailed(detail: "synthetic native setter failure"), operation: "fourthReview.apply"))
        }
        var snapshot = AppliedControlSnapshot(generation: capabilitySnapshot.generation,
            requestRevision: revision, settlement: converges ? .settled : .awaitingObservation,
            isExposureAdjusting: !converges, isFocusAdjusting: !converges, isWhiteBalanceAdjusting: !converges,
            exposureChoice: exposure, biasEV: biasEV,
            observedDurationSeconds: exposure.durationTargetSeconds ?? 0.01,
            observedISO: exposure.isoTarget ?? 100, observedExposureTargetOffset: 0,
            focusMode: focus.mode, focusPosition: focus.position ?? 0.4,
            whiteBalanceMode: whiteBalance.mode, whiteBalanceGains: WhiteBalanceGains(red: 1.4, green: 1, blue: 1.6),
            lensAperture: 1.6, videoZoomFactor: 1, photoConnectionScale: 1, photoConnectionCrop: 1, capturedAtUTC: Date())
        snapshot.observedWhiteBalanceTemperatureAndTint = WhiteBalanceTemperatureAndTint(temperature: 4700, tint: 12)
        reading = snapshot
        return .success(snapshot)
    }

    func currentControlReadback() async -> AppliedControlSnapshot? {
        reads += 1
        guard var result = reading else { return nil }
        result.settlement = converges ? .settled : .moving
        result.isExposureAdjusting = !converges
        result.isFocusAdjusting = !converges
        result.isWhiteBalanceAdjusting = !converges
        return result
    }
    func beginCapture(intent: CaptureIntent) async -> any CaptureRequestTicket {
        submitted += 1
        let ticket = ChainCameraTicket(captureID: intent.captureID, intent: intent)
        if terminalSuccess { ticket.deliver(.success) }
        else { ticket.deliver(.failed(CaptureFailure(kind: .captureFailed(detail: "synthetic terminal: no photo acquired"), operation: "fourthReview.capture"))) }
        return ticket
    }
}

/// Fault only the first restoration's actual native setter; every settings
/// operation still traverses CameraSequenceSettingsControl and the real model.
private actor FourthReviewSettings: SequenceSettingsControlling {
    let actual: CameraSequenceSettingsControl
    let camera: FourthReviewCamera
    private var failRestore = true
    private(set) var resets = 0
    init(model: CameraViewModel, camera: FourthReviewCamera) {
        actual = CameraSequenceSettingsControl(camera: model)
        self.camera = camera
    }
    func snapshotCurrentSettings() async -> SequenceSettingsSnapshot? { await actual.snapshotCurrentSettings() }
    func currentExposureBaseline() async -> ExposureBaseline? { await actual.currentExposureBaseline() }
    func prepareFocusLockForBaseline(_ prior: SequenceSettingsSnapshot) async -> Result<Bool, CaptureFailure> { await actual.prepareFocusLockForBaseline(prior) }
    func apply(_ settings: SequenceSettingsSnapshot) async -> Result<Void, CaptureFailure> { await actual.apply(settings) }
    func restore(_ settings: SequenceSettingsSnapshot) async -> Result<Void, CaptureFailure> {
        if failRestore { failRestore = false; await camera.failNextApplication() }
        return await actual.restore(settings)
    }
    func resetToAuto() async -> Result<Void, CaptureFailure> {
        resets += 1
        return await actual.resetToAuto()
    }
}

enum FourthCameraReviewSuite {
    private static func waitUntil(_ predicate: @escaping @Sendable () async -> Bool) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while !(await predicate()), ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(2)) }
        return await predicate()
    }
    @MainActor
    private static func makeModel(_ camera: FourthReviewCamera, _ h: StorageHarness) -> (CameraViewModel, CaptureCoordinator) {
        let capture = CaptureCoordinator(camera: camera, store: h.store, clock: SystemMonotonicClock())
        let model = CameraViewModel(camera: camera, capture: capture,
            metering: MeteringService(clock: SystemMonotonicClock()), preferences: SyntheticPreferenceStore(), levelFeed: SyntheticLevelFeed())
        model.updateRootState(h.store.rootState)
        return (model, capture)
    }
    @MainActor
    private static func attach(_ model: CameraViewModel, camera: FourthReviewCamera,
                               capture: CaptureCoordinator, h: StorageHarness) -> (SequenceCoordinator, FourthReviewSettings) {
        let clock = SystemMonotonicClock(), settings = FourthReviewSettings(model: model, camera: camera)
        let pipeline = SequenceSourcePipeline(executor: CaptureSequenceExecutor(capture: capture))
        let coordinator = SequenceCoordinator(environment: SequenceCoordinator.Environment(
            clock: clock, wallClock: SystemWallClock(), storage: LibraryStoreSequenceAdapter(store: h.store),
            pipeline: pipeline, settings: settings, baselineSettler: SyntheticBaselineSettler(),
            bracketSubmitter: UnavailableNativeBracketSubmitter(),
            focusDriver: FocusBracketDriver(clock: clock, controller: model, pipeline: pipeline),
            capability: CameraSequenceCapabilityProvider(camera: model)))
        model.attach(sequence: coordinator)
        return (coordinator, settings)
    }
    private static func plan(_ h: StorageHarness) -> SequencePlan {
        SequencePlan(libraryID: h.libraryID, configurationGeneration: .zero, rootGeneration: h.generation,
            physicalCameraKind: .wide, kind: .interval, specification: .interval(IntervalPlan(count: 1, intervalSeconds: 5)), createdAtUTC: Date())
    }

    static let suite = TCSuite(id: "FourthCameraReview", title: "Visible restoration recovery reaches the real coordinator and strict native controls", cases: [
        TCCase(id: "TC46R", title: "Visible Reset waits for native readback, clears both latches and admits the next sequence") { r in
            guard let h = await StorageHarness.make(name: "tc46-reset-connected") else { r.check("fixture", false); return }
            let camera = FourthReviewCamera(), (model, capture) = await makeModel(camera, h)
            await model.start()
            let (coordinator, settings) = await attach(model, camera: camera, capture: capture, h: h)
            let first = await model.executeSequence(plan(h))
            r.equal("actual restoration setter fails", first?.restoration, .failed)
            r.check("coordinator retains actual latch", await coordinator.snapshot().offersResetToAuto)
            r.check("visible action survives the acquisition error", await model.lastFailure?.actions.contains(.resetToAuto) == true)
            // The source's actual native diagnostic remains independent of
            // restoration; Reset must survive both failures.
            if let sourceFailure = first?.failure {
                r.equal("real source failure remains distinct from restoration", sourceFailure.kind.stableCode, "captureFailed")
                r.equal("native operation survives the capture adapter", sourceFailure.operation, "fourthReview.capture")
                r.check("full source failure remains in diagnostics", AppDiagnostics.description(for: sourceFailure, operation: "test.sequence").contains(sourceFailure.description))
                r.check("friendly recovery does not expose the acquisition detail", await model.lastFailure?.detail.contains(sourceFailure.kind.userDescription) == false)
                r.check("visible recovery remains actionable", await model.lastFailure?.detail.contains("Reset to Auto") == true)
            } else {
                r.check("real source failure is available for presentation", false)
            }
            let hold = PrepareHold()
            await camera.holdNextApplication(hold)
            await camera.setConvergence(false)
            await MainActor.run { model.resetControlsToAuto(); model.clearLastFailure(); model.resetControlsToAuto() }
            r.check("real reset setter begins", await waitUntil { await hold.didEnter })
            r.equal("repeated action has one reset owner", await settings.resets, 1)
            r.check("held reset owns busy", await model.isResettingControls)
            r.check("held reset cannot enable shutter", await model.isShutterEnabled == false)
            let beforeReads = await camera.reads
            await hold.release()
            r.check("acknowledged reset waits for live observation", await waitUntil { await camera.reads > beforeReads })
            r.check("moving Auto readback retains UI latch", await model.sequenceBlockedByRestorationFailure != nil)
            r.check("moving Auto readback retains coordinator block", await coordinator.snapshot().isShutterBlocked)
            await camera.setConvergence(true)
            r.check("strict current observation completes reset", await waitUntil { await model.isResettingControls == false })
            r.check("UI restoration latch clears", await model.sequenceBlockedByRestorationFailure == nil)
            r.check("coordinator restoration latch clears", await coordinator.snapshot().offersResetToAuto == false)
            let next = await model.executeSequence(plan(h))
            r.equal("subsequent sequence restores normally", next?.restoration, .restored)
            r.equal("both sequences reach native source admission", await camera.submitted, 2)
            r.check("subsequent sequence is not rejected by stale latch", next?.failure?.operation != "sequence.start")
            await model.handleCameraScreenCovered()
        },
        TCCase(id: "TC46F", title: "Failed visible Reset preserves both blocks and a successful explicit retry releases them") { r in
            guard let h = await StorageHarness.make(name: "tc46-reset-failure") else { r.check("fixture", false); return }
            let camera = FourthReviewCamera(), (model, capture) = await makeModel(camera, h)
            await model.start()
            let (coordinator, settings) = await attach(model, camera: camera, capture: capture, h: h)
            _ = await model.executeSequence(plan(h))
            await camera.failNextApplication()
            await MainActor.run { model.resetControlsToAuto(); model.clearLastFailure() }
            r.check("failed reset drains", await waitUntil { await model.isResettingControls == false })
            r.check("UI failure keeps Reset action", await model.lastFailure?.actions.contains(.resetToAuto) == true)
            r.check("UI block retained", await model.sequenceBlockedByRestorationFailure != nil)
            r.check("coordinator latch retained", await coordinator.snapshot().offersResetToAuto)
            let rejected = await model.executeSequence(plan(h))
            r.equal("new sequence rejected before source submission", rejected?.failure?.operation, "sequence.start")
            r.equal("no extra native source after failed reset", await camera.submitted, 1)
            await model.resetControlsToAuto()
            r.check("explicit retry finishes", await waitUntil { await model.isResettingControls == false })
            r.equal("exactly two real coordinator reset attempts", await settings.resets, 2)
            r.check("retry clears coordinator recovery", await coordinator.snapshot().offersResetToAuto == false)
            r.check("retry clears UI recovery", await model.sequenceBlockedByRestorationFailure == nil)
            let next = await model.executeSequence(plan(h))
            r.equal("next sequence can run", next?.restoration, .restored)
            r.equal("only accepted sequences submit", await camera.submitted, 2)
            await model.handleCameraScreenCovered()
        },
        TCCase(id: "TC46P", title: "Reset never clears pending originals or bypasses their shutter fence") { r in
            guard let h = await StorageHarness.make(name: "tc46-reset-pending") else { r.check("fixture", false); return }
            let camera = FourthReviewCamera(), (model, capture) = await makeModel(camera, h)
            await model.start()
            let (_, settings) = await attach(model, camera: camera, capture: capture, h: h)
            _ = await model.executeSequence(plan(h))
            await model.updatePendingOriginalCount(1)
            await model.resetControlsToAuto()
            r.check("reset finishes", await waitUntil { await model.isResettingControls == false })
            r.equal("one coordinator reset", await settings.resets, 1)
            r.equal("pending originals stay retained", await model.pendingOriginalCount, 1)
            r.check("pending original still blocks shutter", await model.isShutterEnabled == false)
            r.equal("reset acquires no image", await camera.submitted, 1)
            await model.handleCameraScreenCovered()
        },
        TCCase(id: "TC46N", title: "The no-coordinator reset drains interactive controls and verifies Auto without taking a photo") { r in
            guard let h = await StorageHarness.make(name: "tc46-reset-ordinary") else { r.check("fixture", false); return }
            let camera = FourthReviewCamera(), (model, _) = await makeModel(camera, h)
            await model.start()
            let interactive = PrepareHold(), reset = PrepareHold()
            await camera.holdNextApplication(interactive)
            await model.setExposureMode(.manual)
            r.check("interactive setter is really held", await waitUntil { await interactive.didEnter })
            await camera.holdNextApplication(reset)
            await model.resetControlsToAuto()
            r.check("reset owns busy during predecessor drain", await model.isResettingControls)
            r.equal("reset does not overtake interactive setter", await camera.applications, 2)
            await interactive.release()
            r.check("owned reset starts after predecessor", await waitUntil { await reset.didEnter })
            await reset.release()
            r.check("ordinary reset finishes", await waitUntil { await model.isResettingControls == false })
            r.equal("desired exposure is Auto", await model.exposure, .auto)
            r.equal("observed Auto is verified", await model.lastReadback?.exposureChoice, .auto)
            r.equal("only startup, interactive and reset applications", await camera.applications, 3)
            r.equal("reset submits no photo", await camera.submitted, 0)
            r.check("ordinary reset leaves no recovery block", await model.sequenceBlockedByRestorationFailure == nil)
            await model.handleCameraScreenCovered()
        },
        TCCase(id: "TC46H", title: "After either ordinary native terminal, Camera Control rebinds current Auto and seeds measured shutter ISO focus and WB") { r in
            for success in [false, true] {
                for panel in [CameraPanel.shutter, .iso, .focus, .whiteBalance] {
                    guard let h = await StorageHarness.make(name: "tc46-hardware-\(success)-\(panel)") else { r.check("fixture", false); continue }
                    let camera = FourthReviewCamera(), (model, _) = await makeModel(camera, h)
                    await model.start()
                    await camera.setTerminalSuccess(success)
                    await model.captureNow()
                    let captureRevision = await camera.lastAppliedSnapshot()?.requestRevision
                    r.check("ordinary source uses frozen capture identity", (captureRevision ?? 0) > 1_000_000)
                    await MainActor.run { model.openPanel = panel }
                    let configuration = await model.hardwareConfiguration(enabled: true)
                    await model.updateHardwareControls(configuration)
                    guard let picker = configuration.selections.first else {
                        r.check("hardware picker exists", false); await model.handleCameraScreenCovered(); continue
                    }
                    let beforeApplications = await camera.applications
                    await model.receiveHardwareSelection(HardwareControlSelection(domain: picker.domain, index: 1))
                    let revisions = await camera.applicationRevisions
                    r.equal("acknowledged UI rebind owns its actual UI identity", revisions.dropFirst(beforeApplications).first, UInt64(0))
                    switch panel {
                    case .shutter: r.equal("shutter seeds actual duration", await model.exposure.durationTargetSeconds, 0.01)
                    case .iso: r.equal("ISO seeds actual ISO", await model.exposure.isoTarget, 100)
                    case .focus: r.equal("focus seeds actual position", await model.focus.position, 0.4)
                    case .whiteBalance:
                        r.equal("WB seeds measured temperature", await model.whiteBalance.temperatureAndTint?.temperature, 4700)
                        r.equal("WB preserves measured tint", await model.whiteBalance.temperatureAndTint?.tint, 12)
                    case .exposureBias: break
                    }
                    r.check("manual seed reaches actual interactive setter", await waitUntil { await camera.applications == beforeApplications + 2 })
                    r.equal("hardware seed takes no new photo", await camera.submitted, 1)
                    await model.handleCameraScreenCovered()
                }
            }
        },
        TCCase(id: "TC46B", title: "Post-photo Auto rebind drains before shutter and never publishes a cancelled or replaced hardware seed") { r in
            for replacement in 0..<3 {
                guard let h = await StorageHarness.make(name: "tc46-hardware-owned-\(replacement)") else { r.check("fixture", false); continue }
                let camera = FourthReviewCamera(), (model, _) = await makeModel(camera, h)
                await model.start()
                await model.captureNow()
                await MainActor.run { model.openPanel = .shutter }
                let configuration = await model.hardwareConfiguration(enabled: true)
                await model.updateHardwareControls(configuration)
                guard let picker = configuration.selections.first else { r.check("hardware picker", false); continue }
                let hold = PrepareHold()
                await camera.holdNextApplication(hold)
                let seed = Task { await model.receiveHardwareSelection(HardwareControlSelection(domain: picker.domain, index: 1)) }
                r.check("post-photo rebind is actually in flight", await waitUntil { await hold.didEnter })
                if replacement == 0 {
                    let captureHold = PrepareHold()
                    await camera.holdNextApplication(captureHold)
                    let shot = Task { await model.captureNow() }
                    r.check("shutter owns busy while rebind drains", await waitUntil { await model.isCapturing })
                    r.equal("shutter cannot overtake rebind", await camera.applications, 3)
                    await hold.release()
                    r.check("shutter application follows rebind", await waitUntil { await captureHold.didEnter })
                    await seed.value
                    r.equal("busy hardware seed leaves Auto untouched", await model.exposure, .auto)
                    await captureHold.release()
                    await shot.value
                    r.equal("only owned shutter acquires another source", await camera.submitted, 2)
                } else if replacement == 1 {
                    seed.cancel()
                    await hold.release()
                    await seed.value
                    r.equal("cancelled numeric command leaves Auto", await model.exposure, .auto)
                    r.equal("cancelled seed takes no photo", await camera.submitted, 1)
                } else {
                    await model.updateRootState(.unselected)
                    await hold.release()
                    await seed.value
                    r.equal("replaced root cannot publish manual seed", await model.exposure, .auto)
                    r.equal("root replacement takes no photo", await camera.submitted, 1)
                }
                await model.handleCameraScreenCovered()
            }
        }
    ])
}
