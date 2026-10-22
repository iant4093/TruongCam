import Foundation
import Observation
import SwiftUI
import Synchronization

// CONTRACTS.md "Semantic interfaces": AppCoordinator owns onboarding,
// permissions, navigation and display snapshots. All UI state is MainActor. It
// forwards commands to services and never performs native configuration or disk
// work itself.
//
// Until the real LibraryStore is installed (see IMPLEMENTATION_REPORT.md), this
// coordinator leaves the library root `unselected`: the app reports that no
// folder is selected rather than pretending the sandbox is a library.

@MainActor
@Observable
final class AppCoordinator {
    let environment: AppEnvironment
    private var cameraService: AVCaptureCameraService?
    private var captureCoordinator: CaptureCoordinator?
    private var metering: MeteringService?
    private var sequenceCoordinator: SequenceCoordinator?
    private(set) var librarySession: LibrarySessionCoordinator?

    private(set) var exportPresenter: ExportPresenter

    /// Observable service-graph state.
    ///
    /// REVIEW.md S03: `CameraScreen.task` returned immediately when `app.camera`
    /// was still nil, and the graph was attached by a parent task, so attachment
    /// could happen after the only startup attempt and recomputing the body gave
    /// no guarantee that a stable `.task` restarts. The graph is now started once,
    /// its progress is observable, and the camera view starts the camera when the
    /// state is genuinely ready rather than at whatever moment its task ran.
    enum GraphState: Hashable, Sendable {
        case idle
        case starting
        case ready
        case failed(reason: String)

        var isReady: Bool { self == .ready }
    }

    private(set) var graphState: GraphState = .idle
    private var startTask: Task<Void, Never>?

    init(environment: AppEnvironment) {
        self.environment = environment
        self.exportPresenter = ExportPresenter(store: environment.libraryStore)
        environment.exportPresenter = self.exportPresenter
    }

    /// Starts the graph exactly once. Repeated requests are ignored, so a view
    /// that appears twice, or a scene that reactivates, cannot build two camera
    /// services or two sequence coordinators (REVIEW.md S03).
    @discardableResult
    func startOnce(store: (any LibraryStoring)?, index: (any LibraryIndexing)?) async -> GraphState {
        switch graphState {
        case .ready, .starting:
            return graphState
        case .idle, .failed:
            break
        }
        graphState = .starting
        environment.graphState = .starting
        await start(store: store, index: index)
        graphState = environment.camera == nil
            ? .failed(reason: "The camera service could not be constructed.")
            : .ready
        environment.graphState = graphState
        return graphState
    }

