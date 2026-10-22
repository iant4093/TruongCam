import Foundation

#if canImport(XCTest)
@testable import TruongCam
#endif

// REVIEW.md J07: the REAL `ExportPresenter` owns exact prepared / pending-consent /
// presented sessions. `ExportPresenter` is `@MainActor`, so each scenario runs in a
// `@MainActor` helper and returns only Sendable results; the checks themselves are made
// outside the actor. The presenter is driven through the narrow `ExportPreparing` port.
enum ExportOwnershipSuite {
    static let suite = TCSuite(
        id: "EXPORT-OWNERSHIP",
        title: "Export preparation, consent and presentation ownership (J07)",
        cases: [

            TCCase(id: "J07a", title: "A cancel discards ONLY its own prepared session") { r in
                let outcome = await OwnedExportScenarios.cancelOnlyOne()
                r.equal("exactly one session was cleaned", outcome.discarded.count, 1)
                r.equal("and it was A", outcome.discarded.first, outcome.sessionA)
                r.check("the other session is still live", outcome.stillLive)
                r.check("B was never cleaned", !outcome.discarded.contains(outcome.sessionB))
            },

            TCCase(id: "J07b", title: "A stale completion cannot clear a newer presentation") { r in
                let outcome = await OwnedExportScenarios.staleCompletion()
                r.equal("the newer presentation survives", outcome.presented, outcome.sessionB)
                // M05: the stale completion must NOT clear the newer presentation, but it
                // DOES dispose its own finished session rather than leaking its copies.
                r.equal("the stale completion disposed exactly its own session",
                        outcome.discarded, [outcome.sessionA])
                r.check("the newer session was not discarded",
                        !outcome.discarded.contains(outcome.sessionB))
            },

            TCCase(id: "J07c", title: "A held session is live and an empty one is not") { r in
                let outcome = await OwnedExportScenarios.heldVersusEmpty()
                r.check("the held session is live", outcome.heldIsLive)
                r.check("the empty session is not live", !outcome.emptyIsLive)
                r.check("the absence is reported", outcome.reportedMissing)
                r.check("preparing alone cleaned nothing", outcome.discarded.isEmpty,
                        "discarded=\(outcome.discarded)")
            },

            TCCase(id: "J07d", title: "The sidecar choice reaches real preparation") { r in
                let choices = await OwnedExportScenarios.sidecarChoices()
                r.equal("DNG-only is the first request", choices.first, false)
                r.equal("an explicit choice is carried through", choices.last, true)
            },

            TCCase(id: "J07e", title: "Exactly one surface owns a presentation") { r in
                let outcome = await OwnedExportScenarios.routing()
                r.check("the viewer owns it", outcome.viewerOwns)
                r.check("the root does not", outcome.rootDoesNot)
                r.check("routing moves ownership to the root", outcome.rootOwnsAfterRouting)
            },

            TCCase(id: "J07f", title: "A failed preparation leaves nothing live") { r in
                let outcome = await OwnedExportScenarios.failedPreparation()
                r.check("the failure was reported", outcome.reportedFailure)
                r.check("nothing is left live", !outcome.isLive)
            },
        ])
}

/// Sendable results, so the `@Sendable` case bodies only ever see values.
struct OwnedExportOutcome: Sendable {
    var discarded: [UUID] = []
    var sessionA = UUID()
    var sessionB = UUID()
    var presented: UUID?
    var stillLive = false
    var heldIsLive = false
    var emptyIsLive = false
    var reportedMissing = false
    var reportedFailure = false
    var isLive = false
    var viewerOwns = false
    var rootDoesNot = false
    var rootOwnsAfterRouting = false
}

@MainActor
enum OwnedExportScenarios {

    private static func preparedSession(_ name: String) -> ExportSession {
        ExportSession(
            sessionID: UUID(), directoryRelativePath: "TruongCamExport/\(name)",
            fileURLs: [URL(fileURLWithPath: "/tmp/TruongCamExport/\(name)/TC_\(name).dng")],
            includedSidecars: false, missingItems: [], totalByteCount: 4,
            preparedAtUTC: Date(timeIntervalSince1970: 1_700_000_000))
    }

    static func cancelOnlyOne() async -> OwnedExportOutcome {
        var out = OwnedExportOutcome()
        let store = FakeExportStore()
        let presenter = ExportPresenter(store: store)
        let a = preparedSession("A")
        let b = preparedSession("B")
        out.sessionA = a.sessionID
        out.sessionB = b.sessionID
        await store.script([a])
        _ = await presenter.prepare(sources: [store.captureID], includeSidecars: false)
        await store.script([b])
        _ = await presenter.prepare(sources: [store.captureID], includeSidecars: false)
        await presenter.discardPrepared(a)
        out.discarded = await store.discardedSessionIDs
        out.stillLive = presenter.hasActiveExport
        return out
    }

