import Foundation
import AVFoundation
import Synchronization
#if canImport(XCTest)
@testable import TruongCam
#endif

private final class OriginalURLScopeDriver: SecurityScopeDriver {
    let original: URL
    private let stops = Mutex(0)
    init(_ original: URL) { self.original = original }
    func startAccess(_ url: URL) -> Bool { url.absoluteString == original.absoluteString }
    func stopAccess(_ url: URL) { stops.withLock { $0 += 1 } }
    var stopCount: Int { stops.withLock { $0 } }
}

enum StartupRepairSuite {
    static func controlFixture(modes: Set<ExposureModeKind>, kind: PhysicalCameraKind = .wide, heif: Bool = false, generation: ConfigurationGeneration = .zero) -> CameraCapabilitySnapshot {
        let limits = tcSeqCapability()
        let dimensions = PixelDimensions(width: 4000, height: 3000)
        let format = FormatCapability(formatIdentifier: "synthetic controls fixture", videoDimensions: dimensions,
            cleanApertureDimensions: nil, supportedMaxPhotoDimensions: [dimensions], bayerPixelFormats: [1234],
            rawFileTypes: ["synthetic DNG"], supportsCustomExposureMode: .available(true),
            supportedPriorityCombinations: modes, exposureLimits: limits.exposureLimits,
            minLensAperture: nil, maxLensAperture: nil, focusLimits: limits.focusLimits,
            whiteBalanceLimits: .available(maxGain: 4, supportsCustomGains: true, supportsTemperatureAndTint: true), videoFrameRateRanges: [], isVideoStabilizationSupported: false,
            secondaryNativeResolutionZoomFactors: [])
        return CameraCapabilitySnapshot(generation: generation, hardwareModel: "synthetic", osVersion: "synthetic",
            sdkVersion: "synthetic", physicalCameras: [PhysicalCameraCapability(kind: kind,
                deviceType: "synthetic", uniqueDeviceIdentifier: nil, modelIdentifier: "synthetic", formats: [format],
                selectedFormatIndex: 0, bayerRAWDiscovery: .available([1234]), rawFileTypeDiscovery: .available(["synthetic DNG"]),
                nativeBracketCountDiscovery: .unknown(reason: "not tested"), observedRAWDimensions: .unknown(reason: "not measured"),
                observedRAWEvidenceOrigin: nil, videoZoomFactorAtDiscovery: 1)], selectedCameraKind: kind,
            configuredPhotoDimensions: dimensions, configuredPhotoDimensionsEvidence: "synthetic", previewAnalysisFormat: nil,
            bayerCaptureSupported: heif ? .unavailable(reason: "synthetic front has no RAW") : .available(true), probeTimestampUTC: Date(timeIntervalSince1970: 0), notes: [], frontHEIFSupported: heif)
    }

    static func trashFixture(_ h: StorageHarness) async throws -> PhotoTrashRecord {
        let id = CaptureID()
        let handle = try await h.store.stageSource(bytes: StorageFixture.rawBytes(), metadata: StorageFixture.metadata(captureID: id, libraryID: h.libraryID))
        _ = try await h.store.commit(handle: handle)
        let cards = try await h.store.allReconciledSourceCards()
        guard let card = cards.first(where: { $0.captureID == id }) else { throw CancellationError() }
        return try await h.store.trashOriginal(card: card, generation: h.generation)
    }

