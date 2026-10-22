#if canImport(UIKit) && canImport(XCTest) && !TC_TESTKIT_STANDALONE
import XCTest
import UIKit
@testable import TruongCam

final class NativeLibraryPerformanceTests: XCTestCase {
    @MainActor func testPlaceholderRetriesWhenRealSourceArrivesAndFingerprintChanges() async throws {
        let fixture = await StorageHarness.make(name: "native-placeholder-retry")
        let h = try XCTUnwrap(fixture)
        let card = StorageFixture.cards(count: 1, libraryID: h.libraryID, startingAt: StorageFixture.fixedDate)[0]
        let model = ThumbnailModel()
        await model.loadAndWait(card: card, source: .unavailable(reason: "Not attached yet"), sourceRevision: 0, rootState: h.store.rootState)
        guard case .unavailable = model.state else { return XCTFail("Initial placeholder must be honest") }
        let provider = LibraryPreviewFixture()
        let source = GalleryThumbnailSource.scoped(store: h.store, thumbnails: provider)
        await model.loadAndWait(card: card, source: source, sourceRevision: 1, rootState: h.store.rootState)
        guard case .loaded = model.state else { return XCTFail("Attaching source re-arms a visible placeholder") }
        XCTAssertEqual(provider.count, 1)
        await model.loadAndWait(card: card, source: source, sourceRevision: 1, rootState: h.store.rootState)
        XCTAssertEqual(provider.count, 1, "An unchanged visible tile reuses its image")
        let changed = LibrarySourceCard(captureID: card.captureID, libraryID: card.libraryID,
            relativeOriginalPath: card.relativeOriginalPath, capturedAtUTC: card.capturedAtUTC,
            capturedAtProvenance: card.capturedAtProvenance, availability: card.availability,
            classification: card.classification, rawDimensions: card.rawDimensions, byteCount: card.byteCount,
            sequenceID: nil, sequenceIndex: nil, sequenceKind: nil, isTruongCamCapture: true,
            modificationFingerprint: "changed")
        await model.loadAndWait(card: changed, source: source, sourceRevision: 1, rootState: h.store.rootState)
        XCTAssertEqual(provider.count, 2, "Changed source bytes invalidate the old same-capture display")
        XCTAssertNotEqual(provider.identities.first, provider.identities.last)
        guard case .loaded = model.state else { return XCTFail("Changed photo must publish its own image") }
        let viewer = ThumbnailModel()
        await viewer.loadViewerAndWait(card: card, source: source)
        let firstViewerIdentity = provider.identities.last
        await viewer.loadViewerAndWait(card: changed, source: source)
        XCTAssertNotEqual(firstViewerIdentity, provider.identities.last,
            "Real viewer provider cache identity must change with the source fingerprint")
        XCTAssertEqual(provider.count, 4)
    }

    @MainActor func testOpenViewerRetriesLateSourceAndSourceRevisionInvalidatesLoadedImage() async throws {
        let fixture = await StorageHarness.make(name: "native-viewer-source-retry")
        let h = try XCTUnwrap(fixture)
        let card = StorageFixture.cards(count: 1, libraryID: h.libraryID, startingAt: StorageFixture.fixedDate)[0]
        let viewer = ThumbnailModel()
        await viewer.loadViewerAndWait(card: card, source: .unavailable(reason: "Not attached yet"), sourceRevision: 0, rootState: h.store.rootState)
        guard case .unavailable = viewer.state else { return XCTFail("Initial viewer placeholder") }
        let provider = LibraryPreviewFixture()
        let source = GalleryThumbnailSource.scoped(store: h.store, thumbnails: provider)
        await viewer.loadViewerAndWait(card: card, source: source, sourceRevision: 1, rootState: h.store.rootState)
        guard case .loaded = viewer.state else { return XCTFail("Open viewer must retry late provider") }
        XCTAssertEqual(provider.count, 1)
        await viewer.loadViewerAndWait(card: card, source: source, sourceRevision: 1, rootState: h.store.rootState)
        XCTAssertEqual(provider.count, 1, "Stable viewer request reuses its image")
        await viewer.loadViewerAndWait(card: card, source: source, sourceRevision: 2, rootState: h.store.rootState)
        XCTAssertEqual(provider.count, 2, "A replacement provider invalidates even an already loaded same photo")
        guard case .loaded = viewer.state else { return XCTFail("Replacement viewer image must load") }
    }

    @MainActor func testColdGridReadDoesNotBlockMainAndCancelledTileCannotPublish() async throws {
        let coordinator = ObservedLibraryReadCoordinator()
        let fixture = await StorageHarness.make(name: "native-grid-cancel", coordinator: coordinator)
        let h = try XCTUnwrap(fixture)
        let card = StorageFixture.cards(count: 1, libraryID: h.libraryID, startingAt: StorageFixture.fixedDate)[0]
        let hold = HeldLibraryDecode(); defer { hold.release() }
        let provider = LibraryPreviewFixture(hold: hold)
        let model = ThumbnailModel()
        let request = Task { await model.loadAndWait(card: card, source: .scoped(store: h.store, thumbnails: provider)) }
        let entered = await LibraryPerformanceSuite.waitUntil { hold.didEnter }
        XCTAssertTrue(entered)
        XCTAssertFalse(hold.onMain)
        XCTAssertFalse(hold.timedOut)
        XCTAssertEqual(coordinator.activeReads, 1)
        let mainStillRuns = UIView(frame: CGRect(x: 0, y: 0, width: 44, height: 44))
        XCTAssertEqual(mainStillRuns.frame.width, 44, "MainActor remains available during the held native read")
        request.cancel()
        await h.store.releaseRoot()
        XCTAssertFalse(hold.timedOut, "Storage/root command must run while decode remains genuinely held")
        XCTAssertEqual(coordinator.activeReads, 1)
        hold.release()
        await request.value
        if case .loaded = model.state { XCTFail("A cancelled/offscreen tile must not publish") }
        let readers = await h.store.activeReaderCount
        XCTAssertEqual(readers, 0)
        XCTAssertFalse(hold.timedOut)
        guard case .opened = await h.store.selectRoot(from: h.root) else { return XCTFail("Reconnect fixture") }
        let resumedProvider = LibraryPreviewFixture()
        await model.loadAndWait(card: card, source: .scoped(store: h.store, thumbnails: resumedProvider))
        guard case .loaded = model.state else { return XCTFail("Same tile identity can retry after task cancellation") }
        XCTAssertEqual(resumedProvider.count, 1)
    }
}
#endif
