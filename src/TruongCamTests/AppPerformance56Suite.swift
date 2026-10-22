import Foundation
#if canImport(XCTest)
@testable import TruongCam
#endif

@MainActor private final class WeakCamera56Fixture {
    var owner: CameraViewModel?
    weak var observed: CameraViewModel?
    let service: SyntheticCameraService
    let meter: MeteringService
    let feed = SyntheticLevelFeed()
    init(h: StorageHarness) {
        service = SyntheticCameraService(capability: CaptureFormatUISuite.capability())
        meter = MeteringService(clock: SystemMonotonicClock())
        let model = CameraViewModel(camera: service,
            capture: CaptureCoordinator(camera: ChainCameraSpy(), store: h.store, clock: SystemMonotonicClock()),
            metering: meter, preferences: SyntheticPreferenceStore(), levelFeed: feed)
        model.updateRootState(.writable(libraryID: h.libraryID, generation: h.generation))
        owner = model; observed = model
    }
    func start() async {
        await owner?.start(); await service.recordCondition(.running)
        owner?.startReadbackObservation(); owner?.startSessionConditionObservation(); owner?.startLevelFeed()
    }
    func release() { owner = nil }
    var released: Bool { observed == nil }
}

enum AppPerformance56Suite {
    private static func staged(_ h: StorageHarness, count: Int) async throws -> [(StagedSourceHandle, Data)] {
        var values: [(StagedSourceHandle, Data)] = []
        for i in 0..<count {
            let bytes = StorageFixture.rawBytes(byteCount: 4096 + i * 53, filler: UInt8(40 + i))
            let handle = try await h.store.stageSource(bytes: bytes,
                metadata: StorageFixture.metadata(captureID: CaptureID(), libraryID: h.libraryID))
            values.append((handle, bytes))
        }
        return values
    }
    private static func waitUntil(_ condition: @Sendable () async -> Bool) async -> Bool {
        for _ in 0..<500 {
            if await condition() { return true }
            try? await Task.sleep(for: .milliseconds(3))
        }
        return false
    }
    private static func geometry(_ generation: ConfigurationGeneration) -> PreviewGeometrySnapshot {
        PreviewGeometrySnapshot(configurationGeneration: generation, layoutGeneration: 56,
            imageDimensions: PixelDimensions(width: 4, height: 3), cleanApertureDimensions: nil,
            previewLayerContentRect: TCRect(x: 0, y: 0, width: 300, height: 400),
            bufferOrientation: 1, isMirrored: false, analysisRotationDegrees: 0, isVideoMirrored: false, capturedAtUTC: Date())
    }
    static let suite = TCSuite(id: "AppPerformance56", title: "Linear pending recovery export and nonretaining restartable camera observers", cases: [
        TCCase(id: "AP56P", title: "One recovery catalog per batch preserves fresh source verification, exact bytes and unique request order") { r in
            guard let h = await StorageHarness.make(name: "ap56-pending-batch") else { r.check("fixture", false); return }
            do {
                let items = try await staged(h, count: 6)
                await h.store.releaseRoot(); h.memory.resetCounters()
                let ids = items.prefix(4).map { $0.0.transactionID }
                let export = try await h.store.preparePendingOriginalExport(transactionIDs: ids + [ids[0], TransactionID()], includeSidecars: true)
                r.equal("one catalog scan rather than one per selected ID", h.memory.scanInvocations, 1)
                r.equal("a repeated request cannot duplicate or collide with its owned copy", export.fileURLs.filter { $0.pathExtension == "dng" }.count, 4)
                r.equal("each selected source has its own optional sidecar", export.fileURLs.filter { $0.pathExtension == "json" }.count, 4)
                r.equal("one unknown ID stays a disclosed omission", export.missingItems.count, 1)
                for (i, item) in items.enumerated() {
                    let source = h.support.appendingPathComponent(item.0.pendingRelativePath)
                    r.equal("one catalog hash plus selected fresh verification \(i)", h.memory.counters(at: source).hashes, i < 4 ? 2 : 1)
                    r.equal("pending source is never removed \(i)", h.memory.counters(at: source).removes, 0)
                    r.equal("pending source is unchanged \(i)", h.memory.fileBytes(at: source), item.1)
                    if i < 4 {
                        let copy = export.fileURLs.first { $0.pathExtension == "dng" && $0.lastPathComponent.contains(item.0.captureID.description) }
                        r.check("recovery copy exists \(i)", copy != nil)
                        if let copy { r.equal("exact verified original \(i)", h.memory.fileBytes(at: copy), item.1) }
                    }
                }
                r.equal("catalog work is linear in pending count", h.memory.totalCounters().hashes, 10)
                await h.store.discardExport(sessionID: export.sessionID)
            } catch { r.check("bounded pending export", false, String(describing: error)) }
        },
        TCCase(id: "AP56I", title: "A changed selected recovery file still refuses the batch and removes only its export scratch") { r in
            guard let h = await StorageHarness.make(name: "ap56-pending-integrity") else { r.check("fixture", false); return }
            do {
                let items = try await staged(h, count: 2)
                let bad = h.support.appendingPathComponent(items[1].0.pendingRelativePath)
                var changed = items[1].1; changed[changed.count - 1] ^= 0xff
                try h.memory.removeItem(at: bad); try h.memory.writeNewFile(at: bad, bytes: changed)
                do {
                    _ = try await h.store.preparePendingOriginalExport(transactionIDs: items.map { $0.0.transactionID }, includeSidecars: false)
                    r.check("corrupt source cannot be exported", false)
                } catch let failure as CaptureFailure {
                    if case .integrityMismatch = failure.kind { r.check("fresh mismatch remains explicit", true) }
                    else { r.check("fresh mismatch remains explicit", false, failure.kind.userDescription) }
                }
                r.equal("earlier intact pending original remains owned", h.memory.fileBytes(at: h.support.appendingPathComponent(items[0].0.pendingRelativePath)), items[0].1)
                r.equal("failed source remains available for explicit recovery", h.memory.fileBytes(at: bad), changed)
                let temp = try h.memory.scan(root: h.temporary, maxEntries: 100, shouldSkipRelativePath: { _ in false }, shouldDescendRelativeDirectory: { _ in true }, onProgress: nil)
                r.check("partial private export copies are removed", temp.allSatisfy { $0.isDirectory })
            } catch { r.check("integrity failure cleanup", false, String(describing: error)) }
        },
        TCCase(id: "AP56J", title: "Journal-less pending bytes keep deterministic recovery identity under batched export") { r in
            guard let h = await StorageHarness.make(name: "ap56-pending-derived") else { r.check("fixture", false); return }
            do {
                let items = try await staged(h, count: 3)
                for item in items {
                    let journal = h.support.appendingPathComponent(item.0.pendingRelativePath).deletingLastPathComponent().appendingPathComponent("transaction.json")
                    try h.memory.removeItem(at: journal)
                }
                let derived = await h.store.pendingOriginals()
                r.equal("all existing durable bytes remain discoverable", derived.count, 3)
                h.memory.resetCounters()
                let export = try await h.store.preparePendingOriginalExport(transactionIDs: derived.map(\.transactionID), includeSidecars: false)
                r.equal("derived recovery also uses one scan", h.memory.scanInvocations, 1)
                r.equal("every derived source exported", export.fileURLs.count, 3)
                r.equal("derived source bytes remain freshly hashed", h.memory.totalCounters().hashes, 6)
                let repeated = await h.store.pendingOriginals()
                r.equal("derived identities remain stable", Set(repeated.map(\.transactionID)), Set(derived.map(\.transactionID)))
                await h.store.discardExport(sessionID: export.sessionID)
            } catch { r.check("journal-less batched recovery", false, String(describing: error)) }
        },
        TCCase(id: "AP56O", title: "Idle analysis, readback and session observation do not retain a replaced camera model") { r in
            guard let h = await StorageHarness.make(name: "ap56-observer-release") else { r.check("fixture", false); return }
            let fixture = await WeakCamera56Fixture(h: h)
            await fixture.start()
            r.check("live readback observation really started", await waitUntil { await fixture.service.readbackRequests >= 1 })
            r.check("motion was explicitly running", fixture.feed.isRunning)
            await fixture.release()
            r.check("unbounded stream waits cannot retain the model", await waitUntil { await fixture.released })
            r.check("model teardown stops its motion owner", !(fixture.feed.isRunning))
            await fixture.meter.stop(); await fixture.service.stop()
        },
        TCCase(id: "AP56R", title: "The same camera and analysis consumer resume after explicit stop without a process restart") { r in
            guard let h = await StorageHarness.make(name: "ap56-analysis-restart") else { r.check("fixture", false); return }
            let fixture = await WeakCamera56Fixture(h: h)
            await fixture.start()
            guard let model = await fixture.owner else { r.check("model", false); return }
            let generation = await model.capability.generation, geometry = geometry(generation)
            let request = AnalysisRequest(configurationGeneration: generation, geometry: geometry,
                demand: AnalysisDemand(needsLuminanceSample: true, histogramEnabled: true,
                    zebrasEnabled: false, peakingEnabled: false, loupeEnabled: false),
                peakingThreshold: 0.2, zebraThreshold: 0.95, loupeCenter: .center, loupeMagnification: 2)
            await model.updateGeometry(geometry)
            await fixture.meter.setDemand(request)
            await fixture.meter.submit(sample: LuminanceSample(width: 2, height: 2, luma: [255,255,255,255], range: .full,
                configurationGeneration: generation, geometryGeneration: 56, capturedAtUTC: Date()))
            r.check("first current histogram reaches actual UI model", await waitUntil { await model.histogram?.bins[255] == 4 })
            await model.stop()
            r.equal("stopped optional processing has no demand", await fixture.meter.currentDemand, .none)
            let pausedReason = await model.analysisUnavailableReason
            await model.consumeAnalysisOutput(.analysisUnavailable(reason: "obsolete stopped frame"))
            r.equal("a stopped frame cannot poison later analysis readiness", await model.analysisUnavailableReason, pausedReason)
            await model.start()
            await model.updateGeometry(geometry)
            await fixture.meter.setDemand(request)
            await fixture.meter.submit(sample: LuminanceSample(width: 2, height: 2, luma: [0,0,0,0], range: .full,
                configurationGeneration: generation, geometryGeneration: 56, capturedAtUTC: Date().addingTimeInterval(0.01)))
            r.check("resumed consumer receives a new current frame", await waitUntil { await model.histogram?.bins[0] == 4 })
            await model.stop(); await fixture.release()
        }
    ])
}
