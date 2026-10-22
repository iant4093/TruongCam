import Foundation
#if canImport(XCTest)
@testable import TruongCam
#endif

private struct JPEG51BayerClassifier: BayerRAWClassifying {
    func isBayerRAW(_ pixelFormat: UInt32) -> Bool { pixelFormat == 0x4247_4734 }
}

enum JPEGCoreSuite {
    private static func intent(_ format: CaptureFileFormat, kind: PhysicalCameraKind = .wide) -> CaptureIntent {
        CaptureIntent(captureID: CaptureID(), libraryID: LibraryID(),
            requestedDimensions: PixelDimensions(width: 32, height: 24), exposure: .auto, biasEV: 0,
            focus: FocusIntent(mode: .continuousAuto, position: nil, pointOfInterest: nil),
            whiteBalance: WhiteBalanceIntent(mode: .auto, temperatureAndTint: nil),
            configurationGeneration: .zero, rootGeneration: .zero, physicalCameraKind: kind,
            createdAtUTC: Date(timeIntervalSince1970: 0), timezoneOffsetSeconds: 0, mode: .single, fileFormat: format)
    }
    private static func readiness(_ format: CaptureFileFormat, jpeg: Bool, raw: Bool = false,
                                  writable: Bool = true, pending: Int = 0, active: Bool = true) -> CaptureReadinessInputs {
        CaptureReadinessInputs(isSceneActive: active, cameraLifecycle: .running, hasCameraPermission: true,
            bayerSupport: .available(raw), controlsSupported: true, unsupportedControlsDetail: nil,
            rootState: writable ? .writable(libraryID: LibraryID(), generation: .zero) : .unselected,
            pendingOriginalCount: pending, activeSequenceDescription: nil, isReconfiguring: false,
            restorationFailedDetail: nil, fileFormat: format, jpegSupported: jpeg)
    }

    static let suite = TCSuite(id: "JPEGCore51", title: "Frozen format admission and truthful metadata", cases: [
        TCCase(id: "JC51A", title: "Only explicitly chosen JPEG bypasses Bayer eligibility; all other shutter gates remain") { r in
            r.check("JPEG-only camera can admit explicit JPEG", CaptureCoordinator.admissionBlockReason(for: readiness(.jpeg, jpeg: true)) == nil)
            r.check("JPEG support alone cannot authorize RAW", CaptureCoordinator.admissionBlockReason(for: readiness(.bayerDNG, jpeg: true)) != nil)
            r.check("RAW support cannot authorize unavailable JPEG", CaptureCoordinator.admissionBlockReason(for: readiness(.jpeg, jpeg: false, raw: true)) != nil)
            r.check("JPEG cannot bypass folder ownership", CaptureCoordinator.admissionBlockReason(for: readiness(.jpeg, jpeg: true, writable: false)) != nil)
            r.check("JPEG cannot bypass pending originals", CaptureCoordinator.admissionBlockReason(for: readiness(.jpeg, jpeg: true, pending: 1)) != nil)
            r.check("JPEG cannot bypass scene eligibility", CaptureCoordinator.admissionBlockReason(for: readiness(.jpeg, jpeg: true, active: false)) != nil)
        },
        TCCase(id: "JC51B", title: "Delivered JPEG, HEIF and Bayer declarations cannot cross frozen request formats") { r in
            let classifier = JPEG51BayerClassifier()
            let descriptions: [(CaptureFileFormat, UInt32, String, PhysicalCameraKind)] = [
                (.bayerDNG, 0x4247_4734, "com.adobe.raw-image", .wide),
                (.jpeg, 0, "public.jpeg", .wide), (.frontHEIF, 0, "public.heic", .front)]
            for (chosen, _, _, camera) in descriptions {
                let request = intent(chosen, kind: camera)
                for (delivered, pixel, type, _) in descriptions {
                    let representation = DeliveredRAWRepresentation(bytes: Data([1]), captureID: request.captureID,
                        resolvedSettingsUniqueID: 1, nativeBracketIdentity: nil, rawPixelFormatType: pixel,
                        rawFileType: type, rawPhotoDimensions: request.requestedDimensions,
                        rawPixelBufferDimensions: nil, timestampSeconds: nil, metadata: [:])
                    r.equal("\(chosen.rawValue) accepts only matching \(delivered.rawValue)",
                        CaptureCoordinator.acceptsRepresentation(representation, for: request, classifier: classifier), chosen == delivered)
                }
            }
            let rearHEIF = intent(.frontHEIF)
            let representation = DeliveredRAWRepresentation(bytes: Data([1]), captureID: rearHEIF.captureID,
                resolvedSettingsUniqueID: 1, nativeBracketIdentity: nil, rawPixelFormatType: 0,
                rawFileType: "public.heic", rawPhotoDimensions: rearHEIF.requestedDimensions,
                rawPixelBufferDimensions: nil, timestampSeconds: nil, metadata: [:])
            r.check("legacy HEIF remains front-only", !CaptureCoordinator.acceptsRepresentation(representation, for: rearHEIF, classifier: classifier))
        },
        TCCase(id: "JC51C", title: "JPEG sidecars declare processed truth and canonical paths without weakening RAW records") { r in
            let id = CaptureID(), library = LibraryID()
            let path = "originals/2026/10/18/" + LibraryLayout.originalFileName(for: id, format: .jpeg)
            var record = StorageFixture.sidecar(captureID: id, libraryID: library, relativePath: path,
                byteCount: 123, sha256: String(repeating: "a", count: 64))
            record.format = .jpeg
            let validator = SourceSidecarSemanticValidator()
            for camera in ["wide", "ultraWide", "telephoto", "front"] {
                record.cameraDeviceType = camera
                r.check("valid JPEG metadata on \(camera)", validator.validate(record).isEmpty)
            }
            r.check("JPEG never claims Bayer", !record.format.bayerClassification && record.format.rawPixelFormat == 0)
            r.equal("new JPEG filename", (path as NSString).pathExtension, "jpg")
            var crossed = record; crossed.format.bayerClassification = true
            r.check("mixed declaration rejected", !validator.validate(crossed).isEmpty)
            crossed = record; crossed.format.rawPixelFormat = 0x4247_4734
            r.check("JPEG cannot declare sensor pixels", !validator.validate(crossed).isEmpty)
            crossed = record; crossed.relativeOriginalPath = path.replacingOccurrences(of: ".jpg", with: ".dng")
            r.check("JPEG cannot masquerade as DNG", !validator.validate(crossed).isEmpty)
        }
    ])
}