    static let suite = TCSuite(id: "StartupRepair", title: "First device startup regressions", cases: [
        TCCase(id: "TR42L", title: "177 permanent deletions read only their canonical records without repeated collection scans") { r in
            guard let h = await StorageHarness.make(name: "tr42-linear") else { r.check("fixture", false); return }
            do {
                var records: [PhotoTrashRecord] = []
                for _ in 0..<177 { records.append(try await trashFixture(h)) }
                h.memory.resetCounters()
                for record in records { try await h.store.permanentlyDeleteOriginal(record: record, generation: h.generation) }
                r.equal("no whole-collection scan per file", h.memory.scanInvocations, 0)
                r.check("record reads stay linear", h.memory.totalCounters().reads < records.count * 10)
                r.equal("each original keeps both integrity checks", h.memory.counters(at: h.root.appendingPathComponent(records[0].storedOriginalPath)).hashes, 2)
                r.equal("last original also verified twice", h.memory.counters(at: h.root.appendingPathComponent(records[176].storedOriginalPath)).hashes, 2)
                r.equal("all verified photos removed", try await h.store.trashedOriginals().count, 0)
            } catch { r.check("large verified deletion", false, String(describing: error)) }
        },
        TCCase(id: "TR42R", title: "Direct restore never reads unrelated Trash records and rejects a mismatched canonical UUID") { r in
            guard let h = await StorageHarness.make(name: "tr42-direct") else { r.check("fixture", false); return }
            do {
                let first = try await trashFixture(h), second = try await trashFixture(h)
                h.memory.resetCounters()
                try await h.store.restoreOriginal(trashID: first.id, libraryID: h.libraryID, generation: h.generation)
                r.equal("restore needs no collection scan", h.memory.scanInvocations, 0)
                r.equal("unrelated record not read", h.memory.counters(at: h.root.appendingPathComponent(second.directory + "/record.json")).reads, 0)
                r.check("selected source restored", h.memory.fileExists(at: h.finalURL(for: first.captureID)))
                let url = h.root.appendingPathComponent(second.directory + "/record.json")
                let original = try h.memory.readAll(at: url, maxBytes: 16384)
                var json = try JSONSerialization.jsonObject(with: original) as! [String: Any]
                json["id"] = UUID().uuidString
                try h.memory.removeItem(at: url); try h.memory.writeNewFile(at: url, bytes: JSONSerialization.data(withJSONObject: json))
                do { try await h.store.permanentlyDeleteOriginal(record: second, generation: h.generation); r.check("mismatched record UUID refused", false) }
                catch { r.check("mismatched record UUID refused", true) }
                r.check("mismatched source retained", h.memory.fileExists(at: h.root.appendingPathComponent(second.storedOriginalPath)))
                r.check("no intent for mismatched identity", !h.memory.fileExists(at: h.root.appendingPathComponent(second.directory + "/delete-intent.json")))
            } catch { r.check("direct record identity", false, String(describing: error)) }
        },
        TCCase(id: "TR42P", title: "Photo mutation progress is counted from verified IDs and scoped to its library root") { r in
            let library = LibraryID(), generation = RootGeneration.zero, root = URL(fileURLWithPath: "/progress")
            var progress = PhotoMutationProgress(kind: .permanentlyDelete, libraryID: library, generation: generation, root: root, total: 177)
            r.equal("nothing falsely completed", progress.completed, 0)
            r.check("same root visible", progress.matches(state: .writable(libraryID: library, generation: generation), root: root))
            r.check("new generation hidden", !progress.matches(state: .writable(libraryID: library, generation: .next(generation)), root: root))
            r.check("new URL hidden", !progress.matches(state: .writable(libraryID: library, generation: generation), root: root.appendingPathComponent("other")))
            let id = UUID(); progress.completedIDs.insert(id); progress.completedIDs.insert(id)
            r.equal("duplicate completion not counted", progress.completed, 1)
            progress.stopRequested = true; r.equal("safe stopping visible", progress.title, "Finishing current photo…")
            progress.isRefreshing = true; r.equal("refresh phase visible", progress.title, "Updating library…")
        },
        TCCase(id: "TR41P", title: "Confirmed permanent deletion removes only verified Trash files and keeps active/unknown files") { r in
            guard let h = await StorageHarness.make(name: "tr41-permanent") else { r.check("fixture", false); return }
            do {
                let record = try await trashFixture(h)
                let live = CaptureID(), bytes = StorageFixture.rawBytes(filler: 0x42)
                let handle = try await h.store.stageSource(bytes: bytes, metadata: StorageFixture.metadata(captureID: live, libraryID: h.libraryID))
                _ = try await h.store.commit(handle: handle)
                let unknown = h.root.appendingPathComponent(record.directory + "/my-notes.txt")
                try h.memory.writeNewFile(at: unknown, bytes: Data("keep".utf8))
                do { try await h.store.permanentlyDeleteOriginal(record: record, generation: .next(h.generation)); r.check("stale delete refused", false) }
                catch { r.check("stale delete refused", true) }
                r.check("stale request preserved Trash original", h.memory.fileExists(at: h.root.appendingPathComponent(record.storedOriginalPath)))
                try await h.store.permanentlyDeleteOriginal(record: record, generation: h.generation)
                r.check("confirmed Trash original gone", !h.memory.fileExists(at: h.root.appendingPathComponent(record.storedOriginalPath)))
                r.check("confirmed Trash metadata gone", !h.memory.fileExists(at: h.root.appendingPathComponent(record.directory + "/metadata.json")))
                r.equal("unknown neighboring file untouched", h.memory.fileBytes(at: unknown), Data("keep".utf8))
                r.equal("active original untouched", h.memory.fileBytes(at: h.finalURL(for: live)), bytes)
                r.equal("Trash empties", try await h.store.trashedOriginals().count, 0)
                r.equal("only active original remains in reconciliation", try await h.store.allReconciledSourceCards().filter { $0.availability == .local }.map(\.captureID), [live])
            } catch { r.check("permanent deletion", false, String(describing: error)) }
        },
        TCCase(id: "TR41V", title: "A provider success without actual removal is not counted and keeps both files and retry intent") { r in
            guard let h = await StorageHarness.make(name: "tr41-verify-remove") else { r.check("fixture", false); return }
            do {
                let record = try await trashFixture(h)
                h.fault.arm(.removeIgnored)
                do { try await h.store.permanentlyDeleteOriginal(record: record, generation: h.generation); r.check("unverified success refused", false) }
                catch { r.check("unverified success refused", true) }
                r.check("original retained", h.memory.fileExists(at: h.root.appendingPathComponent(record.storedOriginalPath)))
                r.check("metadata retained", h.memory.fileExists(at: h.root.appendingPathComponent(record.directory + "/metadata.json")))
                r.check("durable retry intent retained", h.memory.fileExists(at: h.root.appendingPathComponent(record.directory + "/delete-intent.json")))
                r.equal("entry remains visible", try await h.store.trashedOriginals().count, 1)
                try await h.store.permanentlyDeleteOriginal(record: record, generation: h.generation)
                r.equal("verified explicit retry completes", try await h.store.trashedOriginals().count, 0)
            } catch { r.check("verified removal", false, String(describing: error)) }
        },
        TCCase(id: "TR41F", title: "Changed Trash bytes and interrupted live moves refuse permanent deletion") { r in
            guard let h = await StorageHarness.make(name: "tr41-changed") else { r.check("fixture", false); return }
            do {
                let record = try await trashFixture(h), url = h.root.appendingPathComponent(record.storedOriginalPath)
                try h.memory.removeItem(at: url); let changed = StorageFixture.rawBytes(filler: 0xAB)
                try h.memory.writeNewFile(at: url, bytes: changed)
                do { try await h.store.permanentlyDeleteOriginal(record: record, generation: h.generation); r.check("changed original refused", false) }
                catch { r.check("changed original refused", true) }
                r.equal("changed bytes retained", h.memory.fileBytes(at: url), changed)
                r.check("no deletion intent for changed bytes", !h.memory.fileExists(at: h.root.appendingPathComponent(record.directory + "/delete-intent.json")))
                let id = CaptureID(), handle = try await h.store.stageSource(bytes: StorageFixture.rawBytes(), metadata: StorageFixture.metadata(captureID: id, libraryID: h.libraryID))
                _ = try await h.store.commit(handle: handle)
                let card = try await h.store.allReconciledSourceCards().first { $0.captureID == id }
                guard let card else { r.check("card", false); return }
                h.fault.armMove(destinationSuffix: "metadata.json")
                do { _ = try await h.store.trashOriginal(card: card, generation: h.generation) } catch {}
                guard let interrupted = try await h.store.trashedOriginals().first(where: { $0.captureID == id }) else { r.check("interrupted record", false); return }
                do { try await h.store.permanentlyDeleteOriginal(record: interrupted, generation: h.generation); r.check("live metadata move cannot be purged", false) }
                catch { r.check("live metadata move cannot be purged", true) }
                r.check("live metadata untouched", h.memory.fileExists(at: h.finalSidecarURL(for: id)))
                r.check("interrupted original retained", h.memory.fileExists(at: h.root.appendingPathComponent(interrupted.storedOriginalPath)))
            } catch { r.check("negative permanent deletion", false, String(describing: error)) }
        },
        TCCase(id: "TR41R", title: "Partial permanent deletion and orphan intent survive interruption and retry without resurrection") { r in
            for trigger in ["original.dng", "record.json"] {
                guard let h = await StorageHarness.make(name: "tr41-retry-" + trigger) else { r.check("fixture", false); return }
                do {
                    let record = try await trashFixture(h)
                    let armed = Mutex(false)
                    h.fault.setObserver { event in
                        if event.kind == .remove, event.relativePath.hasSuffix("/" + trigger), !event.injected,
                           armed.withLock({ value in if value { return false }; value = true; return true }) {
                            h.fault.arm(.remove)
                        }
                    }
                    do { try await h.store.permanentlyDeleteOriginal(record: record, generation: h.generation); r.check("injected interruption reported", false) }
                    catch { r.check("injected interruption reported", true) }
                    h.fault.setObserver(nil)
                    let pending = try await h.store.trashedOriginals()
                    r.equal("partial deletion remains discoverable", pending.count, 1)
                    r.check("partial deletion marked", pending.first?.purgeStartedAtUTC != nil)
                    r.check("source was deleted after durable intent", !h.memory.fileExists(at: h.root.appendingPathComponent(record.storedOriginalPath)))
                    do { try await h.store.restoreOriginal(trashID: record.id, libraryID: record.libraryID, generation: h.generation); r.check("partial purge cannot resurrect", false) }
                    catch { r.check("partial purge cannot resurrect", true) }
                    try await h.store.permanentlyDeleteOriginal(record: record, generation: h.generation)
                    r.equal("explicit retry finishes exact files", try await h.store.trashedOriginals().count, 0)
                    r.check("original never reappears", !h.memory.fileExists(at: h.finalURL(for: record.captureID)))
                } catch { r.check("interrupted deletion", false, String(describing: error)) }
            }
        },
        TCCase(id: "TR41D", title: "Real coordinated temporary filesystem permanently deletes a verified original and preserves a neighbor") { r in
            let base = StorageFixture.temporaryDirectory("tr41-real"); defer { StorageFixture.removeDirectory(base) }
            let root = base.appendingPathComponent("library", isDirectory: true)
            do {
                try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
                let store = LibraryStore(adapter: SystemFileSystemAdapter(), coordinator: NSFileCoordinatorMutator(),
                    wallClock: StorageFixture.fixedClock(), supportDirectory: base.appendingPathComponent("support"),
                    temporaryDirectory: base.appendingPathComponent("tmp"), ownedContainerURLs: [], bookmarkStore: InMemoryRootBookmarkStore(),
                    scopeDriver: ScriptedSecurityScopeDriver(grants: [true]), capacityReserveBytes: 0,
                    injectedLocalityVerdict: .userConfirmedLocalDestination(evidence: "isolated temporary fixture"))
                _ = await store.selectRoot(from: root, confirmedLocalDestination: true)
                guard case .writable(let library, let generation) = store.rootState else { r.check("root", false); return }
                let id = CaptureID(), handle = try await store.stageSource(bytes: StorageFixture.rawBytes(), metadata: StorageFixture.metadata(captureID: id, libraryID: library))
                _ = try await store.commit(handle: handle)
                guard let card = try await store.allReconciledSourceCards().first else { r.check("card", false); return }
                let record = try await store.trashOriginal(card: card, generation: generation)
                let neighbor = root.appendingPathComponent(record.directory + "/unknown.txt")
                try Data("keep".utf8).write(to: neighbor)
                try await store.permanentlyDeleteOriginal(record: record, generation: generation)
                r.equal("real Trash no photos", try await store.trashedOriginals().count, 0)
                r.equal("neighbor kept", try Data(contentsOf: neighbor), Data("keep".utf8))
                r.check("original removed", !FileManager.default.fileExists(atPath: root.appendingPathComponent(record.storedOriginalPath).path))
                r.equal("reconciled library remains empty", try await store.allReconciledSourceCards().count, 0)
                let linkedID = CaptureID(), linkedHandle = try await store.stageSource(bytes: StorageFixture.rawBytes(), metadata: StorageFixture.metadata(captureID: linkedID, libraryID: library))
                _ = try await store.commit(handle: linkedHandle)
                guard let linkedCard = try await store.allReconciledSourceCards().first else { r.check("linked card", false); return }
                let linked = try await store.trashOriginal(card: linkedCard, generation: generation)
                let outside = base.appendingPathComponent("outside.dng"), linkedURL = root.appendingPathComponent(linked.storedOriginalPath)
                let outsideBytes = StorageFixture.rawBytes(filler: 0x91); try outsideBytes.write(to: outside)
                try FileManager.default.removeItem(at: linkedURL)
                try FileManager.default.createSymbolicLink(at: linkedURL, withDestinationURL: outside)
                do { try await store.permanentlyDeleteOriginal(record: linked, generation: generation); r.check("symlink purge refused", false) }
                catch { r.check("symlink purge refused", true) }
                r.equal("outside symlink target untouched", try Data(contentsOf: outside), outsideBytes)
                r.check("refused purge keeps metadata", FileManager.default.fileExists(atPath: root.appendingPathComponent(linked.directory + "/metadata.json").path))
                await store.releaseRoot()
            } catch { r.check("real permanent deletion", false, String(describing: error)) }
        },
        TCCase(id: "HW41C", title: "Front retains discovered rear Camera Control choices and automatic preview policy needs no explicit flip") { r in
            guard let h = await StorageHarness.make(name: "hw41-catalog") else { r.check("fixture", false); return }
            var capability = controlFixture(modes: [.auto,.manual], kind: .front)
            capability.physicalCameras += controlFixture(modes: [.auto,.manual], kind: .wide).physicalCameras
                + controlFixture(modes: [.auto,.manual], kind: .ultraWide).physicalCameras
            let service = SyntheticCameraService(capability: capability)
            let model = await CameraViewModel(camera: service, capture: CaptureCoordinator(camera: ChainCameraSpy(), store: h.store, clock: SystemMonotonicClock()),
                metering: MeteringService(clock: SystemMonotonicClock()), preferences: SyntheticPreferenceStore(), levelFeed: SyntheticLevelFeed())
            await model.updateRootState(h.store.rootState); await model.startIfNeeded()
            let configuration = await model.hardwareConfiguration(enabled: true)
            r.check("Front control remains enabled", configuration.enabled)
            r.equal("one native chooser remains installed", configuration.selections.count, 1)
            r.equal("all discovered lenses retained", configuration.selections.first?.domain.options.map(\.value), [.lens(.ultraWide),.lens(.wide),.lens(.front)])
            r.check("automatic native mirror performs no repeated writes", CapturePipelinePreparation.automaticPreviewMirroringChanges(supported: true, automatic: true).isEmpty)
            r.equal("disabled automatic policy restores only automatic mode", CapturePipelinePreparation.automaticPreviewMirroringChanges(supported: true, automatic: false), [.enableAutomatic])
            r.check("unsupported mirror never written", CapturePipelinePreparation.automaticPreviewMirroringChanges(supported: false, automatic: false).isEmpty)
            await model.handleCameraScreenCovered()
        },
        TCCase(id: "PM40S", title: "Remembered front camera starts in a fresh model without resetting preferences or originals") { r in
            guard let h = await StorageHarness.make(name: "pm40-front") else { r.check("fixture", false); return }
            var preferences = CompositionPreferences(); preferences.preferredLens = .front
            for _ in 0..<2 {
                let service = SyntheticCameraService(capability: controlFixture(modes: [.auto,.manual], kind: .front))
                let model = await CameraViewModel(camera: service,
                    capture: CaptureCoordinator(camera: ChainCameraSpy(), store: h.store, clock: SystemMonotonicClock()),
                    metering: MeteringService(clock: SystemMonotonicClock()),
                    preferences: SyntheticPreferenceStore(composition: preferences), levelFeed: SyntheticLevelFeed())
                await model.startIfNeeded()
                r.equal("fresh native preparation receives saved Front choice", await service.preparedCameraRequests, [.front])
                r.equal("remembered Front becomes ready", await model.surface, .ready)
                r.equal("relaunch does not erase saved facing", await model.composition.preferredLens, .front)
                await model.handleCameraScreenCovered()
            }
        },
        TCCase(id: "HW39P", title: "A real held capture preserves hardware presentation while rejecting additional commands") { r in
            guard let h = await StorageHarness.make(name: "hw39-photo") else { r.check("fixture", false); return }
            let native = ChainCameraSpy(); native.holdAttachments()
            let service = SyntheticCameraService(capability: controlFixture(modes: [.auto,.manual]))
            let model = await CameraViewModel(camera: service,
                capture: CaptureCoordinator(camera: ResponsiveAutoCamera(native: native, liveAcknowledgement: true), store: h.store, clock: SystemMonotonicClock()),
                metering: MeteringService(clock: SystemMonotonicClock()), preferences: SyntheticPreferenceStore(), levelFeed: SyntheticLevelFeed())
            await model.start(); await model.updateRootState(.writable(libraryID: h.libraryID, generation: h.generation))
            await MainActor.run { model.openPanel = .shutter }
            let before = await model.hardwareConfiguration(enabled: true)
            await model.updateHardwareControls(before)
            let photo = Task { await model.captureNow() }
            var deadline = ContinuousClock.now.advanced(by: .seconds(2))
            while native.attachArrivals == 0, ContinuousClock.now < deadline { await Task.yield() }
            let during = await model.hardwareConfiguration(enabled: true)
            await model.updateHardwareControls(during)
            r.check("capture really holds native attachment", native.attachArrivals > 0)
            r.check("system event interaction stays registered", await model.isHardwareInteractionEligible)
            let shutterEnabled = await model.isHardwareShutterEnabled
            r.check("commands remain closed during capture", !during.enabled && during.preservesPresentation && !shutterEnabled)
            if let picker = during.selections.first {
                await model.receiveHardwareSelection(HardwareControlSelection(domain: picker.domain, index: 1))
            }
            r.equal("busy swipe cannot change exposure", await model.exposure, .auto)
            native.releaseAttachments()
            deadline = ContinuousClock.now.advanced(by: .seconds(2))
            while native.lastCreatedTicket == nil, ContinuousClock.now < deadline { await Task.yield() }
            native.lastCreatedTicket?.deliver(.failed(CaptureFailure(kind: .captureFailed(detail: "synthetic terminal, no source"), operation: "test")))
            await photo.value
            let after = await model.hardwareConfiguration(enabled: true)
            await model.updateHardwareControls(after)
            r.check("settings resume without toggling Auto or reopening panel", after.enabled && !after.preservesPresentation)
            await model.handleCameraScreenCovered()
        },
        TCCase(id: "HW39R", title: "A transient native failure self-heals a cached running camera with one stop and validated restart") { r in
            guard let h = await StorageHarness.make(name: "hw39-repair") else { r.check("fixture", false); return }
            let service = SyntheticCameraService(capability: controlFixture(modes: [.auto,.manual]))
            await service.configureStopClearsCondition()
            let model = await CameraViewModel(camera: service,
                capture: CaptureCoordinator(camera: ChainCameraSpy(), store: h.store, clock: SystemMonotonicClock()),
                metering: MeteringService(clock: SystemMonotonicClock()), preferences: SyntheticPreferenceStore(), levelFeed: SyntheticLevelFeed())
            await model.start(); await model.updateRootState(SeqTestSupport.writableRoot)
            await model.updatePendingOriginalCount(1)
            let failure = CameraLifecycle.failed(.cameraInterrupted(detail: "synthetic driver failure"))
            await service.recordCondition(failure); await model.applyServiceCondition(failure)
            r.check("failure closes admission before repair", !(await model.runtimeAdmissionReady))
            await model.applyServiceCondition(failure, isTransition: false)
            let deadline = ContinuousClock.now.advanced(by: .seconds(3))
            while !(await model.runtimeAdmissionReady), ContinuousClock.now < deadline { await Task.yield() }
            r.check("visible camera recovered without process restart", await model.runtimeAdmissionReady)
            r.equal("one recovery stop", await service.stopRequests, 1)
            r.equal("one fresh restart", await service.startRequests, 2)
            r.equal("current service condition replaces old failure", await model.effectiveLifecycle, .running)
            r.equal("pending original was preserved", await model.pendingOriginalCount, 1)
            r.check("pending original still gates new shutter", !(await model.isHardwareShutterEnabled))
            await model.handleSceneBecameActive()
            r.equal("duplicate foreground callback does not start again", await service.startRequests, 2)
            await model.handleCameraScreenCovered()
        },
        TCCase(id: "HW39B", title: "Failed automatic recovery is bounded and explicit retry remains usable; permissions and resets are not overridden") { r in
            guard let h = await StorageHarness.make(name: "hw39-bounded") else { r.check("fixture", false); return }
            let service = SyntheticCameraService(capability: controlFixture(modes: [.auto]))
            await service.configureStopClearsCondition()
            let model = await CameraViewModel(camera: service,
                capture: CaptureCoordinator(camera: ChainCameraSpy(), store: h.store, clock: SystemMonotonicClock()),
                metering: MeteringService(clock: SystemMonotonicClock()), preferences: SyntheticPreferenceStore(), levelFeed: SyntheticLevelFeed())
            await model.start(); await model.updateRootState(SeqTestSupport.writableRoot)
            await service.configureStartFailures(1)
            let failure = CameraLifecycle.failed(.cameraInterrupted(detail: "synthetic transient"))
            await service.recordCondition(failure); await model.applyServiceCondition(failure)
            let deadline = ContinuousClock.now.advanced(by: .seconds(3))
            while await service.startRequests < 2, ContinuousClock.now < deadline { await Task.yield() }
            try? await Task.sleep(for: .milliseconds(250))
            r.equal("automatic retry cannot loop on a failed restart", await service.startRequests, 2)
            r.check("failure remains visible", await model.surface != .ready)
            r.check("failed restart cannot open capture", !(await model.runtimeAdmissionReady))
            await model.startIfNeeded()
            r.check("explicit retry can reach usable camera", await model.runtimeAdmissionReady)
            let stops = await service.stopRequests
            let permission = CameraLifecycle.failed(.permissionDenied(domain: "synthetic camera permission"))
            await service.recordCondition(permission); await model.applyServiceCondition(permission)
            try? await Task.sleep(for: .milliseconds(220))
            r.equal("permission denial has no automatic stop/retry", await service.stopRequests, stops)
            let reset = CameraLifecycle.failed(.cameraInterrupted(detail: MediaServicesResetSignal.detail))
            await service.recordCondition(reset); await model.applyServiceCondition(reset)
            await model.startIfNeeded()
            r.equal("typed reset remains owned by its recovery chain", await service.stopRequests, stops)
            r.check("typed reset admission stays closed", !(await model.runtimeAdmissionReady))
            await model.handleCameraScreenCovered()
        },
        TCCase(id: "HW39E", title: "Cover and return while recovery stop drains cannot leave the camera permanently unavailable") { r in
            guard let h = await StorageHarness.make(name: "hw39-cover") else { r.check("fixture", false); return }
            let service = SyntheticCameraService(capability: controlFixture(modes: [.auto]))
            await service.configureStopClearsCondition(); await service.holdStop()
            let model = await CameraViewModel(camera: service,
                capture: CaptureCoordinator(camera: ChainCameraSpy(), store: h.store, clock: SystemMonotonicClock()),
                metering: MeteringService(clock: SystemMonotonicClock()), preferences: SyntheticPreferenceStore(), levelFeed: SyntheticLevelFeed())
            await model.start()
            let failure = CameraLifecycle.failed(.cameraInterrupted(detail: "synthetic return"))
            await service.recordCondition(failure); await model.applyServiceCondition(failure)
            var deadline = ContinuousClock.now.advanced(by: .seconds(3))
            while await service.stopRequests == 0, ContinuousClock.now < deadline { await Task.yield() }
            let cover = Task { await model.handleCameraScreenCovered() }
            deadline = ContinuousClock.now.advanced(by: .seconds(2))
            while await model.isCameraEligibleForCapture, ContinuousClock.now < deadline { await Task.yield() }
            await model.handleCameraScreenRevealed()
            r.equal("return waits for existing stop owner", await service.startRequests, 1)
            await service.releaseStop(); await cover.value
            deadline = ContinuousClock.now.advanced(by: .seconds(3))
            while !(await model.runtimeAdmissionReady), ContinuousClock.now < deadline { await Task.yield() }
            r.check("latest eligible owner eventually restarts", await model.runtimeAdmissionReady)
            r.equal("single latest restart", await service.startRequests, 2)
            await model.handleCameraScreenCovered()
        },
        TCCase(id: "HW39F", title: "Unresolved submitted source obligations prevent recovery teardown and remain retryable") { r in
            guard let h = await StorageHarness.make(name: "hw39-fence") else { r.check("fixture", false); return }
            let service = SyntheticCameraService(capability: controlFixture(modes: [.auto]))
            await service.configureStopClearsCondition(); await service.configureRecoveryOutstanding(1)
            let model = await CameraViewModel(camera: service,
                capture: CaptureCoordinator(camera: ChainCameraSpy(), store: h.store, clock: SystemMonotonicClock()),
                metering: MeteringService(clock: SystemMonotonicClock()), preferences: SyntheticPreferenceStore(), levelFeed: SyntheticLevelFeed())
            await model.start()
            let failure = CameraLifecycle.failed(.cameraInterrupted(detail: "synthetic unfinished source"))
            await service.recordCondition(failure); await model.applyServiceCondition(failure)
            try? await Task.sleep(for: .milliseconds(260))
            r.equal("outstanding source forbids native stop", await service.stopRequests, 0)
            r.equal("outstanding source forbids graph preparation", await service.prepareRequests, 1)
            r.check("outstanding source forbids admission", !(await model.runtimeAdmissionReady))
            r.equal("actionable drain failure retained", await model.lastFailure?.origin, "cameraInterrupted")
            await service.configureRecoveryOutstanding(0)
            await model.startIfNeeded()
            r.check("real resolution permits a later explicit retry", await model.runtimeAdmissionReady)
            await model.handleCameraScreenCovered()
        },
        TCCase(id: "HW39M", title: "Preview mirroring disables automatic adjustment before either facing and refuses stale/no-op work") { r in
            let front = CapturePipelinePreparation.previewMirroringChanges(supported: true, automatic: true, mirrored: false, desired: true)
            r.equal("front explicit setter precondition/order", front, [.disableAutomatic,.setMirrored(true)])
            let rear = CapturePipelinePreparation.previewMirroringChanges(supported: true, automatic: true, mirrored: true, desired: false)
            r.equal("rear explicit setter precondition/order", rear, [.disableAutomatic,.setMirrored(false)])
            r.check("already configured avoids another native setter", CapturePipelinePreparation.previewMirroringChanges(supported: true, automatic: false, mirrored: true, desired: true).isEmpty)
            r.check("unsupported mirroring has no native writes", CapturePipelinePreparation.previewMirroringChanges(supported: false, automatic: true, mirrored: false, desired: true).isEmpty)
            let (result, applied) = await MainActor.run {
                var current = true, applied: [CapturePipelinePreparation.PreviewMirroringChange] = []
                let result = CapturePipelinePreparation.applyPreviewMirroring(front, isCurrent: { current }) {
                    applied.append($0); current = false
                }
                return (result, applied)
            }
            r.check("superseded native owner is refused", !result)
            r.equal("no stale explicit mirror setter", applied, [.disableAutomatic])
        },
        TCCase(id: "HW38A", title: "First hardware swipe preserves exact Auto exposure, focus and both WB axes") { r in
            guard let h = await StorageHarness.make(name: "hw38-auto") else { r.check("fixture", false); return }
            let service = SyntheticCameraService(capability: controlFixture(modes: [.auto,.manual]))
            await service.configureReadbackTransform { hardwareAutoReading($0) }
            let model = await CameraViewModel(camera: service,
                capture: CaptureCoordinator(camera: ChainCameraSpy(), store: h.store, clock: SystemMonotonicClock()),
                metering: MeteringService(clock: SystemMonotonicClock()), preferences: SyntheticPreferenceStore(), levelFeed: SyntheticLevelFeed())
            await model.start(); await model.updateRootState(SeqTestSupport.writableRoot)
            for panel in [CameraPanel.shutter, .iso, .focus, .whiteBalance] {
                await MainActor.run { model.openPanel = panel; model.setStripAutomatic(panel) }
                _ = await model.applyCurrentControls(); _ = await model.currentAppliedSnapshot()
                let config = await model.hardwareConfiguration(enabled: true)
                await model.updateHardwareControls(config)
                guard let control = config.selections.first else { r.check("available", false); continue }
                r.check("Auto is visually anchored at an observed numeric value", control.index > 0 && control.isAutomatic)
                let step = control.index == 1 ? 2 : 1
                await model.receiveHardwareSelection(HardwareControlSelection(domain: control.domain, index: step))
                switch panel {
                case .shutter:
                    r.equal("first swipe locks 1/50, not fastest detent", await model.exposure.durationTargetSeconds, 0.02)
                    r.equal("paired ISO comes from same reading", await model.exposure.isoTarget, 320)
                case .iso:
                    r.equal("first swipe locks current ISO", await model.exposure.isoTarget, 320)
                    r.equal("paired shutter retained from live reading", await model.exposure.durationTargetSeconds, 0.02)
                case .focus: r.equal("first swipe locks measured focus", await model.focus.position, 0.42)
                case .whiteBalance:
                    r.equal("Auto WB seed preserves both converted axes", await model.whiteBalance.temperatureAndTint, WhiteBalanceTemperatureAndTint(temperature: 4700, tint: 12))
                case .exposureBias, .aperture: break
                }
            }
            // Returning to Auto and immediately swiping must wait for that owned
            // 60-ms setter mailbox, rather than consuming the previous Manual read.
            await MainActor.run { model.openPanel = .shutter; model.setStripAutomatic(.shutter) }
            let immediate = await model.hardwareConfiguration(enabled: true)
            await model.updateHardwareControls(immediate)
            if let control = immediate.selections.first {
                await model.receiveHardwareSelection(HardwareControlSelection(domain: control.domain, index: control.index == 1 ? 2 : 1))
                r.equal("immediate swipe after Auto uses fresh Auto value", await model.exposure.durationTargetSeconds, 0.02)
            }
            r.check("active picker ignores periodic value echoes", !HardwarePickerSynchronization.shouldUpdateIndex(active: true, ownerChanged: false, automaticChanged: false))
            r.check("mode change reanchors once", HardwarePickerSynchronization.shouldUpdateIndex(active: true, ownerChanged: false, automaticChanged: true))
            r.check("new owner reanchors", HardwarePickerSynchronization.shouldUpdateIndex(active: true, ownerChanged: true, automaticChanged: false))
            r.check("inactive picker follows current model", HardwarePickerSynchronization.shouldUpdateIndex(active: false, ownerChanged: false, automaticChanged: false))
            await model.handleCameraScreenCovered()
        },
        TCCase(id: "HW38N", title: "Auto handoff refuses missing, stale, foreign and overtaken observations") { r in
            guard let h = await StorageHarness.make(name: "hw38-negative") else { r.check("fixture", false); return }
            let service = SyntheticCameraService(capability: controlFixture(modes: [.auto,.manual]))
            let model = await CameraViewModel(camera: service,
                capture: CaptureCoordinator(camera: ChainCameraSpy(), store: h.store, clock: SystemMonotonicClock()),
                metering: MeteringService(clock: SystemMonotonicClock()), preferences: SyntheticPreferenceStore(), levelFeed: SyntheticLevelFeed())
            await model.start(); await model.updateRootState(SeqTestSupport.writableRoot)
            await MainActor.run { model.openPanel = .shutter }
            let config = await model.hardwareConfiguration(enabled: true)
            await model.updateHardwareControls(config)
            guard let picker = config.selections.first else { r.check("picker", false); return }
            let gesture = HardwareControlSelection(domain: picker.domain, index: 1)
            for variant in 0...5 {
                await service.configureReadbackTransform { snapshot in hardwareAutoReading(snapshot, invalidVariant: variant) }
                await model.receiveHardwareSelection(gesture)
                r.equal("invalid observation cannot turn off Auto \(variant)", await model.exposure, .auto)
            }
            await service.configureReadbackTransform { hardwareAutoReading($0) }
            await service.holdReadback()
            let count = await service.readbackRequests
            let pending = Task { await model.receiveHardwareSelection(gesture) }
            let deadline = ContinuousClock.now.advanced(by: .seconds(2))
            while await service.readbackRequests == count, ContinuousClock.now < deadline { await Task.yield() }
            await MainActor.run { model.openPanel = .iso }
            await service.releaseReadback(); await pending.value
            r.equal("closing the parameter while measuring refuses its old swipe", await model.exposure, .auto)
            await model.handleCameraScreenCovered()
        },
        TCCase(id: "HW38L", title: "Hardware lens swipes retain latest target and require the current rendered frame between switches") { r in
            guard let h = await StorageHarness.make(name: "hw38-lenses") else { r.check("fixture", false); return }
            func fixture(_ kind: PhysicalCameraKind, _ generation: UInt64) -> CameraCapabilitySnapshot {
                var selected = controlFixture(modes: [.auto,.manual], kind: kind, generation: ConfigurationGeneration(generation))
                selected.physicalCameras = [PhysicalCameraKind.wide,.ultraWide,.front].flatMap { controlFixture(modes: [.auto,.manual], kind: $0).physicalCameras }
                return selected
            }
            let service = SyntheticCameraService(capability: fixture(.wide, 10))
            await service.configureFacingFixtures([.front:fixture(.front,11), .wide:fixture(.wide,12), .ultraWide:fixture(.ultraWide,13)])
            await service.installDisplaySession(AVCaptureSession())
            let model = await CameraViewModel(camera: service,
                capture: CaptureCoordinator(camera: ChainCameraSpy(), store: h.store, clock: SystemMonotonicClock()),
                metering: MeteringService(clock: SystemMonotonicClock()), preferences: SyntheticPreferenceStore(), levelFeed: SyntheticLevelFeed())
            func render(_ generation: UInt64) async {
                let geometry = PreviewGeometrySnapshot(configurationGeneration: ConfigurationGeneration(generation), layoutGeneration: 8,
                    imageDimensions: PixelDimensions(width: 4000,height: 3000), cleanApertureDimensions: nil,
                    previewLayerContentRect: TCRect(x: 0,y: 0,width: 300,height: 400), bufferOrientation: 1,
                    isMirrored: false, analysisRotationDegrees: 0, isVideoMirrored: false, capturedAtUTC: Date())
                await model.updateGeometry(geometry)
                _ = await model.previewDidResume(generation: ConfigurationGeneration(generation), layout: 8)
            }
            await model.start(); await model.updateRootState(SeqTestSupport.writableRoot); await render(10)
            let config = await model.hardwareConfiguration(enabled: true)
            await model.updateHardwareControls(config)
            guard let picker = config.selections.first else { r.check("picker", false); return }
            let owner = await model.hardwareInteractionID
            func swipe(_ kind: PhysicalCameraKind) async {
                guard let index = picker.domain.options.firstIndex(where: { $0.value == .lens(kind) }) else { return }
                await model.receiveHardwareEvent(HardwareControlEvent(interactionID: owner, selection: HardwareControlSelection(domain: picker.domain, index: index)))
            }
            await service.holdSwitch(); await swipe(.front)
            var deadline = ContinuousClock.now.advanced(by: .seconds(2))
            while await service.switchRequests.isEmpty, ContinuousClock.now < deadline { await Task.yield() }
            let transitioning = await model.hardwareConfiguration(enabled: true)
            await model.updateHardwareControls(transitioning)
            r.check("lens swipe remains enabled during own switch", transitioning.enabled)
            r.check("hardware event registration survives the in-progress facing switch", await model.isHardwareInteractionEligible)
            r.equal("native chooser identity stays stable", transitioning.selections.first?.domain, picker.domain)
            r.equal("owned switch does not revoke gesture", await model.hardwareInteractionID, owner)
            await swipe(.ultraWide); await swipe(.wide)
            r.equal("only first native graph operation admitted", await service.switchRequests, [.front])
            await service.releaseSwitch()
            deadline = ContinuousClock.now.advanced(by: .seconds(2))
            while await model.isSwitchingLens, ContinuousClock.now < deadline { await Task.yield() }
            r.equal("pending reverse waits for rendered new sensor", await service.switchRequests, [.front])
            r.check("shutter stays closed under transition", !(await model.isHardwareShutterEnabled))
            let switched = await model.hardwareConfiguration(enabled: true)
            await model.updateHardwareControls(switched)
            r.equal("generation change retains chooser", switched.selections.first?.domain, picker.domain)
            await render(11)
            deadline = ContinuousClock.now.advanced(by: .seconds(2))
            while ContinuousClock.now < deadline {
                if await service.switchRequests.count >= 2, await !model.isSwitchingLens { break }
                await Task.yield()
            }
            r.equal("latest reverse wins; intermediate target coalesced", await service.switchRequests, [.front,.wide])
            await render(12)
            // Covering with Tools revokes a queued third target even if its native
            // predecessor later completes successfully.
            await service.holdSwitch(); await swipe(.front)
            deadline = ContinuousClock.now.advanced(by: .seconds(2))
            while await service.switchRequests.count < 3, ContinuousClock.now < deadline { await Task.yield() }
            await swipe(.ultraWide)
            await MainActor.run { model.isToolsSheetPresented = true }
            let gated = await model.hardwareConfiguration(enabled: true)
            await model.updateHardwareControls(gated)
            await service.releaseSwitch()
            deadline = ContinuousClock.now.advanced(by: .seconds(2))
            while await model.isSwitchingLens, ContinuousClock.now < deadline { await Task.yield() }
            await render(11)
            r.equal("modal revokes pending lens intent", await service.switchRequests, [.front,.wide,.front])
            await MainActor.run { model.isToolsSheetPresented = false }
            let reopened = await model.hardwareConfiguration(enabled: true)
            await model.updateHardwareControls(reopened)
            await swipe(.wide)
            r.equal("old gesture cannot replay after modal", await service.switchRequests, [.front,.wide,.front])
            await model.handleCameraScreenCovered()
        },
        TCCase(id: "HW37E", title: "Hardware gesture subscriptions never replay a prior command; state subscriptions retain replay") { r in
            let b = LatestValueBroadcaster<Int>()
            b.send(1)
            var state = b.subscribe().makeAsyncIterator()
            r.equal("state still replays current value", await state.next(), 1)
            let received = SequenceTestBox<Int?>(nil)
            let events = b.subscribe(replayLatest: false)
            let task = Task { var iterator = events.makeAsyncIterator(); received.set(await iterator.next()) }
            try? await Task.sleep(nanoseconds: 20_000_000)
            r.equal("opening a surface is not a new gesture", received.value, nil)
            b.send(2)
            await task.value
            r.equal("new gesture is delivered", received.value, 2)
        },
        TCCase(id: "HW37", title: "Camera Control uses current photographic detents, both WB axes and stale/modal gates") { r in
            guard let storage = await StorageHarness.make(name: "hw37") else { r.check("fixture", false); return }
            let clock = SystemMonotonicClock()
            let service = SyntheticCameraService(capability: controlFixture(modes: [.auto,.manual], generation: SeqTestSupport.configurationGeneration))
            await service.configureReadbackTransform { reading in hardwareAutoReading(reading) }
            let model = await CameraViewModel(camera: service,
                capture: CaptureCoordinator(camera: ChainCameraSpy(), store: storage.store, clock: clock),
                metering: MeteringService(clock: clock), clock: clock, preferences: SyntheticPreferenceStore(), levelFeed: SyntheticLevelFeed())
            await model.start(); await model.updateRootState(SeqTestSupport.writableRoot)
            let lenses = await model.hardwareConfiguration(enabled: true)
            r.check("ready hardware surface", lenses.enabled)
            r.equal("only discovered rear plus explicit front discovery", lenses.selections.first?.domain.options.map(\.value), [.lens(.wide),.lens(.front)])
            for panel in [CameraPanel.shutter, .iso, .focus] {
                await MainActor.run { model.openPanel = panel; model.setStripAutomatic(panel) }
                _ = await model.applyCurrentControls(); _ = await model.currentAppliedSnapshot()
                let request = await model.hardwareConfiguration(enabled: true)
                await model.updateHardwareControls(request)
                guard let picker = request.selections.first else { r.check("supported picker", false); continue }
                r.equal("automatic is an explicit detent", picker.domain.value(at: 0), .automatic)
                r.equal("negative index refused", picker.domain.value(at: -1), nil)
                r.equal("out-of-bounds index refused", picker.domain.value(at: picker.domain.options.count), nil)
                let selected = HardwareControlSelection(domain: picker.domain, index: min(2,picker.domain.options.count-1))
                await model.receiveHardwareSelection(selected)
                let seeded = await model.hardwareConfiguration(enabled: true)
                r.check("first swipe leaves Auto at measured value", seeded.selections.first?.isAutomatic == false)
                await model.receiveHardwareSelection(selected)
                let desired = await model.hardwareConfiguration(enabled: true)
                r.equal("later swipe uses photographic detents", desired.selections.first?.index, selected.index)
                await model.receiveHardwareSelection(HardwareControlSelection(domain: picker.domain, index: 0))
                r.check("Auto intent remains explicit with a live numeric anchor", await model.hardwareConfiguration(enabled: true).selections.first?.isAutomatic == true)
            }
            await MainActor.run { model.openPanel = .whiteBalance }
            _ = await model.applyCurrentControls(); _ = await model.currentAppliedSnapshot()
            let wb = await model.hardwareConfiguration(enabled: true)
            await model.updateHardwareControls(wb)
            r.equal("WB exposes temperature and tint", wb.selections.map { $0.domain.kind }, [.temperature,.tint])
            for selection in wb.selections {
                let index = min(5,selection.domain.options.count-1)
                await model.receiveHardwareSelection(HardwareControlSelection(domain: selection.domain, index: index))
                await model.receiveHardwareSelection(HardwareControlSelection(domain: selection.domain, index: index))
                let now = await model.hardwareConfiguration(enabled: true)
                r.equal("WB axis updated", now.selections.first { $0.domain.kind == selection.domain.kind }?.index, index)
            }
            let prior = await model.whiteBalance
            if let selection = wb.selections.first {
                let oldInteraction = await model.hardwareInteractionID
                await model.updateHardwareControls(HardwareControlConfiguration(enabled: false, selections: wb.selections))
                await model.updateHardwareControls(wb)
                r.check("reactivation gets a new owner", await model.hardwareInteractionID != oldInteraction)
                await model.receiveHardwareEvent(HardwareControlEvent(interactionID: oldInteraction,
                    selection: HardwareControlSelection(domain: selection.domain, index: 1)))
                r.equal("queued pre-modal gesture cannot replay after reopening", await model.whiteBalance, prior)
                let d = selection.domain
                let foreign = HardwareControlDomain(generation: ConfigurationGeneration(d.generation.value+1), kind: d.kind, title: d.title, symbol: d.symbol, options: d.options)
                await model.receiveHardwareSelection(HardwareControlSelection(domain: foreign, index: 1))
                r.equal("old/foreign camera callback refused", await model.whiteBalance, prior)
                await MainActor.run { model.openPanel = .focus }
                await model.receiveHardwareSelection(HardwareControlSelection(domain: d, index: 1))
                r.equal("closed parameter's callback refused", await model.whiteBalance, prior)
                await MainActor.run { model.openPanel = .whiteBalance; model.isToolsSheetPresented = true }
                await model.receiveHardwareSelection(HardwareControlSelection(domain: d, index: 1))
                r.equal("modal cannot change camera settings", await model.whiteBalance, prior)
                r.check("modal disables native surface", !(await model.hardwareConfiguration(enabled: true).enabled))
            }
            await model.updateHardwareControls(HardwareControlConfiguration(enabled: false, selections: []))
            await model.handleCameraScreenCovered()
        },
        TCCase(id: "SF35", title: "Native shutter cues require submitted identity, deduplicate and cannot certify saving") { r in
            let intent = ChainCameraSpy.defaultIntent(captureID: CaptureID())
            let request = PerCaptureRequest(captureID: intent.captureID, intent: intent,
                rawPixelFormatType: 1234, rawFileType: "com.adobe.raw-image", maximumRepresentations: 1)
            let ticket = CameraCaptureTicket(captureID: intent.captureID, uniqueSettingsID: 42, request: request)
            r.check("unbound callback refused", !request.recordNativeShutter(settingsID: 42))
            r.check("bind once", request.bindNativeSettingsID(42))
            r.check("foreign callback refused", !request.recordNativeShutter(settingsID: 43))
            r.check("native will-capture admitted", request.recordNativeShutter(settingsID: 42))
            r.check("duplicate ordinary callback refused", !request.recordNativeShutter(settingsID: 42))
            var iterator = ticket.shutterFeedbackEvents.makeAsyncIterator()
            let cue = await iterator.next()
            r.equal("request identity forwarded", cue?.captureID, intent.captureID)
            r.equal("generation forwarded", cue?.generation, intent.configurationGeneration)
            r.equal("no source is manufactured by a cue", request.recordedRepresentationCount, 0)
            _ = request.finishWith(mappedFailure: nil)
            r.check("late callback refused", !request.recordNativeShutter(settingsID: 42))
            if case .failed? = request.terminal.current { r.check("will-capture is not Saved", true) }
            else { r.check("will-capture is not Saved", false) }
        },
        TCCase(id: "SM35", title: "Focus and interval are exclusive shutter toggles and native source cues drive progress") { r in
            for mode in [SequenceShutterMode.focusBracket, .interval] {
                guard let storage = await StorageHarness.make(name: "sm35-\(mode)") else { r.check("fixture", false); continue }
                let h = SeqHarness(plannedCount: 3), camera = SyntheticCameraService(capability: controlFixture(modes: [.auto,.manual], generation: SeqTestSupport.configurationGeneration))
                let model = await CameraViewModel(camera: camera,
                    capture: CaptureCoordinator(camera: ChainCameraSpy(), store: storage.store, clock: SystemMonotonicClock()),
                    metering: MeteringService(clock: h.clock), clock: h.clock, preferences: SyntheticPreferenceStore(), levelFeed: SyntheticLevelFeed())
                await model.start(); await model.updateRootState(SeqTestSupport.writableRoot); await model.attach(sequence: h.coordinator)
                await MainActor.run { model.sequencePreferences.focusBracketCount = 3; model.sequencePreferences.intervalCount = 3 }
                await model.setExposureBracketEnabled(true); await model.setShutterMode(mode, enabled: true)
                r.equal("mode selection does not capture", await h.executor.submittedCount, 0)
                r.check("other mode is off", !(await model.isExposureBracketActive))
                r.equal("one selected mode", await model.activeShutterMode, mode)
                h.focusController.setSettlePlan([1, 1, 1])
                await h.executor.setBlocking(true); await model.activateShutter()
                _ = await driveVirtualClock(h.clock, maxSteps: 2_000) { await h.executor.blockedCount > 0 }
                guard let sequenceID = await model.activeSequenceID else {
                    let detail = await model.lastFailure?.detail
                    r.check("active run \(mode): \(detail ?? "no failure text")", false); await h.executor.release(); continue
                }
                let captureID = CaptureID()
                let cue = CaptureShutterFeedback(captureID: captureID, sequenceID: sequenceID, ordinal: 0, plannedCount: 3,
                    generation: SeqTestSupport.configurationGeneration, capturedAtUTC: Date())
                await model.receiveShutterFeedback(cue); await model.receiveShutterFeedback(cue)
                r.equal("one native source produces one pulse", await model.shutterPulse, 1)
                r.equal("frame counter is not final-result-only", await model.sequenceFrameOrdinal, 1)
                r.equal("frozen count shown", await model.sequencePlannedCount, 3)
                await model.receiveShutterFeedback(CaptureShutterFeedback(captureID: CaptureID(), sequenceID: SequenceID(), ordinal: 2,
                    plannedCount: 3, generation: SeqTestSupport.configurationGeneration, capturedAtUTC: Date()))
                r.equal("foreign sequence cannot flash", await model.shutterPulse, 1)
                await h.executor.release()
                _ = await driveVirtualClock(h.clock) { !(await model.isSequenceRunning) }
                r.equal("shutter executes configured mode", await h.executor.submittedCount, 3)
                r.check("next shutter remains armed", await model.activeShutterMode == mode)
                await model.setShutterMode(mode, enabled: false)
                r.equal("off returns to single shot", await model.activeShutterMode, .single)
                await model.handleCameraScreenCovered()
            }
        },
        TCCase(id: "BR34", title: "Bracket toggle arms only, repeated shutters and timer dispatch brackets with transient completion") { r in
            guard let storage = await StorageHarness.make(name: "br34-mode") else { r.check("fixture", false); return }
            let sequence = SeqHarness(plannedCount: 3)
            let native = ChainCameraSpy()
            let model = await CameraViewModel(camera: SyntheticCameraService(capability: controlFixture(modes: [.auto,.manual], generation: SeqTestSupport.configurationGeneration)),
                capture: CaptureCoordinator(camera: native, store: storage.store, clock: SystemMonotonicClock()),
                metering: MeteringService(clock: sequence.clock), clock: sequence.clock,
                preferences: SyntheticPreferenceStore(), levelFeed: SyntheticLevelFeed())
            await model.start(); await model.updateRootState(SeqTestSupport.writableRoot)
            await model.attach(sequence: sequence.coordinator)
            await model.setExposureBracketEnabled(true)
            r.equal("arming never submits a frame", await sequence.executor.submittedCount, 0)
            r.check("mode visibly armed", await model.isExposureBracketActive)
            for run in 1...2 {
                await model.activateShutter()
                r.check("sequence owns shutter", !(await model.isShutterEnabled))
                let complete = await driveVirtualClock(sequence.clock) { !(await model.isSequenceRunning) }
                r.check("sequence completes", complete)
                r.equal("each shutter dispatches three originals", await sequence.executor.submittedCount, run * 3)
                r.check("no stuck completion line", await model.sequenceStatusLine == nil)
                r.check("completion feedback is for a bracket", await model.lastCaptureWasExposureBracket)
                r.equal("receipt-driven feedback", await model.lastCommittedReceipts.count, 3)
                r.check("mode remains armed", await model.isExposureBracketActive)
            }
            await model.setTimerSeconds(3); await model.activateShutter()
            r.equal("countdown starts without submitting", await sequence.executor.submittedCount, 6)
            // This UI timer intentionally polls wall time but measures a monotonic
            // deadline. Drive its virtual deadline, then allow its real poll to wake.
            sequence.clock.advance(by: 3)
            let timerWake = ContinuousClock.now.advanced(by: .seconds(2))
            while await model.timerCountdownSeconds != nil, ContinuousClock.now < timerWake {
                try? await Task.sleep(for: .milliseconds(2))
            }
            _ = await driveVirtualClock(sequence.clock) {
                let count = await sequence.executor.submittedCount
                let running = await model.isSequenceRunning
                let timer = await model.timerCountdownSeconds
                return count == 9 && !running && timer == nil
            }
            r.equal("timer uses armed bracket", await sequence.executor.submittedCount, 9)
            await model.setExposureBracketEnabled(false)
            r.check("turning off returns to single mode", !(await model.isExposureBracketActive))
            r.equal("turning off never captures", native.attachCount, 0)
            await model.handleCameraScreenCovered()
        },
        TCCase(id:"PM01",title:"Unchanged photo preparation performs no native mutation; real changes commit before querying") { r in
            let operation=FinalTupleOperation()
            var calls:[String]=[]
            for _ in 0..<100 {
                FinalTupleOperation.configureIfNeeded(false,begin:{ calls.append("begin");operation.noteConfigurationOpened() },
                    commit:{ calls.append("commit");operation.noteConfigurationCommitted() },apply:{ calls.append("set") })
            }
            r.equal("no no-op native commits or setters",calls,[])
            r.equal("unchanged transaction remains current",operation.currentTransaction,0)
            FinalTupleOperation.configureIfNeeded(true,begin:{ calls.append("begin");operation.noteConfigurationOpened() },
                commit:{ calls.append("commit");operation.noteConfigurationCommitted() },apply:{
                    r.equal("real setters run inside configuration",operation.configurationDepth,1);calls.append("set")
                })
            calls.append("freshQuery")
            r.equal("selected facts follow the committed mutation",calls,["begin","set","commit","freshQuery"])
            r.equal("no open configuration at query",operation.configurationDepth,0)
            r.equal("real transaction changed",operation.currentTransaction,2)
        },
        TCCase(id:"PM02",title:"A failed native preparation setter still balances its commit and reports failure") { r in
            let operation=FinalTupleOperation()
            var commits=0, rejected=false
            do {
                try FinalTupleOperation.configureIfNeeded(true,begin:{ operation.noteConfigurationOpened() },
                    commit:{ commits+=1;operation.noteConfigurationCommitted() },apply:{
                        throw CaptureFailure(kind:.noCamera,operation:"synthetic failing setter")
                    })
            } catch { rejected=true }
            r.check("error is not swallowed",rejected)
            r.equal("single balanced commit",commits,1)
            r.equal("no configuration leaks after throw",operation.configurationDepth,0)
        },
        TCCase(id: "SR07", title: "Recovery and display polling cannot supersede an in-flight start") { r in
            guard let h = await StorageHarness.make(name: "sr07-start-recovery") else { r.check("fixture", false); return }
            let service = SyntheticCameraService(capability: controlFixture(modes: [.auto]))
            let model = await CameraViewModel(camera: service,
                capture: CaptureCoordinator(camera: ChainCameraSpy(), store: h.store, clock: SystemMonotonicClock()),
                metering: MeteringService(clock: SystemMonotonicClock()), preferences: SyntheticPreferenceStore(), levelFeed: SyntheticLevelFeed())
            await service.holdStart()
            let starting = Task { await model.start() }
            let deadline = ContinuousClock.now.advanced(by: .seconds(2))
            while await service.startRequests == 0, ContinuousClock.now < deadline { await Task.yield() }
            await service.recordCondition(.reconfiguring)
            await model.applyServiceCondition(.reconfiguring)
            await model.applyServiceCondition(.reconfiguring)
            for _ in 0..<10 { await model.refreshReadback() }
            await model.handleSceneBecameActive()
            await model.handleCameraScreenRevealed()
            await model.start()
            r.equal("only the original native start is pending", await service.startRequests, 1)
            r.equal("recovery cannot prepare over that start", await service.prepareRequests, 1)
            r.equal("recovery cannot issue controls during final validation", await service.controlApplyCount, 0)
            r.equal("live polling cannot publish during final validation", await service.readbackRequests, 0)
            r.check("capture remains closed", !(await model.runtimeAdmissionReady))
            await service.releaseStart()
            await starting.value
            r.equal("one deferred recovery after the owner drains", await service.startRequests, 2)
            r.equal("one prepare per owned start", await service.prepareRequests, 2)
            r.equal("controls restored once per start, after native validation", await service.controlApplyCount, 2)
            r.check("no superseded error", await model.lastFailure == nil)
            r.check("verified recovery opens admission", await model.runtimeAdmissionReady)
            await model.refreshReadback()
            r.check("ordinary live polling resumes", await service.readbackRequests > 2)
        },
        TCCase(id: "SR08", title: "Repeated recovery notifications share one start and preserve a real interruption") { r in
            guard let h = await StorageHarness.make(name: "sr08-recovery-owner") else { r.check("fixture", false); return }
            let service = SyntheticCameraService(capability: controlFixture(modes: [.auto]))
            let model = await CameraViewModel(camera: service,
                capture: CaptureCoordinator(camera: ChainCameraSpy(), store: h.store, clock: SystemMonotonicClock()),
                metering: MeteringService(clock: SystemMonotonicClock()), preferences: SyntheticPreferenceStore(), levelFeed: SyntheticLevelFeed())
            await model.start()
            await service.holdStart()
            let recovery = Task { await model.applyServiceCondition(.reconfiguring) }
            let deadline = ContinuousClock.now.advanced(by: .seconds(2))
            while await service.startRequests < 2, ContinuousClock.now < deadline { await Task.yield() }
            await model.applyServiceCondition(.reconfiguring)
            await model.applyServiceCondition(.reconfiguring)
            await model.refreshReadback()
            r.equal("duplicate recovery never overlaps the current start", await service.startRequests, 2)
            r.equal("no pre-start control application", await service.controlApplyCount, 1)
            await model.applyServiceCondition(.interrupted(reason: "new real interruption"))
            await service.releaseStart()
            await recovery.value
            r.equal("new interruption is not cleared by older recovery", await model.serviceRecordedCondition,
                .interrupted(reason: "new real interruption"))
            r.check("interrupted graph cannot capture", !(await model.runtimeAdmissionReady))
            await model.applyServiceCondition(.reconfiguring)
            r.equal("a later genuine ended event recovers once", await service.startRequests, 3)
            r.check("later recovery reopens admission", await model.runtimeAdmissionReady)
        },
        TCCase(id: "PM03", title: "Missing layout pauses processing without cycling enabled analysis topology") { r in
            let enabled = PreviewAidConfiguration.default
            let geometry = PreviewGeometrySnapshot(configurationGeneration: ConfigurationGeneration(3), layoutGeneration: 9,
                imageDimensions: PixelDimensions(width: 4000, height: 3000), cleanApertureDimensions: nil,
                previewLayerContentRect: TCRect(x: 0, y: 0, width: 300, height: 400), bufferOrientation: 1,
                isMirrored: false, analysisRotationDegrees: 0, isVideoMirrored: false, capturedAtUTC: Date())
            let laidOut = AnalysisDemandPolicy.decide(configuration: enabled, lifecycle: .activeCameraView, geometry: geometry)
            let waiting = AnalysisDemandPolicy.decide(configuration: enabled, lifecycle: .activeCameraView, geometry: nil)
            r.check("enabled tools reserve the native output", waiting.wantsVideoOutput)
            r.equal("layout changes do not change topology demand", waiting.demand, laidOut.demand)
            r.check("no frames can be processed without layout", waiting.request == nil && !waiting.isAnalysisActive)
            r.check("fresh layout enables a correlated request", laidOut.request?.geometry == geometry)
            let inactive = AnalysisDemandPolicy.decide(configuration: enabled, lifecycle: .sceneInactive, geometry: nil)
            r.check("inactive lifecycle still releases output", !inactive.wantsVideoOutput && inactive.request == nil)
            let modelService = SyntheticCameraService(capability: controlFixture(modes: [.auto]))
            await modelService.configureFacingFixtures([
                .ultraWide: controlFixture(modes: [.auto], kind: .ultraWide, generation: ConfigurationGeneration(1)),
                .wide: controlFixture(modes: [.auto], kind: .wide, generation: ConfigurationGeneration(2))])
            guard let h = await StorageHarness.make(name: "pm03-topology") else { r.check("fixture", false); return }
            let model = await CameraViewModel(camera: modelService,
                capture: CaptureCoordinator(camera: ChainCameraSpy(), store: h.store, clock: SystemMonotonicClock()),
                metering: MeteringService(clock: SystemMonotonicClock()), preferences: SyntheticPreferenceStore(), levelFeed: SyntheticLevelFeed())
            await model.start()
            await model.selectLens(.ultraWide)
            await model.selectLens(.wide)
            let demands = await modelService.analysisDemands
            r.check("model sent demand through startup and two switches", demands.count >= 3)
            r.check("no geometry-induced detach at any switch", demands.allSatisfy(\.wantsVideoOutput))
            r.check("requests stay nil until a real layout arrives", await modelService.analysisRequests.allSatisfy { $0 == nil })
            let failedService = SyntheticCameraService(preparationFailure: CaptureFailure(kind: .noCamera, operation: "synthetic prepare"))
            let failedModel = await CameraViewModel(camera: failedService,
                capture: CaptureCoordinator(camera: ChainCameraSpy(), store: h.store, clock: SystemMonotonicClock()),
                metering: MeteringService(clock: SystemMonotonicClock()), preferences: SyntheticPreferenceStore(), levelFeed: SyntheticLevelFeed())
            await failedModel.start()
            await failedModel.updateAnalysisDemand()
            r.check("failed preparation releases its initial output reservation", await failedService.analysisDemands.last?.wantsVideoOutput == false)
            r.check("failed camera cannot process aid frames", await failedService.analysisRequests.allSatisfy { $0 == nil })
        },
        TCCase(id: "PM04", title: "Owned startup reserves enabled analysis before native start without processing unlaid-out frames") { r in
            guard let h = await StorageHarness.make(name: "pm04-start-analysis") else { r.check("fixture", false); return }
            let service = SyntheticCameraService(capability: controlFixture(modes: [.auto]))
            let model = await CameraViewModel(camera: service,
                capture: CaptureCoordinator(camera: ChainCameraSpy(), store: h.store, clock: SystemMonotonicClock()),
                metering: MeteringService(clock: SystemMonotonicClock()), preferences: SyntheticPreferenceStore(), levelFeed: SyntheticLevelFeed())
            await service.holdStart()
            let starting = Task { await model.start() }
            let deadline = ContinuousClock.now.advanced(by: .seconds(2))
            while await service.startRequests == 0, ContinuousClock.now < deadline { await Task.yield() }
            r.equal("one native preparation", await service.prepareRequests, 1)
            r.equal("one owned native start pending", await service.startRequests, 1)
            let reserved = await service.analysisDemands
            r.check("enabled output reserved before native start completes", reserved.first?.wantsVideoOutput == true)
            r.check("no unlaid-out analysis request is admitted", await service.analysisRequests.allSatisfy { $0 == nil })
            r.check("shutter stays closed while native startup waits", !(await model.runtimeAdmissionReady))
            await model.handleSceneBecameInactive()
            await service.releaseStart()
            await starting.value
            r.check("ineligible completion cannot reopen capture", !(await model.runtimeAdmissionReady))
            r.check("background retains no processing request", await service.analysisRequests.allSatisfy { $0 == nil })
            r.equal("background does not cause another start", await service.startRequests, 1)
        },
        TCCase(id: "PM05", title: "Warm ceiling setter plan requires unchanged native identities, topology and complete dimensions") { r in
            let small = PixelDimensions(width: 4000, height: 3000)
            let large = PixelDimensions(width: 8000, height: 6000)
            let matrix = [[small], [small, large]]
            let cached = WarmPhotoCeilingEvidence(deviceIdentity: "device-a", formatIdentity: "native-format-a",
                analysisOutputAttached: true, candidateDimensions: matrix, ceiling: large)
            func plan(device: String = "device-a", format: String = "native-format-a", analysis: Bool = true,
                      candidates: [[PixelDimensions]]? = nil,
                      active: [PixelDimensions]? = nil) -> PixelDimensions? {
                cached.plannedCeiling(deviceIdentity: device, formatIdentity: format,
                    analysisOutputAttached: analysis, candidateDimensions: candidates ?? matrix,
                    currentFormatDimensions: active ?? [small, large])
            }
            r.equal("exact current evidence permits the legal setter", plan(), large)
            r.check("another device cannot borrow ceiling evidence", plan(device: "device-b") == nil)
            r.check("another native format invalidates cache", plan(format: "native-format-b") == nil)
            r.check("changed output topology invalidates cache", plan(analysis: false) == nil)
            r.check("current format must explicitly support setter", plan(active: [small]) == nil)
            r.check("newly larger format forces fresh selection", plan(candidates: matrix + [[PixelDimensions(width: 9000, height: 7000)]]) == nil)
            r.check("removed format forces fresh selection", plan(candidates: [[small]]) == nil)
            let staleLower = WarmPhotoCeilingEvidence(deviceIdentity: "device-a", formatIdentity: "native-format-a",
                analysisOutputAttached: true, candidateDimensions: matrix, ceiling: small)
            r.check("unchanged lower cached ceiling cannot mask highest resolution",
                staleLower.plannedCeiling(deviceIdentity: "device-a", formatIdentity: "native-format-a",
                    analysisOutputAttached: true, candidateDimensions: matrix, currentFormatDimensions: [small, large]) == nil)
            var commits = 0
            let operation = FinalTupleOperation()
            FinalTupleOperation.configureIfNeeded(plan() != nil, begin: { operation.noteConfigurationOpened() },
                commit: { commits += 1; operation.noteConfigurationCommitted() }) {
                    r.equal("cached hint only applies inside input-swap configuration", operation.configurationDepth, 1)
                }
            r.equal("one balanced setter commit", commits, 1)
            r.equal("subsequent final RAW query remains outside config", operation.configurationDepth, 0)
            r.equal("cached ceiling never authorizes missing native Bayer",
                FinalTupleValidation.validate(finalBayerFormats: [], finalFileTypes: ["com.adobe.raw-image"],
                    candidateFileTypes: ["com.adobe.raw-image"]), .rejectNoBayerRAW)
        },
        TCCase(id: "PM08", title: "Fresh first-visit ceiling reservation requires the complete native maximum on the current format") { r in
            let small = PixelDimensions(width: 4000, height: 3000)
            let large = PixelDimensions(width: 8000, height: 6000)
            let matrix = [[small], [small, large]]
            func plan(_ candidates: [[PixelDimensions]], _ active: [PixelDimensions]) -> PixelDimensions? {
                FreshPhotoCeilingReservation.plannedCeiling(candidateDimensions: candidates,
                    currentFormatDimensions: active)
            }
            r.equal("first-visit current format can reserve complete maximum", plan(matrix, [small, large]), large)
            r.equal("duplicate native dimensions do not create ambiguity", plan(matrix + [[large]], [large]), large)
            r.equal("formats without photo dimensions may coexist", plan([[]] + matrix, [small, large]), large)
            r.equal("a lower current format uses committed discovery", plan(matrix, [small]), nil)
            r.equal("missing native matrix refuses", plan([], [large]), nil)
            r.equal("missing current format dimensions refuses", plan(matrix, []), nil)
            r.equal("all-empty native advertisement refuses", plan([[]], []), nil)
            r.equal("current format missing from matrix refuses", plan(matrix, [large]), nil)
            let larger = PixelDimensions(width: 9000, height: 7000)
            r.equal("freshly larger other format prevents old ceiling", plan(matrix + [[larger]], [small, large]), nil)
            r.equal("changed current dimensions cannot borrow previous matrix", plan(matrix, [small, larger]), nil)
            r.equal("fresh changed maximum can be legally reserved", plan([[small], [small, larger]], [small, larger]), larger)
            r.equal("equal-area differently shaped maxima use committed selection",
                plan(matrix + [[PixelDimensions(width: 6000, height: 8000)]], [small, large]), nil)
            for invalid in [PixelDimensions(width: 0, height: 6000), PixelDimensions(width: -1, height: 6000),
                            PixelDimensions(width: Int(Int32.max) + 1, height: 1),
                            PixelDimensions(width: Int.max, height: Int.max)] {
                r.equal("invalid native dimension cannot be silently ignored", plan(matrix + [[invalid]], [small, large]), nil)
                r.equal("invalid current dimension refuses before native setter", plan(matrix + [[invalid]], [invalid]), nil)
            }
            let boundary = PixelDimensions(width: Int(Int32.max), height: Int(Int32.max))
            r.equal("CMVideoDimensions maximum computes without overflow", plan([[boundary]], [boundary]), boundary)
            // This plan never inspects or publishes Bayer capability. Even a
            // valid reservation must still fail the shipping final native query
            // if the committed graph exposes no Bayer RAW for DNG.
            r.equal("a passive legal ceiling does not authorize RAW capture",
                FinalTupleValidation.validate(finalBayerFormats: [], finalFileTypes: ["com.adobe.raw-image"],
                    candidateFileTypes: ["com.adobe.raw-image"]), .rejectNoBayerRAW)
        },
        TCCase(id: "PM06", title: "Shared preparation co-commits actual output differences and leaves no redundant start fallback") { r in
            var state = CapturePipelinePreparation.OutputState(photoDeferred: true, videoDeferred: true,
                speedPrioritization: false, responsiveSupported: true, responsiveEnabled: true,
                zeroLagSupported: true, zeroLagEnabled: true, deferredDeliverySupported: true,
                deferredDeliveryEnabled: true, discardsLateFrames: false)
            let operation = FinalTupleOperation()
            var commits = 0, calls: [CapturePipelinePreparation.OutputChange] = []
            func apply(_ change: CapturePipelinePreparation.OutputChange) {
                r.equal("pipeline setters stay inside the already-owned commit", operation.configurationDepth, 1)
                calls.append(change)
                switch change {
                case .disablePhotoDeferred: state.photoDeferred = false
                case .disableVideoDeferred: state.videoDeferred = false
                case .prioritizeSpeed: state.speedPrioritization = true
                case .disableResponsive: state.responsiveEnabled = false
                case .disableZeroLag: state.zeroLagEnabled = false
                case .disableDeferredDelivery: state.deferredDeliveryEnabled = false
                case .discardLateFrames: state.discardsLateFrames = true
                }
            }
            // The actual input swap already needs a commit; both preparation
            // and start use this same shared current-state plan.
            FinalTupleOperation.configureIfNeeded(true, begin: { operation.noteConfigurationOpened() },
                commit: { commits += 1; operation.noteConfigurationCommitted() }) {
                CapturePipelinePreparation.applyOutputChanges(CapturePipelinePreparation.outputChanges(state),
                    isCurrent: { true }, set: apply)
            }
            let preparedCalls = calls
            for _ in 0..<100 {
                let fallback = CapturePipelinePreparation.outputChanges(state)
                FinalTupleOperation.configureIfNeeded(!fallback.isEmpty, begin: { operation.noteConfigurationOpened() },
                    commit: { commits += 1; operation.noteConfigurationCommitted() }) {
                    CapturePipelinePreparation.applyOutputChanges(fallback, isCurrent: { true }, set: apply)
                }
            }
            r.equal("one swap commit with no late fallback commit", commits, 1)
            r.equal("no repeated native setters after preparation", calls, preparedCalls)
            r.equal("all seven actual changes applied once", calls.count, 7)
            r.equal("responsive disabled before its ZSL prerequisite", Array(calls[3...4]), [.disableResponsive, .disableZeroLag])
            // Framework postcommit defaults may differ; the defensive start
            // fallback must still act on those fresh facts, never a warm cache.
            state.zeroLagEnabled = true
            r.equal("a newly enabled option is still detected", CapturePipelinePreparation.outputChanges(state), [.disableZeroLag])
            var current = false, staleCalls = 0
            let stale = CapturePipelinePreparation.applyOutputChanges([.disableZeroLag], isCurrent: { current }, set: { _ in staleCalls += 1 })
            r.check("obsolete owner cannot normalize a replacement graph", !stale)
            r.equal("no stale native setter", staleCalls, 0)
            current = true
            let interrupted = CapturePipelinePreparation.applyOutputChanges([.disablePhotoDeferred, .disableVideoDeferred],
                isCurrent: { current }, set: { _ in staleCalls += 1; current = false })
            r.check("ownership is checked between mutations", !interrupted)
            r.equal("no second setter after supersession", staleCalls, 1)
            let unsupported = CapturePipelinePreparation.OutputState(responsiveEnabled: true, zeroLagEnabled: true,
                deferredDeliveryEnabled: true)
            r.equal("unsupported native options are never set", CapturePipelinePreparation.outputChanges(unsupported), [])
        },
        TCCase(id: "PM07", title: "Incoming front analysis connection is unmirrored once in legal order and replacement connections are rechecked") { r in
            var state = CapturePipelinePreparation.AnalysisConnectionState(mirrorsSupported: true,
                automaticMirroring: true, mirrored: true, zeroRotationSupported: true, rotationDegrees: 90)
            var calls: [CapturePipelinePreparation.AnalysisConnectionChange] = []
            func set(_ change: CapturePipelinePreparation.AnalysisConnectionChange) {
                calls.append(change)
                switch change {
                case .disableAutomaticMirroring: state.automaticMirroring = false
                case .disableMirroring:
                    r.check("manual mirroring setter has its native precondition", !state.automaticMirroring)
                    state.mirrored = false
                case .zeroRotation: state.rotationDegrees = 0
                }
            }
            CapturePipelinePreparation.applyAnalysisConnectionChanges(
                CapturePipelinePreparation.analysisConnectionChanges(state), isCurrent: { true }, set: set)
            r.equal("front defaults normalized in native setter order", calls,
                [.disableAutomaticMirroring, .disableMirroring, .zeroRotation])
            for _ in 0..<100 {
                CapturePipelinePreparation.applyAnalysisConnectionChanges(
                    CapturePipelinePreparation.analysisConnectionChanges(state), isCurrent: { true }, set: set)
            }
            r.equal("stable connection incurs no setters on geometry/demand updates", calls.count, 3)
            state.automaticMirroring = true; state.mirrored = true
            CapturePipelinePreparation.applyAnalysisConnectionChanges(
                CapturePipelinePreparation.analysisConnectionChanges(state), isCurrent: { true }, set: set)
            r.equal("new input connection gets fresh normalization", Array(calls.suffix(2)), [.disableAutomaticMirroring, .disableMirroring])
            let unsupported = CapturePipelinePreparation.AnalysisConnectionState(automaticMirroring: true,
                mirrored: true, rotationDegrees: 90)
            r.equal("unsupported setters are excluded", CapturePipelinePreparation.analysisConnectionChanges(unsupported), [])
            let previousCount = calls.count
            let refused = CapturePipelinePreparation.applyAnalysisConnectionChanges([.disableMirroring],
                isCurrent: { false }, set: set)
            r.check("obsolete connection work refuses", !refused)
            r.equal("new connection untouched by old owner", calls.count, previousCount)
            let photo = CapturePipelinePreparation.AnalysisConnectionState(mirrorsSupported: true,
                automaticMirroring: true, mirrored: true, zeroRotationSupported: false, rotationDegrees: 270)
            r.equal("original normalization never resets frozen photo rotation",
                CapturePipelinePreparation.analysisConnectionChanges(photo), [.disableAutomaticMirroring, .disableMirroring])
        },
        TCCase(id:"EM01",title:"Marked light meter preserves real EV direction, thirds, clipping and unknown observations") { r in
            r.equal("nineteen third-stop marks",ExposureMeterScale.thirds.count,19)
            r.equal("zero mark exists once",ExposureMeterScale.thirds.filter { $0 == 0 }.count,1)
            r.equal("seven whole-stop marks",ExposureMeterScale.thirds.filter { $0%3 == 0 }.count,7)
            r.equal("zero in middle",ExposureMeterScale.unitPosition(0),0.5)
            r.equal("positive EV toward top",ExposureMeterScale.unitPosition(3),0)
            r.equal("negative EV toward bottom",ExposureMeterScale.unitPosition(-3),1)
            r.equal("over-range pointer bounded",ExposureMeterScale.unitPosition(100),0)
            r.check("overflow disclosed",ExposureMeterScale.isClipped(-4))
            r.check("endpoint is not overflow",!ExposureMeterScale.isClipped(3))
            r.equal("unknown has no pointer",ExposureMeterScale.unitPosition(nil),nil)
            r.equal("NaN has no pointer",ExposureMeterScale.unitPosition(.nan),nil)
            r.equal("infinity has no pointer",ExposureMeterScale.unitPosition(.infinity),nil)
        },
        TCCase(id: "SR05", title: "Front/rear sensor angles and mirroring never choose the physical level axes") { r in
            guard let h = await StorageHarness.make(name: "sr05-level-screen") else { r.check("fixture", false); return }
            let service = SyntheticCameraService(capability: controlFixture(modes: [.auto], kind: .front))
            let model = await CameraViewModel(camera: service,
                capture: CaptureCoordinator(camera: ChainCameraSpy(), store: h.store, clock: SystemMonotonicClock()),
                metering: MeteringService(clock: SystemMonotonicClock()), preferences: SyntheticPreferenceStore(), levelFeed: SyntheticLevelFeed())
            await model.start()
            await MainActor.run { model.composition.levelEnabled = true; model.startLevelFeed() }
            let fixtures: [(DeviceOrientation, GravityReading)] = [(.portrait, GravityReading(x:0,y:-1,z:0)),
                (.portraitUpsideDown, GravityReading(x:0,y:1,z:0)), (.landscapeLeft, GravityReading(x:-1,y:0,z:0)),
                (.landscapeRight, GravityReading(x:1,y:0,z:0))]
            var layout: UInt64 = 0
            for (orientation, gravity) in fixtures {
                // Deliberately unrelated front/rear native rotations. Screen axes
                // must win for the actual model, not only LevelService in isolation.
                for rotation in [0, 90, 180, 270] {
                    layout += 1
                    await model.updateLevel(gravity:nil)
                    await model.updateGeometry(PreviewGeometrySnapshot(configurationGeneration:.zero, layoutGeneration:layout,
                        imageDimensions:PixelDimensions(width:4000,height:3000),cleanApertureDimensions:nil,
                        previewLayerContentRect:TCRect(x:0,y:0,width:300,height:400),bufferOrientation:1,
                        isMirrored:rotation % 180 == 0,analysisRotationDegrees:rotation,isVideoMirrored:true,
                        capturedAtUTC:Date(),interfaceOrientation:orientation))
                    await model.updateLevel(gravity:gravity)
                    r.equal("screen axes survive sensor rotation \(rotation)", await model.levelState?.orientation, orientation)
                    r.close("horizontal remains zero", await model.levelState?.rollDegrees ?? 999, 0, tolerance:0.001)
                }
            }
        },
        TCCase(id: "SR06", title: "Switch cover remains until current-camera geometry and render acknowledgement; stale callbacks cannot reveal it") { r in
            guard let h = await StorageHarness.make(name:"sr06-switch-cover") else { r.check("fixture",false); return }
            let service = SyntheticCameraService(capability:controlFixture(modes:[.auto]))
            await service.configureFacingFixtures([.front:controlFixture(modes:[.auto],kind:.front,generation:ConfigurationGeneration(1))])
            await service.installDisplaySession(AVCaptureSession())
            let model = await CameraViewModel(camera:service,capture:CaptureCoordinator(camera:ChainCameraSpy(),store:h.store,clock:SystemMonotonicClock()),
                metering:MeteringService(clock:SystemMonotonicClock()),preferences:SyntheticPreferenceStore(),levelFeed:SyntheticLevelFeed())
            await model.start()
            r.check("initial frame required before first lens switch", !(await model.canSwitchCamera))
            await model.updateGeometry(PreviewGeometrySnapshot(configurationGeneration:.zero,layoutGeneration:7,
                imageDimensions:PixelDimensions(width:4000,height:3000),cleanApertureDimensions:nil,
                previewLayerContentRect:TCRect(x:0,y:0,width:300,height:400),bufferOrientation:1,isMirrored:false,
                analysisRotationDegrees:90,isVideoMirrored:false,capturedAtUTC:Date(),interfaceOrientation:.portrait))
            r.check("initial render admits switching", await model.previewDidResume(generation:.zero,layout:7))
            await model.rotateCamera()
            r.check("native completion alone keeps cover",await model.isPreviewTransitionVisible)
            r.check("rapid next switch refused before incoming frame", !(await model.canSwitchCamera))
            await model.rotateCamera()
            r.equal("rapid tap never reconfigures another lens", await model.capability.selectedCameraKind, .front)
            r.check("old camera cannot uncover",!(await model.previewDidResume(generation:.zero,layout:7)))
            await model.updateGeometry(PreviewGeometrySnapshot(configurationGeneration:ConfigurationGeneration(1),layoutGeneration:8,
                imageDimensions:PixelDimensions(width:4000,height:3000),cleanApertureDimensions:nil,
                previewLayerContentRect:TCRect(x:0,y:0,width:300,height:400),bufferOrientation:1,isMirrored:true,
                analysisRotationDegrees:270,isVideoMirrored:true,capturedAtUTC:Date(),interfaceOrientation:.portrait))
            r.check("old layout cannot uncover",!(await model.previewDidResume(generation:ConfigurationGeneration(1),layout:7)))
            r.check("correct rendering acknowledgement releases cover",await model.previewDidResume(generation:ConfigurationGeneration(1),layout:8))
            r.check("cover dismissed",!(await model.isPreviewTransitionVisible))
        },
        TCCase(id: "SR01", title: "A switch owns startup across stop notifications, graph publication and duplicate scene/view callbacks") { r in
            guard let h = await StorageHarness.make(name: "sr01-switch-owner") else { r.check("fixture", false); return }
            let service = SyntheticCameraService(capability: controlFixture(modes: [.auto,.manual]))
            await service.configureFacingFixtures([.front: controlFixture(modes: [.auto], kind: .front, generation: ConfigurationGeneration(1))])
            let model = await CameraViewModel(camera: service,
                capture: CaptureCoordinator(camera: ChainCameraSpy(), store: h.store, clock: SystemMonotonicClock()),
                metering: MeteringService(clock: SystemMonotonicClock()), preferences: SyntheticPreferenceStore(), levelFeed: SyntheticLevelFeed())
            await model.start()
            let identity = await model.graphIdentity
            await service.configureSwitch(failures: [], delay: .milliseconds(100))
            await service.configureStartDelay(.milliseconds(100))
            let baselineDemand = await service.analysisDemands.count
            let change = Task { await model.rotateCamera() }
            let deadline = ContinuousClock.now.advanced(by: .seconds(2))
            while !(await model.isSwitchingLens), ContinuousClock.now < deadline { await Task.yield() }
            await model.applyServiceCondition(.stopping)
            r.equal("native stopped state remains observable while the switch owns startup", await model.effectiveLifecycle, .idle)
            // effective native state can be stopped; the explicit switch owner
            // must fence both guarded and direct startup entry points anyway.
            await model.handleSceneBecameActive()
            await model.handleCameraScreenRevealed()
            await model.startIfNeeded()
            await model.start()
            await model.updateAnalysisDemand()
            r.equal("no second prepare while switching", await service.prepareRequests, 1)
            r.equal("UI demand cannot mutate rebuilding graph", await service.analysisDemands.count, baselineDemand)
            r.check("capture closed during switch", !(await model.runtimeAdmissionReady))
            let nativeStartDeadline = ContinuousClock.now.advanced(by: .seconds(2))
            while await service.startRequests < 2, ContinuousClock.now < nativeStartDeadline { await Task.yield() }
            r.equal("new generation published before held native start", await model.capability.generation, ConfigurationGeneration(1))
            await model.applyServiceCondition(.stopping)
            await model.handleSceneBecameActive()
            await model.handleCameraScreenRevealed()
            await model.startIfNeeded()
            r.equal("generation-replay callbacks cannot supersede the held native start", await service.startRequests, 2)
            r.equal("generation replay cannot rebuild the input", await service.prepareRequests, 1)
            r.check("admission remains closed through held native start", !(await model.runtimeAdmissionReady))
            await change.value
            r.equal("exactly one native start for switch", await service.startRequests, 2)
            r.equal("front generation published", await model.capability.generation, ConfigurationGeneration(1))
            r.equal("config generation is not installation identity", await model.graphIdentity, identity)
            r.equal("front owns stable preview", await model.capability.selectedCameraKind, .front)
            r.check("current owner reopens admission", await model.runtimeAdmissionReady)
            r.check("stable view enabled after switch", await model.isPreviewConnectionStable)
            r.check("no superseded-start surface", await model.lastFailure == nil)
        },
        TCCase(id: "SR02", title: "A real cover/reveal cancels a held switch and restarts only after it drains") { r in
            guard let h = await StorageHarness.make(name: "sr02-switch-cover") else { r.check("fixture", false); return }
            let service = SyntheticCameraService(capability: controlFixture(modes: [.auto]))
            await service.configureFacingFixtures([.front: controlFixture(modes: [.auto], kind: .front, generation: ConfigurationGeneration(1))])
            let model = await CameraViewModel(camera: service,
                capture: CaptureCoordinator(camera: ChainCameraSpy(), store: h.store, clock: SystemMonotonicClock()),
                metering: MeteringService(clock: SystemMonotonicClock()), preferences: SyntheticPreferenceStore(), levelFeed: SyntheticLevelFeed())
            await model.start()
            await service.holdSwitch()
            let change = Task { await model.rotateCamera() }
            let deadline = ContinuousClock.now.advanced(by: .seconds(2))
            while await service.switchRequests.isEmpty, ContinuousClock.now < deadline { await Task.yield() }
            await model.handleCameraScreenCovered()
            r.check("covered preview disabled", !(await model.isPreviewConnectionStable))
            await model.handleCameraScreenRevealed()
            r.equal("reveal does not overlap old switch", await service.prepareRequests, 1)
            await service.releaseSwitch()
            await change.value
            let resumed = ContinuousClock.now.advanced(by: .seconds(2))
            while !(await model.runtimeAdmissionReady), ContinuousClock.now < resumed { await Task.yield() }
            r.check("current eligible camera eventually resumes", await model.runtimeAdmissionReady)
            r.equal("one owned restart after stale switch drains", await service.prepareRequests, 2)
            r.equal("new startup succeeds", await model.surface, .ready)
        },
        TCCase(id: "SR03", title: "A genuine interruption during switching cannot reopen capture and its ended event recovers") { r in
            guard let h = await StorageHarness.make(name: "sr03-real-interruption") else { r.check("fixture", false); return }
            let service = SyntheticCameraService(capability: controlFixture(modes: [.auto]))
            let model = await CameraViewModel(camera: service,
                capture: CaptureCoordinator(camera: ChainCameraSpy(), store: h.store, clock: SystemMonotonicClock()),
                metering: MeteringService(clock: SystemMonotonicClock()), preferences: SyntheticPreferenceStore(), levelFeed: SyntheticLevelFeed())
            await model.start()
            await service.configureSwitch(failures: [], delay: .milliseconds(60))
            let change = Task { await model.selectLens(.ultraWide) }
            let deadline = ContinuousClock.now.advanced(by: .seconds(2))
            while !(await model.isSwitchingLens), ContinuousClock.now < deadline { await Task.yield() }
            await model.applyServiceCondition(.interrupted(reason: "real synthetic interruption"))
            await change.value
            r.check("genuine interruption remains authoritative", !(await model.runtimeAdmissionReady))
            r.check("untrusted preview stays paused", !(await model.isPreviewConnectionStable))
            await model.applyServiceCondition(.reconfiguring)
            r.check("ended interruption recovers admission", await model.runtimeAdmissionReady)
            r.equal("recovery remains a usable surface", await model.surface, .ready)
        },
        TCCase(id: "SR04", title: "A displayed camera cannot capture using old-camera geometry; fresh geometry releases it") { r in
            guard let h = await StorageHarness.make(name: "sr04-geometry") else { r.check("fixture", false); return }
            let service = SyntheticCameraService(capability: controlFixture(modes: [.auto], generation: ConfigurationGeneration(3)))
            await service.installDisplaySession(AVCaptureSession())
            let model = await CameraViewModel(camera: service,
                capture: CaptureCoordinator(camera: ChainCameraSpy(), store: h.store, clock: SystemMonotonicClock()),
                metering: MeteringService(clock: SystemMonotonicClock()), preferences: SyntheticPreferenceStore(), levelFeed: SyntheticLevelFeed())
            await model.updateRootState(.writable(libraryID: h.libraryID, generation: h.generation))
            await model.start()
            r.check("physical display waits for own connection geometry", !(await model.isShutterEnabled))
            func geometry(_ generation: ConfigurationGeneration) -> PreviewGeometrySnapshot {
                PreviewGeometrySnapshot(configurationGeneration: generation, layoutGeneration: 8,
                    imageDimensions: PixelDimensions(width: 4000,height: 3000), cleanApertureDimensions: nil,
                    previewLayerContentRect: TCRect(x: 0,y: 0,width: 300,height: 400), bufferOrientation: 1,
                    isMirrored: true, analysisRotationDegrees: 270, isVideoMirrored: true, capturedAtUTC: Date())
            }
            await model.updateGeometry(geometry(ConfigurationGeneration(2)))
            await Task.yield()
            r.equal("old camera layout does not reach native geometry", await service.previewGeometries.count, 0)
            r.check("old layout cannot admit shutter", !(await model.isShutterEnabled))
            await model.updateGeometry(geometry(ConfigurationGeneration(3)))
            let deadline = ContinuousClock.now.advanced(by: .seconds(2))
            while await service.previewGeometries.isEmpty, ContinuousClock.now < deadline { await Task.yield() }
            r.check("fresh camera layout admits shutter", await model.isShutterEnabled)
            let forwarded = await service.previewGeometries.compactMap { $0 }.last
            r.equal("fresh camera rotation forwarded", forwarded?.analysisRotationDegrees, 270)
        },
        TCCase(id: "FC04", title: "Front switch, failed return and reopen retain truthful mode and freeze capture during transitions") { r in
            guard let h = await StorageHarness.make(name: "fc04-facing") else { r.check("fixture", false); return }
            let rear = controlFixture(modes: [.auto,.manual]), front = controlFixture(modes: [.auto], kind: .front, heif: true)
            let service = SyntheticCameraService(capability: rear)
            await service.configureFacingFixtures([.front:front,.wide:rear])
            let model = await CameraViewModel(camera: service,
                capture: CaptureCoordinator(camera: ChainCameraSpy(), store: h.store, clock: SystemMonotonicClock()),
                metering: MeteringService(clock: SystemMonotonicClock()), preferences: SyntheticPreferenceStore(), levelFeed: SyntheticLevelFeed())
            await model.start()
            await service.configureSwitch(failures: [], delay: .milliseconds(40))
            let change = Task { await model.rotateCamera() }
            while !(await model.isSwitchingLens) { try? await Task.sleep(for: .milliseconds(1)) }
            r.check("switch closes admission", !(await model.runtimeAdmissionReady))
            await model.rotateCamera()
            await change.value
            r.equal("one switch", await service.switchRequests, [.front])
            r.equal("front identity", await model.capability.selectedCameraKind, .front)
            r.equal("HEIF label", await model.captureFormatLabel, "HEIF · Front")
            r.equal("no rear lens chips in front", await model.lensButtons.count, 0)
            r.check("HEIF never advertises Bayer", await model.capability.bayerCaptureSupported.value != true)
            r.check("front can return", await model.canSwitchCamera)
            await model.rotateCamera()
            r.equal("rear restored", await model.capability.selectedCameraKind, .wide)
            r.check("rear RAW label", await model.captureFormatLabel.hasPrefix("RAW"))
            await service.configureSwitch(failures: [.front], delay: .zero)
            await model.rotateCamera()
            r.equal("failed front restores rear", await model.capability.selectedCameraKind, .wide)
            r.equal("failing request followed by prior-camera repair", Array(await service.switchRequests.suffix(2)), [.front,.wide])
            await model.handleCameraScreenCovered()
            await model.handleCameraScreenRevealed()
            r.equal("reopen preserves selected rear", await model.capability.selectedCameraKind, .wide)
        },
        TCCase(id: "UX15", title: "Successful held startup reopens the exact lifecycle gate before the first real capture") { r in
            guard let h = await StorageHarness.make(name:"ux15-first-admission") else { r.check("fixture",false); return }
            let native=ChainCameraSpy()
            let captureCamera=ResponsiveAutoCamera(native:native,liveAcknowledgement:true)
            let service=SyntheticCameraService(capability:controlFixture(modes:[.auto,.manual]))
            await service.configureControlDelay(.milliseconds(150))
            let capture=CaptureCoordinator(camera:captureCamera,store:h.store,clock:SystemMonotonicClock())
            let model=await CameraViewModel(camera:service,capture:capture,metering:MeteringService(clock:SystemMonotonicClock()),levelFeed:SyntheticLevelFeed())
            await model.updateRootState(.writable(libraryID:h.libraryID,generation:h.generation))
            let startup=Task { await model.start() }
            while await service.controlApplyCount == 0 { await Task.yield() }
            // Native start has completed, but controls are still held. A duplicate
            // foreground callback must not open admission in this intermediate state.
            await service.recordCondition(.running)
            await model.handleSceneBecameActive()
            r.check("shutter not ready during start", !(await model.runtimeAdmissionReady))
            r.check("downstream gate also closed", !(await capture.canAdmitCapture()))
            // A late close from the same permission/scene transition reaches the
            // coordinator while the initial CameraScreen task still owns startup.
            await capture.setLifecycleAdmission(isOpen:false,revision:1)
            await startup.value
            r.check("start completion publishes ready admission", await model.runtimeAdmissionReady)
            r.check("downstream gate reopened by the start owner", await capture.canAdmitCapture())
            let first=Task { await capture.capture(intent:responsiveIntent(h:h)) }
            let spy=native
            let deadline=ContinuousClock.now.advanced(by:.seconds(2))
            while spy.attachCount == 0,ContinuousClock.now < deadline { try? await Task.sleep(for:.milliseconds(1)) }
            r.equal("first request reaches native capture",spy.attachCount,1)
            if let ticket=spy.lastCreatedTicket {
                ticket.deliverRepresentation(bytes:StorageFixture.rawBytes(),dimensions:PixelDimensions(width:4032,height:3024));ticket.deliver(.success)
            } else { first.cancel() }
            let result=await first.value
            r.equal("first request verifies one commit",result.committedReceipts.count,1)
            r.check("no false previous-native popup",result.failures.isEmpty)
            await model.handleCameraScreenCovered()
        },
        TCCase(id:"UX16",title:"Lifecycle revisions reject stale close/open without clearing a genuine native fence") { r in
            guard let h=await StorageHarness.make(name:"ux16-admission-owner") else { r.check("fixture",false);return }
            let capture=CaptureCoordinator(camera:ChainCameraSpy(),store:h.store,clock:SystemMonotonicClock())
            await capture.setLifecycleAdmission(isOpen:false,revision:10)
            r.check("closed",!(await capture.canAdmitCapture()))
            await capture.setLifecycleAdmission(isOpen:true,revision:11)
            await capture.setLifecycleAdmission(isOpen:false,revision:10)
            r.check("stale close cannot stop newer open",await capture.canAdmitCapture())
            await capture.setLifecycleAdmission(isOpen:false,revision:12)
            await capture.setLifecycleAdmission(isOpen:true,revision:11)
            r.check("stale open cannot admit after newer cover",!(await capture.canAdmitCapture()))
            await capture.noteWatchdogFired(captureID:CaptureID())
            let opened=await capture.setLifecycleAdmission(isOpen:true,revision:13)
            let stillBlocked = !(await capture.canAdmitCapture())
            r.check("lifecycle does not clear unresolved native request",!opened && stillBlocked)
        },

        TCCase(id: "UX14", title: "A fresh correlated unchanged-Auto application observation avoids a redundant read before capture") { r in
            guard let h = await StorageHarness.make(name: "ux14-live-application") else { r.check("fixture", false); return }
            let native = ChainCameraSpy(), camera = ResponsiveAutoCamera(native: native, liveAcknowledgement: true)
            let coordinator = CaptureCoordinator(camera: camera, store: h.store, clock: SystemMonotonicClock())
            let request = Task { await coordinator.capture(intent: responsiveIntent(h: h)) }
            let deadline = ContinuousClock.now.advanced(by: .seconds(2))
            while native.attachCount == 0, ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(1)) }
            r.equal("fresh moving observation submits", native.attachCount, 1)
            r.equal("no second session-queue read needed", await camera.readCount, 0)
            guard let ticket = native.lastCreatedTicket else { request.cancel(); _ = await request.value; return }
            ticket.deliverRepresentation(bytes: StorageFixture.rawBytes(), dimensions: PixelDimensions(width: 4032, height: 3024))
            ticket.deliver(.success)
            let result = await request.value
            r.equal("exactly one verified original", result.committedReceipts.count, 1)
            r.equal("no pending source", result.pendingTransactionIDs.count, 0)
            r.equal("no false settled focus", result.committedReceipts.first?.metadata.observed.focus?.provenance, .requested)
        },
        TCCase(id: "UX11", title: "Auto snapshot submits while 3A is moving and commits without settled metadata claims") { r in
            guard let h = await StorageHarness.make(name: "ux11-responsive-auto") else { r.check("fixture", false); return }
            let native = ChainCameraSpy(), camera = ResponsiveAutoCamera(native: native)
            let coordinator = CaptureCoordinator(camera: camera, store: h.store, clock: SystemMonotonicClock())
            let intent = responsiveIntent(h: h)
            let request = Task { await coordinator.capture(intent: intent) }
            let deadline = ContinuousClock.now.advanced(by: .seconds(1))
            while native.attachCount == 0, ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(1)) }
            r.equal("native submitted before any converged reading exists", native.attachCount, 1)
            r.check("a real fresh read occurred after the setter acknowledgement", await camera.readCount > 0)
            // Always release the negative hold so a regression reports failure,
            // rather than leaving an in-flight request parked in the test runner.
            await camera.allowSettlement()
            let recoveryDeadline = ContinuousClock.now.advanced(by: .seconds(2))
            while native.attachCount == 0, ContinuousClock.now < recoveryDeadline { try? await Task.sleep(for: .milliseconds(1)) }
            guard let ticket = native.lastCreatedTicket else { request.cancel(); _ = await request.value; return }
            ticket.deliverRepresentation(bytes: StorageFixture.rawBytes(), dimensions: PixelDimensions(width: 4032, height: 3024))
            ticket.deliver(.success)
            let result = await request.value
            r.equal("exactly one verified save", result.committedReceipts.count, 1)
            r.equal("no pending source", result.pendingTransactionIDs.count, 0)
            r.equal("moving focus is not labelled settled", result.committedReceipts.first?.metadata.observed.focus?.provenance, .requested)
            r.equal("moving WB is not labelled settled", result.committedReceipts.first?.metadata.observed.whiteBalance?.provenance, .requested)
            r.equal("verified folder contains the source", try? await h.store.reconcile(onProgress: nil).verifiedOriginalCount, 1)
        },
        TCCase(id: "UX12", title: "Auto readiness rejects stale identities, acknowledgements, bad measurements and sequence work") { r in
            guard let h = await StorageHarness.make(name: "ux12-auto-negatives") else { r.check("fixture", false); return }
            let intent = responsiveIntent(h: h)
            let revision = CaptureCoordinator.controlRevision(for: intent)
            func admits(_ value: AppliedControlSnapshot, for request: CaptureIntent? = nil) -> Bool {
                CaptureCoordinator.applicationIsReadyForCapture(value, for: request ?? intent)
            }
            let current = responsiveReading(revision: revision)
            r.check("fresh moving Auto is capture-ready", admits(current))
            r.check("capture-ready does not mean converged", !CaptureCoordinator.applicationIsComplete(current, for: intent))
            r.check("old configuration rejected", !admits(responsiveReading(revision: revision, generation: ConfigurationGeneration(4))))
            r.check("old revision rejected", !admits(responsiveReading(revision: revision &+ 1)))
            var ack = current; ack.settlement = .awaitingObservation
            r.check("setter acknowledgement rejected", !admits(ack))
            ack.settlement = .unmeasured(observations: 1)
            r.check("unmeasured reading rejected", !admits(ack))
            r.check("missing shutter measurement rejected", !admits(responsiveReading(revision: revision, duration: nil)))
            r.check("nonfinite ISO rejected", !admits(responsiveReading(revision: revision, iso: .nan)))
            r.check("zero ISO rejected", !admits(responsiveReading(revision: revision, iso: 0)))
            r.check("missing focus measurement rejected", !admits(responsiveReading(revision: revision, position: nil)))
            r.check("missing WB rejected", !admits(responsiveReading(revision: revision, gains: nil)))
            r.check("wrong bias rejected", !admits(responsiveReading(revision: revision, bias: 1)))
            r.check("wrong exposure mode rejected", !admits(responsiveReading(revision: revision, exposure: .manual(durationSeconds: 0.01, iso: 100))))
            for mode in [CaptureMode.exposureBracketSource, .focusBracketSource, .intervalSource, .timer] {
                r.check("\(mode) retains convergence", !admits(current, for: responsiveIntent(h: h, mode: mode)))
            }
            r.check("sequence-labelled single retains convergence", !admits(current, for: responsiveIntent(h: h, sequenceID: SequenceID())))
            r.check("manual exposure retains convergence", !admits(current, for: responsiveIntent(h: h, exposure: .manual(durationSeconds: 0.01, iso: 100))))
            r.check("priority exposure retains convergence", !admits(current, for: responsiveIntent(h: h, exposure: .isoPriority(iso: 100))))
            r.check("manual focus retains convergence", !admits(current, for: responsiveIntent(h: h, focus: FocusIntent(mode: .manual, position: 0.4, pointOfInterest: nil))))
            r.check("locked focus retains convergence", !admits(current, for: responsiveIntent(h: h, focus: FocusIntent(mode: .lockedAuto, position: nil, pointOfInterest: nil))))
            r.check("manual WB retains convergence", !admits(current, for: responsiveIntent(h: h, wb: WhiteBalanceIntent(mode: .manual, temperatureAndTint: WhiteBalanceTemperatureAndTint(temperature: 5000, tint: 0)))))
        },
        TCCase(id: "UX13", title: "Manual and sequence requests still wait for a matching settled observation before capture") { r in
            for mode in [CaptureMode.single, .exposureBracketSource] {
                guard let h = await StorageHarness.make(name: "ux13-strict-\(mode)") else { r.check("fixture", false); continue }
                let native = ChainCameraSpy(), camera = ResponsiveAutoCamera(native: native, liveAcknowledgement: true)
                let coordinator = CaptureCoordinator(camera: camera, store: h.store, clock: SystemMonotonicClock())
                let exposure: ExposureChoice = mode == .single ? .manual(durationSeconds: 0.01, iso: 100) : .auto
                let intent = responsiveIntent(h: h, mode: mode, exposure: exposure)
                let request = Task { await coordinator.capture(intent: intent) }
                let deadline = ContinuousClock.now.advanced(by: .seconds(1))
                while await camera.readCount < 3, ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(1)) }
                r.check("strict request actually sampled moving readings", await camera.readCount >= 3)
                r.equal("no frame submitted before strict convergence", native.attachCount, 0)
                await camera.allowSettlement()
                let nextDeadline = ContinuousClock.now.advanced(by: .seconds(2))
                while native.attachCount == 0, ContinuousClock.now < nextDeadline { try? await Task.sleep(for: .milliseconds(1)) }
                r.equal("matching settlement admits one frame", native.attachCount, 1)
                guard let ticket = native.lastCreatedTicket else { request.cancel(); _ = await request.value; continue }
                ticket.deliverRepresentation(bytes: StorageFixture.rawBytes(), dimensions: PixelDimensions(width: 4032, height: 3024))
                ticket.deliver(.success)
                let result = await request.value
                r.equal("strict request retains verified save", result.savedToFolderCount, 1)
            }
        },
        TCCase(id: "UX08", title: "Two verified captures finish while an ordered gallery publisher remains held") { r in
            guard let h = await StorageHarness.make(name: "ux08-save-publish") else { r.check("fixture", false); return }
            let spy = ChainCameraSpy(), held = PrepareHold()
            let published = Mutex<[CaptureID]>([])
            let model = await CameraViewModel(camera: SyntheticCameraService(capability: controlFixture(modes: [.auto,.manual])),
                capture: CaptureCoordinator(camera:spy,store:h.store,clock:SystemMonotonicClock()),
                metering:MeteringService(clock:SystemMonotonicClock()),preferences:SyntheticPreferenceStore(),levelFeed:SyntheticLevelFeed())
            await model.start()
            await model.updateRootState(h.store.rootState)
            await MainActor.run { model.onCommittedReceipts = { receipts in
                await held.wait()
                published.withLock { $0.append(contentsOf:receipts.map(\.captureID)) }
            } }
            let first = Task { await model.activateShutter() }
            let firstDeadline = ContinuousClock.now.advanced(by: .seconds(3))
            while spy.attachCount < 1, ContinuousClock.now < firstDeadline { try? await Task.sleep(for:.milliseconds(1)) }
            guard let a = spy.lastCreatedTicket else { first.cancel(); r.check("first admitted",false); return }
            a.deliverRepresentation(bytes:StorageFixture.rawBytes(), dimensions:PixelDimensions(width:4032,height:3024)); a.deliver(.success)
            let commitDeadline = ContinuousClock.now.advanced(by:.seconds(3))
            while !(await held.didEnter), ContinuousClock.now < commitDeadline { try? await Task.sleep(for:.milliseconds(1)) }
            r.check("gallery callback genuinely held",await held.didEnter)
            let readyDeadline = ContinuousClock.now.advanced(by:.seconds(2))
            while await model.isCapturing, ContinuousClock.now < readyDeadline { try? await Task.sleep(for:.milliseconds(1)) }
            r.check("verified save clears busy before gallery refresh",await model.isCapturing == false)
            r.check("saved label requires actual commit",await !model.lastCommittedReceipts.isEmpty)
            r.check("next shutter enabled",await model.isShutterEnabled)
            r.equal("publisher has not manufactured an index receipt",published.withLock { $0.count },0)
            let second = Task { await model.activateShutter() }
            let secondDeadline = ContinuousClock.now.advanced(by:.seconds(3))
            while spy.attachCount < 2, ContinuousClock.now < secondDeadline { try? await Task.sleep(for:.milliseconds(1)) }
            r.equal("second native request admitted without waiting for gallery",spy.attachCount,2)
            if let b = spy.lastCreatedTicket, b.captureID != a.captureID {
                b.deliverRepresentation(bytes:StorageFixture.rawBytes(filler:0x22),dimensions:PixelDimensions(width:4032,height:3024));b.deliver(.success)
            } else { second.cancel() }
            await second.value
            r.equal("both originals are actually durable",try? await h.store.reconcile(onProgress:nil).verifiedOriginalCount,2)
            await held.release();await first.value;await model.waitForReceiptPublication()
            r.equal("ordered exactly-once publication",published.withLock { $0 },[a.captureID,spy.lastCreatedTicket!.captureID])
            await model.handleCameraScreenCovered()
        },
        TCCase(id: "UX09", title: "Hardware shutter eligibility follows camera readiness, modal ownership and pending recovery") { r in
            guard let h = await StorageHarness.make(name:"ux09-hardware") else { r.check("fixture",false);return }
            let model = await CameraViewModel(camera:SyntheticCameraService(capability:controlFixture(modes:[.auto,.manual])),
                capture:CaptureCoordinator(camera:ChainCameraSpy(),store:h.store,clock:SystemMonotonicClock()),
                metering:MeteringService(clock:SystemMonotonicClock()),preferences:SyntheticPreferenceStore(),levelFeed:SyntheticLevelFeed())
            r.check("not intercepted before ready",await model.isHardwareShutterEnabled == false)
            await model.start();await model.updateRootState(h.store.rootState)
            r.check("ready physical shutter admitted",await model.isHardwareShutterEnabled)
            for sheet in [CameraViewModel.CameraSheet.tools,.folder,.recovery] {
                await MainActor.run { model.presentedCameraSheet = sheet }
                r.check("modal returns system button ownership",await model.isHardwareShutterEnabled == false)
            }
            await MainActor.run { model.presentedCameraSheet = nil }
            await model.updatePendingOriginalCount(1)
            r.check("failed pending original blocks hardware too",await model.isHardwareShutterEnabled == false)
            await model.updatePendingOriginalCount(0);await model.handleCameraScreenCovered()
            r.check("covered camera cannot intercept",await model.isHardwareShutterEnabled == false)
        },
        TCCase(id: "UX10", title: "Multi-chunk nonzero-index RAW Data slices retain exact bytes and hashes through verified commit") { r in
            guard let h = await StorageHarness.make(name:"ux10-data-slice") else { r.check("fixture",false);return }
            var container = Data([7,8,9]);container.append(StorageFixture.rawBytes())
            container.append(Data(repeating:0xAB,count:2 * FileAdapterDefaults.hashChunkBytes + 37))
            let bytes = container[3..<container.count]
            r.check("test actually exercises sliced Data indexing",bytes.startIndex != 0)
            do {
                let id=CaptureID(), begun=ContinuousClock.now
                let staged=try await h.store.stageSource(bytes:bytes,metadata:StorageFixture.metadata(captureID:id,libraryID:h.libraryID))
                let receipt=try await h.store.commit(handle:staged)
                r.equal("all bytes committed",receipt.verifiedByteCount,Int64(bytes.count))
                r.equal("digest agrees with independent full Data oracle",receipt.verifiedSHA256.hex,StorageFixture.sha256Hex(Data(bytes)))
                r.equal("no incomplete recovery record",await h.store.pendingOriginals().count,0)
                print("TC_LOCAL_SAVE_FIXTURE bytes=\(bytes.count) elapsed=\(begun.duration(to:.now)); not a phone benchmark")
            } catch { r.check("sliced Data verified pipeline",false,String(describing:error)) }
        },
        TCCase(id: "UX01", title: "Late layout rebuilds the shipping model's full zebra request and stale geometry cannot paint") { r in
            guard let h = await StorageHarness.make(name: "ux01-late-geometry") else { r.check("fixture", false); return }
            let service = SyntheticCameraService(capability: controlFixture(modes: [.auto, .manual]))
            let meter = MeteringService(clock: SystemMonotonicClock())
            let model = await CameraViewModel(camera: service,
                capture: CaptureCoordinator(camera: ChainCameraSpy(), store: h.store, clock: SystemMonotonicClock()),
                metering: meter, preferences: SyntheticPreferenceStore(), levelFeed: SyntheticLevelFeed())
            await model.start()
            await MainActor.run { model.composition.zebrasEnabled = true; model.composition.zebraThreshold = .ninetyFive }
            await model.updateAnalysisDemand()
            r.check("before layout no fabricated request", await service.analysisRequests.last! == nil)
            let geometry = PreviewGeometrySnapshot(configurationGeneration: .zero, layoutGeneration: 72,
                imageDimensions: PixelDimensions(width: 3, height: 2), cleanApertureDimensions: nil,
                previewLayerContentRect: TCRect(x: 0, y: 0, width: 300, height: 200),
                bufferOrientation: 1, isMirrored: false, analysisRotationDegrees: 180,
                isVideoMirrored: false, capturedAtUTC: Date())
            await model.updateGeometry(geometry)
            let deadline = ContinuousClock.now.advanced(by: .seconds(2))
            while (await service.analysisRequests.last ?? nil)?.geometry?.layoutGeneration != 72, ContinuousClock.now < deadline {
                try? await Task.sleep(for: .milliseconds(1))
            }
            guard let request = await service.analysisRequests.last ?? nil else { r.check("request after layout", false); return }
            r.check("zebra output attached", request.demand.zebrasEnabled)
            r.close("user threshold retained", request.zebraThreshold, ZebraThreshold.ninetyFive.normalizedValue, tolerance: 0.0001)
            await meter.setDemand(request)
            await meter.submit(sample: LuminanceSample(width: 3, height: 2, luma: [255,0,0,0,0,0], range: .full,
                configurationGeneration: .zero, geometryGeneration: 71, capturedAtUTC: Date()))
            r.equal("stale layout rejected", await meter.droppedStaleGenerationSampleCount, 1)
            r.check("stale mask absent", await model.masks == nil)
            await meter.submit(sample: LuminanceSample(width: 3, height: 2, luma: [255,0,0,0,0,0], range: .full,
                configurationGeneration: .zero, geometryGeneration: 72, capturedAtUTC: Date()))
            let paintDeadline = ContinuousClock.now.advanced(by: .seconds(2))
            while await model.masks == nil, ContinuousClock.now < paintDeadline { try? await Task.sleep(for: .milliseconds(1)) }
            r.equal("bright corner rotated to opposite corner", await model.masks?.zebraMask, [0,0,0,0,0,255])
            r.equal("geometry reaches visible overlay", await model.masks?.geometryGeneration, 72)
            await model.handleCameraScreenCovered()
        },
        TCCase(id: "UX02", title: "Tools queues a sequence until dismissal, consumes once, and drops background requests") { r in
            guard let h = await StorageHarness.make(name: "ux02-tools") else { r.check("fixture", false); return }
            let model = await CameraViewModel(camera: SyntheticCameraService(capability: controlFixture(modes: [.auto, .manual])),
                capture: CaptureCoordinator(camera: ChainCameraSpy(), store: h.store, clock: SystemMonotonicClock()),
                metering: MeteringService(clock: SystemMonotonicClock()), preferences: SyntheticPreferenceStore(), levelFeed: SyntheticLevelFeed())
            await model.start()
            await MainActor.run { model.isToolsSheetPresented = true; model.requestSequence(.exposureBracket) }
            r.check("tools closes before sequence starts", await model.isToolsSheetPresented == false)
            r.equal("queued request", await model.queuedSequenceRequest, .exposureBracket)
            r.check("no premature failure obscured by sheet", await model.lastFailure == nil)
            await model.launchQueuedSequence()
            r.check("request consumed on dismiss", await model.queuedSequenceRequest == nil)
            r.equal("missing coordinator shown on camera after dismiss", await model.lastFailure?.title, "Sequence unavailable")
            await model.clearLastFailure()
            await model.launchQueuedSequence()
            r.check("duplicate dismiss does not launch twice", await model.lastFailure == nil)
            await MainActor.run { model.isToolsSheetPresented = true; model.requestSequence(.exposureBracket) }
            await model.handleSceneBecameInactive()
            await model.launchQueuedSequence()
            r.check("inactive request consumed", await model.queuedSequenceRequest == nil)
            r.check("inactive request not dispatched", await model.lastFailure == nil)
        },
        TCCase(id: "UX03", title: "Delete navigation uses next, then previous, with an explicit empty state") { r in
            let a = CaptureID(), b = CaptureID(), c = CaptureID()
            r.equal("middle uses next", ViewerDeletionNavigation.successor(deleting: b, ordered: [a,b,c]), c)
            r.equal("first uses next", ViewerDeletionNavigation.successor(deleting: a, ordered: [a,b,c]), b)
            r.equal("last uses previous", ViewerDeletionNavigation.successor(deleting: c, ordered: [a,b,c]), b)
            r.check("only original leaves empty viewer", ViewerDeletionNavigation.successor(deleting: a, ordered: [a]) == nil)
            r.check("empty list has no target", ViewerDeletionNavigation.successor(deleting: a, ordered: []) == nil)
            r.equal("already removed identity uses first surviving item", ViewerDeletionNavigation.successor(deleting: b, ordered: [a,c]), a)
        },
        TCCase(id: "LV06", title: "A late start cannot stop or replace a camera already reopened by a newer attempt") { r in
            guard let h = await StorageHarness.make(name: "lv06-stale-start") else { r.check("fixture", false); return }
            let service = SyntheticCameraService(capability: controlFixture(modes: [.auto, .manual]))
            await service.configureStartDelay(.milliseconds(200))
            let model = await CameraViewModel(camera: service,
                capture: CaptureCoordinator(camera: ChainCameraSpy(), store: h.store, clock: SystemMonotonicClock()),
                metering: MeteringService(clock: SystemMonotonicClock()), levelFeed: SyntheticLevelFeed())
            let old = Task { await model.start() }
            let deadline = ContinuousClock.now.advanced(by: .seconds(2))
            while await service.startRequests == 0, ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(1)) }
            r.equal("first start held", await service.startRequests, 1)
            await model.handleCameraScreenCovered()
            await service.configureStartDelay(.zero)
            await model.handleCameraScreenRevealed()
            r.equal("new start completed", await service.startRequests, 2)
            await old.value
            r.equal("late start did not force third startup", await service.startRequests, 2)
            r.equal("new sensor remains running", await service.lifecycle, .running)
            r.equal("new surface remains ready", await model.surface, .ready)
            r.check("no obsolete failure popup", await model.lastFailure == nil)
            await model.handleCameraScreenCovered()
        },
        TCCase(id: "LV05", title: "Real coordinated filesystem Trash survives a new store and restores exact bytes") { r in
            let base = StorageFixture.temporaryDirectory("lv05-coordinated-trash")
            defer { StorageFixture.removeDirectory(base) }
            let root = base.appendingPathComponent("retained-library", isDirectory: true)
            let support = base.appendingPathComponent("support", isDirectory: true)
            func makeStore() -> LibraryStore {
                LibraryStore(adapter: SystemFileSystemAdapter(), coordinator: NSFileCoordinatorMutator(),
                    wallClock: StorageFixture.fixedClock(), supportDirectory: support,
                    temporaryDirectory: base.appendingPathComponent("tmp"), ownedContainerURLs: [],
                    bookmarkStore: InMemoryRootBookmarkStore(),
                    scopeDriver: ScriptedSecurityScopeDriver(grants: [true]), capacityReserveBytes: 0,
                    injectedLocalityVerdict: .userConfirmedLocalDestination(evidence: "isolated temporary local filesystem fixture"))
            }
            do {
                try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
                let store = makeStore(); _ = await store.selectRoot(from: root, confirmedLocalDestination: true)
                guard case .writable(let libraryID, let generation) = store.rootState else { r.check("root writable", false); return }
                let id = CaptureID(), bytes = StorageFixture.rawBytes()
                let handle = try await store.stageSource(bytes: bytes, metadata: StorageFixture.metadata(captureID: id, libraryID: libraryID))
                _ = try await store.commit(handle: handle)
                _ = try await store.reconcile(onProgress: nil)
                guard let card = try await store.reconciledSourceCards(after: nil, limit: 10).cards.first else { r.check("card", false); return }
                let record = try await store.trashOriginal(card: card, generation: generation)
                r.equal("coordinated Trash contains exact bytes", try Data(contentsOf: root.appendingPathComponent(record.directory + "/original.dng")), bytes)
                await store.releaseRoot()
                let restarted = makeStore(); _ = await restarted.selectRoot(from: root, confirmedLocalDestination: true)
                guard let newGeneration = restarted.rootState.generation else { r.check("reconnected", false); return }
                r.equal("Trash reconstructed without old app state", try await restarted.trashedOriginals().first?.id, record.id)
                try await restarted.restoreOriginal(trashID: record.id, libraryID: libraryID, generation: newGeneration)
                r.equal("real restored bytes unchanged", try Data(contentsOf: root.appendingPathComponent(record.originalPath)), bytes)
                r.equal("reconciled restored original", try await restarted.reconcile(onProgress: nil).verifiedOriginalCount, 1)
                await restarted.releaseRoot()
            } catch { r.check("real filesystem pipeline", false, String(describing: error)) }
        },
        TCCase(id: "LV04", title: "A superseded tuple query retries only under the same start owner and stays bounded") { r in
            let calls = Mutex(0)
            let published = await FinalTupleAdmission.validateCurrentTuple(isCurrent: { true }, query: {
                let count = calls.withLock { $0 += 1; return $0 }
                return count == 1 ? .superseded : .published
            })
            r.equal("fresh committed tuple accepted", published, .published)
            r.equal("exactly one fresh query", calls.withLock { $0 }, 2)
            calls.withLock { $0 = 0 }
            let stale = await FinalTupleAdmission.validateCurrentTuple(isCurrent: { false }, query: {
                calls.withLock { $0 += 1 }; return .superseded
            })
            r.equal("obsolete start remains no-effect superseded", stale, .superseded)
            r.equal("obsolete owner never queries twice", calls.withLock { $0 }, 1)
            calls.withLock { $0 = 0 }
            let churn = await FinalTupleAdmission.validateCurrentTuple(isCurrent: { true }, query: {
                calls.withLock { $0 += 1 }; return .superseded
            })
            r.equal("churn never guessed as RAW supported", churn, .superseded)
            r.equal("retry bounded", calls.withLock { $0 }, 2)
            calls.withLock { $0 = 0 }
            let refused = await FinalTupleAdmission.validateCurrentTuple(isCurrent: { true }, query: {
                calls.withLock { $0 += 1 }; return .refused
            })
            r.equal("real invalid tuple not retried", calls.withLock { $0 }, 1)
            r.equal("real invalid tuple stops", FinalTupleAdmission.action(for: CapabilityRevocation.decision(for: refused)), .stopAndFail)
        },
        TCCase(id: "LV01", title: "Repeated covered/revealed cycles preserve eligibility and controls without detached analysis work") { r in
            guard let h = await StorageHarness.make(name: "lv01-reopen") else { r.check("fixture", false); return }
            let service = SyntheticCameraService(capability: controlFixture(modes: [.auto, .manual]))
            let model = await CameraViewModel(camera: service,
                capture: CaptureCoordinator(camera: ChainCameraSpy(), store: h.store, clock: SystemMonotonicClock()),
                metering: MeteringService(clock: SystemMonotonicClock()), levelFeed: SyntheticLevelFeed())
            await model.start()
            for _ in 0..<5 {
                let demandCount = await service.analysisDemands.count
                await model.handleCameraScreenCovered()
                r.equal("cover never schedules analysis topology detachment", await service.analysisDemands.count, demandCount)
                r.equal("covered sensor stopped", await service.lifecycle, .idle)
                await model.start() // A stale UI task must not run a covered camera.
                r.equal("covered direct start refused", await service.lifecycle, .idle)
                await model.handleCameraScreenRevealed()
                await model.handleCameraScreenRevealed()
                r.equal("reopened model running", await model.lifecycle, .running)
                r.equal("reopened surface ready", await model.surface, .ready)
                r.check("no obsolete startup popup", await model.lastFailure == nil)
            }
            await model.handleCameraScreenCovered()
        },
        TCCase(id: "LV02", title: "Viewer Trash and restore rebuild actual SQLite gallery and sequence counts without rewriting originals") { r in
            guard let h = await StorageHarness.make(name: "lv02-trash") else { r.check("fixture", false); return }
            let id = CaptureID(), sequence = SequenceID(), bytes = StorageFixture.rawBytes()
            let link = SourceSequenceLink(id: sequence, kind: .interval, index: SourceOrdinal(0), plannedCount: 1)
            do {
                let handle = try await h.store.stageSource(bytes: bytes,
                    metadata: StorageFixture.metadata(captureID: id, libraryID: h.libraryID, sequence: link))
                _ = try await h.store.commit(handle: handle)
                var document = SequenceDocument(sequenceID: sequence, libraryID: h.libraryID, kind: .interval,
                    plannedCount: 1, sourcePlan: [.init(index: 0, offsetEV: nil, focusPosition: nil)],
                    intervalSeconds: 5, baseline: nil, startedAtUTC: StorageFixture.fixedDate)
                document.completedSources = [.init(index: 0, captureID: id.rawValue)]
                document.status = .complete; document.endedAtUTC = StorageFixture.fixedDate
                try await h.store.writeSequenceDocument(document)
                let indexURL = StorageFixture.temporaryDirectory("lv02-index").appendingPathComponent("gallery.sqlite")
                defer { StorageFixture.removeDirectory(indexURL.deletingLastPathComponent()) }
                let index = SQLiteIndex(databaseURL: indexURL)
                let session = await LibrarySessionCoordinator(store: h.store, index: index)
                let gallery = await LibraryViewModel(index: index, store: h.store)
                await session.refreshAfterFilesChange(); await gallery.loadFirstPage()
                r.equal("index initially holds source", await gallery.individualOriginalCount, 1)
                let cards = try await h.store.reconciledSourceCards(after: nil, limit: 10)
                guard let card = cards.cards.first else { r.check("source card", false); return }
                let sidecarBefore = h.memory.fileBytes(at: h.finalSidecarURL(for: id))
                let record = try await h.store.trashOriginal(card: card, generation: h.generation)
                r.equal("Trash original is byte-identical", h.memory.fileBytes(at: h.root.appendingPathComponent(record.directory + "/original.dng")), bytes)
                r.check("original absent from normal photo tree", !h.memory.fileExists(at: h.finalURL(for: id)))
                await session.refreshAfterFilesChange(); await gallery.loadFirstPage()
                r.equal("SQLite/gallery no deleted source", await gallery.individualOriginalCount, 0)
                let result = try await h.store.reconcile(onProgress: nil)
                r.equal("deleted source isn't falsely completed", result.sequences.first?.committedCount, 0)
                r.equal("sequence retains missing slot", result.sequences.first?.missingIndices, [0])
                r.equal("complete historical sequence now incomplete", result.sequences.first?.status, .interrupted)
                r.equal("persistent Trash entry", try await h.store.trashedOriginals().count, 1)
                try await h.store.restoreOriginal(trashID: record.id, libraryID: h.libraryID, generation: h.generation)
                await session.refreshAfterFilesChange(); await gallery.loadFirstPage()
                r.equal("gallery restored", await gallery.individualOriginalCount, 1)
                r.equal("DNG untouched through round trip", h.memory.fileBytes(at: h.finalURL(for: id)), bytes)
                r.equal("metadata untouched", h.memory.fileBytes(at: h.finalSidecarURL(for: id)), sidecarBefore)
                r.equal("Trash no longer lists restored original", try await h.store.trashedOriginals().count, 0)
                r.equal("historical sequence complete again", try await h.store.reconcile(onProgress: nil).sequences.first?.committedCount, 1)
                await index.closeDatabase()
            } catch { r.check("production pipeline", false, String(describing: error)) }
        },
        TCCase(id: "LV03", title: "Trash rejects stale root, changed bytes and destination conflicts; interrupted pair remains recoverable") { r in
            guard let h = await StorageHarness.make(name: "lv03-trash-fault") else { r.check("fixture", false); return }
            let id = CaptureID(), bytes = StorageFixture.rawBytes()
            do {
                let handle = try await h.store.stageSource(bytes: bytes, metadata: StorageFixture.metadata(captureID: id, libraryID: h.libraryID))
                _ = try await h.store.commit(handle: handle)
                _ = try await h.store.reconcile(onProgress: nil)
                guard let card = try await h.store.reconciledSourceCards(after: nil, limit: 10).cards.first else { r.check("card", false); return }
                do { _ = try await h.store.trashOriginal(card: card, generation: .next(h.generation)); r.check("stale generation refused", false) }
                catch { r.check("stale generation refused", true) }
                r.equal("stale operation didn't touch DNG", h.memory.fileBytes(at: h.finalURL(for: id)), bytes)
                h.fault.armMove(destinationSuffix: "metadata.json")
                do { _ = try await h.store.trashOriginal(card: card, generation: h.generation); r.check("partial move reported failure", false) }
                catch { r.check("partial move reported failure", true) }
                guard let record = try await h.store.trashedOriginals().first else { r.check("durable recovery record", false); return }
                r.check("sidecar retained after failed second move", h.memory.fileExists(at: h.finalSidecarURL(for: id)))
                let changed = StorageFixture.rawBytes(filler: 0x99)
                try h.memory.writeNewFile(at: h.finalURL(for: id), bytes: changed)
                do { try await h.store.restoreOriginal(trashID: record.id, libraryID: h.libraryID, generation: h.generation); r.check("conflict refused", false) }
                catch { r.check("conflict refused", true) }
                r.equal("conflicting destination preserved", h.memory.fileBytes(at: h.finalURL(for: id)), changed)
                r.equal("Trash intact after conflict", h.memory.fileBytes(at: h.root.appendingPathComponent(record.directory + "/original.dng")), bytes)
                try h.memory.removeItem(at: h.finalURL(for: id)) // isolated fixture only
                try await h.store.restoreOriginal(trashID: record.id, libraryID: h.libraryID, generation: h.generation)
                r.equal("partial pair restored intact", h.memory.fileBytes(at: h.finalURL(for: id)), bytes)
                try h.memory.removeItem(at: h.finalURL(for: id))
                try h.memory.writeNewFile(at: h.finalURL(for: id), bytes: changed)
                do { _ = try await h.store.trashOriginal(card: card, generation: h.generation); r.check("changed original refused", false) }
                catch { r.check("changed original refused", true) }
                r.equal("changed original never deleted", h.memory.fileBytes(at: h.finalURL(for: id)), changed)
            } catch { r.check("fault pipeline", false, String(describing: error)) }
        },
        TCCase(id: "PF03", title: "Lens transitions reject overlapping gestures and recover the prior lens after refusal") { r in
            guard let h = await StorageHarness.make(name: "pf03-lens") else { r.check("fixture", false); return }
            let service = SyntheticCameraService(capability: controlFixture(modes: [.auto, .manual]))
            await service.configureSwitch(failures: [.ultraWide], delay: .milliseconds(80))
            let model = await CameraViewModel(camera: service,
                capture: CaptureCoordinator(camera: ChainCameraSpy(), store: h.store, clock: SystemMonotonicClock()),
                metering: MeteringService(clock: SystemMonotonicClock()), levelFeed: SyntheticLevelFeed())
            await model.start()
            let first = Task { await model.selectLens(.ultraWide) }
            let deadline = ContinuousClock.now.advanced(by: .seconds(2))
            while !(await model.isSwitchingLens), ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(1)) }
            r.check("real model advertises transition", await model.isSwitchingLens)
            await model.selectLens(.wide)
            r.equal("overlapping gesture does not configure", await service.switchRequests, [.ultraWide])
            await first.value
            r.check("refused transition releases ownership", !(await model.isSwitchingLens))
            await model.selectLens(.wide)
            r.equal("old selected lens can be recovered after refusal", await service.switchRequests, [.ultraWide, .wide])
            r.equal("recovered surface ready", await model.surface, .ready)
            await model.selectLens(.wide)
            r.equal("same ready lens is a no-op", await service.switchRequests.count, 2)
        },
        TCCase(id: "PF01", title: "Only a verified photo Bayer tuple at the complete advertised ceiling avoids a sweep") { r in
            let photo = CaptureFormatFacts(index: 4, advertisedMaxPhotoDimensions: [PixelDimensions(width: 8000, height: 6000)],
                bayerPixelFormatsForDNG: [1234], configurationMode: .photoPreset)
            let equal = CaptureFormatDiscovery.Candidate(index: 0, dimensions: [PixelDimensions(width: 8000, height: 6000)])
            let small = CaptureFormatDiscovery.Candidate(index: 1, dimensions: [PixelDimensions(width: 4000, height: 3000)])
            r.check("complete proven ceiling skips format mutations", CaptureFormatDiscovery.photoReachesAdvertisedCeiling(photo, candidates: [equal, small]))
            let larger = CaptureFormatDiscovery.Candidate(index: 2, dimensions: [PixelDimensions(width: 9000, height: 7000)])
            r.check("a larger candidate must be probed", !CaptureFormatDiscovery.photoReachesAdvertisedCeiling(photo, candidates: [equal, larger]))
            r.check("missing candidate ceiling must be probed", !CaptureFormatDiscovery.photoReachesAdvertisedCeiling(photo,
                candidates: [.init(index: 2, dimensions: [])]))
            let noRaw = CaptureFormatFacts(index: photo.index, advertisedMaxPhotoDimensions: photo.advertisedMaxPhotoDimensions,
                bayerPixelFormatsForDNG: [], configurationMode: .photoPreset)
            r.check("no native Bayer proof must be probed", !CaptureFormatDiscovery.photoReachesAdvertisedCeiling(noRaw, candidates: [equal]))
            let explicit = CaptureFormatFacts(index: photo.index, advertisedMaxPhotoDimensions: photo.advertisedMaxPhotoDimensions,
                bayerPixelFormatsForDNG: photo.bayerPixelFormatsForDNG, configurationMode: .explicitFormat)
            r.check("borrowed explicit facts are not photo evidence", !CaptureFormatDiscovery.photoReachesAdvertisedCeiling(explicit, candidates: [equal]))
            r.check("empty discovery must not claim a maximum", !CaptureFormatDiscovery.photoReachesAdvertisedCeiling(photo, candidates: []))
        },
        TCCase(id: "PF02", title: "Photographic detents use familiar values while refusing unsupported native ranges") { r in
            let iso = PhotographicExposureSteps.legal(PhotographicExposureSteps.iso, minimum: 54, maximum: 850)
            r.equal("standard ISO increments", Array(iso.prefix(5)), [64.0, 80, 100, 125, 160])
            r.check("no unsupported endpoints", iso.allSatisfy { $0 >= 54 && $0 <= 850 })
            let durations = PhotographicExposureSteps.legal(PhotographicExposureSteps.durations, minimum: 1/7951.0, maximum: 1/4.0)
            r.check("familiar 1/60 detent", durations.contains(1/60.0))
            r.check("no raw minimum masquerading as a normal stop", !durations.contains(1/7951.0))
            r.check("invalid limits reject choices", PhotographicExposureSteps.legal([100], minimum: .nan, maximum: 800).isEmpty)
            r.equal("very narrow range remains usable and legal", PhotographicExposureSteps.legal([100, 125], minimum: 110, maximum: 115), [110.0, 115])
            r.equal("nearest detent", PhotographicExposureSteps.nearest(810, in: [640, 800, 1000]), 1)
            r.equal("only thirds and off", GridMode.allCases, [.off, .thirds])
        },
        TCCase(id: "RD01", title: "Inline gestures retain selection, use legal paired exposure and preserve temperature/tint independently") { r in
            guard let h = await StorageHarness.make(name: "redesign-controls") else { r.check("fixture", false); return }
            let model = await CameraViewModel(camera: SyntheticCameraService(),
                capture: CaptureCoordinator(camera: ChainCameraSpy(), store: h.store, clock: SystemMonotonicClock()),
                metering: MeteringService(clock: SystemMonotonicClock()), levelFeed: SyntheticLevelFeed())
            await MainActor.run {
                model.adoptCapability(controlFixture(modes: [.auto, .manual]))
                model.openPanel = .shutter
                model.adjustShutterFromStrip(0.02)
                r.equal("manual avoids unsupported intermediate priority", model.exposure.mode, .manual)
                r.check("manual choice is legal", model.appliesLegally())
                let duration = model.exposure.durationTargetSeconds
                model.openPanel = .iso
                model.adjustISOFromStrip(200)
                r.equal("ISO drag preserves chosen shutter", model.exposure.durationTargetSeconds, duration)
                r.equal("parameter stays selected through adjustment", model.openPanel, .iso)
                model.openPanel = nil
                r.equal("closing controls preserves exposure", model.exposure.isoTarget, 200)
                model.setStripAutomatic(.iso)
                r.equal("explicit paired Auto clears both", model.exposure, .auto)
                model.setWhiteBalanceTemperature(4800)
                model.setWhiteBalanceTint(12)
                r.equal("tint preserves temperature", model.whiteBalance.temperatureAndTint?.temperature, 4800)
                model.setWhiteBalanceTemperature(6000)
                r.equal("temperature preserves tint", model.whiteBalance.temperatureAndTint?.tint, 12)
                model.setStripAutomatic(.whiteBalance)
                r.equal("WB Auto remains separate from exposure", model.whiteBalance.mode, .auto)
                r.equal("exposure still Auto", model.exposure, .auto)
            }
        },
        TCCase(id: "RD02", title: "Legacy library plus new metadata tree reconnects, verifies and exports without changing originals") { r in
            guard let raw = StorageHarness.makeRaw(name: "redesign-mixed-layout") else { r.check("fixture", false); return }
            let libraryID = LibraryID(), oldID = CaptureID(), newID = CaptureID()
            var manifest = LibraryManifest(libraryID: libraryID, createdAtUTC: StorageFixture.fixedDate)
            manifest.layoutVersion = nil
            let manifestBytes = StorageFixture.manifestData(manifest)
            let legacyManifest = raw.root.appendingPathComponent(LibraryLayout.legacyLibraryManifestName)
            raw.memory.setBytes(manifestBytes, at: legacyManifest)
            let oldPath = LibraryLayout.relativeOriginalPath(for: oldID, capturedAt: StorageFixture.fixedDate, calendar: StorageFixture.utcCalendar)
            let bytes = StorageFixture.rawBytes()
            let oldMetadataPath = LibraryLayout.relativeSidecarPath(alongside: oldPath)
            let oldSidecar = StorageFixture.sidecar(captureID: oldID, libraryID: libraryID, relativePath: oldPath,
                byteCount: Int64(bytes.count), sha256: StorageFixture.sha256Hex(bytes))
            raw.memory.setBytes(bytes, at: raw.root.appendingPathComponent(oldPath))
            raw.memory.setBytes(StorageFixture.sidecarData(oldSidecar), at: raw.root.appendingPathComponent(oldMetadataPath))
            guard case .opened = await raw.store.selectRoot(from: raw.root) else { r.check("legacy selected", false); return }
            do {
                let staged = try await raw.store.stageSource(bytes: bytes,
                    metadata: StorageFixture.metadata(captureID: newID, libraryID: libraryID))
                let receipt = try await raw.store.commit(handle: staged)
                r.check("new completion metadata is separate", receipt.relativeSidecarPath.hasPrefix("metadata/originals/"))
                r.check("new photo has no adjacent JSON", !raw.memory.fileExists(at: raw.root.appendingPathComponent(LibraryLayout.relativeSidecarPath(alongside: receipt.relativeOriginalPath))))
                r.equal("legacy manifest untouched", raw.memory.fileBytes(at: legacyManifest), manifestBytes)
                r.equal("legacy original untouched", raw.memory.fileBytes(at: raw.root.appendingPathComponent(oldPath)), bytes)
                r.equal("new original unchanged", raw.memory.fileBytes(at: raw.root.appendingPathComponent(receipt.relativeOriginalPath)), bytes)
                let scan = try await raw.store.reconcile(onProgress: nil)
                r.equal("legacy and new are both verified", scan.verifiedOriginalCount, 2)
                r.equal("no metadata counted as photo", scan.verifiedOriginalCount + scan.recoveredRAWCount, 2)
                let exported = try await raw.store.prepareOriginalExport(sourceIDs: [oldID, newID], includeSidecars: true)
                r.equal("opt-in exports both layouts", exported.fileURLs.count, 4)
                await raw.store.discardExport(sessionID: exported.sessionID)
                await raw.store.releaseRoot()
                guard case .opened(let id, _, _) = await raw.store.selectRoot(from: raw.root) else { r.check("reconnect", false); return }
                r.equal("identity survives reconnect", id, libraryID)
                r.equal("reconnect rebuilds both photos", try await raw.store.reconcile(onProgress: nil).verifiedOriginalCount, 2)
            } catch { r.check("mixed layout path", false, "\(error)") }
        },
        TCCase(id: "RD04", title: "Explicit organization verifies records before removing legacy copies and refuses conflicts") { r in
            guard let raw = StorageHarness.makeRaw(name: "redesign-organize") else { r.check("fixture", false); return }
            let libraryID = LibraryID(), captureID = CaptureID()
            var manifest = LibraryManifest(libraryID: libraryID, createdAtUTC: StorageFixture.fixedDate)
            manifest.layoutVersion = nil
            raw.memory.setBytes(StorageFixture.manifestData(manifest), at: raw.root.appendingPathComponent(LibraryLayout.legacyLibraryManifestName))
            let path = LibraryLayout.relativeOriginalPath(for: captureID, capturedAt: StorageFixture.fixedDate, calendar: StorageFixture.utcCalendar)
            let legacy = raw.root.appendingPathComponent(LibraryLayout.relativeSidecarPath(alongside: path))
            let target = raw.root.appendingPathComponent(LibraryLayout.metadataSidecarPath(for: path))
            let bytes = StorageFixture.rawBytes()
            let sidecar = StorageFixture.sidecarData(StorageFixture.sidecar(captureID: captureID, libraryID: libraryID,
                relativePath: path, byteCount: Int64(bytes.count), sha256: StorageFixture.sha256Hex(bytes)))
            raw.memory.setBytes(bytes, at: raw.root.appendingPathComponent(path))
            raw.memory.setBytes(sidecar, at: legacy)
            let userJSON = raw.root.appendingPathComponent("originals/user-notes.json")
            raw.memory.setBytes(Data("personal notes".utf8), at: userJSON)
            guard case .opened = await raw.store.selectRoot(from: raw.root) else { r.check("legacy selected", false); return }
            do {
                raw.memory.setBytes(Data("different record".utf8), at: target)
                var refused = false
                do { _ = try await raw.store.organizeMetadata() } catch { refused = true }
                r.check("different destination refused", refused)
                r.equal("legacy evidence survives refusal", raw.memory.fileBytes(at: legacy), sidecar)
                r.equal("original survives refusal", raw.memory.fileBytes(at: raw.root.appendingPathComponent(path)), bytes)
                try raw.memory.removeItem(at: target)
                r.equal("record plus manifest organized", try await raw.store.organizeMetadata(), 2)
                r.check("legacy record removed only after copy", !raw.memory.fileExists(at: legacy))
                r.equal("new record exact bytes", raw.memory.fileBytes(at: target), sidecar)
                r.equal("DNG exact bytes preserved", raw.memory.fileBytes(at: raw.root.appendingPathComponent(path)), bytes)
                r.equal("unrelated user JSON kept", raw.memory.fileBytes(at: userJSON), Data("personal notes".utf8))
                r.equal("repeating organization is idempotent", try await raw.store.organizeMetadata(), 0)
                _ = await raw.store.selectRoot(from: raw.root)
                r.equal("organized library reconnects and classifies", try await raw.store.reconcile(onProgress: nil).verifiedOriginalCount, 1)
            } catch { r.check("organization path", false, "\(error)") }
        },
        TCCase(id: "RD03", title: "New layout manifest and sequences stay separate; a future layout is read-only") { r in
            guard let h = await StorageHarness.make(name: "redesign-new-layout") else { r.check("fixture", false); return }
            let manifestURL = h.root.appendingPathComponent(LibraryLayout.libraryManifestName)
            r.check("new manifest is in metadata", h.memory.fileExists(at: manifestURL))
            r.check("no root JSON created", !h.memory.fileExists(at: h.root.appendingPathComponent(LibraryLayout.legacyLibraryManifestName)))
            let sequenceID = SequenceID()
            let document = SequenceDocument(sequenceID: sequenceID, libraryID: h.libraryID, kind: .interval,
                plannedCount: 1, sourcePlan: [SequenceSourcePlanEntry(index: 0, offsetEV: nil, focusPosition: nil)],
                intervalSeconds: 1, baseline: nil, startedAtUTC: StorageFixture.fixedDate)
            do {
                try await h.store.writeSequenceDocument(document)
                r.check("new sequence in metadata", h.memory.fileExists(at: h.root.appendingPathComponent(LibraryLayout.metadataSequencePath(for: sequenceID))))
                r.equal("new sequence readable", try await h.store.readSequenceDocument(sequenceID).sequenceID, sequenceID.rawValue)
                var future = LibraryManifest(libraryID: h.libraryID)
                future.layoutVersion = 3
                let futureBytes = StorageFixture.manifestData(future)
                h.memory.setBytes(futureBytes, at: manifestURL)
                _ = await h.store.selectRoot(from: h.root)
                r.check("future layout cannot write", !h.store.rootState.isWritable)
                r.equal("future manifest preserved", h.memory.fileBytes(at: manifestURL), futureBytes)
            } catch { r.check("new layout path", false, "\(error)") }
        },
        TCCase(id: "DS08", title: "Unsupported priority gestures never replace legal intent; full Manual is directly reachable") { r in
            guard let h = await StorageHarness.make(name: "controls-priority-repair") else { r.check("storage fixture", false); return }
            let service = SyntheticCameraService(capability: controlFixture(modes: [.auto, .manual]))
            let model = await CameraViewModel(camera: service,
                capture: CaptureCoordinator(camera: ChainCameraSpy(), store: h.store, clock: SystemMonotonicClock()),
                metering: MeteringService(clock: SystemMonotonicClock()), levelFeed: SyntheticLevelFeed())
            await model.start()
            await MainActor.run {
                model.adoptCapability(controlFixture(modes: [.auto, .manual]))
                r.equal("only advertised modes offered", model.availableExposureModes, [.auto, .manual])
                r.check("shutter toggle into unsupported priority disabled", !model.canToggleShutterManual)
                r.check("ISO toggle into unsupported priority disabled", !model.canToggleISOManual)
                model.setShutterManual(true)
                model.setISOManual(true)
                model.setDuration(0.1)
                model.setISO(100)
                r.equal("refused gestures keep Auto", model.exposure, .auto)
                r.check("no runtime error banner for unsupported UI gesture", model.lastFailure == nil)
                model.setExposureMode(.manual)
                r.equal("both values selected atomically", model.exposure.mode, .manual)
                r.check("Manual is legal", model.appliesLegally())
                r.check("switching one parameter to unsupported Auto disabled", !model.canToggleShutterManual && !model.canToggleISOManual)
                model.setDuration(0.01)
                model.setISO(200)
                r.equal("manual values adjustable", model.exposure, .manual(durationSeconds: 0.01, iso: 200))
                model.setShutterManual(false)
                r.equal("refused independent Auto leaves full Manual", model.exposure.mode, .manual)
                model.setExposureMode(.auto)
                r.equal("both values return to Auto directly", model.exposure, .auto)
                model.setExposureMode(.isoPriority)
                r.equal("unsupported whole mode cannot block capture", model.exposure, .auto)
            }
            await model.stop()
        },
        TCCase(id: "DS09", title: "Supported independent controls preserve the other parameter") { r in
            guard let h = await StorageHarness.make(name: "controls-supported-repair") else { r.check("storage fixture", false); return }
            let model = await CameraViewModel(camera: SyntheticCameraService(),
                capture: CaptureCoordinator(camera: ChainCameraSpy(), store: h.store, clock: SystemMonotonicClock()),
                metering: MeteringService(clock: SystemMonotonicClock()), levelFeed: SyntheticLevelFeed())
            await MainActor.run {
                model.adoptCapability(controlFixture(modes: Set(ExposureModeKind.allCases)))
                r.check("supported shutter toggle available", model.canToggleShutterManual)
                model.setDuration(0.02)
                r.equal("one parameter yields shutter priority", model.exposure, .shutterPriority(durationSeconds: 0.02))
                model.setISO(320)
                r.equal("adding ISO preserves shutter", model.exposure, .manual(durationSeconds: 0.02, iso: 320))
                model.setShutterManual(false)
                r.equal("shutter Auto preserves locked ISO", model.exposure, .isoPriority(iso: 320))
                model.setISOManual(false)
                r.equal("both return to Auto", model.exposure, .auto)
            }
        },
        TCCase(id: "DS10", title: "Pending recovery is independent of errors and shutter admission, and excludes other camera sheets") { r in
            guard let h = await StorageHarness.make(name: "pending-menu-repair") else { r.check("storage fixture", false); return }
            let model = await CameraViewModel(camera: SyntheticCameraService(capability: controlFixture(modes: [.auto, .manual])),
                capture: CaptureCoordinator(camera: ChainCameraSpy(), store: h.store, clock: SystemMonotonicClock()),
                metering: MeteringService(clock: SystemMonotonicClock()), levelFeed: SyntheticLevelFeed())
            await model.start()
            await MainActor.run {
                model.adoptCapability(controlFixture(modes: [.auto, .manual]))
                model.updateRootState(.writable(libraryID: h.libraryID, generation: h.generation))
                model.updatePendingOriginalCount(1)
                r.check("pending blocks a second capture", !model.isShutterEnabled)
                r.check("no failure banner needed to route recovery", model.lastFailure == nil)
                model.isToolsSheetPresented = true
                model.isFolderSheetPresented = true
                model.openPanel = .iso
                model.showPendingRecovery()
                r.equal("recovery owns the camera sheet", model.presentedCameraSheet, .recovery)
                r.check("tools and folder flags cleared", !model.isToolsSheetPresented && !model.isFolderSheetPresented)
                r.check("parameter panel closed", model.openPanel == nil)
                model.presentedCameraSheet = nil
                r.check("dismiss clears modal state", !model.isRecoverySheetPresented)
                model.updatePendingOriginalCount(0)
                r.equal("verified retry clears pending recovery count", model.pendingOriginalCount, 0)
                r.check("capture admission reopens after verified pending count zero", model.isShutterEnabled)
            }
            await model.stop()
        },
        TCCase(id: "DS06", title: "Working photo RAW remains eligible when all explicit configurations lose DNG") { r in
            let photo = CaptureFormatFacts(index: 7,
                advertisedMaxPhotoDimensions: [.init(width: 4000, height: 3000)],
                bayerPixelFormatsForDNG: [1650943796], configurationMode: .photoPreset)
            let explicit = (0..<57).map { CaptureFormatFacts(index: $0,
                advertisedMaxPhotoDimensions: [.init(width: 8000, height: 6000)],
                bayerPixelFormatsForDNG: []) }
            let selected = CaptureTupleSelector.select(from: [photo] + explicit)
            r.equal("photo configuration is retained", selected?.configurationMode, .photoPreset)
            r.equal("format identity belongs to photo configuration", selected?.formatIndex, 7)
            r.equal("ceiling is from the RAW-capable configuration", selected?.requestedDimensions,
                    PixelDimensions(width: 4000, height: 3000))
            r.equal("all larger unsupported configurations disclosed", selected?.notes.count, 57)
            r.equal("later RAW loss still rejects, even with a selected photo candidate",
                    FinalTupleValidation.validate(finalBayerFormats: [], finalFileTypes: ["com.adobe.raw-image"],
                        candidateFileTypes: ["com.adobe.raw-image"]), .rejectNoBayerRAW)
        },
        TCCase(id: "DS07", title: "A larger verified explicit RAW tuple still wins over photo mode") { r in
            let photo = CaptureFormatFacts(index: 2,
                advertisedMaxPhotoDimensions: [.init(width: 4000, height: 3000)],
                bayerPixelFormatsForDNG: [1650943796], configurationMode: .photoPreset)
            let larger = CaptureFormatFacts(index: 3,
                advertisedMaxPhotoDimensions: [.init(width: 8000, height: 6000)],
                bayerPixelFormatsForDNG: [1650943796])
            let selected = CaptureTupleSelector.select(from: [photo, larger])
            r.equal("highest exposed eligible ceiling preserved", selected?.requestedDimensions,
                    PixelDimensions(width: 8000, height: 6000))
            r.equal("explicit configuration authority travels with selection", selected?.configurationMode, .explicitFormat)
        },
        TCCase(id: "DS01", title: "Initial RAW absence cannot veto another committed format") { r in
            var active = -1, events: [String] = []
            let result = CaptureFormatDiscovery.probe(candidates: [
                .init(index: 0, dimensions: [.init(width: 8000, height: 6000)]),
                .init(index: 1, dimensions: [.init(width: 4000, height: 3000)])
            ], activateAndCommit: { active = $0; events.append("commit\($0)") },
                dngIsAvailable: { events.append("dng\(active)"); return active == 1 },
                bayerFormatsForDNG: { events.append("raw\(active)"); return [0x62703136] })
            r.equal("both formats committed before their own queries", events,
                    ["commit0", "dng0", "commit1", "dng1", "raw1"])
            let selection = CaptureTupleSelector.select(from: result.facts)
            r.equal("usable later format selected", selection?.formatIndex, 1)
            r.equal("larger non-RAW ceiling never advertised as RAW", selection?.requestedDimensions,
                    PixelDimensions(width: 4000, height: 3000))
            r.equal("DNG availability is queried per candidate", result.dngCandidateCount, 1)
        },
        TCCase(id: "DS02", title: "Failed format activation is not borrowed as RAW evidence") { r in
            var active = -1, queries: [Int] = []
            let result = CaptureFormatDiscovery.probe(candidates: [
                .init(index: 0, dimensions: [.init(width: 8000, height: 6000)]),
                .init(index: 1, dimensions: [.init(width: 4000, height: 3000)])
            ], activateAndCommit: {
                if $0 == 0 { throw NSError(domain: "fixture", code: 1) }
                active = $0
            }, dngIsAvailable: { queries.append(active); return true },
                bayerFormatsForDNG: { [0x62703136] })
            r.equal("only successfully committed configuration queried", queries, [1])
            r.equal("activation error retained", result.activationFailures.count, 1)
            r.equal("failed high-resolution candidate excluded", CaptureTupleSelector.select(from: result.facts)?.formatIndex, 1)
            let none = CaptureFormatDiscovery.probe(candidates: [.init(index: 0,
                dimensions: [.init(width: 4000, height: 3000)])],
                activateAndCommit: { _ in }, dngIsAvailable: { false }, bayerFormatsForDNG: { [1] })
            r.check("no silent processed or borrowed RAW fallback", CaptureTupleSelector.select(from: none.facts) == nil)
        },
        TCCase(id: "DS03", title: "The exact picker URL reaches scope acquisition and library initialization") { r in
            let original = URL(string: "file:///provider/TruongCam/./Library/")!
            let driver = OriginalURLScopeDriver(original)
            let grant = BookmarkRootGrant(url: original, driver: driver)
            r.notEqual("fixture distinguishes canonical path from grant URL", original.absoluteString,
                       original.standardizedFileURL.absoluteString)
            r.check("original sandbox authority reaches driver", grant.beginAccess())
            grant.endAccess()
            r.equal("scope is balanced", driver.stopCount, 1)
            let memory = InMemoryFileSystemAdapter()
            try? memory.createDirectory(at: original, withIntermediateDirectories: true)
            let store = LibraryStore(adapter: memory, coordinator: DirectFileCoordinatorMutator(),
                supportDirectory: URL(fileURLWithPath: "/app/support"),
                temporaryDirectory: URL(fileURLWithPath: "/app/temp"),
                ownedContainerURLs: [URL(fileURLWithPath: "/app")],
                bookmarkStore: InMemoryRootBookmarkStore(), scopeDriver: driver,
                injectedLocalityVerdict: .userConfirmedLocalDestination(evidence: "synthetic local fixture"))
            _ = await store.selectRoot(from: original)
            r.check("root is writable after original-grant selection", store.rootState.isWritable)
            r.equal("published IO root retains the picked URL", store.grantedRootURL?.absoluteString, original.absoluteString)
            await store.releaseRoot()
            r.equal("store selection lease was genuinely started and released", driver.stopCount, 2)
        },
        TCCase(id: "DS05", title: "A path alias cannot make the app container a permanent library") { r in
            let base = StorageFixture.temporaryDirectory("own-container-alias")
            let owned = base.appendingPathComponent("app", isDirectory: true)
            let alias = base.appendingPathComponent("alias", isDirectory: true)
            do {
                try FileManager.default.createDirectory(at: owned, withIntermediateDirectories: true)
                try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: owned)
            } catch { r.check("isolated alias fixture", false, "\(error)"); return }
            defer { StorageFixture.removeDirectory(base) }
            let driver = OriginalURLScopeDriver(alias)
            let memory = InMemoryFileSystemAdapter()
            let store = LibraryStore(adapter: memory, coordinator: DirectFileCoordinatorMutator(),
                supportDirectory: owned.appendingPathComponent("support"),
                temporaryDirectory: owned.appendingPathComponent("temp"),
                ownedContainerURLs: [owned], bookmarkStore: InMemoryRootBookmarkStore(),
                scopeDriver: driver, injectedLocalityVerdict: .userConfirmedLocalDestination(evidence: "fixture"))
            let outcome = await store.selectRoot(from: alias)
            r.equal("aliased app container refused", outcome, .rejectedOwnContainer)
            r.equal("temporary scope closed on rejection", driver.stopCount, 1)
            r.check("no manifest or original written", memory.allPaths().isEmpty)
        },
        TCCase(id: "DS04", title: "A control gesture cannot mask a failed native preparation") { r in
            let failure = CaptureFailure(kind: .unsupportedCapability(detail: "fixture: no Bayer tuple"),
                                         operation: "prepare.selectTuple")
            let service = SyntheticCameraService(preparationFailure: failure)
            guard let harness = await StorageHarness.make(name: "device-startup-model") else {
                r.check("storage fixture", false); return
            }
            let model = await CameraViewModel(camera: service,
                capture: CaptureCoordinator(camera: ChainCameraSpy(), store: harness.store,
                    clock: SystemMonotonicClock()),
                metering: MeteringService(clock: SystemMonotonicClock()),
                levelFeed: SyntheticLevelFeed())
            await model.start()
            await MainActor.run { model.setDuration(0.1) }
            try? await Task.sleep(nanoseconds: 40_000_000)
            r.equal("no setter issued against failed graph", await service.controlApplyCount, 0)
            r.equal("real startup failure has friendly copy", await model.lastFailure?.detail, UserFacingFailure.message(for: failure))
            r.equal("persistent surface carries failure", await model.surface,
                    .unsupportedBayer(detail: failure.kind.userDescription))
            await model.stop()
        }
    ])
}

