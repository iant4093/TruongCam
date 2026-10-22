import Foundation
import Observation
import SwiftUI

// CONTRACTS.md "Semantic interfaces": AppCoordinator owns onboarding,
// permissions, navigation and display snapshots. All UI state is MainActor. It
// never performs native configuration or disk work itself; it forwards commands
// to the owning service.


/// Composition aids and their preferences. These are remembered across launches;
/// manual capture settings are not (a fresh process starts Auto).

/// Root observable application state shared by every screen.
@MainActor
@Observable
final class AppEnvironment {
    enum Tab: Hashable {
        case camera
        case library
    }

    /// Per-process preparation, not a persistent flag pretending native caches
    /// survive termination. Only production requests the launch screen.
    var isPreparingExperience = false
    var launchResourcesReady = false
    var canFinishLaunchPreparation: Bool {
        if case .failed = graphState { return true }
        guard let camera else { return false }
        if camera.surface != .ready && camera.surface != .preparing { return true }
        return launchResourcesReady && camera.isPreviewConnectionStable
            && camera.hasCurrentDisplayGeometry && camera.hasRenderedCurrentPreview
    }
    func finishLaunchPreparationIfReady() {
        if canFinishLaunchPreparation { isPreparingExperience = false }
    }

    var tab: Tab = .camera
    var cameraSurface: CameraSurfaceState = .preparing
    var composition = CompositionPreferences()
    var failure: UserFacingFailure?
    var libraryStatusLine: String = LibraryRootState.unselected.displayLabel
    var libraryLocationLabel: String = "No folder selected"
    var pendingOriginalCount = 0
    /// True when a folder must be selected or reconnected before saving.
    var needsFolderSelection = true

    let buildInfo: BuildInfo
    let folderPicker: FolderPicking

    // Services are injected at composition time so the UI never constructs them.
    private(set) var camera: CameraViewModel?
    private(set) var library: LibraryViewModel?

    /// Library root state, mirrored for display. The UI never writes files.
    private(set) var libraryRootState: LibraryRootState = .unselected
    private(set) var pendingOriginals: [PendingOriginal] = []

    private(set) var libraryStore: (any LibraryStoring)?
    private(set) var libraryIndex: (any LibraryIndexing)?

    init(buildInfo: BuildInfo = .current(),
         folderPicker: FolderPicking = SystemFolderPicker()) {
        self.buildInfo = buildInfo
        self.folderPicker = folderPicker
    }

    func attach(camera: CameraViewModel) {
        self.camera = camera
        refreshLibraryRootState()
    }

    /// Attaches the storage stack. Until a real `LibraryStore` is installed the
    /// app reports an unselected root rather than pretending a folder exists.
    func attach(store: any LibraryStoring, index: any LibraryIndexing) {
        self.libraryStore = store
        self.libraryIndex = index
        self.library = LibraryViewModel(index: index, store: store)
        refreshLibraryRootState()
        Task { await refreshPendingOriginals() }
    }

    /// Installs the disposable preview source used by the gallery. Resolution
    /// happens inside the store's balanced scope lease (REVIEW.md C10).
    func attachThumbnails(store: any LibraryStoring, thumbnails: any ThumbnailProviding) {
        libraryThumbnailSource = .scoped(store: store, thumbnails: thumbnails)
        libraryThumbnailRevision += 1
        library?.thumbnailSource = libraryThumbnailSource
    }

    /// Re-arm cells first presented before their actual preview source existed.
    private(set) var libraryThumbnailRevision = 0

    /// Disposable preview source for the grid and the detail viewer.
    private(set) var libraryThumbnailSource: GalleryThumbnailSource =
        .unavailable(reason: "Thumbnails are unavailable in this build.")

    /// Attaches the launch/reconnect/rebuild orchestration and wires the
    /// environment's folder actions to it (REVIEW.md C06).
    /// Observable service-graph state, mirrored from the coordinator so the camera
    /// view can start the camera when the graph is genuinely ready (S03).
    var graphState: AppCoordinator.GraphState = .idle

    func attach(librarySession: LibrarySessionCoordinator) {
        self.librarySession = librarySession
    }

    /// J07: the explicit Include-sidecars choice. DNG-only is the default; the user
    /// opts in per process, and the choice is carried into real preparation.
    static var includeExportSidecars = false

    /// Sets the explicit sidecar choice used by every export route.
    func setIncludeExportSidecars(_ include: Bool) {
        Self.includeExportSidecars = include
    }

    private(set) var librarySession: LibrarySessionCoordinator?

    /// True when a folder is waiting for the user to confirm it is local storage.
    var isAwaitingDestinationReconfirmation: Bool {
        librarySession?.rootAwaitingReconfirmation != nil
    }

    /// Reconfirms the pending folder. Bound to THAT folder only, never a blanket
    /// permission, and a known cloud or own-container rejection still wins
    /// (REVIEW.md H05).
    func reconfirmPendingDestination() {
        Task {
            guard let session = librarySession else { return }
            let confirmed = await session.reconfirmAwaitingRoot()
            guard confirmed else {
                // A failed or refused reconfirmation stays honest: the destination was
                // not approved and the previous state is unchanged.
                return
            }
            // Publish the transition for the ACTUAL consumers: the root state the UI
            // reads, and the rebuilt gallery page.
            // The REAL publication path: root state, status/location labels, the
            // needs-selection gate and the camera's own root state (REVIEW.md M05).
            refreshLibraryRootState()
            // The gallery is rebuilt exactly as an ordinary selection does.
            await library?.loadFirstPage()
        }
    }

