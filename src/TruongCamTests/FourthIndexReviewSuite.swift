import Foundation
#if canImport(XCTest)
@testable import TruongCam
#endif

/// Holds an actual SQLite page after materialization, independently of the
/// database actor, so replacement rows/counts can genuinely arrive in between.
private actor FourthReviewPageIndex: LibraryIndexing {
    let base: SQLiteIndex
    private let override: LibraryPage?
    private let holdFirst: Bool
    private var didHold = false
    private var released = false
    private var waiter: CheckedContinuation<Void, Never>?
    private(set) var entered = false
    private(set) var countReads = 0
    init(base: SQLiteIndex, override: LibraryPage? = nil, holdFirst: Bool = false) {
        self.base = base; self.override = override; self.holdFirst = holdFirst
    }
    func release() { released = true; waiter?.resume(); waiter = nil }
    func reset(libraryID: LibraryID, generation: RootGeneration) async throws { try await base.reset(libraryID: libraryID, generation: generation) }
    func ingest(_ receipts: [CommitReceipt]) async throws { try await base.ingest(receipts) }
    func upsert(scanned: [LibrarySourceCard]) async throws { try await base.upsert(scanned: scanned) }
    func updateSequences(_ summaries: [SequenceSummary]) async throws { try await base.updateSequences(summaries) }
    func markUnavailable(captureID: CaptureID, reason: String) async throws { try await base.markUnavailable(captureID: captureID, reason: reason) }
    func firstPage(size: Int) async throws -> LibraryPage {
        let page: LibraryPage
        if let override { page = override } else { page = try await base.firstPage(size: size) }
        entered = true
        if holdFirst && !didHold {
            didHold = true
            if !released { await withCheckedContinuation { waiter = $0 } }
        }
        return page
    }
    func page(after cursor: LibraryCursor, size: Int) async throws -> LibraryPage { try await base.page(after: cursor, size: size) }
    func detail(captureID: CaptureID) async throws -> LibrarySourceCard? { try await base.detail(captureID: captureID) }
    func sources(inSequence sequenceID: SequenceID) async throws -> [LibrarySourceCard] { try await base.sources(inSequence: sequenceID) }
    func dayGroupCounts() async throws -> [DayGroupCount] { try await base.dayGroupCounts() }
    func totalCommittedOriginalCount() async throws -> Int { countReads += 1; return try await base.totalCommittedOriginalCount() }
}

