import CoreGraphics
import Foundation
import ImageIO
import Synchronization
#if canImport(XCTest)
@testable import TruongCam
#endif

/// Isolated remembered drive settings. No shared defaults or actual camera,
/// user library or Photos operation is involved in these shipping-model tests.
private final class Speed54Preferences: PreferenceStoring, @unchecked Sendable {
    private struct State {
        var speed: CaptureSpeed = .single
        var composition = CompositionPreferences()
        var sequence = SequencePlanPreferences()
        var format: CaptureFileFormat = .bayerDNG
    }
    private let value: Mutex<State>
    init(speed: CaptureSpeed = .single, timer: Int = 0, mode: SequenceShutterMode = .single) {
        var state = State(); state.speed = speed; state.composition.timerSeconds = timer; state.sequence.shutterMode = mode
        value = Mutex(state)
    }
    func loadCompositionPreferences() -> CompositionPreferences? { value.withLock { $0.composition } }
    func storeCompositionPreferences(_ preferences: CompositionPreferences) { value.withLock { $0.composition = preferences } }
    func loadSequencePreferences() -> SequencePlanPreferences? { value.withLock { $0.sequence } }
    func storeSequencePreferences(_ preferences: SequencePlanPreferences) { value.withLock { $0.sequence = preferences } }
    func loadPreferredCaptureFormat() -> CaptureFileFormat { value.withLock { $0.format } }
    func storePreferredCaptureFormat(_ format: CaptureFileFormat) { value.withLock { $0.format = format } }
    func loadCaptureSpeed() -> CaptureSpeed { value.withLock { $0.speed } }
    func storeCaptureSpeed(_ speed: CaptureSpeed) { value.withLock { $0.speed = speed } }
}

enum CaptureSpeedSuite {
    private static let failure = CaptureFailure(kind: .captureFailed(detail: "Synthetic drive-test terminal without a source"), operation: "test.drive54")
    private static func waitUntil(_ condition: @Sendable () async -> Bool) async -> Bool {
        for _ in 0..<1500 {
            if await condition() { return true }
            try? await Task.sleep(for: .milliseconds(2))
        }
        return false
    }
    /// Every reached native request is retired even after a failed assertion.
    /// Admission stops first; no cancellation is sent into owned save work.
    private static func retire(_ model: CameraViewModel, native: ChainCameraSpy) async {
        await model.stopContinuousCapture()
        native.releaseAttachments()
        _ = await waitUntil {
            if let ticket = native.lastCreatedTicket, ticket.currentTerminal() == nil { ticket.deliver(.failed(failure)) }
            let active = await model.isContinuousCaptureActive
            let capturing = await model.isCapturing
            return !active && !capturing
        }
        await model.stop()
    }
    private static func deliver(_ ticket: ChainCameraTicket, filler: UInt8 = 0x54) -> Bool {
        let accepted = ticket.deliverRepresentation(bytes: StorageFixture.rawBytes(filler: filler),
            dimensions: PixelDimensions(width: 4000, height: 3000))
        ticket.deliver(.success)
        return accepted
    }
    private static func ticket(_ native: ChainCameraSpy, after count: Int) async -> ChainCameraTicket? {
        guard await waitUntil({ native.attachCount > count && native.lastCreatedTicket != nil }) else { return nil }
        return native.lastCreatedTicket
    }
    private static func assertReceipt(_ r: TCRecorder, model: CameraViewModel, h: StorageHarness,
                                      id: CaptureID, bytes: Data) async {
        let receipts = await model.lastCommittedReceipts
        guard let receipt = receipts.first(where: { $0.captureID == id }) else { r.check("verified receipt for requested identity", false); return }
        r.equal("verified original byte count", receipt.verifiedByteCount, Int64(bytes.count))
        r.equal("verified original digest", receipt.verifiedSHA256.hex, StorageFixture.sha256Hex(bytes))
        r.equal("published original is byte-identical", h.memory.fileBytes(at: h.root.appendingPathComponent(receipt.relativeOriginalPath)), bytes)
    }
    private static func jpegBytes() throws -> Data {
        guard let context = CGContext(data: nil, width: 32, height: 24, bitsPerComponent: 8, bytesPerRow: 128,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue),
              let image = context.makeImage() else { throw CocoaError(.fileWriteUnknown) }
        let bytes = NSMutableData()
        guard let output = CGImageDestinationCreateWithData(bytes, "public.jpeg" as CFString, 1, nil) else { throw CocoaError(.fileWriteUnknown) }
        CGImageDestinationAddImage(output, image, nil)
        guard CGImageDestinationFinalize(output) else { throw CocoaError(.fileWriteUnknown) }
        return bytes as Data
    }

