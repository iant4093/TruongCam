#if canImport(UIKit) && canImport(XCTest) && !TC_TESTKIT_STANDALONE
import CoreGraphics
import Foundation
import Synchronization
import SwiftUI
import UIKit
import XCTest
@testable import TruongCam

private final class ThirdUIHeldRenderer: Sendable {
    let hold: HeldLibraryDecode
    private let calls = Mutex(0)
    var count: Int { calls.withLock { $0 } }
    init(hold: HeldLibraryDecode) { self.hold = hold }
    func render(_ bytes: [UInt8], _ width: Int, _ height: Int) -> CGImage? {
        let position = calls.withLock { $0 += 1; return $0 }
        if position == 1 { hold.hold() }
        return CGImage.rgbaDisplayImage(bytes: bytes, width: width, height: height)
    }
}

private actor ThirdUISelectionIndex: LibraryIndexing {
    let pageValue: LibraryPage
    private var batches: [[LibrarySourceCard]]
    private(set) var sourceReads = 0
    init(page: LibraryPage, batches: [[LibrarySourceCard]]) { pageValue = page; self.batches = batches }
    func reset(libraryID: LibraryID, generation: RootGeneration) async throws {}
    func ingest(_ receipts: [CommitReceipt]) async throws {}
    func upsert(scanned: [LibrarySourceCard]) async throws {}
    func updateSequences(_ summaries: [SequenceSummary]) async throws {}
    func markUnavailable(captureID: CaptureID, reason: String) async throws {}
    func firstPage(size: Int) async throws -> LibraryPage { pageValue }
    func page(after cursor: LibraryCursor, size: Int) async throws -> LibraryPage { pageValue }
    func detail(captureID: CaptureID) async throws -> LibrarySourceCard? { nil }
    func sources(inSequence sequenceID: SequenceID) async throws -> [LibrarySourceCard] {
        sourceReads += 1
        guard !batches.isEmpty else { throw CocoaError(.featureUnsupported) }
        return batches.removeFirst()
    }
    func dayGroupCounts() async throws -> [DayGroupCount] { [] }
    func totalCommittedOriginalCount() async throws -> Int { 2 }
}

