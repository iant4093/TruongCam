import Foundation
import Synchronization
#if canImport(XCTest)
@testable import TruongCam
#endif

/// Real request/ticket/drain/store/sequence code, synthetic callback bytes and
/// faults. No native image, hardware failure or phone timing is measured.
private actor FifthTerminalCamera: CaptureCameraSurface {
    enum Terminal: Sendable { case success, nativeFailure, representationFailure }
    let terminal: Terminal
    let controls = ChainCameraSpy()
    private(set) var submissions = 0
    init(_ terminal: Terminal) { self.terminal = terminal }
    var lifecycle: CameraLifecycle { .running }
    var capabilitySnapshot: CameraCapabilitySnapshot { get async { await controls.capabilitySnapshot } }
    func applyControls(revision: UInt64, exposure: ExposureChoice, biasEV: Double,
                       focus: FocusIntent, whiteBalance: WhiteBalanceIntent) async -> Result<AppliedControlSnapshot, CaptureFailure> {
        await controls.applyControls(revision: revision, exposure: exposure, biasEV: biasEV, focus: focus, whiteBalance: whiteBalance)
    }
    func currentControlReadback() async -> AppliedControlSnapshot? { await controls.currentControlReadback() }
    func beginCapture(intent: CaptureIntent) async -> any CaptureRequestTicket {
        submissions += 1
        let (request, ticket) = FifthCameraReviewSuite.request(intent, nativeID: Int64(submissions))
        _ = request.recordRepresentation(FifthCameraReviewSuite.representation(intent, nativeID: ticket.uniqueSettingsID))
        switch terminal {
        case .success: _ = request.recordNativeTerminal(settingsID: ticket.uniqueSettingsID, mappedFailure: nil)
        case .nativeFailure: _ = request.recordNativeTerminal(settingsID: ticket.uniqueSettingsID, mappedFailure: FifthCameraReviewSuite.nativeFailure)
        case .representationFailure:
            request.noteRepresentationError("Synthetic thumbnail omission failed; original retained")
            _ = request.recordNativeTerminal(settingsID: ticket.uniqueSettingsID, mappedFailure: nil)
        }
        return ticket
    }
}

