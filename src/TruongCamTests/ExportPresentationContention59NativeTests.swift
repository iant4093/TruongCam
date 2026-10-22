#if canImport(UIKit) && canImport(XCTest) && !TC_TESTKIT_STANDALONE
import ImageIO
import SwiftUI
import UIKit
import XCTest
@testable import TruongCam

/// Fresh generated JPEGs only. These tests do not invoke an external activity,
/// request Photos access, touch a library, or perform a real export.
private actor ExportContention59Store: ExportPreparing {
    private let sessions: [UUID: ExportSession]
    private(set) var discardedIDs: [UUID] = []
    init(_ sessions: [ExportSession]) {
        self.sessions = Dictionary(uniqueKeysWithValues: sessions.map { ($0.sessionID, $0) })
    }
    func prepareOriginalExport(sourceIDs: [CaptureID], includeSidecars: Bool) async throws -> ExportSession {
        throw CocoaError(.featureUnsupported)
    }
    func preparePendingOriginalExport(transactionIDs: [TransactionID], includeSidecars: Bool) async throws -> ExportSession {
        throw CocoaError(.featureUnsupported)
    }
    func discardExport(sessionID: UUID) async {
        discardedIDs.append(sessionID)
        if let file = sessions[sessionID]?.fileURLs.first {
            try? FileManager.default.removeItem(at: file.deletingLastPathComponent())
        }
    }
    func clearAbandonedExports() async {}
}

final class ExportPresentationContention59NativeTests: XCTestCase {
    @MainActor private func fixtures(_ count: Int) throws -> (URL, [ExportSession]) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("TruongCam-export-contention59-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let bytes = UIGraphicsImageRenderer(size: CGSize(width: 8, height: 8)).jpegData(withCompressionQuality: 0.8) { context in
            UIColor.systemOrange.setFill(); context.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
        }
        let sessions = try (0..<count).map { index -> ExportSession in
            let id = UUID(), directory = root.appendingPathComponent(id.uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let file = directory.appendingPathComponent("contention-\(index).jpg")
            try bytes.write(to: file)
            let source = try XCTUnwrap(CGImageSourceCreateWithURL(file as CFURL, nil))
            XCTAssertEqual(CGImageSourceGetCount(source), 1)
            XCTAssertNotNil(CGImageSourceCreateImageAtIndex(source, 0, nil))
            return ExportSession(sessionID: id, directoryRelativePath: "fixture/\(id.uuidString)", fileURLs: [file],
                includedSidecars: false, missingItems: [], totalByteCount: Int64(bytes.count), preparedAtUTC: Date())
        }
        return (root, sessions)
    }

    private func exists(_ session: ExportSession) -> Bool {
        session.fileURLs.allSatisfy { FileManager.default.fileExists(atPath: $0.path) }
    }

