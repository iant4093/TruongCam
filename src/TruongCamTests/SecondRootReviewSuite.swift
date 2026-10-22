import Foundation
#if canImport(XCTest)
@testable import TruongCam
#endif

/// A held boundary around the actual SQLite implementation. The actor is
/// deliberately reentrant while reset is held, so it cannot mask writer races.
private actor SecondRootHeldIndex: LibraryIndexing {
    let base: SQLiteIndex
    private(set) var resets: [LibraryID] = []
    private var resetWaiter: CheckedContinuation<Void, Never>?
    private var released = false
    let failHeldReset: Bool
    init(base: SQLiteIndex, failHeldReset: Bool = false) { self.base = base; self.failHeldReset = failHeldReset }
    func releaseReset() { released = true; resetWaiter?.resume(); resetWaiter = nil }
    func reset(libraryID: LibraryID, generation: RootGeneration) async throws {
        resets.append(libraryID)
        if resets.count == 1 {
            if !released { await withCheckedContinuation { resetWaiter = $0 } }
            if failHeldReset { throw CocoaError(.fileWriteNoPermission) }
        }
        try await base.reset(libraryID: libraryID, generation: generation)
    }
    func ingest(_ receipts: [CommitReceipt]) async throws { try await base.ingest(receipts) }
    func upsert(scanned: [LibrarySourceCard]) async throws { try await base.upsert(scanned: scanned) }
    func updateSequences(_ summaries: [SequenceSummary]) async throws { try await base.updateSequences(summaries) }
    func markUnavailable(captureID: CaptureID, reason: String) async throws { try await base.markUnavailable(captureID: captureID, reason: reason) }
    func firstPage(size: Int) async throws -> LibraryPage { try await base.firstPage(size: size) }
    func page(after cursor: LibraryCursor, size: Int) async throws -> LibraryPage { try await base.page(after: cursor, size: size) }
    func detail(captureID: CaptureID) async throws -> LibrarySourceCard? { try await base.detail(captureID: captureID) }
    func sources(inSequence sequenceID: SequenceID) async throws -> [LibrarySourceCard] { try await base.sources(inSequence: sequenceID) }
    func dayGroupCounts() async throws -> [DayGroupCount] { try await base.dayGroupCounts() }
    func totalCommittedOriginalCount() async throws -> Int { try await base.totalCommittedOriginalCount() }
}

