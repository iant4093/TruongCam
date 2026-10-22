import CoreMotion
import Foundation

// REVIEW.md C08: `updateLevel` had no producer, so the level overlay always read
// "Level unavailable". This is the missing CoreMotion feed.
//
// PREVIEW_TOOLS.md requires motion work to stop when the level is hidden or the
// app is inactive, so the feed is explicitly startable/stoppable and reports that
// state instead of silently running in the background.

/// CoreMotion-backed implementation.
///
/// Ownership invariant for the narrow `@unchecked Sendable`: `manager` and
/// `handler` are only read/written while `lock` is held, and the handler is
/// invoked by CoreMotion on `queue`. No other state exists.
final class CoreMotionLevelFeed: DeviceMotionLevelFeeding, @unchecked Sendable {
    private let lock = NSLock()
    private let manager = CMMotionManager()
    private let queue = OperationQueue()
    private var handler: (@Sendable (DeviceGravitySample) -> Void)?
    private var running = false

    /// Update interval. 10 Hz is plenty for a level and keeps the sensor cost low.
    private let updateInterval: TimeInterval = 0.1

    init() {
        queue.name = "com.iantruong.TruongCam.motion"
        queue.qualityOfService = .utility
        queue.maxConcurrentOperationCount = 1
    }

    var isRunning: Bool {
        lock.lock(); defer { lock.unlock() }
        return running
    }

    func start(onSample: @escaping @Sendable (DeviceGravitySample) -> Void) {
        lock.lock()
        handler = onSample
        let alreadyRunning = running
        lock.unlock()

        guard !alreadyRunning else { return }
        guard manager.isDeviceMotionAvailable else { return }

        manager.deviceMotionUpdateInterval = updateInterval
        manager.startDeviceMotionUpdates(to: queue) { [weak self] motion, _ in
            guard let self, let motion else { return }
            let gravity = motion.gravity
            let sample = DeviceGravitySample(x: gravity.x, y: gravity.y, z: gravity.z)
            self.lock.lock()
            let callback = self.handler
            let stillRunning = self.running
            self.lock.unlock()
            // Only deliver while explicitly running, so a stop mid-flight cannot
            // keep updating a hidden overlay.
            if stillRunning || callback != nil {
                callback?(sample)
            }
        }
        lock.lock()
        running = true
        lock.unlock()
    }

    func stop() {
        lock.lock()
        let wasRunning = running
        running = false
        handler = nil
        lock.unlock()
        if wasRunning, manager.isDeviceMotionActive {
            manager.stopDeviceMotionUpdates()
        }
    }

    deinit {
        if manager.isDeviceMotionActive { manager.stopDeviceMotionUpdates() }
    }
}
