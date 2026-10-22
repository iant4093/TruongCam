import Foundation
#if canImport(XCTest)
@testable import TruongCam
#endif

enum ResetAnalysisTopologySuite {
    private static let reset = CameraLifecycle.failed(.cameraInterrupted(detail: MediaServicesResetSignal.detail))
    private static func fixture(_ name: String) async -> (SyntheticCameraService, CameraViewModel, MeteringService)? {
        guard let h = await StorageHarness.make(name: name) else { return nil }
        let service = SyntheticCameraService(capability: StartupRepairSuite.controlFixture(modes: [.auto]))
        let metering = MeteringService(clock: SystemMonotonicClock())
        let model = await CameraViewModel(camera: service,
            capture: CaptureCoordinator(camera: ChainCameraSpy(), store: h.store, clock: SystemMonotonicClock()),
            metering: metering, preferences: SyntheticPreferenceStore(), levelFeed: SyntheticLevelFeed())
        await model.start()
        return (service, model, metering)
    }

    private static func disclose(_ reason: String, through metering: MeteringService) async {
        let geometry = PreviewGeometrySnapshot(configurationGeneration: .zero, layoutGeneration: 1,
            imageDimensions: .init(width: 4000, height: 3000), cleanApertureDimensions: nil,
            previewLayerContentRect: .init(x: 0, y: 0, width: 300, height: 400), bufferOrientation: 1,
            isMirrored: false, analysisRotationDegrees: 90, isVideoMirrored: false, capturedAtUTC: Date())
        let decision = AnalysisDemandPolicy.decide(configuration: .default, lifecycle: .activeCameraView, geometry: geometry)
        await metering.setDemand(decision.request)
        await metering.reportAnalysisUnavailable(reason: reason)
    }

