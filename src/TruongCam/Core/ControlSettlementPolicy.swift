import Foundation

/// Decides when live control readings may be reported as settled.
///
/// REVIEW.md S06: the UI showed a single "applied" number with no distinction
/// between the desired value, the setter's acknowledgement, a live reading and a
/// converged value. Settling is decided from consecutive observations within bounded tolerances
/// inside a bounded window, and a non-converging device is reported as such rather
/// than being presented as settled.
struct ControlSettlementPolicy: Sendable {
    /// Fields compared to decide convergence. Only device-reported measurements
    /// are included: `exposureChoice`/`focusMode`/`whiteBalanceMode` are *intent*
    /// carried forward, so they can never prove the hardware settled.
    struct Observation: Hashable, Sendable {
        let durationSeconds: Double?
        let iso: Double?
        let exposureTargetOffset: Double?
        let focusPosition: Double?
        let redGain: Double?
        let greenGain: Double?
        let blueGain: Double?

        /// Rounded to a stable display/tolerance resolution so sensor noise does
        /// not prevent convergence forever.
        /// True when this observation contains at least one actual device
        /// measurement. An observation that is entirely nil must never be treated
        /// as agreement between readings: absence of data is not convergence.
        var hasAnyMeasurement: Bool {
            durationSeconds != nil || iso != nil || exposureTargetOffset != nil
                || focusPosition != nil || redGain != nil || greenGain != nil || blueGain != nil
        }

        func normalized() -> Observation {
            Observation(
                durationSeconds: Observation.round(durationSeconds, digits: 6),
                iso: Observation.round(iso, digits: 1),
                exposureTargetOffset: Observation.round(exposureTargetOffset, digits: 3),
                focusPosition: Observation.round(focusPosition, digits: 3),
                redGain: Observation.round(redGain, digits: 3),
                greenGain: Observation.round(greenGain, digits: 3),
                blueGain: Observation.round(blueGain, digits: 3))
        }

        /// Engineering convergence tolerances; the request target is still checked
        /// separately. Compare to the window anchor, so slow drift cannot accumulate.
        func isStable(comparedTo other: Observation) -> Bool {
            func close(_ a: Double?, _ b: Double?, relative: Double, absolute: Double) -> Bool {
                switch (a,b) {
                case (nil,nil): return true
                case let (a?,b?): return abs(a-b) <= max(absolute, abs(b)*relative)
                default: return false
                }
            }
            return close(durationSeconds,other.durationSeconds,relative:0.01,absolute:0.000001)
                && close(iso,other.iso,relative:0.01,absolute:0.1)
                && close(exposureTargetOffset,other.exposureTargetOffset,relative:0,absolute:0.05)
                && close(focusPosition,other.focusPosition,relative:0,absolute:0.005)
                && close(redGain,other.redGain,relative:0.01,absolute:0.001)
                && close(greenGain,other.greenGain,relative:0.01,absolute:0.001)
                && close(blueGain,other.blueGain,relative:0.01,absolute:0.001)
        }

        static func round(_ value: Double?, digits: Int) -> Double? {
            guard let value, value.isFinite else { return nil }
            let scale = pow(10.0, Double(digits))
            return (value * scale).rounded() / scale
        }

        init(snapshot: AppliedControlSnapshot) {
            durationSeconds = snapshot.observedDurationSeconds
            iso = snapshot.observedISO
            exposureTargetOffset = snapshot.observedExposureTargetOffset
            focusPosition = snapshot.focusPosition
            redGain = snapshot.whiteBalanceGains?.red
            greenGain = snapshot.whiteBalanceGains?.green
            blueGain = snapshot.whiteBalanceGains?.blue
        }

        init(durationSeconds: Double?, iso: Double?, exposureTargetOffset: Double?,
             focusPosition: Double?, redGain: Double?, greenGain: Double?, blueGain: Double?) {
            self.durationSeconds = durationSeconds
            self.iso = iso
            self.exposureTargetOffset = exposureTargetOffset
            self.focusPosition = focusPosition
            self.redGain = redGain
            self.greenGain = greenGain
            self.blueGain = blueGain
        }
    }

    /// How many consecutive observations within bounded tolerances are required.
    let requiredStableObservations: Int
    /// The maximum number of observations before reporting non-convergence.
    let observationBudget: Int

    init(requiredStableObservations: Int = 2, observationBudget: Int = 12) {
        self.requiredStableObservations = max(1, requiredStableObservations)
        self.observationBudget = max(self.requiredStableObservations, observationBudget)
    }
}

extension ControlSettlementPolicy {
    /// The values a specific request must reach.
    ///
    /// Only the fields the request actually asked for are constrained. A field the
    /// request did not ask for cannot substitute for one it did.
    struct Target: Hashable, Sendable {
        /// Requested exposure duration, when the request fixed one (manual shutter).
        var durationSeconds: Double?
        /// Requested ISO, when the request fixed one.
        var iso: Double?
        /// Requested focus position, when a focus move was requested.
        var focusPosition: Double?
        /// Requested white-balance gains, when a custom WB was requested.
        var redGain: Double?
        var greenGain: Double?
        var blueGain: Double?

        static let none = Target()

        var isEmpty: Bool {
            durationSeconds == nil && iso == nil && focusPosition == nil
                && redGain == nil && greenGain == nil && blueGain == nil
        }

