import Foundation
import Synchronization
#if canImport(XCTest)
@testable import TruongCam
#endif

/// Isolated preference persistence for shipping-model tests. No shared defaults,
/// native photos, provider files or actual camera are used.
private final class Format51Preferences: PreferenceStoring, @unchecked Sendable {
    private let stored: Mutex<CaptureFileFormat>
    init(_ format: CaptureFileFormat = .bayerDNG) { stored = Mutex(format) }
    func loadPreferredCaptureFormat() -> CaptureFileFormat { stored.withLock { $0 } }
    func storePreferredCaptureFormat(_ format: CaptureFileFormat) { stored.withLock { $0 = format } }
    func loadCompositionPreferences() -> CompositionPreferences? { CompositionPreferences() }
    func storeCompositionPreferences(_ preferences: CompositionPreferences) {}
    func loadSequencePreferences() -> SequencePlanPreferences? { nil }
    func storeSequencePreferences(_ preferences: SequencePlanPreferences) {}
}

/// A measurable synthetic control boundary that delegates native ticket ownership
/// to the existing production-request fixture. It cannot produce an actual photo.
private actor Format51CaptureCamera: CaptureCameraSurface {
    let native: ChainCameraSpy
    let capabilitySnapshot: CameraCapabilitySnapshot
    var lifecycle: CameraLifecycle { .running }
    private var reading: AppliedControlSnapshot?
    init(native: ChainCameraSpy, capability: CameraCapabilitySnapshot) {
        self.native = native; self.capabilitySnapshot = capability
    }
    func applyControls(revision: UInt64, exposure: ExposureChoice, biasEV: Double,
                       focus: FocusIntent, whiteBalance: WhiteBalanceIntent) -> Result<AppliedControlSnapshot, CaptureFailure> {
        let value = AppliedControlSnapshot(generation: capabilitySnapshot.generation, requestRevision: revision,
            settlement: .settled, exposureChoice: exposure, biasEV: biasEV,
            observedDurationSeconds: 0.01, observedISO: 100, observedExposureTargetOffset: 0,
            focusMode: focus.mode, focusPosition: 0.4, whiteBalanceMode: whiteBalance.mode,
            whiteBalanceGains: WhiteBalanceGains(red: 1.4, green: 1, blue: 1.6), lensAperture: 1.6,
            videoZoomFactor: 1, photoConnectionScale: 1, photoConnectionCrop: 1, capturedAtUTC: Date())
        reading = value
        return .success(value)
    }
    func currentControlReadback() -> AppliedControlSnapshot? { reading }
    func beginCapture(intent: CaptureIntent) async -> any CaptureRequestTicket { await native.beginCapture(intent: intent) }
}

enum CaptureFormatUISuite {
    static func capability(kind: PhysicalCameraKind = .wide, raw: Bool = true, heif: Bool = false,
                           jpeg: Bool = true) -> CameraCapabilitySnapshot {
        var value = StartupRepairSuite.controlFixture(modes: [.auto, .manual], kind: kind, heif: heif)
        value.bayerCaptureSupported = raw ? .available(true) : .unavailable(reason: "Synthetic camera has no Bayer output")
        value.jpegSupported = jpeg
        value.jpegMaximumDimensions = jpeg ? PixelDimensions(width: 8000, height: 6000) : nil
        return value
    }

    static func makeModel(h: StorageHarness, capability: CameraCapabilitySnapshot,
                                  preferences: any PreferenceStoring = SyntheticPreferenceStore(),
                                  native: ChainCameraSpy = ChainCameraSpy()) async -> (CameraViewModel, SyntheticCameraService) {
        let service = SyntheticCameraService(capability: capability)
        let model = await CameraViewModel(camera: service,
            capture: CaptureCoordinator(camera: Format51CaptureCamera(native: native, capability: capability), store: h.store, clock: SystemMonotonicClock()),
            metering: MeteringService(clock: SystemMonotonicClock()), preferences: preferences, levelFeed: SyntheticLevelFeed())
        await model.updateRootState(.writable(libraryID: h.libraryID, generation: h.generation))
        await model.start()
        return (model, service)
    }

