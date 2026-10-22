import Foundation

// CONTRACTS.md "Automatic bracket baseline settlement" + ARCHITECTURE.md
// "Focus brackets" and "Interval shooting".
//
// All tolerances below are injectable policy values, not device guarantees and
// not measurements of any camera. The settler never reads a device itself: the
// readbacks arrive through `BaselineSampling`.

/// Duration-aware settling policy shared by baseline settlement and the focus
/// bracket driver.
///
/// CONTRACTS.md: the short-exposure control-settling watchdog is 5 s, and any
/// exposure-related wait must allow at least
/// `max(5 s, 2 × longest selected/planned duration + 1 s)`. A legal long
/// exposure must never be rejected because a fixed 5 s timeout was too short.
struct SequenceSettlementPolicy: Hashable, Sendable {
    var minimumWatchdogSeconds: Double = 5
    var watchdogDurationMultiplier: Double = 2
    var watchdogFixedAllowanceSeconds: Double = 1
    // Active sequence measurement is independent of the 4-Hz UI readout.
    // Five real observations need not incur a full second of polling gaps.
    var readbackPollIntervalSeconds: Double = 0.05

    func watchdogSeconds(longestPlannedDurationSeconds: Double) -> Double {
        let duration = longestPlannedDurationSeconds.isFinite
            ? max(0, longestPlannedDurationSeconds)
            : 0
        return max(minimumWatchdogSeconds,
                   watchdogDurationMultiplier * duration + watchdogFixedAllowanceSeconds)
    }

    /// Never zero, so a poll loop cannot spin.
    var safePollIntervalSeconds: Double {
        max(0.01, readbackPollIntervalSeconds)
    }
}

/// One consistent control readback used for stability proof.
struct BaselineReadback: Hashable, Sendable {
    /// Maps a readback's settlement to the provenance it may honestly claim.
    ///
    /// Only a converged reading is `settledDeviceReadback`; anything else is at best
    /// a requested/observed value (REVIEW.md G03).
    static func provenance(for settlement: ControlSettlementState) -> ValueProvenance {
        settlement.isSettled ? .settledDeviceReadback : .requested
    }

    let monotonicSeconds: Double
    /// Identity of the MEASUREMENT this reading came from (configuration generation,
    /// request revision and the device's own acquisition time). Distinct polls of one
    /// cached value share an identity; genuinely new observations do not
    /// (REVIEW.md I01).
    let measurementIdentity: MeasurementIdentity?
    let isExposureAdjusting: Bool?
    let isFocusAdjusting: Bool?
    let isWhiteBalanceAdjusting: Bool?
    let durationSeconds: Double?
    let iso: Double?
    let focusPosition: Double?
    let whiteBalanceGains: WhiteBalanceGains?
    let provenance: ValueProvenance

    /// Identity of one measurement on the device.
    struct MeasurementIdentity: Hashable, Sendable {
        let generationValue: UInt64
        let requestRevision: UInt64?
        /// The device's own acquisition time, which is what makes an observation fresh.
        let sourceTimestamp: Date?
    }

    init(monotonicSeconds: Double,
         measurementIdentity: MeasurementIdentity? = nil,
         isExposureAdjusting: Bool? = nil,
         isFocusAdjusting: Bool? = nil,
         isWhiteBalanceAdjusting: Bool? = nil,
         durationSeconds: Double? = nil,
         iso: Double? = nil,
         focusPosition: Double? = nil,
         whiteBalanceGains: WhiteBalanceGains? = nil,
         provenance: ValueProvenance = .settledDeviceReadback) {
        self.monotonicSeconds = monotonicSeconds
        self.measurementIdentity = measurementIdentity
        self.isExposureAdjusting = isExposureAdjusting
        self.isFocusAdjusting = isFocusAdjusting
        self.isWhiteBalanceAdjusting = isWhiteBalanceAdjusting
        self.durationSeconds = durationSeconds
        self.iso = iso
        self.focusPosition = focusPosition
        self.whiteBalanceGains = whiteBalanceGains
        self.provenance = provenance
    }

    var exposureProduct: Double? {
        guard let durationSeconds, let iso, durationSeconds > 0, iso > 0 else { return nil }
        return durationSeconds * iso
    }
}

