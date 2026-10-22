import Foundation

/// Owns the teardown gate for already-submitted work.
///
/// U02: this is the PRODUCTION component the service uses, moved into Core so the registered
/// suite executes the real gate rather than a mirror of its arithmetic. A request is counted
/// from submission until its native terminal is reported, and its retained staging is counted
/// from the moment the retained drain registers until it finishes — so there is no
/// terminal-to-staging gap in which a teardown could destroy the graph.
///
/// The counts live behind a lock because the retained drain reports from outside the actor
/// that owns the service.
final class SubmissionDrainGate: @unchecked Sendable {
    enum Outcome: Equatable, Sendable {
        /// Every submitted request has reported its native terminal AND its staging.
        case drained
        /// Time was exhausted with work still outstanding. The count is REAL.
        case outstanding(count: Int)
    }

    /// Per-request obligations. A submitted request owes BOTH a native terminal and its
    /// retained staging, so the terminal alone cannot drain it.
    private struct Obligations {
        var awaitingNative: Bool
        var awaitingStaging: Bool
    }

    private let lock = NSLock()
    private var obligations: [CaptureID: Obligations] = [:]
    private var drainWaiters = 0

    /// Actual reconciliation waits currently executing, for coordination diagnostics.
    var activeDrainWaitCount: Int {
        lock.lock(); defer { lock.unlock() }
        return drainWaiters
    }

    private func noteDrainWait(started: Bool) {
        lock.lock(); defer { lock.unlock() }
        drainWaiters += started ? 1 : -1
    }

    init() {}

    /// A request has been submitted. Counted until `noteTerminal`.
    func noteSubmitted(_ captureID: CaptureID) {
        lock.lock()
        obligations[captureID] = Obligations(awaitingNative: true, awaitingStaging: true)
        lock.unlock()
    }

    /// The native terminal was reported. The request is still counted while its retained
    /// staging runs, which is why staging is tracked separately rather than inferred.
    func noteTerminal(_ captureID: CaptureID) {
        lock.lock()
        // The native obligation is met, but the STAGING obligation is not: the request stays
        // outstanding, so a late staging registration cannot reopen an already-drained gate.
        if var existing = obligations[captureID] {
            existing.awaitingNative = false
            obligations[captureID] = existing
        }
        lock.unlock()
    }

    /// Resolves a request that legitimately owes NO retained source (failed before
    /// submission, or explicitly no-source), so it cannot leak a permanent fence.
    func noteNoSource(_ captureID: CaptureID) {
        lock.lock(); obligations.removeValue(forKey: captureID); lock.unlock()
    }

    /// Retained staging for `captureID` has begun.
    func noteStagingStarted(_ captureID: CaptureID) {
        lock.lock()
        // Late staging RE-STATES the obligation rather than reopening a drained request: if
        // the record is gone the request was already fully resolved, and a new obligation is
        // recorded so the work is never silently lost.
        var existing = obligations[captureID] ?? Obligations(
            awaitingNative: false, awaitingStaging: true)
        existing.awaitingStaging = true
        obligations[captureID] = existing
        lock.unlock()
    }

    /// Retained staging for `captureID` has finished. Balanced, so a repeat cannot underflow
    /// the work into a false clean drain.
    func noteStagingFinished(_ captureID: CaptureID) {
        lock.lock()
        if var existing = obligations[captureID] {
            existing.awaitingStaging = false
            if existing.awaitingNative {
                obligations[captureID] = existing
            } else {
                obligations.removeValue(forKey: captureID)
            }
        }
        lock.unlock()
    }

    /// Work still outstanding: submitted-but-not-terminal PLUS retained staging.
    var outstandingCount: Int {
        lock.lock(); defer { lock.unlock() }
        return obligations.count
    }

    var isDrained: Bool { outstandingCount == 0 }

    /// What a reset/teardown boundary may conclude from a drain result.
    enum Disposition: Equatable, Sendable {
        /// Nothing is outstanding: the rebuild may proceed as clean recovery.
        case cleanRecovery
        /// Work is still outstanding: recovery is BLOCKED and the count is disclosed.
        case blockedByOutstanding(count: Int)
    }

    /// Maps a drain result to the reset disposition. The ONLY way to reach clean recovery is
    /// a genuinely drained gate.
    static func disposition(for outcome: Outcome) -> Disposition {
        switch outcome {
        case .drained: return .cleanRecovery
        case .outstanding(let count): return .blockedByOutstanding(count: count)
        }
    }

    /// The contract's duration-aware bound: max(5s, 2 x longest planned + 1s).
    static func teardownBound(longestPlannedSeconds: Double) -> Double {
        max(5.0, 2 * max(0, longestPlannedSeconds) + 1)
    }

    /// Waits, bounded, for every submitted obligation to settle, and reports the TRUTH.
    ///
    /// X02: this is the shipping reconciliation loop. It polls the gate (not a helper's own
    /// arithmetic) and returns `outstanding(count:)` with the real count when the deadline
    /// expires, so a timed-out teardown cannot masquerade as clean recovery.
    func awaitDrain(
        longestPlannedSeconds: Double = 0,
        pollIntervalNanoseconds: UInt64 = 20_000_000,
        // Date is the injectable interval carrier, not a provenance timestamp.
        // The production deadline uses uptime so wall-clock changes cannot extend it.
        now: @Sendable () -> Date = { Date(timeIntervalSince1970: ProcessInfo.processInfo.systemUptime) }
    ) async -> Outcome {
        noteDrainWait(started: true)
        defer { noteDrainWait(started: false) }
        let deadline = now().addingTimeInterval(Self.teardownBound(
            longestPlannedSeconds: longestPlannedSeconds))
        while !isDrained, now() < deadline {
            try? await Task.sleep(nanoseconds: pollIntervalNanoseconds)
        }
        return outcome()
    }

    func outcome() -> Outcome {
        let count = outstandingCount
        return count == 0 ? .drained : .outstanding(count: count)
    }
}
