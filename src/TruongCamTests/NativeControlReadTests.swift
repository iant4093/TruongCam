#if canImport(UIKit) && canImport(XCTest) && !TC_TESTKIT_STANDALONE
import AVFoundation
import XCTest
@testable import TruongCam

final class NativeControlReadTests: XCTestCase {
    private func instruction(
        exposure: ExposureChoice = .auto,
        biasEV: Double = 0,
        focusMode: FocusModeKind = .continuousAuto,
        point: NormalizedDevicePoint? = nil,
        whiteBalanceMode: WhiteBalanceModeKind = .auto
    ) -> NativeControlInstruction {
        NativeControlInstruction(exposure: exposure, biasEV: biasEV,
            focus: FocusIntent(mode: focusMode, position: focusMode == .manual ? 0.5 : nil,
                               pointOfInterest: point),
            whiteBalance: WhiteBalanceIntent(mode: whiteBalanceMode, temperatureAndTint: nil))
    }

    private func state(
        exposure: AVCaptureDevice.ExposureMode = .continuousAutoExposure,
        focus: AVCaptureDevice.FocusMode = .continuousAutoFocus,
        whiteBalance: AVCaptureDevice.WhiteBalanceMode = .continuousAutoWhiteBalance,
        bias: Float = 0,
        point: CGPoint? = nil
    ) -> CameraControlBinding.AutoState {
        .init(exposureMode: exposure, focusMode: focus,
              whiteBalanceMode: whiteBalance, biasEV: bias, focusPoint: point)
    }

    func testNoMutationProofReadsFreshNativeStateOncePerOperation() {
        var reads = 0
        var current = state()
        let read = { reads += 1; return current }
        let request = instruction()
        XCTAssertTrue(CameraControlBinding.controlsAlreadyMatchAuto(request, read: read))
        XCTAssertEqual(reads, 1)
        current = state(whiteBalance: .locked)
        XCTAssertFalse(CameraControlBinding.controlsAlreadyMatchAuto(request, read: read),
            "The same requested values cannot reuse an earlier matching native observation")
        XCTAssertEqual(reads, 2)
        current = state()
        XCTAssertTrue(CameraControlBinding.controlsAlreadyMatchAuto(request, read: read))
        XCTAssertEqual(reads, 3)
    }

    func testEveryNativeModeBiasAndRequestedPointMismatchRequiresOrdinaryBinding() {
        let point = NormalizedDevicePoint(x: 0.25, y: 0.75)
        let request = instruction(point: point)
        let matching = CGPoint(x: point.x, y: point.y)
        XCTAssertTrue(CameraControlBinding.controlsAlreadyMatchAuto(request) { state(point: matching) })
        let mismatches = [
            state(exposure: .custom, point: matching),
            state(exposure: .autoExpose, point: matching),
            state(focus: .locked, point: matching),
            state(focus: .autoFocus, point: matching),
            state(whiteBalance: .locked, point: matching),
            state(whiteBalance: .autoWhiteBalance, point: matching),
            state(bias: 1.0 / 3.0, point: matching),
            state(point: CGPoint(x: 0.75, y: 0.25)),
            state(point: nil),
        ]
        for (index, native) in mismatches.enumerated() {
            XCTAssertFalse(CameraControlBinding.controlsAlreadyMatchAuto(request) { native },
                "Native mismatch \(index) must retain the validated locked control path")
        }
        XCTAssertTrue(CameraControlBinding.controlsAlreadyMatchAuto(instruction()) {
            state(point: CGPoint(x: 0.8, y: 0.2))
        }, "An absent requested focus point does not request resetting the native point")
    }

    func testPriorityManualAndLockedIntentNeverUsesAutoShortcut() {
        let requests = [
            instruction(exposure: .shutterPriority(durationSeconds: 1.0 / 60.0)),
            instruction(exposure: .isoPriority(iso: 100)),
            instruction(exposure: .manual(durationSeconds: 1.0 / 60.0, iso: 100)),
            instruction(focusMode: .lockedAuto),
            instruction(focusMode: .manual),
            instruction(whiteBalanceMode: .manual),
        ]
        var reads = 0
        for request in requests {
            XCTAssertFalse(CameraControlBinding.controlsAlreadyMatchAuto(request) {
                reads += 1
                return state()
            })
        }
        XCTAssertEqual(reads, 0, "Non-Auto intent goes directly to its existing strict binding")
    }
}
#endif
