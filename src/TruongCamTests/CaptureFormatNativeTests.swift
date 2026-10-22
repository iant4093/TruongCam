#if canImport(UIKit) && canImport(XCTest) && !TC_TESTKIT_STANDALONE
import CoreGraphics
import SwiftUI
import UIKit
import XCTest
@testable import TruongCam

/// Hosts the actual shipping top row; no synthetic UI text or camera values are
/// substituted. Raster checks keep the centered EV separate from the new menu.
final class CaptureFormatNativeTests: XCTestCase {
    @MainActor private func host<V: View>(_ view: V, size: CGSize) async throws -> UIWindow {
        for _ in 0..<300 {
            if UIApplication.shared.connectedScenes.contains(where: { $0 is UIWindowScene }) { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(origin: .zero, size: size)
        window.rootViewController = UIHostingController(rootView: view)
        window.makeKeyAndVisible()
        window.layoutIfNeeded()
        try await Task.sleep(for: .milliseconds(150))
        return window
    }

    @MainActor private func pixels(_ window: UIWindow, name: String) throws -> (width: Int, height: Int, bytes: [UInt8]) {
        let format = UIGraphicsImageRendererFormat(); format.scale = 1; format.opaque = true
        let rendered = UIGraphicsImageRenderer(bounds: window.bounds, format: format).image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        let attachment = XCTAttachment(image: rendered); attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
        let image = try XCTUnwrap(rendered.cgImage), width = image.width, height = image.height
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        let drew = bytes.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        XCTAssertTrue(drew)
        return (width, height, bytes)
    }

    @MainActor func testFormatMenuChangesVisibleChipWithoutMovingOrChangingMainExposureControl() async throws {
        let fixture = await StorageHarness.make(name: "native-format51-row"), h = try XCTUnwrap(fixture)
        for size in [CGSize(width: 375, height: 812), CGSize(width: 874, height: 402)] {
            let service = SyntheticCameraService(capability: CaptureFormatUISuite.capability())
            let camera = CameraViewModel(camera: service,
                capture: CaptureCoordinator(camera: ChainCameraSpy(), store: h.store, clock: SystemMonotonicClock()),
                metering: MeteringService(clock: SystemMonotonicClock()), preferences: SyntheticPreferenceStore(), levelFeed: SyntheticLevelFeed())
            let app = AppEnvironment(); app.attach(camera: camera)
            await camera.start()
            let row = CameraTopRow(isCompact: size.width > size.height).environment(app)
                .padding(.horizontal, 14).frame(maxWidth: .infinity).frame(height: 80)
                .background(.black).frame(maxHeight: .infinity, alignment: .top).ignoresSafeArea()
            let window = try await host(row.preferredColorScheme(.dark), size: size)
            defer { window.isHidden = true; window.rootViewController = nil }
            let raw = try pixels(window, name: "format51-raw-\(Int(size.width))")
            camera.selectCaptureFormat(.jpeg)
            try await Task.sleep(for: .milliseconds(150))
            let jpeg = try pixels(window, name: "format51-jpeg-\(Int(size.width))")
            XCTAssertEqual(camera.captureFormatLabel, "JPEG")
            XCTAssertEqual(raw.width, jpeg.width); XCTAssertEqual(raw.height, jpeg.height)
            var rightChanged = 0, centerChanged = 0, centerVisible = 0
            for y in 0..<min(80, raw.height) {
                for x in 0..<raw.width {
                    let i = (y * raw.width + x) * 4
                    let changed = raw.bytes[i..<(i + 3)] != jpeg.bytes[i..<(i + 3)]
                    if x > raw.width * 3 / 4, changed { rightChanged += 1 }
                    if abs(x - raw.width / 2) < 35 {
                        if changed { centerChanged += 1 }
                        if jpeg.bytes[i] > 170 && jpeg.bytes[i + 1] > 170 && jpeg.bytes[i + 2] > 170 { centerVisible += 1 }
                    }
                }
            }
            XCTAssertGreaterThan(rightChanged, 20, "The shipping top-right mode chip must actually redraw from RAW to JPEG")
            XCTAssertEqual(centerChanged, 0, "Changing format cannot move or replace the centered main EV control")
            XCTAssertGreaterThan(centerVisible, 15, "The main EV control remains visibly rendered")
            await camera.stop()
        }
    }
}
#endif
