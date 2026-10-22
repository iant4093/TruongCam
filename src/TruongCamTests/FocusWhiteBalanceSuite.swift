import Foundation

// Native test bundles read the app's real types through the module; the
// standalone verifier compiles the app sources into the same executable and
// therefore cannot import a module. XCTest is only available in the native
// bundle, so it gates the import.
#if canImport(XCTest)
@testable import TruongCam
#endif


// TEST_PLAN.md T05, T06 and CONTRACTS.md focus / white-balance rules.
// Pure conversion and validation; no device.

enum FocusWhiteBalanceSuite {
    static let suite = TCSuite(
        id: "T05-T06",
        title: "Focus points and white balance conversion",
        cases: [
            TCCase(id: "T05", title: "Focus tap conversion rejects letterbox and out-of-image points") { r in
                // Preview content rect inside a taller view: the letterbox bands
                // must not convert into a valid device point.
                let geometry = PreviewGeometryMapper(
                    imageDimensions: PixelDimensions(width: 4032, height: 3024),
                    contentRect: TCRect(x: 0, y: 100, width: 390, height: 292.5),
                    isMirrored: false,
                    rotationDegrees: 0,
                    bufferOrientation: 1)

                let centre = geometry.devicePoint(forViewPoint: TCPoint(x: 195, y: 246.25))
                r.check("centre maps to centre",
                        centre != nil && abs(centre!.x - 0.5) < 1e-6 && abs(centre!.y - 0.5) < 1e-6)

                let topBand = geometry.devicePoint(forViewPoint: TCPoint(x: 195, y: 20))
                r.check("point above the image is rejected", topBand == nil)
                let bottomBand = geometry.devicePoint(forViewPoint: TCPoint(x: 195, y: 500))
                r.check("point below the image is rejected", bottomBand == nil)
                let leftOfImage = geometry.devicePoint(forViewPoint: TCPoint(x: -5, y: 246.25))
                r.check("point left of the image is rejected", leftOfImage == nil)

                let topLeftInside = geometry.devicePoint(forViewPoint: TCPoint(x: 0.5, y: 100.5))
                r.check("just inside the top edge is accepted", topLeftInside != nil)
                if let p = topLeftInside {
                    r.check("normalized inside unit square", p.isInsideUnitSquare)
                }

                let limits = FocusLimits(supportsCustomLensPosition: true,
                                         supportsPointOfInterest: true,
                                         supportsContinuousAutoFocus: true,
                                         supportsAutoFocus: true,
                                         positionZeroDirectionVerified: false)
                let good = NormalizedDevicePoint(x: 0.5, y: 0.5)
                r.check("valid point accepted", FocusValidator.validatePointOfInterest((good.x, good.y), limits: limits) == nil)
                let bad = NormalizedDevicePoint(x: 1.4, y: 0.5)
                r.check("outside point rejected",
                        FocusValidator.validatePointOfInterest((bad.x, bad.y), limits: limits) != nil)
            },

            TCCase(id: "T05b", title: "Manual focus requires finite in-range positions and support") { r in
                let supported = FocusLimits(supportsCustomLensPosition: true,
                                           supportsPointOfInterest: true,
                                           supportsContinuousAutoFocus: true,
                                           supportsAutoFocus: true,
                                           positionZeroDirectionVerified: false)
                let unsupported = FocusLimits(supportsCustomLensPosition: false,
                                              supportsPointOfInterest: false,
                                              supportsContinuousAutoFocus: true,
                                              supportsAutoFocus: true,
                                              positionZeroDirectionVerified: false)

                r.check("0 accepted", FocusValidator.validateManualPosition(0, limits: supported) == nil)
                r.check("1 accepted", FocusValidator.validateManualPosition(1, limits: supported) == nil)
                r.check("0.2 endpoint accepted", FocusValidator.validateManualPosition(0.2, limits: supported) == nil)
                r.check("NaN rejected", FocusValidator.validateManualPosition(.nan, limits: supported) != nil)
                r.check("above 1 rejected", FocusValidator.validateManualPosition(1.0001, limits: supported) != nil)
                r.check("below 0 rejected", FocusValidator.validateManualPosition(-0.001, limits: supported) != nil)
                r.check("custom lens position unsupported rejected",
                        FocusValidator.validateManualPosition(0.5, limits: unsupported) != nil)
            },

            TCCase(id: "T06", title: "Temperature/tint converts to legal gains or reports unrepresentable") { r in
                // A stand-in conversion used to prove clamping/reporting logic
                // without a device: gains are derived, then clamped to [1, max].
                let maxGain: Double = 4.0
                let resolver = WhiteBalanceGainResolver(maxGain: maxGain)

                // A representable request keeps exact gains.
                let neutral = WhiteBalanceTemperatureAndTint(temperature: 5500, tint: 0)
                let exact = resolver.resolve(neutral, gainsFromTemperatureTint: { _ in
                    WhiteBalanceGains(red: 1.5, green: 1.0, blue: 2.0)
                })
                if case .exact(let gains) = exact {
                    r.close("red preserved", gains.red, 1.5)
                    r.close("blue preserved", gains.blue, 2.0)
                } else {
                    r.check("expected exact gains", false, "got \(exact)")
                }

                // A request above the device maximum is clamped and labelled.
                let warm = WhiteBalanceTemperatureAndTint(temperature: 9000, tint: 40)
                let clamped = resolver.resolve(warm, gainsFromTemperatureTint: { _ in
                    WhiteBalanceGains(red: 6.0, green: 1.0, blue: 1.0)
                })
                if case .clamped(let requested, let clampedGains) = clamped {
                    r.close("requested kept for display", requested.red, 6.0)
                    r.close("applied clamped to maximum", clampedGains.red, maxGain)
                } else {
                    r.check("expected clamped gains", false, "got \(clamped)")
                }

                // A request below 1.0 cannot be represented at all.
                let unrepresentable = resolver.resolve(
                    WhiteBalanceTemperatureAndTint(temperature: 2000, tint: -150),
                    gainsFromTemperatureTint: { _ in WhiteBalanceGains(red: 0.4, green: 0.5, blue: 0.6) })
                if case .unrepresentable = unrepresentable {
                    r.check("unrepresentable reported", true)
                } else {
                    r.check("expected unrepresentable", false, "got \(unrepresentable)")
                }

                // Non-finite input never reaches gain conversion.
                let nanTemperature = resolver.resolve(
                    WhiteBalanceTemperatureAndTint(temperature: .nan, tint: 0),
                    gainsFromTemperatureTint: { _ in
                        r.check("conversion must not run for non-finite input", false)
                        return WhiteBalanceGains(red: 1, green: 1, blue: 1)
                    })
                if case .unrepresentable = nanTemperature {
                    r.check("NaN temperature rejected before conversion", true)
                } else {
                    r.check("NaN temperature rejected before conversion", false, "got \(nanTemperature)")
                }

                r.check("no conversion available is reported",
                        resolver.resolveWithoutConversion() == .conversionUnavailable)

                r.check("gains out of range detected",
                        WhiteBalanceGains(red: 1.0, green: 0.9, blue: 2.0).allInLegalRange == false)
                r.check("finite gains detected",
                        WhiteBalanceGains(red: 1.0, green: 1.0, blue: .nan).isFinite == false)
            },

            TCCase(id: "T06b", title: "Slider policy domain is not a capability bound") { r in
                let domain = WhiteBalanceSliderDomain.productPolicy
                r.close("policy minimum Kelvin", domain.minKelvin, 1000)
                r.close("policy maximum Kelvin", domain.maxKelvin, 15000)
                r.close("policy tint range", domain.maxTint - domain.minTint, 300)
                // Direct entry beyond the slider domain must still be accepted by
                // the validator if the gains are legal.
                let resolver = WhiteBalanceGainResolver(maxGain: 8.0)
                let beyond = WhiteBalanceTemperatureAndTint(temperature: 20000, tint: 200)
                let result = resolver.resolve(beyond, gainsFromTemperatureTint: { _ in
                    WhiteBalanceGains(red: 1.2, green: 1.0, blue: 3.0)
                })
                if case .exact = result {
                    r.check("finite direct entry beyond slider domain accepted", true)
                } else {
                    r.check("finite direct entry beyond slider domain accepted", false, "got \(result)")
                }
            },
        ])
}