    private static func wait(_ predicate: @escaping @Sendable () async -> Bool) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while ContinuousClock.now < deadline {
            if await predicate() { return true }
            try? await Task.sleep(for: .milliseconds(1))
        }
        return await predicate()
    }

    static let suite = TCSuite(id: "ResetAnalysisTopology", title: "Typed reset analysis and recovery ownership", cases: [
        TCCase(id: "RA01", title: "Typed reset retains enabled output without processing and clears only its transient disclosure") { r in
            guard let (service, model, metering) = await fixture("ra01-reserved-reset") else { r.check("fixture", false); return }
            let count = await service.analysisDemands.count
            await disclose(MediaServicesResetSignal.analysisUnavailableReason, through: metering)
            r.check("real output stream delivers transient reason", await wait {
                await model.analysisUnavailableReason == MediaServicesResetSignal.analysisUnavailableReason
            })
            await model.applyServiceCondition(reset)
            await model.updateAnalysisDemand()
            r.equal("ordinary failed-state callbacks cannot detach a rebuilding graph", await service.analysisDemands.count, count)
            r.check("capture is closed during reset", !(await model.runtimeAdmissionReady))
            r.check("old visible masks and loupe are cleared", await MainActor.run { model.masks == nil && model.loupe == nil })
            r.check("processing request is explicitly nil", (await service.analysisRequests.last ?? nil) == nil)
            await service.holdStart()
            let recovery = Task { await model.applyServiceCondition(.reconfiguring) }
            r.check("native recovery start is genuinely held", await wait { await service.startRequests == 2 })
            await model.updateAnalysisDemand()
            r.check("all owned output reservations stay enabled", await service.analysisDemands.allSatisfy(\.wantsVideoOutput))
            r.check("unlaid-out recovery never processes a frame", await service.analysisRequests.allSatisfy { $0 == nil })
            await service.releaseStart(); await recovery.value
            r.check("verified recovery reopens capture", await model.runtimeAdmissionReady)
            r.check("only reset disclosure is cleared", await model.analysisUnavailableReason == nil)
            r.check("reset never cycles enabled output", await service.analysisDemands.allSatisfy(\.wantsVideoOutput))
            await model.handleCameraScreenCovered()
        },
        TCCase(id: "RA02", title: "A newer reset owns recovery after an older held native start drains") { r in
            guard let (service, model, _) = await fixture("ra02-newer-reset") else { r.check("fixture", false); return }
            await model.applyServiceCondition(reset)
            await service.holdStart()
            let older = Task { await model.applyServiceCondition(.reconfiguring) }
            r.check("old start held", await wait { await service.startRequests == 2 })
            await model.applyServiceCondition(reset)
            // The real reset invalidates the old native start. The synthetic
            // service's stop advances that same kind of native ownership fence.
            await service.stop()
            await model.applyServiceCondition(.reconfiguring)
            r.equal("new recovery waits for old start to drain", await service.startRequests, 2)
            r.check("new reset keeps capture closed", !(await model.runtimeAdmissionReady))
            await service.releaseStart(); await older.value
            r.check("one deferred latest recovery finishes", await wait { await model.runtimeAdmissionReady })
            r.equal("exactly one latest start after the old one", await service.startRequests, 3)
            r.check("obsolete failure did not overwrite latest success", await model.lastFailure == nil)
            r.equal("current recovery is running", await model.serviceRecordedCondition, .running)
            r.check("no old completion detached current output", await service.analysisDemands.allSatisfy(\.wantsVideoOutput))
            await model.handleCameraScreenCovered()
        },
        TCCase(id: "RA03", title: "Backgrounding revokes held reset recovery without running a hidden sensor or admitting capture") { r in
            guard let (service, model, _) = await fixture("ra03-reset-background") else { r.check("fixture", false); return }
            await model.applyServiceCondition(reset)
            await service.holdStart()
            let recovery = Task { await model.applyServiceCondition(.reconfiguring) }
            r.check("recovery held", await wait { await service.startRequests == 2 })
            await model.handleSceneBecameInactive()
            await service.releaseStart(); await recovery.value
            r.equal("sensor remains stopped", await service.lifecycle, .idle)
            r.equal("no extra hidden recovery start", await service.startRequests, 2)
            r.check("capture stays closed", !(await model.runtimeAdmissionReady))
            r.check("hardware action is disabled", !(await model.isHardwareShutterEnabled))
            r.check("no old processing request survives", (await service.analysisRequests.last ?? nil) == nil)
        },
        TCCase(id: "RA05", title: "A fresh foreground start clears the transient reset disclosure after an ineligible recovery") { r in
            guard let (service, model, metering) = await fixture("ra05-reset-foreground") else { r.check("fixture", false); return }
            await disclose(MediaServicesResetSignal.analysisUnavailableReason, through: metering)
            r.check("reset disclosure arrives", await wait { await model.analysisUnavailableReason == MediaServicesResetSignal.analysisUnavailableReason })
            await model.applyServiceCondition(reset)
            await service.holdStart()
            let recovery = Task { await model.applyServiceCondition(.reconfiguring) }
            r.check("recovery start held", await wait { await service.startRequests == 2 })
            await model.handleSceneBecameInactive()
            await service.releaseStart(); await recovery.value
            r.check("ineligible completion cannot clear the disclosure", await model.analysisUnavailableReason == MediaServicesResetSignal.analysisUnavailableReason)
            await model.handleSceneBecameActive()
            r.check("fresh verified foreground camera can capture", await wait { await model.runtimeAdmissionReady })
            r.check("transient disclosure clears on fresh verified startup", await model.analysisUnavailableReason == nil)
            r.check("foreground restart did not cycle enabled output", await service.analysisDemands.allSatisfy(\.wantsVideoOutput))
            await model.handleCameraScreenCovered()
        },
        TCCase(id: "RA04", title: "Verified camera reset does not erase a genuine unsupported analysis reason") { r in
            guard let (service, model, metering) = await fixture("ra04-real-analysis-failure") else { r.check("fixture", false); return }
            let reason = "Synthetic actual unsupported analysis format"
            await disclose(reason, through: metering)
            r.check("real unavailable disclosure arrives", await wait { await model.analysisUnavailableReason == reason })
            await model.applyServiceCondition(reset)
            await model.applyServiceCondition(.reconfiguring)
            r.check("native camera may recover independently of aid support", await model.runtimeAdmissionReady)
            r.equal("genuine unsupported reason is retained", await model.analysisUnavailableReason, reason)
            r.check("unsupported aid stays detached after verification", await service.analysisDemands.last?.wantsVideoOutput == false)
            r.check("no fabricated processing request", (await service.analysisRequests.last ?? nil) == nil)
            await model.handleCameraScreenCovered()
        }
    ])
}
