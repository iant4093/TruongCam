import Foundation

// Native test bundles read the app's real types through the module; the
// standalone verifier compiles the app sources into the same executable and
// therefore cannot import a module. XCTest is only available in the native
// bundle, so it gates the import.
#if canImport(XCTest)
@testable import TruongCam
#endif


// Independent exposure/aperture values and the shipping control model through
// synthetic camera/storage boundaries. No device or native setter is used.

enum ExposureModelSuite {
    private static func apertureCapability(
        minimum: Double = 1.48, maximum: Double = 4,
        autoModes: Set<ExposureModeKind> = Set(ExposureModeKind.allCases),
        manualModes: Set<ExposureModeKind> = Set(ExposureModeKind.allCases)
    ) -> ApertureCapability {
        ApertureCapability(minFNumber: minimum, maxFNumber: maximum,
            recommendedStops: [1.48, 1.8, 2.8, 4],
            autoExposureModes: autoModes, manualExposureModes: manualModes)
    }

    private static func apertureIntent(_ h: StorageHarness, aperture: ApertureChoice) -> CaptureIntent {
        CaptureIntent(captureID: CaptureID(), libraryID: h.libraryID,
            requestedDimensions: PixelDimensions(width: 4000, height: 3000), exposure: .auto, biasEV: 0,
            focus: FocusIntent(mode: .continuousAuto, position: nil, pointOfInterest: nil),
            whiteBalance: WhiteBalanceIntent(mode: .auto, temperatureAndTint: nil),
            configurationGeneration: .zero, rootGeneration: h.generation, physicalCameraKind: .wide,
            createdAtUTC: StorageFixture.fixedDate, timezoneOffsetSeconds: 0, mode: .single, aperture: aperture)
    }

    private static func apertureReading(
        _ intent: CaptureIntent, measured: Double? = 2.8,
        aperture: ApertureChoice = .manual(fNumber: 2.8), automatic: Bool? = false,
        settlement: ControlSettlementState = .settled,
        revision: UInt64? = nil, generation: ConfigurationGeneration? = nil
    ) -> AppliedControlSnapshot {
        AppliedControlSnapshot(generation: generation ?? intent.configurationGeneration,
            requestRevision: revision ?? CaptureCoordinator.controlRevision(for: intent), settlement: settlement,
            isExposureAdjusting: false, isFocusAdjusting: false, isWhiteBalanceAdjusting: false,
            exposureChoice: intent.exposure, biasEV: intent.biasEV,
            observedDurationSeconds: 0.01, observedISO: 100, observedExposureTargetOffset: 0,
            focusMode: .continuousAuto, focusPosition: 0.5,
            whiteBalanceMode: .auto, whiteBalanceGains: WhiteBalanceGains(red: 1, green: 1, blue: 1),
            lensAperture: measured, videoZoomFactor: 1, photoConnectionScale: 1, photoConnectionCrop: 1,
            capturedAtUTC: StorageFixture.fixedDate, apertureChoice: aperture, isApertureAutomatic: automatic)
    }

