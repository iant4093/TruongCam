import Foundation

// CONTRACTS.md "Interval policy" + ARCHITECTURE.md "Interval shooting".
//
// These are pure deadline-arithmetic value types. They never sleep: the
// coordinator asks for the next eligible deadline and awaits the injected
// `MonotonicClock`, so the whole schedule is drivable by
// `VirtualMonotonicClock` with no real waiting.

/// The one visible monotonic deadline a timer countdown exposes.
struct CountdownDeadline: Hashable, Sendable {
    let originMonotonic: Double
    let delaySeconds: Double

    var deadlineMonotonic: Double { originMonotonic + delaySeconds }

    func remaining(now: Double) -> Double {
        max(0, deadlineMonotonic - now)
    }

    func hasElapsed(now: Double) -> Bool {
        now >= deadlineMonotonic
    }
}

/// Deadline schedule for one interval run.
///
/// Semantics, exactly (CONTRACTS.md "Interval policy"):
///   * the requested count means successfully acquired/committed ORIGINALS, not
///     timer ticks;
///   * the first source is eligible at the origin (Start / countdown completion);
///   * deadlines that elapse while the pipeline is busy are skipped and counted
///     separately from the source ordinal;
///   * after a delayed commit the next source waits for the next eligible
///     deadline, so there is never a catch-up burst;
///   * a complete run has exactly `plannedCount` committed sources even when it
///     skipped deadlines.
struct IntervalSchedule: Hashable, Sendable {
    /// Defensive bound so a pathological cadence cannot spin the skip loop.
    static let maximumSkippedDeadlinesPerAdvance = 1_000_000

    let originMonotonic: Double
    let intervalSeconds: Double
    let plannedCount: Int

    /// Deadline ordinal the next source will be attributed to.
    private(set) var nextDeadlineOrdinal: Int
    /// Successfully committed source count.
    private(set) var committedSourceCount: Int
    /// Deadlines that elapsed without a source while the pipeline was busy.
    private(set) var skippedDeadlineCount: Int
    /// Deadline ordinal actually used, in commit order.
    private(set) var usedDeadlineOrdinals: [Int]

    init(originMonotonic: Double, intervalSeconds: Double, plannedCount: Int) {
        self.originMonotonic = originMonotonic
        self.intervalSeconds = intervalSeconds
        self.plannedCount = max(0, plannedCount)
        self.nextDeadlineOrdinal = 0
        self.committedSourceCount = 0
        self.skippedDeadlineCount = 0
        self.usedDeadlineOrdinals = []
    }

    var isFinished: Bool { committedSourceCount >= plannedCount }

    /// A deadline may only be scheduled when the cadence is legal; validation
    /// guarantees a finite positive value before a run starts.
    var hasUsableCadence: Bool {
        intervalSeconds.isFinite && intervalSeconds > 0
    }

    func deadlineTime(forOrdinal ordinal: Int) -> Double {
        originMonotonic + Double(ordinal) * intervalSeconds
    }

    /// The monotonic instant at which the next source becomes eligible.
    var nextEligibleDeadlineTime: Double {
        deadlineTime(forOrdinal: nextDeadlineOrdinal)
    }

    /// Deadline ordinal that will be recorded for the source about to start.
    var currentDeadlineOrdinal: Int { nextDeadlineOrdinal }

    /// Marks one source committed at `now` and advances the cursor past every
    /// deadline that elapsed while it was busy.
    mutating func recordCommitted(now: Double) {
        guard !isFinished else { return }
        usedDeadlineOrdinals.append(nextDeadlineOrdinal)
        committedSourceCount += 1
        nextDeadlineOrdinal += 1
        advanceCursorPastElapsedDeadlines(now: now)
    }

    /// The number of deadlines that will be skipped if the next commit happens
    /// at `now`. Exposed for tests and diagnostics; does not mutate.
    func pendingSkipCount(ifCommittedAt now: Double) -> Int {
        guard hasUsableCadence else { return 0 }
        var ordinal = nextDeadlineOrdinal
        var skipped = 0
        var iterations = 0
        while deadlineTime(forOrdinal: ordinal) <= now,
              iterations < Self.maximumSkippedDeadlinesPerAdvance {
            skipped += 1
            ordinal += 1
            iterations += 1
        }
        return skipped
    }

    private mutating func advanceCursorPastElapsedDeadlines(now: Double) {
        guard hasUsableCadence else { return }
        var iterations = 0
        while deadlineTime(forOrdinal: nextDeadlineOrdinal) <= now,
              iterations < Self.maximumSkippedDeadlinesPerAdvance {
            skippedDeadlineCount += 1
            nextDeadlineOrdinal += 1
            iterations += 1
        }
    }
}

/// Snapshot of a running deadline schedule for progress reporting.
struct IntervalScheduleSnapshot: Hashable, Sendable {
    let nextEligibleDeadlineTime: Double
    let currentDeadlineOrdinal: Int
    let committedSourceCount: Int
    let skippedDeadlineCount: Int
    let usedDeadlineOrdinals: [Int]

    init(_ schedule: IntervalSchedule) {
        self.nextEligibleDeadlineTime = schedule.nextEligibleDeadlineTime
        self.currentDeadlineOrdinal = schedule.currentDeadlineOrdinal
        self.committedSourceCount = schedule.committedSourceCount
        self.skippedDeadlineCount = schedule.skippedDeadlineCount
        self.usedDeadlineOrdinals = schedule.usedDeadlineOrdinals
    }
}
