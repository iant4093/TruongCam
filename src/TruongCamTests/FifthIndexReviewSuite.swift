import Foundation
#if canImport(XCTest)
@testable import TruongCam
#endif

/// Actual disposable SQLite rows/cursors; no original decoding or user folders.
enum FifthIndexReviewSuite {
    private static func expectExpired(_ db: SQLiteIndex, _ cursor: LibraryCursor,
                                      _ r: TCRecorder, _ label: String) async throws {
        do {
            _ = try await db.page(after: cursor, size: 2)
            r.check(label, false, "A previous index snapshot was accepted")
        } catch LibraryIndexPagingError.expiredCursor {
            r.check(label, true)
        }
    }
    static let suite = TCSuite(id: "FifthIndexReview", title: "Same-root pagination content identity and reopened metadata", cases: [
        TCCase(id: "I47M", title: "Every metadata writer expires an old cursor without changing root generation") { r in
            guard let h = await StorageHarness.make(name: "i47-writers") else { r.check("fixture", false); return }
            let directory = StorageFixture.temporaryDirectory("i47-writers")
            let db = SQLiteIndex(databaseURL: directory.appendingPathComponent("index.sqlite"))
            do {
                let id = CaptureID()
                let staged = try await h.store.stageSource(bytes: StorageFixture.rawBytes(),
                    metadata: StorageFixture.metadata(captureID: id, libraryID: h.libraryID))
                let receipt = try await h.store.commit(handle: staged)
                for writer in 0..<5 {
                    try await db.reset(libraryID: h.libraryID, generation: h.generation)
                    let cards = StorageFixture.cards(count: 5, libraryID: h.libraryID, startingAt: StorageFixture.fixedDate)
                    try await db.upsert(scanned: cards)
                    let page = try await db.firstPage(size: 2)
                    guard let cursor = page.nextCursor else { throw CocoaError(.fileReadCorruptFile) }
                    r.check("production cursor has a content identity", cursor.indexRevision != nil)
                    switch writer {
                    case 0: try await db.reset(libraryID: h.libraryID, generation: h.generation)
                    case 1: try await db.upsert(scanned: Array(cards.suffix(1)))
                    case 2: try await db.markUnavailable(captureID: cards[0].captureID, reason: "test unavailable")
                    case 3:
                        try await db.updateSequences([SequenceSummary(sequenceID: SequenceID(), kind: .interval,
                            plannedCount: 1, committedCount: 0, missingIndices: [0], failedIndices: [],
                            skippedDeadlineCount: 0, status: .interrupted, startedAtUTC: StorageFixture.fixedDate)])
                    default: try await db.ingest([receipt])
                    }
                    try await expectExpired(db, cursor, r, "writer \(writer) cannot mix page snapshots")
                    let current = try await db.firstPage(size: 2)
                    r.equal("writer keeps actual library identity", current.indexedLibraryID, h.libraryID)
                    r.equal("writer does not invent another root generation", current.libraryGeneration, h.generation)
                }
            } catch { r.check("actual SQLite writer boundaries", false, String(describing: error)) }
            await db.closeDatabase(); StorageFixture.removeDirectory(directory)
        },
        TCCase(id: "I47P", title: "The gallery replaces old pages after a same-folder rebuild and quietly continues") { r in
            guard let h = await StorageHarness.make(name: "i47-model-pages") else { r.check("fixture", false); return }
            let directory = StorageFixture.temporaryDirectory("i47-model-pages")
            let db = SQLiteIndex(databaseURL: directory.appendingPathComponent("index.sqlite"))
            do {
                try await db.reset(libraryID: h.libraryID, generation: h.generation)
                let count = MetadataBounds.maxIndexPageSize
                let old = StorageFixture.cards(count: count + 4, libraryID: h.libraryID, startingAt: StorageFixture.fixedDate)
                try await db.upsert(scanned: old)
                let model = await LibraryViewModel(index: db, store: h.store)
                await model.loadFirstPage()
                r.equal("old page really loaded", await model.loadedSourceCount, count)
                r.check("old page has a next cursor", await model.hasMorePages)
                try await db.reset(libraryID: h.libraryID, generation: h.generation)
                let current = StorageFixture.cards(count: count + 3, libraryID: h.libraryID,
                    startingAt: StorageFixture.fixedDate.addingTimeInterval(-1000))
                try await db.upsert(scanned: current)
                await model.loadNextPage()
                r.equal("expired cursor restarts at page one", await model.loadedPageCount, 1)
                r.equal("current count replaces old count", await model.individualOriginalCount, count + 3)
                r.equal("old page set is fully replaced", Set(await model.orderedSources.map(\.captureID)), Set(current.prefix(count).map(\.captureID)))
                r.equal("ordinary rebuild is not a false provider error", await model.lastReconcileIssue, nil)
                r.equal("ordinary rebuild needs no error banner", await model.pageLoadFailure, nil)
                await model.loadNextPage()
                r.equal("new pages continue normally", await model.loadedPageCount, 2)
                r.equal("all new sources appear exactly once", Set(await model.orderedSources.map(\.captureID)), Set(current.map(\.captureID)))
                r.equal("no duplicate source cards", await model.loadedSourceCount, current.count)
                r.check("current library is complete", await model.hasMorePages == false)
            } catch { r.check("actual SQLite and gallery reload", false, String(describing: error)) }
            await db.closeDatabase(); StorageFixture.removeDirectory(directory)
        },
        TCCase(id: "I47N", title: "Unchanged pages and empty writes retain their cursor; reopening revokes it") { r in
            let directory = StorageFixture.temporaryDirectory("i47-current-pages")
            let db = SQLiteIndex(databaseURL: directory.appendingPathComponent("index.sqlite"))
            let id = LibraryID(), generation = RootGeneration(47)
            do {
                try await db.reset(libraryID: id, generation: generation)
                let cards = StorageFixture.cards(count: 6, libraryID: id, startingAt: StorageFixture.fixedDate)
                try await db.upsert(scanned: cards)
                let first = try await db.firstPage(size: 2)
                guard let cursor = first.nextCursor else { throw CocoaError(.fileReadCorruptFile) }
                try await db.upsert(scanned: []); try await db.ingest([]); try await db.updateSequences([])
                let next = try await db.page(after: cursor, size: 2)
                r.equal("unchanged next page has two rows", next.cards.count, 2)
                r.check("pages do not overlap", Set(first.cards.map(\.id)).isDisjoint(with: next.cards.map(\.id)))
                r.equal("next page does not query another total", next.totalCommittedOriginalCount, nil)
                await db.closeDatabase()
                try await expectExpired(db, cursor, r, "reopened metadata never accepts an old handle cursor")
                let reopened = try await db.firstPage(size: 2)
                r.equal("reopened database retains real library", reopened.indexedLibraryID, id)
                r.equal("reopened database retains persisted count", reopened.totalCommittedOriginalCount, 6)
                r.notEqual("new handle has a fresh cursor", reopened.nextCursor?.indexRevision, cursor.indexRevision)
            } catch { r.check("current and reopened pagination", false, String(describing: error)) }
            await db.closeDatabase(); StorageFixture.removeDirectory(directory)
        },
        TCCase(id: "I47E", title: "A deleted empty cache does not inherit the former handle's library identity") { r in
            let directory = StorageFixture.temporaryDirectory("i47-empty-reopen")
            let db = SQLiteIndex(databaseURL: directory.appendingPathComponent("index.sqlite"))
            do {
                let id = LibraryID()
                try await db.reset(libraryID: id, generation: RootGeneration(47))
                let before = try await db.firstPage(size: 2)
                r.equal("old empty database was genuinely bound", before.indexedLibraryID, id)
                await db.deleteDatabaseFiles()
                let empty = try await db.firstPage(size: 2)
                r.equal("new empty database has no inherited identity", empty.indexedLibraryID, nil)
                r.equal("new empty database has no inherited generation", empty.libraryGeneration, .zero)
                r.equal("new empty database count is zero", empty.totalCommittedOriginalCount, 0)
                let nextID = LibraryID()
                try await db.reset(libraryID: nextID, generation: RootGeneration(48))
                let next = try await db.firstPage(size: 2)
                r.equal("later explicit rebuild publishes its real identity", next.indexedLibraryID, nextID)
                r.equal("later explicit rebuild publishes its generation", next.libraryGeneration, RootGeneration(48))
            } catch { r.check("empty-cache replacement", false, String(describing: error)) }
            await db.closeDatabase(); StorageFixture.removeDirectory(directory)
        }
    ])
}
