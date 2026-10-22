#if canImport(UIKit) && canImport(XCTest) && !TC_TESTKIT_STANDALONE
import AVFoundation
import XCTest
@testable import TruongCam

final class NativePhotoResourcePreparationTests: XCTestCase {
    private static let request = PhotoResourcePreparationOwner.Signature(
        deviceIdentity: "wide", formatIdentity: "photo", rawPixelFormat: 1,
        rawFileType: "com.adobe.raw-image", dimensions: .init(width: 8064, height: 6048))

    func testActualOutputRetirementStaysInsideExistingConfigurationAndRejectsLateCallback() async {
        let result = await SerialSessionQueue().perform {
            let session = AVCaptureSession(), output = AVCapturePhotoOutput()
            let configurer = AVCaptureSessionConfigurer(session: session)
            let owner = PhotoResourcePreparationOwner()
            guard let outgoing = owner.reserve(Self.request) else { return [false] }
            configurer.beginConfiguration()
            let retired = AVCaptureCameraService.retirePreparedPhotoResources(output, owner: owner, isCurrent: { true })
            let sameConfiguration = configurer.configurationDepth == 1
            configurer.commitConfiguration()
            return [retired, sameConfiguration, configurer.configurationDepth == 0,
                    output.preparedPhotoSettingsArray.isEmpty, owner.snapshot == nil,
                    !owner.complete(outgoing, prepared: true), !session.isRunning]
        }
        XCTAssertEqual(result, Array(repeating: true, count: 7))
    }

    func testObsoleteRetirementCannotCancelCurrentHintOnActualOutput() async {
        let result = await SerialSessionQueue().perform {
            let output = AVCapturePhotoOutput(), owner = PhotoResourcePreparationOwner()
            let before = output.preparedPhotoSettingsArray.map(\.uniqueID)
            guard let token = owner.reserve(Self.request) else { return [false] }
            let refused = !AVCaptureCameraService.retirePreparedPhotoResources(output,
                owner: owner, isCurrent: { false })
            let retained = owner.snapshot?.token == token
            let completed = owner.complete(token, prepared: true)
            return [refused, retained, completed, owner.reserve(Self.request) == nil,
                    owner.snapshot?.phase == .prepared, output.preparedPhotoSettingsArray.map(\.uniqueID) == before]
        }
        XCTAssertEqual(result, Array(repeating: true, count: 6))
    }

    func testFreshUnownedDefaultPreparationIsNotNeedlesslyCleared() async {
        let result = await SerialSessionQueue().perform {
            let output = AVCapturePhotoOutput(), owner = PhotoResourcePreparationOwner()
            let before = output.preparedPhotoSettingsArray.map(\.uniqueID)
            let current = AVCaptureCameraService.retirePreparedPhotoResources(output,
                owner: owner, isCurrent: { true })
            return [current, owner.snapshot == nil,
                    output.preparedPhotoSettingsArray.map(\.uniqueID) == before]
        }
        XCTAssertEqual(result, Array(repeating: true, count: 3))
    }
}
#endif
