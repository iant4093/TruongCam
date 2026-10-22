import Foundation

/// Requested drive cadence, independent of exposure duration or native quality.
/// The next original is never requested before the previous verified save ends.
enum CaptureSpeed: String, Codable, CaseIterable, Identifiable, Sendable {
    case single, fps1, fps2, fps5
    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .single: "Single shot"
        case .fps1: "1 fps"
        case .fps2: "2 fps"
        case .fps5: "5 fps"
        }
    }
    var framesPerSecond: Double? {
        switch self {
        case .single: nil
        case .fps1: 1
        case .fps2: 2
        case .fps5: 5
        }
    }
    /// Slow capture/save work skips missed slots; it never creates catch-up work.
    func nextStart(after start: Double, finishedAt finish: Double) -> Double? {
        guard let fps = framesPerSecond, start.isFinite, finish.isFinite else { return nil }
        let next = max(start + 1 / fps, finish)
        return next.isFinite ? next : nil
    }
}

/// Portable counterpart of the public AVCaptureEvent phases.
enum ShutterPressPhase: Equatable, Sendable { case began, ended, cancelled }

/// Public capture-event callbacks distinguish these hardware channels.
enum HardwareShutterSource: Hashable, Sendable { case primary, secondary }