    static let suite = TCSuite(id: "CaptureFormatUI", title: "Explicit JPEG choice and capture-tools cleanup", cases: [
        TCCase(id: "JF51P", title: "The explicit JPEG preference persists without changing camera topology or discarding remembered RAW sequences") { r in
            guard let h = await StorageHarness.make(name: "format51-preference") else { r.check("fixture", false); return }
            let preferences = Format51Preferences()
            let (model, service) = await makeModel(h: h, capability: capability(), preferences: preferences)
            await model.setExposureBracketEnabled(true)
            let hardware = await model.hardwareConfiguration(enabled: true)
            await model.updateHardwareControls(hardware)
            let interaction = await model.hardwareInteractionID
            r.check("usable selector", await model.isCaptureFormatSelectionEnabled)
            await model.selectCaptureFormat(.jpeg)
            r.equal("processed mode is explicit", await model.effectiveCaptureFileFormat, .jpeg)
            r.equal("chip says JPEG", await model.captureFormatLabel, "JPEG")
            r.check("accessible format says no RAW", await model.captureFormatAccessibilityLabel.contains("no RAW"))
            r.equal("preference persisted", preferences.loadPreferredCaptureFormat(), .jpeg)
            if let lens = hardware.selections.first, lens.domain.options.count > 1 {
                await model.receiveHardwareEvent(HardwareControlEvent(interactionID: interaction,
                    selection: HardwareControlSelection(domain: lens.domain, index: 1)))
            } else { r.check("hardware lens selection fixture", false) }
            r.equal("old hardware event cannot change camera", await service.switchRequests.count, 0)
            r.equal("no graph preparation restart", await service.prepareRequests, 1)
            r.check("old hardware interaction revoked", await model.hardwareInteractionID != interaction)
            r.equal("JPEG shutter is one photo", await model.activeShutterMode, .single)
            r.equal("RAW sequence remembered", await model.sequencePreferences.shutterMode, .exposureBracket)
            r.check("sequence controls unavailable in JPEG", !(await model.isSequenceCaptureAvailable))
            await model.requestSequence(.focusBracket)
            r.equal("direct sequence call cannot silently take RAW", await model.lastNotice, "Choose RAW to take a series of photos.")
            r.check("no sequence ownership created", await model.activeSequenceID == nil)
            let (reopened, _) = await makeModel(h: h, capability: capability(), preferences: preferences)
            r.equal("new model restores JPEG choice", await reopened.effectiveCaptureFileFormat, .jpeg)
            await model.selectCaptureFormat(.bayerDNG)
            r.equal("RAW chip restored", await model.captureFormatLabel, "RAW")
            r.equal("armed bracket returns only in RAW", await model.activeShutterMode, .exposureBracket)
            r.equal("RAW persistence restored", preferences.loadPreferredCaptureFormat(), .bayerDNG)
            await model.stop(); await reopened.stop()
        },
        TCCase(id: "JF51A", title: "RAW and JPEG support are independent and front HEIF never masquerades as either") { r in
            guard let h = await StorageHarness.make(name: "format51-availability") else { r.check("fixture", false); return }
            let (rawOnly, _) = await makeModel(h: h, capability: capability(jpeg: false))
            await rawOnly.selectCaptureFormat(.jpeg)
            r.equal("unsupported JPEG cannot change choice", await rawOnly.effectiveCaptureFileFormat, .bayerDNG)
            let (processed, _) = await makeModel(h: h, capability: capability(raw: false))
            r.check("RAW shutter closed on JPEG-only graph", !(await processed.isShutterEnabled))
            await processed.selectCaptureFormat(.jpeg)
            r.check("explicit JPEG admits supported processed graph", await processed.isShutterEnabled)
            await processed.selectCaptureFormat(.bayerDNG)
            r.equal("unavailable Bayer is not an enabled choice", await processed.effectiveCaptureFileFormat, .jpeg)
            r.equal("readiness carries explicit chosen format", await processed.readinessInputs.fileFormat, .jpeg)
            let (front, _) = await makeModel(h: h, capability: capability(kind: .front, raw: false, heif: true))
            r.equal("legacy front fallback clearly distinct", await front.captureFormatLabel, "HEIF · Front")
            await front.selectCaptureFormat(.jpeg)
            r.equal("JPEG is explicit on front too", await front.captureFormatLabel, "JPEG")
            await front.selectCaptureFormat(.bayerDNG)
            r.equal("RAW stays unavailable on this front fixture", await front.effectiveCaptureFileFormat, .jpeg)
            await front.selectCaptureFormat(.frontHEIF)
            r.equal("legacy HEIF can be explicitly restored", await front.effectiveCaptureFileFormat, .frontHEIF)
            await rawOnly.stop(); await processed.stop(); await front.stop()
        },
        TCCase(id: "JF51F", title: "A submitted JPEG freezes its own ceiling and container while format changes stay closed") { r in
            guard let h = await StorageHarness.make(name: "format51-frozen") else { r.check("fixture", false); return }
            let native = ChainCameraSpy(); native.holdAttachments()
            let (model, _) = await makeModel(h: h, capability: capability(), native: native)
            await model.selectCaptureFormat(.jpeg)
            let request = Task { await model.activateShutter() }
            var deadline = ContinuousClock.now.advanced(by: .seconds(3))
            while native.attachArrivals == 0, ContinuousClock.now < deadline { await Task.yield() }
            r.check("JPEG really reaches native boundary", native.attachArrivals > 0)
            r.check("selector closed during actual capture", !(await model.isCaptureFormatSelectionEnabled))
            await model.selectCaptureFormat(.bayerDNG)
            r.equal("busy change rejected", await model.effectiveCaptureFileFormat, .jpeg)
            native.releaseAttachments()
            deadline = ContinuousClock.now.advanced(by: .seconds(3))
            while native.lastCreatedTicket == nil, ContinuousClock.now < deadline { await Task.yield() }
            if let ticket = native.lastCreatedTicket {
                r.equal("submitted container is JPEG", ticket.request.intent.fileFormat, .jpeg)
                r.equal("JPEG uses its verified output ceiling", ticket.request.intent.requestedDimensions, PixelDimensions(width: 8000, height: 6000))
                r.equal("ordinary path submits no sequence", ticket.request.intent.sequenceID, nil)
                ticket.deliver(.failed(CaptureFailure(kind: .captureFailed(detail: "Test terminal without any image"), operation: "test.format51")))
            } else { r.check("native ticket exists", false); request.cancel() }
            await request.value
            r.equal("failed fixture never claims Saved", await model.lastCommittedReceipts.count, 0)
            await model.stop()
        },
        TCCase(id: "JF51G", title: "Format selection cannot change during a timer, covering sheet, lens switch or genuine interruption") { r in
            guard let h = await StorageHarness.make(name: "format51-gates") else { r.check("fixture", false); return }
            let (model, service) = await makeModel(h: h, capability: capability())
            await model.startTimerCountdown(seconds: 10)
            await model.selectCaptureFormat(.jpeg)
            r.equal("countdown keeps frozen format choice", await model.effectiveCaptureFileFormat, .bayerDNG)
            await model.cancelTimer()
            await MainActor.run { model.isToolsSheetPresented = true }
            await model.selectCaptureFormat(.jpeg)
            r.equal("covered control is ineligible", await model.effectiveCaptureFileFormat, .bayerDNG)
            await MainActor.run { model.isToolsSheetPresented = false }
            await service.holdSwitch()
            let change = Task { await model.selectLens(.ultraWide) }
            let deadline = ContinuousClock.now.advanced(by: .seconds(3))
            while !(await model.isSwitchingLens), ContinuousClock.now < deadline { await Task.yield() }
            r.check("switch is held", await model.isSwitchingLens)
            await model.selectCaptureFormat(.jpeg)
            r.equal("switch rejects change", await model.effectiveCaptureFileFormat, .bayerDNG)
            await service.releaseSwitch(); await change.value
            await model.applyServiceCondition(.interrupted(reason: "Synthetic genuine interruption"))
            await model.selectCaptureFormat(.jpeg)
            r.equal("native interruption rejects change", await model.effectiveCaptureFileFormat, .bayerDNG)
            await model.stop()
        }
    ])
}
