import Foundation

// Native test bundles read the app's real types through the module; the
// standalone verifier compiles the app sources into the same executable and
// therefore cannot import a module. XCTest is only available in the native
// bundle, so it gates the import.
#if canImport(XCTest)
@testable import TruongCam
#endif


// Synthetic metadata fixtures for shape and semantic-validation tests.
//
// These are deliberately synthetic: TEST device strings, tiny 4x4 dimensions and
// a zero placeholder checksum, exactly like planning/fixtures/. They MUST NOT
// satisfy integrity or device-validation tests, and they are never shipped in
// the app bundle.
enum MetadataFixtures {
    static let syntheticDeviceModel = "TEST-device-model"
    static let syntheticOSVersion = "TEST-os"
    static let syntheticCameraType = "AVCaptureDeviceTypeBuiltInWideAngleCamera"

    static func minimalSourceSidecar() -> SourceSidecar {
        let captureID = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
        let libraryID = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!
        return SourceSidecar(
            schemaVersion: truongCamSupportedSchemaVersion,
            captureID: captureID,
            libraryID: libraryID,
            capturedAtUTC: Date(timeIntervalSince1970: 1_790_000_000),
            timezoneOffsetSeconds: -25_200,
            relativeOriginalPath: "originals/2026/09/22/TC_11111111-2222-3333-4444-555555555555.dng",
            byteCount: 16,
            sha256: String(repeating: "a", count: 64),
            format: SourceFormatRecord(rawPixelFormat: 0x4247_4734),
            deviceModel: syntheticDeviceModel,
            osVersion: syntheticOSVersion,
            cameraDeviceType: syntheticCameraType,
            requested: CaptureRequestRecord(
                maxDimensions: PixelDimensions(width: 4, height: 4),
                exposure: ExposureRequestRecord(mode: .auto, durationSeconds: nil, iso: nil, biasEV: 0),
                focus: FocusRequestRecord(mode: .continuousAuto, position: nil),
                whiteBalance: WhiteBalanceRequestRecord(mode: .auto, temperatureKelvin: nil, tint: nil)),
            observed: SourceObservedRecord(
                rawDimensions: PixelDimensions(width: 4, height: 4),
                durationSeconds: nil,
                iso: nil,
                aperture: nil,
                focalLengthMM: nil,
                orientation: nil,
                focus: FocusObservedRecord(position: nil, provenance: .unknown),
                whiteBalance: WhiteBalanceObservedRecord(gains: nil, provenance: .unknown)),
            ui: SourceUIHints(equivalentFocalLengthMM: nil, cropGuide: nil),
            sequence: nil,
            acquisitionStatus: .complete,
            commitRecordedAtUTC: Date(timeIntervalSince1970: 1_790_000_100),
            capturedAtProvenance: .requestTimestamp)
    }

    static func completeBracketSequence() -> SequenceDocument {
        let sequenceID = SequenceID(UUID(uuidString: "99999999-8888-7777-6666-555555555555")!)
        let libraryID = LibraryID(UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!)
        var document = SequenceDocument(
            sequenceID: sequenceID,
            libraryID: libraryID,
            kind: .exposureBracket,
            plannedCount: 3,
            sourcePlan: [
                SequenceSourcePlanEntry(index: 0, offsetEV: -1, focusPosition: nil),
                SequenceSourcePlanEntry(index: 1, offsetEV: 0, focusPosition: nil),
                SequenceSourcePlanEntry(index: 2, offsetEV: 1, focusPosition: nil),
            ],
            intervalSeconds: nil,
            baseline: SequenceBaseline(
                maxDimensions: PixelDimensions(width: 4032, height: 3024),
                exposure: ExposureRequestRecord(mode: .manual, durationSeconds: 1.0 / 125, iso: 100, biasEV: 0),
                focus: FocusRequestRecord(mode: .manual, position: 0.5),
                whiteBalance: WhiteBalanceRequestRecord(mode: .manual, temperatureKelvin: 5500, tint: 0)),
            startedAtUTC: Date(timeIntervalSince1970: 1_790_000_000))
        document.completedSources = [
            SequenceCompletedSource(index: 0, captureID: UUID()),
            SequenceCompletedSource(index: 1, captureID: UUID()),
            SequenceCompletedSource(index: 2, captureID: UUID()),
        ]
        document.status = .complete
        document.endedAtUTC = Date(timeIntervalSince1970: 1_790_000_060)
        document.restorationStatus = .restored
        return document
    }

    static func completeIntervalSequence(retained: Int, planned: Int) -> SequenceDocument {
        let sequenceID = SequenceID(UUID(uuidString: "12345678-1234-1234-1234-1234567890AB")!)
        let libraryID = LibraryID(UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!)
        var document = SequenceDocument(
            sequenceID: sequenceID,
            libraryID: libraryID,
            kind: .interval,
            plannedCount: planned,
            sourcePlan: [],
            intervalSeconds: 5,
            baseline: SequenceBaseline(
                maxDimensions: PixelDimensions(width: 4032, height: 3024),
                exposure: ExposureRequestRecord(mode: .auto, durationSeconds: nil, iso: nil, biasEV: 0),
                focus: FocusRequestRecord(mode: .continuousAuto, position: nil),
                whiteBalance: WhiteBalanceRequestRecord(mode: .auto, temperatureKelvin: nil, tint: nil)),
            startedAtUTC: Date(timeIntervalSince1970: 1_790_000_000))
        document.completedSources = (0..<retained).map {
            SequenceCompletedSource(index: $0, captureID: UUID())
        }
        document.skippedDeadlineCount = 2
        document.status = .complete
        document.endedAtUTC = Date(timeIntervalSince1970: 1_790_000_120)
        document.restorationStatus = .restored
        return document
    }
}
