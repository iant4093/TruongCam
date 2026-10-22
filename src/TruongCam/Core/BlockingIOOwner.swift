import Foundation
import Synchronization

/// A serial owner for blocking I/O work.
///
/// REVIEW.md F01: real reads and bounded decode work must execute on a dedicated I/O
/// owner rather than MainActor, and must NOT be dispatched out of a coordination
/// accessor that has already returned. `perform` therefore runs the work
/// synchronously on this owner's own thread and returns only when it is finished,
/// which lets a `NSFileCoordinator` accessor wait for the read it is protecting.
final class BlockingIOOwner: @unchecked Sendable {
    private let queue: DispatchQueue
    private let queueKey = DispatchSpecificKey<UInt8>()
    private let queued = Mutex(0)
    var queuedOperationCount: Int { queued.withLock { $0 } }

    init(label: String = "com.iantruong.TruongCam.io-owner") {
        queue = DispatchQueue(label: label, qos: .userInitiated)
        queue.setSpecific(key: queueKey, value: 1)
    }

    /// Runs `work` on the I/O owner and returns after it completes.
    func perform(_ work: () -> Void) {
        if DispatchQueue.getSpecific(key: queueKey) != nil {
            // Already on the owner: run inline to avoid a self-deadlock.
            work()
            return
        }
        queue.sync(execute: work)
    }

    /// Submit the entire synchronous operation to the bounded owner, suspending
    /// its caller instead of blocking a cooperative executor or storage actor.
    /// Cancellation skips queued work; an accessor already running always drains
    /// before returning so its caller can safely release its security-scope lease.
    func submit<T: Sendable>(_ work: @escaping @Sendable () throws -> T) async throws -> T {
        let cancelled = Mutex(false)
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                queued.withLock { $0 += 1 }
                queue.async {
                    self.queued.withLock { $0 -= 1 }
                    guard !cancelled.withLock({ $0 }) else {
                        continuation.resume(throwing: CancellationError())
                        return
                    }
                    let result = Result { try work() }
                    if cancelled.withLock({ $0 }) {
                        continuation.resume(throwing: CancellationError())
                    } else {
                        continuation.resume(with: result)
                    }
                }
            }
        } onCancel: {
            cancelled.withLock { $0 = true }
        }
    }
}

/// Carries a synchronous result out of a coordination accessor's body.
///
/// The accessor's contract is synchronous, so the value must be materialized before
/// it returns. `Sendable` because the box crosses from the I/O owner to the caller.
final class ReadResultBox<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var result: Result<T, Error>?

    func store(_ value: Result<T, Error>) {
        lock.lock(); result = value; lock.unlock()
    }

    func value() throws -> T {
        lock.lock()
        let captured = result
        lock.unlock()
        guard let captured else {
            throw CaptureFailure(
                kind: .providerIOFailed(
                    detail: "The coordinated read did not run on the I/O owner."),
                operation: "readOriginal")
        }
        return try captured.get()
    }
}
