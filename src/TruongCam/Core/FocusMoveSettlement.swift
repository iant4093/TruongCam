import Foundation

/// Decides whether a requested focus move has actually completed.
///
/// REVIEW.md R03: the previous rule was `position != nil ? .settled : .notStarted`,
/// so a lens that was still travelling — which always reports a position — was
/// presented as a finished move. Completion requires the device's own settlement
/// state, and when a target was requested it also requires the observed position to
/// be within a stated tolerance of that target.
enum FocusMoveSettlement {
    /// Tolerance in normalized lens-position units. A policy value, not a measured
    /// lens characteristic.
    static let tolerance = 0.02

    static func state(
        requestedPosition: Double?,
        observedPosition: Double?,
        observedSettlement: ControlSettlementState,
        isManualFocus: Bool
    ) -> FocusMoveState {
        guard let observedPosition else {
            // No reading at all: the move has not been observed to start.
            return requestedPosition == nil ? .notStarted : .adjusting
        }
        guard isManualFocus else {
            // A continuous/auto focus mode has no requested endpoint to reach, so a
            // converged reading is the only thing that may be called settled.
            return observedSettlement.isSettled ? .settled : .adjusting
        }
        guard let requestedPosition else {
            return observedSettlement.isSettled ? .settled : .adjusting
        }
        guard observedSettlement.isSettled else { return .adjusting }
        // The move is complete only when the lens is actually at the requested
        // position, not merely when it stopped somewhere.
        return abs(observedPosition - requestedPosition) <= tolerance ? .settled : .adjusting
    }

    static func provenance(for state: FocusMoveState) -> ValueProvenance {
        switch state {
        case .settled: return .settledDeviceReadback
        case .adjusting, .notStarted, .failed: return .requested
        }
    }
}
