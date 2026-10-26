#if canImport(UIKit) && canImport(XCTest) && !TC_TESTKIT_STANDALONE
import AVFoundation
import SwiftUI
import UIKit
import XCTest
@testable import TruongCam

final class NativeControlReadTests: XCTestCase {
    private func instruction(
        exposure: ExposureChoice = .auto,
        biasEV: Double = 0,
        focusMode: FocusModeKind = .continuousAuto,
        point: NormalizedDevicePoint? = nil,
        whiteBalanceMode: WhiteBalanceModeKind = .auto,
        aperture: ApertureChoice = .auto
    ) -> NativeControlInstruction {
        NativeControlInstruction(exposure: exposure, biasEV: biasEV,
            focus: FocusIntent(mode: focusMode, position: focusMode == .manual ? 0.5 : nil,
                               pointOfInterest: point),
            whiteBalance: WhiteBalanceIntent(mode: whiteBalanceMode, temperatureAndTint: nil), aperture: aperture)
    }

    private func state(
        exposure: AVCaptureDevice.ExposureMode = .continuousAutoExposure,
        focus: AVCaptureDevice.FocusMode = .continuousAutoFocus,
        whiteBalance: AVCaptureDevice.WhiteBalanceMode = .continuousAutoWhiteBalance,
        bias: Float = 0,
        point: CGPoint? = nil,
        apertureAutomatic: Bool = true,
        fixedAperture: Bool = false
    ) -> CameraControlBinding.AutoState {
        .init(exposureMode: exposure, focusMode: focus,
              whiteBalanceMode: whiteBalance, biasEV: bias, focusPoint: point,
              isApertureAutomatic: apertureAutomatic, isFixedApertureCamera: fixedAperture)
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
        current = state(apertureAutomatic: false)
        XCTAssertFalse(CameraControlBinding.controlsAlreadyMatchAuto(request, read: read),
            "A variable aperture left locked cannot reuse the continuous-Auto shortcut")
        XCTAssertEqual(reads, 4)
        current = state(apertureAutomatic: false, fixedAperture: true)
        XCTAssertTrue(CameraControlBinding.controlsAlreadyMatchAuto(request, read: read),
            "A discovered fixed aperture requires no needless setter to move a diaphragm it does not have")
        XCTAssertEqual(reads, 5)
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
            instruction(aperture: .manual(fNumber: 2.8)),
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

    @MainActor func testVariableApertureReadoutsFitCompactPortraitAndLandscapeTargets() async throws {
        let made = await StorageHarness.make(name: "native-aperture-readouts"), h = try XCTUnwrap(made)
        var capability = StartupRepairSuite.controlFixture(modes: Set(ExposureModeKind.allCases))
        capability.physicalCameras[0].formats[0].apertureCapability = ApertureCapability(
            minFNumber: 1.48, maxFNumber: 4, recommendedStops: [1.48, 1.8, 2.8, 4],
            autoExposureModes: Set(ExposureModeKind.allCases), manualExposureModes: Set(ExposureModeKind.allCases))
        let camera = CameraViewModel(camera: SyntheticCameraService(capability: capability),
            capture: CaptureCoordinator(camera: ChainCameraSpy(), store: h.store, clock: SystemMonotonicClock()),
            metering: MeteringService(clock: SystemMonotonicClock()), preferences: SyntheticPreferenceStore(), levelFeed: SyntheticLevelFeed())
        let app = AppEnvironment(); app.attach(camera: camera); app.graphState = .ready
        await camera.start()
        camera.setAperture(2.8); camera.openPanel = .aperture
        XCTAssertTrue(camera.isApertureAvailable)
        for _ in 0..<100 {
            if UIApplication.shared.connectedScenes.contains(where: { $0 is UIWindowScene }) { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        for (landscape, size) in [(false, CGSize(width: 320, height: CameraScreenLayout.readoutHeight)),
                                  (false, CGSize(width: 402, height: CameraScreenLayout.readoutHeight)),
                                  (true, CGSize(width: 172, height: 96))] {
            let row = landscape ? AnyView(CameraReadoutGrid()) : AnyView(CameraReadoutRow())
            let host = UIHostingController(rootView: row.environment(app).preferredColorScheme(.dark))
            host.safeAreaRegions = []
            let fitting = host.sizeThatFits(in: CGSize(width: size.width, height: 200))
            XCTAssertLessThanOrEqual(fitting.width, size.width + 0.5, "Adding aperture must not overflow the compact control rail")
            XCTAssertGreaterThanOrEqual(fitting.height, landscape ? 96 : 44, "Readout targets keep their full touch height")
            XCTAssertLessThanOrEqual(fitting.height, size.height + 0.5, "Complete labels and values fit the shipping row height")
            let window = UIWindow(windowScene: scene)
            window.frame = CGRect(origin: .zero, size: size)
            let rasterHost = UIHostingController(rootView: row.environment(app)
                .frame(width: size.width, height: size.height).background(.black).preferredColorScheme(.dark))
            rasterHost.safeAreaRegions = [] // Isolated component, not a full-screen safe-area capture.
            window.rootViewController = rasterHost
            window.makeKeyAndVisible(); window.layoutIfNeeded()
            try await Task.sleep(for: .milliseconds(150))
            let format = UIGraphicsImageRendererFormat(); format.scale = 1; format.opaque = true
            let raster = UIGraphicsImageRenderer(bounds: window.bounds, format: format).image { _ in
                window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
            }
            let attachment = XCTAttachment(image: raster)
            attachment.name = "aperture-\(landscape ? "landscape" : "portrait")-\(Int(size.width))"
            attachment.lifetime = .keepAlways; add(attachment)
            XCTAssertEqual(raster.size, size)
            let bitmap = try XCTUnwrap(raster.cgImage)
            var rgba = [UInt8](repeating: 0, count: bitmap.width * bitmap.height * 4)
            try rgba.withUnsafeMutableBytes { bytes in
                let context = try XCTUnwrap(CGContext(data: bytes.baseAddress, width: bitmap.width, height: bitmap.height,
                    bitsPerComponent: 8, bytesPerRow: bitmap.width * 4, space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue))
                context.draw(bitmap, in: CGRect(origin: .zero, size: size))
            }
            var yellowCount = 0, firstYellow = bitmap.width, lastYellow = -1
            for y in 0..<bitmap.height {
                for x in 0..<bitmap.width {
                    let offset = (y * bitmap.width + x) * 4
                    if rgba[offset] > 150, rgba[offset + 1] > 100, rgba[offset + 2] < 120 {
                        yellowCount += 1; firstYellow = min(firstYellow, x); lastYellow = max(lastYellow, x)
                    }
                }
            }
            let padding: CGFloat = landscape ? 12 : 16
            let columns: CGFloat = landscape ? 3 : 5
            let columnWidth = (size.width - 2 * padding - (columns - 1) * 8) / columns
            let apertureLeft = padding + 2 * (columnWidth + 8)
            XCTAssertGreaterThan(yellowCount, 8, "The shipping aperture value must actually paint in its selected control")
            XCTAssertGreaterThan(CGFloat(firstYellow), apertureLeft + 1, "Aperture glyphs clear the left target edge")
            XCTAssertLessThan(CGFloat(lastYellow), apertureLeft + columnWidth - 1, "Aperture glyphs clear the right target edge")
            window.isHidden = true; window.rootViewController = nil
        }
        await camera.stop()
    }
}
#endif
