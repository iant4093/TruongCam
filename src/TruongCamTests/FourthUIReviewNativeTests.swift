#if canImport(UIKit) && canImport(XCTest) && !TC_TESTKIT_STANDALONE
import Foundation
import SwiftUI
import UIKit
import XCTest
@testable import TruongCam

/// Metadata-only export port: no original, Photos import or native share is
/// created. The hosted shipping library must still present real UIKit consent.
private actor FourthUIExportPort: ExportPreparing {
    private(set) var sessions: [ExportSession] = []
    private(set) var discarded: [UUID] = []
    var partial = true
    func setPartial(_ value: Bool) { partial = value }
    func prepareOriginalExport(sourceIDs: [CaptureID], includeSidecars: Bool) async throws -> ExportSession {
        let id = UUID()
        let session = ExportSession(sessionID: id, directoryRelativePath: "test-only/fourth-ui/\(id)",
            fileURLs: [URL(fileURLWithPath: "/test-only/fourth-ui/\(id)/kept.dng")],
            includedSidecars: includeSidecars,
            missingItems: partial ? ["missing-original.dng (unreadable locally)"] : [],
            totalByteCount: 4, preparedAtUTC: StorageFixture.fixedDate)
        sessions.append(session)
        return session
    }
    func preparePendingOriginalExport(transactionIDs: [TransactionID], includeSidecars: Bool) async throws -> ExportSession {
        try await prepareOriginalExport(sourceIDs: [], includeSidecars: includeSidecars)
    }
    func discardExport(sessionID: UUID) { discarded.append(sessionID) }
    func clearAbandonedExports() {}
}

final class FourthUIReviewNativeTests: XCTestCase {
    @MainActor private static func wait(_ condition: () async -> Bool) async throws {
        for _ in 0..<400 {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("The hosted partial-export boundary did not reach its expected state")
        throw CocoaError(.featureUnsupported)
    }
    @MainActor private static func window(app: AppEnvironment) async throws -> UIWindow {
        try await wait { UIApplication.shared.connectedScenes.contains(where: { $0 is UIWindowScene }) }
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 402, height: 874)
        window.rootViewController = UIHostingController(rootView: LibraryScreen(selecting: true).environment(app))
        window.makeKeyAndVisible()
        return window
    }
    @MainActor private static func alert(in controller: UIViewController?) -> UIAlertController? {
        guard let controller else { return nil }
        if let alert = controller as? UIAlertController { return alert }
        if let presented = alert(in: controller.presentedViewController) { return presented }
        return controller.children.compactMap { alert(in: $0) }.first
    }
    @MainActor private static func fixture(_ name: String) async throws -> (StorageHarness, AppEnvironment, FourthUIExportPort, [LibrarySourceCard]) {
        let fixture = await StorageHarness.make(name: name), h = try XCTUnwrap(fixture)
        let cards = StorageFixture.cards(count: 2, libraryID: h.libraryID, startingAt: StorageFixture.fixedDate)
        let index = InMemoryLibraryIndex()
        try await index.reset(libraryID: h.libraryID, generation: h.generation)
        try await index.upsert(scanned: cards)
        let app = AppEnvironment(), port = FourthUIExportPort()
        app.attach(store: h.store, index: index)
        app.exportPresenter = ExportPresenter(store: port)
        await app.library?.loadFirstPage()
        return (h, app, port, cards)
    }

