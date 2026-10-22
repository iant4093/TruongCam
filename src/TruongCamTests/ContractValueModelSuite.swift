import Foundation

// Native test bundles read the app's real types through the module; the
// standalone verifier compiles the app sources into the same executable and
// therefore cannot import a module. XCTest is only available in the native
// bundle, so it gates the import.
#if canImport(XCTest)
@testable import TruongCam
#endif


// Verification for the frozen P0 value models: identity/generation ordering,
// provenance separation of desired/applied/observed, and the digest type.

enum ContractValueModelSuite {
    static let suite = TCSuite(
        id: "P0",
        title: "Frozen contract value models",
        cases: [
            TCCase(id: "T00a", title: "Generation ordering and monotonic increment") { r in
                let zero = ConfigurationGeneration.zero
                let one = ConfigurationGeneration.next(zero)
                let two = ConfigurationGeneration.next(one)
                r.check("next increments", one.value == 1 && two.value == 2)
                r.check("ordering", zero < one && one < two)
                r.check("wrap-safe increment keeps counting",
                        ConfigurationGeneration(UInt64.max).value == UInt64.max)
                let root = RootGeneration.zero
                r.check("root generation separate type", RootGeneration.next(root).value == 1)
                r.check("ordinals compare",
                        SourceOrdinal(0) < SourceOrdinal(1) && DeadlineOrdinal(3) > DeadlineOrdinal(2))
            },

            TCCase(id: "T00b", title: "SHA-256 digest accepts only 64 lowercase hex characters") { r in
                let valid = String(repeating: "a", count: 64)
                let validDigits = "0123456789abcdef" + String(repeating: "0", count: 48)
                r.check("valid lowercase accepted", SHA256Digest(hex: valid) != nil)
                r.check("valid digits accepted", SHA256Digest(hex: validDigits) != nil)
                r.check("short rejected", SHA256Digest(hex: String(repeating: "a", count: 63)) == nil)
                r.check("long rejected", SHA256Digest(hex: String(repeating: "a", count: 65)) == nil)
                r.check("uppercase rejected", SHA256Digest(hex: String(repeating: "A", count: 64)) == nil)
                r.check("non-hex rejected", SHA256Digest(hex: String(repeating: "z", count: 64)) == nil)
                r.check("empty rejected", SHA256Digest(hex: "") == nil)
            },

            TCCase(id: "T00c", title: "Desired/applied/observed stay separate") { r in
                var reading = ControlReading<Double>()
                r.check("all unknown initially",
                        !reading.desired.isKnown && !reading.applied.isKnown && !reading.observed.isKnown)

                reading.recordApplied(1.0 / 125.0)
                r.equal("desired after apply", reading.desired.value, 1.0 / 125.0)
                r.equal("applied after apply", reading.applied.value, 1.0 / 125.0)
                r.equal("desired provenance", reading.desired.provenance, .requested)
                r.equal("applied provenance", reading.applied.provenance, .settledDeviceReadback)
                r.check("observed untouched by apply", !reading.observed.isKnown)

                // A failed setter must move only the desired target.
                let priorApplied = reading.applied.value
                reading.recordDesiredOnly(1.0 / 8000.0)
                r.equal("desired moved to rejected target", reading.desired.value, 1.0 / 8000.0)
                r.equal("applied unchanged after failure", reading.applied.value, priorApplied)

                reading.recordObserved(0.008, .settledDeviceReadback)
                r.equal("observed recorded", reading.observed.value, 0.008)
                r.close("observed is not overwritten by applied", reading.observed.value!, 0.008)

                // Unknown values are never zero-filled.
                var blank = ControlReading<Double>()
                blank.recordDesiredOnly(nil)
                r.check("nil desired stays unknown", !blank.desired.isKnown)
                r.equal("unknown provenance", blank.desired.provenance, .unknown)
            },

            TCCase(id: "T00d", title: "ProvenancedValue reports unknown for nil") { r in
                let unknown = ProvenancedValue<Double>.unknown
                r.check("unknown has no value", !unknown.isKnown)
                r.equal("unknown provenance forced", unknown.provenance, .unknown)
                let forced = ProvenancedValue<Double>(value: nil, provenance: .captureMetadata)
                r.equal("nil value cannot claim capture provenance", forced.provenance, .unknown)
                let known = ProvenancedValue.known(3.5, .captureMetadata)
                r.equal("known value preserved", known.value, 3.5)
            },

            TCCase(id: "T00e", title: "Pixel dimensions validate and never infer from a megapixel label") { r in
                let d = PixelDimensions(width: 4032, height: 3024)
                r.check("valid", d.isValid)
                r.equal("pixel count", d.pixelCount, 12_192_768)
                r.check("zero width invalid", !PixelDimensions(width: 0, height: 100).isValid)
                r.check("negative height invalid", !PixelDimensions(width: 100, height: -1).isValid)
            },
            TCCase(id: "T00f", title: "Lens kinds never manufacture iPhone-specific full-frame millimetres") { r in
                for kind in PhysicalCameraKind.allCases {
                    r.check("\(kind.rawValue) has no kind-derived equivalent", kind.expectedEquivalentFocalLengthMM == nil)
                    r.check("\(kind.rawValue) uses a descriptive missing-data label", !kind.displayLabel.contains("mm"))
                    let camera = StartupRepairSuite.controlFixture(modes: [.auto], kind: kind).physicalCameras[0]
                    r.equal("legacy constructor defaults to unknown mm", camera.validNominalEquivalentFocalLengthMM, nil)
                    r.equal("legacy capability uses descriptive label", camera.lensDisplayLabel, kind.displayLabel)
                }
            },
            TCCase(id: "T00g", title: "Runtime nominal equivalents support different optics without granting RAW") { r in
                for (kind, millimetres, expected) in [(PhysicalCameraKind.ultraWide, 13.0, "13mm"),
                                                       (.wide, 24.0, "24mm"), (.wide, 28.0, "28mm"),
                                                       (.telephoto, 77.0, "77mm"), (.telephoto, 120.0, "120mm"),
                                                       (.front, 23.5, "23.5mm")] {
                    var camera = StartupRepairSuite.controlFixture(modes: [.auto], kind: kind).physicalCameras[0]
                    camera.nominalEquivalentFocalLengthMM = millimetres
                    camera.bayerRAWDiscovery = .unknown(reason: "not connected")
                    r.equal("\(kind.rawValue) uses the actual reported nominal value", camera.lensDisplayLabel, expected)
                    r.equal("nominal value retained for request context", camera.validNominalEquivalentFocalLengthMM, millimetres)
                    r.check("VoiceOver identifies the equivalent scale", camera.lensAccessibilityLabel.contains("full-frame equivalent"))
                    r.check("a lens label does not grant RAW", !camera.bayerRAWDiscovery.isAvailable)
                }
                var camera = StartupRepairSuite.controlFixture(modes: [.auto]).physicalCameras[0]
                for invalid in [0.0, -1.0, Double.nan, Double.infinity, -Double.infinity] {
                    camera.nominalEquivalentFocalLengthMM = invalid
                    r.check("invalid native focal value stays unknown", camera.validNominalEquivalentFocalLengthMM == nil)
                    r.equal("invalid native focal value keeps fallback", camera.lensDisplayLabel, "Wide")
                }
            },
            TCCase(id: "T00h", title: "Shipping lens actions follow single dual and triple physical topology") { r in
                guard let storage = await StorageHarness.make(name: "runtime-lens-topology") else { r.check("fixture", false); return }
                for kinds in [[PhysicalCameraKind.wide], [.ultraWide, .wide], [.ultraWide, .wide, .telephoto]] {
                    var snapshot = StartupRepairSuite.controlFixture(modes: [.auto])
                    snapshot.physicalCameras = kinds.reversed().map { kind in
                        var camera = StartupRepairSuite.controlFixture(modes: [.auto], kind: kind).physicalCameras[0]
                        camera.nominalEquivalentFocalLengthMM = kind == .wide ? 24 : kind == .ultraWide ? 14 : 120
                        if kind == .telephoto { camera.bayerRAWDiscovery = .unknown(reason: "not connected") }
                        return camera
                    }
                    let service = SyntheticCameraService(capability: snapshot)
                    let model = await CameraViewModel(camera: service,
                        capture: CaptureCoordinator(camera: ChainCameraSpy(), store: storage.store, clock: SystemMonotonicClock()),
                        metering: MeteringService(clock: SystemMonotonicClock()), preferences: SyntheticPreferenceStore(), levelFeed: SyntheticLevelFeed())
                    await model.start()
                    r.equal("only discovered physical actions in stable order", await model.lensButtons.map(\.kind), kinds)
                    r.equal("only active physical lens is selected", await model.lensButtons.filter(\.isSelected).map(\.kind), [.wide])
                    if kinds.contains(.telephoto) {
                        r.equal("telephoto reports device-specific nominal", await model.lensButtons.last?.label, "120mm")
                        r.check("telephoto remains unprobed", !(await model.capability.camera(.telephoto)?.bayerRAWDiscovery.isAvailable ?? true))
                        await service.configureSwitch(failures: [.telephoto], delay: .zero)
                        await model.selectLens(.telephoto)
                        r.equal("unsupported telephoto cannot replace the working lens", await model.capability.selectedCameraKind, .wide)
                        r.equal("unsupported selection visibly restores the previous physical action", await service.switchRequests, [.telephoto, .wide])
                        r.check("rear refusal does not enable processed fallback", !(await model.capability.frontHEIFSupported))
                    }
                    await model.stop()
                }
            },
        ])
}