    /// The published library root state.
    ///
    /// M05: an ALIAS of the single authoritative `libraryRootState`, so a caller cannot
    /// read a duplicate that drifts from what the UI and capture gate consume.
    var rootState: LibraryRootState { libraryRootState }

    /// Republishes the selected root/readiness after a root transition.
    ///
    /// M05: the reconfirmation previously wrote a DUPLICATE property while the real
    /// consumers stayed stale, so the UI still reported "select a folder". It now
    /// publishes through the existing path those consumers actually read.
    func refreshPublishedRoot() async {
        refreshLibraryRootState()
    }

    /// Records verified commits in the derived index after a capture or retry.
    func ingestCommitted(_ receipts: [CommitReceipt]) async {
        await librarySession?.ingestCommitted(receipts)
        await library?.loadFirstPage()
    }

    /// Receipt ingestion establishes the sources, while the final stored
    /// sequence document establishes its complete/cancelled/restoration state.
    func refreshAfterSequence(sequenceID: SequenceID?) async {
        if let sequenceID { await librarySession?.refreshSequenceSummary(sequenceID) }
        await refreshPendingOriginals()
        await library?.loadFirstPage()
    }

    func refreshLibraryRootState() {
        guard let store = libraryStore else {
            libraryRootState = .unselected
            camera?.updateRootState(.unselected)
            return
        }
        let selectedState = store.rootState
        // Keep diagnostic root reasons in the service state and logs; the folder
        // status line is everyday UI copy, not an error dump.
        switch selectedState {
        case .readOnly(let reason, _):
            if libraryRootState != selectedState { AppDiagnostics.record(reason, operation: "library.root.readOnly") }
            libraryStatusLine = "Browsing and export only"
        case .unavailable(let reason, _):
            if libraryRootState != selectedState { AppDiagnostics.record(reason, operation: "library.root.unavailable") }
            libraryStatusLine = "Reconnect your library folder"
        default:
            libraryStatusLine = selectedState.displayLabel
        }
        libraryRootState = selectedState
        libraryLocationLabel = store.selectedRootDescription ?? "No folder selected"
        needsFolderSelection = !selectedState.isWritable
        camera?.updateRootState(selectedState)
    }

    func refreshPendingOriginals() async {
        guard let store = libraryStore else {
            pendingOriginals = []
            camera?.updatePendingOriginalCount(0)
            return
        }
        let pending = await store.pendingOriginals()
        pendingOriginals = pending
        camera?.updatePendingOriginalCount(pending.count)
    }

    // MARK: Commands forwarded to services

    func selectLibraryFolder() async {
        guard let store = libraryStore else { return }
        guard let url = await folderPicker.pickLocalLibraryFolder() else { return }

        // REVIEW.md F05: `confirmLocalDestination` returning false used to be
        // forwarded as "unconfirmed", and the code then selected anyway. For a
        // verified-local folder that meant Cancel still initialized the library and
        // could write its manifest — Cancel was not cancellation. The decision is
        // now explicit and a cancellation returns immediately with NO candidate
        // filesystem mutation.
        let decision = await folderPicker.localDestinationDecision(for: url)
        switch decision {
        case .cancelled:
            // Preserve the previous selection untouched. No scope change, no
            // bookmark write, no manifest, no rebuild.
            selectionNotice = "Folder selection was cancelled; the previous library folder is unchanged."
            return
        case .unconfirmed:
            // The user did not affirm local retention. Never silently accepted, and
            // never presented as a working library.
            failure = UserFacingFailure(
                title: "Local folder not confirmed",
                detail: "TruongCam stores permanent originals only in a local On My iPhone folder you confirm. Nothing was changed.",
                actions: [.reconnect, .dismiss])
            return
        case .confirmedLocalDestination:
            break
        }

        // Selecting a folder must also rebuild the gallery, not merely reopen it.
        if let librarySession {
            let ok = await librarySession.selectRoot(
                url, confirmedLocalDestination: true)
            refreshLibraryRootState()
            await library?.loadFirstPage()
            if !ok { failure = UserFacingFailure(
                title: "Folder not usable",
                detail: librarySession.status.detailMessage,
                actions: [.reconnect, .dismiss]) }
            return
        }
        let outcome = await store.selectRoot(
            from: url, confirmedLocalDestination: true)
        apply(outcome)
    }

    /// A transient message about the folder flow, presented on the invoking surface.
    private(set) var selectionNotice: String?

    func clearSelectionNotice() { selectionNotice = nil }

    func releaseLibraryFolder() async {
        guard let store = libraryStore else { return }
        librarySession?.invalidateRoot()
        await store.releaseRoot()
        library?.invalidateRoot()
        openSequenceID = nil
        refreshLibraryRootState()
    }

