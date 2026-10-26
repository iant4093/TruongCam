import Foundation

/// Aperture is independent of the shutter/ISO program. Auto never means
/// freezing a sampled f-number, and fixed lenses never offer a manual choice.
enum ApertureChoice: Hashable, Sendable {
    case auto
    case manual(fNumber: Double)

    var numericTarget: Double? {
        if case .manual(let value) = self { return value }
        return nil
    }
    var isAutomatic: Bool { numericTarget == nil }

    func matches(readback: AppliedControlSnapshot) -> Bool {
        guard isAutomatic == readback.apertureChoice.isAutomatic else { return false }
        if let target = numericTarget {
            guard !readback.isFixedApertureCamera, readback.isApertureAutomatic == false,
                  let measured = readback.lensAperture, measured.isFinite, target.isFinite,
                  measured > 0, target > 0 else { return false }
            return abs(measured - target) <= max(0.01, target * 0.01)
        }
        return readback.isFixedApertureCamera || readback.isApertureAutomatic != false
    }
}

/// Format-specific capability for automatic and locked diaphragm combinations.
struct ApertureCapability: Hashable, Sendable {
    let minFNumber: Double
    let maxFNumber: Double
    let recommendedStops: [Double]
    let autoExposureModes: Set<ExposureModeKind>
    let manualExposureModes: Set<ExposureModeKind>

    var isValid: Bool {
        minFNumber.isFinite && maxFNumber.isFinite && minFNumber > 0 && maxFNumber >= minFNumber
    }
    var isVariable: Bool { isValid && maxFNumber > minFNumber }
    var selectableStops: [Double] {
        guard isVariable else { return [] }
        return Array(Set(recommendedStops.filter {
            $0.isFinite && $0 >= minFNumber && $0 <= maxFNumber
        } + [minFNumber, maxFNumber])).sorted()
    }
    func supports(_ aperture: ApertureChoice, exposureMode: ExposureModeKind) -> Bool {
        if let value = aperture.numericTarget {
            return isVariable && value.isFinite && value >= minFNumber && value <= maxFNumber
                && manualExposureModes.contains(exposureMode)
        }
        return isValid && autoExposureModes.contains(exposureMode)
    }
}

// CONTRACTS.md "Identity, values and provenance" and ARCHITECTURE.md "Exposure
// model": exposure selection is exactly four cases. Auto flags are represented
// by the case, never by a numeric sentinel. Current constants are not Auto.

/// The validated numeric limits of the currently active format. Every value here
/// is runtime data discovered on device; nothing is hardcoded per model name.
struct ExposureLimits: Hashable, Sendable {
    var minDurationSeconds: Double
    var maxDurationSeconds: Double
    var minISO: Double
    var maxISO: Double
    var minBiasEV: Double
    var maxBiasEV: Double

    var isValid: Bool {
        minDurationSeconds.isFinite && maxDurationSeconds.isFinite && minDurationSeconds > 0
            && maxDurationSeconds >= minDurationSeconds
            && minISO.isFinite && maxISO.isFinite && minISO > 0 && maxISO >= minISO
            && minBiasEV.isFinite && maxBiasEV.isFinite && maxBiasEV >= minBiasEV
    }
}

/// The four supported exposure selections. Shutter priority has a duration
/// target only; ISO priority has an ISO target only; manual has both.
enum ExposureChoice: Hashable, Sendable {
    case auto
    case shutterPriority(durationSeconds: Double)
    case isoPriority(iso: Double)
    case manual(durationSeconds: Double, iso: Double)

    var mode: ExposureModeKind {
        switch self {
        case .auto: return .auto
        case .shutterPriority: return .shutterPriority
        case .isoPriority: return .isoPriority
        case .manual: return .manual
        }
    }

    /// Duration target, if this case pins one.
    var durationTargetSeconds: Double? {
        switch self {
        case .auto, .isoPriority: return nil
        case .shutterPriority(let d), .manual(let d, _): return d
        }
    }

    /// ISO target, if this case pins one.
    var isoTarget: Double? {
        switch self {
        case .auto, .shutterPriority: return nil
        case .isoPriority(let iso), .manual(_, let iso): return iso
        }
    }

    var isDurationAutomatic: Bool { durationTargetSeconds == nil }
    var isISOAutomatic: Bool { isoTarget == nil }

