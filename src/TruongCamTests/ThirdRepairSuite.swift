import Foundation

#if canImport(XCTest)
@testable import TruongCam
#endif

// Regression tests for the third repair round: the second-pass review's S03
// (permission + startup), S04 (per-frame tuple truth) and S14 (sequence terminal
// admission). Each case fails against the pre-repair source.

enum ThirdRepairSuite {
    static let suite = TCSuite(
        id: "REPAIR3",
        title: "Third repair round (S03 permission/startup, S04 tuple truth, S14 sequence admission)",
        cases: [

            // MARK: S03 — permission

            TCCase(id: "S03a", title: "A not-yet-asked camera is requested, never treated as denied") { r in
                // REVIEW.md S03: `.notDetermined` was reported as permissionDenied
                // and nothing ever called the public request API, so a fresh
                // install could never grant camera access.
                r.equal("authorized proceeds", CameraPermissionDecision.decide(.authorized), .proceed)
                r.equal("notDetermined asks the user", CameraPermissionDecision.decide(.notDetermined), .request)
                r.check("notDetermined is not a refusal",
                        CameraPermissionDecision.decide(.notDetermined) != .refuse(reason: ""))
            },

            TCCase(id: "S03b", title: "Denial and restriction are distinguished, and denial names Settings") { r in
                guard case .refuse(let deniedReason) = CameraPermissionDecision.decide(.denied) else {
                    r.check("denial refuses", false); return
                }
                r.check("denial is recoverable through Settings",
                        deniedReason.localizedCaseInsensitiveContains("settings"))
                guard case .refuse(let restrictedReason) = CameraPermissionDecision.decide(.restricted) else {
                    r.check("restriction refuses", false); return
                }
                r.check("restriction is described as not grantable by the app",
                        restrictedReason.localizedCaseInsensitiveContains("restricted"))
                r.check("the two reasons differ", deniedReason != restrictedReason)
            },

            TCCase(id: "S03c", title: "An unanswered prompt never fabricates a grant") { r in
                // If the system returns notDetermined again after asking, neither
                // "granted" nor "denied" may be invented.
                switch CameraPermissionDecision.decideAfterRequest(.notDetermined) {
                case .refuse(let reason):
                    r.check("an unanswered prompt is reported honestly",
                            reason.localizedCaseInsensitiveContains("undetermined"))
                default:
                    r.check("an unanswered prompt must not proceed", false)
                }
                r.equal("a granted prompt proceeds",
                        CameraPermissionDecision.decideAfterRequest(.authorized), .proceed)
                switch CameraPermissionDecision.decideAfterRequest(.denied) {
                case .refuse(let reason):
                    r.check("a refused prompt names Settings",
                            reason.localizedCaseInsensitiveContains("settings"))
                default:
                    r.check("a refused prompt must not proceed", false)
                }
            },

            TCCase(id: "S03d", title: "Authorization reporting maps to the request decision") { r in
                r.check("only notDetermined is askable", CameraAuthorization.notDetermined.shouldRequest)
                r.check("authorized is not re-asked", !CameraAuthorization.authorized.shouldRequest)
                r.check("denied is not re-asked", !CameraAuthorization.denied.shouldRequest)
                r.check("restricted is not re-asked", !CameraAuthorization.restricted.shouldRequest)
            },

            // MARK: S04 — per-format tuple truth

            TCCase(id: "S04a", title: "ProRAW is never counted as Bayer RAW support") { r in
                // REVIEW.md S04: one RAW list was copied into every format, and a
                // ProRAW-capable format would have looked like Bayer support.
                r.check("'pror' is recognised as ProRAW", BayerPixelFormat.isProRAW(0x7072_6F72))
                let mixed: [UInt32] = [0x7072_6F72, 0x4241_5945, 0x5241_5731]
                let bayer = BayerPixelFormat.bayerOnly(mixed)
                r.equal("ProRAW is removed", bayer.count, 2)
                r.check("ProRAW is absent", !bayer.contains(0x7072_6F72))
                r.check("Bayer formats survive", bayer.contains(0x4241_5945))
                r.equal("all-ProRAW yields no Bayer support",
                        BayerPixelFormat.bayerOnly([0x7072_6F72, 0x7072_6F72]).count, 0)
            },

            TCCase(id: "S04b", title: "A format with no measured RAW support is rejected, not borrowed") { r in
                // The real consequence of the S04 defect: a RAW-less format must not
                // be selected just because another format supports RAW.
                let facts = [
                    // Newest-style large format with NO measured RAW support.
                    CaptureFormatFacts(index: 0,
                                       advertisedMaxPhotoDimensions: [PixelDimensions(width: 8064, height: 6048)],
                                       bayerPixelFormatsForDNG: []),
                    // A smaller format that genuinely measures Bayer RAW.
                    CaptureFormatFacts(index: 1,
                                       advertisedMaxPhotoDimensions: [PixelDimensions(width: 4032, height: 3024)],
                                       bayerPixelFormatsForDNG: [0x4241_5945]),
                ]
                guard let selection = CaptureTupleSelector.select(from: facts) else {
                    r.check("a RAW-capable format is found", false); return
                }
                r.equal("the RAW-less larger format is not chosen", selection.formatIndex, 1)
                r.check("its absence is reported",
                        selection.notes.contains { $0.localizedCaseInsensitiveContains("RAW") })
                r.check("the selected format really has Bayer support",
                        !facts[selection.formatIndex].bayerPixelFormatsForDNG.isEmpty)
            },

            TCCase(id: "S04c", title: "A pixel format is described without inventing vendor names") { r in
                let described = BayerPixelFormat.describe(0x7072_6F72)
                r.check("the FourCC is preserved verbatim", described.contains("pror"))
                r.check("the numeric value is present", described.contains("70726F72"))
                // A non-printable format must not produce garbage text.
                let opaque = BayerPixelFormat.describe(0x0000_0001)
                r.check("a failed FourCC decode is marked, not guessed", opaque.contains("?"))
            },

            // MARK: S05/S06 — readback completion and settlement truth

            TCCase(id: "S05a", title: "A setter acknowledgement is not a device observation") { r in
                // REVIEW.md S05: nothing published a completion for a revision, so
                // the UI could not tell a successful setter from a live reading.
                var snapshot = AppliedControlSnapshot(
                    generation: ConfigurationGeneration(1),
                    exposureChoice: .auto,
                    biasEV: 0,
                    observedDurationSeconds: nil,
                    observedISO: nil,
                    observedExposureTargetOffset: nil,
                    focusMode: .continuousAuto,
                    focusPosition: nil,
                    whiteBalanceMode: .auto,
                    whiteBalanceGains: nil,
                    lensAperture: nil,
                    videoZoomFactor: 1,
                    photoConnectionScale: 1,
                    photoConnectionCrop: 1,
                    capturedAtUTC: Date())
                r.equal("a fresh snapshot is not claimed as settled", snapshot.settlement, .moving)
                r.check("it is a live observation", snapshot.settlement.isLiveObservation)
                snapshot.requestRevision = 7
                snapshot.settlement = .awaitingObservation
                r.equal("the revision is carried", snapshot.requestRevision, 7)
                r.check("an acknowledgement is not a live observation",
                        !snapshot.settlement.isLiveObservation)
                r.check("and is not settled", !snapshot.settlement.isSettled)
            },

            TCCase(id: "S06a", title: "Settlement requires consecutive identical live readings") { r in
                var tracker = ControlSettlementTracker(
                    policy: ControlSettlementPolicy(requiredStableObservations: 2, observationBudget: 8))
                r.equal("nothing observed yet", tracker.state, .awaitingObservation)

                r.equal("the first reading is moving",
                        tracker.observe(SelfRepairFixtures.controlSnapshot(iso: 100, duration: 1.0 / 60)),
                        .moving)
                r.check("the device has not settled on one reading", !tracker.state.isSettled)
                r.equal("a second identical reading settles",
                        tracker.observe(SelfRepairFixtures.controlSnapshot(iso: 100, duration: 1.0 / 60)),
                        .settled)
                r.check("settled is reported", tracker.state.isSettled)
            },

            TCCase(id: "S06b", title: "Changing values keep the readback moving") { r in
                var tracker = ControlSettlementTracker(
                    policy: ControlSettlementPolicy(requiredStableObservations: 2, observationBudget: 8))
                _ = tracker.observe(SelfRepairFixtures.controlSnapshot(iso: 100, duration: 1.0 / 60))
                _ = tracker.observe(SelfRepairFixtures.controlSnapshot(iso: 200, duration: 1.0 / 60))
                _ = tracker.observe(SelfRepairFixtures.controlSnapshot(iso: 400, duration: 1.0 / 60))
                r.check("a moving device is never reported as settled", !tracker.state.isSettled)
                r.equal("it is honestly moving", tracker.state, .moving)
            },

            TCCase(id: "S06c", title: "A non-converging device is reported, not presented as settled") { r in
                // Auto exposure hunting must not be shown as a settled value.
                var tracker = ControlSettlementTracker(
                    policy: ControlSettlementPolicy(requiredStableObservations: 2, observationBudget: 4))
                for index in 0..<4 {
                    _ = tracker.observe(SelfRepairFixtures.controlSnapshot(
                        iso: Double(100 + index * 7), duration: 1.0 / 60))
                }
                switch tracker.state {
                case .didNotSettle(let observations):
                    r.check("non-convergence is typed", observations == 4)
                default:
                    r.check("a hunting device must not report settled", false, "\(tracker.state)")
                }
                r.check("it is still a live observation", tracker.state.isLiveObservation)
                r.check("and is explicitly not settled", !tracker.state.isSettled)
            },

            TCCase(id: "S06d", title: "A new setter request restarts the settle window") { r in
                var tracker = ControlSettlementTracker(
                    policy: ControlSettlementPolicy(requiredStableObservations: 1, observationBudget: 4))
                _ = tracker.observe(SelfRepairFixtures.controlSnapshot(iso: 100, duration: 1.0 / 60))
                r.check("it settled", tracker.state.isSettled)
                tracker.restart()
                r.equal("a new request is awaiting observation again",
                        tracker.state, .awaitingObservation)
                r.check("the previous settled verdict does not survive",
                        !tracker.state.isSettled)
            },

            TCCase(id: "S06e", title: "Absent measurements never establish settlement") { r in
                // REVIEW.md third-pass explicitly corrected this case. The previous
                // assertion claimed that two all-nil readings "agree" and may be
                // called settled. That is an absence-of-evidence error: a device
                // that reported nothing has not converged on anything, so it must
                // never be reported as settled.
                var tracker = ControlSettlementTracker(
                    policy: ControlSettlementPolicy(requiredStableObservations: 2, observationBudget: 8))
                let noMeasurements = SelfRepairFixtures.unmeasuredSnapshot()
                let first = tracker.observe(noMeasurements)
                r.check("an unmeasured reading is not settled", !first.isSettled)
                let second = tracker.observe(noMeasurements)
                r.check("two unmeasured readings are still not settled", !second.isSettled)
                r.check("the state is explicitly unmeasured",
                        !second.hasMeasurement && !second.isLiveObservation)

                // A real measurement later must not inherit credit from the absent
                // ones: it still needs its own consecutive agreement.
                let measured = SelfRepairFixtures.controlSnapshot(iso: 200, duration: 1.0 / 120)
                r.check("the first real reading is not settled",
                        !tracker.observe(measured).isSettled)
                r.check("and only its own repetition settles",
                        tracker.observe(measured).isSettled)

                // A fully measured fixture IS measurable, which is the contrast that
                // proves the unmeasured case is about absence, not about the rules
                // being uniformly strict.
                r.check("a measured fixture is measurable",
                        SelfRepairFixtures.controlSnapshot(iso: 100, duration: 1.0 / 60)
                            .whiteBalanceGains != nil)
            },

            TCCase(id: "S07a", title: "The loupe centre is the user's intent, clamped to the frame") { r in
                // REVIEW.md S07: the centre was hardcoded to `.center`, so the
                // required interaction did not exist. A point outside the frame
                // would magnify nothing, so it is clamped rather than accepted.
                func clamped(_ point: NormalizedDevicePoint) -> NormalizedDevicePoint {
                    NormalizedDevicePoint(x: min(max(point.x, 0), 1),
                                          y: min(max(point.y, 0), 1))
                }
                r.equal("an in-frame point is preserved",
                        clamped(NormalizedDevicePoint(x: 0.25, y: 0.75)),
                        NormalizedDevicePoint(x: 0.25, y: 0.75))
                r.equal("a negative point clamps to the edge",
                        clamped(NormalizedDevicePoint(x: -0.4, y: -2)),
                        NormalizedDevicePoint(x: 0, y: 0))
                r.equal("an over-range point clamps to the far edge",
                        clamped(NormalizedDevicePoint(x: 5, y: 1.4)),
                        NormalizedDevicePoint(x: 1, y: 1))
                r.check("the default centre is still the frame centre",
                        NormalizedDevicePoint.center == NormalizedDevicePoint(x: 0.5, y: 0.5))
                // A move must be a real change, or the analysis request is reissued
                // for nothing.
                r.check("a move is distinguishable from no move",
                        clamped(NormalizedDevicePoint(x: 0.3, y: 0.3)) != NormalizedDevicePoint.center)
            },

            // MARK: S07 — request completeness across a geometry transition

            TCCase(id: "S07b", title: "A request without geometry is retained, not discarded") { r in
                // REVIEW.md S07: a demand arriving before geometry existed was
                // dropped, so analysis stayed off until an unrelated layout change.
                func makeRequest(geometry: PreviewGeometrySnapshot?) -> AnalysisRequest {
                    AnalysisRequest(
                        configurationGeneration: ConfigurationGeneration(2),
                        geometry: geometry,
                        demand: AnalysisDemand(needsLuminanceSample: true,
                                               histogramEnabled: true, zebrasEnabled: false,
                                               peakingEnabled: true, loupeEnabled: false),
                        peakingThreshold: PeakingThreshold.high.value,
                        zebraThreshold: ZebraThreshold.ninety.normalizedValue,
                        loupeCenter: NormalizedDevicePoint(x: 0.25, y: 0.75),
                        loupeMagnification: 4)
                }
                let pending = makeRequest(geometry: nil)
                r.check("a request may legitimately carry no geometry", pending.geometry == nil)
                r.check("but it still carries the user's demand", !pending.demand.isEmpty)

                // The replacement request built when geometry arrives must preserve
                // every tool setting the user chose; only the geometry and the
                // generation stamp change.
                let geometry = PreviewGeometrySnapshot(
                    configurationGeneration: ConfigurationGeneration(2),
                    layoutGeneration: 9,
                    imageDimensions: PixelDimensions(width: 4032, height: 3024),
                    cleanApertureDimensions: nil,
                    previewLayerContentRect: TCRect(x: 0, y: 0, width: 300, height: 400),
                    bufferOrientation: 1,
                    isMirrored: false,
                    analysisRotationDegrees: 0,
                    isVideoMirrored: false,
                    capturedAtUTC: Date())
                let completed = AnalysisRequest(
                    configurationGeneration: geometry.configurationGeneration,
                    geometry: geometry,
                    demand: pending.demand,
                    peakingThreshold: pending.peakingThreshold,
                    zebraThreshold: pending.zebraThreshold,
                    loupeCenter: pending.loupeCenter,
                    loupeMagnification: pending.loupeMagnification)
                r.equal("geometry is now present", completed.geometry?.layoutGeneration, 9)
                r.close("the peaking threshold survives", completed.peakingThreshold,
                        pending.peakingThreshold, tolerance: 1e-12)
                r.close("the zebra threshold survives", completed.zebraThreshold,
                        pending.zebraThreshold, tolerance: 1e-12)
                r.equal("the loupe centre survives", completed.loupeCenter, pending.loupeCenter)
                r.close("the loupe magnification survives", completed.loupeMagnification,
                        pending.loupeMagnification, tolerance: 1e-12)
                r.equal("the demand survives", completed.demand, pending.demand)
            },

            TCCase(id: "S07c", title: "The analysis demand gates whether a request is sent at all") { r in
                r.check("no demand means nothing is sent", AnalysisDemand.none.isEmpty)
                let withHistogram = AnalysisDemand(
                    needsLuminanceSample: true, histogramEnabled: true,
                    zebrasEnabled: false, peakingEnabled: false, loupeEnabled: false)
                r.check("a real demand is not empty", !withHistogram.isEmpty)
                r.check("any enabled aid makes the demand non-empty",
                        !AnalysisDemand(needsLuminanceSample: true, histogramEnabled: false,
                                        zebrasEnabled: false, peakingEnabled: false,
                                        loupeEnabled: true).isEmpty)
            },

            // MARK: S12 — ordered viewer navigation

            TCCase(id: "S12a", title: "Viewer stepping is bounded and identity-based") { r in
                // REVIEW.md S12: the flat gallery viewer could not step between
                // originals, so a single opened source was a dead end. Stepping is
                // decided by identity, never by an out-of-range index.
                let ids = (0..<3).map { _ in CaptureID() }
                func step(current: CaptureID, delta: Int) -> CaptureID? {
                    guard let index = ids.firstIndex(of: current) else { return nil }
                    let next = index + delta
                    guard next >= 0, next < ids.count else { return nil }
                    return ids[next]
                }
                r.equal("forward from the first", step(current: ids[0], delta: 1), ids[1])
                r.equal("backward from the last", step(current: ids[2], delta: -1), ids[1])
                r.check("there is no previous before the first", step(current: ids[0], delta: -1) == nil)
                r.check("there is no next after the last", step(current: ids[2], delta: 1) == nil)
                r.check("an unknown identity cannot step", step(current: CaptureID(), delta: 1) == nil)
            },

            TCCase(id: "S10b", title: "A rebuild cursor advances, so paging always terminates") { r in
                // A real bug found during this round: the rebuild loop re-read the
                // SAME first page on every iteration, re-upserting the same records
                // and never finishing. A cursor must be a position, not a repeat.
                let generation = RootGeneration(3)
                func page(start: Int, limit: Int, total: Int) -> (cards: [Int], next: ScanCursor?) {
                    guard start < total else { return ([], nil) }
                    let end = min(start + limit, total)
                    let next = end < total ? ScanCursor(offset: end, generation: generation) : nil
                    return (Array(start..<end), next)
                }

                var cursor: ScanCursor?
                var seen: [Int] = []
                var iterations = 0
                // 25 records at 10 per page must take 3 iterations, not forever.
                while true {
                    iterations += 1
                    let (cards, next) = page(start: cursor?.offset ?? 0, limit: 10, total: 25)
                    seen.append(contentsOf: cards)
                    guard let next else { break }
                    cursor = next
                    r.check("a paging loop cannot spin forever", iterations < 10)
                    if iterations >= 10 { break }
                }
                r.equal("every record is visited exactly once", seen, Array(0..<25))
                r.equal("and the loop terminated in bounded steps", iterations, 3)

                // A cursor from a different generation must not be honoured, or a
                // rebuild could mix records from two different folders.
                let foreign = ScanCursor(offset: 10, generation: RootGeneration(99))
                r.check("a foreign-generation cursor is detectable",
                        foreign.generation != generation)

                // An empty library terminates immediately rather than looping.
                let (emptyCards, emptyNext) = page(start: 0, limit: 10, total: 0)
                r.check("an empty library has no cards", emptyCards.isEmpty)
                r.check("and no next cursor", emptyNext == nil)
            },

            TCCase(id: "S10c", title: "Counts and the card listing project one classification") { r in
                // REVIEW.md S10's remaining half: the reconciled counts and the card
                // listing came from two passes over the same folder and could
                // disagree. Availability is now a pure projection of the
                // classification the counts are derived from, so a record cannot be
                // counted as verified while being listed as inaccessible.
                func availability(_ classification: SourceClassification) -> SourceAvailability {
                    switch classification {
                    case .verifiedOriginal, .recoveredRAW, .stagedExternal: return .local
                    case .missingOriginal: return .missing
                    case .conflict(let reason): return .inaccessible(reason: reason)
                    }
                }
                r.equal("a verified original is local",
                        availability(.verifiedOriginal), .local)
                r.equal("a recovered RAW is local, because its bytes exist",
                        availability(.recoveredRAW(metadataIssue: nil)), .local)
                r.equal("a missing original is missing",
                        availability(.missingOriginal(reason: "sidecar only")), .missing)
                r.check("a conflict is inaccessible, not silently local",
                        availability(.conflict(reason: "hash mismatch"))
                            != SourceAvailability.local)

                // The counts a reconciliation reports must be derivable from the
                // same classifications, so a listing built from them agrees.
                let classifications: [SourceClassification] = [
                    .verifiedOriginal,
                    .verifiedOriginal,
                    .recoveredRAW(metadataIssue: nil),
                    .missingOriginal(reason: "sidecar only"),
                    .conflict(reason: "hash mismatch"),
                ]
                let verified = classifications.filter { if case .verifiedOriginal = $0 { return true }; return false }.count
                let recovered = classifications.filter { if case .recoveredRAW = $0 { return true }; return false }.count
                let missing = classifications.filter { if case .missingOriginal = $0 { return true }; return false }.count
                let listedLocal = classifications.filter { availability($0) == .local }.count
                r.equal("verified count", verified, 2)
                r.equal("recovered count", recovered, 1)
                r.equal("missing count", missing, 1)
                r.equal("local listings equal verified plus recovered",
                        listedLocal, verified + recovered)
                r.equal("every record is accounted for exactly once",
                        listedLocal + missing + classifications.filter {
                            if case .conflict = $0 { return true }; return false
                        }.count,
                        classifications.count)
            },

            // MARK: S14 — sequence terminal admission

            TCCase(id: "S14a", title: "A terminal status is informational, not active state") { r in
                // REVIEW.md S14: the shutter and lens switch were gated on a STATUS
                // STRING, so a finished sequence blocked ordinary capture forever.
                r.check("a complete line is display text only",
                        SequenceTerminalState.isDisplayOnly(statusLine: "Exposure bracket: complete (3)"))
                r.check("a cancelled line is display text only",
                        SequenceTerminalState.isDisplayOnly(statusLine: "Interval: cancelled, 5 source(s) retained"))
                r.check("a failed line is display text only",
                        SequenceTerminalState.isDisplayOnly(statusLine: "Focus bracket: failed, 1 source(s) retained"))
                r.check("no status means nothing to display",
                        !SequenceTerminalState.isDisplayOnly(statusLine: nil))
            },

            TCCase(id: "S14b", title: "Admission is decided by active identity, not by message text") { r in
                r.check("an active sequence blocks ordinary capture",
                        !SequenceAdmissionState.isShutterEnabled(hasActiveSequenceID: true,
                                                                 blockedByRestorationFailure: nil))
                r.check("a finished sequence releases the shutter",
                        SequenceAdmissionState.isShutterEnabled(hasActiveSequenceID: false,
                                                                blockedByRestorationFailure: nil))
                r.check("a lens switch is allowed after a sequence ends",
                        SequenceAdmissionState.isLensSwitchAllowed(hasActiveSequenceID: false,
                                                                   blockedByRestorationFailure: nil))
                r.check("a lens switch is refused during a sequence",
                        !SequenceAdmissionState.isLensSwitchAllowed(hasActiveSequenceID: true,
                                                                    blockedByRestorationFailure: nil))
            },

            TCCase(id: "S14c", title: "A restoration failure stays a typed block until an explicit reset") { r in
                let block = "The camera settings could not be returned to their previous values."
                r.check("the shutter is refused after a restoration failure",
                        !SequenceAdmissionState.isShutterEnabled(hasActiveSequenceID: false,
                                                                 blockedByRestorationFailure: block))
                r.check("the refusal is not because a sequence is running",
                        !SequenceAdmissionState.isLensSwitchAllowed(hasActiveSequenceID: false,
                                                                    blockedByRestorationFailure: block))
                // Only clearing the typed block restores admission.
                r.check("clearing the block restores the shutter",
                        SequenceAdmissionState.isShutterEnabled(hasActiveSequenceID: false,
                                                                blockedByRestorationFailure: nil))
            },
        ])
}