    private(set) var metadataOrganizationMessage: String?
    private(set) var isOrganizingMetadata = false
    func organizeLibraryMetadata() async {
        guard !isOrganizingMetadata, let libraryStore else { return }
        isOrganizingMetadata = true
        defer { isOrganizingMetadata = false }
        failure = nil
        do {
            let count = try await libraryStore.organizeMetadata()
            metadataOrganizationMessage = count == 0 ? "App records are already organized." : "Organized \(count) app records. Your photos are unchanged."
            await librarySession?.refreshAfterFilesChange()
            await library?.loadFirstPage()
        } catch let error as CaptureFailure { failure = UserFacingFailure.from(error) }
        catch { failure = UserFacingFailure(title: "Couldn't organize the library", detail: UserFacingFailure.message(for: error), actions: [.dismiss]) }
    }

    /// Retries one pending original and reconciles every consumer of the result.
    ///
    /// REVIEW.md R08: this used `try?`, discarding the receipt AND the error. A
    /// successful retry therefore never reached the index or the pending list, and a
    /// failed one was invisible. Both outcomes are now reported and the verified
    /// receipt is ingested.
    func retryPendingOriginal(_ transactionID: TransactionID) async {
        guard let store = libraryStore else {
            exportPresenter?.reportFailure(UserFacingFailure(
                title: "Library unavailable",
                detail: "Open your library folder, then try saving this photo again.",
                actions: [.reconnect, .dismiss]))
            return
        }
        do {
            let receipt = try await store.retry(transactionID: transactionID)
            // A verified receipt is the only thing that may leave pending state.
            await librarySession?.ingestCommitted([receipt])
            await library?.loadFirstPage()
            await refreshPendingOriginals()
            exportPresenter?.reportNotice("Photo saved to your library folder.")
        } catch let failure as CaptureFailure {
            exportPresenter?.reportFailure(UserFacingFailure.from(failure))
            await refreshPendingOriginals()
        } catch {
            exportPresenter?.reportFailure(UserFacingFailure(
                title: "Retry failed",
                detail: UserFacingFailure.message(for: error),
                actions: [.retrySave, .exportPending, .dismiss]))
            await refreshPendingOriginals()
        }
    }

    /// The retained presenter that actually runs exports. Set by the coordinator
    /// once the storage stack exists (REVIEW.md C07).
    var exportPresenter: ExportPresenter?

    /// Exports ONE committed original through the presenter.
    struct CommittedExportRoot: Hashable, Sendable {
        let state: LibraryRootState
        let url: URL
    }

    private var committedExportRoot: CommittedExportRoot? {
        guard let store = libraryStore, let url = store.grantedRootURL,
              store.rootState.libraryID != nil else { return nil }
        switch store.rootState {
        case .writable, .readOnly: return CommittedExportRoot(state: store.rootState, url: url)
        default: return nil
        }
    }

    private func ownsExportRoot(_ root: CommittedExportRoot) -> Bool {
        !Task.isCancelled && committedExportRoot == root
    }

    func exportCommittedOriginal(
        _ captureID: CaptureID,
        surface: ExportPresenter.ExportSurface = .library
    ) {
        guard let exportPresenter, let root = committedExportRoot else { return }
        // O04: the invocation is frozen BEFORE the Task exists, so nothing the user does
        // afterwards can change what this gesture exports.
        let invocation = ExportPresenter.Invocation(
            surface: surface,
            sources: [captureID],
            includeSidecars: Self.includeExportSidecars,
            description: "1 original")
        // U04: a new command supersedes any QUEUED held confirmation AND any session an
        // earlier command already presented, disposing their copies.
        supersedeHeldConfirmation(by: exportPresenter)
        supersedePresentedSession(by: exportPresenter)
        // T04: the single command takes an ordinal from the SHARED epoch, so it supersedes an
        // older sequence consent rather than coexisting with it.
        let epoch = exportPresenter.beginCommand()
        var stamped = invocation
        stamped.epoch = epoch
        Task {
            guard exportPresenter.isCurrentCommand(epoch), ownsExportRoot(root) else { return }
            let outcome = await exportPresenter.prepare(stamped)
            guard exportPresenter.isCurrentCommand(epoch), ownsExportRoot(root) else {
                if case .ready(let session) = outcome { await exportPresenter.discardPrepared(session) }
                return
            }
            switch outcome {
            case .ready(let session):
                exportPresenter.adoptFrozenSurface(invocation.surface, for: session)
                exportPresenter.presentPrepared(session, description: invocation.description)
            case .nothingAvailable(let missing): await exportPresenter.reportMissingAll(missing: missing)
            case .failed(let failure): exportPresenter.reportFailure(failure)
            }
        }
    }

