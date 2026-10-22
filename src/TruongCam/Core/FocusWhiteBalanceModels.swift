import Foundation

// CONTRACTS.md / ARCHITECTURE.md "Focus, white balance and lens selection".
// Focus position is a normalized lens control in [0, 1] — never an inferred
// distance in meters.

enum FocusModeKind: String, Hashable, Sendable, Codable, CaseIterable {
    case continuousAuto
    case lockedAuto
    case manual

    var displayName: String {
        switch self {
        case .continuousAuto: return "Continuous AF"
        case .lockedAuto: return "Locked AF"
        case .manual: return "Manual"
        }
    }

    /// Short control-row rendering used by the compact readouts.
    var shorthand: String {
        switch self {
        case .continuousAuto: return "AF"
        case .lockedAuto: return "AF-L"
        case .manual: return "M"
        }
    }
}

struct FocusLimits: Hashable, Sendable {
    let supportsCustomLensPosition: Bool
    let supportsPointOfInterest: Bool
    let supportsContinuousAutoFocus: Bool
    let supportsAutoFocus: Bool
    /// Direction is not assumed; documented as unverified until measured.
    let positionZeroDirectionVerified: Bool
}

enum FocusValidationFailure: Hashable, Sendable {
    case positionNonFinite(Double)
    case positionOutOfRange(Double)
    case customLensPositionUnsupported
    case manualModeUnsupported
    case pointOfInterestUnsupported
    case pointOutsideImage(Double, Double)

    var userDescription: String {
        switch self {
        case .positionNonFinite(let v): return "Focus position is not a finite number (\(v))."
        case .positionOutOfRange(let v):
            return "Focus position \(String(format: "%.3f", v)) is outside the supported 0…1 range."
        case .customLensPositionUnsupported:
            return "This camera does not support locking focus at a custom lens position."
        case .manualModeUnsupported:
            return "This camera does not support manual focus."
        case .pointOfInterestUnsupported:
            return "This camera does not support focus points of interest."
        case .pointOutsideImage(let x, let y):
            return "Focus point (\(String(format: "%.2f", x)), \(String(format: "%.2f", y))) is outside the visible image."
        }
    }
}

enum FocusValidator {
    /// Manual position must be finite and inside [0, 1] before
    /// `setFocusModeLocked(lensPosition:)`, which raises for other values when
    /// custom positions are unsupported.
    static func validateManualPosition(_ position: Double, limits: FocusLimits) -> FocusValidationFailure? {
        if !position.isFinite { return .positionNonFinite(position) }
        if position < 0 || position > 1 { return .positionOutOfRange(position) }
        if !limits.supportsCustomLensPosition { return .customLensPositionUnsupported }
        return nil
    }

    /// Normalized device coordinates must lie inside the visible image rect.
    static func validatePointOfInterest(_ point: (x: Double, y: Double), limits: FocusLimits) -> FocusValidationFailure? {
        if !limits.supportsPointOfInterest { return .pointOfInterestUnsupported }
        if !point.x.isFinite || !point.y.isFinite { return .pointOutsideImage(point.x, point.y) }
        if point.x < 0 || point.x > 1 || point.y < 0 || point.y > 1 {
            return .pointOutsideImage(point.x, point.y)
        }
        return nil
    }
}

/// White balance: temperature AND tint are both user-facing controls.
enum WhiteBalanceModeKind: String, Hashable, Sendable, Codable, CaseIterable {
    case auto
    case manual

    var displayName: String {
        switch self {
        case .auto: return "Auto"
        case .manual: return "Manual"
        }
    }
}

/// UI slider policy domain from CONTRACTS.md. This is *not* a device capability
/// bound; direct entry may go beyond it as long as native conversion yields
/// legal representable gains.
struct WhiteBalanceSliderDomain: Hashable, Sendable {
    let minKelvin: Double
    let maxKelvin: Double
    let minTint: Double
    let maxTint: Double

    static let productPolicy = WhiteBalanceSliderDomain(
        minKelvin: 1000, maxKelvin: 15000, minTint: -150, maxTint: 150)
}

struct WhiteBalanceGains: Hashable, Sendable, Codable {
    let red: Double
    let green: Double
    let blue: Double

    var isFinite: Bool { red.isFinite && green.isFinite && blue.isFinite }
    var allInLegalRange: Bool { isFinite && red >= 1 && green >= 1 && blue >= 1 }
}

/// Temperature/tint as entered by the user.
struct WhiteBalanceTemperatureAndTint: Hashable, Sendable, Codable {
    /// Kelvin.
    let temperature: Double
    /// Device tint units (AVFoundation convention: positive = magenta).
    let tint: Double

    var isFinite: Bool { temperature.isFinite && tint.isFinite }
}

enum WhiteBalanceLimits: Hashable, Sendable {
    case unavailable
    case available(maxGain: Double, supportsCustomGains: Bool, supportsTemperatureAndTint: Bool)
}

enum WhiteBalanceValidationFailure: Hashable, Sendable {
    case temperatureNonFinite(Double)
    case temperatureNonPositive(Double)
    case tintNonFinite(Double)
    case conversionUnavailable
    case gainsOutOfRange(WhiteBalanceGains, max: Double)
    case customGainsUnsupported
    /// The requested temperature or tint is finite as a Double but cannot be
    /// represented as a Float, so it must not reach the native converter
    /// (REVIEW.md F03).
    case temperatureTintUnrepresentable

    var userDescription: String {
        switch self {
        case .temperatureNonFinite(let v): return "White balance temperature is not finite (\(v))."
        case .temperatureNonPositive(let v): return "White balance temperature must be positive (got \(v) K)."
        case .tintNonFinite(let v): return "White balance tint is not finite (\(v))."
        case .conversionUnavailable:
            return "This camera cannot convert a temperature and tint into device white balance gains."
        case .gainsOutOfRange(_, let max):
            return "The requested temperature/tint converts to gains outside the device range 1.0–\(String(format: "%.2f", max))."
        case .customGainsUnsupported:
            return "This camera does not support locking white balance at custom gains."
        case .temperatureTintUnrepresentable:
            return "The requested white balance temperature or tint is outside the range this camera's conversion can represent."
        }
    }
}

/// Result of attempting to represent a requested temperature/tint as device
/// gains. `clamped` records that the requested value could not be represented
/// exactly, so the UI can distinguish desired from applied.
enum WhiteBalanceGainResolution: Hashable, Sendable {
    case exact(WhiteBalanceGains)
    case clamped(requested: WhiteBalanceGains, clamped: WhiteBalanceGains)
    case unrepresentable(requested: WhiteBalanceGains)
    case conversionUnavailable
}
