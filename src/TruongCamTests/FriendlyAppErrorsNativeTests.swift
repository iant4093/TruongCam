#if canImport(UIKit) && canImport(XCTest) && !TC_TESTKIT_STANDALONE
import Foundation
import XCTest
@testable import TruongCam

/// These ports never access Files or Photos. The diagnostic contains a domain,
/// code, private path and internal operation that must not become app copy.
private enum FriendlyAppFault {
    static var error: NSError {
        NSError(domain: "TechnicalFixtureDomain", code: 913,
            userInfo: [NSLocalizedDescriptionKey: "SQLITE_CORRUPT internalStep /private/fixture/library.json"])
    }
    static let detail = "SQLITE_CORRUPT internalStep /private/fixture/library.json"
}

private final class FriendlyAppStore: LibraryStoring, @unchecked Sendable {
    let libraryID = LibraryID()
    let generation = RootGeneration(48)
    let outcome: RootSelectionOutcome?
    let reconcileFails: Bool
    let diagnosticIssues: [String]
    let rootOverride: LibraryRootState?
    init(outcome: RootSelectionOutcome? = nil, reconcileFails: Bool = false, diagnosticIssues: [String] = [], rootOverride: LibraryRootState? = nil) {
        self.outcome = outcome; self.reconcileFails = reconcileFails; self.diagnosticIssues = diagnosticIssues
        self.rootOverride = rootOverride
    }
    var rootState: LibraryRootState { rootOverride ?? .writable(libraryID: libraryID, generation: generation) }
    var grantedRootURL: URL? { URL(fileURLWithPath: "/fixture-only/friendly-app") }
    var currentManifest: LibraryManifest? { nil }
    var selectedRootDescription: String? { "Friendly fixture" }
    func selectRoot(from grantedURL: URL, confirmedLocalDestination: Bool) async -> RootSelectionOutcome {
        outcome ?? .initialized(libraryID: libraryID, generation: generation)
    }
    func reconnectStoredRoot() async -> RootSelectionOutcome { outcome ?? .initialized(libraryID: libraryID, generation: generation) }
    func releaseRoot() async {}
    func reconcile(onProgress: (@Sendable (ScanProgress) -> Void)?) async throws -> ReconciledLibrary {
        if reconcileFails { throw FriendlyAppFault.error }
        return ReconciledLibrary(libraryID: libraryID, generation: generation, verifiedOriginalCount: 0,
            recoveredRAWCount: 0, missingOriginalCount: 0, conflictCount: 0, pendingCount: 0,
            sequences: [], issues: diagnosticIssues)
    }
    func reconciledSourceCards(after cursor: ScanCursor?, limit: Int) async throws -> ReconciledCardPage { ReconciledCardPage.empty }
    func allReconciledSourceCards() async throws -> [LibrarySourceCard] { [] }
    func browsableSourceCards(limit: Int) async throws -> [LibrarySourceCard] { [] }
    func stageSource(bytes: Data, metadata: SourceCaptureMetadata) async throws -> StagedSourceHandle { throw FriendlyAppFault.error }
    func commit(handle: StagedSourceHandle) async throws -> CommitReceipt { throw FriendlyAppFault.error }
    func retry(transactionID: TransactionID) async throws -> CommitReceipt { throw FriendlyAppFault.error }
    func pendingOriginals() async -> [PendingOriginal] { [] }
    func organizeMetadata() async throws -> Int { throw FriendlyAppFault.error }
    func trashOriginal(card: LibrarySourceCard, generation: RootGeneration) async throws -> PhotoTrashRecord { throw FriendlyAppFault.error }
    func permanentlyDeleteOriginal(record: PhotoTrashRecord, generation: RootGeneration) async throws { throw FriendlyAppFault.error }
    func restoreOriginal(trashID: UUID, libraryID: LibraryID, generation: RootGeneration) async throws { throw FriendlyAppFault.error }
    func prepareOriginalExport(sourceIDs: [CaptureID], includeSidecars: Bool) async throws -> ExportSession { throw FriendlyAppFault.error }
    func preparePendingOriginalExport(transactionIDs: [TransactionID], includeSidecars: Bool) async throws -> ExportSession { throw FriendlyAppFault.error }
    func discardExport(sessionID: UUID) async {}
    func clearAbandonedExports() async {}
    func writeSequenceDocument(_ document: SequenceDocument) async throws { throw FriendlyAppFault.error }
    func readSequenceDocument(_ sequenceID: SequenceID) async throws -> SequenceDocument { throw FriendlyAppFault.error }
    func originalURL(for captureID: CaptureID, relativePath: String) -> URL? { nil }
    func withRootReadAccess<T: Sendable>(_ body: @Sendable (URL) throws -> T) async throws -> T { throw FriendlyAppFault.error }
    func readOriginal<T: Sendable>(relativePath: String, _ body: @escaping @Sendable (URL) throws -> T) async throws -> T { throw FriendlyAppFault.error }
    func openScopedRead() async throws -> ScopedReadLease { throw FriendlyAppFault.error }
    func closeScopedRead(_ lease: ScopedReadLease) {}
}

