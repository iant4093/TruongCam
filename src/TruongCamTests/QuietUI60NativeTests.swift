#if canImport(UIKit) && canImport(XCTest) && !TC_TESTKIT_STANDALONE
import SwiftUI
import UIKit
import XCTest
@testable import TruongCam

final class QuietUI60NativeTests: XCTestCase {
    @MainActor private func host<V: View>(_ view: V, size: CGSize) async throws -> UIWindow {
        for _ in 0..<200 {
            if UIApplication.shared.connectedScenes.contains(where: { $0 is UIWindowScene }) { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene); window.frame = CGRect(origin: .zero, size: size)
        window.rootViewController = UIHostingController(rootView: view.ignoresSafeArea().preferredColorScheme(.dark))
        window.makeKeyAndVisible(); window.layoutIfNeeded()
        try await Task.sleep(for: .milliseconds(100))
        return window
    }
    @MainActor private func snapshot(_ window: UIWindow, name: String) throws -> UIImage {
        let format = UIGraphicsImageRendererFormat(); format.scale = 1; format.opaque = true
        let image = UIGraphicsImageRenderer(bounds: window.bounds, format: format).image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        let attachment = XCTAttachment(image: image); attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
        return image
    }
    @MainActor func testFooterIsEmptyForSingleShotAndKeepsItsHeightForEnabledTools() async throws {
        let fixture = await StorageHarness.make(name: "quiet60-footer"), h = try XCTUnwrap(fixture)
        let (camera, _) = await CaptureFormatUISuite.makeModel(h: h, capability: CaptureFormatUISuite.capability())
        let footer = CameraShootingModeFooter(camera: camera, compact: true)
        XCTAssertNil(footer.modeLabel)
        let window = try await host(footer.frame(width: 320, height: 20)
            .frame(maxWidth: .infinity, maxHeight: .infinity).background(.black), size: CGSize(width: 320, height: 80))
        defer { window.isHidden = true; window.rootViewController = nil }
        let empty = try snapshot(window, name: "quiet60-single-no-caption")
        let pixel = try XCTUnwrap(empty.cgImage)
        var rgba = [UInt8](repeating: 0, count: pixel.width * pixel.height * 4)
        rgba.withUnsafeMutableBytes { buffer in
            let context = CGContext(data: buffer.baseAddress, width: pixel.width, height: pixel.height,
                bitsPerComponent: 8, bytesPerRow: pixel.width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue)!
            context.draw(pixel, in: CGRect(x: 0, y: 0, width: pixel.width, height: pixel.height))
        }
        XCTAssertEqual((0..<rgba.count).filter { $0 % 4 != 3 && rgba[$0] > 30 }.count, 0,
            "Ordinary single-shot mode has no visible footer status or receipt")
        camera.setCaptureSpeed(.fps2)
        XCTAssertEqual(footer.modeLabel, "Burst · 2 fps")
        try await Task.sleep(for: .milliseconds(80))
        _ = try snapshot(window, name: "quiet60-burst-caption")
        let sized = UIHostingController(rootView: footer)
        XCTAssertEqual(sized.sizeThatFits(in: CGSize(width: 320, height: 100)).height, 20, accuracy: 1)
        camera.setCaptureSpeed(.single); camera.setExposureBracketEnabled(true)
        XCTAssertEqual(footer.modeLabel, "Exposure bracket")
        camera.setExposureBracketEnabled(false); camera.setTimerSeconds(3)
        XCTAssertEqual(footer.modeLabel, "Timer · 3s")
        camera.setTimerSeconds(0); XCTAssertNil(footer.modeLabel)
        await camera.stop()
    }
    @MainActor func testGalleryToolbarUsesSeparateNativeSelectAndFolderGroups() async throws {
        let fixture = await StorageHarness.make(name: "quiet60-toolbar"), h = try XCTUnwrap(fixture)
        let app = AppEnvironment(); app.attach(store: h.store, index: InMemoryLibraryIndex())
        await app.library?.loadFirstPage()
        let window = try await host(LibraryScreen().environment(app), size: CGSize(width: 402, height: 874))
        defer { window.isHidden = true; window.rootViewController = nil }
        let image = try snapshot(window, name: "quiet60-gallery-separated-toolbar")
        // Fixed 402 x 874 hosted fixture: a scan through the visible toolbar
        // centers must find two glass islands with black space between them.
        // A shared glass group renders one continuous island and fails this.
        let pixel = try XCTUnwrap(image.cgImage)
        let start = Int(window.bounds.width * 0.55), width = pixel.width - start - 8
        let strip = try XCTUnwrap(pixel.cropping(to: CGRect(x: start, y: 84, width: width, height: 1)))
        var rgba = [UInt8](repeating: 0, count: width * 4)
        rgba.withUnsafeMutableBytes { buffer in
            let context = CGContext(data: buffer.baseAddress, width: width, height: 1,
                bitsPerComponent: 8, bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue)!
            context.draw(strip, in: CGRect(x: 0, y: 0, width: width, height: 1))
        }
        var runs: [Int] = [], length = 0
        for x in 0..<width {
            // Close only subpixel/glyph-shadow holes. The native 12-point
            // black gap must still separate the two visible glass capsules.
            let lit = (max(0, x - 1)...min(width - 1, x + 1)).contains { sample in
                max(rgba[sample * 4], rgba[sample * 4 + 1], rgba[sample * 4 + 2]) >= 15
            }
            if lit { length += 1 }
            else if length > 0 { runs.append(length); length = 0 }
        }
        if length > 0 { runs.append(length) }
        XCTAssertEqual(runs.filter { $0 >= 20 }.count, 2,
            "Select and Folder need separate glass backgrounds, not one joined toolbar group")

    }
}
#endif
