import Foundation

/// Verification shared by the shipping sequence settings adapter and local checks.
/// Setter acknowledgement is not evidence that the requested settings converged.
enum SequenceControlVerification {
    static func matches(_ reading: AppliedControlSnapshot,
                        settings: SequenceSettingsSnapshot,
                        generation: ConfigurationGeneration,
                        revision: UInt64,
                        whiteBalanceTarget: WhiteBalanceGains?) -> Bool {
        guard reading.generation == generation, reading.requestRevision == revision,
              reading.settlement.isSettled,
              reading.exposureChoice.mode == settings.exposure.mode,
              settings.aperture.matches(readback: reading),
              CaptureCoordinator.closeEnough(reading.biasEV, settings.biasEV),
              (reading.focusMode == settings.focus.mode || (reading.isFixedFocusCamera && settings.focus.mode != .manual && reading.isFocusAdjusting == false)),
              reading.whiteBalanceMode == settings.whiteBalance.mode else { return false }
        if settings.whiteBalance.mode == .manual && whiteBalanceTarget == nil { return false }
        let target = ControlSettlementPolicy.Target(
            durationSeconds: settings.exposure.durationTargetSeconds,
            iso: settings.exposure.isoTarget,
            focusPosition: settings.focus.mode == .manual ? settings.focus.position : nil,
            redGain: whiteBalanceTarget?.red,
            greenGain: whiteBalanceTarget?.green,
            blueGain: whiteBalanceTarget?.blue,
            lensAperture: settings.aperture.numericTarget,
            apertureAutomatic: reading.isFixedApertureCamera ? nil : settings.aperture.numericTarget.map { _ in false })
        return target.isSatisfied(by: .init(snapshot: reading))
    }
}
