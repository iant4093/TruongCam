#if canImport(UIKit) && canImport(XCTest) && !TC_TESTKIT_STANDALONE
import XCTest
import SwiftUI
import UIKit
import Synchronization
@testable import TruongCam

@MainActor private final class UIAudit43FlowState {
    var frames: [Int: CGRect] = [:]
    var container = CGRect.zero
}
private struct UIAudit43FlowFrames: PreferenceKey {
    static let defaultValue: [Int: CGRect] = [:]
    static func reduce(value: inout [Int: CGRect], nextValue: () -> [Int: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { _, next in next })
    }
}
private struct UIAudit43FlowProbe: View {
    let state: UIAudit43FlowState
    let accessibility: Bool
    var body: some View {
        FlowRow(spacing: 8) {
            ForEach(0..<3) { index in
                Group {
                    if accessibility {
                        Button(["Retry save", "Reconnect folder", "Dismiss"][index]) { }
                            .buttonStyle(.bordered).frame(minHeight: 44)
                    } else {
                        Color.red.frame(width: index == 2 ? 40 : 120, height: index == 1 ? 60 : 44)
                    }
                }.background { GeometryReader { proxy in
                    Color.clear.preference(key: UIAudit43FlowFrames.self, value: [index: proxy.frame(in: .named("flow-audit"))])
                } }
            }
        }
        .background { GeometryReader { proxy in
            Color.clear.onAppear { state.container = proxy.frame(in: .named("flow-audit")) }
                .onChange(of: proxy.size) { _, _ in state.container = proxy.frame(in: .named("flow-audit")) }
        } }
        // Compact fixture: 120 + 8 + 120 fits, but adding 8 + 40
        // exceeds 260. A 300-point proposal incorrectly kept all three on
        // one 296-point row and never exercised the short-last-row bug.
        .frame(width: accessibility ? 300 : 260, alignment: .leading)
        .coordinateSpace(name: "flow-audit")
        .onPreferenceChange(UIAudit43FlowFrames.self) { state.frames = $0 }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .environment(\.dynamicTypeSize, accessibility ? .accessibility3 : .large)
    }
}

private actor UIAudit43LoupeGate {
    private var samples: [LoupeSnapshot] = []
    private var continuations: [Int: CheckedContinuation<PreparedPreviewLoupe?, Never>] = [:]
    var count: Int { samples.count }
    func render(_ snapshot: LoupeSnapshot) async -> PreparedPreviewLoupe? {
        let index = samples.count; samples.append(snapshot)
        return await withCheckedContinuation { continuations[index] = $0 }
    }
    func release(_ index: Int) {
        guard let continuation = continuations.removeValue(forKey: index) else { return }
        let sample = samples[index]
        guard let image = sample.makeImage() else { continuation.resume(returning: nil); return }
        continuation.resume(returning: PreparedPreviewLoupe(image: image, capturedAt: sample.mappedAtUTC,
            configuration: sample.configurationGeneration, layout: sample.geometryGeneration,
            magnification: sample.magnification))
    }
}

/// Independent held-index port: no original read, shared index implementation,
/// library actor build or device is involved in these publication-order checks.
private actor UIAudit43HeldIndex: LibraryIndexing {
    private var firstWaiters: [Int: CheckedContinuation<LibraryPage, Error>] = [:]
    private var nextWaiters: [Int: CheckedContinuation<LibraryPage, Error>] = [:]
    private var sourceWaiters: [Int: CheckedContinuation<[LibrarySourceCard], Error>] = [:]
    private(set) var firstCount = 0
    private(set) var nextCursors: [LibraryCursor] = []
    private(set) var sequenceIDs: [SequenceID] = []
    private(set) var countReads = 0
    private var total = 0
    func reset(libraryID: LibraryID, generation: RootGeneration) async throws {}
    func ingest(_ receipts: [CommitReceipt]) async throws {}
    func upsert(scanned: [LibrarySourceCard]) async throws {}
    func updateSequences(_ summaries: [SequenceSummary]) async throws {}
    func markUnavailable(captureID: CaptureID, reason: String) async throws {}
    func firstPage(size: Int) async throws -> LibraryPage {
        let index = firstCount; firstCount += 1
        return try await withCheckedThrowingContinuation { firstWaiters[index] = $0 }
    }
    func page(after cursor: LibraryCursor, size: Int) async throws -> LibraryPage {
        let index = nextCursors.count; nextCursors.append(cursor)
        return try await withCheckedThrowingContinuation { nextWaiters[index] = $0 }
    }
    func detail(captureID: CaptureID) async throws -> LibrarySourceCard? { nil }
    func sources(inSequence sequenceID: SequenceID) async throws -> [LibrarySourceCard] {
        let index = sequenceIDs.count; sequenceIDs.append(sequenceID)
        return try await withCheckedThrowingContinuation { sourceWaiters[index] = $0 }
    }
    func dayGroupCounts() async throws -> [DayGroupCount] { [] }
    func totalCommittedOriginalCount() async throws -> Int { countReads += 1; return total }
    func releaseFirst(_ index: Int, page: LibraryPage, total: Int) {
        self.total = total; firstWaiters.removeValue(forKey: index)?.resume(returning: page)
    }
    func releaseNext(_ index: Int, page: LibraryPage) { nextWaiters.removeValue(forKey: index)?.resume(returning: page) }
    func releaseSources(_ index: Int, cards: [LibrarySourceCard]) { sourceWaiters.removeValue(forKey: index)?.resume(returning: cards) }
}

