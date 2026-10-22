#if canImport(UIKit) && canImport(XCTest) && !TC_TESTKIT_STANDALONE
import SwiftUI
import UIKit
import XCTest
@testable import TruongCam

final class ViewerDelete59NativeTests: XCTestCase {
    @MainActor private func anchors(_ view: UIView) -> [GalleryTrashAnchorView] {
        ((view as? GalleryTrashAnchorView).map { [$0] } ?? []) + view.subviews.flatMap(anchors)
    }
    @MainActor func testShippingViewerOwnsAnAboveTrashConfirmationAndReleasesItsPresenter() async throws {
        let fixture = await StorageHarness.make(name: "viewer59-delete-anchor"), h = try XCTUnwrap(fixture)
        let card = try XCTUnwrap(StorageFixture.cards(count: 1, libraryID: h.libraryID,
            startingAt: StorageFixture.fixedDate).first)
        let app = AppEnvironment()
        app.attach(store: h.store, index: InMemoryLibraryIndex())
        app.attachThumbnails(store: h.store, thumbnails: LibraryPreviewFixture())
        let model = ThumbnailModel()
        await model.loadViewerAndWait(card: card, source: app.libraryThumbnailSource,
            sourceRevision: app.libraryThumbnailRevision, rootState: app.libraryRootState)
        for _ in 0..<200 {
            if UIApplication.shared.connectedScenes.contains(where: { $0 is UIWindowScene }) { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 402, height: 874)
        let host = UIHostingController(rootView: SourceDetailView(card: card, orderedSources: [card], viewerModel: model).environment(app))
        window.rootViewController = host; window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil }
        for _ in 0..<200 {
            if anchors(window).first?.bounds.width == 44 { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        let anchor = try XCTUnwrap(anchors(window).first)
        XCTAssertEqual(anchors(window).count, 1, "The single-photo viewer uses the shared Trash confirmation")
        let sourceRect = anchor.convert(anchor.bounds, to: window)
        XCTAssertEqual(sourceRect.width, 44, accuracy: 1)
        XCTAssertEqual(sourceRect.height, 44, accuracy: 1)
        XCTAssertGreaterThan(sourceRect.midY, window.bounds.height * 0.75, "Anchor belongs to the bottom Trash target, not the whole viewer")
        let id = UUID(); var dismissed: [UUID] = []
        anchor.update(requestID: id, count: 1, onConfirm: { _ in XCTFail("This geometry test must not delete a photo") },
            onDismiss: { dismissed.append($0) })
        for _ in 0..<300 {
            if let alert = anchor.confirmation, !alert.isBeingPresented,
               alert.view.window != nil, alert.transitionCoordinator == nil { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let alert = try XCTUnwrap(anchor.confirmation)
        let popover = try XCTUnwrap(alert.popoverPresentationController)
        XCTAssertEqual(popover.permittedArrowDirections, .down)
        let proxy = try XCTUnwrap(popover.sourceView)
        XCTAssertEqual(proxy.convert(proxy.bounds, to: window).midX, sourceRect.midX, accuracy: 1)
        XCTAssertEqual(proxy.convert(proxy.bounds, to: window).midY, sourceRect.midY, accuracy: 1)
        let container = try XCTUnwrap(popover.containerView)
        let cardRect = alert.view.convert(alert.view.bounds, to: container)
        let target = proxy.convert(proxy.bounds, to: container)
        XCTAssertLessThanOrEqual(cardRect.maxY, target.minY + 1, "The native card sits above the actual Trash button")
        anchor.performAction(for: id, alert: alert, confirms: false)
        for _ in 0..<300 {
            if dismissed == [id], host.presentedViewController == nil { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(dismissed, [id]); XCTAssertNil(host.presentedViewController)
    }
}
#endif
