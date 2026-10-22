#if canImport(UIKit) && canImport(XCTest) && !TC_TESTKIT_STANDALONE
import AVFoundation
import ImageIO
import UIKit
import XCTest
@testable import TruongCam

final class NativeJPEGCameraTests: XCTestCase {
    private let dimensions = PixelDimensions(width: 4032, height: 3024)

    func testSettingsContainJPEGOnlyAndRetainCommittedCeiling() throws {
        let settings = try NativeJPEGPhotoSettings.make(requestedDimensions: dimensions,
            maximumDimensions: dimensions, supportedFileTypes: [.jpg, .heic], supportedCodecs: [.jpeg])
        XCTAssertEqual(settings.rawPhotoPixelFormatType, 0)
        XCTAssertNil(settings.rawFileType)
        XCTAssertEqual(settings.processedFileType, .jpg)
        XCTAssertEqual(settings.format?[AVVideoCodecKey] as? String, AVVideoCodecType.jpeg.rawValue)
        XCTAssertEqual(settings.maxPhotoDimensions.width, 4032)
        XCTAssertEqual(settings.maxPhotoDimensions.height, 3024)
        XCTAssertEqual(settings.photoQualityPrioritization, .speed)
        XCTAssertEqual(settings.flashMode, .off)
        XCTAssertNil(settings.previewPhotoFormat)
        XCTAssertNil(settings.rawEmbeddedThumbnailPhotoFormat)
    }

    func testSettingsRejectUnsupportedCodecContainerAndStaleCeiling() {
        XCTAssertThrowsError(try NativeJPEGPhotoSettings.make(requestedDimensions: dimensions,
            maximumDimensions: dimensions, supportedFileTypes: [.heic], supportedCodecs: [.jpeg]))
        XCTAssertThrowsError(try NativeJPEGPhotoSettings.make(requestedDimensions: dimensions,
            maximumDimensions: dimensions, supportedFileTypes: [.jpg], supportedCodecs: [.hevc]))
        XCTAssertThrowsError(try NativeJPEGPhotoSettings.make(requestedDimensions: dimensions,
            maximumDimensions: .init(width: 1920, height: 1080), supportedFileTypes: [.jpg], supportedCodecs: [.jpeg]))
        XCTAssertThrowsError(try NativeJPEGPhotoSettings.make(requestedDimensions: .init(width: 0, height: 0),
            maximumDimensions: .init(width: 0, height: 0), supportedFileTypes: [.jpg], supportedCodecs: [.jpeg]))
        let overflow = PixelDimensions(width: Int(Int32.max) + 1, height: 1)
        XCTAssertThrowsError(try NativeJPEGPhotoSettings.make(requestedDimensions: overflow,
            maximumDimensions: overflow, supportedFileTypes: [.jpg], supportedCodecs: [.jpeg]))
    }

    func testCallbackPolicyRejectsCrossedModesAndRawCompanions() {
        for camera in [PhysicalCameraKind.wide, .front, .ultraWide, .telephoto] {
            XCTAssertEqual(NativePhotoRepresentationPolicy.serialization(format: .jpeg, camera: camera,
                rawPixelFormat: 0, fileType: AVFileType.jpg.rawValue, isRawPhoto: false), .processedOriginal)
            XCTAssertNil(NativePhotoRepresentationPolicy.serialization(format: .jpeg, camera: camera,
                rawPixelFormat: 0, fileType: AVFileType.jpg.rawValue, isRawPhoto: true))
            XCTAssertNil(NativePhotoRepresentationPolicy.serialization(format: .jpeg, camera: camera,
                rawPixelFormat: 1, fileType: AVFileType.jpg.rawValue, isRawPhoto: false))
            XCTAssertNil(NativePhotoRepresentationPolicy.serialization(format: .jpeg, camera: camera,
                rawPixelFormat: 0, fileType: AVFileType.heic.rawValue, isRawPhoto: false))
        }
        XCTAssertNil(NativePhotoRepresentationPolicy.serialization(format: .bayerDNG, camera: .wide,
            rawPixelFormat: 0, fileType: AVFileType.jpg.rawValue, isRawPhoto: false))
        XCTAssertEqual(NativePhotoRepresentationPolicy.serialization(format: .bayerDNG, camera: .wide,
            rawPixelFormat: kCVPixelFormatType_14Bayer_RGGB, fileType: AVFileType.dng.rawValue,
            isRawPhoto: true), .bayerThumbnailFree)
        XCTAssertEqual(NativePhotoRepresentationPolicy.serialization(format: .frontHEIF, camera: .front,
            rawPixelFormat: 0, fileType: AVFileType.heic.rawValue, isRawPhoto: false), .processedOriginal)
        XCTAssertNil(NativePhotoRepresentationPolicy.serialization(format: .frontHEIF, camera: .wide,
            rawPixelFormat: 0, fileType: AVFileType.heic.rawValue, isRawPhoto: false))
    }

    func testActualJPEGBytesAreAcceptedWithoutReencodingAndOtherContainersRejected() throws {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let context = try XCTUnwrap(CGContext(data: nil, width: 3, height: 2, bitsPerComponent: 8,
            bytesPerRow: 12, space: colorSpace, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        context.setFillColor(red: 1, green: 0, blue: 0, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: 3, height: 2))
        let image = try XCTUnwrap(context.makeImage())
        func encoded(_ type: CFString) throws -> Data {
            let mutable = NSMutableData()
            let destination = try XCTUnwrap(CGImageDestinationCreateWithData(mutable, type, 1, nil))
            CGImageDestinationAddImage(destination, image, nil)
            XCTAssertTrue(CGImageDestinationFinalize(destination))
            return mutable as Data
        }
        let jpeg = try encoded(AVFileType.jpg.rawValue as CFString)
        let originalBytes = jpeg
        XCTAssertTrue(NativePhotoRepresentationPolicy.containerMatches(jpeg, format: .jpeg))
        XCTAssertEqual(jpeg, originalBytes)
        XCTAssertFalse(NativePhotoRepresentationPolicy.containerMatches(jpeg, format: .frontHEIF))
        XCTAssertFalse(NativePhotoRepresentationPolicy.containerMatches(try encoded("public.png" as CFString), format: .jpeg))
        XCTAssertFalse(NativePhotoRepresentationPolicy.containerMatches(Data([0xFF, 0xD8]), format: .jpeg))
    }
}
#endif
