import Foundation

/// Converts a requested temperature/tint into device white balance gains and
/// reports whether the request was representable.
///
/// `maxGain` is runtime data from `AVCaptureDevice.maxWhiteBalanceGain`. The
/// temperature-to-gain conversion itself is device-specific and is injected, so
/// this type stays testable without a camera and never invents a colour model.
struct WhiteBalanceGainResolver: Sendable {
    let maxGain: Double

    init(maxGain: Double) {
        self.maxGain = maxGain
    }

    /// Result when the device cannot convert temperature/tint at all.
    func resolveWithoutConversion() -> WhiteBalanceGainResolution {
        .conversionUnavailable
    }

    /// Resolves a request using a device-supplied converter.
    ///
    /// Rules (CONTRACTS.md "White balance"):
    ///   * non-finite or non-positive temperature is rejected before conversion;
    ///   * gains below 1.0 are not representable at all;
    ///   * gains above `maxGain` on any channel are clamped and the original
    ///     requested gains are retained so the UI can show desired vs applied.
    func resolve(
        _ request: WhiteBalanceTemperatureAndTint,
        gainsFromTemperatureTint: (WhiteBalanceTemperatureAndTint) -> WhiteBalanceGains
    ) -> WhiteBalanceGainResolution {
        guard request.isFinite, request.temperature > 0 else {
            return .unrepresentable(requested: WhiteBalanceGains(red: 0, green: 0, blue: 0))
        }
        let gains = gainsFromTemperatureTint(request)
        guard gains.isFinite else {
            return .unrepresentable(requested: gains)
        }
        if !gains.allInLegalRange {
            return .unrepresentable(requested: gains)
        }
        let clamped = WhiteBalanceGains(
            red: min(gains.red, maxGain),
            green: min(gains.green, maxGain),
            blue: min(gains.blue, maxGain))
        if clamped == gains {
            return .exact(gains)
        }
        return .clamped(requested: gains, clamped: clamped)
    }

    /// Clamps already-known gains (for example, read back from the device).
    func clamp(_ gains: WhiteBalanceGains) -> WhiteBalanceGains {
        WhiteBalanceGains(
            red: min(max(gains.red, 1.0), maxGain),
            green: min(max(gains.green, 1.0), maxGain),
            blue: min(max(gains.blue, 1.0), maxGain))
    }

    /// Smallest representable neutral triple for this device.
    var neutralGains: WhiteBalanceGains {
        WhiteBalanceGains(red: 1, green: 1, blue: 1)
    }
}
