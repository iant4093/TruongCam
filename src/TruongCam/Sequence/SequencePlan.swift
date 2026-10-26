import Foundation

// CONTRACTS.md "Sequence rules and policy defaults" + ARCHITECTURE.md "Advanced
// sequences". Requirement IDs R7 and R9 (with R3/R4 for bracket target
// validation).
//
// Every plan is an immutable value type. Nothing in this file may hardcode a
// camera limit as if it had been measured: product/UI bounds are declared as
// policy, and anything a device must prove enters through `SequenceAdmissionPolicy`
// or `SequenceCapabilityContext`, which are injected and start out `unknown`.

// MARK: - Kind

enum SequencePlanKind: String, Hashable, Sendable, Codable, CaseIterable {
    case timer
    case interval
    case exposureBracket
    case focusBracket

    var displayName: String {
        switch self {
        case .timer: return "Timer"
        case .interval: return "Interval"
        case .exposureBracket: return "Exposure bracket"
        case .focusBracket: return "Focus bracket"
        }
    }

    /// Portable document kind, or nil when the run produces no grouped sequence.
    ///
    /// A timer run is one source after a countdown. `SequenceKind` has no timer
    /// case, and writing a one-source "interval" document would misstate the
    /// cadence, so a timer run writes no sequence document and its source stands
    /// alone in the library.
    var documentKind: SequenceKind? {
        switch self {
        case .timer: return nil
        case .interval: return .interval
        case .exposureBracket: return .exposureBracket
        case .focusBracket: return .focusBracket
        }
    }

    /// True for the source-varied bracket kinds.
    var isBracket: Bool {
        self == .exposureBracket || self == .focusBracket
    }
}

// MARK: - Timer

/// Timer countdown policy: Off / 3 / 10 seconds (CONTRACTS.md "Timer").
struct TimerPlan: Hashable, Sendable {
    static let supportedDelaySeconds: [Double] = [0, 3, 10]
    static let defaultDelaySeconds: Double = 3

    let delaySeconds: Double

    init(delaySeconds: Double = TimerPlan.defaultDelaySeconds) {
        self.delaySeconds = delaySeconds
    }

    var isOff: Bool { delaySeconds == 0 }

    func validate() -> [SequencePlanValidationError] {
        guard delaySeconds.isFinite,
              Self.supportedDelaySeconds.contains(where: { abs($0 - delaySeconds) < 1e-9 })
        else {
            return [.timerDelayUnsupported(requested: delaySeconds,
                                           allowed: Self.supportedDelaySeconds)]
        }
        return []
    }
}

// MARK: - Interval

/// Interval cadence policy. Count means retained ORIGINALS, never timer ticks.
struct IntervalPlan: Hashable, Sendable {
    /// Product/UI bounds. Parser and interface policy, not camera limits.
    static let countRange: ClosedRange<Int> = 1...999
    static let productMinimumIntervalSeconds: Double = 1
    static let productMaximumIntervalSeconds: Double = 3600
    static let defaultCount = 10
    static let defaultIntervalSeconds: Double = 5

    let count: Int
    let intervalSeconds: Double

    init(count: Int = IntervalPlan.defaultCount,
         intervalSeconds: Double = IntervalPlan.defaultIntervalSeconds) {
        self.count = count
        self.intervalSeconds = intervalSeconds
    }

    func validate(admission: SequenceAdmissionPolicy) -> [SequencePlanValidationError] {
        var errors: [SequencePlanValidationError] = []
        if !Self.countRange.contains(count) {
            errors.append(.intervalCountOutOfRange(requested: count, allowed: Self.countRange))
        }
        guard intervalSeconds.isFinite else {
            errors.append(.intervalNonFinite(intervalSeconds))
            return errors
        }
        guard intervalSeconds >= Self.productMinimumIntervalSeconds,
              intervalSeconds <= Self.productMaximumIntervalSeconds else {
            errors.append(.intervalOutOfRange(
                requested: intervalSeconds,
                productMinimum: Self.productMinimumIntervalSeconds,
                productMaximum: Self.productMaximumIntervalSeconds))
            return errors
        }
        // A device-tested admission minimum may only narrow the product bound.
        if let tested = admission.testedMinimumIntervalSeconds.value,
           intervalSeconds < tested - 1e-9 {
            errors.append(.intervalBelowTestedAdmission(requested: intervalSeconds,
                                                        testedMinimum: tested))
        }
        return errors
    }
}

