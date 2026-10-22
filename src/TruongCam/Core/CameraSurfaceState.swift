import Foundation

/// What the camera screen should currently show.
///
/// AL01: App-layer state that depends on NOTHING platform-specific, so the portable verifier
/// can compile the camera model that consumes it.
/// What the camera screen should currently show.
enum CameraSurfaceState: Hashable, Sendable {
    case preparing
    case ready
    case unsupportedBayer(detail: String)
    case cameraPermissionDenied
    case cameraUnavailable(detail: String)

    var userDescription: String {
        switch self {
        case .preparing: return "Starting the camera"
        case .ready: return "Ready"
        case .unsupportedBayer: return "RAW isn’t available on this camera. Try another lens."
        case .cameraPermissionDenied: return "Allow camera access in Settings to take photos."
        case .cameraUnavailable: return "The camera isn’t ready. Please try again."
        }
    }
}