/// Supplied by the camera layer. Returns nil when no readback is available yet.
protocol BaselineSampling: Sendable {
    func readback() async -> BaselineReadback?
}

/// Which parameters must be proven stable. Fields that are not relevant or not
/// supported are not required.
struct BaselineSettlementRequirements: OptionSet, Hashable, Sendable {
    let rawValue: Int

    init(rawValue: Int) { self.rawValue = rawValue }

    static let exposure = BaselineSettlementRequirements(rawValue: 1 << 0)
    static let focus = BaselineSettlementRequirements(rawValue: 1 << 1)
    static let whiteBalance = BaselineSettlementRequirements(rawValue: 1 << 2)

    static let exposureOnly: BaselineSettlementRequirements = [.exposure]
}

/// Result of applying the tolerances to the current sample window.
struct BaselineStabilityReport: Hashable, Sendable {
    let sampleCount: Int
    let indicatorsStopped: Bool
    let exposureProductVariationEV: Double?
    let focusPositionSpread: Double?
    let whiteBalanceGainRelativeSpread: Double?
    let unmetChecks: [String]

    var isStable: Bool { unmetChecks.isEmpty }

    var summary: String {
        if isStable { return "stable over \(sampleCount) readbacks" }
        return unmetChecks.joined(separator: "; ")
    }
}

enum BaselineSettlementIntent: Hashable, Sendable {
    /// Freeze the settled readings as numeric duration/ISO so every bracket
    /// source shares one consistent exposure.
    case freezeNumeric
    /// Keep the chosen Auto mode and snapshot each source's own readings instead
    /// of pretending a numeric exposure was frozen.
    case retainAutomatic
}

struct BaselineSettlementRequest: Hashable, Sendable {
    let sequenceID: SequenceID
    let intent: BaselineSettlementIntent
    let requirements: BaselineSettlementRequirements
    let longestPlannedDurationSeconds: Double
    let fallbackExposure: ExposureChoice
    let fallbackFocus: FocusIntent
    let fallbackWhiteBalance: WhiteBalanceIntent
    let maxDimensions: PixelDimensions
    /// The settled baseline already in force, when the plan was built from a
    /// manual selection instead of automatic parameters.
    let explicitBaseline: ExposureBaseline?
}

/// Why baseline settlement stopped.
enum BaselineSettlementFailure: Error, Hashable, Sendable, CustomStringConvertible {
    case cancelled
    case unsettled(reason: String, samplesObserved: Int, lastReport: BaselineStabilityReport?)
    case readbackUnavailable(reason: String, samplesObserved: Int)
    case notSupported(reason: String)

    /// A stability timeout must suggest Manual rather than silently freezing
    /// arbitrary stale readings.
    var suggestsManual: Bool {
        switch self {
        case .unsettled: return true
        case .cancelled, .readbackUnavailable, .notSupported: return false
        }
    }

    var samplesObserved: Int {
        switch self {
        case .cancelled, .notSupported: return 0
        case .unsettled(_, let samples, _): return samples
        case .readbackUnavailable(_, let samples): return samples
        }
    }

    var description: String {
        switch self {
        case .cancelled:
            return "Baseline settlement was cancelled."
        case .unsettled(let reason, let samples, let report):
            let detail = report.map { " Last window: \($0.summary)." } ?? ""
            return "Baseline did not settle after \(samples) readbacks (\(reason)).\(detail) "
                + "Set the parameter to Manual to choose a fixed value."
        case .readbackUnavailable(let reason, let samples):
            return "No usable control readback arrived during baseline settlement "
                + "(\(samples) samples; \(reason))."
        case .notSupported(let reason):
            return "Baseline settlement is not supported here: \(reason)"
        }
    }

    /// Maps onto the normalized product failure vocabulary.
    var captureFailure: CaptureFailure {
        switch self {
        case .cancelled:
            return CaptureFailure(kind: .cancelled(detail: "Baseline settlement cancelled"),
                                  operation: "sequence.baselineSettlement")
        case .unsettled, .readbackUnavailable:
            return CaptureFailure(kind: .operationStalled(detail: description),
                                  operation: "sequence.baselineSettlement")
        case .notSupported:
            return CaptureFailure(kind: .unsupportedCapability(detail: description),
                                  operation: "sequence.baselineSettlement")
        }
    }
}

