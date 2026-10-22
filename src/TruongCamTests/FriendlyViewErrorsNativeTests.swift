#if canImport(UIKit) && canImport(XCTest) && !TC_TESTKIT_STANDALONE
import Foundation
import XCTest
@testable import TruongCam

private enum FriendlyViewFixture {
    static let privateDetail = "SQLite statement SELECT sourceID failed: NSCocoaErrorDomain Code=257 /private/recovery/secret.json"
    static var error: NSError {
        NSError(domain: "FriendlyViewInternalDomain", code: 257,
            userInfo: [NSLocalizedDescriptionKey: privateDetail])
    }
    static func card(_ original: LibrarySourceCard, availability: SourceAvailability? = nil,
                     path: String? = nil) -> LibrarySourceCard {
        LibrarySourceCard(captureID: original.captureID, libraryID: original.libraryID,
            relativeOriginalPath: path ?? original.relativeOriginalPath,
            capturedAtUTC: original.capturedAtUTC, capturedAtProvenance: original.capturedAtProvenance,
            availability: availability ?? original.availability, classification: original.classification,
            rawDimensions: original.rawDimensions, byteCount: original.byteCount,
            sequenceID: original.sequenceID, sequenceIndex: original.sequenceIndex,
            sequenceKind: original.sequenceKind, isTruongCamCapture: original.isTruongCamCapture,
            modificationFingerprint: original.modificationFingerprint)
    }
}

/// No system sharing or actual file/Photos mutation: these ports expose errors
/// at the shipping presenters while retaining the original diagnostic payload.
private actor FriendlyViewExportPort: ExportPreparing {
    var fail = true
    func setFail(_ value: Bool) { fail = value }
    func prepareOriginalExport(sourceIDs: [CaptureID], includeSidecars: Bool) async throws -> ExportSession {
        if fail { throw FriendlyViewFixture.error }
        return ExportSession(sessionID: UUID(), directoryRelativePath: "test-only/friendly-export",
            fileURLs: [URL(fileURLWithPath: "/test-only/friendly-export/visible.dng")],
            includedSidecars: includeSidecars, missingItems: [FriendlyViewFixture.privateDetail],
            totalByteCount: 4, preparedAtUTC: StorageFixture.fixedDate)
    }
    func preparePendingOriginalExport(transactionIDs: [TransactionID], includeSidecars: Bool) async throws -> ExportSession {
        try await prepareOriginalExport(sourceIDs: [], includeSidecars: includeSidecars)
    }
    func discardExport(sessionID: UUID) {}
    func clearAbandonedExports() {}
}

private actor FriendlyViewIndex: LibraryIndexing {
    let base = InMemoryLibraryIndex()
    var fail = true
    func setFail(_ value: Bool) { fail = value }
    func reset(libraryID: LibraryID, generation: RootGeneration) async throws { try await base.reset(libraryID: libraryID, generation: generation) }
    func ingest(_ receipts: [CommitReceipt]) async throws { try await base.ingest(receipts) }
    func upsert(scanned: [LibrarySourceCard]) async throws { try await base.upsert(scanned: scanned) }
    func updateSequences(_ summaries: [SequenceSummary]) async throws { try await base.updateSequences(summaries) }
    func markUnavailable(captureID: CaptureID, reason: String) async throws { try await base.markUnavailable(captureID: captureID, reason: reason) }
    func firstPage(size: Int) async throws -> LibraryPage {
        if fail { throw FriendlyViewFixture.error }
        return try await base.firstPage(size: size)
    }
    func page(after cursor: LibraryCursor, size: Int) async throws -> LibraryPage { throw FriendlyViewFixture.error }
    func detail(captureID: CaptureID) async throws -> LibrarySourceCard? { try await base.detail(captureID: captureID) }
    func sources(inSequence sequenceID: SequenceID) async throws -> [LibrarySourceCard] { try await base.sources(inSequence: sequenceID) }
    func dayGroupCounts() async throws -> [DayGroupCount] { try await base.dayGroupCounts() }
    func totalCommittedOriginalCount() async throws -> Int { try await base.totalCommittedOriginalCount() }
}