    /// Builds the production service graph.
    ///
    /// `store` and `index` are supplied by the caller so this type never creates
    /// a placeholder that could pretend a permanent library exists.
    func start(store: (any LibraryStoring)?, index: (any LibraryIndexing)?) async {
        // Construct only the lightweight provider. Native renderers/codecs are
        // lazy and run on the lease-owning worker when an actual image needs them.
        // Synthetic warm-up took 9.4 seconds on the human's cold install and must
        // neither compete with camera startup nor hold first capture admission.
        let thumbnailPreparation = Task.detached(priority:.utility) {
            LibraryStoreFactory.makeDefaultThumbnails()
        }
        let metering = MeteringService(clock: SystemMonotonicClock())
        // The camera service owns the acquisition-time generation source; the
        // bridge shares that exact instance so stamps and samples agree.
        let analysisSink = MeteringAnalysisBridge(metering: metering)
        // Native capture object construction can load frameworks synchronously.
        // Build this owned actor away from MainActor so first launch stays responsive.
        let nativeServices = await Task.detached(priority: .userInitiated) {
            #if DEBUG
            let began = ProcessInfo.processInfo.systemUptime
            defer { print("TruongCam timing camera-construction=\(Int((ProcessInfo.processInfo.systemUptime - began) * 1000))ms context=detached") }
            #endif
            // CoreMotion's manager can also initialize native framework state.
            // Construct it beside the camera, away from the UI executor; motion
            // updates still start only when the visible camera requests the level.
            return (camera: AVCaptureCameraService(analysisSink: analysisSink), level: CoreMotionLevelFeed())
        }.value
        let cameraService = nativeServices.camera
        await analysisSink.attach(generation: cameraService.analysisGeneration)
        let capture = CaptureCoordinator(
            camera: cameraService,
            store: store ?? UnavailableLibraryStore.shared,
            clock: SystemMonotonicClock(),
            // The framework decides what is Bayer RAW; the coordinator never guesses
            // from FourCC spelling (REVIEW.md R05).
            bayerClassifier: SystemBayerRAWClassifier())

        self.cameraService = cameraService
        self.captureCoordinator = capture
        self.metering = metering

        let viewModel = CameraViewModel(
            camera: cameraService,
            capture: capture,
            metering: metering,
            levelFeed: nativeServices.level,
            resourceMonitor: SystemCameraResourcePressureMonitor())
        environment.attach(camera: viewModel)

        // Sequences. Every port below is injected; the coordinator itself never
        // touches a device or the file system.
        if let store {
            let pipeline = SequenceSourcePipeline(
                executor: CaptureSequenceExecutor(capture: capture),
                persister: LibrarySequencePersister(capture: capture))
            let settings = CameraSequenceSettingsControl(camera: viewModel)
            let sequenceEnvironment = SequenceCoordinator.Environment(
                clock: SystemMonotonicClock(),
                wallClock: SystemWallClock(),
                storage: LibraryStoreSequenceAdapter(store: store),
                pipeline: pipeline,
                settings: settings,
                baselineSettler: BaselineSettler(
                    clock: SystemMonotonicClock(),
                    sampler: CameraBaselineSampler(camera: viewModel, clock: SystemMonotonicClock())),
                bracketSubmitter: UnavailableNativeBracketSubmitter(),
                focusDriver: FocusBracketDriver(
                    clock: SystemMonotonicClock(),
                    controller: viewModel,
                    pipeline: pipeline),
                capability: CameraSequenceCapabilityProvider(camera: viewModel),
                admission: .provisional)
            let coordinator = SequenceCoordinator(environment: sequenceEnvironment)
            self.sequenceCoordinator = coordinator
            viewModel.attach(sequence: coordinator)
        }
        if let store, let index {
            environment.attach(store: store, index: index)
            exportPresenter = ExportPresenter(store: store)
            environment.exportPresenter = exportPresenter
            // REVIEW.md C06: reconnect/rebuild the gallery on ordinary launch and
            // ingest verified commits into the derived index.
            let session = LibrarySessionCoordinator(store: store, index: index)
            librarySession = session
            environment.attach(librarySession: session)
            // Wire commit ingestion and folder actions to this session.
            viewModel.onCommittedReceipts = { [weak environment] receipts in
                await environment?.ingestCommitted(receipts)
            }
            // REVIEW.md F06: a finished sequence must reach the SAME consumers as a
            // single capture — verified receipt ingestion, refreshed pending
            // recovery state, and a refreshed library view.
            viewModel.onPendingOriginalsChanged = { [weak environment] _ in
                await environment?.refreshPendingOriginals()
            }
            viewModel.onSequenceFinished = { [weak environment, weak viewModel] _ in
                await environment?.refreshAfterSequence(sequenceID: viewModel?.lastFinishedSequenceDocumentID)
            }
            // Service graph is usable now. A potentially large library rebuild
            // must not hold camera preview startup behind disk/index work.
            graphState = .ready
            environment.graphState = .ready
            if let thumbnails = await thumbnailPreparation.value {
                environment.attachThumbnails(store: store, thumbnails: thumbnails)
            }
            environment.launchResourcesReady = true
            await session.reconnectOnLaunch()
            await environment.library?.loadFirstPage()
        } else {
            _ = await thumbnailPreparation.value
            environment.launchResourcesReady = true
        }
        environment.refreshLibraryRootState()
    }

    func stop() async {
        await cameraService?.stop()
    }
}

