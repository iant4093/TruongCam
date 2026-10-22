import Foundation
import Observation

// REVIEW.md C06: nothing ever called `store.reconcile`, `index.reset`,
// `index.upsert`, `index.ingest` or `store.reconnectStoredRoot`, so the gallery
// read an index nobody populated and a fresh install could never rebuild it, no
// matter how many originals the folder held.
//
// This is the missing orchestration. It owns the sequence:
//
//   launch/reconnect -> reconcile -> replace the index -> publish pages
//   capture/retry     -> ingest the verified receipt -> refresh pending state
//
// The index stays disposable throughout: a failed index write never revokes a
// committed original, and rebuilding is always allowed to start from empty.

@MainActor
@Observable
final class LibrarySessionCoordinator {
    enum Status: Equatable {
        case idle
        case reconnecting
        case reconciling
        case ready(verified: Int, recovered: Int, missing: Int)
        case unavailable(String)
        case readOnly(String)

        /// Human-readable reason for the current state.
        var detailMessage: String {
            switch self {
            case .idle: return "No folder has been opened yet."
            case .reconnecting: return "Checking the retained folder."
            case .reconciling: return "Reading the library folder."
            case .ready(let verified, let recovered, let missing):
                var parts = ["\(verified) verified original(s)"]
                if recovered > 0 { parts.append("\(recovered) recovered photos") }
                if missing > 0 { parts.append("\(missing) missing") }
                return parts.joined(separator: ", ")
            case .unavailable(let reason): return reason
            case .readOnly(let reason): return reason
            }
        }
    }

    private(set) var status: Status = .idle
    private(set) var issues: [String] = []
    /// True when the last rebuild stopped at its bound instead of scanning the
    /// whole folder. Surfaced so the gallery never presents a truncated listing as
    /// complete (REVIEW.md R09).
    private(set) var lastScanWasTruncated = false
    private(set) var lastReconciledAt: Date?

    private let store: any LibraryStoring
    private let index: any LibraryIndexing
    private let wallClock: any WallClock
    private let indexWriter = AsyncGate()
    private var rebuildOperation = UUID()
    private var selectionOperation = UUID()
    private struct RootAuthority: Equatable {
        let state: LibraryRootState
        let url: URL?
    }
    private var rootAuthority: RootAuthority {
        RootAuthority(state: store.rootState, url: store.grantedRootURL)
    }
    #if DEBUG || TC_PORTABLE_VERIFIER
    var rebuildIdentityForTesting: UUID { rebuildOperation }
    #endif

    /// Revoke publication immediately; an already-issued index write still
    /// drains under its serial owner before a newer rebuild resets the index.
    func invalidateRoot() {
        rebuildOperation = UUID(); selectionOperation = UUID()
        rootAwaitingReconfirmation = nil
        status = .idle; issues = []; lastScanWasTruncated = false
        lastReconciledAt = nil
    }

    init(store: any LibraryStoring, index: any LibraryIndexing, wallClock: any WallClock = SystemWallClock()) {
        self.store = store
        self.index = index
        self.wallClock = wallClock
    }

    /// Ordinary-launch reconnect. A fresh install has no bookmark, which is an
    /// ordinary state rather than an error: the caller shows Reconnect.
    @discardableResult
    func reconnectOnLaunch() async -> Bool {
        invalidateRoot()
        let operation = selectionOperation
        status = .reconnecting
        let outcome = await store.reconnectStoredRoot()
        return await handle(outcome, attemptedRoot: nil, operation: operation)
    }

    /// The folder whose locality could not be verified, awaiting explicit
    /// reconfirmation. Nil when nothing is pending.
    private(set) var rootAwaitingReconfirmation: URL?

    /// Reconfirms the folder that could not be verified, and retries it.
    ///
    /// REVIEW.md H05: the confirmation is a deliberate user act about a SPECIFIC folder,
    /// so it is passed for that URL only and never becomes a global "accept unknown
    /// roots" switch. Known cloud and own-container rejections still win.
    @discardableResult
    func reconfirmAwaitingRoot() async -> Bool {
        guard let pending = rootAwaitingReconfirmation else { return false }
        rootAwaitingReconfirmation = nil
        return await selectRoot(pending, confirmedLocalDestination: true)
    }

    /// The user selected or re-selected a folder.
    @discardableResult
    /// Selects a root. `confirmedLocalDestination` is bound to THIS url by the
    /// picker flow; it is never a blanket permission (REVIEW.md R07).
    func selectRoot(_ url: URL, confirmedLocalDestination: Bool = false) async -> Bool {
        invalidateRoot()
        let operation = selectionOperation
        status = .reconnecting
        let outcome = await store.selectRoot(
            from: url, confirmedLocalDestination: confirmedLocalDestination)
        return await handle(outcome, attemptedRoot: url, operation: operation)
    }