enum SecondRootReviewSuite {
    private static func wait(_ condition: @escaping @Sendable () async -> Bool) async -> Bool {
        for _ in 0..<2000 {
            if await condition() { return true }
            try? await Task.sleep(for: .milliseconds(1))
        }
        return await condition()
    }
    private static func seed(_ h: StorageHarness, libraryID: LibraryID, capture: CaptureID = CaptureID()) async throws -> CommitReceipt {
        let handle = try await h.store.stageSource(bytes: StorageFixture.rawBytes(), metadata: StorageFixture.metadata(captureID: capture, libraryID: libraryID))
        return try await h.store.commit(handle: handle)
    }
    private static func selectB(_ h: StorageHarness) async throws -> LibraryID {
        let url = h.root.deletingLastPathComponent().appendingPathComponent("different-root")
        try h.memory.createDirectory(at: url, withIntermediateDirectories: true)
        let result = await h.store.selectRoot(from: url, confirmedLocalDestination: true)
        guard case .initialized(let id, _) = result else { throw CocoaError(.fileWriteUnknown) }
        return id
    }
    static let suite = TCSuite(id: "SecondRootReview", title: "Exact-root serialized SQLite rebuild and recovered availability", cases: [
        TCCase(id: "R244W", title: "Held older root index writes drain before a newer root reset, without stale success or error publication") { r in
            for failOld in [false, true] {
                guard let h = await StorageHarness.make(name: "r244-writer-\(failOld)") else { r.check("fixture", false); return }
                let dir = StorageFixture.temporaryDirectory("r244-writer-db")
                do {
                    _ = try await seed(h, libraryID: h.libraryID)
                    let db = SQLiteIndex(databaseURL: dir.appendingPathComponent("index.sqlite"))
                    let held = SecondRootHeldIndex(base: db, failHeldReset: failOld)
                    let session = await LibrarySessionCoordinator(store: h.store, index: held)
                    let old = Task { await session.rebuildIndex() }
                    r.check("old reset held", await wait { await held.resets.count == 1 })
                    let oldIdentity = await session.rebuildIdentityForTesting
                    let b = try await selectB(h)
                    let bReceipts = [try await seed(h, libraryID: b), try await seed(h, libraryID: b)]
                    // Compare to the current root's display projection, rather
                    // than demanding raw provider diagnostics in ordinary UI.
                    // This independent index does not overtake the held writer.
                    let currentSession = await LibrarySessionCoordinator(store: h.store, index: InMemoryLibraryIndex())
                    await currentSession.rebuildIndex()
                    let expectedBIssues = await currentSession.issues
                    let newer = Task { await session.rebuildIndex() }
                    r.check("new root request entered", await wait { await session.rebuildIdentityForTesting != oldIdentity })
                    r.equal("new writer cannot overtake held old write", await held.resets, [h.libraryID])
                    await held.releaseReset(); await old.value; await newer.value
                    r.equal("resets preserve actual serial ownership", await held.resets, [h.libraryID, b])
                    let page = try await db.firstPage(size: 20)
                    let ids = page.cards.compactMap { card -> CaptureID? in if case .single(let source) = card.kind { return source.captureID }; return nil }
                    r.equal("new root retains exactly its real originals", Set(ids), Set(bReceipts.map(\.captureID)))
                    r.equal("real SQLite exact count", try await db.totalCommittedOriginalCount(), 2)
                    r.equal("new root status survives old result", await session.status, .ready(verified: 2, recovered: 0, missing: 0))
                    r.equal("old error cannot overwrite current root messages", await session.issues, expectedBIssues)
                    await db.closeDatabase()
                } catch { r.check("held root writer", false, String(describing: error)) }
                StorageFixture.removeDirectory(dir)
            }
        },
        TCCase(id: "R244R", title: "Released root revokes a held rebuild before it can publish ready or new source rows") { r in
            guard let h = await StorageHarness.make(name: "r244-release") else { r.check("fixture", false); return }
            let dir = StorageFixture.temporaryDirectory("r244-release-db")
            defer { StorageFixture.removeDirectory(dir) }
            do {
                _ = try await seed(h, libraryID: h.libraryID)
                let held = SecondRootHeldIndex(base: SQLiteIndex(databaseURL: dir.appendingPathComponent("held.sqlite")))
                let session = await LibrarySessionCoordinator(store: h.store, index: held)
                let task = Task { await session.rebuildIndex() }
                r.check("reset held", await wait { await held.resets.count == 1 })
                await session.invalidateRoot(); await h.store.releaseRoot()
                await held.releaseReset(); await task.value
                r.equal("released status remains idle", await session.status, .idle)
                r.equal("no stale publication time", await session.lastReconciledAt, nil)
                r.equal("old pages not inserted", try await held.totalCommittedOriginalCount(), 0)
                await held.base.closeDatabase()
            } catch { r.check("released rebuild", false, String(describing: error)) }
        },
        TCCase(id: "R244I", title: "A late verified receipt from another grant cannot pollute the current SQLite library") { r in
            guard let h = await StorageHarness.make(name: "r244-ingest") else { r.check("fixture", false); return }
            let dir = StorageFixture.temporaryDirectory("r244-ingest-db")
            defer { StorageFixture.removeDirectory(dir) }
            do {
                let a = try await seed(h, libraryID: h.libraryID)
                let bID = try await selectB(h), b = try await seed(h, libraryID: bID)
                let db = SQLiteIndex(databaseURL: dir.appendingPathComponent("index.sqlite"))
                let session = await LibrarySessionCoordinator(store: h.store, index: db)
                await session.rebuildIndex()
                await session.ingestCommitted([a, b])
                r.equal("stale receipt is not indexed", try await db.detail(captureID: a.captureID), nil)
                r.equal("matching receipt remains indexed", try await db.detail(captureID: b.captureID)?.captureID, b.captureID)
                r.equal("no cross-library count", try await db.totalCommittedOriginalCount(), 1)
                r.equal("old original still retained", h.memory.fileBytes(at: h.finalURL(for: a.captureID)), StorageFixture.rawBytes())
                await db.closeDatabase()
            } catch { r.check("current receipt boundary", false, String(describing: error)) }
        },
        TCCase(id: "R244D", title: "An extant recovered DNG without app metadata stays local, viewable and exactly exportable after real SQLite rebuild") { r in
            guard let h = await StorageHarness.make(name: "r244-recovered") else { r.check("fixture", false); return }
            let dir = StorageFixture.temporaryDirectory("r244-recovered-db")
            defer { StorageFixture.removeDirectory(dir) }
            do {
                let path = "originals/user-photo.dng", bytes = StorageFixture.rawBytes()
                try h.memory.createDirectory(at: h.root.appendingPathComponent("originals"), withIntermediateDirectories: true)
                try h.memory.writeNewFile(at: h.root.appendingPathComponent(path), bytes: bytes)
                let db = SQLiteIndex(databaseURL: dir.appendingPathComponent("index.sqlite"))
                let session = await LibrarySessionCoordinator(store: h.store, index: db)
                await session.rebuildIndex()
                let model = await LibraryViewModel(index: db, store: h.store)
                await model.loadFirstPage()
                let sources = await model.orderedSources
                r.equal("recovered original remains visible", sources.count, 1)
                guard let source = sources.first else { r.check("source exists", false); return }
                r.equal("extant bytes remain local", source.availability, .local)
                r.check("viewer/export eligibility", source.canExportOriginal)
                r.check("not falsely authored capture", !source.isTruongCamCapture)
                if case .recoveredRAW(let issue) = source.classification { r.check("metadata diagnostic retained", issue != nil) }
                else { r.check("recovered classification", false) }
                let exported = try await h.store.prepareOriginalExport(sourceIDs: [source.captureID], includeSidecars: false)
                r.equal("one exact original exported", exported.fileURLs.count, 1)
                r.equal("unchanged exported bytes", h.memory.fileBytes(at: exported.fileURLs[0]), bytes)
                await h.store.discardExport(sessionID: exported.sessionID)
                await db.closeDatabase()
            } catch { r.check("recovered real index", false, String(describing: error)) }
        }
    ])
}
