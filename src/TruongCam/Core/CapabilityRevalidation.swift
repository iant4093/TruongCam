import Foundation

/// Owns the SEQUENCE a service caller performs when it revalidates the published RAW capability
/// after a topology, analysis-demand, speed or format change (AF03).
///
/// The caller's ORDER is the contract: revalidate (an await), then decide on the RETURNED
/// disposition, then act — revoking or stopping only when the disposition is genuinely invalid.
/// A newer configuration that took over during the await must be left untouched. Owning the
/// sequence here makes that order executable rather than three separately-reviewed call sites.
enum CapabilityRevalidation {
    /// What the caller did, so a test can assert the effects rather than infer them.
    enum Outcome: Equatable, Sendable {
        /// The tuple was valid: nothing was changed.
        case retained
        /// A newer configuration owns the capability: nothing was changed, and NOTHING may be.
        case retainedBecauseSuperseded
        /// The capability was revoked because the tuple is genuinely invalid.
        case revoked
        /// The graph was stopped and the capability revoked because the configuration failed.
        case stoppedAndRevoked
    }

    /// The thin port for one revalidation pass.
    struct Port: @unchecked Sendable {
        /// Re-queries the committed tuple and returns its disposition (an await).
        var revalidate: () async -> FinalTupleOperation.Disposition
        /// Revoke the published capability. It receives the transaction that was current when
        /// this pass STARTED and must re-validate it immediately before mutating, so an
        /// obsolete pass cannot revoke a newer configuration (AG03).
        var revoke: (_ transactionAtStart: UInt64) async -> Void
        /// The configuration transaction current when this pass starts.
        var currentTransaction: () -> UInt64
        /// Stop the native graph (start-path callers only; topology callers pass a no-op).
        var stopGraph: () async -> Void
        /// Whether this caller stops the graph on a genuinely invalid tuple.
        var stopsOnInvalid: Bool
    }

    /// Runs the caller sequence. The decision is computed from the AWAITED disposition, and no
    /// suspension separates the decision from the mutation.
    static func run(port: Port) async -> Outcome {
        // AG03: captured BEFORE the await, so the callback can tell whether a newer
        // configuration registered while this pass was suspended.
        let transactionAtStart = port.currentTransaction()
        let disposition = await port.revalidate()
        let action = FinalTupleAdmission.action(
            for: CapabilityRevocation.decision(for: disposition))
        switch action {
        case .proceed:
            return .retained
        case .failWithoutStopping:
            // A newer configuration owns the graph: neither revoke nor stop it.
            return .retainedBecauseSuperseded
        case .stopAndFail:
            if port.stopsOnInvalid { await port.stopGraph() }
            await port.revoke(transactionAtStart)
            return port.stopsOnInvalid ? .stoppedAndRevoked : .revoked
        }
    }
}
