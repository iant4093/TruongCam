#if canImport(UIKit) && canImport(XCTest) && !TC_TESTKIT_STANDALONE
import CoreGraphics
import SwiftUI
import UIKit
import XCTest
@testable import TruongCam

final class CameraControlSpacing58NativeTests: XCTestCase {
    @MainActor private func host<V: View>(_ view: V, size: CGSize) async throws -> UIWindow {
        for _ in 0..<300 {
            if UIApplication.shared.connectedScenes.contains(where: { $0 is UIWindowScene }) { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(origin: .zero, size: size)
        window.rootViewController = UIHostingController(rootView: view.ignoresSafeArea())
        window.makeKeyAndVisible(); window.layoutIfNeeded()
        try await Task.sleep(for: .milliseconds(80))
        return window
    }

    @MainActor private func descendants<V: UIView>(_ type: V.Type, in root: UIView) -> [V] {
        ((root as? V).map { [$0] } ?? []) + root.subviews.flatMap { descendants(type, in: $0) }
    }

    @MainActor func testShippingPortraitShutterUsesTheLowerAnchorAndStaysFixedForBothWBRulers() async throws {
        let fixture = await StorageHarness.make(name: "native58-control-spacing"), h = try XCTUnwrap(fixture)
        for size in [CGSize(width: 320, height: 548), CGSize(width: 402, height: 778), CGSize(width: 440, height: 860)] {
            let (camera, _) = await CaptureFormatUISuite.makeModel(h: h, capability: CaptureFormatUISuite.capability())
            let app = AppEnvironment(); app.attach(store: h.store, index: InMemoryLibraryIndex()); app.attach(camera: camera)
            camera.setCaptureSpeed(.fps5)
            let window = try await host(CameraScreen().environment(app).preferredColorScheme(.dark), size: size)
            defer { window.isHidden = true; window.rootViewController = nil }
            let root = try XCTUnwrap(window.rootViewController?.view)
            let surface = try XCTUnwrap(descendants(ContinuousShutterTouchView.self, in: root).first)
            let actual = surface.convert(surface.bounds, to: root)
            let plan = CameraScreenLayout(size: size, bottomSafeArea: 0, accessibility: false)
            XCTAssertEqual(actual.midX, size.width / 2, accuracy: 0.5)
            XCTAssertEqual(actual.maxY, size.height - 20, accuracy: 0.5, "The real action row sits eight points below build57 on no-inset content")
            XCTAssertEqual(actual.minY - plan.controls.minY - plan.parameterHeight, 8, accuracy: 0.5, "Shipping RootView must install the reserved gap")
            XCTAssertGreaterThanOrEqual(actual.width, 75.5); XCTAssertGreaterThanOrEqual(actual.height, 75.5)
            for panel: CameraPanel? in [.whiteBalance, .shutter, .iso, .focus, nil] {
                camera.openPanel = panel
                window.layoutIfNeeded(); try await Task.sleep(for: .milliseconds(220))
                XCTAssertEqual(surface.convert(surface.bounds, to: root), actual, "Both WB rows and every other panel keep the lower shutter fixed")
            }
            window.isHidden = true; window.rootViewController = nil
            await camera.stop()
        }
    }

    @MainActor func testShippingLandscapeReservesTheGapOutsideItsParameterScrollWithoutMovingTheShutter() async throws {
        let fixture = await StorageHarness.make(name: "native58-landscape-spacing"), h = try XCTUnwrap(fixture)
        for size in [CGSize(width: 528, height: 320), CGSize(width: 750, height: 381)] {
            let (camera, _) = await CaptureFormatUISuite.makeModel(h: h, capability: CaptureFormatUISuite.capability())
            let app = AppEnvironment(); app.attach(store: h.store, index: InMemoryLibraryIndex()); app.attach(camera: camera)
            camera.setCaptureSpeed(.fps5); camera.openPanel = .whiteBalance
            let window = try await host(CameraScreen().environment(app).preferredColorScheme(.dark), size: size)
            defer { window.isHidden = true; window.rootViewController = nil }
            let root = try XCTUnwrap(window.rootViewController?.view)
            let surface = try XCTUnwrap(descendants(ContinuousShutterTouchView.self, in: root).first)
            let shutter = surface.convert(surface.bounds, to: root)
            let scroll = try XCTUnwrap(descendants(UIScrollView.self, in: root).first)
            let parameters = scroll.convert(scroll.bounds, to: root)
            let plan = CameraScreenLayout(size: size, bottomSafeArea: 0, accessibility: false)
            XCTAssertEqual(parameters.height, plan.parameterHeight, accuracy: 0.5)
            // Landscape puts the 76-point button inside a 92-point action row.
            XCTAssertEqual(shutter.minY - 8 - parameters.maxY, 8, accuracy: 0.5)
            XCTAssertEqual(shutter.maxY, size.height - 38, accuracy: 0.5, "Existing landscape bottom anchor stays unchanged")
            XCTAssertFalse(plan.preview.intersects(plan.controls))
            camera.openPanel = nil; window.layoutIfNeeded()
            try await Task.sleep(for: .milliseconds(220))
            XCTAssertEqual(surface.convert(surface.bounds, to: root), shutter)
            window.isHidden = true; window.rootViewController = nil
            await camera.stop()
        }
    }

    @MainActor func testShippingCompactAccessibilityWBScrollsWithoutConsumingTheNewShutterGap() async throws {
        let fixture = await StorageHarness.make(name: "native58-accessibility-spacing"), h = try XCTUnwrap(fixture)
        let (camera, _) = await CaptureFormatUISuite.makeModel(h: h, capability: CaptureFormatUISuite.capability())
        let app = AppEnvironment(); app.attach(store: h.store, index: InMemoryLibraryIndex()); app.attach(camera: camera)
        camera.setCaptureSpeed(.fps5); camera.openPanel = .whiteBalance
        let size = CGSize(width: 320, height: 548)
        let window = try await host(CameraScreen().environment(app).dynamicTypeSize(.accessibility3).preferredColorScheme(.dark), size: size)
        defer { window.isHidden = true; window.rootViewController = nil }
        let root = try XCTUnwrap(window.rootViewController?.view)
        let surface = try XCTUnwrap(descendants(ContinuousShutterTouchView.self, in: root).first)
        let shutter = surface.convert(surface.bounds, to: root)
        let scroll = try XCTUnwrap(descendants(UIScrollView.self, in: root).first)
        let well = scroll.convert(scroll.bounds, to: root)
        XCTAssertEqual(well.height, 60, accuracy: 0.5)
        XCTAssertGreaterThanOrEqual(scroll.contentSize.height, 175.5, "Both full-size WB rulers remain scrollable")
        XCTAssertEqual(shutter.minY - well.maxY, 8, accuracy: 0.5)
        XCTAssertEqual(shutter.maxY, size.height - 20, accuracy: 0.5)
        let format = UIGraphicsImageRendererFormat(); format.scale = 1; format.opaque = true
        let image = UIGraphicsImageRenderer(bounds: window.bounds, format: format).image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        let attachment = XCTAttachment(image: image); attachment.name = "camera58-compact-accessibility-lower-controls"
        attachment.lifetime = .keepAlways; add(attachment)
        camera.openPanel = nil; window.layoutIfNeeded()
        try await Task.sleep(for: .milliseconds(220))
        XCTAssertEqual(surface.convert(surface.bounds, to: root), shutter)
        await camera.stop()
    }

    @MainActor func testShortLandscapeWBShowsBothRulerMarkersAboveTheFixedShutterGap() async throws {
        let fixture = await StorageHarness.make(name: "native58-short-landscape-wb"), h = try XCTUnwrap(fixture)
        let (camera, _) = await CaptureFormatUISuite.makeModel(h: h, capability: CaptureFormatUISuite.capability())
        let app = AppEnvironment(); app.attach(store: h.store, index: InMemoryLibraryIndex()); app.attach(camera: camera)
        camera.setCaptureSpeed(.fps5); camera.openPanel = .whiteBalance
        // The old rotation fixture resizes a portrait window to 874x402 while
        // retaining 62pt top/34pt bottom inherited insets. Test the equivalent
        // available 306pt height directly, independently of current scene axes.
        let size = CGSize(width: 874, height: 306)
        let window = try await host(CameraScreen().environment(app).preferredColorScheme(.dark), size: size)
        defer { window.isHidden = true; window.rootViewController = nil }
        let root = try XCTUnwrap(window.rootViewController?.view)
        let scroll = try XCTUnwrap(descendants(UIScrollView.self, in: root).first)
        let parameters = scroll.convert(scroll.bounds, to: root)
        XCTAssertEqual(parameters.height, 176, accuracy: 0.5)
        XCTAssertGreaterThan(scroll.contentSize.height, parameters.height, "Short landscapes retain scrolling and full ruler targets")
        let surface = try XCTUnwrap(descendants(ContinuousShutterTouchView.self, in: root).first)
        let shutter = surface.convert(surface.bounds, to: root)
        XCTAssertEqual(shutter.minY - 8 - parameters.maxY, 8, accuracy: 0.5)
        try await Task.sleep(for: .milliseconds(220))
        let format = UIGraphicsImageRendererFormat(); format.scale = 1; format.opaque = true
        let image = UIGraphicsImageRenderer(bounds: window.bounds, format: format).image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        let attachment = XCTAttachment(image: image); attachment.name = "camera58-short-landscape-both-wb-markers"
        attachment.lifetime = .keepAlways; add(attachment)
        let bitmap = try XCTUnwrap(image.cgImage), width = bitmap.width, height = bitmap.height
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        let drew = bytes.withUnsafeMutableBytes { memory -> Bool in
            guard let context = CGContext(data: memory.baseAddress, width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue) else { return false }
            context.draw(bitmap, in: CGRect(x: 0, y: 0, width: width, height: height)); return true
        }
        XCTAssertTrue(drew)
        let center = Int(parameters.midX.rounded())
        var markerGroups = 0, wasYellow = false
        for y in 96..<min(height, Int(parameters.maxY)) {
            let yellow = ((center - 2)...(center + 2)).contains { x in
                let i = (y * width + x) * 4
                return bytes[i] > 180 && bytes[i + 1] > 130 && bytes[i + 2] < 100
            }
            if yellow && !wasYellow { markerGroups += 1 }
            wasYellow = yellow
        }
        XCTAssertEqual(markerGroups, 2, "Temperature and tint must both be visible before scrolling; the 8pt shutter gap cannot hide tint")
        await camera.stop()
    }
}
#endif
