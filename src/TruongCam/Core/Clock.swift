import Foundation
import Synchronization

// CONTRACTS.md bounds handling and "Automatic bracket baseline settlement".
// Analysis and sequencing run on monotonic time. Wall-clock time is used only
// for provenance labeling, never for scheduling.

/// Monotonic time source, injectable so state machines can be tested with a
/// deterministic virtual clock (TEST_PLAN.md T25–T29).
protocol MonotonicClock: Sendable {
    /// Seconds from an arbitrary but strictly increasing origin.
    func now() -> Double
    /// Suspends until the given monotonic instant, or until cancelled.
    func sleep(until instant: Double) async throws
}

/// Production clock based on `DispatchTime` uptime, which does not jump when the
/// user changes the wall clock.
struct SystemMonotonicClock: MonotonicClock {
    private let origin: DispatchTime

    init() { origin = DispatchTime.now() }

    func now() -> Double {
        let delta = DispatchTime.now().uptimeNanoseconds &- origin.uptimeNanoseconds
        return Double(delta) / 1_000_000_000
    }

    func sleep(until instant: Double) async throws {
        let delta = instant - now()
        guard delta > 0 else { return }
        let nanoseconds = UInt64(min(delta, 86_400) * 1_000_000_000)
        try await Task.sleep(nanoseconds: nanoseconds)
    }
}

/// Deterministic clock for tests. Time only moves when the test advances it.
///
/// Uses `Synchronization.Mutex` so the waiter registration inside the async
/// continuation is legal under Swift 6's "no locks across suspension points"
/// diagnostic. The lock is never held across an `await`.
final class VirtualMonotonicClock: MonotonicClock, Sendable {
    private struct Waiter {
        let deadline: Double
        let continuation: CheckedContinuation<Void, Error>
    }

    private struct State {
        var now: Double
        var waiters: [Waiter]
    }

    private let mutex = Mutex<State>(State(now: 0, waiters: []))

    init(start: Double = 0) {
        mutex.withLock { $0.now = start }
    }

    func now() -> Double {
        mutex.withLock { $0.now }
    }

    /// Advances the virtual clock and resumes every waiter whose deadline passed.
    func advance(by seconds: Double) {
        advance(to: now() + seconds)
    }

    func advance(to instant: Double) {
        let due: [Waiter] = mutex.withLock { state in
            state.now = max(state.now, instant)
            let ready = state.waiters.filter { $0.deadline <= state.now }
            state.waiters.removeAll { $0.deadline <= state.now }
            return ready
        }
        for waiter in due { waiter.continuation.resume() }
    }

    /// Number of coroutines currently parked on this clock.
    var pendingWaiterCount: Int {
        mutex.withLock { $0.waiters.count }
    }

    func sleep(until instant: Double) async throws {
        let alreadyDue = mutex.withLock { instant <= $0.now }
        if alreadyDue { return }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            mutex.withLock { $0.waiters.append(Waiter(deadline: instant, continuation: continuation)) }
        }
    }
}

/// Wall-clock abstraction. Used for captured-at timestamps, sidecars and
/// human-readable UI, never for deadlines.
protocol WallClock: Sendable {
    func now() -> Date
    var timeZone: TimeZone { get }
    var calendar: Calendar { get }
}

struct SystemWallClock: WallClock {
    func now() -> Date { Date() }
    var timeZone: TimeZone { TimeZone.current }
    var calendar: Calendar { Calendar.current }
}

struct FixedWallClock: WallClock {
    let instant: Date
    let timeZone: TimeZone
    let calendar: Calendar

    init(instant: Date, timeZone: TimeZone = TimeZone(identifier: "UTC")!) {
        self.instant = instant
        self.timeZone = timeZone
        var c = Calendar(identifier: .gregorian)
        c.timeZone = timeZone
        self.calendar = c
    }

    func now() -> Date { instant }
}

/// Converts a capture-clock `CMTime`-style timestamp into wall-clock time using a
/// measured offset. CONTRACTS.md forbids treating CMTime seconds as Unix time.
struct CaptureClockConverter: Sendable {
    /// Wall-clock instant paired with the monotonic reading taken at the same
    /// moment during session start.
    let wallAnchor: Date
    let monotonicAnchor: Double

    func wallClockTime(forCaptureClockSeconds seconds: Double) -> Date {
        wallAnchor.addingTimeInterval(seconds - monotonicAnchor)
    }
}
