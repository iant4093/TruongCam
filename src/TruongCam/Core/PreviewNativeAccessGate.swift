import Foundation
import Synchronization

/// A native graph operation first crosses MainActor, after any synchronous
/// preview work already running there. All later preview calls see the pause
/// before the session queue starts. Release never waits for the main thread.
/// Overlapping/stale operations hold independent leases, so one cannot reopen
/// access while another still owns native work. Analysis callbacks borrow a
/// short read lease; production graph work also asynchronously drains those
/// reads before touching the session. This is not capture admission.
final class PreviewNativeAccessGate: Sendable {
    struct Snapshot: Equatable, Sendable {
        let pauseCount: Int
        let revision: UInt64
        let frameReadCount: Int
        let waitingDrainCount: Int
        var isPaused: Bool { pauseCount > 0 }
    }
    private struct State: Sendable {
        var count = 0
        var revision: UInt64 = 0
        var frameReads = 0
        var drainWaiters: [CheckedContinuation<Void, Never>] = []
    }
    private let state = Mutex(State())
    var snapshot: Snapshot { state.withLock { Snapshot(pauseCount: $0.count, revision: $0.revision,
        frameReadCount: $0.frameReads, waitingDrainCount: $0.drainWaiters.count) } }

    @MainActor func pause() -> Lease {
        state.withLock { $0.count += 1 }
        return Lease(gate: self)
    }

    /// Pausing precedes the wait, so no later sample can enter the borrowed
    /// buffer path. Waiting suspends the caller; it never blocks MainActor or
    /// the serial analysis queue. A callback must release its read synchronously
    /// before returning and must never await graph work while holding it.
    @MainActor func pauseAndDrainFrames() async -> Lease {
        let lease = pause()
        #if DEBUG
        let readsAtPause = snapshot.frameReadCount
        let began = ProcessInfo.processInfo.systemUptime
        #endif
        await withCheckedContinuation { continuation in
            let drained = state.withLock { value in
                if value.frameReads == 0 { return true }
                value.drainWaiters.append(continuation)
                return false
            }
            if drained { continuation.resume() }
        }
        #if DEBUG
        if readsAtPause > 0 {
            print("TruongCam timing analysis-read-drain=\(Int((ProcessInfo.processInfo.systemUptime - began) * 1000))ms reads=\(readsAtPause)")
        }
        #endif
        return lease
    }

    /// Called only around the synchronous video sample callback. An already
    /// paused graph drops that sample before any pixel-buffer lock or still copy.
    func beginFrameRead() -> FrameReadLease? {
        let admitted = state.withLock { value in
            guard value.count == 0 else { return false }
            value.frameReads += 1
            return true
        }
        return admitted ? FrameReadLease(gate: self) : nil
    }

    private func finishFrameRead() {
        let waiters = state.withLock { value in
            value.frameReads -= 1
            guard value.frameReads == 0 else { return [CheckedContinuation<Void, Never>]() }
            let ready = value.drainWaiters
            value.drainWaiters.removeAll(keepingCapacity: true)
            return ready
        }
        // No continuation resumes under the gate lock.
        for waiter in waiters { waiter.resume() }
    }

    private func resume() {
        state.withLock { $0.count -= 1 }
    }

    /// Only a real native mutation invalidates cached connection bindings. A
    /// no-op analysis-demand update must not create a geometry feedback loop.
    func noteNativeMutation() { state.withLock { $0.revision &+= 1 } }

    final class FrameReadLease: Sendable {
        private let gate: PreviewNativeAccessGate
        private let released = Mutex(false)
        fileprivate init(gate: PreviewNativeAccessGate) { self.gate = gate }
        func release() {
            let first = released.withLock { value in
                if value { return false }
                value = true
                return true
            }
            if first { gate.finishFrameRead() }
        }
        deinit { release() }
    }

    final class Lease: Sendable {
        private let gate: PreviewNativeAccessGate
        private let released = Mutex(false)
        fileprivate init(gate: PreviewNativeAccessGate) { self.gate = gate }
        func release() {
            let first = released.withLock { value in
                if value { return false }
                value = true
                return true
            }
            if first { gate.resume() }
        }
        deinit { release() }
    }
}