    @MainActor func testHostedLibraryShowsExactAbsencesAndConfirmsTheHeldLibrarySession() async throws {
        let (_, app, port, cards) = try await Self.fixture("fourth-ui-library-consent")
        let window = try await Self.window(app: app)
        defer { window.isHidden = true; window.rootViewController = nil }
        app.exportSelectedOriginals(cards)
        try await Self.wait { Self.alert(in: window.rootViewController)?.isBeingPresented == false }
        let alert = try XCTUnwrap(Self.alert(in: window.rootViewController))
        let pending = try XCTUnwrap(app.pendingPartialExport), held = try XCTUnwrap(pending.preparedSession)
        XCTAssertEqual(alert.title, "Some photos are unavailable")
        XCTAssertTrue(alert.message?.contains("missing-original.dng") == true)
        XCTAssertFalse(alert.message?.contains("unreadable locally") == true)
        XCTAssertTrue(alert.message?.contains("won’t be included") == true)
        XCTAssertTrue(alert.actions.contains { $0.title == "Export available originals" })
        XCTAssertTrue(alert.actions.contains { $0.title == "Cancel" && $0.style == .cancel })
        XCTAssertEqual(pending.surface, .library)
        XCTAssertNil(app.exportPresenter?.presented, "Missing originals require visible consent before sharing")
        // This is the exact ID-bound action used by the shipping alert button.
        app.confirmPendingPartialExport(expectedID: pending.id)
        try await Self.wait { app.exportPresenter?.presented != nil && Self.alert(in: window.rootViewController) == nil }
        let presented = try XCTUnwrap(app.exportPresenter?.presented)
        XCTAssertEqual(presented.session.sessionID, held.sessionID)
        XCTAssertEqual(presented.session.fileURLs, held.fileURLs)
        XCTAssertTrue(app.exportPresenter?.ownsPresentation(.library) == true)
        let prepared = await port.sessions
        XCTAssertEqual(prepared.count, 1, "Confirmation shares the prepared bytes without another lookup/copy")
        await app.exportPresenter?.finished(sessionID: held.sessionID)

        await port.setPartial(false)
        app.exportSelectedOriginals(cards)
        try await Self.wait { app.exportPresenter?.presented != nil }
        XCTAssertNil(app.pendingPartialExport, "A complete export still needs no partial-consent dialog")
        XCTAssertNil(Self.alert(in: window.rootViewController))
        await app.exportPresenter?.finished(sessionID: app.exportPresenter?.presented?.session.sessionID)
    }

    @MainActor func testObsoleteLibraryAlertActionsCannotConfirmOrCancelReplacementConsent() async throws {
        let (_, app, port, cards) = try await Self.fixture("fourth-ui-library-cancel")
        let window = try await Self.window(app: app)
        defer { window.isHidden = true; window.rootViewController = nil }
        app.exportSelectedOriginals(cards)
        try await Self.wait { app.pendingPartialExport != nil && Self.alert(in: window.rootViewController) != nil }
        let old = try XCTUnwrap(app.pendingPartialExport), oldSession = try XCTUnwrap(old.preparedSession)
        app.exportSelectedOriginals(cards)
        try await Self.wait { app.pendingPartialExport?.id != nil && app.pendingPartialExport?.id != old.id }
        let current = try XCTUnwrap(app.pendingPartialExport), currentSession = try XCTUnwrap(current.preparedSession)
        app.confirmPendingPartialExport(expectedID: old.id)
        app.cancelPendingPartialExport(expectedID: old.id)
        XCTAssertEqual(app.pendingPartialExport?.id, current.id)
        XCTAssertNil(app.exportPresenter?.presented)
        app.cancelPendingPartialExport(expectedID: current.id)
        try await Self.wait { await port.discarded.contains(currentSession.sessionID) }
        let discarded = await port.discarded
        XCTAssertEqual(discarded.filter { $0 == oldSession.sessionID }.count, 1)
        XCTAssertEqual(discarded.filter { $0 == currentSession.sessionID }.count, 1)
        XCTAssertFalse(app.exportPresenter?.hasActiveExport == true)
        XCTAssertNil(app.pendingPartialExport)
        try await Self.wait { Self.alert(in: window.rootViewController) == nil }
    }

