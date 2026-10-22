import Foundation
#if canImport(XCTest)
@testable import TruongCam
#endif

enum JPEGPreparationUISuite {
    private static func waitUntil(_ condition: @Sendable () async -> Bool) async -> Bool {
        for _ in 0..<500 {
            if await condition() { return true }
            try? await Task.sleep(for: .milliseconds(2))
        }
        return false
    }
    static let suite = TCSuite(id: "JPEGPreparationUI52", title: "Optional preparation never holds shutter readiness", cases: [
        TCCase(id: "JP52A", title: "A held JPEG hint cannot block format choice, shutter admission or cancellation") { r in
            guard let h = await StorageHarness.make(name: "format-hint52") else { r.check("store fixture", false); return }
            let service = SyntheticCameraService(capability: CaptureFormatUISuite.capability())
            await service.setHoldsFormatPreparation(true)
            let model = await CameraViewModel(camera: service,
                capture: CaptureCoordinator(camera: ChainCameraSpy(), store: h.store, clock: SystemMonotonicClock()),
                metering: MeteringService(clock: SystemMonotonicClock()), preferences: SyntheticPreferenceStore(), levelFeed: SyntheticLevelFeed())
            await model.updateRootState(.writable(libraryID: h.libraryID, generation: h.generation))
            await model.start()
            r.equal("no hidden RAW resource hint", await service.formatPreparationRequests.count, 0)
            await model.selectCaptureFormat(.jpeg)
            let entered = await waitUntil { await service.formatPreparationRequests.count == 1 }
            r.check("optional JPEG preparation starts", entered)
            r.check("shutter remains admitted without completion", await model.isShutterEnabled)
            r.check("native resource hint is not capture ownership", !(await model.isCaptureBusy))
            r.check("choice remains enabled while hint held", await model.isCaptureFormatSelectionEnabled)
            await model.selectCaptureFormat(.bayerDNG)
            let invalidated = await waitUntil { await service.formatPreparationRequests.count == 2 }
            r.check("non-JPEG choice invalidates pending native hint", invalidated)
            r.equal("latest native hint intent is RAW", await service.formatPreparationRequests.last?.format, .bayerDNG)
            r.equal("format change does not rebuild graph", await service.prepareRequests, 1)
            await model.stop()
            let stopped = await service.formatPreparationRequests.count
            r.check("stopped model closes shutter immediately", !(await model.isShutterEnabled))
            r.check("stopped model closes lens/format selection", !(await model.isCaptureFormatSelectionEnabled))
            await model.selectCaptureFormat(.jpeg)
            r.equal("ineligible camera cannot enqueue preparation", await service.formatPreparationRequests.count, stopped)
            await service.setHoldsFormatPreparation(false)
            await model.startIfNeeded()
            r.check("an explicit restart restores shutter admission", await model.isShutterEnabled)
            r.check("an explicit restart restores lens/format selection", await model.isCaptureFormatSelectionEnabled)
            await model.stop()
        },
        TCCase(id: "JP52B", title: "Remembered JPEG warms only after startup and keeps its current generation") { r in
            guard let h = await StorageHarness.make(name: "remembered-hint52") else { r.check("store fixture", false); return }
            let capability = CaptureFormatUISuite.capability()
            let service = SyntheticCameraService(capability: capability)
            await service.holdStart()
            var preferences = SyntheticPreferenceStore(); preferences.captureFormat = .jpeg
            let model = await CameraViewModel(camera: service,
                capture: CaptureCoordinator(camera: ChainCameraSpy(), store: h.store, clock: SystemMonotonicClock()),
                metering: MeteringService(clock: SystemMonotonicClock()), preferences: preferences, levelFeed: SyntheticLevelFeed())
            let start = Task { await model.start() }
            let waiting = await waitUntil { await service.startRequests == 1 }
            r.check("startup is held", waiting)
            r.equal("no hint before graph finishes", await service.formatPreparationRequests.count, 0)
            await service.releaseStart(); await start.value
            let entered = await waitUntil { await service.formatPreparationRequests.count == 1 }
            r.check("remembered JPEG prepares after current start", entered)
            r.equal("hint belongs to admitted generation", await service.formatPreparationRequests.last?.generation, capability.generation)
            r.equal("hint belongs to explicit format", await service.formatPreparationRequests.last?.format, .jpeg)
            await model.stop()
        }
    ])
}