/// Adapts the metering service to the camera service's analysis sink and to the
/// video-data sample consumer.
///
/// REVIEW.md C08: this type used to rebuild the analysis request from a hardcoded
/// set of defaults on every geometry change, so a user's peaking threshold, zebra
/// threshold and loupe magnification/centre were silently replaced. It now stores
/// the request the UI supplied and only refreshes the generation stamp.
///
/// Ownership invariant for the narrow `@unchecked Sendable`: `state` is only
/// touched while `mutex` holds it, and the lock is never held across an `await`.
final class MeteringAnalysisBridge: PreviewAnalysisSink, AnalysisSampleConsumer, @unchecked Sendable {
    private struct State {
        var request: AnalysisRequest?
        var geometry: PreviewGeometrySnapshot?
        /// The demand the UI asked for even when geometry was not yet available.
        /// REVIEW.md S07: a request arriving before geometry was dropped, so
        /// analysis stayed off until an unrelated geometry change happened.
        var pendingDemand: AnalysisDemand?
        var pendingTools: (peaking: Double, zebra: Double,
                           loupeCenter: NormalizedDevicePoint, loupeMagnification: Double)?
    }

    private let metering: MeteringService
    private let mutex = Mutex(State())

    init(metering: MeteringService) {
        self.metering = metering
    }

    /// Shares the camera service's acquisition-time generation source.
    func attach(generation: SessionGenerationSource) async {
        _ = generation
    }

    func setAnalysisRequest(_ request: AnalysisRequest?) async {
        let snapshot = mutex.withLock { state -> State in
            guard let request else {
                state.request = nil
                state.pendingDemand = nil
                state.pendingTools = nil
                return state
            }
            state.request = request
            if let geometry = request.geometry {
                state.geometry = geometry
                state.pendingDemand = nil
                state.pendingTools = nil
            } else {
                // Remember the intent so the request can be completed coherently
                // once geometry exists.
                state.pendingDemand = request.demand
                state.pendingTools = (request.peakingThreshold, request.zebraThreshold,
                                      request.loupeCenter, request.loupeMagnification)
            }
            return state
        }
        await push(snapshot)
    }

    func updateGeometry(_ geometry: PreviewGeometrySnapshot?) async {
        let snapshot = mutex.withLock { state -> State in
            guard let geometry else { return state }
            state.geometry = geometry
            // Complete the coherent request that could not be built before:
            // the user's settings are preserved and only the generation stamp and
            // geometry are refreshed.
            if var pending = state.request, let demand = state.pendingDemand,
               let tools = state.pendingTools {
                pending = AnalysisRequest(
                    configurationGeneration: geometry.configurationGeneration,
                    geometry: geometry,
                    demand: demand,
                    peakingThreshold: tools.peaking,
                    zebraThreshold: tools.zebra,
                    loupeCenter: tools.loupeCenter,
                    loupeMagnification: tools.loupeMagnification)
                state.request = pending
                state.pendingDemand = nil
                state.pendingTools = nil
            }
            return state
        }
        await push(snapshot)
    }

    private func push(_ state: State) async {
        guard var request = state.request, !request.demand.isEmpty else {
            await metering.setDemand(nil)
            return
        }
        // No geometry yet: keep the intent and do not send a request the analyser
        // cannot place. It is completed by the next geometry change (S07).
        guard request.geometry != nil else {
            await metering.setDemand(nil)
            return
        }
        // Only the generation stamp is refreshed; every tool setting the user
        // chose is preserved exactly.
        if let geometry = state.geometry, geometry != request.geometry {
            request = AnalysisRequest(
                configurationGeneration: geometry.configurationGeneration,
                geometry: geometry,
                demand: request.demand,
                peakingThreshold: request.peakingThreshold,
                zebraThreshold: request.zebraThreshold,
                loupeCenter: request.loupeCenter,
                loupeMagnification: request.loupeMagnification)
        }
        await metering.setDemand(request)
    }

    func consume(outcome: LumaDownsampleOutcome, geometry: PreviewGeometrySnapshot?) async {
        switch outcome {
        case .sampled(let sample, _):
            // The sample already carries the generation captured at acquisition
            // (REVIEW.md C08); it is forwarded unchanged so a stale frame is
            // dropped rather than relabelled.
            await metering.submit(sample: sample)
        case .unsupported(_, let reason):
            await metering.reportAnalysisUnavailable(reason: reason)
        case .invalid(let reason):
            await metering.reportAnalysisUnavailable(reason: reason)
        }
    }
}