    /// CONTRACTS.md: changing one parameter to Manual starts from a legal
    /// current observed value, then applies the whole case. Changing a
    /// parameter to Auto preserves the other parameter's choice.
    static func settingDurationManual(
        _ durationSeconds: Double,
        from prior: ExposureChoice
    ) -> ExposureChoice {
        switch prior {
        case .auto: return .shutterPriority(durationSeconds: durationSeconds)
        case .shutterPriority: return .shutterPriority(durationSeconds: durationSeconds)
        case .isoPriority(let iso): return .manual(durationSeconds: durationSeconds, iso: iso)
        case .manual(_, let iso): return .manual(durationSeconds: durationSeconds, iso: iso)
        }
    }

    static func settingISOManual(_ iso: Double, from prior: ExposureChoice) -> ExposureChoice {
        switch prior {
        case .auto: return .isoPriority(iso: iso)
        case .shutterPriority(let d): return .manual(durationSeconds: d, iso: iso)
        case .isoPriority: return .isoPriority(iso: iso)
        case .manual(let d, _): return .manual(durationSeconds: d, iso: iso)
        }
    }

    static func settingDurationAuto(from prior: ExposureChoice) -> ExposureChoice {
        switch prior {
        case .auto, .shutterPriority: return .auto
        case .isoPriority(let iso): return .isoPriority(iso: iso)
        case .manual(_, let iso): return .isoPriority(iso: iso)
        }
    }

    static func settingISOAuto(from prior: ExposureChoice) -> ExposureChoice {
        switch prior {
        case .auto, .isoPriority: return .auto
        case .shutterPriority(let d): return .shutterPriority(durationSeconds: d)
        case .manual(let d, _): return .shutterPriority(durationSeconds: d)
        }
    }
}

enum ExposureModeKind: String, Hashable, Sendable, Codable, CaseIterable {
    case auto
    case shutterPriority
    case isoPriority
    case manual

    var displayName: String {
        switch self {
        case .auto: return "Auto"
        case .shutterPriority: return "Shutter priority"
        case .isoPriority: return "ISO priority"
        case .manual: return "Manual"
        }
    }
}

/// Reasons an exposure selection can be refused before any Objective-C setter
/// runs.
enum ExposureValidationFailure: Hashable, Sendable {
    case nonFiniteDuration(Double)
    case nonPositiveDuration(Double)
    case durationOutOfRange(requested: Double, min: Double, max: Double)
    case nonFiniteISO(Double)
    case nonPositiveISO(Double)
    case isoOutOfRange(requested: Double, min: Double, max: Double)
    case nonFiniteBias(Double)
    case biasOutOfRange(requested: Double, min: Double, max: Double)
    case unsupportedCombination(ExposureModeKind)
    case customExposureModeUnsupported

    var userDescription: String {
        switch self {
        case .nonFiniteDuration(let v): return "Exposure duration is not a finite number (\(v))."
        case .nonPositiveDuration(let v): return "Exposure duration must be positive (got \(v) s)."
        case .durationOutOfRange(let r, let lo, let hi):
            return "Exposure duration \(ExposureFormatting.duration(r)) is outside the active format range \(ExposureFormatting.duration(lo))–\(ExposureFormatting.duration(hi))."
        case .nonFiniteISO(let v): return "ISO is not a finite number (\(v))."
        case .nonPositiveISO(let v): return "ISO must be positive (got \(v))."
        case .isoOutOfRange(let r, let lo, let hi):
            return "ISO \(ExposureFormatting.iso(r)) is outside the active format range \(ExposureFormatting.iso(lo))–\(ExposureFormatting.iso(hi))."
        case .nonFiniteBias(let v): return "Exposure bias is not finite (\(v))."
        case .biasOutOfRange(let r, let lo, let hi):
            return "Exposure bias \(ExposureFormatting.bias(r)) is outside the supported range \(ExposureFormatting.bias(lo))–\(ExposureFormatting.bias(hi))."
        case .unsupportedCombination(let mode):
            return "The active format does not support \(mode.displayName) exposure."
        case .customExposureModeUnsupported:
            return "The active format does not support custom (manual or priority) exposure."
        }
    }
}