final class FriendlyViewErrorsNativeTests: XCTestCase {
    private func assertFriendly(_ message: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertFalse(message.isEmpty, file: file, line: line)
        for fragment in ["SELECT", "NSCocoa", "Code=", "/private/", "secret.json", "SQLite", "FriendlyViewInternalDomain"] {
            XCTAssertFalse(message.contains(fragment), "User copy leaked \(fragment): \(message)", file: file, line: line)
        }
    }

    @MainActor func testExportFailuresArePlainAcrossCommittedPreparedAndPendingRoutes() async throws {
        let port = FriendlyViewExportPort(), presenter = ExportPresenter(store: port)
        await presenter.export(sources: [CaptureID()], includeSidecars: false, description: "test photo")
        let committed = try XCTUnwrap(presenter.lastFailure)
        assertFriendly(committed.detail)
        XCTAssertEqual(committed.title, "Export failed")
        XCTAssertEqual(committed.actions, [.dismiss])
        XCTAssertNil(presenter.presented)
        presenter.clearLastFailure()
        guard case .failed(let prepared) = await presenter.prepare(sources: [CaptureID()], includeSidecars: false) else {
            return XCTFail("A genuine preparation failure must remain visible")
        }
        assertFriendly(prepared.detail)
        await presenter.exportPending(transactionIDs: [TransactionID()], description: "pending photo")
        assertFriendly(try XCTUnwrap(presenter.lastFailure?.detail))
        XCTAssertFalse(presenter.hasActiveExport)
        XCTAssertFalse(presenter.isPreparingExport)
        let logged = AppDiagnostics.description(for: FriendlyViewFixture.error, operation: "fixture.export")
        XCTAssertTrue(logged.contains(FriendlyViewFixture.privateDetail), "Full payload remains available to diagnostics")
    }

    @MainActor func testPartialAndEmptyExportMessagesKeepCountsAndRecoveryWithoutLeakingRawAbsences() async throws {
        let port = FriendlyViewExportPort(); await port.setFail(false)
        let presenter = ExportPresenter(store: port)
        await presenter.export(sources: [CaptureID()], includeSidecars: false, description: "test selection")
        let presented = try XCTUnwrap(presenter.presented)
        XCTAssertEqual(presented.session.missingItems, [FriendlyViewFixture.privateDetail], "Membership evidence stays intact")
        let notice = try XCTUnwrap(presenter.lastNotice)
        assertFriendly(notice)
        XCTAssertTrue(notice.contains("1 photo"))
        await presenter.finished(sessionID: presented.session.sessionID)
        await presenter.reportMissingAll(missing: [FriendlyViewFixture.privateDetail])
        let missing = try XCTUnwrap(presenter.lastFailure)
        assertFriendly(missing.detail)
        XCTAssertEqual(missing.actions, [.reconnect, .dismiss])
        XCTAssertNil(presenter.presented)
    }

    @MainActor func testGridViewerAndPhotoDetailsDoNotPublishInternalProviderReasons() async throws {
        let fixture = await StorageHarness.make(name: "friendly-view-error-projection"), h = try XCTUnwrap(fixture)
        let original = try XCTUnwrap(StorageFixture.cards(count: 1, libraryID: h.libraryID, startingAt: StorageFixture.fixedDate).first)
        let source = GalleryThumbnailSource.unavailable(reason: FriendlyViewFixture.privateDetail)
        let model = ThumbnailModel()
        await model.loadAndWait(card: original, source: source)
        guard case .unavailable(let gridMessage) = model.state else { return XCTFail("Missing preview remains visibly unavailable") }
        assertFriendly(gridMessage)
        await model.loadViewerAndWait(card: original, source: source)
        guard case .unavailable(let viewerMessage) = model.state else { return XCTFail("Missing viewer remains visibly unavailable") }
        assertFriendly(viewerMessage)
        let internalResult = try await DisplayImagePreparation.shared.prepare(.unavailable(reason: FriendlyViewFixture.privateDetail))
        guard case .unavailable(let internalReason) = internalResult else { return XCTFail("Internal outcome was changed") }
        XCTAssertEqual(internalReason, FriendlyViewFixture.privateDetail, "Only UI publication simplifies the reason")

        let handle = try await h.store.stageSource(bytes: StorageFixture.rawBytes(),
            metadata: StorageFixture.metadata(captureID: original.captureID, libraryID: h.libraryID))
        let receipt = try await h.store.commit(handle: handle)
        let committed = FriendlyViewFixture.card(original, path: receipt.relativeOriginalPath)
        let details = PhotoDetailModel(reader: { _ in throw FriendlyViewFixture.error })
        await details.load(card: committed, store: h.store)
        assertFriendly(try XCTUnwrap(details.error))
        XCTAssertNil(details.details)
        let readers = await h.store.activeReaderCount
        XCTAssertEqual(readers, 0, "Presentation copy must not change read-scope cleanup")
    }