/// Storage that honestly reports "no library selected" for every operation.
///
/// This is NOT a storage implementation and never reports success. It exists so
/// the app can be built and inspected before the real `LibraryStore` is wired in,
/// without inventing a folder or silently using the app container.
actor UnavailableLibraryStore: @preconcurrency LibraryStoring {
    static let shared = UnavailableLibraryStore()

    nonisolated var rootState: LibraryRootState { .unselected }
    nonisolated var currentManifest: LibraryManifest? { nil }
    nonisolated var selectedRootDescription: String? { nil }
    nonisolated var grantedRootURL: URL? { nil }

    func selectRoot(
        from grantedURL: URL,
        confirmedLocalDestination: Bool = false
    ) async -> RootSelectionOutcome {
        .unavailable(reason: "No library storage is installed in this build.")
    }

    func reconnectStoredRoot() async -> RootSelectionOutcome {
        .unavailable(reason: "No library storage is installed in this build.")
    }

    func releaseRoot() async {}

    func reconcile(onProgress: (@Sendable (ScanProgress) -> Void)?) async throws -> ReconciledLibrary {
        throw CaptureFailure(
            kind: .folderUnavailable(detail: "No library storage is installed in this build."),
            operation: "reconcile")
    }

    func stageSource(bytes: Data, metadata: SourceCaptureMetadata) async throws -> StagedSourceHandle {
        throw CaptureFailure(
            kind: .folderUnavailable(detail: "No library storage is installed in this build."),
            operation: "stageSource")
    }

    func commit(handle: StagedSourceHandle) async throws -> CommitReceipt {
        throw CaptureFailure(
            kind: .folderUnavailable(detail: "No library storage is installed in this build."),
            operation: "commit")
    }

    func retry(transactionID: TransactionID) async throws -> CommitReceipt {
        throw CaptureFailure(
            kind: .folderUnavailable(detail: "No library storage is installed in this build."),
            operation: "retry")
    }

    func pendingOriginals() async -> [PendingOriginal] { [] }

    func prepareOriginalExport(sourceIDs: [CaptureID], includeSidecars: Bool) async throws -> ExportSession {
        throw CaptureFailure(
            kind: .folderUnavailable(detail: "No library storage is installed in this build."),
            operation: "prepareOriginalExport")
    }

    func preparePendingOriginalExport(
        transactionIDs: [TransactionID],
        includeSidecars: Bool
    ) async throws -> ExportSession {
        throw CaptureFailure(
            kind: .folderUnavailable(detail: "No library storage is installed in this build."),
            operation: "preparePendingOriginalExport")
    }

    func discardExport(sessionID: UUID) async {}

    func clearAbandonedExports() async {}

    func writeSequenceDocument(_ document: SequenceDocument) async throws {
        throw CaptureFailure(
            kind: .folderUnavailable(detail: "No library storage is installed in this build."),
            operation: "writeSequenceDocument")
    }

    func readSequenceDocument(_ sequenceID: SequenceID) async throws -> SequenceDocument {
        throw CaptureFailure(
            kind: .folderUnavailable(detail: "No library storage is installed in this build."),
            operation: "readSequenceDocument")
    }

    func originalURL(for captureID: CaptureID, relativePath: String) -> URL? { nil }

    func browsableSourceCards(limit: Int) async throws -> [LibrarySourceCard] { [] }

    func reconciledSourceCards(after cursor: ScanCursor?, limit: Int) async throws -> ReconciledCardPage {
        .empty
    }

    func allReconciledSourceCards() async throws -> [LibrarySourceCard] { [] }

    func withRootReadAccess<T: Sendable>(_ body: @Sendable (URL) throws -> T) async throws -> T {
        throw CaptureFailure(
            kind: .folderUnavailable(detail: "No library storage is installed in this build."),
            operation: "withRootReadAccess")
    }

    var sessionConditionStream: AsyncStream<CameraLifecycle> {
        AsyncStream { $0.finish() }
    }

    func recordedSessionCondition() async -> CameraLifecycle { .idle }

    func readOriginal<T: Sendable>(
        relativePath: String,
        _ body: @escaping @Sendable (URL) throws -> T
    ) async throws -> T {
        throw CaptureFailure(
            kind: .folderUnavailable(detail: "No library storage is installed in this build."),
            operation: "readOriginal")
    }

    func openScopedRead() async throws -> ScopedReadLease {
        throw CaptureFailure(
            kind: .folderUnavailable(detail: "No library storage is installed in this build."),
            operation: "openScopedRead")
    }

    func closeScopedRead(_ lease: ScopedReadLease) {}
}
