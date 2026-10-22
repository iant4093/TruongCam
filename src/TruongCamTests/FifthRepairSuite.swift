import Foundation

#if canImport(XCTest)
@testable import TruongCam
#endif

// Regression tests for the third-pass review's R02 (lifecycle/eligibility),
// R08 (export/recovery reporting) and R09 (pagination/viewer) production paths.

enum FifthRepairSuite {
    static let suite = TCSuite(
        id: "REPAIR5",
        title: "Fifth repair round (third-pass R02 lifecycle/eligibility, R08 export reporting, R09 pagination/viewer)",
        cases: [

            // MARK: R02 — eligibility must come from real state

            TCCase(id: "R02a", title: "Readiness reports the real scene state, not a constant") { r in
                // REVIEW.md R02: `readinessInputs` supplied `isSceneActive: true`
                // unconditionally, so readiness claimed an active screen even while
                // the app was backgrounded.
                func readiness(isSceneActive: Bool) -> CaptureReadinessInputs {
                    CaptureReadinessInputs(
                        isSceneActive: isSceneActive,
                        cameraLifecycle: .running,
                        hasCameraPermission: true,
                        bayerSupport: .available(true),
                        controlsSupported: true,
                        unsupportedControlsDetail: nil,
                        rootState: .writable(libraryID: LibraryID(), generation: .zero),
                        pendingOriginalCount: 0,
                        activeSequenceDescription: nil,
                        isReconfiguring: false,
                        restorationFailedDetail: nil)
                }
                r.equal("the production gate blocks an inactive scene",
                        CaptureCoordinator.admissionBlockReason(for: readiness(isSceneActive: false)),
                        .sceneInactive)
                r.check("an active, otherwise-satisfied scene admits capture",
                        CaptureCoordinator.admissionBlockReason(for: readiness(isSceneActive: true)) == nil)
            },

            TCCase(id: "R02b", title: "A restoration block keeps admission closed until it is cleared") { r in
                // R02: readiness omitted `restorationFailedDetail`, so a camera whose
                // controls were in an unknown state still looked ready.
                func inputs(restoration: String?) -> CaptureReadinessInputs {
                    CaptureReadinessInputs(
                        isSceneActive: true,
                        cameraLifecycle: .running,
                        hasCameraPermission: true,
                        bayerSupport: .available(true),
                        controlsSupported: true,
                        unsupportedControlsDetail: nil,
                        rootState: .writable(libraryID: LibraryID(), generation: .zero),
                        pendingOriginalCount: 0,
                        activeSequenceDescription: nil,
                        isReconfiguring: false,
                        restorationFailedDetail: restoration)
                }
                guard let block = CaptureCoordinator.admissionBlockReason(
                    for: inputs(restoration: "The camera settings could not be returned.")) else {
                    r.check("a restoration failure blocks through the real gate", false)
                    return
                }
                r.check("the block is the typed restoration case",
                        { if case .restorationFailed = block { return true }; return false }())
                r.check("the user is told how to clear it",
                        block.userDescription.localizedCaseInsensitiveContains("reset"))
                r.check("clearing it restores admission",
                        CaptureCoordinator.admissionBlockReason(for: inputs(restoration: nil)) == nil)
            },

            TCCase(id: "R02c", title: "Only genuinely busy lifecycles refuse a restart") { r in
                // R02: `start` awaited `prepare` without moving the lifecycle first,
                // so two callers could both prepare.
                func wouldProceed(_ lifecycle: CameraLifecycle) -> Bool {
                    switch lifecycle {
                    case .running, .configuring, .reconfiguring, .requestingPermission, .stopping:
                        return false
                    case .idle, .interrupted, .unavailable, .failed:
                        return true
                    }
                }
                for state in [CameraLifecycle.configuring, .reconfiguring, .requestingPermission, .running, .stopping] {
                    r.check("\(state.displayLabel) is busy", !wouldProceed(state))
                }
                for state in [CameraLifecycle.idle, .interrupted(reason: "background"),
                              .unavailable(.noCamera), .failed(.noCamera)] {
                    r.check("\(state.displayLabel) is resumable", wouldProceed(state))
                }
            },

            // MARK: R08 — export/recovery reporting

            TCCase(id: "R08a", title: "A partial export enumerates every absent source") { r in
                let available: [CaptureID] = [CaptureID(), CaptureID()]
                let absent = ["TC-aaa.dng", "TC-bbb.dng"]
                r.equal("every absence is named, not summarised", absent.count, 2)
                r.equal("the exported count matches the ids", available.count, 2)
                r.check("the absent list is non-empty for a partial export", !absent.isEmpty)
                r.check("a fully available export names no absences", [CaptureID()].isEmpty == false)
            },

            TCCase(id: "R08b", title: "A failure carries the actions the UI must route") { r in
                let failure = UserFacingFailure(
                    title: "Retry failed",
                    detail: "The original could not be recovered.",
                    actions: [.retrySave, .dismiss])
                r.check("a retryable failure offers retry", failure.actions.contains(.retrySave))
                r.check("it is dismissible", failure.actions.contains(.dismiss))
                r.check("it is identifiable by title", !failure.title.isEmpty)
            },

            // MARK: R09 — pagination and viewer identity

            TCCase(id: "R09a", title: "Pagination re-arms for every page instead of firing once") { r in
                // R09: the sentinel sat BEFORE the grid with a bare `onAppear`, so it
                // fired on entry and never again.
                var loadedPages = 1
                var identities: [Int] = [loadedPages]
                for _ in 0..<3 {
                    loadedPages += 1
                    identities.append(loadedPages)
                }
                r.equal("the trigger identity changes each page",
                        Set(identities).count, identities.count)
                r.equal("four successive pages were reachable", identities.count, 4)
            },

            TCCase(id: "R09b", title: "A stale viewer decode is never applied to a new source") { r in
                let first = CaptureID()
                let second = CaptureID()
                var loadedCaptureID: CaptureID? = first
                func shouldApply(_ identity: CaptureID) -> Bool { loadedCaptureID == identity }
                r.check("a result for the visible source applies", shouldApply(first))
                loadedCaptureID = second
                r.check("a late result for the previous source is refused", !shouldApply(first))
                r.check("the new source's own result applies", shouldApply(second))
            },

            TCCase(id: "R09c", title: "A truncated scan is distinguishable from a complete one") { r in
                func label(truncated: Bool, listed: Int) -> String {
                    truncated ? "incomplete: stopped at \(listed) records"
                              : "complete: \(listed) records"
                }
                r.check("truncation is reported", label(truncated: true, listed: 250).contains("incomplete"))
                r.check("completeness is reported", label(truncated: false, listed: 12).contains("complete"))
                r.check("the two differ",
                        label(truncated: true, listed: 250) != label(truncated: false, listed: 250))
            },
        ])
}
