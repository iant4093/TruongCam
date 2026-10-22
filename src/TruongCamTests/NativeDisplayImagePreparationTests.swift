#if canImport(UIKit) && canImport(XCTest) && !TC_TESTKIT_STANDALONE
import CoreGraphics
import Foundation
import Synchronization
import UIKit
import XCTest
@testable import TruongCam

/// Holds only the conversion boundary, after the real model's scoped read has
/// returned. Each admitted invocation still executes the shipping conversion.
private final class HeldDisplayImageRenderer: Sendable {
    let first: HeldLibraryDecode
    let second: HeldLibraryDecode?
    private let invocations = Mutex(0)
    var count: Int { invocations.withLock { $0 } }
    init(first: HeldLibraryDecode, second: HeldLibraryDecode? = nil) {
        self.first = first
        self.second = second
    }
    func render(_ bytes: [UInt8], _ width: Int, _ height: Int) -> CGImage? {
        let invocation = invocations.withLock { $0 += 1; return $0 }
        if invocation == 1 { first.hold() }
        if invocation == 2 { second?.hold() }
        return CGImage.rgbaDisplayImage(bytes: bytes, width: width, height: height)
    }
}

final class NativeDisplayImagePreparationTests: XCTestCase {
    @MainActor func testActualConversionRunsOnSerialWorkerAndSkipsCancelledQueuedCopy() async throws {
        let hold = HeldLibraryDecode(); defer { hold.release() }
        let renderer = HeldDisplayImageRenderer(first: hold)
        let owner = BlockingIOOwner(label: "test.display-image.serial")
        let preparation = DisplayImagePreparation(owner: owner, makeImage: renderer.render)
        let bytes: [UInt8] = [10, 20, 30, 255, 40, 50, 60, 255]
        let input = ThumbnailOutcome.image(rgbaBytes: bytes, width: 2, height: 1, pixelFingerprint: "pixels")
        let first = Task { try await preparation.prepare(input) }
        let entered = await LibraryPerformanceSuite.waitUntil { hold.didEnter }
        XCTAssertTrue(entered)
        XCTAssertFalse(hold.onMain)
        let obsolete = Task { try await preparation.prepare(input) }
        let queued = await LibraryPerformanceSuite.waitUntil { owner.queuedOperationCount == 1 }
        XCTAssertTrue(queued)
        obsolete.cancel()
        let mainView = UIView(frame: CGRect(x: 0, y: 0, width: 44, height: 44))
        XCTAssertEqual(mainView.bounds.width, 44, "MainActor remains callable while actual conversion is held")
        XCTAssertEqual(renderer.count, 1, "No concurrent bitmap allocation")
        hold.release()
        guard case .image(let image) = try await first.value else { return XCTFail("Actual CGImage conversion") }
        XCTAssertEqual(image.width, 2)
        XCTAssertEqual(image.height, 1)
        let nativeData = try XCTUnwrap(image.dataProvider?.data)
        XCTAssertEqual(Array(UnsafeBufferPointer(start: CFDataGetBytePtr(nativeData), count: CFDataGetLength(nativeData))), bytes)
        do { _ = try await obsolete.value; XCTFail("Queued cancellation must be reported") }
        catch is CancellationError { /* expected */ }
        XCTAssertEqual(renderer.count, 1, "Cancelled queued requests never copy RGBA")
        XCTAssertFalse(hold.timedOut)
        let malformed = try await preparation.prepare(.image(rgbaBytes: [0], width: Int.max, height: Int.max, pixelFingerprint: "bad"))
        if case .unavailable = malformed {} else { XCTFail("Unbounded/malformed image must be refused") }
    }

