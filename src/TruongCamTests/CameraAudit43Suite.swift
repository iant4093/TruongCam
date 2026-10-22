import Foundation
import Synchronization
#if canImport(XCTest)
@testable import TruongCam
#endif

/// Injected event source uses the same asynchronous callback boundary as the
/// real process monitor; tests never change system thermal/power/memory state.
final class CameraAudit43ResourceSource: CameraResourcePressureMonitoring, @unchecked Sendable {
    private let state = Mutex<(callback: (@Sendable (CameraResourcePressureSnapshot) -> Void)?, starts: Int, stops: Int)>((nil, 0, 0))
    var starts: Int { state.withLock { $0.starts } }
    var stops: Int { state.withLock { $0.stops } }
    func start(onChange: @escaping @Sendable (CameraResourcePressureSnapshot) -> Void) {
        state.withLock { $0.callback = onChange; $0.starts += 1 }
    }
    func stop() { state.withLock { $0.callback = nil; $0.stops += 1 } }
    func emit(_ snapshot: CameraResourcePressureSnapshot) { state.withLock { $0.callback }?(snapshot) }
}

/// Executes shipping model/admission/drain code over synthetic camera/storage
/// boundaries. No physical autofocus, native photo or phone latency is inferred.
enum CameraAudit43Suite {
    static func waitUntil(_ predicate: @escaping @Sendable () async -> Bool) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while !(await predicate()), ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(2)) }
        return await predicate()
    }
    static let suite = TCSuite(id: "CameraAudit43", title: "Owned focus, preview-only loupe and bounded capture bookkeeping", cases: [
        TCCase(id: "CA43F", title: "Focus taps use owned controls and reject stale, modal, manual and ineligible input") { r in
            guard let h = await StorageHarness.make(name: "ca43-focus") else { r.check("fixture", false); return }
            let service = SyntheticCameraService(capability: StartupRepairSuite.controlFixture(modes: [.auto, .manual]))
            let model = await CameraViewModel(camera: service,
                capture: CaptureCoordinator(camera: ChainCameraSpy(), store: h.store, clock: SystemMonotonicClock()),
                metering: MeteringService(clock: SystemMonotonicClock()), preferences: SyntheticPreferenceStore(), levelFeed: SyntheticLevelFeed())
            await model.start()
            let rect = TCRect(x: 0, y: 0, width: 100, height: 100)
            let mapper = await model.previewGeometryMapper(fallbackContentRect: rect)
            let before = await service.controlApplyCount
            r.check("ready focus gesture eligible", await model.canAdjustFocusPoint)
            await model.handleFocusTap(atViewPoint: TCPoint(x: 25, y: 50), mapper: mapper)
            r.check("tap reaches normal application", await waitUntil { await service.controlApplyCount == before + 1 })
            r.equal("desired point preserved", await model.focus.pointOfInterest, NormalizedDevicePoint(x: 0.25, y: 0.5))
            let revision = await model.lastAppliedRequestRevision
            r.check("tap owns a newer control revision", revision > 0)
            let staleMapper = PreviewGeometryMapper(imageDimensions: mapper.imageDimensions,
                contentRect: rect, isMirrored: !mapper.isMirrored, rotationDegrees: mapper.rotationDegrees)
            await model.handleFocusTap(atViewPoint: TCPoint(x: 75, y: 50), mapper: staleMapper)
            r.equal("stale display transform cannot move focus", await model.focus.pointOfInterest, NormalizedDevicePoint(x: 0.25, y: 0.5))
            await MainActor.run { model.presentedCameraSheet = .tools }
            r.check("modal closes gesture admission", await model.canAdjustFocusPoint == false)
            await model.handleFocusTap(atViewPoint: TCPoint(x: 75, y: 50), mapper: mapper)
            r.equal("modal tap cannot change focus", await model.focus.pointOfInterest, NormalizedDevicePoint(x: 0.25, y: 0.5))
            await MainActor.run { model.presentedCameraSheet = nil; model.setFocusManual(true) }
            r.check("manual focus is never unlocked by tap", await model.canAdjustFocusPoint == false)
            await model.handleFocusTap(atViewPoint: TCPoint(x: 75, y: 50), mapper: mapper)
            r.equal("manual intent remains manual", await model.focus.mode, .manual)
            await model.handleCameraScreenCovered()
            r.check("covered camera refuses focus gesture", await model.canAdjustFocusPoint == false)
        },
        TCCase(id: "CA43L", title: "Loupe inspection changes analysis without native setters or a new capture revision") { r in
            guard let h = await StorageHarness.make(name: "ca43-loupe") else { r.check("fixture", false); return }
            let service = SyntheticCameraService(capability: StartupRepairSuite.controlFixture(modes: [.auto, .manual]))
            let model = await CameraViewModel(camera: service,
                capture: CaptureCoordinator(camera: ChainCameraSpy(), store: h.store, clock: SystemMonotonicClock()),
                metering: MeteringService(clock: SystemMonotonicClock()), preferences: SyntheticPreferenceStore(), levelFeed: SyntheticLevelFeed())
            await model.start()
            let calls = await service.controlApplyCount, revision = await model.lastAppliedRequestRevision
            let requests = await service.analysisRequests.count
            await MainActor.run {
                model.composition.loupeEnabled = true
                for i in 1...20 { model.setLoupeCenter(NormalizedDevicePoint(x: Double(i) / 20, y: 0.4)) }
            }
            r.check("analysis receives inspection demand", await waitUntil { await service.analysisRequests.count > requests })
            try? await Task.sleep(for: .milliseconds(90))
            r.equal("pan performs no camera control application", await service.controlApplyCount, calls)
            r.equal("pan preserves capture request revision", await model.lastAppliedRequestRevision, revision)
            r.equal("latest inspection point retained", await model.activeLoupeCenter, NormalizedDevicePoint(x: 1, y: 0.4))
            await model.handleCameraScreenCovered()
        },
        TCCase(id: "CA43A", title: "Queued old sensor/layout histogram and loupe outputs cannot replace current display") { r in
            guard let h = await StorageHarness.make(name: "ca43-analysis") else { r.check("fixture", false); return }
            let model = await CameraViewModel(camera: SyntheticCameraService(capability: StartupRepairSuite.controlFixture(modes: [.auto])),
                capture: CaptureCoordinator(camera: ChainCameraSpy(), store: h.store, clock: SystemMonotonicClock()),
                metering: MeteringService(clock: SystemMonotonicClock()), preferences: SyntheticPreferenceStore(), levelFeed: SyntheticLevelFeed())
            await model.start()
            let geometry = PreviewGeometrySnapshot(configurationGeneration: .zero, layoutGeneration: 7,
                imageDimensions: PixelDimensions(width: 4, height: 3), cleanApertureDimensions: nil,
                previewLayerContentRect: TCRect(x: 0, y: 0, width: 100, height: 100), bufferOrientation: 1,
                isMirrored: false, analysisRotationDegrees: 0, isVideoMirrored: false, capturedAtUTC: Date())
            await model.updateGeometry(geometry)
            func histogram(_ generation: ConfigurationGeneration, _ layout: UInt64, _ count: UInt32) -> HistogramSnapshot {
                HistogramSnapshot(bins: Array(repeating: count, count: 256), sampleCount: count,
                    geometryGeneration: layout, configurationGeneration: generation, isFullRange: true, mappedAtUTC: Date())
            }
            func loupe(_ generation: ConfigurationGeneration, _ layout: UInt64, _ color: UInt8) -> LoupeSnapshot {
                LoupeSnapshot(width: 1, height: 1, rgbaBytes: [color, 0, 0, 255], geometryGeneration: layout,
                    configurationGeneration: generation, magnification: 2, mappedAtUTC: Date())
            }
            await model.consumeAnalysisOutput(.histogram(histogram(.zero, 7, 1)))
            await model.consumeAnalysisOutput(.loupe(loupe(.zero, 7, 1)))
            r.equal("current histogram accepted", await model.histogram?.sampleCount, 1)
            r.equal("current loupe accepted", await model.loupe?.rgbaBytes.first, 1)
            await model.consumeAnalysisOutput(.histogram(histogram(ConfigurationGeneration(1), 7, 2)))
            await model.consumeAnalysisOutput(.loupe(loupe(.zero, 8, 2)))
            r.equal("foreign sensor histogram ignored", await model.histogram?.sampleCount, 1)
            r.equal("foreign layout loupe ignored", await model.loupe?.rgbaBytes.first, 1)
            await model.handleCameraScreenCovered()
            await model.consumeAnalysisOutput(.histogram(histogram(.zero, 7, 3)))
            await model.consumeAnalysisOutput(.loupe(loupe(.zero, 7, 3)))
            r.equal("inactive output cannot overwrite histogram", await model.histogram?.sampleCount, 1)
            r.equal("inactive output cannot overwrite loupe", await model.loupe?.rgbaBytes.first, 1)
        },
        TCCase(id: "CA43P", title: "Real resource-source events reduce and restore only optional analysis without unchanged native demand") { r in
            guard let h = await StorageHarness.make(name: "ca43-pressure") else { r.check("fixture", false); return }
            let service = SyntheticCameraService(capability: StartupRepairSuite.controlFixture(modes: [.auto, .manual]))
            let source = CameraAudit43ResourceSource(), meter = MeteringService(clock: SystemMonotonicClock())
            let model = await CameraViewModel(camera: service,
                capture: CaptureCoordinator(camera: ChainCameraSpy(), store: h.store, clock: SystemMonotonicClock()),
                metering: meter, preferences: SyntheticPreferenceStore(), levelFeed: SyntheticLevelFeed(), resourceMonitor: source)
            await model.start()
            await MainActor.run { model.composition.peakingEnabled = true; model.composition.loupeEnabled = true }
            await model.updateAnalysisDemand()
            let demandCount = await service.analysisDemands.count, controls = await service.controlApplyCount
            r.equal("source has one lifecycle registration", source.starts, 1)
            source.emit(CameraResourcePressureSnapshot(isLowPowerMode: true, revision: 1))
            r.check("Low Power event reaches existing rate policy", await waitUntil { await meter.currentRateLimits.histogramHz == 5 })
            r.equal("rate-only event skips native demand", await service.analysisDemands.count, demandCount)
            source.emit(CameraResourcePressureSnapshot(isLowPowerMode: true, revision: 1))
            try? await Task.sleep(for: .milliseconds(15))
            r.equal("duplicate event cannot reconfigure output", await service.analysisDemands.count, demandCount)
            source.emit(CameraResourcePressureSnapshot(memory: .critical, revision: 2))
            r.check("genuine critical-memory signal updates rates", await waitUntil {
                let pressure = await model.resourcePressureSnapshot.memory, hz = await meter.currentRateLimits.histogramHz
                return pressure == .critical && hz == 5
            })
            source.emit(CameraResourcePressureSnapshot(revision: 3))
            r.check("actual normal event clears pressure", await waitUntil { await meter.currentRateLimits == .nominal })
            r.equal("normal rate restoration skips unchanged native demand", await service.analysisDemands.count, demandCount)
            source.emit(CameraResourcePressureSnapshot(thermal: .critical, revision: 4))
            r.check("critical thermal pauses expensive aids visibly and reduces rates", await waitUntil {
                let paused = await model.pausedAids.count, hz = await meter.currentRateLimits.histogramHz
                return paused == 2 && hz == 2.5
            })
            r.equal("native camera controls are independent of pressure", await service.controlApplyCount, controls)
            source.emit(CameraResourcePressureSnapshot(revision: 5))
            r.check("thermal recovery restores selected aids", await waitUntil {
                let paused = await model.pausedAids.isEmpty, rates = await meter.currentRateLimits
                return paused && rates == .nominal
            })
            await model.handleCameraScreenCovered()
            let coveredDemands = await service.analysisDemands.count
            source.emit(CameraResourcePressureSnapshot(memory: .elevated, revision: 6))
            r.check("covered model retains newest real pressure", await waitUntil { await model.resourcePressureSnapshot.revision == 6 })
            r.equal("covered event cannot restart native analysis", await service.analysisDemands.count, coveredDemands)
            source.emit(CameraResourcePressureSnapshot(revision: 5))
            try? await Task.sleep(for: .milliseconds(15))
            r.equal("late old normal cannot clear warning", await model.resourcePressureSnapshot.memory, .elevated)
            await model.handleCameraScreenRevealed()
            r.equal("reveal uses retained actual warning", await meter.currentRateLimits.histogramHz, 5)
            source.emit(CameraResourcePressureSnapshot(revision: 7))
            r.check("actual clear resumes nominal rates", await waitUntil { await meter.currentRateLimits == .nominal })
            source.stop()
            source.emit(CameraResourcePressureSnapshot(thermal: .critical, revision: 8))
            try? await Task.sleep(for: .milliseconds(15))
            r.equal("stopped source cannot deliver events", await model.resourcePressureSnapshot.revision, 7)
            await model.handleCameraScreenCovered()

            // Rejected ordinary callbacks must not revoke the real startup
            // owner's update while its acknowledged native demand is suspended.
            let ownedService = SyntheticCameraService(capability: StartupRepairSuite.controlFixture(modes: [.auto]))
            let ownedHold = PrepareHold(), ownedMeter = MeteringService(clock: SystemMonotonicClock())
            await ownedService.holdAnalysisDemand(atCall: 2, hold: ownedHold)
            let ownedModel = await CameraViewModel(camera: ownedService,
                capture: CaptureCoordinator(camera: ChainCameraSpy(), store: h.store, clock: SystemMonotonicClock()),
                metering: ownedMeter, preferences: SyntheticPreferenceStore(), levelFeed: SyntheticLevelFeed())
            let ownedStart = Task { await ownedModel.start() }
            r.check("owned analysis reaches the held native boundary", await waitUntil { await ownedHold.didEnter })
            await ownedModel.updateAnalysisDemand()
            await ownedHold.release()
            await ownedStart.value
            r.equal("rejected callback preserves startup analysis publication", await ownedService.analysisRequests.count, 1)
            await ownedModel.handleCameraScreenCovered()

            // A real event during that same suspension changes policy input;
            // it is reconciled after startup releases ownership, without waiting
            // for a later user gesture or a fabricated normal event.
            let heldService = SyntheticCameraService(capability: StartupRepairSuite.controlFixture(modes: [.auto]))
            let pressureHold = PrepareHold(), pressureMeter = MeteringService(clock: SystemMonotonicClock())
            let heldSource = CameraAudit43ResourceSource()
            await heldService.holdAnalysisDemand(atCall: 2, hold: pressureHold)
            let heldModel = await CameraViewModel(camera: heldService,
                capture: CaptureCoordinator(camera: ChainCameraSpy(), store: h.store, clock: SystemMonotonicClock()),
                metering: pressureMeter, preferences: SyntheticPreferenceStore(), levelFeed: SyntheticLevelFeed(), resourceMonitor: heldSource)
            let pressureStart = Task { await heldModel.start() }
            r.check("pressure startup reaches held native boundary", await waitUntil { await pressureHold.didEnter })
            heldSource.emit(CameraResourcePressureSnapshot(isLowPowerMode: true, revision: 1))
            r.check("resource event retained under owned start", await waitUntil { await heldModel.resourcePressureSnapshot.revision == 1 })
            await pressureHold.release()
            await pressureStart.value
            r.check("retained start event reconciles without a new UI callback", await waitUntil { await pressureMeter.currentRateLimits.histogramHz == 5 })
            r.check("reconciliation publishes the current analysis request", await heldService.analysisRequests.count > 0)
            await heldModel.handleCameraScreenCovered()
        },
        TCCase(id: "CA43H", title: "Commit must reconfirm exact pending ownership after retained or missing staging") { r in
            for removeBeforeCommit in [false, true] {
                guard let h = await StorageHarness.make(name: "ca43-retention-" + String(removeBeforeCommit)) else {
                    r.check("fixture", false); continue
                }
                let captureID = CaptureID()
                let intent = CaptureIntent(captureID: captureID, libraryID: h.libraryID,
                    requestedDimensions: PixelDimensions(width: 4032, height: 3024), exposure: .auto, biasEV: 0,
                    focus: FocusIntent(mode: .continuousAuto, position: nil, pointOfInterest: nil),
                    whiteBalance: WhiteBalanceIntent(mode: .auto, temperatureAndTint: nil),
                    configurationGeneration: .zero, rootGeneration: h.generation, physicalCameraKind: .wide,
                    createdAtUTC: StorageFixture.fixedDate, timezoneOffsetSeconds: 0, mode: .single)
                let removed = Mutex(0)
                if removeBeforeCommit {
                    // Runs after actual sidecar publication, the final staging
                    // operation, but before stageSource returns its old handle.
                    // The commit therefore observes a genuinely absent copy.
                    h.fault.setObserver { event in
                        guard event.kind == .move,
                              event.destinationRelativePath == "PendingCaptures/\(captureID.description)/sidecar.json" else { return }
                        do {
                            try h.memory.removeItem(at: h.pendingSourceURL(for: captureID))
                            removed.withLock { $0 += 1 }
                        } catch { }
                    }
                } else {
                    h.fault.armMove(destinationSuffix: h.finalURL(for: captureID).lastPathComponent)
                }
                let ticket = ChainCameraTicket(captureID: captureID, intent: intent)
                r.check("synthetic native owner accepts delivered source", ticket.deliverRepresentation(
                    bytes: StorageFixture.rawBytes(), dimensions: intent.requestedDimensions))
                ticket.deliver(.success)
                let coordinator = CaptureCoordinator(camera: ChainCameraSpy(), store: h.store, clock: SystemMonotonicClock())
                // Shipping request drain, real store/staging/commit and adapter;
                // only the native callback and filesystem fault are synthetic.
                let result = await coordinator.drain(ticket: ticket, intent: intent)
                h.fault.setObserver(nil)
                let mapped = CaptureSequenceExecutor.executionResult(for: result, intent: intent)
                r.equal("failed publication has no receipt", result.committedReceipts.count, 0)
                if removeBeforeCommit {
                    r.equal("actual staged file removed before commit", removed.withLock { $0 }, 1)
                    r.check("staging bytes actually absent", !h.memory.fileExists(at: h.pendingSourceURL(for: captureID)))
                    r.equal("missing bytes transfer no pending transaction", result.pendingTransactionIDs.count, 0)
                    r.equal("missing bytes transfer no stale stage handle", result.pendingHandles.count, 0)
                    r.check("native success cannot imply retained bytes", !result.didRetainAnything)
                    if case .failed(let failure) = result.acquisition {
                        r.equal("reconciled failure has no invented in-memory bytes", failure.retainedSourceStatus, .none)
                    } else { r.check("missing bytes fail acquisition reconciliation", false) }
                    r.check("adapter cannot claim missing bytes durable", !mapped.persistence.isDurablyStaged && mapped.stagedHandle == nil)
                    r.check("actual commit reports missing recovery copy", result.failures.contains {
                        $0.operation == "commit" && $0.retainedSourceStatus == .none
                    })
                } else {
                    r.equal("provider publication fault actually fired", h.fault.injectedFailureCount, 1)
                    r.check("internal original remains after provider failure", h.memory.fileExists(at: h.pendingSourceURL(for: captureID)))
                    r.equal("one actual pending source", result.pendingHandles.count, 1)
                    if case .partial(let count, _) = result.acquisition {
                        r.equal("native terminal reconciles only proven durable source", count, 1)
                    } else { r.check("provider failure is partial with retained source", false) }
                    r.equal("pending transaction belongs to returned source", result.pendingTransactionIDs, result.pendingHandles.map(\.transactionID))
                    r.check("adapter retains the exact proven source", mapped.persistence.isDurablyStaged && mapped.stagedHandle == result.pendingHandles.first)
                    if let handle = mapped.stagedHandle {
                        r.equal("fresh failure reports exact retained path", result.failures.first?.retainedSourceStatus,
                            .durableInternalStaging(relativePath: handle.pendingRelativePath))
                        r.equal("staged bytes remain unchanged", h.memory.fileBytes(at: h.pendingSourceURL(for: captureID)), StorageFixture.rawBytes())
                    }
                }
            }
        },
        TCCase(id: "CA43R", title: "Rejected and cancelled pre-submission requests release only their readback bookkeeping") { r in
            guard let h = await StorageHarness.make(name: "ca43-bookkeeping") else { r.check("fixture", false); return }
            let spy = ChainCameraSpy(), capture = CaptureCoordinator(camera: ChainCameraSpy(), store: h.store, clock: SystemMonotonicClock())
            let reading = try? await spy.applyControls(revision: 0, exposure: .auto, biasEV: 0,
                focus: FocusIntent(mode: .continuousAuto, position: nil, pointOfInterest: nil),
                whiteBalance: WhiteBalanceIntent(mode: .auto, temperatureAndTint: nil)).get()
            await capture.stopAdmittingNewRequests()
            for _ in 0..<32 {
                let intent = ChainCameraSpy.defaultIntent(captureID: CaptureID())
                await capture.noteReadback(reading, for: intent.captureID)
                let result = await capture.capture(intent: intent)
                r.check("refused request retained no original", !result.didRetainAnything)
            }
            r.equal("refused requests release sampled readings", await capture.retainedReadbackCount, 0)
            r.equal("refused requests release verified readings", await capture.retainedVerifiedSnapshotCount, 0)
            let hold = PrepareHold(), intent = ChainCameraSpy.defaultIntent(captureID: CaptureID())
            let task = Task {
                await hold.wait()
                await capture.noteReadback(reading, for: intent.captureID)
                return await capture.capture(intent: intent)
            }
            await hold.waitUntilEntered(); task.cancel(); await hold.release()
            let cancelled = await task.value
            r.check("pre-entry cancellation submits no original", !cancelled.didRetainAnything)
            r.equal("cancelled request releases sampled reading", await capture.retainedReadbackCount, 0)
            r.equal("cancelled request releases verified reading", await capture.retainedVerifiedSnapshotCount, 0)
        }
    ])
}