/// Pure validation against discovered runtime limits. This is the single gate
/// that runs before any native setter, so an invalid value can never reach
/// `setExposureModeCustom`, which raises `NSInvalidArgumentException`.
enum ExposureValidator {
    static func validate(
        choice: ExposureChoice,
        limits: ExposureLimits,
        supportsCustomExposureMode: Bool,
        supportsCombination: (ExposureChoice) -> Bool
    ) -> [ExposureValidationFailure] {
        var failures: [ExposureValidationFailure] = []

        if let d = choice.durationTargetSeconds {
            if !d.isFinite {
                failures.append(.nonFiniteDuration(d))
            } else if d <= 0 {
                failures.append(.nonPositiveDuration(d))
            } else if limits.isValid
                && (d < limits.minDurationSeconds || d > limits.maxDurationSeconds) {
                failures.append(.durationOutOfRange(
                    requested: d,
                    min: limits.minDurationSeconds,
                    max: limits.maxDurationSeconds))
            }
        }

        if let iso = choice.isoTarget {
            if !iso.isFinite {
                failures.append(.nonFiniteISO(iso))
            } else if iso <= 0 {
                failures.append(.nonPositiveISO(iso))
            } else if limits.isValid && (iso < limits.minISO || iso > limits.maxISO) {
                failures.append(.isoOutOfRange(
                    requested: iso, min: limits.minISO, max: limits.maxISO))
            }
        }

        switch choice.mode {
        case .auto:
            break
        case .shutterPriority, .isoPriority, .manual:
            if !supportsCustomExposureMode {
                failures.append(.customExposureModeUnsupported)
            }
        }

        if failures.isEmpty, choice.mode != .auto, !supportsCombination(choice) {
            failures.append(.unsupportedCombination(choice.mode))
        }
        return failures
    }

    static func validateBias(_ bias: Double, limits: ExposureLimits) -> ExposureValidationFailure? {
        if !bias.isFinite { return .nonFiniteBias(bias) }
        guard limits.isValid else { return nil }
        if bias < limits.minBiasEV || bias > limits.maxBiasEV {
            return .biasOutOfRange(requested: bias, min: limits.minBiasEV, max: limits.maxBiasEV)
        }
        return nil
    }
}

/// Logarithmic/photographic stepping helpers. These compute candidates only;
/// legal boundaries come from the active format and are never hardcoded.
enum PhotographicScale {
    /// Standard third-stop aperture/shutter/ISO ladder multiplier.
    static let thirdStop: Double = pow(2.0, 1.0 / 3.0)
    static let halfStop: Double = pow(2.0, 0.5)
    static let fullStop: Double = 2.0

    static func nextStop(_ value: Double, step: Double, up: Bool) -> Double {
        up ? value * step : value / step
    }

    /// Full-stop and third-stop standard still-camera shutter ladder, in
    /// seconds. Values are conventional photographic markings, not device
    /// capability limits; the active format's real range still gates them.
    static let standardDurations: [Double] = {
        var values: [Double] = []
        // Long exposures: powers of two from 64 s down to 1 s, plus the
        // conventional 30 s marking that sits between 32 s and 16 s.
        var long: Double = 64
        while long >= 1 {
            values.append(long)
            if long == 32 { values.append(30) }
            long /= 2
        }
        // Fast shutters: third-stop spacing snapped to conventional markings.
        let thirdStops = (0...45).map { 1.0 / pow(2.0, Double($0) / 3.0) }
        values.append(contentsOf: thirdStops.map { roundedForDisplay($0) })
        return Array(Set(values)).sorted(by: >)
    }()

    static func roundedForDisplay(_ seconds: Double) -> Double {
        // Conventional camera markings are round numbers, so snap each ladder
        // entry to the nearest "nice" denominator.
        guard seconds > 0, seconds < 1 else { return seconds }
        let denominator = 1.0 / seconds
        let niceDenominators: [Double] = [1, 2, 3, 4, 5, 6, 8, 10, 13, 15, 20, 25, 30, 40, 50, 60,
                                          80, 100, 125, 160, 200, 250, 320, 400, 500, 640, 800,
                                          1000, 1250, 1600, 2000, 2500, 3200, 4000, 5000, 6400,
                                          8000, 10000, 12500, 16000, 20000, 25000, 32000]
        let nearest = niceDenominators.min { abs($0 - denominator) < abs($1 - denominator) } ?? denominator
        return 1.0 / nearest
    }