    /// A frozen gallery selection. Missing originals are confirmed against the
    /// actual prepared copies, using the same consent/session owner as sequences.
    func exportSelectedOriginals(_ cards: [LibrarySourceCard]) {
        guard let presenter = exportPresenter, let root = committedExportRoot else { return }
        var seen: Set<CaptureID> = []
        let ids = cards.map(\.captureID).filter { seen.insert($0).inserted }
        guard !ids.isEmpty, cards.allSatisfy({ $0.libraryID == root.state.libraryID }) else { return }
        let includeSidecars = Self.includeExportSidecars
        supersedeHeldConfirmation(by: presenter)
        supersedePresentedSession(by: presenter)
        let epoch = presenter.beginCommand()
        presenter.routePresentation(to: .library)
        Task {
            guard presenter.isCurrentCommand(epoch), ownsExportRoot(root) else { return }
            let outcome = await presenter.prepare(sources: ids, includeSidecars: includeSidecars)
            guard presenter.isCurrentCommand(epoch), ownsExportRoot(root) else {
                if case .ready(let session) = outcome { await presenter.discardPrepared(session) }
                return
            }
            switch outcome {
            case .ready(let session):
                presenter.adoptFrozenSurface(.library, for: session)
                if session.missingItems.isEmpty {
                    presenter.presentPrepared(session, description: "\(ids.count) selected originals")
                } else {
                    replacePendingPartialExport(PartialExportConfirmation(
                        surface: .library,
                        description: "\(ids.count) selected originals", availableCaptureIDs: ids,
                        absentDescriptions: session.missingItems, preparedSession: session, root: root))
                }
            case .nothingAvailable(let missing):
                guard presenter.isCurrentCommand(epoch) else { return }
                await presenter.reportMissingAll(missing: missing)
            case .failed(let failure):
                guard presenter.isCurrentCommand(epoch) else { return }
                presenter.reportFailure(failure)
            }
        }
    }

    /// Exports every committed source of a sequence.
    /// A pending partial-export confirmation.
    ///
    /// REVIEW.md R08: the previous implementation silently prefiltered unavailable
    /// sources and relied on a static footer, which is not confirmation. The user is
    /// now told exactly which sources will be ABSENT and must accept before any
    /// share sheet appears.
    struct PartialExportConfirmation: Identifiable, Hashable, Sendable {
        let id = UUID()
        let surface: ExportPresenter.ExportSurface
        let description: String
        let availableCaptureIDs: [CaptureID]
        let absentDescriptions: [String]
        /// The ALREADY PREPARED copies this confirmation is about. Present so the
        /// confirmed share cannot silently present different bytes (REVIEW.md H06).
        var preparedSession: ExportSession? = nil
        /// Consent is for these prepared copies under this exact selected root.
        var root: CommittedExportRoot? = nil
    }

    private(set) var pendingPartialExport: PartialExportConfirmation?

    /// Exports every committed source of a sequence, confirming absences first.
    func exportSequenceOriginals(_ sequenceID: SequenceID) {
        guard let exportPresenter, let root = committedExportRoot, let library else { return }
        supersedeHeldConfirmation(by: exportPresenter)
        supersedePresentedSession(by: exportPresenter)
        // U04: the epoch comes from the PRESENTER, synchronously, and travels with the
        // invocation so it is re-checked at the publication boundary.
        let invocationOrdinal = exportPresenter.beginCommand()
        // Q04: the complete invocation is frozen in the SYNCHRONOUS user command.
        let invocation = ExportPresenter.Invocation(
            surface: .sequence,
            sources: [],
            includeSidecars: Self.includeExportSidecars,
            description: "sequence originals",
            sequenceID: sequenceID)
        exportPresenter.routePresentation(to: invocation.surface)
        Task {
            guard exportPresenter.isCurrentCommand(invocationOrdinal), ownsExportRoot(root), self.library === library else { return }
            let cards = await library.sourcesInSequence(sequenceID)
            guard exportPresenter.isCurrentCommand(invocationOrdinal), ownsExportRoot(root), self.library === library else { return }
            let available = cards.filter(\.canExportOriginal).map(\.captureID)
            let cardAbsences = cards.filter { !$0.canExportOriginal }.map(\.captureID.description)

            // G06: the sequence SUMMARY knows which planned ordinals never delivered a
            // source. Those are absences too, and the previous precheck could not see
            // them because they have no card at all.
            let summary = library.summary(for: sequenceID)
            var plannedAbsences: [String] = []
            if let summary {
                plannedAbsences = summary.missingIndices.map { "planned source \($0 + 1) (never delivered)" }
                    + summary.failedIndices.map { "planned source \($0 + 1) (failed)" }
            }

            let description = "sequence \(sequenceID) — \(available.count) original(s)"
            let knownAbsences = cardAbsences + plannedAbsences

            guard !available.isEmpty else {
                // W04: validated against THIS command's identity before publishing.
                guard exportPresenter.isCurrentCommand(invocationOrdinal) else { return }
                await exportPresenter.reportMissingAll(missing: knownAbsences)
                return
            }
            // H06: PREPARE FIRST, always. The precheck is only a hint; the authoritative
            // missing set comes from actually preparing the originals. Nothing is shared
            // until the user has consented to whatever the preparation really found.
            let outcome = await exportPresenter.prepare(
                sources: available, includeSidecars: invocation.includeSidecars)
            guard exportPresenter.isCurrentCommand(invocationOrdinal), ownsExportRoot(root), self.library === library else {
                if case .ready(let session) = outcome { await exportPresenter.discardPrepared(session) }
                return
            }
            switch outcome {
            case .ready(let session):
                // S04: a superseded command disposes its own obsolete copies instead of
                // publishing over, or replacing, a newer confirmation.
                guard exportPresenter.isCurrentCommand(invocationOrdinal) else {
                    await exportPresenter.discardPrepared(session)
                    return
                }
                // Q04: bind the FROZEN invocation surface to this session immediately.
                exportPresenter.adoptFrozenSurface(invocation.surface, for: session)
                let discovered = session.missingItems
                let allAbsences = knownAbsences + discovered
                if allAbsences.isEmpty {
                    exportPresenter.presentPrepared(session, description: description)
                    return
                }
                // Hold the PREPARED session so the confirmed share presents exactly
                // these verified copies, and cancel/replacement can clean it.
                replacePendingPartialExport(PartialExportConfirmation(
                    surface: invocation.surface,
                    description: description,
                    availableCaptureIDs: available.filter { id in
                        !discovered.contains { $0.contains(id.description) }
                    },
                    absentDescriptions: allAbsences,
                    preparedSession: session, root: root))
                return
            case .nothingAvailable(let missing):
                guard exportPresenter.isCurrentCommand(invocationOrdinal) else { return }
                await exportPresenter.reportMissingAll(missing: knownAbsences + missing)
                return
            case .failed(let failure):
                guard exportPresenter.isCurrentCommand(invocationOrdinal) else { return }
                exportPresenter.reportFailure(failure)
                return
            }
        }
    }


