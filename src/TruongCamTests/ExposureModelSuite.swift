import Foundation

// Native test bundles read the app's real types through the module; the
// standalone verifier compiles the app sources into the same executable and
// therefore cannot import a module. XCTest is only available in the native
// bundle, so it gates the import.
#if canImport(XCTest)
@testable import TruongCam
#endif


// TEST_PLAN.md T01–T04 plus the CONTRACTS.md four-case exposure model.
// These run entirely on pure value types: no device and no setter.

enum ExposureModelSuite {
    static let suite = TCSuite(
        id: "T01-T04",
        title: "Independent Auto/manual exposure model",
        cases: [
            TCCase(id: "T01", title: "Auto -> manual ISO -> manual shutter -> Auto ISO transitions") { r in
                var choice = ExposureChoice.auto
                r.equal("starts Auto", choice.mode, .auto)
                r.check("Auto pins nothing", choice.durationTargetSeconds == nil && choice.isoTarget == nil)

                choice = .settingISOManual(400, from: choice)
                r.equal("ISO priority mode", choice.mode, .isoPriority)
                r.equal("ISO target kept", choice.isoTarget, 400)
                r.check("shutter still automatic", choice.durationTargetSeconds == nil)

                choice = .settingDurationManual(1.0 / 60.0, from: choice)
                r.equal("manual mode", choice.mode, .manual)
                r.equal("duration kept", choice.durationTargetSeconds, 1.0 / 60.0)
                r.equal("unrelated ISO target preserved", choice.isoTarget, 400)

                choice = .settingISOAuto(from: choice)
                r.equal("shutter priority mode", choice.mode, .shutterPriority)
                r.equal("shutter target preserved when ISO returns to Auto",
                        choice.durationTargetSeconds, 1.0 / 60.0)
                r.check("ISO automatic again", choice.isoTarget == nil)

                choice = .settingDurationAuto(from: choice)
                r.equal("fully Auto again", choice.mode, .auto)
            },

            TCCase(id: "T01b", title: "Auto path preserves the other parameter's choice") { r in
                let fromShutter = ExposureChoice.settingISOAuto(
                    from: .shutterPriority(durationSeconds: 2.0))
                r.equal("shutter priority survives ISO -> Auto", fromShutter.mode, .shutterPriority)

                let fromISO = ExposureChoice.settingDurationAuto(from: .isoPriority(iso: 64))
                r.equal("ISO priority survives shutter -> Auto", fromISO.mode, .isoPriority)
                r.equal("ISO value survives", fromISO.isoTarget, 64)

                let manualToISOAuto = ExposureChoice.settingISOAuto(
                    from: .manual(durationSeconds: 0.5, iso: 200))
                r.equal("manual with Auto ISO becomes shutter priority", manualToISOAuto.mode, .shutterPriority)
                r.equal("duration preserved", manualToISOAuto.durationTargetSeconds, 0.5)

                let manualToShutterAuto = ExposureChoice.settingDurationAuto(
                    from: .manual(durationSeconds: 0.5, iso: 200))
                r.equal("manual with Auto shutter becomes ISO priority", manualToShutterAuto.mode, .isoPriority)
                r.equal("ISO preserved", manualToShutterAuto.isoTarget, 200)
            },

            TCCase(id: "T02", title: "Invalid durations, ISOs and bias are rejected before any setter") { r in
                let limits = ExposureLimits(
                    minDurationSeconds: 1.0 / 8000.0, maxDurationSeconds: 1.0,
                    minISO: 32, maxISO: 3200,
                    minBiasEV: -8, maxBiasEV: 8)

                func validate(_ choice: ExposureChoice) -> [ExposureValidationFailure] {
                    ExposureValidator.validate(
                        choice: choice, limits: limits,
                        supportsCustomExposureMode: true,
                        supportsCombination: { _ in true })
                }

                let nan = validate(.shutterPriority(durationSeconds: .nan))
                r.check("NaN duration rejected", nan.contains { if case .nonFiniteDuration = $0 { return true }; return false })

                let infinite = validate(.isoPriority(iso: .infinity))
                r.check("Infinite ISO rejected", infinite.contains { if case .nonFiniteISO = $0 { return true }; return false })

                let zero = validate(.manual(durationSeconds: 0, iso: 100))
                r.check("zero duration rejected", zero.contains { if case .nonPositiveDuration = $0 { return true }; return false })

                let negativeISO = validate(.manual(durationSeconds: 0.01, iso: -50))
                r.check("negative ISO rejected", negativeISO.contains { if case .nonPositiveISO = $0 { return true }; return false })

                let tooLong = validate(.shutterPriority(durationSeconds: 4.0))
                r.check("duration above format maximum rejected",
                        tooLong.contains { if case .durationOutOfRange = $0 { return true }; return false })

                let tooFast = validate(.shutterPriority(durationSeconds: 1.0 / 20000.0))
                r.check("duration below format minimum rejected",
                        tooFast.contains { if case .durationOutOfRange = $0 { return true }; return false })

                let tooHighISO = validate(.isoPriority(iso: 12800))
                r.check("ISO above format maximum rejected",
                        tooHighISO.contains { if case .isoOutOfRange = $0 { return true }; return false })

                r.check("valid manual accepted", validate(.manual(durationSeconds: 0.01, iso: 100)).isEmpty)
                r.check("valid Auto accepted", validate(.auto).isEmpty)

                r.check("bias NaN rejected", ExposureValidator.validateBias(.nan, limits: limits) != nil)
                r.check("bias above maximum rejected", ExposureValidator.validateBias(9, limits: limits) != nil)
                r.check("bias inside range accepted", ExposureValidator.validateBias(-2, limits: limits) == nil)
            },

            TCCase(id: "T02b", title: "Custom exposure mode unsupported blocks priority and manual") { r in
                let limits = ExposureLimits(minDurationSeconds: 1.0 / 8000, maxDurationSeconds: 1,
                                           minISO: 32, maxISO: 3200, minBiasEV: -8, maxBiasEV: 8)
                let failures = ExposureValidator.validate(
                    choice: .manual(durationSeconds: 0.01, iso: 100),
                    limits: limits,
                    supportsCustomExposureMode: false,
                    supportsCombination: { _ in true })
                r.check("reports customExposureModeUnsupported",
                        failures.contains(.customExposureModeUnsupported))

                let autoFailures = ExposureValidator.validate(
                    choice: .auto, limits: limits,
                    supportsCustomExposureMode: false,
                    supportsCombination: { _ in false })
                r.check("Auto does not require custom exposure mode", autoFailures.isEmpty)
            },

            TCCase(id: "T02c", title: "Unsupported priority combination is a typed failure, not a clamp") { r in
                let limits = ExposureLimits(minDurationSeconds: 1.0 / 8000, maxDurationSeconds: 1,
                                           minISO: 32, maxISO: 3200, minBiasEV: -8, maxBiasEV: 8)
                let failures = ExposureValidator.validate(
                    choice: .manual(durationSeconds: 0.01, iso: 100),
                    limits: limits,
                    supportsCustomExposureMode: true,
                    supportsCombination: { _ in false })
                r.check("reports unsupportedCombination",
                        failures.contains(.unsupportedCombination(.manual)))
            },

            TCCase(id: "T03", title: "Stale limits from another lens are not silently reused") { r in
                // Manual choice legal on the previous lens but outside the new lens limits.
                let wideLimits = ExposureLimits(minDurationSeconds: 1.0 / 8000, maxDurationSeconds: 1,
                                               minISO: 32, maxISO: 3200, minBiasEV: -8, maxBiasEV: 8)
                let ultraWideLimits = ExposureLimits(minDurationSeconds: 1.0 / 4000, maxDurationSeconds: 0.5,
                                                     minISO: 50, maxISO: 1600, minBiasEV: -8, maxBiasEV: 8)
                let prior = ExposureChoice.manual(durationSeconds: 0.8, iso: 3200)
                r.check("legal on the previous lens",
                        ExposureValidator.validate(choice: prior, limits: wideLimits,
                                                   supportsCustomExposureMode: true,
                                                   supportsCombination: { _ in true }).isEmpty)
                let afterSwitch = ExposureValidator.validate(choice: prior, limits: ultraWideLimits,
                                                             supportsCustomExposureMode: true,
                                                             supportsCombination: { _ in true })
                r.check("review-required after lens switch",
                        afterSwitch.contains { if case .durationOutOfRange = $0 { return true }; return false })
                r.check("ISO also flagged",
                        afterSwitch.contains { if case .isoOutOfRange = $0 { return true }; return false })
            },

            TCCase(id: "T04", title: "Duration formatting is photographic and never zero-filled") { r in
                r.equal("1/125", ExposureFormatting.duration(1.0 / 125.0), "1/125s")
                r.equal("1/8000", ExposureFormatting.duration(1.0 / 8000.0), "1/8000s")
                r.equal("2 seconds", ExposureFormatting.duration(2.0), "2s")
                r.equal("non-finite", ExposureFormatting.duration(.nan), "—")
                r.equal("zero", ExposureFormatting.duration(0), "—")
                r.equal("negative", ExposureFormatting.duration(-1), "—")
                r.equal("ISO 100", ExposureFormatting.iso(100), "100")
                r.equal("ISO unknown", ExposureFormatting.iso(.infinity), "—")
                r.equal("bias signed", ExposureFormatting.bias(1.5), "+1.5 EV")
                r.equal("unknown distance is not a number", ExposureFormatting.meters(nil), "—")
            },

            TCCase(id: "T04b", title: "Photographic stepping stays within supplied bounds only via validation") { r in
                var value = 1.0 / 125.0
                value = PhotographicScale.nextStop(value, step: PhotographicScale.thirdStop, up: true)
                r.close("one third stop slower", value, (1.0 / 125.0) * pow(2, 1.0 / 3.0), tolerance: 1e-12)
                value = PhotographicScale.nextStop(value, step: PhotographicScale.thirdStop, up: false)
                r.close("returns to origin", value, 1.0 / 125.0, tolerance: 1e-12)
                r.close("standard duration snapping picks 1/125",
                        PhotographicScale.nearestStandardDuration(to: 0.0079), 1.0 / 125.0, tolerance: 1e-9)
                r.close("snapping a long exposure stays conventional",
                        PhotographicScale.nearestStandardDuration(to: 2.05), 2.0, tolerance: 1e-9)
                r.close("bulb-ish long end is a power of two",
                        PhotographicScale.nearestStandardDuration(to: 30.5), 30.0, tolerance: 1e-9)
                let ladder = PhotographicScale.standardDurations
                r.check("ladder contains 1/125 exactly",
                        ladder.contains(1.0 / 125.0),
                        "ladder head \(ladder.prefix(8)) tail \(ladder.suffix(4))")
                r.check("ladder contains 1 s and a long exposure",
                        ladder.contains(1.0) && ladder.contains(64.0),
                        "ladder head \(ladder.prefix(8)) tail \(ladder.suffix(4))")
                r.check("ladder is sorted descending",
                        zip(PhotographicScale.standardDurations, PhotographicScale.standardDurations.dropFirst())
                            .allSatisfy { $0 > $1 })
            },
        ])
}