enum FourthIndexReviewSuite {
    private static func wait(_ condition: @escaping @Sendable () async -> Bool) async -> Bool {
        for _ in 0..<1000 {
            if await condition() { return true }
            try? await Task.sleep(for: .milliseconds(2))
        }
        return await condition()
    }
    static let suite = TCSuite(id: "FourthIndexReview", title: "Empty-page identity and same-snapshot gallery count", cases: [
        TCCase(id: "I46E", title: "A former empty database cannot publish as a newly selected read-only library") { r in
            guard let h = await StorageHarness.make(name: "i46-empty-identity") else { r.check("fixture", false); return }
            let directory = StorageFixture.temporaryDirectory("i46-empty-db")
            let db = SQLiteIndex(databaseURL: directory.appendingPathComponent("index.sqlite"))
            do {
                try await db.reset(libraryID: h.libraryID, generation: h.generation)
                let stale = try await db.firstPage(size: 20)
                r.equal("empty real page still identifies its database", stale.indexedLibraryID, h.libraryID)
                let b = h.root.deletingLastPathComponent().appendingPathComponent("readonly-b")
                let manifest = Data("{\"schemaVersion\":\(truongCamSupportedSchemaVersion + 1)}".utf8)
                h.memory.setBytes(manifest, at: b.appendingPathComponent(LibraryLayout.libraryManifestName))
                guard case .readOnlyNewerSchema = await h.store.selectRoot(from: b, confirmedLocalDestination: true),
                      let id = h.store.rootState.libraryID else { throw CocoaError(.fileReadCorruptFile) }
                let model = await LibraryViewModel(index: db, store: h.store)
                await model.loadFirstPage()
                r.equal("former empty page not accepted", await model.loadedPageCount, 0)
                r.equal("no foreign count published", await model.individualOriginalCount, 0)
                r.equal("no false product failure", await model.lastReconcileIssue, nil)
                let lease = try await h.store.openScopedRead()
                let generation = lease.generation; h.store.closeScopedRead(lease)
                try await db.reset(libraryID: id, generation: generation)
                await model.loadFirstPage()
                r.equal("current empty read-only page is accepted", await model.loadedPageCount, 1)
                r.equal("current actual count remains zero", await model.individualOriginalCount, 0)
            } catch { r.check("empty read-only page integration", false, String(describing: error)) }
            await db.closeDatabase(); StorageFixture.removeDirectory(directory)
        },
        TCCase(id: "I46C", title: "Coverless metadata cannot hide its foreign database identity, and current metadata still renders") { r in
            guard let h = await StorageHarness.make(name: "i46-cover-identity") else { r.check("fixture", false); return }
            let directory = StorageFixture.temporaryDirectory("i46-cover-db")
            let db = SQLiteIndex(databaseURL: directory.appendingPathComponent("index.sqlite"))
            do {
                try await db.reset(libraryID: h.libraryID, generation: h.generation)
                let summary = SequenceSummary(sequenceID: SequenceID(), kind: .interval, plannedCount: 2,
                    committedCount: 0, missingIndices: [0, 1], failedIndices: [], skippedDeadlineCount: 0,
                    status: .interrupted, startedAtUTC: StorageFixture.fixedDate)
                let card = LibraryCard(id: summary.sequenceID.description, kind: .sequenceCover(summary, cover: nil),
                    capturedAtUTC: summary.startedAtUTC, representedOriginalCount: 0)
                for id in [LibraryID(), h.libraryID] {
                    let page = LibraryPage(cards: [card], nextCursor: nil, libraryGeneration: h.generation,
                        indexedLibraryID: id, totalCommittedOriginalCount: 0)
                    let index = FourthReviewPageIndex(base: db, override: page)
                    let model = await LibraryViewModel(index: index, store: h.store)
                    await model.loadFirstPage()
                    r.equal("only current coverless metadata is published", await model.loadedPageCount, id == h.libraryID ? 1 : 0)
                    r.equal("no independent count query", await index.countReads, 0)
                    r.equal("current summary retained only under its database", await model.summary(for: summary.sequenceID), id == h.libraryID ? summary : nil)
                }
            } catch { r.check("cover identity", false, String(describing: error)) }
            await db.closeDatabase(); StorageFixture.removeDirectory(directory)
        },
        TCCase(id: "I46S", title: "A held real page keeps its own count when a same-root replacement index arrives") { r in
            guard let h = await StorageHarness.make(name: "i46-snapshot-count") else { r.check("fixture", false); return }
            let directory = StorageFixture.temporaryDirectory("i46-count-db")
            let db = SQLiteIndex(databaseURL: directory.appendingPathComponent("index.sqlite"))
            do {
                try await db.reset(libraryID: h.libraryID, generation: h.generation)
                let a = StorageFixture.cards(count: 2, libraryID: h.libraryID, startingAt: StorageFixture.fixedDate)
                try await db.upsert(scanned: a)
                let index = FourthReviewPageIndex(base: db, holdFirst: true)
                let model = await LibraryViewModel(index: index, store: h.store)
                let held = Task { await model.loadFirstPage() }
                r.check("real page is held after materialization", await wait { await index.entered })
                try await db.reset(libraryID: h.libraryID, generation: h.generation)
                let b = StorageFixture.cards(count: 3, libraryID: h.libraryID, startingAt: StorageFixture.fixedDate)
                try await db.upsert(scanned: b)
                r.equal("replacement count is genuinely different", try await db.totalCommittedOriginalCount(), 3)
                await index.release(); await held.value
                r.equal("held source snapshot remains coherent", Set(await model.orderedSources.map(\.captureID)), Set(a.map(\.captureID)))
                r.equal("count belongs to that page snapshot", await model.individualOriginalCount, 2)
                r.equal("no extra count actor hop", await index.countReads, 0)
                await model.loadFirstPage()
                r.equal("current reload publishes replacement sources", Set(await model.orderedSources.map(\.captureID)), Set(b.map(\.captureID)))
                r.equal("current reload publishes replacement count", await model.individualOriginalCount, 3)
            } catch { r.check("same-root snapshot count", false, String(describing: error)) }
            await db.closeDatabase(); StorageFixture.removeDirectory(directory)
        }
    ])
}