    /// Replaces the pending confirmation, DISPOSING any session it still held.
    ///
    /// P04: an overwritten confirmation leaked its prepared copies, because nothing else
    /// owned them afterwards. The superseded session is discarded first.
    private func replacePendingPartialExport(_ confirmation: PartialExportConfirmation) {
        if let superseded = pendingPartialExport?.preparedSession, let exportPresenter {
            Task { await exportPresenter.discardPrepared(superseded) }
        }
        pendingPartialExport = confirmation
    }

    /// Runs the export the user confirmed, including the listed absences.
    ///
    /// REVIEW.md G06: preparation happens BEFORE sharing, so an absence discovered at
    /// export time is folded into the confirmation the user sees rather than silently
    /// shrinking the shared subset.
    func confirmPendingPartialExport(expectedID: UUID? = nil) {
        guard let pending = pendingPartialExport, let exportPresenter else { return }
        guard expectedID == nil || expectedID == pending.id else { return }
        let epoch = exportPresenter.beginCommand()
        pendingPartialExport = nil
        Task {
            // U04: a newer command issued before this task runs supersedes the
            // confirmation, which then DISPOSES the copies it was holding.
            guard exportPresenter.isCurrentCommand(epoch), let root = pending.root, ownsExportRoot(root) else {
                if let held = pending.preparedSession {
                    await exportPresenter.discardPrepared(held)
                }
                return
            }
            // H06: if this confirmation owns a prepared session, present THOSE verified
            // copies rather than repreparing unchecked data. Preparation is only redone
            // when there is no owned session (the library-surface flow).
            if let held = pending.preparedSession {
                exportPresenter.presentPrepared(
                    held,
                    description: pending.description
                        + ", \(pending.absentDescriptions.count) confirmed absent")
                return
            }
            let outcome = await exportPresenter.prepare(
                sources: pending.availableCaptureIDs,
                includeSidecars: Self.includeExportSidecars)
            guard exportPresenter.isCurrentCommand(epoch), ownsExportRoot(root) else {
                if case .ready(let session) = outcome { await exportPresenter.discardPrepared(session) }
                return
            }
            switch outcome {
            case .ready(let session):
                let newlyMissing = session.missingItems
                if newlyMissing.isEmpty {
                    exportPresenter.presentPrepared(
                        session,
                        description: pending.description
                            + ", \(pending.absentDescriptions.count) confirmed absent")
                    return
                }
                // New absences appeared after the precheck. Re-present the
                // confirmation with them included; nothing is shared yet.
                let stillAvailable = pending.availableCaptureIDs.filter { id in
                    !newlyMissing.contains { $0.contains(id.description) }
                }
                guard !stillAvailable.isEmpty else {
                    await exportPresenter.reportMissingAll(
                        missing: pending.absentDescriptions + newlyMissing)
                    return
                }
                pendingPartialExport = PartialExportConfirmation(
                    surface: pending.surface,
                    description: pending.description,
                    availableCaptureIDs: stillAvailable,
                    absentDescriptions: pending.absentDescriptions + newlyMissing,
                    preparedSession: session, root: root)
            case .nothingAvailable(let missing):
                await exportPresenter.reportMissingAll(
                    missing: pending.absentDescriptions + missing)
            case .failed(let failure):
                guard exportPresenter.isCurrentCommand(epoch) else { return }
                exportPresenter.reportFailure(failure)
            }
        }
    }

