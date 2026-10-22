import Foundation

/// The single, shared marker a media-services reset publishes in its failure detail.
///
/// AM03: the camera model must interrupt an active sequence with
/// `SequenceInterruptionReason.mediaServicesReset` — not a generic `.unknown` — because the
/// recovery path differs. The service publishes this detail when the system resets its media
/// services; the model matches it. One shared constant, so neither side carries an ad-hoc literal.
enum MediaServicesResetSignal {
    static let detail = "The system reset its media services; the camera is being rebuilt."
    static let analysisUnavailableReason = "The system reset its media services. Rebuilding the camera."

    /// True when a recorded failure is a media-services reset.
    static func matches(detail: String) -> Bool { detail == Self.detail }
}

/// Latest camera state with a cumulative reset identity. A consumer may skip
/// transient lifecycle values, but a reset cannot disappear with that coalescing.
struct CameraSessionStatus: Sendable, Equatable {
    let condition: CameraLifecycle
    let resetEpoch: UInt64
}

protocol CameraSessionStatusProviding: Sendable {
    var sessionStatusStream: AsyncStream<CameraSessionStatus> { get }
    func recordedSessionStatus() async -> CameraSessionStatus
}
