import Foundation

/// The ONE rule that decides whether the published RAW capability is revoked after a final
/// tuple query.
///
/// AE03: three service callers act on the tuple disposition — `start`, the topology/analysis
/// -demand revalidation and the tuple refresh — and each previously decided for itself. Owning
/// the rule in Core makes the consumer decision executable in the verifier, so "a superseded
/// pass must not revoke a newer configuration" is a property of shared code rather than of
/// three separately-reviewed `if` statements.
enum CapabilityRevocation {
    /// What a caller must do with the published capability.
    enum Decision: Equatable, Sendable {
        /// The tuple is valid: keep advertising it.
        case retain
        /// A newer configuration owns the capability: keep it, and do NOT revoke.
        case retainBecauseSuperseded
        /// The tuple is genuinely invalid: revoke the capability and report actionable.
        case revoke
        /// The configuration could not be completed: revoke and report the failure.
        case revokeBecauseConfigurationFailed
    }

    /// Maps a final-tuple disposition to the caller's decision.
    static func decision(for disposition: FinalTupleOperation.Disposition) -> Decision {
        switch disposition {
        case .published:
            return .retain
        case .superseded:
            return .retainBecauseSuperseded
        case .refused:
            return .revoke
        case .configureFailed:
            return .revokeBecauseConfigurationFailed
        }
    }

    /// Whether a decision revokes. Callers use this rather than re-deriving the rule.
    static func revokes(_ decision: Decision) -> Bool {
        switch decision {
        case .revoke, .revokeBecauseConfigurationFailed: return true
        case .retain, .retainBecauseSuperseded: return false
        }
    }
}