enum FifthCameraReviewSuite {
    static let nativeFailure = CaptureFailure(kind: .cameraInterrupted(detail: "Synthetic native terminal interruption"),
        operation: "capturePhoto", retainedSourceStatus: .inMemoryRepresentationUnstaged,
        nsErrorDomain: "fifth.synthetic.camera", nsErrorCode: -47, underlyingDescription: "Synthetic native detail")
    static func intent(_ h: StorageHarness) -> CaptureIntent {
        CaptureIntent(captureID: CaptureID(), libraryID: h.libraryID,
            requestedDimensions: PixelDimensions(width: 4032, height: 3024), exposure: .auto, biasEV: 0,
            focus: FocusIntent(mode: .continuousAuto, position: nil, pointOfInterest: nil),
            whiteBalance: WhiteBalanceIntent(mode: .auto, temperatureAndTint: nil), configurationGeneration: .zero,
            rootGeneration: h.generation, physicalCameraKind: .wide, createdAtUTC: StorageFixture.fixedDate,
            timezoneOffsetSeconds: 0, mode: .single)
    }
    static func request(_ intent: CaptureIntent, nativeID: Int64 = 47) -> (PerCaptureRequest, CameraCaptureTicket) {
        let request = PerCaptureRequest(captureID: intent.captureID, intent: intent, rawPixelFormatType: 0x4247_4734,
            rawFileType: "com.adobe.raw-image", maximumRepresentations: 1)
        _ = request.bindNativeSettingsID(nativeID)
        return (request, CameraCaptureTicket(captureID: intent.captureID, uniqueSettingsID: nativeID, request: request))
    }
    static func representation(_ intent: CaptureIntent, nativeID: Int64 = 47) -> DeliveredRAWRepresentation {
        DeliveredRAWRepresentation(bytes: StorageFixture.rawBytes(), captureID: intent.captureID,
            resolvedSettingsUniqueID: nativeID, nativeBracketIdentity: nil, rawPixelFormatType: 0x4247_4734,
            rawFileType: "com.adobe.raw-image", rawPhotoDimensions: intent.requestedDimensions,
            rawPixelBufferDimensions: intent.requestedDimensions, timestampSeconds: nil, metadata: [:])
    }
    static let suite = TCSuite(id: "FifthCameraReview", title: "Native diagnostics and exact retained ownership survive capture and sequence adapters", cases: [
        TCCase(id: "FC47N", title: "A zero-source native error keeps its typed diagnostic instead of a generic persistence failure") { r in
            guard let h = await StorageHarness.make(name: "fc47-native-empty") else { r.check("fixture", false); return }
            let intent = Self.intent(h), (request, ticket) = Self.request(intent)
            r.check("foreign terminal cannot finish the request", request.recordNativeTerminal(settingsID: 48, mappedFailure: nativeFailure) == nil)
            r.check("foreign callback cannot publish a diagnostic", ticket.terminalFailure() == nil)
            _ = request.recordNativeTerminal(settingsID: 47, mappedFailure: nativeFailure)
            let late = CaptureFailure(kind: .captureFailed(detail: "Late duplicate"), operation: "late")
            _ = request.recordNativeTerminal(settingsID: 47, mappedFailure: late)
            r.equal("first native diagnostic remains immutable", ticket.terminalFailure(), nativeFailure)
            let capture = CaptureCoordinator(camera: ChainCameraSpy(), store: h.store, clock: SystemMonotonicClock())
            let result = await capture.drain(ticket: ticket, intent: intent)
            let mapped = CaptureSequenceExecutor.executionResult(for: result, intent: intent)
            r.equal("one native diagnostic carried", result.failures.count, 1)
            r.equal("native error kind preserved", mapped.failure?.kind, nativeFailure.kind)
            r.equal("native operation preserved", mapped.failure?.operation, nativeFailure.operation)
            r.equal("native domain preserved", mapped.failure?.nsErrorDomain, nativeFailure.nsErrorDomain)
            r.equal("native code preserved", mapped.failure?.nsErrorCode, nativeFailure.nsErrorCode)
            r.equal("underlying detail preserved", mapped.failure?.underlyingDescription, nativeFailure.underlyingDescription)
            r.equal("no historical in-memory retention claimed", mapped.failure?.retainedSourceStatus, RetainedSourceStatus.none)
            r.check("no fabricated retained source", !result.didRetainAnything && mapped.stagedHandle == nil && mapped.receipt == nil)
            if case .failed(let failure) = mapped.persistence { r.equal("persistence exposes actual native error", failure.kind, nativeFailure.kind) }
            else { r.check("zero-source persistence fails", false) }
        },
        TCCase(id: "FC47P", title: "Native partial errors retain exact committed or pending bytes and all native diagnostics") { r in
            for failPublication in [false, true] {
                guard let h = await StorageHarness.make(name: "fc47-native-partial-\(failPublication)") else { r.check("fixture", false); continue }
                let intent = Self.intent(h), (request, ticket) = Self.request(intent)
                r.check("real owner accepts representation", request.recordRepresentation(Self.representation(intent)))
                if failPublication { h.fault.armMove(destinationSuffix: h.finalURL(for: intent.captureID).lastPathComponent) }
                _ = request.recordNativeTerminal(settingsID: 47, mappedFailure: nativeFailure)
                if case .partial(let count, _) = await ticket.awaitTerminal() { r.equal("native partial count", count, 1) }
                else { r.check("retained native failure is partial", false) }
                r.equal("partial retains typed terminal error", ticket.terminalFailure(), nativeFailure)
                let result = await CaptureCoordinator(camera: ChainCameraSpy(), store: h.store, clock: SystemMonotonicClock()).drain(ticket: ticket, intent: intent)
                let mapped = CaptureSequenceExecutor.executionResult(for: result, intent: intent)
                let native = result.failures.first { $0.nsErrorDomain == nativeFailure.nsErrorDomain }
                r.equal("native domain and code survive drain", native?.nsErrorCode, -47)
                r.equal("native operation survives drain", native?.operation, "capturePhoto")
                r.equal("underlying native description survives drain", native?.underlyingDescription, nativeFailure.underlyingDescription)
                r.check("partial is never silently successful", mapped.failure != nil)
                if failPublication {
                    r.equal("actual provider fault", h.fault.injectedFailureCount, 1)
                    r.equal("one exact pending handle", result.pendingHandles.count, 1)
                    if let handle = result.pendingHandles.first {
                        r.equal("native diagnostic refers only to current owned staging", native?.retainedSourceStatus, .durableInternalStaging(relativePath: handle.pendingRelativePath))
                        r.equal("pending bytes unchanged", h.memory.fileBytes(at: h.pendingSourceURL(for: intent.captureID)), StorageFixture.rawBytes())
                        r.equal("adapter transfers exact owned handle", mapped.stagedHandle, handle)
                    }
                } else {
                    r.equal("committed original preserved", result.savedToFolderCount, 1)
                    r.equal("committed bytes unchanged", h.memory.fileBytes(at: h.finalURL(for: intent.captureID)), StorageFixture.rawBytes())
                    r.equal("no stale native memory claim after commit", native?.retainedSourceStatus, RetainedSourceStatus.none)
                    r.equal("adapter preserves native diagnostic", mapped.failure?.nsErrorCode, -47)
                    r.check("actual receipt still denotes committed source", mapped.persistence.isCommitted)
                }
            }
        },
        TCCase(id: "FC47S", title: "A retained partial source stops future sequence frames while positive acquisition remains complete") { r in
            for terminal in [FifthTerminalCamera.Terminal.success, .nativeFailure, .representationFailure] {
                guard let h = await StorageHarness.make(name: "fc47-sequence-\(terminal)") else { r.check("fixture", false); continue }
                let camera = FifthTerminalCamera(terminal), clock = SystemMonotonicClock()
                let capture = CaptureCoordinator(camera: camera, store: h.store, clock: clock)
                let pipeline = SequenceSourcePipeline(executor: CaptureSequenceExecutor(capture: capture))
                let settings = SeqFakeSettings(current: SequenceSettingsSnapshot(configurationGeneration: .zero, revision: 1,
                    exposure: .auto, biasEV: 0, focus: FocusIntent(mode: .continuousAuto, position: nil, pointOfInterest: nil),
                    whiteBalance: WhiteBalanceIntent(mode: .auto, temperatureAndTint: nil), maxDimensions: PixelDimensions(width: 4032, height: 3024)))
                let coordinator = SequenceCoordinator(environment: SequenceCoordinator.Environment(clock: clock,
                    wallClock: StorageFixture.fixedClock(), storage: LibraryStoreSequenceAdapter(store: h.store), pipeline: pipeline,
                    settings: settings, baselineSettler: SyntheticBaselineSettler(), bracketSubmitter: UnavailableNativeBracketSubmitter(),
                    focusDriver: FocusBracketDriver(clock: clock, controller: SyntheticFocusController(), pipeline: pipeline),
                    capability: SeqFakeCapabilityProvider(context: tcSeqCapability())))
                let isSuccess: Bool = if case .success = terminal { true } else { false }
                let plan = SequencePlan(libraryID: h.libraryID, configurationGeneration: .zero, rootGeneration: h.generation,
                    physicalCameraKind: .wide, kind: .interval, specification: .interval(IntervalPlan(count: isSuccess ? 1 : 3, intervalSeconds: 5)),
                    createdAtUTC: StorageFixture.fixedDate)
                let result = await coordinator.start(plan)
                r.equal("only the first source submits", await camera.submissions, 1)
                r.equal("intact acquired original is committed", result.committedReceipts.count, 1)
                r.equal("terminal status respects actual acquisition", result.status, isSuccess ? .complete : .failed)
                r.check("no pending source invented", result.retainedHandles.isEmpty)
                if !isSuccess {
                    r.check("error is visible in the sequence result", result.failure != nil)
                    if case .nativeFailure = terminal { r.equal("typed native diagnostic reaches sequence", result.failure?.nsErrorCode, -47) }
                    else { r.equal("representation warning reaches sequence", result.failure?.kind.stableCode, "representationUnavailable") }
                    r.equal("future ordinals remain missing", result.progress.missingOrdinals, [1, 2])
                } else { r.check("positive result has no spurious error", result.failure == nil) }
                do {
                    let doc = try await h.store.readSequenceDocument(plan.sequenceID)
                    r.equal("durable sequence status agrees", doc.status, result.status)
                    r.equal("committed original stays in durable sequence", doc.completedSources.count, 1)
                } catch { r.check("actual sequence document readable", false, String(describing: error)) }
            }
        },
        TCCase(id: "FC47A", title: "Adapter preserves terminal-only diagnostics and does not manufacture retained handles") { r in
            guard let h = await StorageHarness.make(name: "fc47-adapter") else { r.check("fixture", false); return }
            let intent = Self.intent(h)
            let result = CaptureRequestResult(captureID: intent.captureID, acquisition: .failed(nativeFailure),
                committedReceipts: [], pendingTransactionIDs: [], failures: [])
            let mapped = CaptureSequenceExecutor.executionResult(for: result, intent: intent)
            r.equal("legacy terminal-only kind preserved", mapped.failure?.kind, nativeFailure.kind)
            r.equal("legacy terminal-only operation preserved", mapped.failure?.operation, nativeFailure.operation)
            r.equal("legacy terminal-only domain preserved", mapped.failure?.nsErrorDomain, nativeFailure.nsErrorDomain)
            r.equal("legacy terminal-only code preserved", mapped.failure?.nsErrorCode, nativeFailure.nsErrorCode)
            r.equal("legacy terminal-only detail preserved", mapped.failure?.underlyingDescription, nativeFailure.underlyingDescription)
            r.equal("legacy native memory claim is not current retention", mapped.failure?.retainedSourceStatus, RetainedSourceStatus.none)
            r.check("native failure never establishes byte ownership", mapped.stagedHandle == nil && !mapped.persistence.isDurablyStaged)
            do {
                let foreign = Self.intent(h)
                let foreignHandle = try await h.store.stageSource(bytes: StorageFixture.rawBytes(),
                    metadata: StorageFixture.metadata(captureID: foreign.captureID, libraryID: h.libraryID))
                let ownHandle = try await h.store.stageSource(bytes: StorageFixture.rawBytes(),
                    metadata: StorageFixture.metadata(captureID: intent.captureID, libraryID: h.libraryID))
                for (handle, transactions) in [(foreignHandle, [foreignHandle.transactionID]), (ownHandle, [])] {
                    let stale = CaptureFailure(kind: nativeFailure.kind, operation: nativeFailure.operation,
                        retainedSourceStatus: .durableInternalStaging(relativePath: handle.pendingRelativePath),
                        nsErrorDomain: nativeFailure.nsErrorDomain, nsErrorCode: nativeFailure.nsErrorCode,
                        underlyingDescription: nativeFailure.underlyingDescription)
                    let boundary = CaptureRequestResult(captureID: intent.captureID, acquisition: .failed(stale),
                        committedReceipts: [], pendingTransactionIDs: transactions, failures: [], pendingHandles: [handle])
                    let refused = CaptureSequenceExecutor.executionResult(for: boundary, intent: intent)
                    r.equal("foreign or unconfirmed stage cannot transfer a path claim", refused.failure?.retainedSourceStatus, RetainedSourceStatus.none)
                    r.equal("refusing stale authority keeps native diagnostic", refused.failure?.nsErrorCode, nativeFailure.nsErrorCode)
                    r.check("foreign or unconfirmed handle is refused", refused.stagedHandle == nil && !refused.persistence.isDurablyStaged)
                }
                let owned = CaptureRequestResult(captureID: intent.captureID, acquisition: .failed(nativeFailure),
                    committedReceipts: [], pendingTransactionIDs: [ownHandle.transactionID], failures: [], pendingHandles: [ownHandle])
                let accepted = CaptureSequenceExecutor.executionResult(for: owned, intent: intent)
                r.equal("accepted exact source alone authorizes current path", accepted.failure?.retainedSourceStatus,
                    .durableInternalStaging(relativePath: ownHandle.pendingRelativePath))
                r.equal("accepted exact source transfers its handle", accepted.stagedHandle, ownHandle)
                r.equal("owned-source diagnostic keeps native details", accepted.failure?.underlyingDescription, nativeFailure.underlyingDescription)
            } catch { r.check("adapter exact-ownership fixtures", false, String(describing: error)) }
            let partial = CaptureRequestResult(captureID: intent.captureID, acquisition: .partial(retainedSourceCount: 1, description: "Synthetic acquisition warning"),
                committedReceipts: [], pendingTransactionIDs: [], failures: [])
            let partialMapped = CaptureSequenceExecutor.executionResult(for: partial, intent: intent)
            r.check("legacy partial warning is not hidden", partialMapped.failure?.kind.userDescription.contains("Synthetic acquisition warning") == true)
            r.check("claimed native count does not invent ownership", partialMapped.stagedHandle == nil && !partialMapped.persistence.isDurablyStaged)
            let success = CaptureRequestResult(captureID: intent.captureID, acquisition: .success, committedReceipts: [], pendingTransactionIDs: [], failures: [])
            let emptyMapped = CaptureSequenceExecutor.executionResult(for: success, intent: intent)
            r.equal("true unexplained no-source result keeps generic safety failure", emptyMapped.failure?.operation, "sequence.capture.persist")
        },
        TCCase(id: "FC47B", title: "Delivered bracket persistence transfers a pending source only when exact current staging survives") { r in
            for outcome in 0..<3 {
                guard let h = await StorageHarness.make(name: "fc47-delivered-\(outcome)") else { r.check("fixture", false); continue }
                let intent = Self.intent(h), removed = Mutex(0)
                if outcome == 1 { h.fault.armMove(destinationSuffix: h.finalURL(for: intent.captureID).lastPathComponent) }
                if outcome == 2 {
                    h.fault.setObserver { event in
                        guard event.kind == .move, event.destinationRelativePath == "PendingCaptures/\(intent.captureID.description)/sidecar.json" else { return }
                        do { try h.memory.removeItem(at: h.pendingSourceURL(for: intent.captureID)); removed.withLock { $0 += 1 } } catch { }
                    }
                }
                let capture = CaptureCoordinator(camera: ChainCameraSpy(), store: h.store, clock: SystemMonotonicClock())
                let result = await LibrarySequencePersister(capture: capture).persist(Self.representation(intent), intent: intent)
                h.fault.setObserver(nil)
                switch outcome {
                case 0:
                    r.check("positive delivered source commits", result.persistence.isCommitted && result.receipt != nil && result.failure == nil)
                    r.equal("verified original unchanged", h.memory.fileBytes(at: h.finalURL(for: intent.captureID)), StorageFixture.rawBytes())
                case 1:
                    r.equal("provider fault actually fired", h.fault.injectedFailureCount, 1)
                    r.check("surviving pending original transferred", result.persistence.isDurablyStaged && result.stagedHandle != nil)
                    if let handle = result.stagedHandle {
                        r.equal("pending proof is exact", result.failure?.retainedSourceStatus, .durableInternalStaging(relativePath: handle.pendingRelativePath))
                        r.equal("pending bytes unchanged", h.memory.fileBytes(at: h.pendingSourceURL(for: intent.captureID)), StorageFixture.rawBytes())
                    }
                default:
                    r.equal("actual staged original removed before commit", removed.withLock { $0 }, 1)
                    r.check("missing staging bytes actually absent", !h.memory.fileExists(at: h.pendingSourceURL(for: intent.captureID)))
                    r.check("historical handle not transferred", result.stagedHandle == nil && !result.persistence.isDurablyStaged)
                    r.equal("missing bytes failure has no retention", result.failure?.retainedSourceStatus, RetainedSourceStatus.none)
                    if case .failed = result.terminalStatus { r.check("missing original fails acquisition", true) }
                    else { r.check("missing original fails acquisition", false) }
                }
            }
        }
    ])
}
