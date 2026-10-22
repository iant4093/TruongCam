#if canImport(UIKit) && canImport(XCTest) && !TC_TESTKIT_STANDALONE
import Foundation
import XCTest
@testable import TruongCam

private actor ThirdHeldExportPort: ExportPreparing {
    enum Outcome: Equatable, Sendable { case ready, partial, empty, failure }
    let firstSession = UUID()
    private var outcome: Outcome
    private let holdFirst: Bool
    private var waiter: CheckedContinuation<Void, Never>?
    private var released = false
    private(set) var requests: [[CaptureID]] = []
    private(set) var discarded: [UUID] = []
    init(_ outcome: Outcome = .ready, holdFirst: Bool = true) {
        self.outcome = outcome; self.holdFirst = holdFirst
    }
    func release() { released = true; waiter?.resume(); waiter = nil }
    func setOutcome(_ value: Outcome) { outcome = value }
    func prepareOriginalExport(sourceIDs: [CaptureID], includeSidecars: Bool) async throws -> ExportSession {
        let ordinal = requests.count
        requests.append(sourceIDs)
        let selected = outcome
        if ordinal == 0 && holdFirst && !released { await withCheckedContinuation { waiter = $0 } }
        if selected == .failure { throw CocoaError(.fileReadNoPermission) }
        return ExportSession(sessionID: ordinal == 0 ? firstSession : UUID(),
            directoryRelativePath: "test-only/third-export",
            fileURLs: selected == .empty ? [] : [URL(fileURLWithPath: "/test-only/third-export/original.dng")],
            includedSidecars: includeSidecars,
            missingItems: selected == .partial || selected == .empty ? ["missing test original"] : [],
            totalByteCount: selected == .empty ? 0 : 4, preparedAtUTC: StorageFixture.fixedDate)
    }
    func preparePendingOriginalExport(transactionIDs: [TransactionID], includeSidecars: Bool) async throws -> ExportSession {
        try await prepareOriginalExport(sourceIDs: [], includeSidecars: includeSidecars)
    }
    func discardExport(sessionID: UUID) { discarded.append(sessionID) }
    func clearAbandonedExports() {}
}

/// Real current-generation metadata, with one deliberately held sequence read.
private actor ThirdHeldSequenceIndex: LibraryIndexing {
    let base = InMemoryLibraryIndex()
    private(set) var entered = false
    private var released = false
    private var waiter: CheckedContinuation<Void, Never>?
    func release() { released = true; waiter?.resume(); waiter = nil }
    func reset(libraryID: LibraryID, generation: RootGeneration) async throws { try await base.reset(libraryID: libraryID, generation: generation) }
    func ingest(_ receipts: [CommitReceipt]) async throws { try await base.ingest(receipts) }
    func upsert(scanned: [LibrarySourceCard]) async throws { try await base.upsert(scanned: scanned) }
    func updateSequences(_ summaries: [SequenceSummary]) async throws { try await base.updateSequences(summaries) }
    func markUnavailable(captureID: CaptureID, reason: String) async throws { try await base.markUnavailable(captureID: captureID, reason: reason) }
    func firstPage(size: Int) async throws -> LibraryPage { try await base.firstPage(size: size) }
    func page(after cursor: LibraryCursor, size: Int) async throws -> LibraryPage { try await base.page(after: cursor, size: size) }
    func detail(captureID: CaptureID) async throws -> LibrarySourceCard? { try await base.detail(captureID: captureID) }
    func sources(inSequence sequenceID: SequenceID) async throws -> [LibrarySourceCard] {
        entered = true
        if !released { await withCheckedContinuation { waiter = $0 } }
        return try await base.sources(inSequence: sequenceID)
    }
    func dayGroupCounts() async throws -> [DayGroupCount] { try await base.dayGroupCounts() }
    func totalCommittedOriginalCount() async throws -> Int { try await base.totalCommittedOriginalCount() }
}

