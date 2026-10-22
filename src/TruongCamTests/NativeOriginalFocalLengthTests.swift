#if canImport(XCTest) && !TC_TESTKIT_STANDALONE
import ImageIO
import XCTest
@testable import TruongCam

final class NativeOriginalFocalLengthTests: XCTestCase {
    func testOnlyThisOriginalsValidExifEquivalentCanEnterThePhotoSettingsStrip() {
        let equivalentKey = kCGImagePropertyExifFocalLenIn35mmFilm as String
        let exifKey = kCGImagePropertyExifDictionary as String
        for value: Any in [24, 48, 77, 120, "160"] {
            let details = PhotoMetadataDetails.parse([exifKey: [equivalentKey: value, "FocalLength": 5.96]])
            XCTAssertNotNil(details.equivalentFocalLength)
            XCTAssertFalse(details.settings.contains("5.96 mm"), "Physical focal length must not masquerade as full-frame equivalent.")
        }
        for value: Any in [0, -26, 26.5, 65536, Double.nan, Double.infinity, true, "unknown"] {
            let details = PhotoMetadataDetails.parse([exifKey: [equivalentKey: value, "FocalLength": 5.96]])
            XCTAssertNil(details.equivalentFocalLength, "Malformed EXIF equivalent: \(value)")
            XCTAssertTrue(details.settings.isEmpty, "Unknown equivalence has no physical or model-table fallback.")
            XCTAssertEqual(details.infoFields.first { $0.name == "FocalLength" }?.value, "5.96 mm actual")
        }
        let wrongSource = PhotoMetadataDetails.parse([
            exifKey: ["FocalLength": 5.96],
            kCGImagePropertyTIFFDictionary as String: [equivalentKey: 26, "Model": "iPhone 17 Pro"],
            "TruongCam sidecar UI": ["equivalentFocalLengthMM": 13],
            "FocalLenIn35mmFilm": 120])
        XCTAssertNil(wrongSource.equivalentFocalLength, "Container/other-dictionary/legacy sidecar hints are not this original's EXIF equivalent.")
        XCTAssertTrue(wrongSource.settings.isEmpty)
        let absentPhysical = PhotoMetadataDetails.parse([exifKey: [equivalentKey: 120]])
        XCTAssertEqual(absentPhysical.settings, ["120 mm"])
        XCTAssertEqual(absentPhysical.infoFields.first { $0.name == "FocalLength" }?.value, "120 mm equivalent")
    }
}
#endif
