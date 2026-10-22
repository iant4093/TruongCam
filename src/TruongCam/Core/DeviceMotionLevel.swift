import Foundation

/// The device-motion BOUNDARY and its sample type.
///
/// AL01: Foundation-only. The CoreMotion coupling is confined to `CoreMotionLevelFeed`, which
/// stays in Camera/.
/// A gravity sample in the device's own frame.
struct DeviceGravitySample: Sendable {
    let x: Double
    let y: Double
    let z: Double
}

/// The motion feed boundary, so the camera view model is testable without sensors.
@preconcurrency
protocol DeviceMotionLevelFeeding: Sendable {
    var isRunning: Bool { get }
    /// Starts delivering samples. `onSample` is called on an internal queue.
    func start(onSample: @escaping @Sendable (DeviceGravitySample) -> Void)
    func stop()
}
