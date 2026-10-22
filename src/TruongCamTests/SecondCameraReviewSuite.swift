import Foundation
#if canImport(XCTest)
@testable import TruongCam
#endif

/// Shipping analysis-request boundary over a synthetic camera; these checks do
/// not infer native camera speed, pressure occurrence or physical capability.
enum SecondCameraReviewSuite {
    static func geometry(_ generation: ConfigurationGeneration = .zero) -> PreviewGeometrySnapshot {
        PreviewGeometrySnapshot(configurationGeneration: generation, layoutGeneration: 7,
            imageDimensions: PixelDimensions(width: 4, height: 3), cleanApertureDimensions: nil,
            previewLayerContentRect: TCRect(x: 0, y: 0, width: 100, height: 100), bufferOrientation: 1,
            isMirrored: false, analysisRotationDegrees: 0, isVideoMirrored: false, capturedAtUTC: Date())
    }
    static func waitUntil(_ predicate: @escaping @Sendable () async -> Bool) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while !(await predicate()), ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(2)) }
        return await predicate()
    }
    static let suite = TCSuite(id: "SecondCameraReview", title: "Acknowledged analysis demand and stale ownership fences", cases: [
        TCCase(id: "SC43L", title: "Loupe drag and threshold requests reuse the acknowledged native output without losing the latest center") { r in
            guard let h = await StorageHarness.make(name: "sc43-loupe") else { r.check("fixture", false); return }
            let service = SyntheticCameraService(capability: StartupRepairSuite.controlFixture(modes: [.auto, .manual]))
            let model = await CameraViewModel(camera: service,
                capture: CaptureCoordinator(camera: ChainCameraSpy(), store: h.store, clock: SystemMonotonicClock()),
                metering: MeteringService(clock: SystemMonotonicClock()), preferences: SyntheticPreferenceStore(), levelFeed: SyntheticLevelFeed())
            await model.start()
            await model.updateGeometry(geometry())
            r.check("current geometry request reaches the camera", await waitUntil {
                await service.analysisRequests.compactMap { $0 }.last?.geometry?.layoutGeneration == 7
            })
            await MainActor.run { model.composition.loupeEnabled = true }
            await model.updateAnalysisDemand()
            let demands = await service.analysisDemands.count, controls = await service.controlApplyCount
            let finalCenter = NormalizedDevicePoint(x: 0.75, y: 0.4)
            await MainActor.run {
                for i in 1...20 { model.setLoupeCenter(NormalizedDevicePoint(x: Double(i) * 0.75 / 20, y: 0.4)) }
            }
            r.check("latest center reaches the actual processing request", await waitUntil {
                await service.analysisRequests.compactMap { $0 }.last?.loupeCenter == finalCenter
            })
            r.equal("drag adds no unchanged native output calls", await service.analysisDemands.count, demands)
            r.equal("drag adds no native control setters", await service.controlApplyCount, controls)
            await MainActor.run { model.composition.peakingThreshold = .high }
            await model.updateAnalysisDemand()
            r.equal("request-only threshold adds no native output call", await service.analysisDemands.count, demands)
            await MainActor.run { model.composition.zebrasEnabled = true }
            await model.updateAnalysisDemand()
            r.equal("changed union demand still crosses native boundary", await service.analysisDemands.count, demands + 1)
            await model.handleCameraScreenCovered()
        },
        TCCase(id: "SC43G", title: "An analysis demand suspended across a new sensor cannot publish or label its cache with that sensor") { r in
            guard let h = await StorageHarness.make(name: "sc43-generation") else { r.check("fixture", false); return }
            let service = SyntheticCameraService(capability: StartupRepairSuite.controlFixture(modes: [.auto]))
            let model = await CameraViewModel(camera: service,
                capture: CaptureCoordinator(camera: ChainCameraSpy(), store: h.store, clock: SystemMonotonicClock()),
                metering: MeteringService(clock: SystemMonotonicClock()), preferences: SyntheticPreferenceStore(), levelFeed: SyntheticLevelFeed())
            await model.start()
            await model.updateGeometry(geometry())
            r.check("initial current request present", await waitUntil { await service.analysisRequests.compactMap { $0 }.last != nil })
            await MainActor.run { model.composition.loupeEnabled = true }
            let before = await service.analysisRequests.count, next = await service.analysisDemands.count + 1
            let hold = PrepareHold()
            await service.holdAnalysisDemand(atCall: next, hold: hold)
            let oldUpdate = Task { await model.updateAnalysisDemand() }
            r.check("old output request reaches held native boundary", await waitUntil { await hold.didEnter })
            let newer = ConfigurationGeneration(1)
            await model.adoptCapability(StartupRepairSuite.controlFixture(modes: [.auto], generation: newer))
            await hold.release()
            await oldUpdate.value
            r.equal("old generation cannot publish a processing request", await service.analysisRequests.count, before)
            await model.updateGeometry(geometry(newer))
            r.check("fresh geometry receives a current request", await waitUntil {
                await service.analysisRequests.compactMap { $0 }.last?.configurationGeneration == newer
            })
            r.equal("old acknowledgement cannot populate a new generation cache", await service.analysisDemands.count, next + 1)
            await model.handleCameraScreenCovered()
        },
        TCCase(id: "SC43R", title: "Returning to the previous demand while a detach is suspended supersedes native work instead of trusting the old cache") { r in
            guard let h = await StorageHarness.make(name: "sc43-replacement") else { r.check("fixture", false); return }
            let service = SyntheticCameraService(capability: StartupRepairSuite.controlFixture(modes: [.auto]))
            let model = await CameraViewModel(camera: service,
                capture: CaptureCoordinator(camera: ChainCameraSpy(), store: h.store, clock: SystemMonotonicClock()),
                metering: MeteringService(clock: SystemMonotonicClock()), preferences: SyntheticPreferenceStore(), levelFeed: SyntheticLevelFeed())
            await model.start()
            await model.updateGeometry(geometry())
            r.check("initial current request present", await waitUntil { await service.analysisRequests.compactMap { $0 }.last != nil })
            // Finish an explicit update so the original demand is acknowledged.
            await model.updateAnalysisDemand()
            let hold = PrepareHold(), next = await service.analysisDemands.count + 1
            await service.holdAnalysisDemand(atCall: next, hold: hold)
            await MainActor.run { model.composition.histogramEnabled = false }
            let detach = Task { await model.updateAnalysisDemand() }
            r.check("native detach is suspended", await waitUntil { await hold.didEnter })
            await MainActor.run { model.composition.histogramEnabled = true }
            await model.updateAnalysisDemand()
            r.equal("return demand supersedes pending native detach", await service.analysisDemands.count, next + 1)
            r.equal("native last request restores histogram", await service.analysisDemands.last?.histogramEnabled, true)
            let restoredRequests = await service.analysisRequests.count
            await hold.release()
            await detach.value
            r.equal("late detach cannot replace the restored request", await service.analysisRequests.count, restoredRequests)
            await model.handleCameraScreenCovered()
        },
        TCCase(id: "SC43O", title: "Same-generation synthetic switch still invalidates an older suspended request by camera-operation ownership") { r in
            guard let h = await StorageHarness.make(name: "sc43-owner") else { r.check("fixture", false); return }
            let service = SyntheticCameraService(capability: StartupRepairSuite.controlFixture(modes: [.auto]))
            await service.configureFacingFixtures([.front: StartupRepairSuite.controlFixture(modes: [.auto], kind: .front, generation: .zero)])
            let model = await CameraViewModel(camera: service,
                capture: CaptureCoordinator(camera: ChainCameraSpy(), store: h.store, clock: SystemMonotonicClock()),
                metering: MeteringService(clock: SystemMonotonicClock()), preferences: SyntheticPreferenceStore(), levelFeed: SyntheticLevelFeed())
            await model.start()
            await model.updateGeometry(geometry())
            r.check("initial current request present", await waitUntil { await service.analysisRequests.compactMap { $0 }.last != nil })
            await MainActor.run { model.composition.loupeEnabled = true }
            let hold = PrepareHold(), next = await service.analysisDemands.count + 1
            await service.holdAnalysisDemand(atCall: next, hold: hold)
            let oldUpdate = Task { await model.updateAnalysisDemand() }
            r.check("old output request held", await waitUntil { await hold.didEnter })
            await model.selectLens(.front)
            r.equal("owned switch uses native output despite a matching demand", await service.analysisDemands.count, next + 1)
            let afterSwitch = await service.analysisRequests.count
            await hold.release()
            await oldUpdate.value
            r.equal("old request cannot reappear after the complete switch", await service.analysisRequests.count, afterSwitch)
            r.equal("front remains selected", await model.capability.selectedCameraKind, .front)
            let latestRequest = await service.analysisRequests.last
            if let request = latestRequest {
                r.check("owned switch publishes no old processing layout", request?.geometry == nil)
            } else {
                r.check("owned switch publishes processing state", false)
            }
            await model.handleCameraScreenCovered()
        }
    ])
}