    @MainActor private func wait(_ predicate: () -> Bool) async throws {
        for _ in 0..<500 {
            if predicate() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("The hosted export did not reach its expected native presentation boundary")
        throw CocoaError(.featureUnsupported)
    }

    @MainActor private func waitForCleanup(_ store: ExportContention59Store, expected: [UUID]) async throws {
        for _ in 0..<500 {
            if await store.discardedIDs == expected { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Exact session cleanup did not match \(expected)")
        throw CocoaError(.featureUnsupported)
    }

    @MainActor private func activity(in controller: UIViewController?) -> UIActivityViewController? {
        guard let controller else { return nil }
        if let activity = controller as? UIActivityViewController { return activity }
        if let presented = activity(in: controller.presentedViewController) { return presented }
        for child in controller.children { if let found = activity(in: child) { return found } }
        return nil
    }

    @MainActor private func host(_ presenter: ExportPresenter) async throws -> UIWindow {
        try await wait { UIApplication.shared.connectedScenes.contains { $0 is UIWindowScene } }
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 402, height: 874)
        window.rootViewController = UIHostingController(rootView: Color.black
            .modifier(ExportSheetPresentation(presenter: presenter, surface: .nonViewer)))
        window.makeKeyAndVisible(); window.layoutIfNeeded()
        try await wait { window.rootViewController?.viewIfLoaded?.window === window }
        return window
    }

    @MainActor private func presentBlockingAlert(in window: UIWindow) async throws -> UIAlertController {
        let alert = UIAlertController(title: "Synthetic blocking confirmation", message: "No photos are changed.", preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        try XCTUnwrap(window.rootViewController).present(alert, animated: false)
        try await wait { alert.viewIfLoaded?.window === window && !alert.isBeingPresented }
        return alert
    }

    @MainActor func testPendingExportWaitsForNativeAlertThenMountsAndCleansAfterActualDismissal() async throws {
        let (root, sessions) = try fixtures(1)
        defer { try? FileManager.default.removeItem(at: root) }
        let session = sessions[0], store = ExportContention59Store(sessions), presenter = ExportPresenter(store: store)
        let window = try await host(presenter)
        defer { window.isHidden = true; window.rootViewController = nil }
        let alert = try await presentBlockingAlert(in: window)
        presenter.presentPrepared(session, description: "Waiting behind an alert")
        // Give both SwiftUI observation and the native presentation owner time
        // to consume the pending intent while the actual presenter is occupied.
        try await Task.sleep(for: .milliseconds(120))
        XCTAssertTrue(window.rootViewController?.presentedViewController === alert)
        XCTAssertNil(activity(in: window.rootViewController))
        XCTAssertTrue(exists(session)); XCTAssertTrue(presenter.hasActiveExport)
        XCTAssertEqual(presenter.presented?.session.sessionID, session.sessionID)
        let blocked = await store.discardedIDs
        XCTAssertTrue(blocked.isEmpty)
        alert.dismiss(animated: true)
        try await wait { self.activity(in: window.rootViewController)?.viewIfLoaded?.window === window }
        let sheet = try XCTUnwrap(activity(in: window.rootViewController))
        XCTAssertNil(alert.viewIfLoaded?.window)
        XCTAssertTrue(exists(session)); XCTAssertTrue(presenter.hasActiveExport)
        let completion = try XCTUnwrap(sheet.completionWithItemsHandler)
        completion(nil, false, nil, nil)
        XCTAssertTrue(exists(session), "The mounted reader owns its files through native closing")
        try await wait { sheet.viewIfLoaded?.window == nil && self.activity(in: window.rootViewController) == nil }
        try await waitForCleanup(store, expected: [session.sessionID])
        XCTAssertFalse(exists(session)); XCTAssertFalse(presenter.hasActiveExport)
    }

    @MainActor func testCancelBeforeMountDiscardsOnlyPendingSessionAndNextExportMountsWithoutRestart() async throws {
        let (root, sessions) = try fixtures(2)
        defer { try? FileManager.default.removeItem(at: root) }
        let a = sessions[0], b = sessions[1], store = ExportContention59Store(sessions), presenter = ExportPresenter(store: store)
        let window = try await host(presenter)
        defer { window.isHidden = true; window.rootViewController = nil }
        let alert = try await presentBlockingAlert(in: window)
        presenter.presentPrepared(a, description: "Cancelled before first mount")
        try await Task.sleep(for: .milliseconds(120))
        XCTAssertNil(activity(in: window.rootViewController))
        XCTAssertTrue(window.rootViewController?.presentedViewController === alert)
        await presenter.finished(sessionID: a.sessionID)
        try await waitForCleanup(store, expected: [a.sessionID])
        XCTAssertFalse(exists(a)); XCTAssertFalse(presenter.hasActiveExport)
        XCTAssertNil(presenter.presented)
        XCTAssertTrue(window.rootViewController?.presentedViewController === alert, "Cancelling pending A must not dismiss another modal")
        presenter.presentPrepared(b, description: "Next export from the same owner")
        try await Task.sleep(for: .milliseconds(120))
        XCTAssertNil(activity(in: window.rootViewController))
        XCTAssertTrue(exists(b))
        alert.dismiss(animated: true)
        try await wait { self.activity(in: window.rootViewController)?.viewIfLoaded?.window === window }
        let sheet = try XCTUnwrap(activity(in: window.rootViewController))
        XCTAssertEqual(presenter.presented?.session.sessionID, b.sessionID)
        XCTAssertFalse(exists(a)); XCTAssertTrue(exists(b))
        await presenter.finished(sessionID: a.sessionID)
        XCTAssertEqual(presenter.presented?.session.sessionID, b.sessionID, "Delayed A cleanup cannot finish B")
        XCTAssertTrue(sheet.viewIfLoaded?.window === window)
        sheet.completionWithItemsHandler?(nil, false, nil, nil)
        try await waitForCleanup(store, expected: [a.sessionID, b.sessionID])
        XCTAssertNil(sheet.viewIfLoaded?.window)
        XCTAssertFalse(exists(b)); XCTAssertFalse(presenter.hasActiveExport)
    }

    @MainActor func testRemovingBlockedPresentationModifierCleansPendingIntentAndFreshModifierCanExport() async throws {
        let (root, sessions) = try fixtures(2)
        defer { try? FileManager.default.removeItem(at: root) }
        let a = sessions[0], b = sessions[1], store = ExportContention59Store(sessions), presenter = ExportPresenter(store: store)
        try await wait { UIApplication.shared.connectedScenes.contains { $0 is UIWindowScene } }
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 402, height: 874)
        let hosting = UIHostingController(rootView: AnyView(Color.black
            .modifier(ExportSheetPresentation(presenter: presenter, surface: .nonViewer))))
        window.rootViewController = hosting
        window.makeKeyAndVisible(); window.layoutIfNeeded()
        defer { window.isHidden = true; window.rootViewController = nil }
        func containsAnchor(_ view: UIView) -> Bool {
            view is NativeExportPresentationAnchor || view.subviews.contains(where: containsAnchor)
        }
        try await wait { hosting.viewIfLoaded?.window === window && containsAnchor(hosting.view) }
        let alert = try await presentBlockingAlert(in: window)
        presenter.presentPrepared(a, description: "Owner removed before native presentation")
        try await Task.sleep(for: .milliseconds(120))
        XCTAssertNil(activity(in: hosting))
        XCTAssertEqual(presenter.presented?.session.sessionID, a.sessionID)
        XCTAssertTrue(exists(a)); XCTAssertTrue(presenter.hasActiveExport)
        XCTAssertTrue(hosting.presentedViewController === alert)
        let beforeRemoval = await store.discardedIDs
        XCTAssertTrue(beforeRemoval.isEmpty)

        // Remove only the SwiftUI presentation owner. Its unrelated UIKit alert
        // remains mounted while dismantleUIView cancels the unmounted intent.
        hosting.rootView = AnyView(Color.clear)
        try await wait { !containsAnchor(hosting.view) }
        try await waitForCleanup(store, expected: [a.sessionID])
        XCTAssertNil(presenter.presented); XCTAssertFalse(presenter.hasActiveExport)
        XCTAssertFalse(exists(a)); XCTAssertTrue(exists(b))
        XCTAssertTrue(hosting.presentedViewController === alert)
        XCTAssertTrue(alert.viewIfLoaded?.window === window)
        XCTAssertNil(activity(in: hosting))

        hosting.rootView = AnyView(Color.black
            .modifier(ExportSheetPresentation(presenter: presenter, surface: .nonViewer)))
        try await wait { containsAnchor(hosting.view) }
        presenter.presentPrepared(b, description: "Fresh presentation owner")
        try await Task.sleep(for: .milliseconds(120))
        XCTAssertTrue(hosting.presentedViewController === alert)
        XCTAssertNil(activity(in: hosting))
        XCTAssertEqual(presenter.presented?.session.sessionID, b.sessionID)
        XCTAssertTrue(exists(b))
        alert.dismiss(animated: true)
        try await wait { self.activity(in: hosting)?.viewIfLoaded?.window === window }
        let sheet = try XCTUnwrap(activity(in: hosting))
        XCTAssertTrue(exists(b)); XCTAssertTrue(presenter.hasActiveExport)
        await presenter.finished(sessionID: a.sessionID)
        XCTAssertEqual(presenter.presented?.session.sessionID, b.sessionID)
        XCTAssertTrue(sheet.viewIfLoaded?.window === window)
        sheet.completionWithItemsHandler?(nil, false, nil, nil)
        XCTAssertTrue(exists(b), "The fresh mounted reader retains its copies until actual dismissal")
        try await waitForCleanup(store, expected: [a.sessionID, b.sessionID])
        XCTAssertNil(sheet.viewIfLoaded?.window)
        XCTAssertNil(presenter.presented); XCTAssertFalse(presenter.hasActiveExport)
        XCTAssertFalse(exists(b))
    }
}
#endif
