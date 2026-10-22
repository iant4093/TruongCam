import Foundation

/// Composition preferences and the grid mode they refer to.
///
/// AL01: portable types (their remaining dependencies are already Core/Preview), extracted so
/// the camera model can be compiled and driven by the portable verifier.
struct CompositionPreferences: Hashable, Sendable {
    var gridMode: GridMode = .thirds
    var histogramEnabled = true
    var levelEnabled = true
    var peakingEnabled = false
    var peakingThreshold: PeakingThreshold = .normal
    var zebrasEnabled = false
    var zebraThreshold: ZebraThreshold = .default
    var loupeEnabled = false
    var loupeMagnification: Double = 2
    /// Where the loupe inspects. REVIEW.md S07: this was hardcoded to `.center`,
    /// so the required centre interaction did not exist. Remembered per user and
    /// clamped to the frame, since a point outside 0...1 would magnify nothing.
    var loupeCenter: NormalizedDevicePoint = .center
    var preferredLens: PhysicalCameraKind = .wide
    var timerSeconds: Int = 0
}

enum GridMode: String, Hashable, Sendable, CaseIterable, Identifiable {
    case off
    case thirds

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .off: return "Off"
        case .thirds: return "Thirds"
        }
    }
}