    /// Drops the pending confirmation without exporting anything.
    ///
    /// REVIEW.md J07: the prepared session this confirmation owned is discarded
    /// explicitly. Only ITS directory is removed, so a concurrent export's copies
    /// survive.
    /// Disposes a held confirmation superseded by a NEWER command.
    ///
    /// U04: the epoch alone stops the superseded preparation from publishing, but a consent
    /// that was ALREADY held would otherwise stay live and keep its copies.
    private func supersedeHeldConfirmation(by presenter: ExportPresenter) {
        guard let held = pendingPartialExport?.preparedSession else {
            pendingPartialExport = nil
            return
        }
        pendingPartialExport = nil
        Task { await presenter.discardPrepared(held) }
    }

    /// Disposes the session a superseded command had already PRESENTED.
    private func supersedePresentedSession(by presenter: ExportPresenter) {
        guard let presented = presenter.presented else { return }
        Task { await presenter.finished(sessionID: presented.session.sessionID) }
    }

    func cancelPendingPartialExport(expectedID: UUID? = nil) {
        guard expectedID == nil || expectedID == pendingPartialExport?.id else { return }
        // U04: cancellation participates in the SAME command epoch, so work still in flight
        // (even before consent exists) is superseded and cannot publish later.
        _ = exportPresenter?.beginCommand()
        guard let pending = pendingPartialExport, let exportPresenter else {
            pendingPartialExport = nil
            return
        }
        pendingPartialExport = nil
        guard let held = pending.preparedSession else { return }
        Task { await exportPresenter.discardPrepared(held) }
    }

    /// Exports a PENDING original straight from internal recovery storage. This is
    /// the recovery action that must work when the external root is unavailable.
    func exportPendingOriginal(
        _ transactionID: TransactionID,
        surface: ExportPresenter.ExportSurface = .library
    ) {
        guard let exportPresenter else { return }
        supersedeHeldConfirmation(by: exportPresenter)
        supersedePresentedSession(by: exportPresenter)
        // P04: frozen BEFORE the Task exists, so nothing the user does afterwards can
        // change what this pending gesture exports or which surface owns it.
        let invocation = ExportPresenter.Invocation(
            surface: surface,
            sources: [],
            includeSidecars: Self.includeExportSidecars,
            description: "pending original \(transactionID)",
            transactionIDs: [transactionID])
        // T04: the pending command participates in the SAME epoch.
        let epoch = exportPresenter.beginCommand()
        var stamped = invocation
        stamped.epoch = epoch
        Task { await exportPresenter.exportPending(stamped) }
    }

    /// Loads the next index page. Wired to the gallery's own scroll trigger so the
    /// whole library is reachable (REVIEW.md S10).
    func libraryLoadNextPage() {
        Task { await library?.loadNextPage() }
    }

    /// Explicit/foreground refresh. REVIEW.md S10: `refreshAfterFilesChange` had no
    /// production caller, so files added in the Files app never appeared.
    /// True when the last rebuild hit its scan bound. Read by the gallery so an
    /// incomplete listing is labelled incomplete (REVIEW.md R09).
    var libraryScanWasTruncated: Bool {
        librarySession?.lastScanWasTruncated ?? false
    }

    private(set) var photoMutationInProgress = false
    private(set) var photoMutationProgress: PhotoMutationProgress?
    /// Retained completion identity: recreated/coalesced views reload once even
    /// when the transient in-progress state never rendered on that surface.
    private(set) var photoMutationRevision: UInt64 = 0
    @ObservationIgnored private var photoMutationBeganAt: TimeInterval = 0
    var visiblePhotoMutationProgress: PhotoMutationProgress? {
        guard let progress = photoMutationProgress,
              progress.matches(state: libraryRootState, root: libraryStore?.grantedRootURL) else { return nil }
        return progress
    }
    func stopPhotoMutation(_ id: UUID) {
        guard photoMutationProgress?.id == id, photoMutationProgress?.isRefreshing == false else { return }
        photoMutationProgress?.stopRequested = true
    }
    private func beginPhotoMutation(kind: PhotoMutationProgress.Kind, total: Int, generation: RootGeneration) -> Bool {
        guard !photoMutationInProgress, let store = libraryStore,
              case .writable(let libraryID, let current) = store.rootState, current == generation else { return false }
        photoMutationInProgress = true
        photoMutationProgress = PhotoMutationProgress(kind: kind, libraryID: libraryID,
            generation: generation, root: store.grantedRootURL, total: total)
        photoMutationBeganAt = ProcessInfo.processInfo.systemUptime
        return true
    }
    private func finishPhotoMutation() {
        #if DEBUG
        if let progress = photoMutationProgress {
            print("TruongCam timing photo-mutation=\(Int((ProcessInfo.processInfo.systemUptime-photoMutationBeganAt)*1000))ms kind=\(progress.kind.rawValue) completed=\(progress.completed) total=\(progress.total)")
        }
        #endif
        photoMutationProgress = nil
        photoMutationInProgress = false
        photoMutationRevision &+= 1
    }
    private var mayContinuePhotoMutation: Bool {
        guard !Task.isCancelled, let progress = photoMutationProgress, !progress.stopRequested,
              let store = libraryStore else { return false }
        return progress.matches(state: store.rootState, root: store.grantedRootURL)
    }

    struct BatchTrashResult: Sendable {
        let completed: Set<CaptureID>
        let failure: String?
    }