    @MainActor func testRootReplacementRevokesVisibleLibraryConsentAndOldActionsCannotAcceptNewRootCopies() async throws {
        let (h, app, port, cards) = try await Self.fixture("fourth-ui-root-consent")
        let window = try await Self.window(app: app)
        defer { window.isHidden = true; window.rootViewController = nil }
        app.exportSelectedOriginals(cards)
        try await Self.wait { app.pendingPartialExport != nil && Self.alert(in: window.rootViewController)?.isBeingPresented == false }
        let old = try XCTUnwrap(app.pendingPartialExport), oldSession = try XCTUnwrap(old.preparedSession)
        let newRoot = h.root.deletingLastPathComponent().appendingPathComponent("fourth-ui-replacement")
        try h.memory.createDirectory(at: newRoot, withIntermediateDirectories: true)
        guard case .initialized = await h.store.selectRoot(from: newRoot, confirmedLocalDestination: true) else {
            return XCTFail("The fixture must replace the actual grant")
        }
        app.refreshLibraryRootState()
        try await Self.wait { app.pendingPartialExport == nil && Self.alert(in: window.rootViewController) == nil }
        try await Self.wait { await port.discarded.contains(oldSession.sessionID) }
        let newLibraryID = try XCTUnwrap(h.store.rootState.libraryID)
        let newCards = StorageFixture.cards(count: 2, libraryID: newLibraryID, startingAt: StorageFixture.fixedDate)
        app.exportSelectedOriginals(newCards)
        try await Self.wait { app.pendingPartialExport != nil && Self.alert(in: window.rootViewController)?.isBeingPresented == false }
        let current = try XCTUnwrap(app.pendingPartialExport), currentSession = try XCTUnwrap(current.preparedSession)
        app.confirmPendingPartialExport(expectedID: old.id)
        app.cancelPendingPartialExport(expectedID: old.id)
        XCTAssertEqual(app.pendingPartialExport?.id, current.id)
        XCTAssertNil(app.exportPresenter?.presented)
        app.confirmPendingPartialExport(expectedID: current.id)
        try await Self.wait { app.exportPresenter?.presented != nil }
        XCTAssertEqual(app.exportPresenter?.presented?.session.sessionID, currentSession.sessionID)
        await app.exportPresenter?.finished(sessionID: currentSession.sessionID)
    }

    @MainActor func testSequenceConsentAppearsOnlyOnItsOwningSequenceSurface() async throws {
        let (h, app, port, cards) = try await Self.fixture("fourth-ui-consent-surface")
        let sequence = SequenceID()
        let members = cards.enumerated().map { ordinal, source in
            LibrarySourceCard(captureID: source.captureID, libraryID: source.libraryID,
                relativeOriginalPath: source.relativeOriginalPath, capturedAtUTC: source.capturedAtUTC,
                capturedAtProvenance: source.capturedAtProvenance, availability: source.availability,
                classification: source.classification, rawDimensions: source.rawDimensions, byteCount: source.byteCount,
                sequenceID: sequence, sequenceIndex: ordinal, sequenceKind: .exposureBracket,
                isTruongCamCapture: source.isTruongCamCapture, modificationFingerprint: source.modificationFingerprint)
        }
        let summary = SequenceSummary(sequenceID: sequence, kind: .exposureBracket, plannedCount: 2,
            committedCount: 2, missingIndices: [], failedIndices: [], skippedDeadlineCount: 0,
            status: .complete, startedAtUTC: StorageFixture.fixedDate)
        let index = try XCTUnwrap(app.libraryIndex)
        try await index.reset(libraryID: h.libraryID, generation: h.generation)
        try await index.upsert(scanned: members)
        try await index.updateSequences([summary])
        await app.library?.loadFirstPage()
        await app.library?.selectSequence(sequence)
        let window = try await Self.window(app: app)
        defer { window.isHidden = true; window.rootViewController = nil }
        app.exportSequenceOriginals(sequence)
        try await Self.wait { app.pendingPartialExport != nil }
        let pending = try XCTUnwrap(app.pendingPartialExport), session = try XCTUnwrap(pending.preparedSession)
        XCTAssertEqual(pending.surface, .sequence)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertNil(Self.alert(in: window.rootViewController), "The library cannot claim a sequence command's consent")
        window.rootViewController = UIHostingController(rootView:
            SequenceDetailView(sequenceID: sequence, summary: summary).environment(app))
        try await Self.wait { Self.alert(in: window.rootViewController)?.isBeingPresented == false }
        XCTAssertTrue(Self.alert(in: window.rootViewController)?.message?.contains("missing-original.dng") == true)
        app.cancelPendingPartialExport(expectedID: pending.id)
        try await Self.wait { await port.discarded.contains(session.sessionID) }
        XCTAssertNil(app.exportPresenter?.presented)
    }
}
#endif
