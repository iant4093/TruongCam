#if canImport(UIKit) && canImport(XCTest) && !TC_TESTKIT_STANDALONE
import Foundation
import ImageIO
import Synchronization
import XCTest
@testable import TruongCam

private actor SecondUI43ReadGate {
    private(set) var entered = false
    private var released = false
    private var continuation: CheckedContinuation<Void, Never>?
    func wait() async {
        entered = true
        if !released { await withCheckedContinuation { continuation = $0 } }
    }
    func release() { released = true; continuation?.resume(); continuation = nil }
}

/// Metadata-only authority/read seam. It never opens a file or user library.
private final class SecondUI43MetadataStore: LibraryStoring, @unchecked Sendable {
    private let root: Mutex<(LibraryRootState, URL?)>
    let gate = SecondUI43ReadGate()
    let shouldFail: Bool
    init(id: LibraryID, url: URL, shouldFail: Bool = false) {
        root = Mutex((.readOnly(reason: "Synthetic metadata test", libraryID: id), url))
        self.shouldFail = shouldFail
    }
    func replaceRoot(url: URL?) { root.withLock { $0.1 = url } }
    func set(state: LibraryRootState, url: URL?) { root.withLock { $0 = (state, url) } }
    var rootState: LibraryRootState { root.withLock { $0.0 } }
    var grantedRootURL: URL? { root.withLock { $0.1 } }
    var currentManifest: LibraryManifest? { nil }
    var selectedRootDescription: String? { grantedRootURL?.lastPathComponent }
    private func unsupported() -> CocoaError { CocoaError(.featureUnsupported) }
    func readOriginal<T: Sendable>(relativePath: String, _ body: @escaping @Sendable (URL) throws -> T) async throws -> T {
        let url = grantedRootURL?.appendingPathComponent(relativePath) ?? URL(fileURLWithPath: "/no-root")
        await gate.wait()
        if shouldFail { throw CocoaError(.fileReadNoSuchFile) }
        return try body(url)
    }
    func selectRoot(from grantedURL: URL, confirmedLocalDestination: Bool) async -> RootSelectionOutcome { .conflictingManifest(reason: "Metadata-only test") }
    func reconnectStoredRoot() async -> RootSelectionOutcome { .conflictingManifest(reason: "Metadata-only test") }
    func releaseRoot() async { root.withLock { $0 = (.unselected, nil) } }
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
    func openScopedRead() async throws -> ScopedReadLease { throw unsupported() }
    func closeScopedRead(_ lease: ScopedReadLease) {}
}

private actor SecondUI43PageIndex: LibraryIndexing {
    private var pages: [LibraryPage] = []
    private(set) var totalReads = 0
    private(set) var cursors: [LibraryCursor] = []
    func script(_ pages: [LibraryPage]) { self.pages = pages }
    private func next() throws -> LibraryPage {
        guard !pages.isEmpty else { throw CocoaError(.featureUnsupported) }
        return pages.removeFirst()
    }
    func reset(libraryID: LibraryID, generation: RootGeneration) async throws {}
    func ingest(_ receipts: [CommitReceipt]) async throws {}
    func upsert(scanned: [LibrarySourceCard]) async throws {}
    func updateSequences(_ summaries: [SequenceSummary]) async throws {}
    func markUnavailable(captureID: CaptureID, reason: String) async throws {}
    func firstPage(size: Int) async throws -> LibraryPage { try next() }
    func page(after cursor: LibraryCursor, size: Int) async throws -> LibraryPage { cursors.append(cursor); return try next() }
    func detail(captureID: CaptureID) async throws -> LibrarySourceCard? { nil }
    func sources(inSequence sequenceID: SequenceID) async throws -> [LibrarySourceCard] { [] }
    func dayGroupCounts() async throws -> [DayGroupCount] { [] }
    func totalCommittedOriginalCount() async throws -> Int { totalReads += 1; return 12 }
}

