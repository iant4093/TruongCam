import Foundation
import Synchronization

#if canImport(XCTest)
@testable import TruongCam
#endif

/// Holds the actual model's metadata query without opening originals or a user
/// folder. The response identity is independent of the root/request identity.
private actor ThirdUISequenceIndex: LibraryIndexing {
    private(set) var requested: [SequenceID] = []
    private var waiters: [Int: CheckedContinuation<[LibrarySourceCard], Never>] = [:]
    private var responses: [Int: [LibrarySourceCard]] = [:]
    func sources(inSequence sequenceID: SequenceID) async throws -> [LibrarySourceCard] {
        let position = requested.count
        requested.append(sequenceID)
        if let response = responses.removeValue(forKey: position) { return response }
        return await withCheckedContinuation { waiters[position] = $0 }
    }
    func release(_ position: Int, cards: [LibrarySourceCard]) {
        if let waiter = waiters.removeValue(forKey: position) { waiter.resume(returning: cards) }
        else { responses[position] = cards }
    }
    func reset(libraryID: LibraryID, generation: RootGeneration) async throws {}
    func ingest(_ receipts: [CommitReceipt]) async throws {}
    func upsert(scanned: [LibrarySourceCard]) async throws {}
    func updateSequences(_ summaries: [SequenceSummary]) async throws {}
    func markUnavailable(captureID: CaptureID, reason: String) async throws {}
    func firstPage(size: Int) async throws -> LibraryPage { LibraryPage(cards: [], nextCursor: nil, libraryGeneration: .zero) }
    func page(after cursor: LibraryCursor, size: Int) async throws -> LibraryPage { try await firstPage(size: size) }
    func detail(captureID: CaptureID) async throws -> LibrarySourceCard? { nil }
    func dayGroupCounts() async throws -> [DayGroupCount] { [] }
    func totalCommittedOriginalCount() async throws -> Int { 0 }
}

/// Only root authority is implemented; all original/file operations refuse.
private final class ThirdUIRootStore: LibraryStoring, @unchecked Sendable {
    private let authority: Mutex<(LibraryRootState, URL?)>
    init(id: LibraryID) {
        authority = Mutex((.readOnly(reason: "Synthetic metadata fixture", libraryID: id),
            URL(fileURLWithPath: "/third-ui/root-a")))
    }
    var rootState: LibraryRootState { authority.withLock { $0.0 } }
    var grantedRootURL: URL? { authority.withLock { $0.1 } }
    var currentManifest: LibraryManifest? { nil }
    var selectedRootDescription: String? { grantedRootURL?.lastPathComponent }
    func set(state: LibraryRootState, url: URL?) { authority.withLock { $0 = (state, url) } }
    private func unsupported() -> CocoaError { CocoaError(.featureUnsupported) }
    func selectRoot(from grantedURL: URL, confirmedLocalDestination: Bool) async -> RootSelectionOutcome { .conflictingManifest(reason: "Metadata-only fixture") }
    func reconnectStoredRoot() async -> RootSelectionOutcome { .conflictingManifest(reason: "Metadata-only fixture") }
    func releaseRoot() async { set(state: .unselected, url: nil) }
    func reconcile(onProgress: (@Sendable (ScanProgress) -> Void)?) async throws -> ReconciledLibrary { throw unsupported() }
    func stageSource(bytes: Data, metadata: SourceCaptureMetadata) async throws -> StagedSourceHandle { throw unsupported() }
    func commit(handle: StagedSourceHandle) async throws -> CommitReceipt { throw unsupported() }
    func retry(transactionID: TransactionID) async throws -> CommitReceipt { throw unsupported() }
    func pendingOriginals() async -> [PendingOriginal] { [] }
    func prepareOriginalExport(sourceIDs: [CaptureID], includeSidecars: Bool) async throws -> ExportSession { throw unsupported() }
    func preparePendingOriginalExport(transactionIDs: [TransactionID], includeSidecars: Bool) async throws -> ExportSession { throw unsupported() }
    func discardExport(sessionID: UUID) async {}
    func clearAbandonedExports() async {}
    func reconciledSourceCards(after cursor: ScanCursor?, limit: Int) async throws -> ReconciledCardPage { throw unsupported() }
    func allReconciledSourceCards() async throws -> [LibrarySourceCard] { throw unsupported() }
    func browsableSourceCards(limit: Int) async throws -> [LibrarySourceCard] { throw unsupported() }
    func writeSequenceDocument(_ document: SequenceDocument) async throws { throw unsupported() }
    func readSequenceDocument(_ sequenceID: SequenceID) async throws -> SequenceDocument { throw unsupported() }
    func originalURL(for captureID: CaptureID, relativePath: String) -> URL? { nil }
    func withRootReadAccess<T: Sendable>(_ body: @Sendable (URL) throws -> T) async throws -> T { throw unsupported() }
    func readOriginal<T: Sendable>(relativePath: String, _ body: @escaping @Sendable (URL) throws -> T) async throws -> T { throw unsupported() }
    func openScopedRead() async throws -> ScopedReadLease { throw unsupported() }
    func closeScopedRead(_ lease: ScopedReadLease) {}
}

enum ThirdUIReviewSuite {
    static let suite = TCSuite(id: "THIRD-UI-REVIEW", title: "Sequence read authority at every UI consumer", cases: [
        TCCase(id: "UIR3-S", title: "Sequence drilldown rejects foreign and wrong-sequence members, retaining current reads") { r in
            await selectionIdentity(r)
        },
        TCCase(id: "UIR3-R", title: "Held sequence drilldown cannot publish across equal-state URL replacement or release") { r in
            await selectionRoot(r)
        },
        TCCase(id: "UIR3-E", title: "Sequence export query rejects foreign and wrong-sequence members before returning IDs") { r in
            await exportIdentity(r)
        },
        TCCase(id: "UIR3-C", title: "Held sequence export query rejects changed roots and cancellation; unavailable roots do not query") { r in
            await exportRoot(r)
        }
    ])

