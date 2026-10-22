#if canImport(UIKit) && canImport(XCTest) && !TC_TESTKIT_STANDALONE
import ImageIO
import SwiftUI
import UIKit
import XCTest
@testable import TruongCam

/// Only generated JPEG fixtures in a fresh temporary directory. No user library,
/// capture, external activity, Photos authorization or real export is involved.
private actor Export59LifetimeStore: ExportPreparing {
    private let sessions: [UUID: ExportSession]
    private(set) var discardedIDs: [UUID] = []
    private var preparationQueue: [ExportSession]
    init(_ sessions: [ExportSession], preparing: [ExportSession]? = nil) {
        self.sessions = Dictionary(uniqueKeysWithValues: sessions.map { ($0.sessionID, $0) })
        preparationQueue = preparing ?? sessions
    }
    func prepareOriginalExport(sourceIDs: [CaptureID], includeSidecars: Bool) async throws -> ExportSession {
        guard !preparationQueue.isEmpty else { throw CocoaError(.fileNoSuchFile) }
        return preparationQueue.removeFirst()
    }
    func preparePendingOriginalExport(transactionIDs: [TransactionID], includeSidecars: Bool) async throws -> ExportSession {
        try await prepareOriginalExport(sourceIDs: [], includeSidecars: includeSidecars)
    }
    func discardExport(sessionID: UUID) async {
        discardedIDs.append(sessionID)
        if let file = sessions[sessionID]?.fileURLs.first { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
    }
    func clearAbandonedExports() async {}
}

final class ExportPresentation59NativeTests: XCTestCase {
    @MainActor private func fixtures(_ count: Int) throws -> (URL, [ExportSession]) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("TruongCam-export59-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let bytes = UIGraphicsImageRenderer(size: CGSize(width: 8, height: 8)).jpegData(withCompressionQuality: 0.8) { context in
            UIColor.systemBlue.setFill(); context.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
        }
        let sessions = try (0..<count).map { index -> ExportSession in
            let id = UUID(), directory = root.appendingPathComponent(id.uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let file = directory.appendingPathComponent("fixture-\(index).jpg")
            try bytes.write(to: file)
            let source = try XCTUnwrap(CGImageSourceCreateWithURL(file as CFURL, nil))
            XCTAssertEqual(CGImageSourceGetCount(source), 1, "The mounted share receives a real valid fixture, not a missing URL.")
            XCTAssertNotNil(CGImageSourceCreateImageAtIndex(source, 0, nil))
            return ExportSession(sessionID: id, directoryRelativePath: "fixture/\(id.uuidString)", fileURLs: [file],
                includedSidecars: false, missingItems: [], totalByteCount: Int64(bytes.count), preparedAtUTC: Date())
        }
        return (root, sessions)
    }
    private func exists(_ session: ExportSession) -> Bool { session.fileURLs.allSatisfy { FileManager.default.fileExists(atPath: $0.path) } }

    @MainActor private func wait(_ predicate: () -> Bool) async throws {
        for _ in 0..<500 {
            if predicate() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("The hosted share presentation did not reach its expected UIKit lifetime boundary")
        throw CocoaError(.featureUnsupported)
    }
    @MainActor private func waitForCleanup(_ store: Export59LifetimeStore, count: Int) async throws {
        for _ in 0..<500 {
            if await store.discardedIDs.count == count { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Expected exact export cleanup did not follow actual dismissal")
        throw CocoaError(.featureUnsupported)
    }
    @MainActor private func activity(in controller: UIViewController?) -> UIActivityViewController? {
        guard let controller else { return nil }
        if let activity = controller as? UIActivityViewController { return activity }
        if let presented = activity(in: controller.presentedViewController) { return presented }
        for child in controller.children { if let found = activity(in: child) { return found } }
        return nil
    }
    @MainActor private func host(_ presenter: ExportPresenter, surface: ExportSheetPresentation.Surface = .nonViewer) async throws -> UIWindow {
        try await wait { UIApplication.shared.connectedScenes.contains { $0 is UIWindowScene } }
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene); window.frame = CGRect(x: 0, y: 0, width: 402, height: 874)
        window.rootViewController = UIHostingController(rootView: Color.black
            .modifier(ExportSheetPresentation(presenter: presenter, surface: surface)))
        window.makeKeyAndVisible()
        return window
    }

    @MainActor func testLeasedCompletionRetainsFilesAndStaleSessionCannotDismissOrDeleteReplacement() async throws {
        let (root, sessions) = try fixtures(2); defer { try? FileManager.default.removeItem(at: root) }
        let a = sessions[0], b = sessions[1], store = Export59LifetimeStore(sessions), presenter = ExportPresenter(store: store)
        presenter.presentPrepared(a, description: "A")
        presenter.presentationWillPresent(sessionID: a.sessionID)
        await presenter.finished(sessionID: a.sessionID)
        XCTAssertNil(presenter.presented, "Completion requests dismissal of the exact intent.")
        XCTAssertTrue(presenter.hasActiveExport); XCTAssertTrue(exists(a))
        let beforeDismissal = await store.discardedIDs
        XCTAssertTrue(beforeDismissal.isEmpty, "A mounted sheet still owns its exact copies.")
        presenter.presentPrepared(b, description: "B")
        presenter.presentationWillPresent(sessionID: b.sessionID)
        await presenter.presentationDidDismiss(sessionID: a.sessionID)
        XCTAssertEqual(presenter.presented?.session.sessionID, b.sessionID)
        XCTAssertFalse(exists(a)); XCTAssertTrue(exists(b)); XCTAssertTrue(presenter.hasActiveExport)
        presenter.requestDismissal(sessionID: a.sessionID)
        await presenter.finished(sessionID: a.sessionID)
        await presenter.presentationDidDismiss(sessionID: a.sessionID)
        XCTAssertEqual(presenter.presented?.session.sessionID, b.sessionID, "Repeated A callbacks cannot clear B.")
        let afterStale = await store.discardedIDs
        XCTAssertEqual(afterStale, [a.sessionID], "A is cleaned exactly once.")
        await presenter.finished(sessionID: b.sessionID)
        XCTAssertTrue(exists(b), "B also retains its mounted lifetime.")
        await presenter.presentationDidDismiss(sessionID: b.sessionID)
        await presenter.presentationDidDismiss(sessionID: b.sessionID)
        let final = await store.discardedIDs
        XCTAssertEqual(final, [a.sessionID, b.sessionID]); XCTAssertFalse(presenter.hasActiveExport)
        XCTAssertFalse(exists(b))
    }

    @MainActor func testActualAppSupersedeCommandKeepsMountedOldCopiesUntilDismissal() async throws {
        let (root, sessions) = try fixtures(2); defer { try? FileManager.default.removeItem(at: root) }
        let a = sessions[0], b = sessions[1], store = Export59LifetimeStore(sessions, preparing: [sessions[1]])
        let presenter = ExportPresenter(store: store)
        let fixture = await StorageHarness.make(name: "export59-app-supersede"), h = try XCTUnwrap(fixture)
        let app = AppEnvironment(); app.attach(store: h.store, index: InMemoryLibraryIndex()); app.exportPresenter = presenter
        presenter.presentPrepared(a, description: "Mounted A")
        presenter.presentationWillPresent(sessionID: a.sessionID)
        app.exportCommittedOriginal(CaptureID()) // Uses the shipping supersede + frozen preparation path.
        try await wait { presenter.presented?.session.sessionID == b.sessionID }
        XCTAssertTrue(exists(a)); XCTAssertTrue(exists(b))
        let duringReplacement = await store.discardedIDs
        XCTAssertTrue(duringReplacement.isEmpty, "App supersession may request dismissal but cannot delete mounted A.")
        await presenter.presentationDidDismiss(sessionID: a.sessionID)
        XCTAssertEqual(presenter.presented?.session.sessionID, b.sessionID)
        XCTAssertFalse(exists(a)); XCTAssertTrue(exists(b))
        await presenter.finished(sessionID: a.sessionID)
        XCTAssertEqual(presenter.presented?.session.sessionID, b.sessionID)
        await presenter.finished(sessionID: b.sessionID)
        let discarded = await store.discardedIDs
        XCTAssertEqual(discarded, [a.sessionID, b.sessionID]); XCTAssertFalse(presenter.hasActiveExport)
    }

    @MainActor func testUnpresentedSessionCleansImmediatelyAndDuplicateFinishIsInert() async throws {
        let (root, sessions) = try fixtures(1); defer { try? FileManager.default.removeItem(at: root) }
        let session = sessions[0], store = Export59LifetimeStore(sessions), presenter = ExportPresenter(store: store)
        presenter.presentPrepared(session, description: "Not mounted")
        await presenter.finished(sessionID: session.sessionID)
        await presenter.finished(sessionID: session.sessionID)
        let discarded = await store.discardedIDs
        XCTAssertEqual(discarded, [session.sessionID]); XCTAssertFalse(exists(session))
        XCTAssertNil(presenter.presented); XCTAssertFalse(presenter.hasActiveExport)
    }

    @MainActor func testActualActivityCompletionRetainsCopiesUntilOwningSheetActuallyDismisses() async throws {
        let (root, sessions) = try fixtures(1); defer { try? FileManager.default.removeItem(at: root) }
        let session = sessions[0], store = Export59LifetimeStore(sessions), presenter = ExportPresenter(store: store)
        let window = try await host(presenter)
        defer { window.isHidden = true; window.rootViewController = nil }
        presenter.presentPrepared(session, description: "Mounted JPEG fixture")
        try await wait { self.activity(in: window.rootViewController)?.viewIfLoaded?.window != nil }
        let controller = try XCTUnwrap(activity(in: window.rootViewController))
        XCTAssertTrue(exists(session)); XCTAssertTrue(presenter.hasActiveExport)
        let before = await store.discardedIDs
        XCTAssertTrue(before.isEmpty)
        let completion = try XCTUnwrap(controller.completionWithItemsHandler)
        completion(nil, false, nil, nil)
        XCTAssertTrue(controller.viewIfLoaded?.window != nil, "The native sheet is still mounted at callback entry.")
        XCTAssertTrue(exists(session), "Activity completion cannot synchronously delete mounted readers' input.")
        XCTAssertTrue(presenter.hasActiveExport)
        try await wait { controller.viewIfLoaded?.window == nil && self.activity(in: window.rootViewController) == nil }
        try await waitForCleanup(store, count: 1)
        XCTAssertFalse(exists(session)); XCTAssertFalse(presenter.hasActiveExport)
        completion(nil, false, nil, nil)
        let after = await store.discardedIDs
        XCTAssertEqual(after, [session.sessionID], "A delayed native completion is idempotent.")
    }

    @MainActor func testDeeperNativePresentationDoesNotFinishTheShareOrRemoveItsCopies() async throws {
        let (root, sessions) = try fixtures(1); defer { try? FileManager.default.removeItem(at: root) }
        let session = sessions[0], store = Export59LifetimeStore(sessions), presenter = ExportPresenter(store: store)
        let window = try await host(presenter)
        defer { window.isHidden = true; window.rootViewController = nil }
        presenter.presentPrepared(session, description: "Nested presentation fixture")
        try await wait {
            guard let activity = self.activity(in: window.rootViewController) else { return false }
            return activity.viewIfLoaded?.window != nil && activity.presentedViewController == nil && !activity.isBeingPresented
        }
        let controller = try XCTUnwrap(activity(in: window.rootViewController)), deeper = UIViewController()
        deeper.view.backgroundColor = .systemBackground; deeper.modalPresentationStyle = .fullScreen
        controller.present(deeper, animated: false)
        try await wait { deeper.viewIfLoaded?.window != nil }
        XCTAssertTrue(exists(session)); XCTAssertTrue(presenter.hasActiveExport)
        XCTAssertEqual(presenter.presented?.session.sessionID, session.sessionID)
        let covered = await store.discardedIDs
        XCTAssertTrue(covered.isEmpty, "Content being covered is not the owning share's dismissal.")
        deeper.dismiss(animated: false)
        try await wait { controller.presentedViewController == nil && controller.viewIfLoaded?.window != nil }
        XCTAssertTrue(exists(session)); XCTAssertTrue(presenter.hasActiveExport)
        let restored = await store.discardedIDs
        XCTAssertTrue(restored.isEmpty)
        controller.completionWithItemsHandler?(nil, false, nil, nil)
        try await waitForCleanup(store, count: 1)
        XCTAssertFalse(exists(session))
    }

    @MainActor func testMountedReplacementWaitsForOldDismissalAndOldCompletionCannotTouchNewSheet() async throws {
        let (root, sessions) = try fixtures(2); defer { try? FileManager.default.removeItem(at: root) }
        let a = sessions[0], b = sessions[1], store = Export59LifetimeStore(sessions), presenter = ExportPresenter(store: store)
        let window = try await host(presenter)
        defer { window.isHidden = true; window.rootViewController = nil }
        presenter.presentPrepared(a, description: "A")
        try await wait { self.activity(in: window.rootViewController)?.viewIfLoaded?.window != nil }
        let first = try XCTUnwrap(activity(in: window.rootViewController)), oldCompletion = try XCTUnwrap(first.completionWithItemsHandler)
        presenter.presentPrepared(b, description: "B")
        XCTAssertTrue(exists(a)); XCTAssertTrue(exists(b), "New intent cannot destroy the mounted old controller's files.")
        try await wait {
            guard let current = self.activity(in: window.rootViewController) else { return false }
            return current !== first && current.viewIfLoaded?.window != nil
        }
        let second = try XCTUnwrap(activity(in: window.rootViewController))
        XCTAssertNil(first.viewIfLoaded?.window, "The second controller cannot replace a still-mounted A.")
        try await waitForCleanup(store, count: 1)
        XCTAssertFalse(exists(a)); XCTAssertTrue(exists(b))
        oldCompletion(nil, false, nil, nil)
        XCTAssertEqual(presenter.presented?.session.sessionID, b.sessionID)
        XCTAssertTrue(second.viewIfLoaded?.window != nil); XCTAssertTrue(exists(b))
        let afterStale = await store.discardedIDs
        XCTAssertEqual(afterStale, [a.sessionID])
        second.completionWithItemsHandler?(nil, false, nil, nil)
        try await waitForCleanup(store, count: 2)
        let final = await store.discardedIDs
        XCTAssertEqual(final, [a.sessionID, b.sessionID]); XCTAssertFalse(exists(b))
    }
}
#endif