    static let suite = TCSuite(id: "CaptureSpeed54", title: "Owned hold-to-shoot cadence and verified serial saving", cases: [
        TCCase(id: "DS54P", title: "Single is the default and remembered drive speed stays exclusive with timer and RAW sequences") { r in
            guard let h = await StorageHarness.make(name: "drive54-preferences") else { r.check("fixture", false); return }
            let p = Speed54Preferences()
            let (model, _) = await CaptureFormatUISuite.makeModel(h: h, capability: CaptureFormatUISuite.capability(), preferences: p)
            r.equal("fresh install remains one photo per press", await model.captureSpeed, .single)
            await model.setCaptureSpeed(.fps5)
            r.equal("drive speed persists", p.loadCaptureSpeed(), .fps5)
            let (reopened, _) = await CaptureFormatUISuite.makeModel(h: h, capability: CaptureFormatUISuite.capability(), preferences: p)
            r.equal("reopened model restores speed", await reopened.captureSpeed, .fps5)
            await model.setTimerSeconds(3)
            r.equal("arming timer selects Single", await model.captureSpeed, .single)
            await model.setCaptureSpeed(.fps2)
            r.equal("drive clears timer", await model.timerSeconds, nil)
            await model.setExposureBracketEnabled(true)
            r.equal("arming bracket selects Single", await model.captureSpeed, .single)
            await model.setCaptureSpeed(.fps1)
            r.equal("drive clears sequence shutter mode", await model.activeShutterMode, .single)
            await model.stop(); await reopened.stop()
            for timer in [true, false] {
                let incompatible = Speed54Preferences(speed: .fps5, timer: timer ? 3 : 0, mode: timer ? .single : .focusBracket)
                let (restored, _) = await CaptureFormatUISuite.makeModel(h: h, capability: CaptureFormatUISuite.capability(), preferences: incompatible)
                r.equal("incompatible persisted timer or bracket wins on launch", await restored.captureSpeed, .single)
                r.equal("incompatible drive preference repaired", incompatible.loadCaptureSpeed(), .single)
                await restored.stop()
            }
            r.close("one-fps target", CaptureSpeed.fps1.nextStart(after: 10, finishedAt: 10.2) ?? -1, 11)
            r.close("two-fps target", CaptureSpeed.fps2.nextStart(after: 10, finishedAt: 10.2) ?? -1, 10.5)
            r.close("five-fps target", CaptureSpeed.fps5.nextStart(after: 10, finishedAt: 10.1) ?? -1, 10.2)
            r.close("slow save never queues missed slots", CaptureSpeed.fps5.nextStart(after: 10, finishedAt: 12) ?? -1, 12)
            r.equal("Single has no repeat deadline", CaptureSpeed.single.nextStart(after: 10, finishedAt: 10), nil)
            r.equal("invalid clock cannot spin a repeat loop", CaptureSpeed.fps5.nextStart(after: .nan, finishedAt: 10), nil)
        },
        TCCase(id: "DS54Q", title: "A quick release preserves exactly its first original while cancellation before task admission takes none") { r in
            guard let h = await StorageHarness.make(name: "drive54-quick") else { r.check("fixture", false); return }
            let native = ChainCameraSpy()
            let (model, _) = await CaptureFormatUISuite.makeModel(h: h, capability: CaptureFormatUISuite.capability(), native: native)
            let id = UUID()
            let accepted = await MainActor.run {
                model.setCaptureSpeed(.fps5)
                let accepted = model.beginShutterHold(id: id)
                model.endShutterHold(id: id)
                return accepted
            }
            r.check("quick press admitted", accepted)
            if let first = await ticket(native, after: 0) {
                r.check("first owned source delivered", deliver(first))
                r.check("quick press reaches terminal", await waitUntil { !(await model.isContinuousCaptureActive) })
                r.equal("one verified original", await model.continuousCapturedCount, 1)
                await assertReceipt(r, model: model, h: h, id: first.captureID, bytes: StorageFixture.rawBytes(filler: 0x54))
            } else { r.check("first ticket", false) }
            let before = native.attachCount
            await MainActor.run {
                let cancel = UUID()
                _ = model.beginShutterHold(id: cancel)
                model.cancelShutterHold(id: cancel)
            }
            r.check("cancelled press finishes", await waitUntil { !(await model.isContinuousCaptureActive) })
            r.equal("cancel before first has zero native requests", native.attachCount, before)
            await retire(model, native: native)
        },
        TCCase(id: "DS54D", title: "Release during an owned native request drains verified persistence and cannot schedule another frame") { r in
            guard let h = await StorageHarness.make(name: "drive54-drain") else { r.check("fixture", false); return }
            let native = ChainCameraSpy(); native.holdAttachments()
            let (model, _) = await CaptureFormatUISuite.makeModel(h: h, capability: CaptureFormatUISuite.capability(), native: native)
            let id = UUID()
            await model.setCaptureSpeed(.fps5)
            r.check("hold admitted", await model.beginShutterHold(id: id))
            r.check("native request really entered", await waitUntil { native.attachArrivals == 1 })
            await model.endShutterHold(id: id)
            r.check("release does not discard an owned request", await model.isContinuousCaptureActive)
            r.check("release clears only held input", !(await model.isContinuousCaptureHeld))
            native.releaseAttachments()
            if let first = await ticket(native, after: 0) {
                r.check("owned bytes survive release", deliver(first, filler: 0x65))
                r.check("drained hold finishes", await waitUntil { !(await model.isContinuousCaptureActive) })
                r.equal("release stops repeats", native.attachCount, 1)
                r.equal("verified count follows commit", await model.continuousCapturedCount, 1)
                await assertReceipt(r, model: model, h: h, id: first.captureID, bytes: StorageFixture.rawBytes(filler: 0x65))
            } else { r.check("released native ticket", false) }
            await retire(model, native: native)
        },
        TCCase(id: "DS54R", title: "Held shooting verifies one save before the next request and stale input IDs cannot release a newer hold") { r in
            guard let h = await StorageHarness.make(name: "drive54-repeat") else { r.check("fixture", false); return }
            let native = ChainCameraSpy()
            let (model, _) = await CaptureFormatUISuite.makeModel(h: h, capability: CaptureFormatUISuite.capability(), native: native)
            await model.setCaptureSpeed(.fps5)
            let old = UUID(), id = UUID()
            await MainActor.run {
                _ = model.beginShutterHold(id: old); model.cancelShutterHold(id: old)
            }
            r.check("old cancelled owner drains", await waitUntil { !(await model.isContinuousCaptureActive) })
            let admitted = await MainActor.run {
                let accepted = model.beginShutterHold(id: id)
                model.endShutterHold(id: old); model.cancelShutterHold(id: old)
                return accepted && model.isContinuousCaptureHeld
            }
            r.check("new hold survives stale input", admitted)
            if let first = await ticket(native, after: 0) {
                try? await Task.sleep(for: .milliseconds(240))
                r.equal("a held terminal cannot build a frame backlog", native.attachCount, 1)
                r.equal("an uncommitted frame is not counted", await model.continuousCapturedCount, 0)
                r.check("first source accepted", deliver(first, filler: 0x31))
                if let second = await ticket(native, after: 1) {
                    r.equal("next request waits for first verified save", await model.continuousCapturedCount, 1)
                    await assertReceipt(r, model: model, h: h, id: first.captureID, bytes: StorageFixture.rawBytes(filler: 0x31))
                    r.notEqual("each request owns a distinct original", second.captureID, first.captureID)
                    await model.endShutterHold(id: id)
                    r.check("second source accepted", deliver(second, filler: 0x32))
                    r.check("released repeated run drains", await waitUntil { !(await model.isContinuousCaptureActive) })
                    r.equal("exactly two saves counted", await model.continuousCapturedCount, 2)
                    r.equal("no post-release third request", native.attachCount, 2)
                    await assertReceipt(r, model: model, h: h, id: second.captureID, bytes: StorageFixture.rawBytes(filler: 0x32))
                } else { r.check("second request after verified save", false) }
            } else { r.check("first request", false) }
            await retire(model, native: native)
        },
        TCCase(id: "DS54F", title: "A native failure or retained commit failure stops held shooting without claiming a save") { r in
            for pending in [false, true] {
                guard let h = await StorageHarness.make(name: "drive54-failure-\(pending)") else { r.check("fixture", false); return }
                let native = ChainCameraSpy()
                let (model, _) = await CaptureFormatUISuite.makeModel(h: h, capability: CaptureFormatUISuite.capability(), native: native)
                await model.setCaptureSpeed(.fps5)
                r.check("failure fixture hold admitted", await model.beginShutterHold(id: UUID()))
                if let first = await ticket(native, after: 0) {
                    if pending {
                        h.fault.armMove(destinationSuffix: "TC_\(first.captureID.description).dng")
                        r.check("source reaches failed provider publication", deliver(first))
                    } else { first.deliver(.failed(failure)) }
                    r.check("failure ends hold admission", await waitUntil { !(await model.isContinuousCaptureActive) })
                    r.equal("failed shot cannot count as verified", await model.continuousCapturedCount, 0)
                    r.equal("failure cannot enqueue a repeat", native.attachCount, 1)
                    r.equal("failure reports no committed receipt", await model.lastCommittedReceipts.count, 0)
                    if pending {
                        r.check("intact failed-save original remains recoverable", await model.pendingOriginalCount > 0)
                        r.check("store retains durable recovery source", !(await h.store.pendingOriginals()).isEmpty)
                    }
                } else { r.check("failure native request", false) }
                await retire(model, native: native)
            }
        },
        TCCase(id: "DS54G", title: "Modal, root, control and camera eligibility changes revoke an unsubmitted hold") { r in
            for change in 0..<5 {
                guard let h = await StorageHarness.make(name: "drive54-gate-\(change)") else { r.check("fixture", false); return }
                let native = ChainCameraSpy()
                let (model, _) = await CaptureFormatUISuite.makeModel(h: h, capability: CaptureFormatUISuite.capability(), native: native)
                await MainActor.run {
                    model.setCaptureSpeed(.fps5)
                    _ = model.beginShutterHold(id: UUID())
                    switch change {
                    case 0: model.isToolsSheetPresented = true
                    case 1: model.updateRootState(.unselected)
                    case 2: model.setBias(1)
                    case 3: model.setTimerSeconds(3)
                    default: model.setExposureBracketEnabled(true)
                    }
                }
                r.check("revoked first request ends", await waitUntil { !(await model.isContinuousCaptureActive) })
                r.equal("revoked unsubmitted hold takes no photo", native.attachCount, 0)
                await retire(model, native: native)
            }
        },
        TCCase(id: "DS54W", title: "Cancellation during an issued interactive-control drain prevents native photo submission") { r in
            for modal in [false, true] {
                guard let h = await StorageHarness.make(name: "drive54-control-await-\(modal)") else { r.check("fixture", false); return }
                let native = ChainCameraSpy()
                let (model, service) = await CaptureFormatUISuite.makeModel(h: h, capability: CaptureFormatUISuite.capability(), native: native)
                await model.setCaptureSpeed(.fps5)
                await service.holdControls()
                let before = await service.controlApplyCount
                await model.setBias(1)
                r.check("interactive setter genuinely issued", await waitUntil { await service.controlApplyCount > before })
                let id = UUID()
                r.check("hold admitted behind issued setter", await model.beginShutterHold(id: id))
                r.check("photo waits for issued control drain", await waitUntil { await model.isCapturing })
                r.equal("no native photo before control acknowledgement", native.attachCount, 0)
                await MainActor.run {
                    if modal { model.isToolsSheetPresented = true }
                    else { model.cancelShutterHold(id: id) }
                }
                await service.releaseControls()
                r.check("cancelled asynchronous owner drains", await waitUntil { !(await model.isContinuousCaptureActive) })
                r.equal("late acknowledgement cannot submit a cancelled photo", native.attachCount, 0)
                r.equal("cancelled pre-native work never claims Saved", await model.continuousCapturedCount, 0)
                await retire(model, native: native)
            }
        },
        TCCase(id: "DS54L", title: "Backgrounding during submitted shooting retains that original and stops future admission") { r in
            guard let h = await StorageHarness.make(name: "drive54-background") else { r.check("fixture", false); return }
            let native = ChainCameraSpy()
            let (model, _) = await CaptureFormatUISuite.makeModel(h: h, capability: CaptureFormatUISuite.capability(), native: native)
            await model.setCaptureSpeed(.fps5)
            r.check("background fixture hold admitted", await model.beginShutterHold(id: UUID()))
            if let first = await ticket(native, after: 0) {
                await model.handleSceneBecameInactive()
                r.check("background closes input hold", !(await model.isContinuousCaptureHeld))
                r.check("already submitted original still delivered", deliver(first, filler: 0x75))
                r.check("background owner drains", await waitUntil { !(await model.isContinuousCaptureActive) })
                r.equal("background cannot take another original", native.attachCount, 1)
                r.equal("submitted save completes in background", await model.continuousCapturedCount, 1)
                await assertReceipt(r, model: model, h: h, id: first.captureID, bytes: StorageFixture.rawBytes(filler: 0x75))
            } else { r.check("submitted background request", false) }
            await retire(model, native: native)
        },
        TCCase(id: "DS54H", title: "Hardware begin/end share quick-press semantics and cancelled hardware presses take no photo") { r in
            guard let h = await StorageHarness.make(name: "drive54-hardware") else { r.check("fixture", false); return }
            let native = ChainCameraSpy()
            let (model, _) = await CaptureFormatUISuite.makeModel(h: h, capability: CaptureFormatUISuite.capability(), native: native)
            await MainActor.run {
                model.setCaptureSpeed(.fps5)
                model.handleHardwareShutter(.began)
                model.handleHardwareShutter(.began, source: .secondary)
                model.handleHardwareShutter(.ended, source: .secondary)
                r.check("other button release preserves primary hold", model.isContinuousCaptureHeld)
                model.handleHardwareShutter(.ended)
            }
            if let first = await ticket(native, after: 0) {
                r.check("hardware first source accepted", deliver(first))
                r.check("hardware quick press drains", await waitUntil { !(await model.isContinuousCaptureActive) })
                r.equal("hardware quick press saves exactly once", await model.continuousCapturedCount, 1)
            } else { r.check("hardware quick press reached capture", false) }
            let before = native.attachCount
            await MainActor.run {
                model.handleHardwareShutter(.began); model.handleHardwareShutter(.cancelled)
            }
            r.check("cancelled hardware press ends", await waitUntil { !(await model.isContinuousCaptureActive) })
            r.equal("hardware cancellation cannot create a photo", native.attachCount, before)
            await retire(model, native: native)
        },
        TCCase(id: "DS54C", title: "Drive shooting preserves explicit JPEG and front HEIF containers through verified saving") { r in
            for front in [false, true] {
                guard let h = await StorageHarness.make(name: "drive54-container-\(front)") else { r.check("fixture", false); return }
                let native = ChainCameraSpy()
                let cap = CaptureFormatUISuite.capability(kind: front ? .front : .wide, raw: !front, heif: front)
                let (model, _) = await CaptureFormatUISuite.makeModel(h: h, capability: cap, native: native)
                if !front { await model.selectCaptureFormat(.jpeg) }
                let expected: CaptureFileFormat = front ? .frontHEIF : .jpeg
                await MainActor.run {
                    model.setCaptureSpeed(.fps2)
                    let id = UUID(); _ = model.beginShutterHold(id: id); model.endShutterHold(id: id)
                }
                if let first = await ticket(native, after: 0) {
                    r.equal("native intent retains explicit processed container", first.request.intent.fileFormat, expected)
                    do {
                        let bytes: Data
                        if front { bytes = try StorageFixture.heifBytes() }
                        else { bytes = try jpegBytes() }
                        r.check("processed source accepted", first.deliverRepresentation(bytes: bytes,
                            dimensions: PixelDimensions(width: 32, height: 24), rawPixelFormatType: 0,
                            rawFileType: front ? "public.heic" : "public.jpeg"))
                        first.deliver(.success)
                        r.check("processed drive request drains", await waitUntil { !(await model.isContinuousCaptureActive) })
                        r.equal("processed original verified once", await model.continuousCapturedCount, 1)
                        await assertReceipt(r, model: model, h: h, id: first.captureID, bytes: bytes)
                        r.equal("no hidden RAW fallback", native.attachCount, 1)
                    } catch { first.deliver(.failed(failure)); r.check("generated processed fixture", false, String(describing: error)) }
                } else { r.check("processed native request", false) }
                await retire(model, native: native)
            }
        }
    ])
}