    /// Progress counts only verified outcomes. Stop/cancellation takes effect
    /// between files; the current owned move and recovery journal must finish.
    func trashOriginals(_ cards: [LibrarySourceCard], generation: RootGeneration,
                        onVerified: ((CaptureID) -> Void)? = nil) async -> BatchTrashResult {
        guard let store = libraryStore, beginPhotoMutation(kind: .moveToTrash,
            total: Set(cards.map(\.captureID)).count, generation: generation) else {
            return BatchTrashResult(completed: [], failure: "The library isn't ready. Wait for any photo task to finish, or reconnect its folder.")
        }
        defer { finishPhotoMutation() }
        await Task.yield()
        var completed: Set<CaptureID> = []
        var failure: String?
        for card in cards where !completed.contains(card.captureID) {
            guard mayContinuePhotoMutation else { failure = "The operation stopped. Remaining originals were not moved."; break }
            do {
                _ = try await store.trashOriginal(card: card, generation: generation)
                completed.insert(card.captureID)
                photoMutationProgress?.completedIDs.insert(card.captureID.rawValue)
                onVerified?(card.captureID)
                await Task.yield()
            } catch { failure = UserFacingFailure.message(for: error); break }
        }
        await refreshAfterPhotoMutation()
        return BatchTrashResult(completed: completed, failure: failure)
    }

    func trashOriginal(_ card: LibrarySourceCard, generation: RootGeneration) async throws {
        guard let store = libraryStore, beginPhotoMutation(kind: .moveToTrash, total: 1, generation: generation) else {
            throw CaptureFailure(kind: .operationStalled(detail: "Another photo operation is in progress, or the folder changed."), operation: "trashOriginal")
        }
        defer { finishPhotoMutation() }
        await Task.yield()
        do {
            guard mayContinuePhotoMutation else { throw CancellationError() }
            _ = try await store.trashOriginal(card: card, generation: generation)
            photoMutationProgress?.completedIDs.insert(card.captureID.rawValue)
            await refreshAfterPhotoMutation()
        } catch {
            // An interrupted pair may already be in recoverable Trash.
            await refreshAfterPhotoMutation()
            throw error
        }
    }

    func restoreOriginal(_ record: PhotoTrashRecord, generation: RootGeneration) async throws {
        guard let store = libraryStore, beginPhotoMutation(kind: .recover, total: 1, generation: generation) else {
            throw CaptureFailure(kind: .operationStalled(detail: "Another photo operation is in progress, or the folder changed."), operation: "restoreOriginal")
        }
        defer { finishPhotoMutation() }
        await Task.yield()
        do {
            guard mayContinuePhotoMutation else { throw CancellationError() }
            try await store.restoreOriginal(trashID: record.id, libraryID: record.libraryID, generation: generation)
            photoMutationProgress?.completedIDs.insert(record.id)
            await refreshAfterPhotoMutation()
        } catch { await refreshAfterPhotoMutation(); throw error }
    }

    struct TrashActionResult: Sendable {
        let completed: Set<UUID>
        let failure: String?
    }
    func performTrashAction(_ records: [PhotoTrashRecord], permanently: Bool, generation: RootGeneration,
                            onVerified: ((UUID) -> Void)? = nil) async -> TrashActionResult {
        guard let store = libraryStore, beginPhotoMutation(kind: permanently ? .permanentlyDelete : .recover,
            total: Set(records.map(\.id)).count, generation: generation) else {
            return TrashActionResult(completed: [], failure: "The library isn't ready. Wait for any photo task to finish, or reconnect its folder.")
        }
        defer { finishPhotoMutation() }
        await Task.yield()
        var completed: Set<UUID> = [], failure: String?
        for record in records where !completed.contains(record.id) {
            guard mayContinuePhotoMutation else { failure = "The operation stopped. Remaining photos were kept."; break }
            do {
                if permanently { try await store.permanentlyDeleteOriginal(record: record, generation: generation) }
                else { try await store.restoreOriginal(trashID: record.id, libraryID: record.libraryID, generation: generation) }
                completed.insert(record.id)
                photoMutationProgress?.completedIDs.insert(record.id)
                onVerified?(record.id)
                await Task.yield()
            } catch { failure = UserFacingFailure.message(for: error); break }
        }
        await refreshAfterPhotoMutation()
        return TrashActionResult(completed: completed, failure: failure)
    }

    private func refreshAfterPhotoMutation() async {
        photoMutationProgress?.isRefreshing = true
        await Task.yield()
        #if DEBUG
        let began = ProcessInfo.processInfo.systemUptime
        defer { print("TruongCam timing photo-mutation-refresh=\(Int((ProcessInfo.processInfo.systemUptime-began)*1000))ms") }
        #endif
        await librarySession?.refreshAfterFilesChange()
        await library?.loadFirstPage()
        if let sequenceID = openSequenceID { await library?.selectSequence(sequenceID) }
    }

    func libraryRefreshFromFiles() {
        guard !photoMutationInProgress else { return }
        Task {
            await librarySession?.refreshAfterFilesChange()
            await library?.loadFirstPage()
        }
    }