    private func handle(_ outcome: RootSelectionOutcome, attemptedRoot: URL?, operation: UUID) async -> Bool {
        guard selectionOperation == operation, !Task.isCancelled else { return false }
        switch outcome {
        case .initialized, .opened:
            let selected = rootAuthority
            await rebuildIndex()
            return selectionOperation == operation && rootAuthority == selected && !Task.isCancelled
        case .readOnlyNewerSchema(let found, let supported):
            let selected = rootAuthority
            AppDiagnostics.record("Newer metadata version \(found); supported version \(supported).", operation: "library.selectRoot")
            status = .readOnly("This library needs a newer version of TruongCam. You can still browse and export photos.")
            await rebuildIndex()
            return selectionOperation == operation && rootAuthority == selected && !Task.isCancelled
        case .conflictingManifest(let reason):
            AppDiagnostics.record(reason, operation: "library.selectRoot.conflictingManifest")
            status = .unavailable("This folder couldn't be opened as a library. Choose another folder.")
            return false
        case .rejectedOwnContainer:
            AppDiagnostics.record("The selected root is inside TruongCam's own container.", operation: "library.selectRoot.ownContainer")
            status = .unavailable(
                "Choose a folder outside TruongCam so your photos stay safe if the app is deleted.")
            return false
        case .rejectedCloudLocation(let reason):
            AppDiagnostics.record(reason, operation: "library.selectRoot.cloudLocation")
            status = .unavailable("Choose a folder in On My iPhone. Cloud folders aren't supported.")
            return false
        case .localityUnconfirmed(let reason):
            // Remember the folder so the user can explicitly reconfirm it (H05).
            rootAwaitingReconfirmation = attemptedRoot
            // REVIEW.md G05: the store RESETS to unselected here, so the previous
            // "opened read-only, browsing and export only" account was false, and
            // rebuilding a root that does not exist was meaningless. The real state is
            // reported instead: no root is selected and the user must confirm the
            // destination explicitly to proceed.
            AppDiagnostics.record(reason, operation: "library.selectRoot.localityUnconfirmed")
            status = .unavailable("Confirm that this folder is in On My iPhone before using it. No folder was selected.")
            return false
        case .unavailable(let reason):
            AppDiagnostics.record(reason, operation: "library.selectRoot.unavailable")
            status = .unavailable("This folder couldn't be opened. Reconnect it and try again.")
            return false
        }
    }

    /// Reconciles the root and replaces the derived index with what the files
    /// actually contain. Safe to call repeatedly.
    func rebuildIndex() async {
        let operation = UUID()
        rebuildOperation = operation
        let root = rootAuthority
        status = .reconciling
        await indexWriter.acquire()
        await rebuildOwned(operation: operation, root: root)
        await indexWriter.release()
        if Task.isCancelled, rebuildOperation == operation, rootAuthority == root {
            status = .idle
        }
    }

    private func ownsRebuild(_ operation: UUID, root: RootAuthority) -> Bool {
        !Task.isCancelled && rebuildOperation == operation && rootAuthority == root
    }

    private func rebuildOwned(operation: UUID, root: RootAuthority) async {
        guard ownsRebuild(operation, root: root) else { return }
        do {
            let reconciled = try await store.reconcile(onProgress: nil)
            guard ownsRebuild(operation, root: root) else { return }
            if let id = root.state.libraryID, id != reconciled.libraryID {
                throw CaptureFailure(kind: .metadataInvalid(detail: "The reconciled library changed before indexing."), operation: "rebuildIndex.identity")
            }
            if let expected = root.state.generation, expected != reconciled.generation {
                throw CaptureFailure(kind: .metadataInvalid(detail: "The reconciled grant changed before indexing."), operation: "rebuildIndex.generation")
            }

            let generation = reconciled.generation
            try await index.reset(libraryID: reconciled.libraryID, generation: generation)
            guard ownsRebuild(operation, root: root) else { return }

            // Enumerate EVERY reconciled record (extant and missing) and page it
            // into the index in bounded batches. REVIEW.md S10: using only the
            // extant DNGs dropped missing originals so they vanished from the
            // gallery, and the loop must ADVANCE its cursor or it re-upserts the
            // same records forever.
            var cursor: ScanCursor?
            var totalUpserted = 0
            var scanWasTruncated = false
            while true {
                let page = try await store.reconciledSourceCards(
                    after: cursor, limit: MetadataBounds.maxScanBatchEntries)
                guard ownsRebuild(operation, root: root) else { return }
                guard page.cards.allSatisfy({ $0.libraryID == reconciled.libraryID }) else {
                    throw CaptureFailure(kind: .metadataInvalid(detail: "A library page belongs to another folder."), operation: "rebuildIndex.page")
                }
                if !page.cards.isEmpty {
                    try await index.upsert(scanned: page.cards)
                    guard ownsRebuild(operation, root: root) else { return }
                    totalUpserted += page.cards.count
                }
                guard let next = page.nextCursor else { break }
                cursor = next
                if totalUpserted >= MetadataBounds.maxSequenceSources * 8 {
                    // A bounded stop, reported rather than presented as complete.
                    scanWasTruncated = true
                    break
                }
            }
            // Metadata issues are carried by each recovered classification.
            // They do not mean that the extant original bytes are unavailable.
            // The index reset also clears sequence summaries. Publish the actual
            // reconciled documents so complete/partial/restoration state survives
            // reconnect instead of falling back to an invented interrupted row.
            try await index.updateSequences(reconciled.sequences)
            guard ownsRebuild(operation, root: root) else { return }
            for issue in reconciled.issues {
                AppDiagnostics.record(issue, operation: "library.reconcile")
            }
            issues = reconciled.issues.isEmpty ? [] : ["Some photos couldn't be fully checked. Try refreshing the library."]
            lastReconciledAt = wallClock.now()
            lastScanWasTruncated = scanWasTruncated
            if scanWasTruncated {
                AppDiagnostics.record("The library listing was truncated at \(totalUpserted) records.", operation: "library.reconcile.scanLimit")
                issues.append("This library is large, so some photos aren't shown yet.")
            }
            // The card listing and the reconciled counts come from ONE
            // classification pass, so they cannot disagree; the scan above is the
            // single source of truth for both (REVIEW.md S10).
            status = .ready(verified: reconciled.verifiedOriginalCount,
                            recovered: reconciled.recoveredRAWCount,
                            missing: reconciled.missingOriginalCount)
        } catch let failure as CaptureFailure {
            guard ownsRebuild(operation, root: root) else { return }
            status = .unavailable(UserFacingFailure.message(for: failure))
        } catch {
            guard ownsRebuild(operation, root: root) else { return }
            status = .unavailable(UserFacingFailure.message(for: error))
        }
    }