    /// Nearest conventional shutter marking to a duration, in log space so the
    /// choice is perceptually even at both ends of the ladder.
    static func nearestStandardDuration(to seconds: Double) -> Double {
        guard seconds.isFinite, seconds > 0 else { return seconds }
        let target = log2(seconds)
        var best = seconds
        var bestDistance = Double.infinity
        for candidate in standardDurations {
            let distance = abs(log2(candidate) - target)
            if distance < bestDistance {
                bestDistance = distance
                best = candidate
            }
        }
        return best
    }
}

enum ExposureFormatting {
    static func duration(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds > 0 else { return "—" }
        if seconds >= 1 {
            let whole = (seconds * 10).rounded() / 10
            guard whole.isFinite, let integer = Int(exactly: whole.rounded()) else { return "—" }
            return whole == whole.rounded() ? "\(integer)s" : String(format: "%.1fs", whole)
        }
        let denominator = (1.0 / seconds).rounded()
        if denominator >= 1 {
            guard let integer = Int(exactly: denominator) else { return "—" }
            return "1/\(integer)s"
        }
        return String(format: "%.4fs", seconds)
    }

    static func iso(_ value: Double) -> String {
        guard value.isFinite, value > 0 else { return "—" }
        if value >= 100 {
            guard let integer = Int(exactly: value.rounded()) else { return "—" }
            return "\(integer)"
        }
        return String(format: "%.0f", value)
    }

    static func bias(_ value: Double) -> String {
        guard value.isFinite else { return "—" }
        return String(format: "%+.1f EV", value)
    }

    static func meters(_ value: Double?) -> String {
        guard let value, value.isFinite, value > 0 else { return "—" }
        return String(format: "%.2f m", value)
    }
}

/// Familiar photographic detents, filtered through the active native limits.
/// These are UI choices, not claims about a device's supported capabilities.
enum PhotographicExposureSteps {
    static let iso = [25.0, 32, 40, 50, 64, 80, 100, 125, 160, 200, 250, 320, 400, 500, 640, 800,
                      1000, 1250, 1600, 2000, 2500, 3200, 4000, 5000, 6400, 8000, 10000, 12800, 16000, 20000, 25600]
    static let durations = [64000.0, 51200, 40000, 32000, 25600, 20000, 16000, 12800, 10000, 8000,
        6400, 5000, 4000, 3200, 2500, 2000, 1600, 1250, 1000, 800, 640, 500, 400, 320, 250, 200,
        160, 125, 100, 80, 60, 50, 40, 30, 25, 20, 15, 13, 10, 8, 6, 5, 4, 3, 2.5, 2, 1.6, 1.3, 1]
        .map { 1 / $0 } + [1.3, 1.6, 2, 2.5, 3, 4, 5, 6, 8, 10, 13, 15, 20, 25, 30]
    static func legal(_ values: [Double], minimum: Double, maximum: Double) -> [Double] {
        guard minimum.isFinite, maximum.isFinite, minimum > 0, maximum >= minimum else { return [] }
        let choices = values.filter { $0 >= minimum && $0 <= maximum }
        return choices.isEmpty ? (minimum == maximum ? [minimum] : [minimum, maximum]) : choices
    }
    static func nearest(_ value: Double, in values: [Double]) -> Int {
        guard !values.isEmpty, value.isFinite else { return 0 }
        return values.indices.min { abs(values[$0] - value) < abs(values[$1] - value) } ?? 0
    }
}

/// A compact meter: full/third-stop marks over ±3 EV, not exposure compensation.
/// Unknown observations have no pointer rather than implying perfect exposure.
enum ExposureMeterScale {
    static let thirds = Array(-9...9)
    static func unitPosition(_ offsetEV: Double?) -> Double? {
        guard let offsetEV, offsetEV.isFinite else { return nil }
        return min(1,max(0,(3-offsetEV)/6))
    }
    static func isClipped(_ offsetEV: Double?) -> Bool {
        guard let offsetEV, offsetEV.isFinite else { return false }
        return abs(offsetEV)>3
    }
}

enum ApertureFormatting {
    static func fNumber(_ value: Double) -> String {
        guard value.isFinite, value > 0 else { return "—" }
        var digits = String(format: "%.2f", locale: Locale(identifier: "en_US_POSIX"), value)
        while digits.hasSuffix("0") { digits.removeLast() }
        if digits.hasSuffix(".") { digits.removeLast() }
        return "ƒ/" + digits
    }
}
