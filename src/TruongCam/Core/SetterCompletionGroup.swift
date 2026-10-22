import CoreMedia
import Foundation
import Synchronization

/// Callback ownership for one native control application. A deadline ends its
/// observer's wait, not the outstanding native callbacks or their ownership.
final class SetterCompletionGroup: @unchecked Sendable {
    private struct State {
        var outstanding = 0
        var completed = false
        var timedOut = false
        var arrived = 0
        var lastDeviceTime: CMTime?
        var waiters: [UUID: CheckedContinuation<Bool, Never>] = [:]
    }
    // Callback, timeout, classification and waiter registration share one lock;
    // no timeout can be lost before registration or overwrite a winning arrival.
    private let mutex = Mutex(State())
    var arrived: Int { mutex.withLock { $0.arrived } }
    var isComplete: Bool { mutex.withLock { $0.completed } }
    var timedOut: Bool { mutex.withLock { $0.timedOut } }
    var lastDeviceTime: CMTime? { mutex.withLock { $0.lastDeviceTime } }
    #if DEBUG || TC_PORTABLE_VERIFIER
    var installedWaiterCount: Int { mutex.withLock { $0.waiters.count } }
    #endif

    func expectOne() {
        mutex.withLock { state in
            state.outstanding += 1
            state.completed = false
        }
    }
    func arrive() { arrive(atDeviceTime: nil) }
    func arrive(atDeviceTime time: CMTime?) {
        let waiters = mutex.withLock { state -> [CheckedContinuation<Bool, Never>] in
            state.arrived += 1
            if let time { state.lastDeviceTime = time }
            state.outstanding = max(0, state.outstanding - 1)
            guard state.outstanding == 0, !state.completed else { return [] }
            state.completed = true
            let waiting = Array(state.waiters.values)
            state.waiters.removeAll()
            return waiting
        }
        for waiter in waiters { waiter.resume(returning: true) }
    }

    @discardableResult
    func awaitAll(timeoutSeconds: Double) async -> Bool {
        await wait(timeoutSeconds: timeoutSeconds)
    }
    /// An unbounded observer continues to own its wait even if another observer
    /// times out. Late native callbacks still reconcile actual completion.
    func awaitAll() async { _ = await wait(timeoutSeconds: nil) }

    private func wait(timeoutSeconds: Double?) async -> Bool {
        let id = UUID()
        let timer = Mutex<Task<Void, Never>?>(nil)
        defer { timer.withLock { $0 }?.cancel() }
        return await withCheckedContinuation { continuation in
            let completed = mutex.withLock { state -> Bool in
                if timeoutSeconds != nil { state.timedOut = false }
                if state.completed || state.outstanding == 0 {
                    state.completed = true
                    return true
                }
                state.waiters[id] = continuation
                return false
            }
            if completed { continuation.resume(returning: true); return }
            guard let timeoutSeconds else { return }
            // Install the continuation before even an immediate deadline can run.
            // Invalid/overflowing timeouts fail boundedly instead of trapping.
            let safeSeconds = timeoutSeconds.isFinite ? max(0, timeoutSeconds) : 0
            let maximumSeconds = Double(UInt64.max / 1_000_000_000)
            let nanoseconds = UInt64(min(safeSeconds, maximumSeconds) * 1_000_000_000)
            let deadline = Task { [weak self] in
                do { try await Task.sleep(nanoseconds: nanoseconds) }
                catch { return }
                guard !Task.isCancelled else { return }
                self?.expire(id)
            }
            timer.withLock { $0 = deadline }
        }
    }
    private func expire(_ id: UUID) {
        let waiter = mutex.withLock { state -> CheckedContinuation<Bool, Never>? in
            guard let waiting = state.waiters.removeValue(forKey: id) else { return nil }
            state.timedOut = true
            return waiting
        }
        waiter?.resume(returning: false)
    }
}
