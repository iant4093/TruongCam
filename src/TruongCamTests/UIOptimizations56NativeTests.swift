#if canImport(UIKit) && canImport(XCTest) && !TC_TESTKIT_STANDALONE
import Observation
import SwiftUI
import UIKit
import XCTest
@testable import TruongCam

@MainActor @Observable private final class ViewerOrder56Fixture {
    var order: [LibrarySourceCard]
    let opened: LibrarySourceCard
    let viewer: ThumbnailModel
    init(order: [LibrarySourceCard], viewer: ThumbnailModel) {
        self.order = order; opened = order[1]; self.viewer = viewer
    }
}
private struct ViewerOrder56FixtureView: View {
    let fixture: ViewerOrder56Fixture
    var body: some View {
        SourceDetailView(card: fixture.opened, orderedSources: fixture.order, viewerModel: fixture.viewer)
    }
}

final class UIOptimizations56NativeTests: XCTestCase {
    @MainActor private func wait(_ predicate: () -> Bool) async throws {
        for _ in 0..<300 {
            if predicate() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("The shipping viewer did not reach its expected metadata/image identity")
        throw CocoaError(.featureUnsupported)
    }
    @MainActor private func pager(in view: UIView) -> OriginalPagerView? {
        if let result = view as? OriginalPagerView { return result }
        return view.subviews.compactMap { pager(in: $0) }.first
    }
    @MainActor func testViewerKeepsItsOrderAcrossParentRefreshAndPagesInBothDirections() async throws {
        let fixture = await StorageHarness.make(name: "ui56-viewer-order"), h = try XCTUnwrap(fixture)
        let cards = StorageFixture.cards(count: 3, libraryID: h.libraryID, startingAt: StorageFixture.fixedDate)
        let app = AppEnvironment(); app.attach(store: h.store, index: InMemoryLibraryIndex())
        app.attachThumbnails(store: h.store, thumbnails: LibraryPreviewFixture())
        let viewer = ThumbnailModel()
        await viewer.loadViewerAndWait(card: cards[1], source: app.libraryThumbnailSource,
            sourceRevision: app.libraryThumbnailRevision, rootState: app.libraryRootState)
        let value = ViewerOrder56Fixture(order: cards, viewer: viewer)
        try await wait { UIApplication.shared.connectedScenes.contains { $0 is UIWindowScene } }
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene); window.frame = CGRect(x: 0, y: 0, width: 402, height: 874)
        window.rootViewController = UIHostingController(rootView: ViewerOrder56FixtureView(fixture: value).environment(app))
        window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil }
        try await wait { self.pager(in: window)?.configuration.captureID == cards[1].captureID }
        let pageView = try XCTUnwrap(pager(in: window)), scroll = pageView.scroll
        value.order = [] // A parent first-page refresh must not strand this open viewer.
        try await Task.sleep(for: .milliseconds(40))
        XCTAssertEqual(pageView.configuration.previousCaptureID, cards[0].captureID)
        XCTAssertEqual(pageView.configuration.nextCaptureID, cards[2].captureID)
        XCTAssertTrue(pageView.scroll === scroll)
        pageView.configuration.next()
        try await wait { pageView.configuration.captureID == cards[2].captureID }
        XCTAssertEqual(pageView.configuration.position, 2)
        XCTAssertTrue(pageView.scroll.imageView.image?.cgImage === pageView.configuration.image)
        XCTAssertFalse(pageView.configuration.hasNext)
        pageView.configuration.previous()
        try await wait { pageView.configuration.captureID == cards[1].captureID }
        XCTAssertEqual(pageView.configuration.position, 1)
        XCTAssertTrue(pageView.scroll === scroll)
        XCTAssertTrue(pageView.scroll.imageView.image?.cgImage === pageView.configuration.image)
    }
}
#endif