// MARK: - Exposure bracket

/// Which tested path the bracket uses. `native` is only selectable once a device
/// test has proven both the count and callback correspondence; `serial` is the
/// clearly labeled slower single-source alternative.
enum ExposureBracketPath: String, Hashable, Sendable, Codable, CaseIterable {
    case native
    case serial

    var displayName: String {
        switch self {
        case .native: return "Native bracket"
        case .serial: return "Serial source bracket"
        }
    }
}

/// The exposure the bracket varies around. Duration/ISO come from one consistent
/// applied/readback revision; `provenance` records which.
struct ExposureBaseline: Hashable, Sendable {
    let durationSeconds: Double
    let iso: Double
    let biasEV: Double
    let provenance: ValueProvenance
    var aperture: Double? = nil

    init(durationSeconds: Double,
         iso: Double,
         biasEV: Double = 0,
         provenance: ValueProvenance = .settledDeviceReadback,
         aperture: Double? = nil) {
        self.durationSeconds = durationSeconds
        self.iso = iso
        self.biasEV = biasEV
        self.provenance = provenance
        self.aperture = aperture
    }
}

/// A smaller bracket the plan can legally use instead of the rejected one.
struct BracketSpanSuggestion: Hashable, Sendable {
    /// Half-span in EV: the largest absolute offset that stays in range.
    let spanEV: Double
    /// 3 or 5, the smallest supported count that fits the legal span.
    let sourceCount: Int

    var displayLabel: String {
        String(format: "±%.2f EV with %d sources", spanEV, sourceCount)
    }
}

struct ExposureBracketPlan: Hashable, Sendable {
    static let allowedCounts: [Int] = [3, 5]
    static let allowedStepEV: [Double] = [1.0 / 3.0, 2.0 / 3.0, 1.0, 2.0]
    static let defaultCount = 3
    static let defaultStepEV = 1.0

    let count: Int
    let stepEV: Double
    let path: ExposureBracketPath

    init(count: Int = ExposureBracketPlan.defaultCount,
         stepEV: Double = ExposureBracketPlan.defaultStepEV,
         path: ExposureBracketPath = .native) {
        self.count = count
        self.stepEV = stepEV
        self.path = path
    }

    /// 3 sources → ±1 step, 5 sources → ±2 steps.
    var halfSpanSteps: Int { count == 5 ? 2 : 1 }

    var spanEV: Double { Double(halfSpanSteps) * stepEV }

    /// Three offsets `[-step, 0, +step]`, five offsets
    /// `[-2·step, -step, 0, +step, +2·step]`. The middle offset is exactly 0.
    var offsetsEV: [Double] {
        let half = halfSpanSteps
        return (-half...half).map { Double($0) * stepEV }
    }

    /// Duration target for one offset, from the baseline duration. ISO is fixed.
    func targetDurationSeconds(offsetEV offset: Double, baselineSeconds: Double) -> Double {
        baselineSeconds * pow(2.0, offset)
    }

    /// The largest supported bracket that keeps every duration target inside the
    /// active format limits. Returned so a rejected plan can propose a smaller
    /// span instead of silently clamping and producing duplicate exposures.
    static func maximalLegalSuggestion(baselineSeconds: Double,
                                       stepEV: Double,
                                       limits: ExposureLimits) -> BracketSpanSuggestion? {
        guard limits.isValid, baselineSeconds.isFinite, baselineSeconds > 0,
              stepEV.isFinite, stepEV > 0 else { return nil }
        let headroomUp = log2(limits.maxDurationSeconds / baselineSeconds)
        let headroomDown = log2(baselineSeconds / limits.minDurationSeconds)
        let maxAbsoluteEV = min(headroomUp, headroomDown)
        guard maxAbsoluteEV.isFinite, maxAbsoluteEV > 0 else { return nil }
        // Only two steps are representable. Bound the floating-point quotient
        // before integer conversion, including overflow from a tiny step.
        let legalSteps = Int(min(2, floor(maxAbsoluteEV / stepEV + 1e-9)))
        guard legalSteps >= 1 else { return nil }
        let usableSteps = min(legalSteps, 2)
        return BracketSpanSuggestion(spanEV: Double(usableSteps) * stepEV,
                                     sourceCount: usableSteps >= 2 ? 5 : 3)
    }