/// Metadata-only root-authority seam. It performs no file/storage operation;
/// every method outside the read identity is explicitly unavailable.
private final class UIAudit43RootStore: LibraryStoring, @unchecked Sendable {
    private let authority: Mutex<(LibraryRootState, URL?)>
    init(state: LibraryRootState, url: URL?) { authority = Mutex((state, url)) }
    var rootState: LibraryRootState { authority.withLock { $0.0 } }
    var grantedRootURL: URL? { authority.withLock { $0.1 } }
    var currentManifest: LibraryManifest? { nil }
    var selectedRootDescription: String? { grantedRootURL?.lastPathComponent }
    func set(state: LibraryRootState, url: URL?) { authority.withLock { $0 = (state, url) } }
    private func unsupported() -> CocoaError { CocoaError(.featureUnsupported) }
    func selectRoot(from grantedURL: URL, confirmedLocalDestination: Bool) async -> RootSelectionOutcome { .conflictingManifest(reason: "Metadata-only test seam") }
    func reconnectStoredRoot() async -> RootSelectionOutcome { .conflictingManifest(reason: "Metadata-only test seam") }
    func releaseRoot() async { set(state: .unselected, url: nil) }
    func reconcile(onProgress: (@Sendable (ScanProgress) -> Void)?) async throws -> ReconciledLibrary { throw unsupported() }
    func stageSource(bytes: Data, metadata: SourceCaptureMetadata) async throws -> StagedSourceHandle { throw unsupported() }
    func commit(handle: StagedSourceHandle) async throws -> CommitReceipt { throw unsupported() }
    func retry(transactionID: TransactionID) async throws -> CommitReceipt { throw unsupported() }
    func pendingOriginals() async -> [PendingOriginal] { [] }
    func prepareOriginalExport(sourceIDs: [CaptureID], includeSidecars: Bool) async throws -> ExportSession { throw unsupported() }
    func preparePendingOriginalExport(transactionIDs: [TransactionID], includeSidecars: Bool) async throws -> ExportSession { throw unsupported() }
    func discardExport(sessionID: UUID) async {}
    func clearAbandonedExports() async {}
    func reconciledSourceCards(after cursor: ScanCursor?, limit: Int) async throws -> ReconciledCardPage { throw unsupported() }
    func allReconciledSourceCards() async throws -> [LibrarySourceCard] { throw unsupported() }
    func browsableSourceCards(limit: Int) async throws -> [LibrarySourceCard] { throw unsupported() }
    func writeSequenceDocument(_ document: SequenceDocument) async throws { throw unsupported() }
    func readSequenceDocument(_ sequenceID: SequenceID) async throws -> SequenceDocument { throw unsupported() }
    func originalURL(for captureID: CaptureID, relativePath: String) -> URL? { nil }
    func withRootReadAccess<T: Sendable>(_ body: @Sendable (URL) throws -> T) async throws -> T { throw unsupported() }
    func readOriginal<T: Sendable>(relativePath: String, _ body: @escaping @Sendable (URL) throws -> T) async throws -> T { throw unsupported() }
    func openScopedRead() async throws -> ScopedReadLease { throw unsupported() }
    func closeScopedRead(_ lease: ScopedReadLease) {}
}