/// Injectable baseline settlement, so the coordinator never touches a device.
protocol SequenceBaselineSettling: Sendable {
    func settle(_ request: BaselineSettlementRequest,
                cancellation: SequenceCancellationSignal) async -> Result<SequenceBaselineSnapshot,
                                                                         BaselineSettlementFailure>
}

/// Policy tolerances. Initial engineering policy, refined only with recorded
/// evidence.
struct BaselineSettlementPolicy: Hashable, Sendable {
    var settlement: SequenceSettlementPolicy = SequenceSettlementPolicy()
    var requiredConsecutiveStableSamples: Int = 5
    /// Total exposure-product (duration × ISO) variation across the window.
    var maxExposureProductVariationEV: Double = 1.0 / 6.0
    /// Focus-position spread across the window.
    var maxFocusPositionSpread: Double = 0.01
    /// Per-channel WB gain spread, relative to the window mean.
    var maxWhiteBalanceGainRelativeSpread: Double = 0.02

    static let initial = BaselineSettlementPolicy()
}

actor BaselineSettler: SequenceBaselineSettling {
    private let clock: MonotonicClock
    private let sampler: BaselineSampling
    private let policy: BaselineSettlementPolicy

    init(clock: MonotonicClock,
         sampler: BaselineSampling,
         policy: BaselineSettlementPolicy = .initial) {
        self.clock = clock
        self.sampler = sampler
        self.policy = policy
    }

    func settle(_ request: BaselineSettlementRequest,
                cancellation: SequenceCancellationSignal) async -> Result<SequenceBaselineSnapshot,
                                                                         BaselineSettlementFailure> {
        let watchdog = policy.settlement.watchdogSeconds(
            longestPlannedDurationSeconds: request.longestPlannedDurationSeconds)
        let deadline = clock.now() + watchdog
        let pollInterval = policy.settlement.safePollIntervalSeconds
        let windowSize = max(1, policy.requiredConsecutiveStableSamples)

        var window: [BaselineReadback] = []
        var samplesObserved = 0
        var lastReport: BaselineStabilityReport?
        #if DEBUG
        let began = clock.now()
        defer {
            print("TruongCam timing sequence-baseline=\(Int((clock.now() - began) * 1000))ms samples=\(samplesObserved) sequence=\(request.sequenceID) report=\(lastReport?.summary ?? "no readback")")
        }
        #endif

        while true {
            if cancellation.isRequested || Task.isCancelled {
                return .failure(.cancelled)
            }
            let now = clock.now()
            if now > deadline {
                if samplesObserved == 0 {
                    return .failure(.readbackUnavailable(
                        reason: "no readback arrived before the \(format(seconds: watchdog)) s watchdog",
                        samplesObserved: samplesObserved))
                }
                return .failure(.unsettled(
                    reason: "the \(format(seconds: watchdog)) s duration-aware watchdog expired",
                    samplesObserved: samplesObserved,
                    lastReport: lastReport))
            }

            if let sample = await sampler.readback() {
                samplesObserved += 1
                window.append(sample)
                if window.count > windowSize {
                    window.removeFirst(window.count - windowSize)
                }
                let report = Self.stabilityReport(window: window,
                                                  requirements: request.requirements,
                                                  policy: policy)
                lastReport = report
                if report.isStable {
                    return .success(Self.snapshot(request: request,
                                                  window: window,
                                                  requirements: request.requirements))
                }
            }

            let nextPoll = clock.now() + pollInterval
            let sleepUntil = min(deadline, nextPoll)
            if sleepUntil > clock.now() {
                try? await clock.sleep(until: sleepUntil)
            } else {
                // The watchdog deadline has passed; loop once so the timeout path
                // reports the observed samples instead of spinning.
                return .failure(samplesObserved == 0
                    ? .readbackUnavailable(reason: "the watchdog expired", samplesObserved: samplesObserved)
                    : .unsettled(reason: "the duration-aware watchdog expired",
                                 samplesObserved: samplesObserved,
                                 lastReport: lastReport))
            }
        }
    }

    private func format(seconds: Double) -> String {
        String(format: "%.2f", seconds)
    }

    // MARK: - Tolerances

    static func stabilityReport(window: [BaselineReadback],
                                requirements: BaselineSettlementRequirements,
                                policy: BaselineSettlementPolicy) -> BaselineStabilityReport {
        var unmet: [String] = []

        // CONTRACTS.md requires five *consecutive* readbacks: a single quiet
        // sample is not stability proof.
        if window.count < policy.requiredConsecutiveStableSamples {
            unmet.append("only \(window.count) of \(policy.requiredConsecutiveStableSamples) "
                + "consecutive readbacks")
        }

        // I01: the window must contain genuinely DISTINCT measurements. Five polls of
        // one cached applied snapshot share a measurement identity, so they are one
        // observation repeated — not the five consecutive readbacks CONTRACTS.md
        // requires. A reading with no identity cannot prove freshness either.
        // The check applies to readings that CARRY an identity: the production sampler
        // always supplies one, so a repeated poll of one cached snapshot is caught. A
        // synthetic window built directly by a fixture carries none, and is judged by
        // the remaining rules rather than being rejected for a field it never had.
        let identified = window.compactMap(\.measurementIdentity)
        if !window.isEmpty {
            // K01: EVERY reading must be identified. A missing identity is a defect in the
            // window, not a reason to stop checking.
            if identified.count != window.count {
                unmet.append("only \(identified.count) of \(window.count) readbacks carried "
                    + "a measurement identity; an unidentifiable reading cannot prove freshness")
            }
            let distinctIdentities = Set(identified)
            if distinctIdentities.count < policy.requiredConsecutiveStableSamples {
                unmet.append("only \(distinctIdentities.count) of "
                    + "\(policy.requiredConsecutiveStableSamples) readbacks came from distinct "
                    + "measurements; the rest repeat one cached observation")
            }
            // K01: correlation. An absent application revision means the window cannot be
            // tied to ONE application, so it cannot authorize a baseline. This is what
            // rejected the `all requestRevision=nil` window.
            if identified.contains(where: { $0.requestRevision == nil }) {
                unmet.append("some readbacks carry no application revision, so the window "
                    + "cannot be correlated to one application")
            }
            // J01: the window must describe ONE configuration and ONE application
            // revision. Five distinct measurements spanning five revisions is a MIXED
            // window: it spans an application change, so it cannot prove that any single
            // configuration was stable.
            let generations = Set(identified.map(\.generationValue))
            let revisions = Set(identified.map { $0.requestRevision })
            if generations.count > 1 || revisions.count > 1 {
                unmet.append("the readbacks span \(generations.count) configuration "
                    + "generation(s) and \(revisions.count) application revision(s); a "
                    + "baseline must be measured within one consistent revision")
            }
        }

        // H01: a window of `requested` (unconverged) readings proves nothing. Requiring
        // actually-converged observations is what stops repeated polls of one cached
        // moving acknowledgement from being read as stability.
        let converged = window.filter { $0.provenance == .settledDeviceReadback }
        if converged.count < policy.requiredConsecutiveStableSamples {
            unmet.append("only \(converged.count) of \(policy.requiredConsecutiveStableSamples) "
                + "readbacks were actually converged observations; the rest were mere requests")
        }

        var indicatorsStopped = true
        for sample in window {
            if sample.isExposureAdjusting == true
                || sample.isFocusAdjusting == true
                || sample.isWhiteBalanceAdjusting == true {
                indicatorsStopped = false
                break
            }
        }
        if !indicatorsStopped {
            let exposure = window.filter { $0.isExposureAdjusting == true }.count
            let focus = window.filter { $0.isFocusAdjusting == true }.count
            let wb = window.filter { $0.isWhiteBalanceAdjusting == true }.count
            unmet.append("native adjusting indicators are still active (exposure=\(exposure), focus=\(focus), WB=\(wb) of \(window.count))")
        }

        var exposureVariation: Double?
        if requirements.contains(.exposure) {
            let products = window.compactMap(\.exposureProduct)
            if let smallest = products.min(), let largest = products.max(),
               smallest > 0, products.count == max(window.count, 1) {
                let ev = log2(largest / smallest)
                exposureVariation = ev
                if ev > policy.maxExposureProductVariationEV + 1e-12 {
                    unmet.append(String(format: "exposure product varies %.4f EV", ev))
                }
            } else {
                unmet.append("exposure readback (duration and ISO) is incomplete")
            }
        }

        var focusSpread: Double?
        if requirements.contains(.focus) {
            let positions = window.compactMap(\.focusPosition)
            if let smallest = positions.min(), let largest = positions.max(),
               positions.count == max(window.count, 1) {
                let spread = largest - smallest
                focusSpread = spread
                if spread > policy.maxFocusPositionSpread + 1e-12 {
                    unmet.append(String(format: "focus position spread %.5f", spread))
                }
            } else {
                unmet.append("focus-position readback is incomplete")
            }
        }

        var whiteBalanceSpread: Double?
        if requirements.contains(.whiteBalance) {
            let gains = window.compactMap(\.whiteBalanceGains)
            if gains.count == max(window.count, 1) {
                let worst = max(
                    channelRelativeSpread(gains.map(\.red)),
                    channelRelativeSpread(gains.map(\.green)),
                    channelRelativeSpread(gains.map(\.blue)))
                whiteBalanceSpread = worst
                if worst > policy.maxWhiteBalanceGainRelativeSpread + 1e-12 {
                    unmet.append(String(format: "white-balance gain spread %.4f", worst))
                }
            } else {
                unmet.append("white-balance gain readback is incomplete")
            }
        }

        return BaselineStabilityReport(
            sampleCount: window.count,
            indicatorsStopped: indicatorsStopped,
            exposureProductVariationEV: exposureVariation,
            focusPositionSpread: focusSpread,
            whiteBalanceGainRelativeSpread: whiteBalanceSpread,
            unmetChecks: unmet)
    }

    private static func channelRelativeSpread(_ values: [Double]) -> Double {
        guard let smallest = values.min(), let largest = values.max() else { return 0 }
        let mean = values.reduce(0, +) / Double(values.count)
        guard mean > 0 else { return 0 }
        return (largest - smallest) / mean
    }

    // MARK: - Snapshot

    static func snapshot(request: BaselineSettlementRequest,
                         window: [BaselineReadback],
                         requirements: BaselineSettlementRequirements) -> SequenceBaselineSnapshot {
        let reference = window.last
        let referenceProvenance = reference?.provenance ?? .unknown

        let exposure: ExposureChoice
        let exposureProvenance: ValueProvenance
        switch request.intent {
        case .freezeNumeric:
            if let duration = reference?.durationSeconds, let iso = reference?.iso,
               duration.isFinite, duration > 0, iso.isFinite, iso > 0 {
                exposure = .manual(durationSeconds: duration, iso: iso)
                exposureProvenance = referenceProvenance
            } else if let explicit = request.explicitBaseline {
                exposure = .manual(durationSeconds: explicit.durationSeconds, iso: explicit.iso)
                exposureProvenance = explicit.provenance
            } else {
                exposure = request.fallbackExposure
                exposureProvenance = .requested
            }
        case .retainAutomatic:
            // An interval with automatic parameters keeps the chosen Auto mode;
            // each source snapshots its own readings instead of pretending a
            // numeric exposure was frozen.
            exposure = request.fallbackExposure
            exposureProvenance = .requested
        }

        let focus: FocusIntent
        if requirements.contains(.focus), let position = reference?.focusPosition,
           position.isFinite {
            focus = FocusIntent(mode: .manual, position: position, pointOfInterest: nil)
        } else {
            focus = request.fallbackFocus
        }

        // White balance has no gains-locked intent in the frozen value model, so
        // an automatic choice stays automatic and is recorded per source rather
        // than being frozen to an unconvertible numeric temperature.
        let whiteBalance = request.fallbackWhiteBalance

        return SequenceBaselineSnapshot(
            exposure: exposure,
            biasEV: request.explicitBaseline?.biasEV ?? 0,
            focus: focus,
            whiteBalance: whiteBalance,
            maxDimensions: request.maxDimensions,
            provenance: exposureProvenance,
            stableSampleCount: window.count,
            longestPlannedDurationSeconds: request.longestPlannedDurationSeconds)
    }
}