    func validate(baseline: ExposureBaseline?,
                  context: SequenceValidationContext) -> [SequencePlanValidationError] {
        var errors: [SequencePlanValidationError] = []

        guard Self.allowedCounts.contains(count) else {
            errors.append(.bracketCountUnsupported(requested: count, allowed: Self.allowedCounts))
            return errors
        }
        let stepIsSupported = stepEV.isFinite
            && Self.allowedStepEV.contains(where: { abs($0 - stepEV) < 1e-9 })
        if !stepIsSupported {
            errors.append(.bracketStepUnsupported(requested: stepEV, allowed: Self.allowedStepEV))
        }

        if path == .native {
            if context.capability.apertureCapability?.isVariable == true {
                errors.append(.nativeBracketPathUnverified(requested: count,
                    reason: "Native bracket aperture retention has not been measured for this variable lens."))
            }
            switch context.admission.testedNativeBracketCounts {
            case .unknown(let reason), .unavailable(let reason):
                errors.append(.nativeBracketPathUnverified(requested: count, reason: reason))
            case .available(let tested):
                if !tested.contains(count) {
                    errors.append(.nativeBracketCountNotTested(requested: count,
                                                               tested: tested.sorted()))
                }
            }
            if let testedMaximum = context.admission.testedMaximumBracketCount,
               count > testedMaximum {
                errors.append(.bracketCountExceedsTestedMaximum(requested: count,
                                                                testedMaximum: testedMaximum))
            }
        }

        guard let baseline else {
            errors.append(.bracketBaselineMissing)
            return errors
        }

        let limits = context.capability.exposureLimits
        if !baseline.durationSeconds.isFinite || !baseline.iso.isFinite {
            errors.append(.bracketBaselineNotFinite)
        }

        let baselineFailures = ExposureValidator.validate(
            choice: .manual(durationSeconds: baseline.durationSeconds, iso: baseline.iso),
            limits: limits,
            supportsCustomExposureMode: context.capability.supportsCustomExposureMode,
            supportsCombination: { choice in
                if let aperture = context.capability.apertureCapability, aperture.isVariable {
                    return aperture.manualExposureModes.contains(choice.mode)
                }
                return context.capability.supportedExposureModes.contains(choice.mode)
            })
        if !baselineFailures.isEmpty {
            errors.append(.baselineExposureInvalid(failures: baselineFailures))
        }

        // Every duration target is validated BEFORE start.
        if limits.isValid, baseline.durationSeconds.isFinite, baseline.durationSeconds > 0 {
            var offendingOffsets: [Double] = []
            for offset in offsetsEV {
                let target = targetDurationSeconds(offsetEV: offset,
                                                   baselineSeconds: baseline.durationSeconds)
                if !target.isFinite || target <= 0
                    || target < limits.minDurationSeconds
                    || target > limits.maxDurationSeconds {
                    offendingOffsets.append(offset)
                }
            }
            if !offendingOffsets.isEmpty {
                errors.append(.bracketDurationOutOfRange(
                    offsetsEV: offendingOffsets,
                    baselineSeconds: baseline.durationSeconds,
                    minSeconds: limits.minDurationSeconds,
                    maxSeconds: limits.maxDurationSeconds,
                    suggestion: Self.maximalLegalSuggestion(baselineSeconds: baseline.durationSeconds,
                                                            stepEV: stepEV,
                                                            limits: limits)))
            }
        }

        return errors
    }
}

// MARK: - Focus bracket

/// Normalized focus positions. Direction is unverified on device, so every label
/// says "Position": never Near/Far and never a distance in metres.
struct FocusBracketPlan: Hashable, Sendable {
    static let countRange: ClosedRange<Int> = 2...9
    static let defaultCount = 5
    static let defaultStartPosition = 0.2
    static let defaultEndPosition = 0.8
    static let labelNoun = "Position"

    let count: Int
    let startPosition: Double
    let endPosition: Double

    init(count: Int = FocusBracketPlan.defaultCount,
         startPosition: Double = FocusBracketPlan.defaultStartPosition,
         endPosition: Double = FocusBracketPlan.defaultEndPosition) {
        self.count = count
        self.startPosition = startPosition
        self.endPosition = endPosition
    }