final class UIAudit43Tests: XCTestCase {
    @MainActor private func window() async throws -> UIWindow {
        for _ in 0..<100 {
            if UIApplication.shared.connectedScenes.contains(where: { $0 is UIWindowScene }) { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 402, height: 874)
        return window
    }
    @MainActor private func wait(_ predicate: () -> Bool) async throws {
        for _ in 0..<200 {
            if predicate() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Expected current owned UI result did not publish")
        throw CocoaError(.featureUnsupported)
    }
    private func sample(layout: UInt64 = 1, magnification: Double = 2, date: Date = Date()) -> LoupeSnapshot {
        var bytes: [UInt8] = []
        bytes.reserveCapacity(24)
        for index in 0..<6 {
            bytes.append(UInt8(index + 1))
            bytes.append(UInt8(index + 21))
            bytes.append(UInt8(index + 41))
            bytes.append(UInt8(index + 201))
        }
        return LoupeSnapshot(width: 3, height: 2, rgbaBytes: bytes,
            geometryGeneration: layout, configurationGeneration: ConfigurationGeneration(4),
            magnification: magnification, mappedAtUTC: date)
    }

    private func source(libraryID: LibraryID = LibraryID(), sequence: SequenceID? = nil) -> LibrarySourceCard {
        LibrarySourceCard(captureID: CaptureID(), libraryID: libraryID, relativeOriginalPath: "originals/test.dng",
            capturedAtUTC: Date(), capturedAtProvenance: .requestTimestamp, availability: .local,
            classification: .verifiedOriginal, rawDimensions: nil, byteCount: nil, sequenceID: sequence,
            sequenceIndex: sequence == nil ? nil : 0, sequenceKind: sequence == nil ? nil : .exposureBracket,
            isTruongCamCapture: true, modificationFingerprint: nil)
    }
    private func page(_ source: LibrarySourceCard, cursor: LibraryCursor? = nil) -> LibraryPage {
        LibraryPage(cards: [LibraryCard(id: source.id, kind: .single(source), capturedAtUTC: source.capturedAtUTC, representedOriginalCount: 1)],
            nextCursor: cursor, libraryGeneration: RootGeneration(1))
    }
    @MainActor private func waitAsync(_ predicate: () async -> Bool) async throws {
        for _ in 0..<200 {
            if await predicate() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("Held-index request did not enter")
        throw CocoaError(.featureUnsupported)
    }

    @MainActor func testLibraryPageLatestRequestOwnsCursorCountAndCancelledPublication() async throws {
        let index = UIAudit43HeldIndex()
        let library = LibraryViewModel(index: index, store: nil)
        let a = source(), b = source(), c = source(), d = source()
        let cursor = LibraryCursor(capturedAtUTC: b.capturedAtUTC, tieBreaker: b.id, libraryGeneration: RootGeneration(1))
        let old = Task { await library.loadFirstPage() }
        try await waitAsync { await index.firstCount == 1 }
        let current = Task { await library.loadFirstPage() }
        try await waitAsync { await index.firstCount == 2 }
        await index.releaseFirst(1, page: page(b, cursor: cursor), total: 22); await current.value
        XCTAssertEqual(library.orderedSources.map(\.captureID), [b.captureID]); XCTAssertEqual(library.individualOriginalCount, 22)
        XCTAssertTrue(library.hasMorePages); XCTAssertFalse(library.isLoading)
        await index.releaseFirst(0, page: page(a), total: 11); await old.value
        XCTAssertEqual(library.orderedSources.map(\.captureID), [b.captureID]); XCTAssertEqual(library.individualOriginalCount, 22)
        let countReads = await index.countReads
        XCTAssertEqual(countReads, 1, "Obsolete page cannot even issue a stale total query")

        let next = Task { await library.loadNextPage() }
        try await waitAsync { await index.nextCursors.count == 1 }
        let cursors = await index.nextCursors; XCTAssertEqual(cursors, [cursor])
        let replacement = Task { await library.loadFirstPage() }
        try await waitAsync { await index.firstCount == 3 }
        await index.releaseFirst(2, page: page(c), total: 33); await replacement.value
        await index.releaseNext(0, page: page(a)); await next.value
        XCTAssertEqual(library.orderedSources.map(\.captureID), [c.captureID]); XCTAssertEqual(library.loadedPageCount, 1)
        XCTAssertEqual(library.individualOriginalCount, 33); XCTAssertFalse(library.hasMorePages)

        let cancelled = Task { await library.loadFirstPage() }
        try await waitAsync { await index.firstCount == 4 }
        cancelled.cancel(); await index.releaseFirst(3, page: page(d), total: 44); await cancelled.value
        XCTAssertEqual(library.orderedSources.map(\.captureID), [c.captureID]); XCTAssertEqual(library.individualOriginalCount, 33)
        XCTAssertFalse(library.isLoading)
    }

    @MainActor func testSequenceCoalescesExactPendingReadAndRejectsReplacedAndCancelledResults() async throws {
        let index = UIAudit43HeldIndex()
        let model = LibraryViewModel(index: index, store: nil)
        let a = SequenceID(), b = SequenceID(), sourceA = source(sequence: a), sourceB = source(sequence: b)
        let first = Task { await model.selectSequence(a) }
        try await waitAsync { await index.sequenceIDs.count == 1 }
        let joined = Task { await model.selectSequence(a) }
        for _ in 0..<10 { await Task.yield() }
        let initialQueries = await index.sequenceIDs; XCTAssertEqual(initialQueries, [a])
        let second = Task { await model.selectSequence(b) }
        try await waitAsync { await index.sequenceIDs.count == 2 }
        await index.releaseSources(1, cards: [sourceB]); await second.value
        XCTAssertEqual(model.selectedSequenceID, b); XCTAssertEqual(model.sequenceCards.map(\.captureID), [sourceB.captureID])
        await index.releaseSources(0, cards: [sourceA]); await first.value; await joined.value
        XCTAssertEqual(model.selectedSequenceID, b); XCTAssertEqual(model.sequenceCards.map(\.captureID), [sourceB.captureID])

        let cancelled = Task { await model.selectSequence(a) }
        try await waitAsync { await index.sequenceIDs.count == 3 }
        cancelled.cancel(); await index.releaseSources(2, cards: [sourceA]); await cancelled.value
        XCTAssertTrue(model.sequenceCards.isEmpty, "A cancelled owner cannot publish a completed query")
        let pending = Task { await model.selectSequence(a) }
        try await waitAsync { await index.sequenceIDs.count == 4 }
        await model.selectSequence(nil)
        await index.releaseSources(3, cards: [sourceA]); await pending.value
        XCTAssertNil(model.selectedSequenceID); XCTAssertTrue(model.sequenceCards.isEmpty)
    }

    @MainActor func testOfflineMetadataIsRetainedButEqualReadOnlyStatesCannotCrossRootURLs() async throws {
        let id = LibraryID()
        let readOnly = LibraryRootState.readOnly(reason: "Fixture read-only", libraryID: id)
        let store = UIAudit43RootStore(state: readOnly, url: URL(fileURLWithPath: "/fixture-root-a"))
        let index = UIAudit43HeldIndex(), model = LibraryViewModel(index: index, store: store)
        let a = source(libraryID: id), b = source(libraryID: id)
        let initial = Task { await model.loadFirstPage() }
        try await waitAsync { await index.firstCount == 1 }
        await index.releaseFirst(0, page: page(a), total: 1); await initial.value
        let old = Task { await model.loadFirstPage() }
        try await waitAsync { await index.firstCount == 2 }
        store.set(state: .unavailable(reason: "Fixture grant loss", libraryID: readOnly.libraryID), url: nil)
        await model.loadFirstPage()
        let readsAfterLoss = await index.firstCount
        XCTAssertEqual(readsAfterLoss, 2, "Offline browsing uses retained metadata without a new index read")
        XCTAssertEqual(model.orderedSources.map(\.captureID), [a.captureID]); XCTAssertEqual(model.individualOriginalCount, 1)
        store.set(state: readOnly, url: URL(fileURLWithPath: "/fixture-root-b"))
        let replacement = Task { await model.loadFirstPage() }
        try await waitAsync { await index.firstCount == 3 }
        XCTAssertTrue(model.dayGroups.isEmpty, "Same read-only enum/library ID cannot identify another granted URL")
        await index.releaseFirst(2, page: page(b), total: 2); await replacement.value
        await index.releaseFirst(1, page: page(a), total: 1); await old.value
        XCTAssertEqual(model.orderedSources.map(\.captureID), [b.captureID]); XCTAssertEqual(model.individualOriginalCount, 2)
    }

    @MainActor func testHeldPageAndSequenceCannotRepopulateReleasedRoot() async throws {
        let fixture = await StorageHarness.make(name: "ui-audit43-root")
        let harness = try XCTUnwrap(fixture)
        let index = UIAudit43HeldIndex(), model = LibraryViewModel(index: index, store: harness.store)
        let card = source(libraryID: harness.libraryID), sequence = SequenceID()
        let pageRead = Task { await model.loadFirstPage() }
        let sourceRead = Task { await model.selectSequence(sequence) }
        try await waitAsync {
            let pages = await index.firstCount, sequences = await index.sequenceIDs.count
            return pages == 1 && sequences == 1
        }
        await harness.store.releaseRoot(); model.invalidateRoot()
        await index.releaseFirst(0, page: page(card), total: 100)
        await index.releaseSources(0, cards: [card])
        await pageRead.value; await sourceRead.value
        XCTAssertTrue(model.dayGroups.isEmpty); XCTAssertEqual(model.individualOriginalCount, 0)
        XCTAssertFalse(model.hasMorePages); XCTAssertFalse(model.isLoading)
        XCTAssertNil(model.selectedSequenceID); XCTAssertTrue(model.sequenceCards.isEmpty)
    }

    @MainActor func testWrappedRecoveryActionsRetainWidestRowAndFitAccessibilityProposal() async throws {
        let window = try await window()
        defer { window.isHidden = true }
        for accessibility in [false, true] {
            let state = UIAudit43FlowState()
            let host = UIHostingController(rootView: UIAudit43FlowProbe(state: state, accessibility: accessibility))
            window.rootViewController = host; window.makeKeyAndVisible(); host.view.layoutIfNeeded()
            try await wait { state.frames.count == 3 && state.container.height > 0 }
            let bounds = state.container.insetBy(dx: -0.5, dy: -0.5)
            for frame in state.frames.values { XCTAssertTrue(bounds.contains(frame), "Every recovery action stays inside the measured flow: \(frame) in \(bounds)") }
            if !accessibility {
                XCTAssertEqual(state.container.width, 248, accuracy: 0.5)
                XCTAssertEqual(state.container.height, 112, accuracy: 0.5)
                XCTAssertEqual(state.frames[2]?.minY ?? -1, 68, accuracy: 0.5)
                XCTAssertEqual(state.frames[0]?.width ?? -1, 120, accuracy: 0.5)
                XCTAssertEqual(state.frames[1]?.width ?? -1, 120, accuracy: 0.5)
                XCTAssertEqual(state.frames[2]?.width ?? -1, 40, accuracy: 0.5)
            } else {
                XCTAssertGreaterThan(state.frames.values.map(\.minY).max() ?? 0, 0,
                    "Accessibility-size recovery labels must actually exercise wrapping")
                for frame in state.frames.values { XCTAssertGreaterThanOrEqual(frame.height, 44) }
            }
        }
    }

    func testPackedLoupeTransformPreservesEveryChannelForAllOrientationsAndMirrors() {
        let input = sample()
        for angle in [0, 90, 180, 270, -90, 450, 45] {
            for mirrored in [false, true] {
                let actual = LoupeRenderer.orient(input, rotationDegrees: angle, mirrored: mirrored)
                let reference = (0..<4).map { channel in
                    PreviewMaskOrientation.rotate(stride(from: channel, to: input.rgbaBytes.count, by: 4).map { input.rgbaBytes[$0] },
                        width: input.width, height: input.height, degrees: angle, mirrored: mirrored)
                }
                let expected = (0..<(reference[0].width * reference[0].height)).flatMap { index in (0..<4).map { reference[$0].bytes[index] } }
                XCTAssertEqual(actual.rgbaBytes, expected, "Every channel survives angle \(angle), mirror \(mirrored)")
                XCTAssertEqual(actual.width, reference[0].width); XCTAssertEqual(actual.height, reference[0].height)
                XCTAssertEqual(actual.mappedAtUTC, input.mappedAtUTC)
                XCTAssertEqual(actual.configurationGeneration, input.configurationGeneration)
                XCTAssertEqual(actual.geometryGeneration, input.geometryGeneration)
            }
        }
        let clockwise = LoupeRenderer.orient(input, rotationDegrees: 90, mirrored: false)
        XCTAssertEqual(stride(from: 0, to: clockwise.rgbaBytes.count, by: 4).map { clockwise.rgbaBytes[$0] }, [4, 1, 5, 2, 6, 3])
    }

    func testMalformedPreviewBufferDimensionsFailClosedBeforeAllocation() {
        for size in [PixelDimensions(width: Int.max, height: Int.max),
                     PixelDimensions(width: Int.min, height: Int.min),
                     PixelDimensions(width: 0, height: 64), PixelDimensions(width: -1, height: -1)] {
            let malformed = LuminanceSample(width: size.width, height: size.height, luma: [], range: .full,
                configurationGeneration: ConfigurationGeneration(4), geometryGeneration: 1, capturedAtUTC: Date())
            XCTAssertEqual(PreviewAnalysisMath.histogram(from: malformed).sampleCount, 0)
            XCTAssertTrue(PreviewAnalysisMath.peakingMask(from: malformed, threshold: 0.1).isEmpty)
            XCTAssertTrue(PreviewAnalysisMath.zebraMask(from: malformed, threshold: 0.95).isEmpty)
        }
    }

    @MainActor func testLoupeBitmapConversionUsesSnapshotWorkerAndRejectsInvalidBuffers() async throws {
        let threads = Mutex<[Bool]>([])
        let renderer = PreviewMaskImageRenderer(makeLoupeImage: { snapshot in
            threads.withLock { $0.append(Thread.isMainThread) }
            return snapshot.makeImage()
        })
        let input = sample()
        let prepared = await renderer.render(input)
        XCTAssertNotNil(prepared); XCTAssertEqual(threads.withLock { $0 }, [false])
        XCTAssertEqual(prepared?.capturedAt, input.mappedAtUTC)
        let invalid = LoupeSnapshot(width: LoupeRenderer.maxColorOutputLongEdge + 1, height: 1, rgbaBytes: [0], geometryGeneration: 1,
            configurationGeneration: ConfigurationGeneration(4), magnification: 2, mappedAtUTC: Date())
        let rejected = await renderer.render(invalid)
        XCTAssertNil(rejected); XCTAssertEqual(threads.withLock { $0.count }, 1, "Reject before native image creation")
        let overflow = LoupeSnapshot(width: Int.max, height: Int.max, rgbaBytes: [], geometryGeneration: 1,
            configurationGeneration: ConfigurationGeneration(4), magnification: 2, mappedAtUTC: Date())
        XCTAssertNil(overflow.makeImage(), "The display helper rejects impossible dimensions before multiplying")
        XCTAssertNil(invalid.makeImage(), "The display helper shares the renderer's bounded-buffer contract")
    }

    @MainActor func testLoupeCoalescesLatestSampleRejectsOldGeometryAndExpiresSourceTime() async throws {
        let clock = Date()
        let gate = UIAudit43LoupeGate()
        let presentation = PreviewLoupePresentation(render: { await gate.render($0) }, now: { clock })
        presentation.submit(sample(layout: 1, date: clock))
        for _ in 0..<100 { if await gate.count == 1 { break }; try await Task.sleep(for: .milliseconds(5)) }
        presentation.submit(sample(layout: 2, date: clock))
        presentation.submit(sample(layout: 3, magnification: 4, date: clock))
        await gate.release(0)
        for _ in 0..<100 { if await gate.count == 2 { break }; try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertNil(presentation.prepared, "Old geometry cannot paint over the newest requested layout")
        let count = await gate.count
        XCTAssertEqual(count, 2, "One in flight plus the latest sample, without an intermediate decode queue")
        await gate.release(1)
        try await wait { presentation.prepared?.layout == 3 }
        XCTAssertEqual(presentation.prepared?.magnification, 4)
        presentation.invalidate(); XCTAssertNil(presentation.prepared)

        let stale = PreviewLoupePresentation(render: { await PreviewMaskImageRenderer.shared.render($0) }, now: { clock })
        stale.submit(sample(date: clock.addingTimeInterval(-1)))
        try await Task.sleep(for: .milliseconds(40))
        XCTAssertNil(stale.prepared, "Preparing a bitmap must not refresh the original source timestamp")
        stale.invalidate()

        let cancelledGate = UIAudit43LoupeGate()
        let cancelled = PreviewLoupePresentation(render: { await cancelledGate.render($0) }, now: { clock })
        cancelled.submit(sample(date: clock))
        for _ in 0..<100 { if await cancelledGate.count == 1 { break }; try await Task.sleep(for: .milliseconds(5)) }
        cancelled.invalidate(); await cancelledGate.release(0)
        try await Task.sleep(for: .milliseconds(20))
        XCTAssertNil(cancelled.prepared, "Disappearing/invalidation cannot resurrect a late bitmap")
    }
}
#endif