    @MainActor func testObsoleteGridConversionCannotPublishOrClearNewViewerTask() async throws {
        let fixture = await StorageHarness.make(name: "native-display-replacement")
        let h = try XCTUnwrap(fixture)
        let cards = StorageFixture.cards(count: 2, libraryID: h.libraryID, startingAt: StorageFixture.fixedDate)
        let firstHold = HeldLibraryDecode(), secondHold = HeldLibraryDecode()
        defer { firstHold.release(); secondHold.release() }
        let renderer = HeldDisplayImageRenderer(first: firstHold, second: secondHold)
        let preparation = DisplayImagePreparation(makeImage: renderer.render)
        let model = ThumbnailModel(imagePreparation: preparation)
        let provider = LibraryPreviewFixture()
        let source = GalleryThumbnailSource.scoped(store: h.store, thumbnails: provider)
        let old = Task { await model.loadAndWait(card: cards[0], source: source, sourceRevision: 1, rootState: h.store.rootState) }
        let firstEntered = await LibraryPerformanceSuite.waitUntil { firstHold.didEnter }
        XCTAssertTrue(firstEntered)
        let readersDuringConversion = await h.store.activeReaderCount
        XCTAssertEqual(readersDuringConversion, 0, "Conversion owns materialized bytes, not an escaped accessor")
        let replacement = Task { await model.loadViewerAndWait(card: cards[1], source: source, sourceRevision: 2, rootState: h.store.rootState) }
        let replacementRead = await LibraryPerformanceSuite.waitUntil { provider.count == 2 }
        XCTAssertTrue(replacementRead)
        firstHold.release()
        let secondEntered = await LibraryPerformanceSuite.waitUntil { secondHold.didEnter }
        XCTAssertTrue(secondEntered)
        await old.value
        guard case .loading = model.state else { return XCTFail("Old grid pixels cannot become the new viewer") }
        let sameCurrent = Task { await model.loadViewerAndWait(card: cards[1], source: source, sourceRevision: 2, rootState: h.store.rootState) }
        for _ in 0..<20 { await Task.yield() }
        XCTAssertEqual(provider.count, 2, "Old task completion cannot clear or duplicate the in-flight current viewer task")
        secondHold.release()
        await replacement.value
        await sameCurrent.value
        XCTAssertEqual(model.loadedCaptureID, cards[1].captureID)
        guard case .loaded(let image) = model.state else { return XCTFail("Current viewer must publish") }
        let data = try XCTUnwrap(image.dataProvider?.data)
        XCTAssertEqual(CFDataGetBytePtr(data)?.pointee, 2, "Published pixels come from the replacement request")
        XCTAssertFalse(firstHold.onMain)
        XCTAssertFalse(secondHold.onMain)
        XCTAssertFalse(firstHold.timedOut)
        XCTAssertFalse(secondHold.timedOut)
    }

    @MainActor func testRootReleaseDuringConversionRejectsOldPixelsAndAllowsReconnect() async throws {
        let fixture = await StorageHarness.make(name: "native-display-root-release")
        let h = try XCTUnwrap(fixture)
        let card = StorageFixture.cards(count: 1, libraryID: h.libraryID, startingAt: StorageFixture.fixedDate)[0]
        let hold = HeldLibraryDecode(); defer { hold.release() }
        let renderer = HeldDisplayImageRenderer(first: hold)
        let model = ThumbnailModel(imagePreparation: DisplayImagePreparation(makeImage: renderer.render))
        let provider = LibraryPreviewFixture()
        let source = GalleryThumbnailSource.scoped(store: h.store, thumbnails: provider)
        let old = Task { await model.loadViewerAndWait(card: card, source: source, sourceRevision: 1, rootState: h.store.rootState) }
        let entered = await LibraryPerformanceSuite.waitUntil { hold.didEnter }
        XCTAssertTrue(entered)
        await h.store.releaseRoot()
        hold.release()
        await old.value
        guard case .unavailable(let reason) = model.state else { return XCTFail("Root changed after read but before conversion completion") }
        XCTAssertTrue(reason.contains("folder changed"))
        guard case .opened = await h.store.selectRoot(from: h.root) else { return XCTFail("Reconnect fixture") }
        await model.loadViewerAndWait(card: card, source: source, sourceRevision: 2, rootState: h.store.rootState)
        guard case .loaded = model.state else { return XCTFail("Reconnected current root can load") }
        XCTAssertEqual(provider.count, 2)
        let readers = await h.store.activeReaderCount
        XCTAssertEqual(readers, 0)
        XCTAssertFalse(hold.timedOut)
    }
}
#endif
