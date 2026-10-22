import Foundation
import Synchronization

/// Owns the bookkeeping for requests that have been SUBMITTED to the native boundary and not yet
/// retired.
///
/// AM03: this is the shipping submission/retirement algorithm's state. It was private to
/// `AVCaptureCameraService`, which is AVFoundation-coupled, so the portable verifier could not
/// execute it and the fixture's producer code stood in. The state and transitions here use only
/// Core types, so extracting them lets the REAL algorithm run in tests while the service simply
/// delegates. The `drainGate` obligation stays explicit: a request is gate-tracked only when it is
/// first submitted, and the gate is told exactly once when it retires.
final class InFlightRequestRegistry: Sendable {
    private struct State: Sendable {
        var inFlight: Set<CaptureID> = []
        /// Requests whose SUBMISSION obligation was recorded on the drain gate.
        var gateTracked: Set<CaptureID> = []
        /// Longest planned exposure per in-flight request, so a bounded drain knows how long the
        /// outstanding work could legitimately take.
        var plannedSeconds: [CaptureID: Double] = [:]
    }

    private let state = Mutex(State())

    /// Records a request at its SUBMISSION boundary. Returns true when this call performed the
    /// transition, so a duplicate submission is visible rather than silently absorbing.
    @discardableResult
    func noteSubmitted(captureID: CaptureID, plannedSeconds: Double) -> Bool {
        state.withLock { s in
            let isNew = s.inFlight.insert(captureID).inserted
            s.gateTracked.insert(captureID)
            s.plannedSeconds[captureID] = plannedSeconds
            return isNew
        }
    }

    /// Retires a request at its TERMINAL boundary. Returns true when this call performed the
    /// transition AND the request was gate-tracked, so the caller knows to notify the gate exactly
    /// once; a second retirement returns false.
    @discardableResult
    func retire(captureID: CaptureID) -> Bool {
        state.withLock { s in
            let wasTracked = s.gateTracked.remove(captureID) != nil
            let wasInFlight = s.inFlight.remove(captureID) != nil
            s.plannedSeconds.removeValue(forKey: captureID)
            return wasTracked && wasInFlight
        }
    }

    var inFlightCount: Int { state.withLock { $0.inFlight.count } }
    func isInFlight(_ captureID: CaptureID) -> Bool { state.withLock { $0.inFlight.contains(captureID) } }
    /// Longest planned exposure among outstanding requests; 0 when none are outstanding.
    var longestPlannedSeconds: Double { state.withLock { $0.plannedSeconds.values.max() ?? 0 } }
}