    /// Records a verified commit in the derived index.
    ///
    /// An index failure is reported but never treated as a commit failure: the
    /// original is already durable in the folder (CONTRACTS.md).
    func ingestCommitted(_ receipts: [CommitReceipt]) async {
        guard !receipts.isEmpty else { return }
        let root = rootAuthority
        let selection = selectionOperation
        await indexWriter.acquire()
        await ingestOwned(receipts, root: root, selection: selection)
        await indexWriter.release()
    }

    private func ingestOwned(_ receipts: [CommitReceipt], root: RootAuthority, selection: UUID) async {
        guard !Task.isCancelled, rootAuthority == root,
              selectionOperation == selection,
              case .writable(let libraryID, let generation) = root.state else { return }
        let current = receipts.filter { $0.libraryID == libraryID && $0.rootGeneration == generation }
        guard !current.isEmpty else { return }
        do {
            try await index.ingest(current)
        } catch {
            guard rootAuthority == root, selectionOperation == selection, !Task.isCancelled else { return }
            AppDiagnostics.record(error, operation: "library.ingestCommitted")
            issues.append("Your photo was saved, but the gallery couldn't update. Refresh the library to see it.")
        }
    }

    /// Read one final document after receipt ingestion, rather than rescan the
    /// whole library after every timer/bracket. Indexed extant members determine
    /// current completion; the document supplies its final run/restoration state.
    func refreshSequenceSummary(_ sequenceID: SequenceID) async {
        let root = rootAuthority, selection = selectionOperation
        await indexWriter.acquire()
        await refreshSequenceOwned(sequenceID, root: root, selection: selection)
        await indexWriter.release()
    }

    private func refreshSequenceOwned(_ sequenceID: SequenceID, root: RootAuthority, selection: UUID) async {
        func current() -> Bool {
            !Task.isCancelled && rootAuthority == root && selectionOperation == selection
        }
        guard current(), root.state.isWritable else { return }
        do {
            let document = try await store.readSequenceDocument(sequenceID)
            guard current() else { return }
            guard document.sequenceID == sequenceID.rawValue,
                  document.libraryID == root.state.libraryID?.rawValue,
                  SequenceDocumentSemanticValidator().validate(document).isEmpty else {
                throw CaptureFailure(kind: .metadataInvalid(detail: "The final sequence document does not belong to this library."), operation: "sequence.summary")
            }
            let cards = try await index.sources(inSequence: sequenceID)
            guard current() else { return }
            let sources = cards.reduce(into: [CaptureID: LibrarySourceCard]()) { result, card in
                if card.libraryID == root.state.libraryID, card.availability == .local, card.isTruongCamCapture {
                    result[card.captureID] = card
                }
            }
            let committed = Set(document.completedSources.compactMap { entry -> Int? in
                guard let card = sources[CaptureID(entry.captureID)], card.sequenceID == sequenceID,
                      card.sequenceIndex == entry.index else { return nil }
                return entry.index
            })
            let failed = Set(document.failedIndices)
            let summary = SequenceSummary(sequenceID: sequenceID, kind: document.kind,
                plannedCount: document.plannedCount, committedCount: committed.count,
                missingIndices: (0..<document.plannedCount).filter { !committed.contains($0) && !failed.contains($0) },
                failedIndices: document.failedIndices, skippedDeadlineCount: document.skippedDeadlineCount,
                status: document.status, startedAtUTC: document.startedAtUTC)
            try await index.updateSequences([summary])
        } catch {
            guard current() else { return }
            AppDiagnostics.record(error, operation: "library.refreshSequenceSummary")
            issues.append("The photo set couldn't be updated. Refresh the library to try again.")
        }
    }

    /// Re-scans after Files changed, or after the user asks to refresh.
    func refreshAfterFilesChange() async {
        await rebuildIndex()
    }
}