// Synthetic native boundary with a deliberately nonconverging live 3A feed.
// Only the observation/settlement release is fake; capture admission, ticket
// ownership, durable staging, verified folder commit and metadata are production.
private func responsiveIntent(h: StorageHarness, mode: CaptureMode = .single,
                              sequenceID: SequenceID? = nil, exposure: ExposureChoice = .auto,
                              focus: FocusIntent = FocusIntent(mode: .continuousAuto, position: nil, pointOfInterest: nil),
                              wb: WhiteBalanceIntent = WhiteBalanceIntent(mode: .auto, temperatureAndTint: nil)) -> CaptureIntent {
    CaptureIntent(captureID: CaptureID(), libraryID: h.libraryID, sequenceID: sequenceID,
        requestedDimensions: PixelDimensions(width: 4032, height: 3024), exposure: exposure, biasEV: 0,
        focus: focus, whiteBalance: wb, configurationGeneration: .zero, rootGeneration: h.generation,
        physicalCameraKind: .wide, createdAtUTC: StorageFixture.fixedDate, timezoneOffsetSeconds: 0, mode: mode)
}
private func responsiveReading(revision: UInt64, generation: ConfigurationGeneration = .zero,
                               exposure: ExposureChoice = .auto, bias: Double = 0,
                               duration: Double? = 0.01, iso: Double? = 100, position: Double? = 0.4,
                               gains: WhiteBalanceGains? = WhiteBalanceGains(red: 1.4, green: 1, blue: 1.6),
                               focusMode: FocusModeKind = .continuousAuto,
                               wbMode: WhiteBalanceModeKind = .auto) -> AppliedControlSnapshot {
    AppliedControlSnapshot(generation: generation, requestRevision: revision, settlement: .moving,
        isExposureAdjusting: true, isFocusAdjusting: true, isWhiteBalanceAdjusting: true,
        exposureChoice: exposure, biasEV: bias, observedDurationSeconds: duration,
        observedISO: iso, observedExposureTargetOffset: 0, focusMode: focusMode,
        focusPosition: position, whiteBalanceMode: wbMode, whiteBalanceGains: gains,
        lensAperture: 1.6, videoZoomFactor: 1, photoConnectionScale: 1, photoConnectionCrop: 1,
        capturedAtUTC: Date())
}
private actor ResponsiveAutoCamera: CaptureCameraSurface {
    let native: ChainCameraSpy
    private var observation: AppliedControlSnapshot?
    private var settledAllowed = false
    private(set) var readCount = 0
    let liveAcknowledgement: Bool
    init(native: ChainCameraSpy, liveAcknowledgement: Bool = false) { self.native = native; self.liveAcknowledgement = liveAcknowledgement }
    var lifecycle: CameraLifecycle { .running }
    var capabilitySnapshot: CameraCapabilitySnapshot { .empty(generation: .zero, reason: "synthetic moving 3A") }
    func applyControls(revision: UInt64, exposure: ExposureChoice, biasEV: Double,
                       focus: FocusIntent, whiteBalance: WhiteBalanceIntent, aperture: ApertureChoice = .auto) async -> Result<AppliedControlSnapshot, CaptureFailure> {
        let live = responsiveReading(revision: revision, exposure: exposure, bias: biasEV,
            duration: exposure.durationTargetSeconds ?? 0.01, iso: exposure.isoTarget ?? 100,
            position: focus.position ?? 0.4, focusMode: focus.mode, wbMode: whiteBalance.mode)
        observation = live
        var acknowledgement = live; acknowledgement.settlement = liveAcknowledgement ? .moving : .awaitingObservation
        return .success(acknowledgement)
    }
    func currentControlReadback() async -> AppliedControlSnapshot? {
        readCount += 1
        guard var live = observation else { return nil }
        if settledAllowed {
            live.settlement = .settled
            live.isExposureAdjusting = false; live.isFocusAdjusting = false; live.isWhiteBalanceAdjusting = false
        }
        return live
    }
    func allowSettlement() { settledAllowed = true }
    func beginCapture(intent: CaptureIntent) async -> any CaptureRequestTicket { await native.beginCapture(intent: intent) }
}