    func librarySelectSequence(_ sequenceID: SequenceID) {
        Task { await library?.selectSequence(sequenceID) }
    }

    /// The sequence currently open in the detail drilldown.
    var openSequenceID: SequenceID?

    /// Opens a sequence's source list.
    func openSequence(_ sequenceID: SequenceID) {
        openSequenceID = sequenceID
        librarySelectSequence(sequenceID)
    }

    // `presentSource`/`presentedSource` were removed: they had no reader, so the
    // sequence toolbar appeared to do nothing (REVIEW.md F06). The sequence viewer
    // now drives its own sheet index directly.

    private func apply(_ outcome: RootSelectionOutcome) {
        switch outcome {
        case .initialized, .opened:
            failure = nil
        case .readOnlyNewerSchema(let found, let supported):
            AppDiagnostics.record("Newer metadata version \(found); supported version \(supported).", operation: "library.selectRoot")
            failure = UserFacingFailure(
                title: "Update TruongCam to use this library",
                detail: "You can still browse and export photos. Update TruongCam before saving new photos here.",
                actions: [.reconnect, .dismiss])
        case .conflictingManifest(let reason):
            AppDiagnostics.record(reason, operation: "library.selectRoot.conflictingManifest")
            failure = UserFacingFailure(
                title: "Couldn't open this folder",
                detail: "This folder couldn't be opened as a library. Choose another folder.",
                actions: [.reconnect, .dismiss])
        case .rejectedOwnContainer:
            AppDiagnostics.record("The selected root is inside TruongCam's own container.", operation: "library.selectRoot.ownContainer")
            failure = UserFacingFailure(
                title: "Folder is inside TruongCam",
                detail: "Choose a folder outside TruongCam so your photos stay safe if the app is deleted.",
                actions: [.reconnect, .dismiss])
        case .rejectedCloudLocation(let reason):
            AppDiagnostics.record(reason, operation: "library.selectRoot.cloudLocation")
            failure = UserFacingFailure(
                title: "Choose a local folder",
                detail: "Choose a folder in On My iPhone. Cloud folders aren't supported.",
                actions: [.reconnect, .dismiss])
        case .localityUnconfirmed(let reason):
            AppDiagnostics.record(reason, operation: "library.selectRoot.localityUnconfirmed")
            failure = UserFacingFailure(
                title: "Confirm this folder",
                detail: "Confirm that this folder is in On My iPhone before using it. No folder was selected.",
                actions: [.reconnect, .dismiss])
        case .unavailable(let reason):
            AppDiagnostics.record(reason, operation: "library.selectRoot.unavailable")
            failure = UserFacingFailure(
                title: "Folder unavailable",
                detail: "This folder couldn't be opened. Reconnect it and try again.",
                actions: [.reconnect, .dismiss])
        }
        refreshLibraryRootState()
        Task {
            await refreshPendingOriginals()
            await library?.loadFirstPage()
        }
    }

    static func makeProduction() -> AppEnvironment {
        let environment = AppEnvironment()
        environment.isPreparingExperience = true
        return environment
    }


}

/// Non-identifying build provenance used by diagnostics and the report. It
/// contains no personal or device identifiers.
struct BuildInfo: Hashable, Sendable {
    let marketingVersion: String
    let buildNumber: String
    let bundleIdentifier: String
    let swiftVersion: String

    static func current() -> BuildInfo {
        let bundle = Bundle.main
        return BuildInfo(
            marketingVersion: bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown",
            buildNumber: bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown",
            bundleIdentifier: bundle.bundleIdentifier ?? "unknown",
            swiftVersion: SwiftVersionDescription.current)
    }
}

enum SwiftVersionDescription {
    static var current: String {
        #if swift(>=6.0)
        return "Swift 6 or newer"
        #else
        return "Swift 5"
        #endif
    }
}

/// Opening the system folder picker. A protocol so UI tests and previews can use
/// a stub instead of presenting a real document browser.
@MainActor
protocol FolderPicking: AnyObject {
    /// Presents the picker and returns the selected directory URL, or nil when
    /// the user cancelled. Does not retain access beyond the grant helper.
    func pickLocalLibraryFolder() async -> URL?

    /// Asks the user to make an explicit decision about THIS folder.
    ///
    /// REVIEW.md F05: a `Bool` conflated "the user cancelled" with "the user did not
    /// affirm", and both were then treated as permission to select. The three-way
    /// decision below keeps cancellation distinct, so cancelling cannot mutate the
    /// library.
    func localDestinationDecision(for url: URL) async -> LocalDestinationDecision
}

/// The user's explicit answer about one candidate destination.
enum LocalDestinationDecision: Hashable, Sendable {
    /// The user dismissed the choice. Nothing may be selected or written.
    case cancelled
    /// The user did not affirm this folder as local independent storage.
    case unconfirmed
    /// The user affirmed this exact folder.
    case confirmedLocalDestination
}

extension FolderPicking {
    /// A picker with no confirmation UI reports `.unconfirmed`, never `.cancelled`,
    /// because it cannot know the user withdrew.
    func localDestinationDecision(for url: URL) async -> LocalDestinationDecision { .unconfirmed }
}
