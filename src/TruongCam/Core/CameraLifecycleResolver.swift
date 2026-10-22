import Foundation

/// Resolves the camera lifecycle from a recorded session condition and the session's
/// own running state.
///
/// REVIEW.md fourth-pass F02: the rule lived inside `AVCaptureCameraService`, which
/// imports AVFoundation and therefore cannot be exercised by the portable verifier,
/// so a test-local duplicate had drifted into the suite as "evidence". The rule is
/// platform-neutral and now lives here, and the service delegates to it, so there is
/// exactly one implementation.
enum CameraLifecycleResolver {
    /// The effective lifecycle.
    ///
    /// A recorded interruption, failure or unavailability takes precedence over a
    /// technically-running session: a session that is running but no longer
    /// trustworthy must not open capture admission.
    static func effective(
        recorded: CameraLifecycle,
        sessionIsRunning: Bool
    ) -> CameraLifecycle {
        effective(recorded: recorded, cachedLifecycle: .idle, sessionIsRunning: sessionIsRunning)
    }

    /// Merges a service-recorded condition with the caller's cached lifecycle.
    ///
    /// REVIEW.md F02: the view model and the service each held part of the truth.
    /// A recorded interruption/failure/unavailability always wins, because the
    /// service observed it natively; otherwise the cached lifecycle wins while the
    /// session is genuinely running.
    static func effective(
        recorded: CameraLifecycle,
        cachedLifecycle: CameraLifecycle,
        sessionIsRunning: Bool
    ) -> CameraLifecycle {
        switch recorded {
        case .interrupted, .failed, .unavailable:
            return recorded
        case .reconfiguring:
            // A recorded reconfiguration means controls must be reapplied; report it
            // rather than pretending the camera is ready.
            return sessionIsRunning ? .reconfiguring : .idle
        case .idle, .requestingPermission, .configuring, .running, .stopping:
            // No native condition recorded. The caller's own terminal states still
            // win, because they were derived from real prepare/start failures; a
            // genuinely running session is otherwise reported as running.
            switch cachedLifecycle {
            case .unavailable, .failed, .interrupted:
                return cachedLifecycle
            case .idle, .requestingPermission, .configuring, .running, .reconfiguring, .stopping:
                return sessionIsRunning ? .running : .idle
            }
        }
    }
}