final class SecondUIAudit43NativeTests: XCTestCase {
    @MainActor private static func waitForRead(_ gate: SecondUI43ReadGate) async throws {
        for _ in 0..<200 {
            if await gate.entered { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("Metadata reader did not enter the held await")
        throw CocoaError(.featureUnsupported)
    }

    @MainActor func testMetadataCannotPublishFromEqualReadOnlyStateAtDifferentURL() async throws {
        let id = LibraryID(), urlA = URL(fileURLWithPath: "/fixture-root-a"), urlB = URL(fileURLWithPath: "/fixture-root-b")
        let store = SecondUI43MetadataStore(id: id, url: urlA)
        let card = try XCTUnwrap(StorageFixture.cards(count: 1, libraryID: id, startingAt: StorageFixture.fixedDate).first)
        let model = PhotoDetailModel(reader: { url in
            PhotoMetadataDetails.parse([kCGImagePropertyExifDictionary as String:
                ["ISOSpeedRatings": [url.path.hasPrefix(urlB.path) ? 800 : 100]]])
        })
        let originalState = store.rootState
        let old = Task { await model.load(card: card, store: store) }
        try await Self.waitForRead(store.gate)
        store.replaceRoot(url: urlB)
        XCTAssertEqual(store.rootState, originalState, "URL identity must distinguish otherwise equal read-only roots")
        await store.gate.release(); await old.value
        XCTAssertNil(model.details, "A completed old-folder read must not publish metadata in the new folder")
        XCTAssertNil(model.error)
        await model.load(card: card, store: store)
        XCTAssertEqual(model.details?.iso, "ISO 800", "A new current-root request still publishes legitimate details")
    }

    @MainActor func testFailedMetadataReadCannotPublishAcrossReplacementReleaseOrCancellation() async throws {
        for transition in 0..<3 {
            let id = LibraryID()
            let current = SecondUI43MetadataStore(id: id, url: URL(fileURLWithPath: "/fixture-error-a"), shouldFail: true)
            let card = try XCTUnwrap(StorageFixture.cards(count: 1, libraryID: id, startingAt: StorageFixture.fixedDate).first)
            let model = PhotoDetailModel()
            let old = Task { await model.load(card: card, store: current) }
            try await Self.waitForRead(current.gate)
            if transition == 0 { current.replaceRoot(url: URL(fileURLWithPath: "/fixture-error-b")) }
            else if transition == 1 { await current.releaseRoot() }
            else { old.cancel() }
            await current.gate.release(); await old.value
            XCTAssertNil(model.details)
            XCTAssertNil(model.error, "An obsolete or cancelled error must not attach to the current photo/root")
            if transition == 0 {
                await model.load(card: card, store: current)
                XCTAssertNotNil(model.error, "A genuine current-root read failure must remain visible")
            }
        }
    }

    @MainActor func testLibraryRejectsOldIndexGenerationAndForeignLibraryCardsBeforeCountQuery() async throws {
        let id = LibraryID(), generation = RootGeneration(7)
        let root = SecondUI43MetadataStore(id: id, url: URL(fileURLWithPath: "/fixture-page-root"))
        root.set(state: .writable(libraryID: id, generation: generation), url: root.grantedRootURL)
        let index = SecondUI43PageIndex(), model = LibraryViewModel(index: index, store: root)
        let current = try XCTUnwrap(StorageFixture.cards(count: 1, libraryID: id, startingAt: StorageFixture.fixedDate).first)
        let foreign = try XCTUnwrap(StorageFixture.cards(count: 1, libraryID: LibraryID(), startingAt: StorageFixture.fixedDate).first)
        func card(_ source: LibrarySourceCard) -> LibraryCard {
            LibraryCard(id: source.id, kind: .single(source), capturedAtUTC: source.capturedAtUTC, representedOriginalCount: 1)
        }
        let summary = SequenceSummary(sequenceID: SequenceID(), kind: .interval, plannedCount: 1,
            committedCount: 1, missingIndices: [], failedIndices: [], skippedDeadlineCount: 0,
            status: .complete, startedAtUTC: StorageFixture.fixedDate)
        let foreignCover = LibraryCard(id: summary.sequenceID.description, kind: .sequenceCover(summary, cover: foreign),
            capturedAtUTC: StorageFixture.fixedDate, representedOriginalCount: 1)
        let rejected = [
            LibraryPage(cards: [card(current)], nextCursor: nil, libraryGeneration: RootGeneration(6)),
            LibraryPage(cards: [card(foreign)], nextCursor: nil, libraryGeneration: generation),
            LibraryPage(cards: [foreignCover], nextCursor: nil, libraryGeneration: generation)
        ]
        for page in rejected {
            await index.script([page]); await model.loadFirstPage()
            XCTAssertTrue(model.dayGroups.isEmpty)
            XCTAssertEqual(model.individualOriginalCount, 0)
            XCTAssertFalse(model.isLoading)
            XCTAssertNil(model.lastReconcileIssue, "Stale derived-index data must not become a new product error")
        }
        let rejectedCountReads = await index.totalReads
        XCTAssertEqual(rejectedCountReads, 0, "Reject foreign pages before issuing their count query")
        let cursor = LibraryCursor(capturedAtUTC: current.capturedAtUTC, tieBreaker: current.id, libraryGeneration: generation)
        await index.script([LibraryPage(cards: [card(current)], nextCursor: cursor, libraryGeneration: generation)])
        await model.loadFirstPage()
        XCTAssertEqual(model.orderedSources.map(\.captureID), [current.captureID])
        XCTAssertEqual(model.individualOriginalCount, 12)
        XCTAssertTrue(model.hasMorePages)
        for page in rejected {
            await index.script([page]); await model.loadNextPage()
            XCTAssertEqual(model.orderedSources.map(\.captureID), [current.captureID])
            XCTAssertEqual(model.loadedPageCount, 1)
            XCTAssertTrue(model.hasMorePages, "A foreign next page must not consume the current cursor")
            XCTAssertNil(model.pageLoadFailure)
        }
        let another = try XCTUnwrap(StorageFixture.cards(count: 1, libraryID: id, startingAt: StorageFixture.fixedDate.addingTimeInterval(-1)).first)
        await index.script([LibraryPage(cards: [card(another)], nextCursor: nil, libraryGeneration: generation)])
        await model.loadNextPage()
        XCTAssertEqual(Set(model.orderedSources.map(\.captureID)), Set([current.captureID, another.captureID]))
        XCTAssertEqual(model.loadedPageCount, 2)
        XCTAssertFalse(model.hasMorePages)
        let used = await index.cursors
        XCTAssertEqual(used, Array(repeating: cursor, count: 4), "Rejected pages preserve the original valid pagination cursor")
    }

}
#endif