    /// Linear normalized spacing between the endpoints. No equal-depth claim.
    var positions: [Double] {
        guard Self.countRange.contains(count) else { return [] }
        let denominator = Double(count - 1)
        return (0..<count).map { index in
            startPosition + (endPosition - startPosition) * (Double(index) / denominator)
        }
    }

    /// User-facing label. Always "Position", never Near/Far or metres.
    func label(forIndex index: Int) -> String {
        let list = positions
        let clamped = min(max(index, 0), max(list.count - 1, 0))
        guard list.indices.contains(clamped) else {
            return "\(Self.labelNoun) \(clamped + 1)"
        }
        return "\(Self.labelNoun) \(clamped + 1) of \(count) · \(String(format: "%.3f", list[clamped]))"
    }

    func validate(context: SequenceValidationContext) -> [SequencePlanValidationError] {
        var errors: [SequencePlanValidationError] = []

        if !Self.countRange.contains(count) {
            errors.append(.focusCountOutOfRange(requested: count, allowed: Self.countRange))
        }

        var focusFailures: [FocusValidationFailure] = []
        if let failure = FocusValidator.validateManualPosition(startPosition,
                                                               limits: context.capability.focusLimits) {
            focusFailures.append(failure)
        }
        if let failure = FocusValidator.validateManualPosition(endPosition,
                                                               limits: context.capability.focusLimits) {
            focusFailures.append(failure)
        }
        if !focusFailures.isEmpty {
            errors.append(.focusEndpointInvalid(failures: focusFailures))
        }

        if startPosition.isFinite, endPosition.isFinite,
           abs(endPosition - startPosition) < 1e-9 {
            errors.append(.focusEndpointsIdentical(startPosition))
        }

        let list = positions
        let rounded = Set(list.map { ($0 * 1_000_000).rounded() })
        if rounded.count != list.count {
            errors.append(.focusPositionsDuplicate(positions: list))
        }
        return errors
    }
}

// MARK: - Admission policy

/// Injected admission policy.
///
/// The product bounds are interface/parser policy. The `tested*` fields are the
/// only place a device or serial-path measurement may narrow them, and they stay
/// `unknown` (or `unavailable`) until such a measurement exists. Nothing here is
/// a claim about any camera.
struct SequenceAdmissionPolicy: Hashable, Sendable {
    static let noIntervalMeasurement = "no interval run has been measured on this configuration"
    static let noNativeBracketMeasurement = "no native bracket path has been measured on this configuration"

    /// Device-tested cadence floor for this camera/format generation.
    var testedMinimumIntervalSeconds: DiscoveryStatus<Double> =
        .unknown(reason: SequenceAdmissionPolicy.noIntervalMeasurement)

    /// Source counts a tested native bracket path actually delivered.
    var testedNativeBracketCounts: DiscoveryStatus<Set<Int>> =
        .unknown(reason: SequenceAdmissionPolicy.noNativeBracketMeasurement)

    /// Highest count the tested path can deliver in one request, when known.
    var testedMaximumBracketCount: Int?

    /// Provisional policy for a build that has no device measurements yet: only
    /// the product bounds apply, and native bracketing stays unavailable.
    static let provisional = SequenceAdmissionPolicy()

    /// Effective cadence floor: the product bound, narrowed only by a real
    /// measurement.
    var effectiveMinimumIntervalSeconds: Double {
        switch testedMinimumIntervalSeconds {
        case .available(let tested):
            return max(IntervalPlan.productMinimumIntervalSeconds, tested)
        case .unknown, .unavailable:
            return IntervalPlan.productMinimumIntervalSeconds
        }
    }

    /// Whether the cadence floor is backed by a real measurement.
    var intervalAdmissionIsMeasured: Bool {
        testedMinimumIntervalSeconds.value != nil
    }
}

// MARK: - Capability context

/// Active-format facts a plan needs. Injected; the sequence layer never reads a
/// camera itself.
struct SequenceCapabilityContext: Hashable, Sendable {
    let exposureLimits: ExposureLimits
    let focusLimits: FocusLimits
    let supportsCustomExposureMode: Bool
    let supportedExposureModes: Set<ExposureModeKind>
    var apertureCapability: ApertureCapability? = nil