        /// True when every REQUESTED field is present in the observation and within
        /// tolerance of the request.
        func isSatisfied(by observation: Observation) -> Bool {
            if let durationSeconds {
                guard let measured = observation.durationSeconds,
                      isClose(measured, durationSeconds) else { return false }
            }
            if let iso {
                guard let measured = observation.iso, isClose(measured, iso) else { return false }
            }
            if let focusPosition {
                guard let measured = observation.focusPosition,
                      isClose(measured, focusPosition) else { return false }
            }
            // White balance is a triple; all three requested components must match.
            if redGain != nil || greenGain != nil || blueGain != nil {
                guard let r = observation.redGain, let g = observation.greenGain,
                      let b = observation.blueGain else { return false }
                if let redGain, !isClose(r, redGain) { return false }
                if let greenGain, !isClose(g, greenGain) { return false }
                if let blueGain, !isClose(b, blueGain) { return false }
            }
            return true
        }

        /// Relative-plus-absolute tolerance, because exposure values span orders of
        /// magnitude. These are engineering tolerances, not device measurements.
        private func isClose(_ measured: Double, _ requested: Double) -> Bool {
            guard measured.isFinite, requested.isFinite else { return false }
            let difference = abs(measured - requested)
            return difference <= max(0.05 * abs(requested), 1e-4)
        }
    }
}

/// Accumulates observations for one control application.
///
/// Deliberately a value type with an explicit `mutating` step so the settle rule
/// is exercised by the portable verifier without a camera.
struct ControlSettlementTracker: Sendable {
    private let policy: ControlSettlementPolicy
    private var lastObservation: ControlSettlementPolicy.Observation?
    private var stableCount = 0
    private(set) var observationCount = 0
    private(set) var state: ControlSettlementState = .awaitingObservation

    init(policy: ControlSettlementPolicy = ControlSettlementPolicy()) {
        self.policy = policy
    }

    /// The target this tracker is confirming. Nil means "no specific request", which
    /// is only valid for a live display reading, never for a sequence baseline.
    private var target: ControlSettlementPolicy.Target?

    /// Binds the tracker to the request it must confirm.
    ///
    /// REVIEW.md G03: without a target, equality of two readings — however old —
    /// counted as completion. The target makes "settled" mean "the device reached what
    /// was asked for".
    mutating func setTarget(_ target: ControlSettlementPolicy.Target?) {
        self.target = target
        lastObservation = nil
        stableCount = 0
        state = .awaitingObservation
    }

    /// Feeds one live reading and returns the resulting state.
    ///
    /// REVIEW.md R03: two readings that were entirely absent used to "agree" and
    /// were reported as settled. A reading with no measurement is not evidence, so
    /// it can only ever leave the state unmeasured/moving.
    ///
    /// REVIEW.md G03: a reading must also SATISFY the bound target. A stable reading
    /// for a superseded request, or one that measures an unrelated field while the
    /// requested exposure fields are absent, is not completion.
    mutating func observe(_ snapshot: AppliedControlSnapshot) -> ControlSettlementState {
        observationCount += 1
        let observation = ControlSettlementPolicy.Observation(snapshot: snapshot).normalized()

        // The explicit target wins; otherwise the snapshot's own intent is used, so a
        // manual request can never be satisfied by an unrelated stable reading.
        let effectiveTarget = target ?? Self.target(from: snapshot)
        // A MANUAL focus mode asserts a specific lens position. If no target carries
        // that position, nothing has been confirmed, so stability alone cannot settle
        // it (H01). Auto/continuous focus has no endpoint and is handled below.
        if snapshot.focusMode == .manual, !snapshot.isFixedFocusCamera, effectiveTarget?.focusPosition == nil {
            lastObservation = nil
            stableCount = 0
            state = .moving
            return state
        }
        if let effectiveTarget, !effectiveTarget.isEmpty {
            guard effectiveTarget.isSatisfied(by: observation) else {
                lastObservation = nil
                stableCount = 0
                state = observation.hasAnyMeasurement
                    ? .moving
                    : .unmeasured(observations: observationCount)
                return state
            }
        }

        // H01: a device that reports itself as still adjusting has NOT converged,
        // whatever two consecutive readings happen to say. This flag is real device
        // evidence, so it is checked before stability is credited.
        if snapshot.isExposureAdjusting == true
            || snapshot.isFocusAdjusting == true
            || snapshot.isWhiteBalanceAdjusting == true {
            lastObservation = nil
            stableCount = 0
            state = .moving
            return state
        }

        guard observation.hasAnyMeasurement else {
            // The device reported nothing to compare. This is explicitly NOT
            // settled and NOT convergence; it resets any stability already counted
            // so a later real reading cannot inherit credit from absent ones.
            lastObservation = nil
            stableCount = 0
            state = .unmeasured(observations: observationCount)
            return state
        }

        if let lastObservation, observation.isStable(comparedTo: lastObservation) {
            stableCount += 1
        } else {
            lastObservation = observation
            stableCount = 1
        }
        if stableCount >= policy.requiredStableObservations {
            state = .settled
        } else if observationCount >= policy.observationBudget {
            state = .didNotSettle(observations: observationCount)
        } else {
            state = .moving
        }
        return state
    }

    /// Derives the target a snapshot's own intent pins.
    ///
    /// A manual choice pins BOTH duration and ISO; a priority choice pins one. Auto
    /// pins nothing, so an Auto reading is settled by convergence alone — which is the
    /// only thing that can be checked for a continuously adjusting device.
    static func target(from snapshot: AppliedControlSnapshot) -> ControlSettlementPolicy.Target? {
        let choice = snapshot.exposureChoice
        var target = ControlSettlementPolicy.Target()
        target.durationSeconds = choice.durationTargetSeconds
        target.iso = choice.isoTarget
        guard !target.isEmpty else { return nil }
        return target
    }

    /// Restarts the window, e.g. after a new setter request.
    mutating func restart() {
        lastObservation = nil
        stableCount = 0
        observationCount = 0
        state = .awaitingObservation
    }
}