final class ThirdUIReviewNativeTests: XCTestCase {
    @MainActor private static func window() async throws -> UIWindow {
        for _ in 0..<100 {
            if UIApplication.shared.connectedScenes.contains(where: { $0 is UIWindowScene }) { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 402, height: 874)
        return window
    }

    @MainActor func testActualIndividualSelectionRejectsMixedForeignOrWrongSequenceRowsAndKeepsCurrentRows() async throws {
        let fixture = await StorageHarness.make(name: "third-ui-selection-authority")
        let h = try XCTUnwrap(fixture), sequence = SequenceID()
        func member(libraryID: LibraryID, sequenceID: SequenceID?) -> LibrarySourceCard {
            LibrarySourceCard(captureID: CaptureID(), libraryID: libraryID, relativeOriginalPath: "originals/fixture.dng",
                capturedAtUTC: StorageFixture.fixedDate, capturedAtProvenance: .requestTimestamp, availability: .local,
                classification: .verifiedOriginal, rawDimensions: nil, byteCount: nil, sequenceID: sequenceID,
                sequenceIndex: sequenceID == nil ? nil : 0, sequenceKind: sequenceID == nil ? nil : .exposureBracket,
                isTruongCamCapture: true, modificationFingerprint: nil)
        }
        let current = member(libraryID: h.libraryID, sequenceID: sequence)
        let summary = SequenceSummary(sequenceID: sequence, kind: .exposureBracket, plannedCount: 2,
            committedCount: 2, missingIndices: [], failedIndices: [], skippedDeadlineCount: 0,
            status: .complete, startedAtUTC: StorageFixture.fixedDate)
        let tile = LibraryCard(id: sequence.description, kind: .sequenceCover(summary, cover: current),
            capturedAtUTC: StorageFixture.fixedDate, representedOriginalCount: 2)
        let invalid = [member(libraryID: LibraryID(), sequenceID: sequence),
                       member(libraryID: h.libraryID, sequenceID: SequenceID()),
                       member(libraryID: h.libraryID, sequenceID: nil)]
        let index = ThirdUISelectionIndex(page: LibraryPage(cards: [tile], nextCursor: nil, libraryGeneration: h.generation),
            batches: invalid.map { [current, $0] } + [[current]])
        let app = AppEnvironment(); app.attach(store: h.store, index: index)
        await app.library?.loadFirstPage()
        let window = try await Self.window()
        defer { window.isHidden = true; window.rootViewController = nil }
        func descendants(_ view: UIView) -> [UIView] { [view] + view.subviews.flatMap(descendants) }
        for position in 0..<4 {
            window.rootViewController = UIHostingController(rootView: LibraryScreen(selecting: true).environment(app))
            window.makeKeyAndVisible()
            for _ in 0..<200 {
                if await index.sourceReads >= position + 1 { break }
                try await Task.sleep(for: .milliseconds(5))
            }
            let reads = await index.sourceReads
            XCTAssertEqual(reads, position + 1)
            try await Task.sleep(for: .milliseconds(100))
            window.rootViewController?.view.layoutIfNeeded()
            let candidate = descendants(window).compactMap { $0 as? GallerySelectionGestureView }.first
            if position < 3 {
                if let sweep = candidate {
                    sweep.begin(at: CGPoint(x: sweep.bounds.width / 6, y: sweep.bounds.width / 6))
                    XCTAssertNil(sweep.sweep, "The actual selection grid must not contain any mixed-authority source rows")
                    sweep.finish(cancelled: true)
                }
            } else {
                let sweep = try XCTUnwrap(candidate)
                sweep.begin(at: CGPoint(x: sweep.bounds.width / 6, y: sweep.bounds.width / 6))
                XCTAssertNotNil(sweep.sweep, "Current sequence rows still create actual selectable tile frames")
                sweep.finish(cancelled: true)
            }
        }
    }

    @MainActor func testInitialViewerDisappearanceCancelsItsQueuedDisplayWork() async throws {
        let fixture = await StorageHarness.make(name: "third-ui-initial-viewer")
        let h = try XCTUnwrap(fixture)
        let card = try XCTUnwrap(StorageFixture.cards(count: 1, libraryID: h.libraryID,
            startingAt: StorageFixture.fixedDate).first)
        let hold = HeldLibraryDecode(); defer { hold.release() }
        let renderer = ThirdUIHeldRenderer(hold: hold)
        let owner = BlockingIOOwner(label: "test.third-ui-initial-viewer")
        let preparation = DisplayImagePreparation(owner: owner, makeImage: renderer.render)
        let blocker = Task { try await preparation.prepare(.image(rgbaBytes: [1, 2, 3, 255],
            width: 1, height: 1, pixelFingerprint: "initial-viewer-blocker")) }
        let entered = await LibraryPerformanceSuite.waitUntil { hold.didEnter }
        XCTAssertTrue(entered)
        let provider = LibraryPreviewFixture(), app = AppEnvironment()
        app.attachThumbnails(store: h.store, thumbnails: provider)
        let model = ThumbnailModel(imagePreparation: preparation)
        for _ in 0..<100 {
            if UIApplication.shared.connectedScenes.contains(where: { $0 is UIWindowScene }) { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 402, height: 874)
        let host = UIHostingController(rootView: AnyView(SourceDetailView(card: card, orderedSources: [card],
            viewerModel: model).environment(app)))
        window.rootViewController = host; window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil }
        let queued = await LibraryPerformanceSuite.waitUntil { owner.queuedOperationCount == 1 }
        XCTAssertTrue(queued, "The shipping initial viewer task queues display conversion")
        XCTAssertEqual(provider.count, 1)
        host.rootView = AnyView(Color.black)
        host.view.setNeedsLayout(); host.view.layoutIfNeeded()
        // Let SwiftUI finish removing the old identity and cancelling its task
        // while the independent renderer still keeps the queue genuinely held.
        try await Task.sleep(for: .milliseconds(100))
        hold.release(); _ = try await blocker.value
        let drained = await LibraryPerformanceSuite.waitUntil { owner.queuedOperationCount == 0 }
        XCTAssertTrue(drained)
        XCTAssertEqual(renderer.count, 1, "Leaving the actual viewer skips its queued conversion")
        if case .loaded = model.state { XCTFail("An offscreen initial viewer cannot publish late pixels") }
        XCTAssertFalse(hold.timedOut)
    }

    @MainActor func testCancelledViewerSkipsItsQueuedConversionAndCanRetrySameRequest() async throws {
        let fixture = await StorageHarness.make(name: "third-ui-viewer-conversion")
        let h = try XCTUnwrap(fixture)
        let card = try XCTUnwrap(StorageFixture.cards(count: 1, libraryID: h.libraryID,
            startingAt: StorageFixture.fixedDate).first)
        let hold = HeldLibraryDecode(); defer { hold.release() }
        let renderer = ThirdUIHeldRenderer(hold: hold)
        let owner = BlockingIOOwner(label: "test.third-ui-viewer-conversion")
        let preparation = DisplayImagePreparation(owner: owner, makeImage: renderer.render)
        let blocker = Task { try await preparation.prepare(.image(rgbaBytes: [1, 2, 3, 255],
            width: 1, height: 1, pixelFingerprint: "owned-blocker")) }
        let entered = await LibraryPerformanceSuite.waitUntil { hold.didEnter }
        XCTAssertTrue(entered)
        let provider = LibraryPreviewFixture()
        let source = GalleryThumbnailSource.scoped(store: h.store, thumbnails: provider)
        let model = ThumbnailModel(imagePreparation: preparation)
        let obsolete = Task { await model.loadViewerAndWait(card: card, source: source,
            sourceRevision: 1, rootState: h.store.rootState) }
        let queued = await LibraryPerformanceSuite.waitUntil { owner.queuedOperationCount == 1 }
        XCTAssertTrue(queued, "The viewer has returned from its real scoped read and queued bitmap preparation")
        XCTAssertEqual(provider.count, 1)
        let activeReaders = await h.store.activeReaderCount
        XCTAssertEqual(activeReaders, 0, "Materialized display bytes do not retain a provider accessor")
        obsolete.cancel()
        hold.release()
        _ = try await blocker.value
        await obsolete.value
        XCTAssertEqual(renderer.count, 1, "Cancelled viewer must never enter the queued RGBA conversion")
        if case .loaded = model.state { XCTFail("A cancelled viewer cannot publish pixels") }
        await model.loadViewerAndWait(card: card, source: source, sourceRevision: 1, rootState: h.store.rootState)
        guard case .loaded = model.state else { return XCTFail("A new current owner can retry the identical viewer request") }
        XCTAssertEqual(renderer.count, 2)
        XCTAssertEqual(provider.count, 2)
        XCTAssertFalse(hold.onMain)
        XCTAssertFalse(hold.timedOut)
    }

    @MainActor func testCancelledViewerDrainsAnAlreadyRunningScopedReadWithoutPublishing() async throws {
        let coordinator = ObservedLibraryReadCoordinator()
        let fixture = await StorageHarness.make(name: "third-ui-viewer-scope", coordinator: coordinator)
        let h = try XCTUnwrap(fixture)
        let card = try XCTUnwrap(StorageFixture.cards(count: 1, libraryID: h.libraryID,
            startingAt: StorageFixture.fixedDate).first)
        let hold = HeldLibraryDecode(); defer { hold.release() }
        let source = GalleryThumbnailSource.scoped(store: h.store, thumbnails: LibraryPreviewFixture(hold: hold))
        let model = ThumbnailModel()
        let request = Task { await model.loadViewerAndWait(card: card, source: source) }
        let entered = await LibraryPerformanceSuite.waitUntil { hold.didEnter }
        XCTAssertTrue(entered)
        XCTAssertEqual(coordinator.activeReads, 1)
        request.cancel()
        await h.store.releaseRoot()
        XCTAssertEqual(coordinator.activeReads, 1, "Cancellation/release must keep an admitted accessor scoped until its body returns")
        hold.release(); await request.value
        if case .loaded = model.state { XCTFail("A cancelled or released viewer cannot publish the drained read") }
        let remainingReaders = await h.store.activeReaderCount
        XCTAssertEqual(remainingReaders, 0)
        XCTAssertFalse(hold.onMain)
        XCTAssertFalse(hold.timedOut)
    }
}
#endif