    /// No discovered limits: range checks are skipped exactly as
    /// `ExposureValidator` does for invalid limits, and manual focus is refused
    /// because it has not been shown to be supported.
    static let undiscovered = SequenceCapabilityContext(
        exposureLimits: ExposureLimits(
            minDurationSeconds: 0,
            maxDurationSeconds: 0,
            minISO: 0,
            maxISO: 0,
            minBiasEV: 0,
            maxBiasEV: 0),
        focusLimits: FocusLimits(
            supportsCustomLensPosition: false,
            supportsPointOfInterest: false,
            supportsContinuousAutoFocus: false,
            supportsAutoFocus: false,
            positionZeroDirectionVerified: false),
        supportsCustomExposureMode: false,
        supportedExposureModes: [])
}

struct SequenceValidationContext: Hashable, Sendable {
    let capability: SequenceCapabilityContext
    let admission: SequenceAdmissionPolicy
    /// The baseline used to pre-validate exposure-bracket duration targets.
    let bracketBaseline: ExposureBaseline?

    init(capability: SequenceCapabilityContext,
         admission: SequenceAdmissionPolicy,
         bracketBaseline: ExposureBaseline? = nil) {
        self.capability = capability
        self.admission = admission
        self.bracketBaseline = bracketBaseline
    }
}

// MARK: - Validation errors

enum SequencePlanValidationError: Error, Hashable, Sendable, CustomStringConvertible {
    case timerDelayUnsupported(requested: Double, allowed: [Double])
    case intervalCountOutOfRange(requested: Int, allowed: ClosedRange<Int>)
    case intervalNonFinite(Double)
    case intervalOutOfRange(requested: Double, productMinimum: Double, productMaximum: Double)
    case intervalBelowTestedAdmission(requested: Double, testedMinimum: Double)

    case bracketCountUnsupported(requested: Int, allowed: [Int])
    case bracketStepUnsupported(requested: Double, allowed: [Double])
    case nativeBracketPathUnverified(requested: Int, reason: String)
    case nativeBracketCountNotTested(requested: Int, tested: [Int])
    case bracketCountExceedsTestedMaximum(requested: Int, testedMaximum: Int)
    case bracketBaselineMissing
    case bracketBaselineNotFinite
    case baselineExposureInvalid(failures: [ExposureValidationFailure])
    case bracketDurationOutOfRange(offsetsEV: [Double],
                                   baselineSeconds: Double,
                                   minSeconds: Double,
                                   maxSeconds: Double,
                                   suggestion: BracketSpanSuggestion?)

    case focusCountOutOfRange(requested: Int, allowed: ClosedRange<Int>)
    case focusEndpointInvalid(failures: [FocusValidationFailure])
    case focusEndpointsIdentical(Double)
    case focusPositionsDuplicate(positions: [Double])

    var description: String {
        switch self {
        case .timerDelayUnsupported(let requested, let allowed):
            return "Timer delay \(requested)s is not one of \(allowed)."
        case .intervalCountOutOfRange(let requested, let allowed):
            return "Interval count \(requested) is outside \(allowed.lowerBound)…\(allowed.upperBound)."
        case .intervalNonFinite(let value):
            return "Interval cadence is not a finite number (\(value))."
        case .intervalOutOfRange(let requested, let low, let high):
            return "Interval cadence \(requested)s is outside the product range \(low)–\(high) s."
        case .intervalBelowTestedAdmission(let requested, let tested):
            return "Interval cadence \(requested)s is below the device-tested admission minimum \(tested)s."
        case .bracketCountUnsupported(let requested, let allowed):
            return "Exposure bracket count \(requested) is not supported (choose \(allowed))."
        case .bracketStepUnsupported(let requested, let allowed):
            return "Exposure bracket step \(requested) EV is not one of \(allowed)."
        case .nativeBracketPathUnverified(let requested, let reason):
            return "A native \(requested)-source bracket has not been proven on this configuration: \(reason)."
        case .nativeBracketCountNotTested(let requested, let tested):
            return "Native bracket count \(requested) was not among the tested counts \(tested)."
        case .bracketCountExceedsTestedMaximum(let requested, let testedMaximum):
            return "Bracket count \(requested) exceeds the tested maximum \(testedMaximum)."
        case .bracketBaselineMissing:
            return "An exposure bracket needs a settled baseline duration and ISO before it can start."
        case .bracketBaselineNotFinite:
            return "The exposure baseline is not finite."
        case .baselineExposureInvalid(let failures):
            return "The exposure baseline is not legal: "
                + failures.map(\.userDescription).joined(separator: " ")
        case .bracketDurationOutOfRange(let offsets, let baseline, let low, let high, let suggestion):
            let offsetList = offsets.map { String(format: "%+.2f", $0) }.joined(separator: ", ")
            let proposal = suggestion.map { " Suggested span: \($0.displayLabel)." } ?? ""
            return "Duration targets at \(offsetList) EV from \(ExposureFormatting.duration(baseline)) "
                + "fall outside \(ExposureFormatting.duration(low))–\(ExposureFormatting.duration(high))."
                + proposal
        case .focusCountOutOfRange(let requested, let allowed):
            return "Focus bracket count \(requested) is outside \(allowed.lowerBound)…\(allowed.upperBound)."
        case .focusEndpointInvalid(let failures):
            return "Focus bracket endpoints are not legal: "
                + failures.map(\.userDescription).joined(separator: " ")
        case .focusEndpointsIdentical(let position):
            return "Focus bracket endpoints are identical (\(position)); there is nothing to bracket."
        case .focusPositionsDuplicate(let positions):
            return "Focus bracket positions repeat (\(positions)); duplicate sources are not a bracket."
        }
    }
}

