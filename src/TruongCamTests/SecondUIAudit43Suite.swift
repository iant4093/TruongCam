import Foundation

#if canImport(XCTest)
@testable import TruongCam
#endif

/// Scheduled, superseded commands must be inert before touching even routing.
/// Uses the real presenter with a narrow recording port, without Files or Photos.
enum SecondUIAudit43Suite {
    static let suite = TCSuite(id: "SECOND-UI-AUDIT-43", title: "Second review: scheduled export authority", cases: [
        TCCase(id: "UI43R2-E", title: "Stale committed and pending invocations cannot reroute the current command") { r in
            await staleRouting(r)
        },
        TCCase(id: "UI43R2-V", title: "Current committed and pending invocations retain valid surface/session routing") { r in
            await validRouting(r)
        }
    ])

    @MainActor private static func staleRouting(_ r: TCRecorder) async {
        let store = FakeExportStore(), presenter = ExportPresenter(store: nil)
        let recordedPresenter = ExportPresenter(store: store)
        for subject in [presenter, recordedPresenter] {
            let stale = subject.beginCommand()
            _ = subject.beginCommand()
            subject.routePresentation(to: .library)
            await subject.export(ExportPresenter.Invocation(surface: .viewer, sources: [store.captureID],
                includeSidecars: false, description: "superseded committed", epoch: stale))
            r.check("stale committed command leaves route unchanged", subject.ownsPresentation(.library))
            await subject.exportPending(ExportPresenter.Invocation(surface: .root, sources: [],
                includeSidecars: false, description: "superseded pending", transactionIDs: [TransactionID()], epoch: stale))
            r.check("stale pending command leaves route unchanged", subject.ownsPresentation(.library))
            r.check("obsolete commands publish neither error nor session", subject.lastFailure == nil && subject.presented == nil)
        }
        r.check("obsolete commands never reach storage", await store.requestedSidecarChoices.isEmpty)
    }

    @MainActor private static func validRouting(_ r: TCRecorder) async {
        let store = FakeExportStore(), presenter = ExportPresenter(store: store)
        let first = session("committed"), second = session("pending")
        await store.script([first])
        let committed = presenter.beginCommand()
        await presenter.export(ExportPresenter.Invocation(surface: .viewer, sources: [store.captureID],
            includeSidecars: true, description: "current committed", epoch: committed))
        r.equal("current committed session presented", presenter.presented?.session.sessionID, first.sessionID)
        r.check("current committed surface is the viewer", presenter.ownsPresentation(.viewer))
        await presenter.finished(sessionID: first.sessionID)
        await store.script([second])
        let pending = presenter.beginCommand()
        await presenter.exportPending(ExportPresenter.Invocation(surface: .root, sources: [],
            includeSidecars: false, description: "current pending", transactionIDs: [TransactionID()], epoch: pending))
        r.equal("current pending session presented", presenter.presented?.session.sessionID, second.sessionID)
        r.check("current pending surface is root", presenter.ownsPresentation(.root))
        r.equal("both valid choices reached storage", await store.requestedSidecarChoices, [true, false])
        await presenter.finished(sessionID: second.sessionID)
        r.check("finished sessions release live ownership", !presenter.hasActiveExport)
        r.equal("only owned sessions discarded", await store.discardedSessionIDs, [first.sessionID, second.sessionID])
    }

    private static func session(_ name: String) -> ExportSession {
        ExportSession(sessionID: UUID(), directoryRelativePath: "TruongCamExport/second-review-\(name)",
            fileURLs: [URL(fileURLWithPath: "/fixture-export/\(name).dng")], includedSidecars: false,
            missingItems: [], totalByteCount: 4, preparedAtUTC: Date(timeIntervalSince1970: 1_700_000_000))
    }
}
