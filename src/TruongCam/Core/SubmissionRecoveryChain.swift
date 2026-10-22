import Foundation

/// Owns the submission → terminal retirement → bounded teardown → reset → recovery/admission
/// SEQUENCE, so the caller order the service performs is executable in the verifier rather
/// than only in the AVFoundation adapter (Z02).
///
/// The native work is supplied by a narrow port. What is owned here is the ORDER and the
/// disposition: a teardown may only proceed to clean recovery/admission when the gate is
/// genuinely drained, otherwise the outstanding ownership is retained, disclosed and blocks
/// new admission until it is reconciled.
final class SubmissionRecoveryChain: @unchecked Sendable {
    /// What the rebuild/revalidation actually achieved.
    enum RebuildResult: Equatable, Sendable {
        /// The graph was rebuilt and the in-process controls were revalidated.
        case verified
        /// Native preparation failed.
        case prepareFailed
        /// The graph rebuilt but the controls could not be restored.
        case controlsFailed
    }

    /// What the chain concluded and did.
    enum Outcome: Equatable, Sendable {
        /// The drain settled and the graph was rebuilt with admission reopened.
        case recovered
        /// Work was still outstanding: the graph was torn down but admission stays CLOSED and
        /// the count is disclosed to the caller.
        case blockedByOutstanding(count: Int)
        /// The rebuild was not verified, so admission stays CLOSED and the failure stands.
        case blockedByFailedRebuild(RebuildResult)
    }

    /// The thin native port for one reset/recovery pass.
    ///
    /// `@unchecked Sendable`: the port is constructed and consumed within a single `run`
    /// call, and its closures only hop to the caller's own actor methods.
    struct Port: @unchecked Sendable {
        /// Tear the native graph down once the drain has been given its bounded chance.
        var teardownGraph: () async -> Void
        /// Rebuild and revalidate, reporting what actually happened.
        var rebuildAndRevalidate: () async -> RebuildResult
        /// Publish the actionable disclosure for outstanding work.
        var discloseOutstanding: (_ count: Int) async -> Void
        /// Reopen capture admission. Only reached on genuine recovery.
        var reopenAdmission: () async -> Void
    }

    private let gate: SubmissionDrainGate

    init(gate: SubmissionDrainGate) {
        self.gate = gate
    }

    /// Runs one reset/recovery pass. The deadline is the gate's duration-aware bound.
    func run(
        longestPlannedSeconds: Double = 0,
        generationChanged: @Sendable () -> Bool = { false },
        port: Port
    ) async -> Outcome {
        // The drain gets its bounded chance BEFORE any teardown, so already-submitted work is
        // not abandoned by the rebuild.
        let drain = await gate.awaitDrain(longestPlannedSeconds: longestPlannedSeconds)

        await port.teardownGraph()
        let rebuild = await port.rebuildAndRevalidate()

        // AA02: a GENERATION CHANGE cannot waive unresolved retained ownership — the older
        // pass is superseded, so it neither reopens admission nor rewrites the newer graph.
        let superseded = generationChanged()

        // Unresolved ownership is checked FIRST, so neither a supersession nor a rebuild
        // failure can turn outstanding retained work into clean recovery.
        if case .blockedByOutstanding(let count) = SubmissionDrainGate.disposition(for: drain) {
            await port.discloseOutstanding(count)
            return .blockedByOutstanding(count: count)
        }

        if superseded {
            // The newer graph owns admission; this pass must not reopen it.
            return .blockedByFailedRebuild(rebuild)
        }

        // AA02: only a VERIFIED rebuild may reopen admission. A failed preparation or
        // unrestored controls keeps admission closed and the failure actionable.
        guard rebuild == .verified else {
            return .blockedByFailedRebuild(rebuild)
        }

        await port.reopenAdmission()
        return .recovered
    }
}
