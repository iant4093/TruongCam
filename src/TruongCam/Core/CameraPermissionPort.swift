import Foundation

/// Camera authorization as the app observes it.
///
/// REVIEW.md S03: the app treated `.notDetermined` as denial and never called the
/// public request API, so a fresh install could not grant permission. The decision
/// logic is expressed against this port so it can be exercised without a device.
enum CameraAuthorization: Hashable, Sendable {
    case notDetermined
    case authorized
    case denied
    case restricted

    /// True when asking the user is both possible and correct.
    var shouldRequest: Bool { self == .notDetermined }
}

/// Supplies camera authorization and can request it.
protocol CameraPermissionPort: Sendable {
    func currentAuthorization() async -> CameraAuthorization
    /// Requests access. Only meaningful from `.notDetermined`.
    func requestAuthorization() async -> CameraAuthorization
}

/// The decision for a `prepare()` attempt, kept pure so it is testable.
enum CameraPermissionDecision: Hashable, Sendable {
    /// Proceed with session configuration.
    case proceed
    /// Ask the user, then re-evaluate the returned state.
    case request
    /// Refuse, with the reason to surface.
    case refuse(reason: String)

    /// Maps an observed authorization to the correct action.
    ///
    /// A denied grant is recoverable only through Settings, so it reports that
    /// distinctly from an unaskable restriction.
    static func decide(_ authorization: CameraAuthorization) -> CameraPermissionDecision {
        switch authorization {
        case .authorized: return .proceed
        case .notDetermined: return .request
        case .denied:
            return .refuse(reason: "Camera access is denied. Allow Camera for TruongCam in Settings.")
        case .restricted:
            return .refuse(reason: "Camera access is restricted on this device and cannot be granted by the app.")
        }
    }

    /// The action AFTER a request has been answered.
    static func decideAfterRequest(_ authorization: CameraAuthorization) -> CameraPermissionDecision {
        switch authorization {
        case .authorized: return .proceed
        case .notDetermined:
            // The system did not answer; do not pretend either way.
            return .refuse(reason: "Camera access is still undetermined after the system prompt.")
        case .denied:
            return .refuse(reason: "Camera access was not granted. Allow Camera for TruongCam in Settings.")
        case .restricted:
            return .refuse(reason: "Camera access is restricted on this device and cannot be granted by the app.")
        }
    }
}
