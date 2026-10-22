import Foundation

/// Owns the ORDERING and the OWNERSHIP GUARDS of the two rebuild steps a media-services reset
/// performs, so the shipping service and the portable verifier run the same algorithm.
///
/// AM03: `prepareForRebuild` and `revalidateControlsAfterRebuild` previously held this logic inline
/// in the AVFoundation-coupled service, so the verifier could not execute it and fixture code
/// stood in. Both bodies were already free of AVFoundation references, so the logic moves here and
/// the native work is supplied through narrow ports.
enum ResetRebuildSteps {
    /// The preparation step: bump the configuration generation, prepare the camera, and disclose an
    /// actionable failure. Returns false when preparation failed OR this pass became obsolete while
    /// preparing — in the obsolete case the newer graph keeps its own state and condition.
    static func prepare(
        passToken: UInt64,
        bumpGeneration: @Sendable (UInt64) async -> Void,
        isCurrentPass: @Sendable (UInt64) async -> Bool,
        prepare: @Sendable (UInt64) async -> Result<Void, CaptureFailure>,
        discloseFailure: @Sendable (String, UInt64) async -> Void
    ) async -> Bool {
        // AN02: refused BEFORE the bump and BEFORE any native preparation. A stale pass must not
        // advance the newer graph's generation nor issue a preparation at all.
        guard await isCurrentPass(passToken) else { return false }
        await bumpGeneration(passToken)
        guard await isCurrentPass(passToken) else { return false }
        switch await prepare(passToken) {
        case .success:
            // AN02: a SUCCESS is re-checked too — a pass superseded WHILE preparing must not report
            // success over the newer graph.
            return await isCurrentPass(passToken)
        case .failure(let failure):
            // AD02: re-checked AFTER the await. A newer pass may have completed while this one was
            // inside native preparation, and this obsolete pass must not relabel or replace the
            // newer graph with its own failure.
            guard await isCurrentPass(passToken) else { return false }
            await discloseFailure(
                "The camera could not be rebuilt after the media services reset: "
                    + failure.kind.userDescription,
                passToken)
            return false
        }
    }

    /// The control step: re-apply and verify the in-process controls under the NEW generation.
    ///
    /// AE02: ownership is re-validated AFTER the prepare await and BEFORE any native control is
    /// issued, so an obsolete pass never reapplies controls over a newer graph. AD02/AA02: a control
    /// failure is ACTIONABLE and is re-checked after its own await, so an obsolete pass cannot
    /// replace a newer graph's condition with its own failure.
    static func revalidateControls(
        passToken: UInt64,
        isCurrentPass: @Sendable (UInt64) async -> Bool,
        applyControls: @Sendable (UInt64) async -> Result<Void, CaptureFailure>,
        discloseFailure: @Sendable (String, UInt64) async -> Void
    ) async -> Bool {
        guard await isCurrentPass(passToken) else { return false }
        switch await applyControls(passToken) {
        case .success:
            // AN02: re-checked after the control await, so a pass superseded WHILE verifying does
            // not report success over the newer graph.
            return await isCurrentPass(passToken)
        case .failure(let failure):
            guard await isCurrentPass(passToken) else { return false }
            await discloseFailure(
                "The camera was rebuilt but its controls could not be restored: "
                    + failure.kind.userDescription,
                passToken)
            return false
        }
    }
}
