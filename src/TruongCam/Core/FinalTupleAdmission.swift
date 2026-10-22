import Foundation

/// The START caller's handling of a final-tuple revalidation, owned in Core so the ORDER of
/// its effects is executable in the verifier (AE03).
///
/// The distinction matters: a SUPERSEDED pass must fail WITHOUT stopping the graph, because a
/// newer configuration owns it; only a genuinely invalid or failed configuration stops and
/// clears readiness.
enum FinalTupleAdmission {
    /// What the start caller must do after revalidating the final tuple.
    enum Action: Equatable, Sendable {
        /// The tuple is valid: the start may proceed.
        case proceed
        /// A newer configuration superseded this start: fail, but do NOT stop the graph.
        case failWithoutStopping
        /// The configuration is unusable: STOP the graph and clear readiness.
        case stopAndFail
    }

    static func action(for decision: CapabilityRevocation.Decision) -> Action {
        switch decision {
        case .retain: return .proceed
        case .retainBecauseSuperseded: return .failWithoutStopping
        case .revoke, .revokeBecauseConfigurationFailed: return .stopAndFail
        }
    }

    /// A topology change may obsolete a query while its START still owns the
    /// lifecycle. One fresh query is permitted; obsolete starts never query again
    /// or infer support, and sustained churn stays an actionable neutral failure.
    static func validateCurrentTuple(
        isolation: isolated (any Actor)? = #isolation,
        isCurrent: () -> Bool,
        query: () async -> FinalTupleOperation.Disposition
    ) async -> FinalTupleOperation.Disposition {
        let first = await query()
        guard first == .superseded, isCurrent() else { return first }
        return await query()
    }

    /// Whether the start caller must stop the native graph. Callers branch on this rather than
    /// re-deriving the rule, so "superseded never stops a newer graph" is shared code.
    static func stopsGraph(_ action: Action) -> Bool { action == .stopAndFail }
}