    private static func card(libraryID: LibraryID, sequenceID: SequenceID?) -> LibrarySourceCard {
        LibrarySourceCard(captureID: CaptureID(), libraryID: libraryID, relativeOriginalPath: "originals/fixture.dng",
            capturedAtUTC: Date(timeIntervalSince1970: 1_700_000_000), capturedAtProvenance: .requestTimestamp,
            availability: .local, classification: .verifiedOriginal, rawDimensions: nil, byteCount: nil,
            sequenceID: sequenceID, sequenceIndex: sequenceID == nil ? nil : 0,
            sequenceKind: sequenceID == nil ? nil : .exposureBracket, isTruongCamCapture: true,
            modificationFingerprint: nil)
    }

    private static func entered(_ index: ThirdUISequenceIndex, count: Int) async -> Bool {
        for _ in 0..<200 {
            if await index.requested.count >= count { return true }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return false
    }

    @MainActor private static func selectionIdentity(_ r: TCRecorder) async {
        let id = LibraryID(), sequence = SequenceID(), store = ThirdUIRootStore(id: id)
        let index = ThirdUISequenceIndex(), model = LibraryViewModel(index: index, store: store)
        let current = card(libraryID: id, sequenceID: sequence)
        let rejected = [card(libraryID: LibraryID(), sequenceID: sequence),
                        card(libraryID: id, sequenceID: SequenceID()),
                        card(libraryID: id, sequenceID: nil)]
        for (position, bad) in rejected.enumerated() {
            // A mixed result must be rejected as a whole, not silently narrowed.
            await index.release(position, cards: [current, bad])
            await model.selectSequence(sequence)
            r.check("foreign/wrong/nil sequence membership cannot publish", model.sequenceCards.isEmpty)
            r.equal("selected request is still current", model.selectedSequenceID, sequence)
        }
        await index.release(3, cards: [current]); await model.selectSequence(sequence)
        r.equal("valid current sequence remains browsable", model.sequenceCards.map(\.captureID), [current.captureID])
        r.equal("rejected results do not poison a later query", await index.requested, Array(repeating: sequence, count: 4))
    }

    @MainActor private static func selectionRoot(_ r: TCRecorder) async {
        for release in [false, true] {
            let id = LibraryID(), sequence = SequenceID(), store = ThirdUIRootStore(id: id)
            let originalState = store.rootState
            let index = ThirdUISequenceIndex(), model = LibraryViewModel(index: index, store: store)
            let member = card(libraryID: id, sequenceID: sequence)
            let old = Task { await model.selectSequence(sequence) }
            r.check("held sequence query entered", await entered(index, count: 1))
            if release { await store.releaseRoot() }
            else { store.set(state: originalState, url: URL(fileURLWithPath: "/third-ui/root-b")) }
            await index.release(0, cards: [member]); await old.value
            r.check("obsolete sequence result remains unpublished", model.sequenceCards.isEmpty)
            if !release {
                r.equal("equal read-only state alone cannot identify folder", store.rootState, originalState)
                await index.release(1, cards: [member]); await model.selectSequence(sequence)
                r.equal("fresh exact-root read still publishes", model.sequenceCards.map(\.captureID), [member.captureID])
            }
        }
    }

    @MainActor private static func exportIdentity(_ r: TCRecorder) async {
        let id = LibraryID(), sequence = SequenceID(), store = ThirdUIRootStore(id: id)
        let index = ThirdUISequenceIndex(), model = LibraryViewModel(index: index, store: store)
        let current = card(libraryID: id, sequenceID: sequence)
        for (position, bad) in [card(libraryID: LibraryID(), sequenceID: sequence),
                                card(libraryID: id, sequenceID: SequenceID()),
                                card(libraryID: id, sequenceID: nil)].enumerated() {
            await index.release(position, cards: [current, bad])
            r.check("export receives no mixed-authority IDs", await model.sourcesInSequence(sequence).isEmpty)
        }
        await index.release(3, cards: [current])
        r.equal("valid export query returns exact member", await model.sourcesInSequence(sequence).map(\.captureID), [current.captureID])
        r.check("export query does not navigate drilldown", model.selectedSequenceID == nil && model.sequenceCards.isEmpty)
    }

    @MainActor private static func exportRoot(_ r: TCRecorder) async {
        for transition in 0..<3 {
            let id = LibraryID(), sequence = SequenceID(), store = ThirdUIRootStore(id: id)
            let originalState = store.rootState
            let index = ThirdUISequenceIndex(), model = LibraryViewModel(index: index, store: store)
            let member = card(libraryID: id, sequenceID: sequence)
            let old = Task { await model.sourcesInSequence(sequence) }
            r.check("held export query entered", await entered(index, count: 1))
            if transition == 0 { store.set(state: originalState, url: URL(fileURLWithPath: "/third-ui/root-b")) }
            else if transition == 1 { await store.releaseRoot() }
            else { old.cancel() }
            await index.release(0, cards: [member])
            r.check("obsolete/cancelled export receives no IDs", await old.value.isEmpty)
            if transition == 1 {
                r.check("released-root query refuses before index read", await model.sourcesInSequence(sequence).isEmpty)
                r.equal("released root does not query cached index", await index.requested.count, 1)
                store.set(state: originalState, url: URL(fileURLWithPath: "/third-ui/root-a"))
            }
            await index.release(1, cards: [member])
            r.equal("fresh current-root query remains available", await model.sourcesInSequence(sequence).map(\.captureID), [member.captureID])
        }
    }
}