// Deliberate live observations, never inferred from a desired manual target.
private func hardwareAutoReading(_ snapshot: AppliedControlSnapshot, invalidVariant: Int? = nil) -> AppliedControlSnapshot {
    var reading = AppliedControlSnapshot(
        generation: invalidVariant == 1 ? ConfigurationGeneration(snapshot.generation.value + 1) : snapshot.generation,
        requestRevision: invalidVariant == 2 ? (snapshot.requestRevision ?? 0) + 1 : snapshot.requestRevision,
        settlement: invalidVariant == 3 ? .awaitingObservation : .moving,
        exposureChoice: snapshot.exposureChoice, biasEV: snapshot.biasEV,
        observedDurationSeconds: invalidVariant == 0 ? nil : invalidVariant == 5 ? .nan : 0.02,
        observedISO: 320, observedExposureTargetOffset: 0, focusMode: snapshot.focusMode,
        focusPosition: 0.42, whiteBalanceMode: snapshot.whiteBalanceMode, whiteBalanceGains: WhiteBalanceGains(red: 1.4,green: 1,blue: 1.6),
        lensAperture: 1.6, videoZoomFactor: 1, photoConnectionScale: 1, photoConnectionCrop: 1,
        capturedAtUTC: invalidVariant == 4 ? Date(timeIntervalSinceNow: -10) : Date())
    reading.observedWhiteBalanceTemperatureAndTint = WhiteBalanceTemperatureAndTint(temperature: 4700, tint: 12)
    return reading
}