// MARK: - Plan

enum SequenceSpecification: Hashable, Sendable {
    case timer(TimerPlan)
    case interval(IntervalPlan)
    case exposureBracket(ExposureBracketPlan)
    case focusBracket(FocusBracketPlan)
}

/// An immutable sequence plan. It is frozen at Start and carries the library
/// identity and the camera configuration generation it was built against.
struct SequencePlan: Hashable, Sendable {
    let sequenceID: SequenceID
    let libraryID: LibraryID
    let configurationGeneration: ConfigurationGeneration
    let rootGeneration: RootGeneration
    let physicalCameraKind: PhysicalCameraKind
    let kind: SequencePlanKind
    let specification: SequenceSpecification
    let createdAtUTC: Date
    /// Nominal equivalent from this plan's selected native camera capability.
    /// It is a frozen display hint, not per-photo EXIF or a kind/model lookup.
    let nominalEquivalentFocalLengthMM: Double?

    init(sequenceID: SequenceID = SequenceID(),
         libraryID: LibraryID,
         configurationGeneration: ConfigurationGeneration,
         rootGeneration: RootGeneration = .zero,
         physicalCameraKind: PhysicalCameraKind = .wide,
         kind: SequencePlanKind,
         specification: SequenceSpecification,
         createdAtUTC: Date,
         nominalEquivalentFocalLengthMM: Double? = nil) {
        self.sequenceID = sequenceID
        self.libraryID = libraryID
        self.configurationGeneration = configurationGeneration
        self.rootGeneration = rootGeneration
        self.physicalCameraKind = physicalCameraKind
        self.kind = kind
        self.specification = specification
        self.createdAtUTC = createdAtUTC
        self.nominalEquivalentFocalLengthMM = nominalEquivalentFocalLengthMM.flatMap {
            $0.isFinite && $0 > 0 ? $0 : nil
        }
    }

    /// Number of sources the plan intends to retain. For an interval this is the
    /// requested original count, not a timer-tick count.
    var plannedSourceCount: Int {
        switch specification {
        case .timer: return 1
        case .interval(let plan): return max(0, plan.count)
        case .exposureBracket(let plan): return max(0, plan.count)
        case .focusBracket(let plan): return max(0, plan.count)
        }
    }

    var intervalPlan: IntervalPlan? {
        if case .interval(let plan) = specification { return plan }
        return nil
    }

    var exposureBracketPlan: ExposureBracketPlan? {
        if case .exposureBracket(let plan) = specification { return plan }
        return nil
    }

    var focusBracketPlan: FocusBracketPlan? {
        if case .focusBracket(let plan) = specification { return plan }
        return nil
    }

    var timerPlan: TimerPlan? {
        if case .timer(let plan) = specification { return plan }
        return nil
    }

    /// The longest single exposure the plan can request, used by the
    /// duration-aware settling watchdog. Nil when the plan has no frozen
    /// duration yet (an exposure bracket before settlement).
    func longestPlannedDurationSeconds(baseline: ExposureBaseline?) -> Double {
        switch specification {
        case .timer:
            return 0
        case .interval:
            return 0
        case .focusBracket:
            return baseline?.durationSeconds ?? 0
        case .exposureBracket(let plan):
            guard let baseline else { return 0 }
            let offsets = plan.offsetsEV.map { abs($0) }
            let largestOffset = offsets.max() ?? 0
            return plan.targetDurationSeconds(offsetEV: largestOffset,
                                              baselineSeconds: baseline.durationSeconds)
        }
    }