@MainActor private final class FriendlyAppPicker: FolderPicking {
    func pickLocalLibraryFolder() async -> URL? { URL(fileURLWithPath: "/fixture-only/picked-folder") }
    func localDestinationDecision(for url: URL) async -> LocalDestinationDecision { .confirmedLocalDestination }
}

final class FriendlyAppErrorsNativeTests: XCTestCase {
    private func assertFriendly(_ text: String?, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertFalse(text?.isEmpty ?? true, file: file, line: line)
        for technical in ["SQLITE_CORRUPT", "internalStep", "/private/", "TechnicalFixtureDomain", "913", "metadata version"] {
            XCTAssertFalse(text?.contains(technical) == true, "Technical detail leaked: \(text ?? "nil")", file: file, line: line)
        }
    }
    @MainActor func testFolderSelectionKeepsRecoveryActionsButHidesProviderAndSchemaDetails() async throws {
        let outcomes: [RootSelectionOutcome] = [
            .conflictingManifest(reason: FriendlyAppFault.detail),
            .rejectedCloudLocation(reason: FriendlyAppFault.detail),
            .localityUnconfirmed(reason: FriendlyAppFault.detail),
            .unavailable(reason: FriendlyAppFault.detail),
            .readOnlyNewerSchema(found: 913, supported: 1),
            .rejectedOwnContainer
        ]
        for outcome in outcomes {
            let store = FriendlyAppStore(outcome: outcome), app = AppEnvironment(folderPicker: FriendlyAppPicker())
            app.attach(store: store, index: InMemoryLibraryIndex())
            await app.selectLibraryFolder()
            let failure = try XCTUnwrap(app.failure)
            assertFriendly(failure.title); assertFriendly(failure.detail)
            XCTAssertEqual(failure.actions, [.reconnect, .dismiss])
            XCTAssertEqual(app.libraryRootState, store.rootState, "Message changes don't change actual folder authority")
        }
    }
    @MainActor func testPublishedRootStatusKeepsDiagnosticAuthorityWithoutDisplayingItsReason() async throws {
        for state in [LibraryRootState.readOnly(reason: FriendlyAppFault.detail, libraryID: LibraryID()),
                      .unavailable(reason: FriendlyAppFault.detail, libraryID: LibraryID())] {
            let store = FriendlyAppStore(rootOverride: state), app = AppEnvironment()
            app.attach(store: store, index: InMemoryLibraryIndex())
            assertFriendly(app.libraryStatusLine)
            XCTAssertEqual(app.libraryRootState, state, "Full typed root authority remains available internally")
            XCTAssertTrue(app.needsFolderSelection)
            await app.refreshPublishedRoot()
            assertFriendly(app.libraryStatusLine)
        }
    }
    @MainActor func testSessionFolderFailuresAreFriendlyAndUnconfirmedFolderCanStillBeReconfirmed() async throws {
        let outcomes: [RootSelectionOutcome] = [
            .conflictingManifest(reason: FriendlyAppFault.detail),
            .rejectedCloudLocation(reason: FriendlyAppFault.detail),
            .localityUnconfirmed(reason: FriendlyAppFault.detail),
            .unavailable(reason: FriendlyAppFault.detail), .rejectedOwnContainer
        ]
        let picked = URL(fileURLWithPath: "/fixture-only/picked-folder")
        for outcome in outcomes {
            let store = FriendlyAppStore(outcome: outcome)
            let session = LibrarySessionCoordinator(store: store, index: InMemoryLibraryIndex())
            let opened = await session.selectRoot(picked)
            XCTAssertFalse(opened)
            assertFriendly(session.status.detailMessage)
            if case .localityUnconfirmed = outcome { XCTAssertEqual(session.rootAwaitingReconfirmation, picked) }
            else { XCTAssertNil(session.rootAwaitingReconfirmation) }
        }
    }
    @MainActor func testRebuildAndReconciliationIssuesNeverExposeTheUnderlyingDiagnostic() async throws {
        let failed = FriendlyAppStore(reconcileFails: true)
        let failedSession = LibrarySessionCoordinator(store: failed, index: InMemoryLibraryIndex())
        await failedSession.rebuildIndex()
        guard case .unavailable = failedSession.status else { return XCTFail("The failed rebuild still reports unavailable") }
        assertFriendly(failedSession.status.detailMessage)
        let store = FriendlyAppStore(diagnosticIssues: [FriendlyAppFault.detail, FriendlyAppFault.detail])
        let session = LibrarySessionCoordinator(store: store, index: InMemoryLibraryIndex())
        await session.rebuildIndex()
        XCTAssertEqual(session.status, .ready(verified: 0, recovered: 0, missing: 0))
        XCTAssertEqual(session.issues.count, 1, "Detailed scanner issues become one useful user message")
        assertFriendly(session.issues.first)
        XCTAssertTrue(session.issues.first?.contains("refreshing") == true)
        await session.refreshSequenceSummary(SequenceID())
        XCTAssertEqual(session.issues.count, 2)
        assertFriendly(session.issues.last)
        XCTAssertTrue(session.issues.last?.contains("Refresh the library") == true)
    }
    @MainActor func testOrganizeRetryAndBatchTrashFailuresStayFriendlyWithoutClaimingSuccess() async throws {
        let store = FriendlyAppStore(), app = AppEnvironment()
        app.attach(store: store, index: InMemoryLibraryIndex())
        app.exportPresenter = ExportPresenter(store: store)
        await app.organizeLibraryMetadata()
        assertFriendly(app.failure?.detail)
        XCTAssertEqual(app.failure?.actions, [.dismiss])
        await app.retryPendingOriginal(TransactionID())
        assertFriendly(app.exportPresenter?.lastFailure?.detail)
        XCTAssertEqual(app.exportPresenter?.lastFailure?.actions, [.retrySave, .exportPending, .dismiss])
        let cards = StorageFixture.cards(count: 1, libraryID: store.libraryID, startingAt: StorageFixture.fixedDate)
        let result = await app.trashOriginals(cards, generation: store.generation)
        XCTAssertTrue(result.completed.isEmpty)
        assertFriendly(result.failure)
        XCTAssertFalse(app.photoMutationInProgress)
        XCTAssertNil(app.photoMutationProgress)
        let record = PhotoTrashRecord(id: UUID(), libraryID: store.libraryID, captureID: CaptureID(),
            originalPath: "originals/test.dng", metadataPath: "metadata/test.json", originalSHA256: "a", metadataSHA256: "b",
            deletedAtUTC: StorageFixture.fixedDate)
        for permanently in [false, true] {
            let trash = await app.performTrashAction([record], permanently: permanently, generation: store.generation)
            XCTAssertTrue(trash.completed.isEmpty)
            assertFriendly(trash.failure)
            XCTAssertFalse(app.photoMutationInProgress)
        }
    }
}
#endif
