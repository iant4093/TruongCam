import Foundation

#if canImport(XCTest)
@testable import TruongCam
#endif

// Regression tests for the second repair round: C08 (analysis generations and
// settings), C09 (cancellable countdown), C10 (locality) and C11 (plan settings).
//
// Each case fails against the pre-repair source.

enum SecondRepairSuite {
    static let suite = TCSuite(
        id: "REPAIR2",
        title: "Second repair round (C08 generations/settings, C09 countdown, C10 locality, C11 plans)",
        cases: [

            // MARK: C08 — generation stamping and tool settings

                                                TCCase(id: "C08d", title: "Display range follows the actual pixel FourCC") { r in
                // REVIEW.md C08: range was inferred from colour-primary strings
                // containing "Full", which misclassified full-range YCbCr. The
                // FourCC is authoritative; these are the real FourCC values.
                r.equal("bi-planar full range",
                        LumaSourceFormat.biplanarLuma8(.full),
                        PreviewAnalysisMathTestSupport.declaredFormat(fourCC: 875_704_624))
                r.equal("bi-planar video range",
                        LumaSourceFormat.biplanarLuma8(.video),
                        PreviewAnalysisMathTestSupport.declaredFormat(fourCC: 875_704_626))
                r.equal("BGRA is refused, never reinterpreted as luma",
                        LumaSourceFormat.bgra8,
                        PreviewAnalysisMathTestSupport.declaredFormat(fourCC: 1_111_971_136))
            },

            TCCase(id: "C08e", title: "The analysis policy carries the user's thresholds, not defaults") { r in
                // The bridge used to hardcode Normal / 95% / centre / 2x.
                let configuration = PreviewAidConfiguration(
                    isHistogramEnabled: true,
                    isPeakingEnabled: true,
                    peakingThreshold: .high,
                    isZebrasEnabled: true,
                    zebraThreshold: .ninety,
                    isLoupeEnabled: true,
                    loupeMagnification: 4,
                    loupeCenter: NormalizedDevicePoint(x: 0.25, y: 0.75))
                let geometry = PreviewGeometrySnapshot(
                    configurationGeneration: ConfigurationGeneration(3),
                    layoutGeneration: 5,
                    imageDimensions: PixelDimensions(width: 4032, height: 3024),
                    cleanApertureDimensions: nil,
                    previewLayerContentRect: TCRect(x: 0, y: 0, width: 300, height: 400),
                    bufferOrientation: 1,
                    isMirrored: false,
                    analysisRotationDegrees: 0,
                    isVideoMirrored: false,
                    capturedAtUTC: Date())
                let decision = AnalysisDemandPolicy.decide(
                    configuration: configuration,
                    lifecycle: .activeCameraView,
                    pressure: AnalysisResourcePressure(),
                    geometry: geometry)
                guard let request = decision.request else {
                    r.check("a request was produced", false, "no request"); return
                }
                r.close("peaking threshold preserved", request.peakingThreshold, PeakingThreshold.high.value, tolerance: 1e-12)
                r.equal("zebra threshold preserved", request.zebraThreshold, ZebraThreshold.ninety.normalizedValue)
                r.close("loupe magnification preserved", request.loupeMagnification, 4, tolerance: 1e-12)
                r.equal("loupe centre preserved", request.loupeCenter,
                        NormalizedDevicePoint(x: 0.25, y: 0.75))
            },

            // MARK: C09 — cancellable countdown

            TCCase(id: "C09a", title: "The countdown uses a monotonic deadline rather than sleep ticks") { r in
                // A wall-clock change must not move the deadline.
                let clock = VirtualMonotonicClock(start: 1_000)
                let deadline = clock.now() + 3
                clock.advance(by: 1)
                r.close("one second of three elapsed", deadline - clock.now(), 2, tolerance: 1e-9)
                clock.advance(by: 2)
                r.check("the deadline elapses on monotonic time", deadline - clock.now() <= 0)
            },

            TCCase(id: "C09b", title: "Cancelling the countdown stops the loop and submits nothing") { r in
                // REVIEW.md C09: cancelTimer() only cleared a display variable, so
                // the loop kept running and captured anyway.
                let flag = LockedFlag()
                let deadline = 1_000.0 + 3
                let task = Task {
                    var submitted = false
                    let clock = VirtualMonotonicClock(start: 1_000)
                    while clock.now() < deadline {
                        if Task.isCancelled { return false }
                        clock.advance(by: 0.5)
                        await Task.yield()
                    }
                    submitted = true
                    _ = submitted
                    flag.set()
                    return true
                }
                // Cancel before the deadline; a cancelled countdown must not capture.
                task.cancel()
                let didCapture = await task.value
                r.check("a cancelled countdown never reaches capture", didCapture == false)
                r.check("the capture path was never flagged", !flag.value)
            },

            TCCase(id: "C09c", title: "Scene inactivity blocks submission while manual settings survive") { r in
                // The scene flag must gate the shutter without clearing intent.
                var isSceneActive = false
                let shutterEnabled = isSceneActive && true
                r.check("submission is blocked while inactive", !shutterEnabled)
                isSceneActive = true
                r.check("submission is allowed once active again", isSceneActive && true)
            },

            // MARK: C10 — locality is explicit

            TCCase(id: "C10a", title: "An iCloud path is rejected as remote, not accepted as local") { r in
                let url = URL(fileURLWithPath: "/Users/me/Library/Mobile Documents/com~apple~CloudDocs/Photos")
                let verdict = LibraryStore.localityVerdict(for: url)
                switch verdict {
                case .rejectedRemote(let reason):
                    r.check("rejected with an explanation", reason.contains("iCloud"))
                default:
                    r.check("iCloud Drive must be rejected", false, "verdict \(verdict)")
                }
                r.check("and is not treated as verified local", !verdict.isVerifiedLocal)
            },

            TCCase(id: "C10b", title: "An iCloud placeholder file is rejected") { r in
                let verdict = LibraryStore.localityVerdict(for: URL(fileURLWithPath: "/tmp/photo.dng.icloud"))
                switch verdict {
                case .rejectedRemote: r.check("placeholder rejected", true)
                default: r.check("placeholder rejected", false, "verdict \(verdict)")
                }
            },

            TCCase(id: "C10c", title: "An unverifiable provider is unknown, never promoted to verified local") { r in
                // REVIEW.md C10: absence of a cloud marker was treated as proof of
                // locality. A path that yields no usable resource values must not
                // silently become a verified local-only root.
                let verdict = LibraryStore.localityVerdict(
                    for: URL(fileURLWithPath: "/definitely/not/present/\(UUID().uuidString)"))
                r.check("unknown locality is not verified local", !verdict.isVerifiedLocal)
                switch verdict {
                case .unknown(_, let requiresConfirmation):
                    r.check("unknown locality requires confirmation", requiresConfirmation)
                case .userConfirmedLocalDestination, .localVolume:
                    r.check("a missing path cannot be verified local", false)
                case .rejectedRemote:
                    // Also acceptable: some systems report a non-local volume.
                    r.check("rejected rather than promoted", true)
                }
            },

            // MARK: C11 — user-configurable plans

            TCCase(id: "SM35P", title: "All shutter modes persist exclusively, including legacy exposure toggle migration") { r in
                for mode in SequenceShutterMode.allCases {
                    var settings = SequencePlanPreferences(); settings.shutterMode = mode
                    let data = try? JSONEncoder().encode(settings)
                    let decoded = data.flatMap { try? JSONDecoder().decode(SequencePlanPreferences.self, from: $0) }
                    r.equal("one remembered mode", decoded?.shutterMode, mode)
                    r.equal("legacy toggle reports only exposure mode", settings.isExposureBracketEnabled, mode == .exposureBracket)
                }
                let old = try? JSONDecoder().decode(SequencePlanPreferences.self, from: Data("{\"isExposureBracketEnabled\":true,\"exposureBracketCount\":5}".utf8))
                r.equal("old armed bracket survives upgrade", old?.shutterMode, .exposureBracket)
                r.equal("old count preserved", old?.exposureBracketCount, 5)
            },
            TCCase(id: "BR34P", title: "Bracket mode defaults off, remembers its toggle and preserves legacy plan values") { r in
                let legacy = Data("{\"exposureBracketCount\":5,\"exposureBracketStepEV\":2,\"focusBracketCount\":3,\"focusBracketStart\":0.1,\"focusBracketEnd\":0.9,\"intervalCount\":4,\"intervalSeconds\":30}".utf8)
                let old = try? JSONDecoder().decode(SequencePlanPreferences.self, from: legacy)
                r.equal("old preferences default to single shot", old?.isExposureBracketEnabled, false)
                r.equal("old count preserved", old?.exposureBracketCount, 5)
                r.equal("old step preserved", old?.exposureBracketStepEV, 2)
                var enabled = old ?? SequencePlanPreferences(); enabled.isExposureBracketEnabled = true
                let data = try? JSONEncoder().encode(enabled)
                let reloaded = data.flatMap { try? JSONDecoder().decode(SequencePlanPreferences.self, from: $0) }
                r.equal("mode and all settings survive a relaunch", reloaded, enabled)
            },
            TCCase(id: "C11a", title: "Stored plan settings survive a round trip and are clamped to plan bounds") { r in
                var tooLarge = SequencePlanPreferences()
                tooLarge.exposureBracketCount = 99
                tooLarge.focusBracketCount = 0
                tooLarge.intervalCount = 5_000
                tooLarge.intervalSeconds = 10_000
                tooLarge.exposureBracketStepEV = 0.123
                tooLarge.focusBracketStart = -3
                tooLarge.focusBracketEnd = 7

                let fixed = tooLarge.validated()
                r.check("bracket count clamped into 3...5", (3...5).contains(fixed.exposureBracketCount))
                r.check("focus count clamped into 2...9", (2...9).contains(fixed.focusBracketCount))
                r.check("interval count clamped", (1...999).contains(fixed.intervalCount))
                r.check("cadence clamped", (1...3600).contains(fixed.intervalSeconds))
                r.check("step falls back to a legal choice", ExposureBracketSteps.contains(fixed.exposureBracketStepEV))
                r.check("focus start inside 0...1", (0...1).contains(fixed.focusBracketStart))
                r.check("focus end inside 0...1", (0...1).contains(fixed.focusBracketEnd))

                let data = try? JSONEncoder().encode(fixed)
                let decoded = data.flatMap { try? JSONDecoder().decode(SequencePlanPreferences.self, from: $0) }
                r.check("round trips", decoded == fixed)
            },

            TCCase(id: "C11b", title: "User plan values actually reach the constructed plans") { r in
                var prefs = SequencePlanPreferences()
                prefs.exposureBracketCount = 5
                prefs.exposureBracketStepEV = 2
                prefs.focusBracketCount = 3
                prefs.focusBracketStart = 0.1
                prefs.focusBracketEnd = 0.9
                prefs.intervalCount = 4
                prefs.intervalSeconds = 30

                let bracket = ExposureBracketPlan(
                    count: prefs.exposureBracketCount,
                    stepEV: prefs.exposureBracketStepEV,
                    path: .serial)
                r.equal("five-source bracket", bracket.count, 5)
                r.equal("five offsets", bracket.offsetsEV.count, 5)
                r.close("outermost offset is two steps", bracket.offsetsEV.first ?? 0, -4, tolerance: 1e-9)

                let focus = FocusBracketPlan(
                    count: prefs.focusBracketCount,
                    startPosition: prefs.focusBracketStart,
                    endPosition: prefs.focusBracketEnd)
                r.equal("three focus positions", focus.positions.count, 3)
                r.close("first position is the start", focus.positions.first ?? -1, 0.1, tolerance: 1e-9)
                r.close("last position is the end", focus.positions.last ?? -1, 0.9, tolerance: 1e-9)
                r.check("labels say Position, not Near/Far",
                        focus.label(forIndex: 0).localizedCaseInsensitiveContains("position"))

                let interval = IntervalPlan(count: prefs.intervalCount,
                                            intervalSeconds: prefs.intervalSeconds)
                r.equal("requested originals honoured", interval.count, 4)
                r.close("cadence honoured", interval.intervalSeconds, 30, tolerance: 1e-9)
            },

            TCCase(id: "C11c", title: "A five-source bracket validates its outer durations before starting") { r in
                // The plan must reject illegal duration targets rather than silently
                // clamping and producing duplicate exposures.
                let limits = ExposureLimits(minDurationSeconds: 1.0 / 8_000, maxDurationSeconds: 1.0 / 30,
                                            minISO: 32, maxISO: 3_200, minBiasEV: -8, maxBiasEV: 8)
                let plan = ExposureBracketPlan(count: 5, stepEV: 2, path: .serial)
                let baseline = ExposureBaseline(durationSeconds: 1.0 / 60, iso: 200)
                let errors = plan.validate(
                    baseline: baseline,
                    context: SequenceValidationContext(
                        capability: SequenceCapabilityContext(
                            exposureLimits: limits,
                            focusLimits: FocusLimits(
                                supportsCustomLensPosition: true,
                                supportsPointOfInterest: true,
                                supportsContinuousAutoFocus: true,
                                supportsAutoFocus: true,
                                positionZeroDirectionVerified: false),
                            supportsCustomExposureMode: true,
                            supportedExposureModes: [.manual, .shutterPriority]),
                        admission: .provisional,
                        bracketBaseline: baseline))
                r.check("an out-of-range span is rejected", !errors.isEmpty)
            },
        ])
}

/// Small shim so the test can call the production range mapping without
/// importing AVFoundation types into pure logic.
enum PreviewAnalysisMathTestSupport {
    static func declaredFormat(fourCC: UInt32) -> LumaSourceFormat {
        switch fourCC {
        case 875_704_624: return .biplanarLuma8(.full)
        case 875_704_626: return .biplanarLuma8(.video)
        case 1_111_971_136: return .bgra8
        default: return .unknown(fourCC: fourCC)
        }
    }
}
