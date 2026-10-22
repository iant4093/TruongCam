#if canImport(UIKit) && canImport(XCTest) && !TC_TESTKIT_STANDALONE
import XCTest
@testable import TruongCam

final class SecondRootReviewNativeTests: XCTestCase {
    @MainActor func testSequenceCompletionRefreshPublishesStoredStatusWithoutReopeningTheLibrary() async throws {
        let fixture = await StorageHarness.make(name: "r244-complete-callback")
        let h = try XCTUnwrap(fixture)
        let dir = StorageFixture.temporaryDirectory("r244-complete-db")
        defer { StorageFixture.removeDirectory(dir) }
        let db = SQLiteIndex(databaseURL: dir.appendingPathComponent("index.sqlite"))
        try await db.reset(libraryID: h.libraryID, generation: h.generation)
        let app = AppEnvironment()
        app.attach(store: h.store, index: db)
        app.attach(librarySession: LibrarySessionCoordinator(store: h.store, index: db))
        let sequence = SequenceID(), captures = [CaptureID(), CaptureID()]
        var receipts: [CommitReceipt] = []
        for (ordinal, capture) in captures.enumerated() {
            let link = SourceSequenceLink(id: sequence, kind: .interval, index: SourceOrdinal(ordinal), plannedCount: 2)
            let handle = try await h.store.stageSource(bytes: StorageFixture.rawBytes(), metadata: StorageFixture.metadata(captureID: capture, libraryID: h.libraryID, sequence: link))
            receipts.append(try await h.store.commit(handle: handle))
        }
        await app.ingestCommitted(receipts)
        XCTAssertEqual(app.library?.summary(for: sequence)?.status, .interrupted)
        var document = SequenceDocument(sequenceID: sequence, libraryID: h.libraryID, kind: .interval, plannedCount: 2,
            sourcePlan: [], intervalSeconds: 1, baseline: nil, startedAtUTC: StorageFixture.fixedDate)
        document.completedSources = captures.enumerated().map { SequenceCompletedSource(index: $0.offset, captureID: $0.element.rawValue) }
        document.status = .complete; document.endedAtUTC = StorageFixture.fixedDate; document.restorationStatus = .restored
        try await h.store.writeSequenceDocument(document)
        h.memory.resetCounters()
        await app.librarySession?.refreshSequenceSummary(sequence)
        XCTAssertEqual(h.memory.scanInvocations, 0, "The final summary reads its one document, not any collection")
        h.memory.resetCounters()
        await app.refreshAfterSequence(sequenceID: sequence)
        let summary = try XCTUnwrap(app.library?.summary(for: sequence))
        XCTAssertEqual(h.memory.scanInvocations, 1, "Only the existing internal pending-recovery scan runs; the library collections are not rescanned")
        XCTAssertTrue(summary.isComplete)
        XCTAssertEqual(summary.committedCount, 2)
        XCTAssertEqual(app.library?.individualOriginalCount, 2)
        XCTAssertEqual(app.pendingOriginalCount, 0)
        await db.closeDatabase()
    }
}
#endif