    @MainActor func testPartialConsentUsesFilenamesAndHumanOrdinalsInsteadOfIDsAndReasons() throws {
        let id = LibraryID(), original = try XCTUnwrap(StorageFixture.cards(count: 1, libraryID: id, startingAt: StorageFixture.fixedDate).first)
        let named = FriendlyViewFixture.card(original, path: "originals/2026/10/18/holiday.dng")
        let unknown = CaptureID()
        let message = PartialExportConsentCopy.message(absences: [
            "\(named.captureID.description) (unreadable: \(FriendlyViewFixture.privateDetail))",
            "planned source 3 (never delivered)",
            "\(unknown.description) (missing)",
            "/private/library/missing.heic (unreadable: \(FriendlyViewFixture.privateDetail))"
        ], sources: [named])
        assertFriendly(message)
        XCTAssertTrue(message.contains("4 photos won’t be included"))
        XCTAssertTrue(message.contains("holiday.dng"))
        XCTAssertTrue(message.contains("Photo 3 wasn’t captured"))
        XCTAssertTrue(message.contains("missing.heic"))
        XCTAssertFalse(message.contains(named.captureID.description))
        XCTAssertFalse(message.contains(unknown.description))
        XCTAssertFalse(message.contains("never delivered"))
    }

    @MainActor func testPhotosActivityFailureCopyKeepsPermissionActionAndOriginalSafety() {
        for failure in [DNGPhotosExporter.Failure.permission, .changedCopy, .noDNG] {
            assertFriendly(DNGPhotosSaveController.failureMessage(for: failure))
        }
        let permission = DNGPhotosSaveController.failureMessage(for: DNGPhotosExporter.Failure.permission)
        XCTAssertTrue(permission.contains("Settings"))
        XCTAssertTrue(permission.contains("still in Files"))
        let unknown = DNGPhotosSaveController.failureMessage(for: FriendlyViewFixture.error)
        assertFriendly(unknown)
        XCTAssertTrue(unknown.contains("still in Files"))
        XCTAssertFalse(unknown.contains("Nothing was added"), "An unknown Photos failure cannot promise an atomic rollback")
    }

    @MainActor func testFirstLibraryReadFailureIsFriendlyAndRetryStillLoadsTheSamePhotos() async throws {
        let index = FriendlyViewIndex(), id = LibraryID(), generation = RootGeneration(4)
        let cards = StorageFixture.cards(count: 2, libraryID: id, startingAt: StorageFixture.fixedDate)
        try await index.reset(libraryID: id, generation: generation)
        try await index.upsert(scanned: cards)
        let model = LibraryViewModel(index: index, store: nil)
        await model.loadFirstPage()
        assertFriendly(try XCTUnwrap(model.lastReconcileIssue))
        XCTAssertTrue(model.orderedSources.isEmpty)
        XCTAssertFalse(model.isLoading)
        await index.setFail(false)
        await model.loadFirstPage()
        XCTAssertEqual(Set(model.orderedSources.map(\.captureID)), Set(cards.map(\.captureID)))
        XCTAssertEqual(model.individualOriginalCount, 2)
    }
}
#endif