    static func staleCompletion() async -> OwnedExportOutcome {
        var out = OwnedExportOutcome()
        let store = FakeExportStore()
        let presenter = ExportPresenter(store: store)
        let a = preparedSession("A")
        let b = preparedSession("B")
        out.sessionA = a.sessionID
        out.sessionB = b.sessionID
        await store.script([a])
        if case .ready(let prepared) = await presenter.prepare(
            sources: [store.captureID], includeSidecars: false) {
            presenter.presentPrepared(prepared, description: "A")
        }
        await store.script([b])
        if case .ready(let prepared) = await presenter.prepare(
            sources: [store.captureID], includeSidecars: false) {
            presenter.presentPrepared(prepared, description: "B")
        }
        // A's dismissal arrives LATE, after B owns the presentation.
        await presenter.finished(sessionID: a.sessionID)
        out.presented = presenter.presented?.session.sessionID
        out.discarded = await store.discardedSessionIDs
        return out
    }

    static func heldVersusEmpty() async -> OwnedExportOutcome {
        var out = OwnedExportOutcome()
        let store = FakeExportStore()
        let presenter = ExportPresenter(store: store)
        await store.script([preparedSession("A")])
        _ = await presenter.prepare(sources: [store.captureID], includeSidecars: false)
        out.heldIsLive = presenter.hasActiveExport

        // A separate presenter, so "is the EMPTY session live?" is not answered by A.
        let emptyStore = FakeExportStore()
        let emptyPresenter = ExportPresenter(store: emptyStore)
        let empty = ExportSession(
            sessionID: UUID(), directoryRelativePath: "TruongCamExport/empty",
            fileURLs: [], includedSidecars: false, missingItems: ["TC_missing.dng"],
            totalByteCount: 0, preparedAtUTC: Date())
        await emptyStore.script([empty])
        if case .nothingAvailable(let missing) = await emptyPresenter.prepare(
            sources: [emptyStore.captureID], includeSidecars: false) {
            out.reportedMissing = missing.contains("TC_missing.dng")
        }
        out.emptyIsLive = emptyPresenter.hasActiveExport
        out.discarded = await store.discardedSessionIDs + (await emptyStore.discardedSessionIDs)
        return out
    }

    static func sidecarChoices() async -> [Bool] {
        let store = FakeExportStore()
        let presenter = ExportPresenter(store: store)
        await store.script([preparedSession("A")])
        _ = await presenter.prepare(sources: [store.captureID], includeSidecars: false)
        await store.script([preparedSession("B")])
        _ = await presenter.prepare(sources: [store.captureID], includeSidecars: true)
        return await store.requestedSidecarChoices
    }

    static func routing() async -> OwnedExportOutcome {
        var out = OwnedExportOutcome()
        let store = FakeExportStore()
        let presenter = ExportPresenter(store: store)
        presenter.routePresentation(to: .viewer)
        out.viewerOwns = presenter.ownsPresentation(.viewer)
        out.rootDoesNot = !presenter.ownsPresentation(.root)
        presenter.routePresentation(to: .root)
        out.rootOwnsAfterRouting = presenter.ownsPresentation(.root)
        return out
    }

    static func failedPreparation() async -> OwnedExportOutcome {
        var out = OwnedExportOutcome()
        let store = FakeExportStore()
        await store.setShouldFail(true)
        let presenter = ExportPresenter(store: store)
        let result = await presenter.prepare(sources: [store.captureID], includeSidecars: false)
        if case .failed = result { out.reportedFailure = true }
        out.isLive = presenter.hasActiveExport
        return out
    }
}

/// A minimal `ExportPreparing` fake: exactly the port the export owner depends on.
actor FakeExportStore: ExportPreparing {
    let captureID = CaptureID()
    private var scripted: [ExportSession] = []
    private var shouldFail = false
    private(set) var discardedSessionIDs: [UUID] = []
    private(set) var requestedSidecarChoices: [Bool] = []

    func script(_ sessions: [ExportSession]) { scripted = sessions }
    func setShouldFail(_ value: Bool) { shouldFail = value }

    func prepareOriginalExport(
        sourceIDs: [CaptureID], includeSidecars: Bool
    ) async throws -> ExportSession {
        requestedSidecarChoices.append(includeSidecars)
        if shouldFail {
            throw CaptureFailure(kind: .providerIOFailed(detail: "synthetic"), operation: "prepare")
        }
        guard let first = scripted.first else {
            throw CaptureFailure(kind: .providerIOFailed(detail: "no scripted session"), operation: "prepare")
        }
        return first
    }

    func preparePendingOriginalExport(
        transactionIDs: [TransactionID], includeSidecars: Bool
    ) async throws -> ExportSession {
        requestedSidecarChoices.append(includeSidecars)
        guard let first = scripted.first else {
            throw CaptureFailure(kind: .providerIOFailed(detail: "no scripted session"), operation: "prepare")
        }
        return first
    }

    func discardExport(sessionID: UUID) async { discardedSessionIDs.append(sessionID) }

    func clearAbandonedExports() async {}
}