    func validate(context: SequenceValidationContext) -> [SequencePlanValidationError] {
        switch specification {
        case .timer(let plan):
            return plan.validate()
        case .interval(let plan):
            return plan.validate(admission: context.admission)
        case .exposureBracket(let plan):
            return plan.validate(baseline: context.bracketBaseline, context: context)
        case .focusBracket(let plan):
            return plan.validate(context: context)
        }
    }
}

// MARK: - Settled baseline

/// The frozen control state a sequence runs with after baseline settlement.
struct SequenceBaselineSnapshot: Hashable, Sendable {
    let exposure: ExposureChoice
    let biasEV: Double
    let focus: FocusIntent
    let whiteBalance: WhiteBalanceIntent
    let maxDimensions: PixelDimensions
    let provenance: ValueProvenance
    let stableSampleCount: Int
    let longestPlannedDurationSeconds: Double
    var aperture: ApertureChoice = .auto

    var durationSeconds: Double? { exposure.durationTargetSeconds }
    var isoTarget: Double? { exposure.isoTarget }

    /// Numeric baseline for an exposure bracket. Only a fully manual baseline can
    /// drive duration targets; anything else means settlement did not freeze it.
    var exposureBaseline: ExposureBaseline? {
        guard case .manual(let duration, let iso) = exposure else { return nil }
        return ExposureBaseline(durationSeconds: duration,
                                iso: iso,
                                biasEV: biasEV,
                                provenance: provenance,
                                aperture: aperture.numericTarget)
    }
}

// MARK: - Document projection

/// Projects a frozen plan into the portable `SequenceDocument`.
enum SequenceDocumentBuilder {
    static func makeDocument(plan: SequencePlan,
                             baseline: SequenceBaselineSnapshot?,
                             startedAtUTC: Date) -> SequenceDocument? {
        guard let documentKind = plan.kind.documentKind else { return nil }

        let sourcePlan: [SequenceSourcePlanEntry]
        let intervalSeconds: Double?
        switch plan.specification {
        case .timer:
            return nil
        case .interval(let interval):
            // An interval enumerates no per-source plan: the cadence and the
            // requested original count are the plan.
            sourcePlan = []
            intervalSeconds = interval.intervalSeconds
        case .exposureBracket(let bracket):
            sourcePlan = bracket.offsetsEV.enumerated().map { index, offset in
                SequenceSourcePlanEntry(index: index, offsetEV: offset, focusPosition: nil)
            }
            intervalSeconds = nil
        case .focusBracket(let focus):
            sourcePlan = focus.positions.enumerated().map { index, position in
                SequenceSourcePlanEntry(index: index, offsetEV: nil, focusPosition: position)
            }
            intervalSeconds = nil
        }

        return SequenceDocument(
            sequenceID: plan.sequenceID,
            libraryID: plan.libraryID,
            kind: documentKind,
            plannedCount: plan.plannedSourceCount,
            sourcePlan: sourcePlan,
            intervalSeconds: intervalSeconds,
            baseline: baseline.map(makeBaselineRecord),
            startedAtUTC: startedAtUTC)
    }

    static func makeBaselineRecord(_ snapshot: SequenceBaselineSnapshot) -> SequenceBaseline {
        SequenceBaseline(
            maxDimensions: snapshot.maxDimensions,
            exposure: ExposureRequestRecord(
                mode: snapshot.exposure.mode,
                durationSeconds: snapshot.exposure.durationTargetSeconds,
                iso: snapshot.exposure.isoTarget,
                biasEV: snapshot.biasEV,
                apertureMode: snapshot.aperture.isAutomatic ? "auto" : "manual",
                aperture: snapshot.aperture.numericTarget),
            focus: FocusRequestRecord(
                mode: snapshot.focus.mode,
                position: snapshot.focus.position),
            whiteBalance: WhiteBalanceRequestRecord(
                mode: snapshot.whiteBalance.mode,
                temperatureKelvin: snapshot.whiteBalance.temperatureAndTint?.temperature,
                tint: snapshot.whiteBalance.temperatureAndTint?.tint))
    }
}