    static let suite = TCSuite(
        id: "T01-T04",
        title: "Independent Auto/manual exposure model",
        cases: [
            TCCase(id: "AP01", title: "Aperture selection uses discovered limits and exact Auto/manual combinations") { r in
                let capability = apertureCapability(manualModes: [.auto, .manual])
                r.check("variable hardware exposes aperture controls", capability.isVariable)
                r.check("automatic aperture with shutter priority allowed", capability.supports(.auto, exposureMode: .shutterPriority))
                r.check("manual aperture with Auto shutter and ISO allowed", capability.supports(.manual(fNumber: 2.8), exposureMode: .auto))
                r.check("unadvertised manual-aperture priority refused", !capability.supports(.manual(fNumber: 2.8), exposureMode: .shutterPriority))
                r.check("lower boundary is legal", capability.supports(.manual(fNumber: 1.48), exposureMode: .manual))
                r.check("upper boundary is legal", capability.supports(.manual(fNumber: 4), exposureMode: .manual))
                for value in [Double.nan, .infinity, -.infinity, -1, 0, 1.4, 4.1, Double.greatestFiniteMagnitude] {
                    r.check("invalid aperture refused: \(value)", !capability.supports(.manual(fNumber: value), exposureMode: .manual))
                }
                r.check("one fixed aperture is not adjustable", !apertureCapability(minimum: 1.8, maximum: 1.8).isVariable)
                r.check("reversed bounds never expose a control", !apertureCapability(minimum: 4, maximum: 1.48).isVariable)
                r.check("unknown bounds never expose a control", !apertureCapability(minimum: .nan).isVariable)
                r.equal("Auto has no numeric target", ApertureChoice.auto.numericTarget, nil)
                r.equal("manual target is preserved", ApertureChoice.manual(fNumber: 2.8).numericTarget, 2.8)
            },
            TCCase(id: "AP02", title: "Asymmetric priority support keeps supported Auto independent and labels an unsupported peer reset") { r in
                for supported in [ExposureModeKind.shutterPriority, .isoPriority] {
                    guard let h = await StorageHarness.make(name: "ap02-\(supported)") else { r.check("fixture", false); continue }
                    let fixture = StartupRepairSuite.controlFixture(modes: [.auto, .manual, supported])
                    let model = await CameraViewModel(camera: SyntheticCameraService(capability: fixture),
                        capture: CaptureCoordinator(camera: ChainCameraSpy(), store: h.store, clock: SystemMonotonicClock()),
                        metering: MeteringService(clock: SystemMonotonicClock()), preferences: SyntheticPreferenceStore(), levelFeed: SyntheticLevelFeed())
                    await model.start()
                    await model.updateRootState(SeqTestSupport.writableRoot)
                    await MainActor.run {
                        model.setExposureMode(.manual); model.setDuration(0.02); model.setISO(400)
                        let permitted: CameraPanel = supported == .shutterPriority ? .iso : .shutter
                        let refused: CameraPanel = supported == .shutterPriority ? .shutter : .iso
                        r.check("supported independent Auto is enabled", model.canSetStripAutomatic(permitted))
                        r.equal("unsupported independent Auto names its reset", model.stripAutomaticLabel(refused), "Auto both")
                        r.equal("supported action is independently labelled", model.stripAutomaticLabel(permitted), "Auto")
                        model.setStripAutomatic(refused)
                        r.equal("explicit reset restores Auto", model.exposure, .auto)
                        model.setExposureMode(.manual); model.setDuration(0.02); model.setISO(400)
                        model.setStripAutomatic(permitted)
                        r.equal("supported peer becomes automatic", model.exposure.mode, supported)
                        if supported == .shutterPriority { r.equal("manual shutter preserved", model.exposure.durationTargetSeconds, 0.02) }
                        else { r.equal("manual ISO preserved", model.exposure.isoTarget, 400) }
                        model.setExposureMode(.manual); model.setDuration(0.02); model.setISO(400)
                        model.openPanel = refused
                    }
                    let refusedHardware = await model.hardwareConfiguration(enabled: true)
                    r.check("hardware names the unsupported transition as a whole-program reset", refusedHardware.selections.first?.domain.options.contains {
                        $0.value == .automatic && $0.title == "Auto both"
                    } == true)
                    await MainActor.run { model.openPanel = supported == .shutterPriority ? .iso : .shutter }
                    let allowedHardware = await model.hardwareConfiguration(enabled: true)
                    guard let picker = allowedHardware.selections.first,
                          let autoIndex = picker.domain.options.firstIndex(where: { $0.value == .automatic }) else {
                        r.check("hardware retains the independently supported Auto action", false)
                        await model.stop(); continue
                    }
                    r.check("hardware picker is eligible", allowedHardware.enabled)
                    await model.updateHardwareControls(allowedHardware)
                    await model.receiveHardwareSelection(HardwareControlSelection(domain: picker.domain, index: autoIndex))
                    r.equal("hardware Auto uses the same independent transition", await model.exposure.mode, supported)
                    if supported == .shutterPriority { r.equal("hardware preserves manual shutter", await model.exposure.durationTargetSeconds, 0.02) }
                    else { r.equal("hardware preserves manual ISO", await model.exposure.isoTarget, 400) }
                    await model.stop()
                }
            },
            TCCase(id: "AP03", title: "Manual aperture is visible only on a variable lens and rejects out-of-range intent") { r in
                guard let h = await StorageHarness.make(name: "ap03-aperture-ui") else { r.check("fixture", false); return }
                var fixture = StartupRepairSuite.controlFixture(modes: Set(ExposureModeKind.allCases))
                fixture.physicalCameras[0].formats[0].apertureCapability = apertureCapability()
                let variableFixture = fixture
                let model = await CameraViewModel(camera: SyntheticCameraService(capability: variableFixture),
                    capture: CaptureCoordinator(camera: ChainCameraSpy(), store: h.store, clock: SystemMonotonicClock()),
                    metering: MeteringService(clock: SystemMonotonicClock()), preferences: SyntheticPreferenceStore(), levelFeed: SyntheticLevelFeed())
                await model.start()
                await MainActor.run {
                    r.check("variable lens shows aperture", model.isApertureAvailable)
                    r.check("no fabricated stops", model.apertureStops == [1.48, 1.8, 2.8, 4])
                    model.setAperture(2.8)
                    r.check("aperture moves independently to Manual", model.isApertureManual)
                    r.equal("shutter and ISO remain Auto", model.exposure, .auto)
                    r.equal("requested f-number remains exact", model.selectedApertureValue, 2.8)
                    model.setAperture(.nan); model.setAperture(5.6)
                    r.equal("invalid request preserves legal aperture", model.selectedApertureValue, 2.8)
                    model.setStripAutomatic(.aperture)
                    r.check("aperture returns to Auto independently", !model.isApertureManual)
                    r.equal("Auto aperture leaves exposure unchanged", model.exposure, .auto)
                    model.setAperture(2.8); model.openPanel = .aperture
                    var fixed = variableFixture
                    fixed.physicalCameras[0].formats[0].apertureCapability = apertureCapability(minimum: 1.8, maximum: 1.8)
                    model.adoptCapability(fixed)
                    r.check("fixed lens has no aperture control", !model.isApertureAvailable)
                    r.check("lens replacement clears an unavailable aperture panel", model.openPanel == nil)
                    model.setAperture(2.8)
                    r.check("fixed lens refuses manual aperture", !model.isApertureManual)
                    var systemOnly = variableFixture
                    systemOnly.physicalCameras[0].formats[0].apertureCapability = apertureCapability(manualModes: [])
                    model.adoptCapability(systemOnly)
                    r.check("system-only aperture has no unusable manual control", !model.isApertureAvailable)
                    model.setExposureMode(.manual)
                    r.check("Auto diaphragm permits EV with manual shutter and ISO", model.isBiasAvailable)
                }
                await model.stop()
            },
            TCCase(id: "AP04", title: "Aperture capture admission requires the exact current mode and measured f-number") { r in
                guard let h = await StorageHarness.make(name: "ap04-readback") else { r.check("fixture", false); return }
                let intent = apertureIntent(h, aperture: .manual(fNumber: 2.8))
                let matching = apertureReading(intent)
                r.check("current settled aperture permits capture", CaptureCoordinator.applicationIsComplete(matching, for: intent))
                r.check("moving manual aperture cannot take the fast Auto path", !CaptureCoordinator.applicationIsReadyForCapture(apertureReading(intent, settlement: .moving), for: intent))
                r.check("stable wrong f-number cannot authorize capture", !CaptureCoordinator.applicationIsComplete(apertureReading(intent, measured: 4), for: intent))
                r.check("missing actual aperture cannot authorize capture", !CaptureCoordinator.applicationIsComplete(apertureReading(intent, measured: nil), for: intent))
                r.check("nonfinite aperture cannot authorize capture", !CaptureCoordinator.applicationIsComplete(apertureReading(intent, measured: .nan), for: intent))
                r.check("actual Auto cannot stand in for requested manual aperture", !CaptureCoordinator.applicationIsComplete(apertureReading(intent, aperture: .auto, automatic: true), for: intent))
                r.check("manual intent alone is not a native lock observation", !CaptureCoordinator.applicationIsComplete(apertureReading(intent, automatic: true), for: intent))
                r.check("unknown lock observation cannot confirm manual aperture", !CaptureCoordinator.applicationIsComplete(apertureReading(intent, automatic: nil), for: intent))
                r.check("old revision cannot authorize aperture capture", !CaptureCoordinator.applicationIsComplete(apertureReading(intent, revision: CaptureCoordinator.controlRevision(for: intent) &+ 1), for: intent))
                r.check("old sensor cannot authorize aperture capture", !CaptureCoordinator.applicationIsComplete(apertureReading(intent, generation: ConfigurationGeneration(1)), for: intent))
                let automatic = apertureIntent(h, aperture: .auto)
                r.check("manual aperture cannot stand in for requested Auto", !CaptureCoordinator.applicationIsReadyForCapture(apertureReading(automatic), for: automatic))
                var tracker = ControlSettlementTracker()
                r.check("wrong aperture does not settle", !tracker.observe(apertureReading(intent, measured: 4)).isSettled)
                r.check("repeated wrong aperture still does not settle", !tracker.observe(apertureReading(intent, measured: 4)).isSettled)
                r.check("one matching reading starts a fresh stability window", !tracker.observe(matching).isSettled)
                r.check("two matching actual readings settle", tracker.observe(matching).isSettled)
                let settings = SequenceSettingsSnapshot(configurationGeneration: intent.configurationGeneration,
                    revision: CaptureCoordinator.controlRevision(for: intent), exposure: .auto, biasEV: 0,
                    focus: intent.focus, whiteBalance: intent.whiteBalance, maxDimensions: intent.requestedDimensions,
                    aperture: .manual(fNumber: 2.8))
                r.check("matching sequence aperture accepted", SequenceControlVerification.matches(matching, settings: settings,
                    generation: intent.configurationGeneration, revision: settings.revision, whiteBalanceTarget: nil))
                r.check("wrong sequence aperture refused", !SequenceControlVerification.matches(apertureReading(intent, measured: 4), settings: settings,
                    generation: intent.configurationGeneration, revision: settings.revision, whiteBalanceTarget: nil))
            },
            TCCase(id: "AP05", title: "Exposure and aperture Auto actions honor their joint capability without changing peers") { r in
                guard let h = await StorageHarness.make(name: "ap05-joint-modes") else { r.check("fixture", false); return }
                var initial = StartupRepairSuite.controlFixture(modes: Set(ExposureModeKind.allCases))
                initial.physicalCameras[0].formats[0].apertureCapability = apertureCapability(manualModes: [.manual])
                let model = await CameraViewModel(camera: SyntheticCameraService(capability: initial),
                    capture: CaptureCoordinator(camera: ChainCameraSpy(), store: h.store, clock: SystemMonotonicClock()),
                    metering: MeteringService(clock: SystemMonotonicClock()), preferences: SyntheticPreferenceStore(), levelFeed: SyntheticLevelFeed())
                await model.start()
                await MainActor.run {
                    model.setAperture(2.8)
                    r.check("unsupported manual aperture does not replace Auto", !model.isApertureManual)
                    r.equal("refused aperture does not make shutter or ISO manual", model.exposure, .auto)
                    model.setExposureMode(.manual); model.setDuration(0.02); model.setISO(400); model.setAperture(2.8)
                    r.check("legal whole manual combination accepts the aperture", model.isApertureManual)
                    r.equal("unsupported Auto ISO explicitly names the whole-program reset", model.stripAutomaticLabel(.iso), "Auto all")
                    model.setStripAutomatic(.iso)
                    r.equal("named reset restores automatic exposure", model.exposure, .auto)
                    r.check("named reset restores required automatic aperture", model.aperture.isAutomatic)
                    model.setExposureMode(.manual); model.setDuration(0.02); model.setISO(400); model.setAperture(2.8)
                    model.setStripAutomatic(.aperture)
                    r.check("allowed Auto aperture changes just aperture", !model.isApertureManual)
                    r.equal("Auto aperture preserves manual shutter and ISO", model.exposure, .manual(durationSeconds: 0.02, iso: 400))
                    model.setAperture(2.8)
                    var restricted = model.capability
                    restricted.physicalCameras[0].formats[0].apertureCapability = apertureCapability(autoModes: [.auto], manualModes: [.manual])
                    model.adoptCapability(restricted)
                    r.check("whole-program reset is available when all independent exits are unsupported", model.canSetStripAutomatic(.aperture))
                    r.equal("reset explicitly names all parameters", model.stripAutomaticLabel(.aperture), "Auto all")
                    r.check("offering reset does not change Manual", model.isApertureManual)
                    r.equal("offering reset preserves peers", model.exposure, .manual(durationSeconds: 0.02, iso: 400))
                    model.openPanel = .aperture
                }
                let configuration = await model.hardwareConfiguration(enabled: true)
                r.check("aperture hardware domain remains available", configuration.selections.first?.domain.kind == .aperture)
                r.check("hardware reset also explicitly names all parameters", configuration.selections.first?.domain.options.contains {
                    $0.value == .automatic && $0.title == "Auto all"
                } == true)
                await model.setStripAutomatic(.aperture)
                r.check("explicit reset restores automatic aperture", await model.aperture.isAutomatic)
                r.equal("explicit reset restores automatic shutter and ISO", await model.exposure, .auto)
                await model.stop()
            },
            TCCase(id: "AP06", title: "Achieved bracket EV uses source aperture and never substitutes requested metadata") { r in
                func ev(_ base: Double?, _ source: Double?) -> Double? {
                    CaptureCoordinator.achievedOffsetEV(requestedOffsetEV: 1, baselineISO: 100,
                        baselineDurationSeconds: 0.01, sourceISO: 100, sourceDurationSeconds: 0.01,
                        baselineAperture: base, sourceAperture: source)
                }
                r.check("wider source aperture adds delivered exposure", abs((ev(4, 2) ?? -10) - 2) < 1e-9)
                r.check("narrower source aperture reduces delivered exposure", abs((ev(2, 4) ?? 10) + 2) < 1e-9)
                r.equal("known aperture with absent source EXIF remains unknown", ev(4, nil), nil)
                r.equal("invalid source f-number remains unknown", ev(4, .nan), nil)
                r.equal("legacy fixed-aperture baseline retains its calculation", ev(nil, nil), 0)
            },
            TCCase(id: "AP07", title: "Camera Control domain survives an Auto-to-paired-Manual transition under manual aperture") { r in
                guard let h = await StorageHarness.make(name: "ap07-domain") else { r.check("fixture", false); return }
                var fixture = StartupRepairSuite.controlFixture(modes: Set(ExposureModeKind.allCases))
                fixture.physicalCameras[0].formats[0].apertureCapability = apertureCapability(manualModes: [.auto, .manual])
                let model = await CameraViewModel(camera: SyntheticCameraService(capability: fixture),
                    capture: CaptureCoordinator(camera: ChainCameraSpy(), store: h.store, clock: SystemMonotonicClock()),
                    metering: MeteringService(clock: SystemMonotonicClock()), preferences: SyntheticPreferenceStore(), levelFeed: SyntheticLevelFeed())
                await model.start()
                await MainActor.run { model.setAperture(2.8); model.openPanel = .iso }
                let initial = await model.hardwareConfiguration(enabled: true).selections.first?.domain
                await model.adjustISOFromStrip(400)
                r.equal("the supported whole Manual program is selected", await model.exposure.mode, .manual)
                let manual = await model.hardwareConfiguration(enabled: true).selections.first?.domain
                r.equal("subsequent swipe retains the exact picker domain", manual, initial)
                r.check("reset title is explicit before and after seeding", manual?.options.first?.title == "Auto both")
                await model.setStripAutomatic(.iso)
                r.equal("explicit paired reset restores ISO/shutter Auto", await model.exposure, .auto)
                r.equal("supported manual aperture is preserved by the reset", await model.aperture, .manual(fNumber: 2.8))
                await model.stop()
            },
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