final class ThirdExportReviewNativeTests: XCTestCase {
    @MainActor private static func wait(_ condition: () async -> Bool) async throws {
        for _ in 0..<400 {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("The held export boundary did not reach its expected state")
        throw CocoaError(.featureUnsupported)
    }
    private static func card(libraryID: LibraryID, sequenceID: SequenceID) -> LibrarySourceCard {
        LibrarySourceCard(captureID: CaptureID(), libraryID: libraryID, relativeOriginalPath: "originals/test.dng",
            capturedAtUTC: StorageFixture.fixedDate, capturedAtProvenance: .requestTimestamp, availability: .local,
            classification: .verifiedOriginal, rawDimensions: nil, byteCount: nil, sequenceID: sequenceID,
            sequenceIndex: 0, sequenceKind: .interval, isTruongCamCapture: true, modificationFingerprint: nil)
    }
    private static func replaceRoot(_ h: StorageHarness) async throws {
        let b = h.root.deletingLastPathComponent().appendingPathComponent("different-export-root")
        try h.memory.createDirectory(at: b, withIntermediateDirectories: true)
        guard case .initialized = await h.store.selectRoot(from: b, confirmedLocalDestination: true) else {
            throw CocoaError(.fileWriteUnknown)
        }
    }

    @MainActor func testEveryCommittedExportRouteRejectsOldRootSuccessAbsenceAndFailure() async throws {
        for route in ["single", "selected", "sequence"] {
            for outcome in [ThirdHeldExportPort.Outcome.ready, .empty, .failure] {
                let fixture = await StorageHarness.make(name: "third-export-\(route)-\(outcome)")
                let h = try XCTUnwrap(fixture), sequence = SequenceID()
                let card = Self.card(libraryID: h.libraryID, sequenceID: sequence)
                let index = InMemoryLibraryIndex()
                try await index.reset(libraryID: h.libraryID, generation: h.generation)
                try await index.upsert(scanned: [card])
                let app = AppEnvironment(); app.attach(store: h.store, index: index)
                let port = ThirdHeldExportPort(outcome), presenter = ExportPresenter(store: port)
                app.exportPresenter = presenter
                switch route {
                case "single": app.exportCommittedOriginal(card.captureID, surface: .viewer)
                case "selected": app.exportSelectedOriginals([card])
                default: app.exportSequenceOriginals(sequence)
                }
                try await Self.wait { await port.requests.count == 1 }
                try await Self.replaceRoot(h)
                presenter.reportNotice("The current folder owns this notice")
                await port.release()
                try await Self.wait { !presenter.isPreparingExport }
                if outcome == .ready { try await Self.wait { await port.discarded == [port.firstSession] } }
                XCTAssertNil(presenter.presented, route)
                XCTAssertNil(app.pendingPartialExport, route)
                XCTAssertNil(presenter.lastFailure, "Old-root failures/absences must not replace the current folder's result")
                XCTAssertEqual(presenter.lastNotice, "The current folder owns this notice")
                XCTAssertFalse(presenter.hasActiveExport)
                await port.setOutcome(.ready)
                app.exportCommittedOriginal(CaptureID(), surface: .viewer)
                try await Self.wait { presenter.presented != nil }
                XCTAssertTrue(presenter.ownsPresentation(.viewer), "A fresh current-root command still works")
                let current = try XCTUnwrap(presenter.presented)
                await presenter.finished(sessionID: current.session.sessionID)
            }
        }
    }

    @MainActor func testSupersededSequenceLookupDoesNotStartAnObsoleteExport() async throws {
        let fixture = await StorageHarness.make(name: "third-export-stale-sequence")
        let h = try XCTUnwrap(fixture), sequence = SequenceID()
        let card = Self.card(libraryID: h.libraryID, sequenceID: sequence)
        let index = ThirdHeldSequenceIndex()
        try await index.reset(libraryID: h.libraryID, generation: h.generation)
        try await index.upsert(scanned: [card])
        let app = AppEnvironment(); app.attach(store: h.store, index: index)
        let port = ThirdHeldExportPort(.ready, holdFirst: false), presenter = ExportPresenter(store: port)
        app.exportPresenter = presenter
        app.exportSequenceOriginals(sequence)
        try await Self.wait { await index.entered }
        let currentID = CaptureID()
        app.exportCommittedOriginal(currentID, surface: .viewer)
        try await Self.wait { presenter.presented != nil }
        let current = try XCTUnwrap(presenter.presented)
        await index.release()
        for _ in 0..<20 { await Task.yield() }
        let requests = await port.requests
        XCTAssertEqual(requests, [[currentID]], "The superseded lookup must not queue scan/hash/copy work")
        XCTAssertEqual(presenter.presented?.session.sessionID, current.session.sessionID)
        XCTAssertTrue(presenter.ownsPresentation(.viewer))
        await presenter.finished(sessionID: current.session.sessionID)
    }

    @MainActor func testNewSequenceOrPendingCommandDisposesOldConsentAndChangedRootCannotConfirmIt() async throws {
        for next in ["sequence", "pending", "changed-root"] {
            let fixture = await StorageHarness.make(name: "third-export-consent-\(next)")
            let h = try XCTUnwrap(fixture), sequence = SequenceID()
            let card = Self.card(libraryID: h.libraryID, sequenceID: sequence)
            let index = InMemoryLibraryIndex()
            try await index.reset(libraryID: h.libraryID, generation: h.generation)
            try await index.upsert(scanned: [card])
            let app = AppEnvironment(); app.attach(store: h.store, index: index)
            let port = ThirdHeldExportPort(.partial, holdFirst: false), presenter = ExportPresenter(store: port)
            app.exportPresenter = presenter
            app.exportSelectedOriginals([card])
            try await Self.wait { app.pendingPartialExport != nil }
            let old = try XCTUnwrap(app.pendingPartialExport?.preparedSession)
            await port.setOutcome(.ready)
            switch next {
            case "sequence": app.exportSequenceOriginals(sequence)
            case "pending": app.exportPendingOriginal(TransactionID())
            default:
                try await Self.replaceRoot(h)
                app.confirmPendingPartialExport()
            }
            XCTAssertNil(app.pendingPartialExport, "A different command or folder cannot retain old consent")
            try await Self.wait { await port.discarded.contains(old.sessionID) }
            if next == "changed-root" {
                XCTAssertNil(presenter.presented)
                XCTAssertFalse(presenter.hasActiveExport)
                let requests = await port.requests
                XCTAssertEqual(requests.count, 1, "Invalidated consent never reprepares under another root")
            } else {
                try await Self.wait { presenter.presented != nil }
                let current = try XCTUnwrap(presenter.presented)
                XCTAssertNotEqual(current.session.sessionID, old.sessionID)
                await presenter.finished(sessionID: current.session.sessionID)
            }
        }
    }
}
#endif
