import Foundation

// ARCHITECTURE.md "Focus brackets" + CONTRACTS.md "Focus bracket policy".
//
// Per frame: set position → observe completion/readback with a timeout →
// acquire one RAW → await staging/commit → next. The settling watchdog is
// policy, not proof: it is duration-aware and never a magic fixed sleep. A
// timeout stops future frames and retains the partial sources.

/// Where a manual focus move currently stands.
enum FocusMoveState: Hashable, Sendable {
    case notStarted
    case adjusting
    case settled
    case failed(detail: String)

    var isSettled: Bool { self == .settled }
}

/// One focus readback. Position direction is unverified on device, so it is
/// reported as a normalized lens position and never as metres.
struct FocusSettleReadback: Hashable, Sendable {
    let position: Double?
    let state: FocusMoveState
    let provenance: ValueProvenance

    init(position: Double?, state: FocusMoveState, provenance: ValueProvenance) {
        self.position = position
        self.state = state
        self.provenance = provenance
    }
}

/// Injected focus control. The driver owns the timeout; this boundary only starts
/// a move and reports readbacks.
protocol FocusPositionControlling: Sendable {
    /// Starts moving to a normalized lens position. Returns once the request has
    /// been accepted, not once the lens has settled.
    func beginMove(to position: Double) async -> Result<Void, CaptureFailure>
    /// Latest readback, or nil when the device has not produced one yet.
    func readback() async -> FocusSettleReadback?
}

/// One focus-bracket frame: a requested position plus the frozen intent that
/// captures it.
struct FocusFrameRequest: Sendable {
    let ordinal: SourceOrdinal
    let requestedPosition: Double
    let longestPlannedDurationSeconds: Double
    let intent: CaptureIntent
}

/// Result of one focus-bracket frame, including the settled readback and its
/// provenance even when the frame could not be acquired.
struct FocusFrameOutcome: Sendable {
    let ordinal: SourceOrdinal
    let requestedPosition: Double
    let settledPosition: Double?
    let provenance: ValueProvenance
    let settleTimedOut: Bool
    let watchdogSeconds: Double
    let failure: CaptureFailure?
    let source: SequenceSourceOutcome?

    var didAcquire: Bool { source != nil }
}

