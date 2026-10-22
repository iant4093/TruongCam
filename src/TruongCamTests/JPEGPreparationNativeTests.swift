#if canImport(UIKit) && canImport(XCTest) && !TC_TESTKIT_STANDALONE
import AVFoundation
import Synchronization
import XCTest
@testable import TruongCam

final class JPEGPreparationNativeTests: XCTestCase {
    private typealias Completion = @Sendable (Bool, Error?) -> Void
    private func signature(_ generation: String = "one") -> PhotoResourcePreparationOwner.Signature {
        .init(deviceIdentity: "synthetic-device", formatIdentity: generation, rawPixelFormat: 0,
            rawFileType: AVFileType.jpg.rawValue, dimensions: .init(width: 4032, height: 3024))
    }
    private func settings() throws -> AVCapturePhotoSettings {
        try NativeJPEGPhotoSettings.make(requestedDimensions: signature().dimensions,
            maximumDimensions: signature().dimensions, supportedFileTypes: [.jpg], supportedCodecs: [.jpeg])
    }
    func testJPEGPreparationIsOptionalDeduplicatedAndOldCallbackCannotCompleteReplacement() throws {
        let owner = PhotoResourcePreparationOwner(), completions = Mutex<[Completion]>([])
        let current = Mutex(true), issued = Mutex(0)
        let initial = try settings()
        func issue(_ values: [AVCapturePhotoSettings], _ completion: @escaping Completion) {
            issued.withLock { $0 += values.count }; completions.withLock { $0.append(completion) }
        }
        XCTAssertTrue(NativeJPEGPhotoSettings.prepareResources(initial, signature: signature(), owner: owner,
            isCurrent: { current.withLock { $0 } }, issue: issue))
        XCTAssertEqual(owner.snapshot?.phase, .preparing, "Pending allocation is not shutter admission evidence")
        XCTAssertFalse(NativeJPEGPhotoSettings.prepareResources(try settings(), signature: signature(), owner: owner,
            isCurrent: { current.withLock { $0 } }, issue: issue))
        XCTAssertEqual(issued.withLock { $0 }, 1)
        XCTAssertEqual(initial.rawPhotoPixelFormatType, 0); XCTAssertEqual(initial.processedFileType, .jpg)
        XCTAssertTrue(owner.retire())
        XCTAssertTrue(NativeJPEGPhotoSettings.prepareResources(try settings(), signature: signature("replacement"), owner: owner,
            isCurrent: { current.withLock { $0 } }, issue: issue))
        let callbacks = completions.withLock { $0 }
        callbacks[0](true, nil)
        XCTAssertEqual(owner.snapshot?.phase, .preparing)
        callbacks[1](false, CocoaError(.featureUnsupported))
        XCTAssertEqual(owner.snapshot?.phase, .failed, "Optional failure stays retryable without affecting capture")
        XCTAssertTrue(NativeJPEGPhotoSettings.prepareResources(try settings(), signature: signature("replacement"), owner: owner,
            isCurrent: { current.withLock { $0 } }, issue: issue))
        current.withLock { $0 = false }
        completions.withLock { $0.last }?(true, nil)
        XCTAssertEqual(owner.snapshot?.phase, .failed, "Late obsolete success cannot certify resources")
    }
    func testNonJPEGOrObsoleteHintsNeverReachSDKIssue() throws {
        let owner = PhotoResourcePreparationOwner(), count = Mutex(0)
        let issue: ([AVCapturePhotoSettings], @escaping Completion) -> Void = { _, _ in count.withLock { $0 += 1 } }
        XCTAssertFalse(NativeJPEGPhotoSettings.prepareResources(try settings(), signature: signature(), owner: owner,
            isCurrent: { false }, issue: issue))
        let crossed = PhotoResourcePreparationOwner.Signature(deviceIdentity: "d", formatIdentity: "f", rawPixelFormat: 1,
            rawFileType: AVFileType.dng.rawValue, dimensions: signature().dimensions)
        XCTAssertFalse(NativeJPEGPhotoSettings.prepareResources(try settings(), signature: crossed, owner: owner,
            isCurrent: { true }, issue: issue))
        XCTAssertNil(owner.snapshot); XCTAssertEqual(count.withLock { $0 }, 0)
    }
}
#endif