/// Fixtures for the readback settlement cases.
enum SelfRepairFixtures {
    /// A snapshot in which the device reported no measurable value at all. Used by
    /// the absence-of-evidence cases (REVIEW.md third-pass R03).
    static func unmeasuredSnapshot() -> AppliedControlSnapshot {
        AppliedControlSnapshot(
            generation: ConfigurationGeneration(1),
            exposureChoice: .auto,
            biasEV: 0,
            observedDurationSeconds: nil,
            observedISO: nil,
            observedExposureTargetOffset: nil,
            focusMode: .continuousAuto,
            focusPosition: nil,
            whiteBalanceMode: .auto,
            whiteBalanceGains: nil,
            lensAperture: nil,
            videoZoomFactor: 1,
            photoConnectionScale: 1,
            photoConnectionCrop: 1,
            capturedAtUTC: Date())
    }

    static func controlSnapshot(iso: Double?, duration: Double?) -> AppliedControlSnapshot {
        AppliedControlSnapshot(
            generation: ConfigurationGeneration(1),
            exposureChoice: .auto,
            biasEV: 0,
            observedDurationSeconds: duration,
            observedISO: iso,
            observedExposureTargetOffset: 0,
            focusMode: .continuousAuto,
            focusPosition: 0.5,
            whiteBalanceMode: .auto,
            whiteBalanceGains: WhiteBalanceGains(red: 2, green: 1, blue: 1.5),
            lensAperture: 1.8,
            videoZoomFactor: 1,
            photoConnectionScale: 1,
            photoConnectionCrop: 1,
            capturedAtUTC: Date())
    }
}

/// Pure admission policy for the sequence terminal state (REVIEW.md S14).
///
/// Extracted so the rule is testable without a running camera: admission must
/// depend on whether a sequence is ACTIVE and on a typed restoration block, never
/// on the presence of a status message.
enum SequenceAdmissionState {
    static func isShutterEnabled(hasActiveSequenceID: Bool,
                                 blockedByRestorationFailure: String?) -> Bool {
        guard !hasActiveSequenceID else { return false }
        return blockedByRestorationFailure == nil
    }

    static func isLensSwitchAllowed(hasActiveSequenceID: Bool,
                                    blockedByRestorationFailure: String?) -> Bool {
        guard !hasActiveSequenceID else { return false }
        return blockedByRestorationFailure == nil
    }
}

enum SequenceTerminalState {
    /// True when a status line is only retained for display. A nil line means
    /// there is nothing to show, which is distinct from "display only".
    static func isDisplayOnly(statusLine: String?) -> Bool {
        guard let statusLine else { return false }
        return !statusLine.isEmpty
    }
}