actor FocusBracketDriver {
    private let clock: MonotonicClock
    private let controller: FocusPositionControlling
    private let pipeline: SequenceSourcePipeline
    private let policy: SequenceSettlementPolicy

    init(clock: MonotonicClock,
         controller: FocusPositionControlling,
         pipeline: SequenceSourcePipeline,
         policy: SequenceSettlementPolicy = SequenceSettlementPolicy()) {
        self.clock = clock
        self.controller = controller
        self.pipeline = pipeline
        self.policy = policy
    }

    /// Duration-aware settling watchdog: at least `max(5 s, 2 × longest planned
    /// duration + 1 s)`.
    func watchdogSeconds(longestPlannedDurationSeconds: Double) -> Double {
        policy.watchdogSeconds(longestPlannedDurationSeconds: longestPlannedDurationSeconds)
    }

    func runFrame(_ request: FocusFrameRequest,
                  cancellation: SequenceCancellationSignal,
                  observer: any SequencePhaseObserving) async -> FocusFrameOutcome {
        let watchdog = watchdogSeconds(
            longestPlannedDurationSeconds: request.longestPlannedDurationSeconds)

        func cancelledBeforeSubmission() -> FocusFrameOutcome {
            FocusFrameOutcome(ordinal: request.ordinal,
                requestedPosition: request.requestedPosition, settledPosition: nil,
                provenance: .unknown, settleTimedOut: false, watchdogSeconds: watchdog,
                failure: CaptureFailure(kind: .cancelled(detail: "Focus bracket cancelled before source submission"),
                    operation: "sequence.focusBracket.settle"), source: nil)
        }
        guard !cancellation.isRequested, !Task.isCancelled else { return cancelledBeforeSubmission() }

        switch await controller.beginMove(to: request.requestedPosition) {
        case .failure(let failure):
            return FocusFrameOutcome(ordinal: request.ordinal,
                                     requestedPosition: request.requestedPosition,
                                     settledPosition: nil,
                                     provenance: .unknown,
                                     settleTimedOut: false,
                                     watchdogSeconds: watchdog,
                                     failure: failure,
                                     source: nil)
        case .success:
            break
        }
        guard !cancellation.isRequested, !Task.isCancelled else { return cancelledBeforeSubmission() }

        let deadline = clock.now() + watchdog
        var settledPosition: Double?
        var settledProvenance: ValueProvenance = .unknown
        var timedOut = false
        var moveFailure: CaptureFailure?

        settleLoop: while true {
            if cancellation.isRequested || Task.isCancelled {
                return cancelledBeforeSubmission()
            }

            // Visible, cancellable settling state. The watchdog is policy, not
            // proof of settled focus.
            await observer.observe(phase: .settlingFocus(ordinal: request.ordinal.value,
                                                         watchdogSeconds: watchdog))
            guard !cancellation.isRequested, !Task.isCancelled else { return cancelledBeforeSubmission() }

            let readback = await controller.readback()
            guard !cancellation.isRequested, !Task.isCancelled else { return cancelledBeforeSubmission() }
            if let readback {
                switch readback.state {
                case .settled:
                    settledPosition = readback.position
                    settledProvenance = readback.provenance
                    break settleLoop
                case .failed(let detail):
                    moveFailure = CaptureFailure(
                        kind: .captureFailed(detail: "Manual focus did not settle: \(detail)"),
                        operation: "sequence.focusBracket.settle")
                    break settleLoop
                case .notStarted, .adjusting:
                    break
                }
            }

            if clock.now() >= deadline {
                timedOut = true
                break settleLoop
            }
            let sleepUntil = min(deadline, clock.now() + policy.safePollIntervalSeconds)
            try? await clock.sleep(until: sleepUntil)
        }

        guard !cancellation.isRequested, !Task.isCancelled else { return cancelledBeforeSubmission() }
        if let moveFailure {
            return FocusFrameOutcome(ordinal: request.ordinal,
                                     requestedPosition: request.requestedPosition,
                                     settledPosition: nil,
                                     provenance: .unknown,
                                     settleTimedOut: false,
                                     watchdogSeconds: watchdog,
                                     failure: moveFailure,
                                     source: nil)
        }

        if timedOut {
            // Stop before any illegal capture: no acquisition happens for a frame
            // whose focus never settled.
            return FocusFrameOutcome(
                ordinal: request.ordinal,
                requestedPosition: request.requestedPosition,
                settledPosition: nil,
                provenance: .unknown,
                settleTimedOut: true,
                watchdogSeconds: watchdog,
                failure: CaptureFailure(
                    kind: .operationStalled(
                        detail: "Manual focus did not settle within \(String(format: "%.2f", watchdog)) s"),
                    operation: "sequence.focusBracket.settle"),
                source: nil)
        }

        await observer.observe(phase: .capturing(ordinal: request.ordinal.value))
        guard !cancellation.isRequested, !Task.isCancelled else { return cancelledBeforeSubmission() }
        let source = await pipeline.run(request.intent)
        return FocusFrameOutcome(ordinal: request.ordinal,
                                 requestedPosition: request.requestedPosition,
                                 settledPosition: settledPosition,
                                 provenance: settledProvenance,
                                 settleTimedOut: false,
                                 watchdogSeconds: watchdog,
                                 failure: source.failure,
                                 source: source)
    }
}

/// Requested position plus last settled readback and its provenance, kept for
/// the sequence record.
struct FocusSettleRecord: Hashable, Sendable {
    let ordinal: Int
    let requestedPosition: Double
    let settledPosition: Double?
    let provenance: ValueProvenance
}
