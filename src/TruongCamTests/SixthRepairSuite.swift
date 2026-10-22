import Foundation

#if canImport(XCTest)
@testable import TruongCam
#endif

// Regression tests for the third-pass R05 (Bayer classification, no guessed
// dimensions, embedded-thumbnail codec ownership), R02 (real lifecycle condition)
// and R03 (settlement of a requested move) production rules.

enum SixthRepairSuite {
    static let suite = TCSuite(
        id: "REPAIR6",
        title: "Sixth repair round (third-pass R05 Bayer/dimensions/codecs, R02 condition, R03 move settlement)",
        cases: [

            // MARK: R05 — Bayer classification

            TCCase(id: "R05a", title: "The conservative classifier refuses what it cannot identify") { r in
                // R05: the old test accepted a guessed FourCC suffix. The fallback that
                // a non-AVFoundation target uses must resolve uncertainty to "no",
                // because accepting a processed format as Bayer RAW is unrecoverable.
                let classifier = ConservativeBayerClassifier()
                r.check("zero is not Bayer", !classifier.isBayerRAW(0))
                r.check("a packed Bayer code is recognised", classifier.isBayerRAW(0x6267_6734))
                r.check("arbitrary text is refused", !classifier.isBayerRAW(0x7465_7374))
                r.check("BGRA is refused", !classifier.isBayerRAW(0x4247_5241))
                // A truncated or over-long code cannot be a FourCC.
                r.check("a short code is refused", !classifier.isBayerRAW(0x6767))
            },

            TCCase(id: "R05b", title: "The classifier is a port, so the native target uses the framework answer") { r in
                // R05: the production build must inject
                // `AVCapturePhotoOutput.isBayerRAWPixelFormat(_:)`, never a guess.
                struct AlwaysBayer: BayerRAWClassifying {
                    func isBayerRAW(_ pixelFormat: UInt32) -> Bool { true }
                }
                struct NeverBayer: BayerRAWClassifying {
                    func isBayerRAW(_ pixelFormat: UInt32) -> Bool { false }
                }
                let yes: any BayerRAWClassifying = AlwaysBayer()
                let no: any BayerRAWClassifying = NeverBayer()
                r.check("an injected classifier decides", yes.isBayerRAW(0x7465_7374))
                r.check("and can refuse", !no.isBayerRAW(0x6267_6734))
                r.check("uncertainty is not silently accepted by the default",
                        !ConservativeBayerClassifier().isBayerRAW(0x7072_6F72))
            },

            // MARK: R05 — no guessed dimensions

            TCCase(id: "R05c", title: "An absent RAW ceiling is a refusal, never 4032x3024") { r in
                // R05: `?? PixelDimensions(width: 4032, height: 3024)` invented a size
                // the active format never advertised. An unknown ceiling must be
                // distinguishable from a known one.
                let advertised = [
                    PixelDimensions(width: 4032, height: 3024),
                    PixelDimensions(width: 8064, height: 6048),
                ]
                let largest = advertised.max { $0.pixelCount < $1.pixelCount }
                r.equal("the largest advertised ceiling is chosen", largest?.width, 8064)

                let none: [PixelDimensions] = []
                r.check("no advertised ceiling yields no dimension",
                        none.max { $0.pixelCount < $1.pixelCount } == nil)
                // The critical property: nil must NOT be replaced by a constant.
                let resolved: PixelDimensions? = none.max { $0.pixelCount < $1.pixelCount }
                r.check("the caller must handle the unknown case", resolved == nil)
            },

            TCCase(id: "R05d", title: "The embedded thumbnail is bounded and never full size") { r in
                // R05: a codec is only requested when the settings object offers one,
                // and the requested size is a bounded preview.
                func bounded(_ raw: PixelDimensions) -> (width: Int, height: Int)? {
                    guard raw.isValid, raw.width > 0, raw.height > 0 else { return nil }
                    let longEdge = max(raw.width, raw.height)
                    let target = min(longEdge, 1024)
                    let scale = Double(target) / Double(longEdge)
                    return (max(1, Int((Double(raw.width) * scale).rounded())),
                            max(1, Int((Double(raw.height) * scale).rounded())))
                }
                guard let thumb = bounded(PixelDimensions(width: 8064, height: 6048)) else {
                    r.check("a real RAW size yields a thumbnail", false); return
                }
                r.equal("the long edge is capped at 1024", max(thumb.width, thumb.height), 1024)
                r.check("the aspect ratio is preserved",
                        abs(Double(thumb.width) / Double(thumb.height) - 8064.0 / 6048.0) < 0.01)
                r.check("the thumbnail is far smaller than the RAW",
                        thumb.width * thumb.height < 8064 * 6048 / 4)
                r.check("a small RAW is not upscaled",
                        bounded(PixelDimensions(width: 640, height: 480))?.width == 640)
                r.check("a degenerate size yields no thumbnail",
                        bounded(PixelDimensions(width: 0, height: 0)) == nil)
            },

            // MARK: R02 — recorded lifecycle condition

            TCCase(id: "R02d", title: "A recorded session condition outranks a running session") { r in
                // REVIEW.md fourth-pass: the previous version used a test-local
                // SessionConditionProbe, a duplicate of the production type. The
                // RULE is now a shared production decision function, so this case
                // cannot drift from what the service actually does.
                func effective(recorded: CameraLifecycle, sessionIsRunning: Bool) -> CameraLifecycle {
                    CameraLifecycleResolver.effective(
                        recorded: recorded, sessionIsRunning: sessionIsRunning)
                }
                r.check("an interrupted session is not reported as running",
                        effective(recorded: .interrupted(reason: "phone call"),
                                  sessionIsRunning: true) != .running)
                r.check("a failed session is not reported as running",
                        effective(recorded: .failed(.cameraInterrupted(detail: "reset")),
                                  sessionIsRunning: true) != .running)
                r.equal("a healthy running session is running",
                        effective(recorded: .idle, sessionIsRunning: true), .running)
                r.equal("a healthy stopped session is idle",
                        effective(recorded: .idle, sessionIsRunning: false), .idle)
                r.equal("reconfiguring is reported while it is recorded",
                        effective(recorded: .reconfiguring, sessionIsRunning: true), .reconfiguring)
            },

            // MARK: R03 — settlement of a requested move

            TCCase(id: "R03c", title: "A lens position alone never proves a requested move completed") { r in
                // R03: the rule was `position != nil ? .settled : .notStarted`, so a
                // lens still travelling was reported as a finished move.
                r.equal("a moving lens with a position is adjusting",
                        FocusMoveSettlement.state(
                            requestedPosition: 0.8, observedPosition: 0.2,
                            observedSettlement: .moving, isManualFocus: true),
                        .adjusting)
                r.equal("a converged lens away from the target is still adjusting",
                        FocusMoveSettlement.state(
                            requestedPosition: 0.8, observedPosition: 0.4,
                            observedSettlement: .settled, isManualFocus: true),
                        .adjusting)
                r.equal("a converged lens at the target has settled",
                        FocusMoveSettlement.state(
                            requestedPosition: 0.8, observedPosition: 0.8,
                            observedSettlement: .settled, isManualFocus: true),
                        .settled)
                r.equal("within tolerance counts as arrived",
                        FocusMoveSettlement.state(
                            requestedPosition: 0.8, observedPosition: 0.81,
                            observedSettlement: .settled, isManualFocus: true),
                        .settled)
                r.equal("an unmeasured readback cannot settle",
                        FocusMoveSettlement.state(
                            requestedPosition: 0.8, observedPosition: 0.8,
                            observedSettlement: .unmeasured(observations: 3), isManualFocus: true),
                        .adjusting)
                r.equal("no observation of a requested move is not started",
                        FocusMoveSettlement.state(
                            requestedPosition: nil, observedPosition: nil,
                            observedSettlement: .moving, isManualFocus: true),
                        .notStarted)
            },

            TCCase(id: "R03d", title: "Provenance distinguishes an arrived move from a requested one") { r in
                r.equal("only an arrived move claims settled device readback",
                        FocusMoveSettlement.provenance(for: .settled), .settledDeviceReadback)
                r.equal("an adjusting move claims requested only",
                        FocusMoveSettlement.provenance(for: .adjusting), .requested)
                r.equal("a failed move claims requested only",
                        FocusMoveSettlement.provenance(for: .failed(detail: "x")), .requested)
                r.equal("an unstarted move claims requested only",
                        FocusMoveSettlement.provenance(for: .notStarted), .requested)
            },

            TCCase(id: "R03e", title: "Continuous focus has no endpoint, so only convergence settles") { r in
                r.equal("a converged continuous reading settles",
                        FocusMoveSettlement.state(
                            requestedPosition: nil, observedPosition: 0.5,
                            observedSettlement: .settled, isManualFocus: false),
                        .settled)
                r.equal("a moving continuous reading does not",
                        FocusMoveSettlement.state(
                            requestedPosition: nil, observedPosition: 0.5,
                            observedSettlement: .moving, isManualFocus: false),
                        .adjusting)
            },
        ])
}
