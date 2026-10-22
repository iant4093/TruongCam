#if canImport(UIKit) && canImport(XCTest) && !TC_TESTKIT_STANDALONE
import CoreGraphics
import SwiftUI
import UIKit
import XCTest
@testable import TruongCam

final class CameraGallery55NativeTests: XCTestCase {
    @MainActor private func request(_ card: LibrarySourceCard, h: StorageHarness, revision: Int = 1) -> ThumbnailModel.Request {
        ThumbnailModel.Request(card: card, sourceRevision: revision, rootState: h.store.rootState,
            targetLongEdge: CameraGalleryThumbnailModel.targetLongEdge, rootURL: h.store.grantedRootURL)
    }

    @MainActor func testCameraShortcutReusesItsBoundedImageAndCannotRelabelItAsANewerPhoto() async throws {
        let fixture = await StorageHarness.make(name: "native55-shortcut"), h = try XCTUnwrap(fixture)
        let cards = StorageFixture.cards(count: 2, libraryID: h.libraryID, startingAt: StorageFixture.fixedDate)
        let provider = LibraryPreviewFixture(), model = CameraGalleryThumbnailModel()
        let source = GalleryThumbnailSource.scoped(store: h.store, thumbnails: provider)
        let first = request(cards[0], h: h), next = request(cards[1], h: h)
        await model.load(request: first, source: source, enabled: false)
        XCTAssertEqual(provider.count, 0, "Optional decode cannot start while the camera owns priority")
        XCTAssertNil(model.image(for: first))
        await model.load(request: first, source: source, enabled: true)
        XCTAssertNotNil(model.image(for: first)); XCTAssertEqual(provider.count, 1)
        XCTAssertEqual(first.targetLongEdge, 256, "Use the existing grid cache variant")
        await model.load(request: first, source: source, enabled: true)
        XCTAssertEqual(provider.count, 1, "An unchanged shortcut must reuse its image")
        XCTAssertNil(model.image(for: next), "Old pixels cannot be called the newest photo")
        await model.load(request: next, source: source, enabled: false)
        XCTAssertNil(model.image(for: next)); XCTAssertEqual(provider.count, 1)
        await model.load(request: next, source: source, enabled: true)
        XCTAssertNotNil(model.image(for: next)); XCTAssertNil(model.image(for: first)); XCTAssertEqual(provider.count, 2)
        await model.load(request: next, source: source, enabled: false)
        XCTAssertNotNil(model.image(for: next), "A loaded current thumbnail stays visible during a photo")
        XCTAssertNil(model.image(for: nil), "An empty/released library immediately restores the fallback icon")
        await model.load(request: nil, source: source, enabled: false)
        XCTAssertNil(model.completedRequest)
    }

    @MainActor func testMissingShortcutRetriesWhenSourceArrivesAndProviderReplacementInvalidatesPixels() async throws {
        let fixture = await StorageHarness.make(name: "native55-retry"), h = try XCTUnwrap(fixture)
        let card = StorageFixture.cards(count: 1, libraryID: h.libraryID, startingAt: StorageFixture.fixedDate)[0]
        let model = CameraGalleryThumbnailModel(), original = request(card, h: h)
        await model.load(request: original, source: .unavailable(reason: "Synthetic missing source"), enabled: true)
        XCTAssertNil(model.image(for: original)); XCTAssertNil(model.completedRequest)
        let provider = LibraryPreviewFixture(), source = GalleryThumbnailSource.scoped(store: h.store, thumbnails: provider)
        let replaced = request(card, h: h, revision: 2)
        await model.load(request: replaced, source: source, enabled: true)
        XCTAssertNotNil(model.image(for: replaced)); XCTAssertNil(model.image(for: original))
        let refreshed = request(card, h: h, revision: 3)
        XCTAssertNil(model.image(for: refreshed), "Replacing the provider cannot keep an old-source image")
        await model.load(request: refreshed, source: source, enabled: true)
        XCTAssertEqual(provider.count, 2); XCTAssertNotNil(model.image(for: refreshed))
    }

    @MainActor func testHeldShortcutDecodeLeavesUIResponsiveAndRootReleaseRejectsItsLateImage() async throws {
        let coordinator = ObservedLibraryReadCoordinator()
        let fixture = await StorageHarness.make(name: "native55-held", coordinator: coordinator), h = try XCTUnwrap(fixture)
        let card = StorageFixture.cards(count: 1, libraryID: h.libraryID, startingAt: StorageFixture.fixedDate)[0]
        let hold = HeldLibraryDecode(); defer { hold.release() }
        let provider = LibraryPreviewFixture(hold: hold), model = CameraGalleryThumbnailModel()
        let value = request(card, h: h), source = GalleryThumbnailSource.scoped(store: h.store, thumbnails: provider)
        let work = Task { await model.load(request: value, source: source, enabled: true) }
        let entered = await LibraryPerformanceSuite.waitUntil { hold.didEnter }
        XCTAssertTrue(entered); XCTAssertFalse(hold.onMain); XCTAssertEqual(coordinator.activeReads, 1)
        let view = UIView(frame: CGRect(x: 0, y: 0, width: 44, height: 44))
        XCTAssertEqual(view.bounds.width, 44, "MainActor is available while the cold read is held")
        work.cancel(); model.cancel(); await h.store.releaseRoot()
        XCTAssertNil(model.image(for: nil))
        hold.release(); await work.value
        XCTAssertNil(model.image(for: value)); XCTAssertNil(model.completedRequest)
        let readers = await h.store.activeReaderCount
        XCTAssertEqual(readers, 0); XCTAssertFalse(hold.timedOut)
    }

    @MainActor private func host<V: View>(_ view: V, size: CGSize) async throws -> UIWindow {
        for _ in 0..<300 {
            if UIApplication.shared.connectedScenes.contains(where: { $0 is UIWindowScene }) { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene); window.frame = CGRect(origin: .zero, size: size)
        window.rootViewController = UIHostingController(rootView: view.ignoresSafeArea())
        window.makeKeyAndVisible(); window.layoutIfNeeded()
        try await Task.sleep(for: .milliseconds(80))
        return window
    }

    @MainActor private func raster(_ window: UIWindow, name: String) throws -> (Int, Int, [UInt8]) {
        let format = UIGraphicsImageRendererFormat(); format.scale = 1; format.opaque = true
        let image = UIGraphicsImageRenderer(bounds: window.bounds, format: format).image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        let attachment = XCTAttachment(image: image); attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
        let bitmap = try XCTUnwrap(image.cgImage), w = bitmap.width, h = bitmap.height
        var bytes = [UInt8](repeating: 0, count: w * h * 4)
        let drew = bytes.withUnsafeMutableBytes { p -> Bool in
            guard let context = CGContext(data: p.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue) else { return false }
            context.draw(bitmap, in: CGRect(x: 0, y: 0, width: w, height: h)); return true
        }
        XCTAssertTrue(drew); return (w, h, bytes)
    }

    @MainActor func testShippingGalleryLabelShowsPhotoOrIconWithinTheSame44PointTarget() async throws {
        let pixel: [UInt8] = [245, 0, 0, 255]
        let rgba: [UInt8] = Array(repeating: pixel, count: 64).flatMap { $0 }
        let image = try XCTUnwrap(CGImage.rgbaDisplayImage(bytes: rgba, width: 8, height: 8))
        for photo in [false, true] {
            let label = CameraGalleryButtonLabel(image: photo ? image : nil).foregroundStyle(.white)
            let window = try await host(label.frame(maxWidth: .infinity, maxHeight: .infinity).background(.black), size: CGSize(width: 88, height: 88))
            let (w, h, bytes) = try raster(window, name: "camera55-gallery-\(photo ? "photo" : "empty")")
            let red = stride(from: 0, to: bytes.count, by: 4).filter { bytes[$0] > 180 && bytes[$0 + 1] < 40 && bytes[$0 + 2] < 40 }.count
            if photo { XCTAssertGreaterThan(red, 850); XCTAssertLessThan(red, 38 * 38) }
            else {
                XCTAssertEqual(red, 0)
                let white = stride(from: 0, to: bytes.count, by: 4).filter { bytes[$0] > 150 && bytes[$0 + 1] > 150 && bytes[$0 + 2] > 150 }.count
                XCTAssertGreaterThan(white, 30, "Empty state retains its visible gallery icon")
            }
            XCTAssertEqual(w, 88); XCTAssertEqual(h, 88)
            window.isHidden = true; window.rootViewController = nil
        }
    }

    @MainActor private func descendants<V: UIView>(_ type: V.Type, in root: UIView) -> [V] {
        ((root as? V).map { [$0] } ?? []) + root.subviews.flatMap { descendants(type, in: $0) }
    }

    @MainActor func testCompactAdjustmentScrollsOnlyRulersKeepingAutoAndCloseVisible() async throws {
        let fixture = await StorageHarness.make(name: "native55-compact-controls"), h = try XCTUnwrap(fixture)
        let (camera, _) = await CaptureFormatUISuite.makeModel(h: h, capability: CaptureFormatUISuite.capability())
        camera.openPanel = .whiteBalance
        let window = try await host(CameraAdjustmentWell(camera: camera, controlsViewportHeight: 44, controlsContentHeight: 100)
            .frame(width: 320, height: 44).frame(maxWidth: .infinity, maxHeight: .infinity).background(.black),
            size: CGSize(width: 320, height: 100))
        defer { window.isHidden = true; window.rootViewController = nil }
        let root = try XCTUnwrap(window.rootViewController?.view)
        let scroll = try XCTUnwrap(descendants(UIScrollView.self, in: root).first)
        let rect = scroll.convert(scroll.bounds, to: root)
        XCTAssertGreaterThan(scroll.contentSize.height, 44, "The two WB rulers remain scrollable")
        XCTAssertGreaterThanOrEqual(rect.minX, 44, "Auto stays outside the clipped scrolling region")
        XCTAssertLessThanOrEqual(rect.maxX, 276, "Close stays outside the clipped scrolling region")
        let (w, _, bytes) = try raster(window, name: "camera55-compact-wb-fixed-actions")
        var spill = 0
        for y in Array(0..<27) + Array(73..<100) { for x in 0..<w {
            let offset = (y * w + x) * 4
            if max(bytes[offset], max(bytes[offset + 1], bytes[offset + 2])) > 80 { spill += 1 }
        } }
        XCTAssertEqual(spill, 0, "Only the clipped 44pt viewport and fixed actions may paint")
        for range in [0..<44, 276..<320] {
            var count = 0
            for y in 28..<72 { for x in range {
                let offset = (y * w + x) * 4
                if bytes[offset] > 120 && bytes[offset + 1] > 120 { count += 1 }
            } }
            XCTAssertGreaterThan(count, 15, "The actual Auto/close glyph remains visible in the 44pt well")
        }
        await camera.stop()
    }

    @MainActor func testShippingPortraitShutterStaysBelowTheFrameAndFixedAcrossParameterChanges() async throws {
        let fixture = await StorageHarness.make(name: "native55-fixed-shutter"), h = try XCTUnwrap(fixture)
        for size in [CGSize(width: 320, height: 548), CGSize(width: 402, height: 778), CGSize(width: 440, height: 860)] {
            let (camera, _) = await CaptureFormatUISuite.makeModel(h: h, capability: CaptureFormatUISuite.capability())
            let app = AppEnvironment(); app.attach(store: h.store, index: InMemoryLibraryIndex()); app.attach(camera: camera)
            camera.setCaptureSpeed(.fps5)
            let window = try await host(CameraScreen().environment(app).preferredColorScheme(.dark), size: size)
            let root = try XCTUnwrap(window.rootViewController?.view)
            let surface = try XCTUnwrap(descendants(ContinuousShutterTouchView.self, in: root).first)
            let before = surface.convert(surface.bounds, to: root)
            let plan = CameraScreenLayout(size: size, bottomSafeArea: 0, accessibility: false)
            XCTAssertEqual(before.midX, size.width / 2, accuracy: 0.5)
            XCTAssertGreaterThan(before.minY, plan.preview.maxY + 56, "The full readouts and adjustment gap are below the uncropped image")
            XCTAssertLessThanOrEqual(before.maxY, size.height - 20 + 0.5, "Shutter clears feedback and safe content bottom")
            XCTAssertGreaterThanOrEqual(before.width, 75.5); XCTAssertGreaterThanOrEqual(before.height, 75.5)
            for panel: CameraPanel? in [.shutter, .whiteBalance, nil] {
                camera.openPanel = panel
                window.layoutIfNeeded(); try await Task.sleep(for: .milliseconds(220))
                let after = surface.convert(surface.bounds, to: root)
                XCTAssertEqual(after, before, "Selecting/collapsing a parameter cannot move the shutter")
            }
            _ = try raster(window, name: "camera55-fixed-controls-\(Int(size.width))")
            window.isHidden = true; window.rootViewController = nil
            await camera.stop()
        }
    }

    @MainActor func testFrontCameraHasNoEmptyLensCapsuleOrDot() async throws {
        let fixture = await StorageHarness.make(name: "native55-empty-lenses"), h = try XCTUnwrap(fixture)
        let (camera, _) = await CaptureFormatUISuite.makeModel(h: h, capability: CaptureFormatUISuite.capability(kind: .front))
        let app = AppEnvironment(); app.attach(camera: camera)
        XCTAssertTrue(camera.lensButtons.isEmpty)
        let window = try await host(PhysicalLensSelector().environment(app)
            .frame(maxWidth: .infinity, maxHeight: .infinity).background(.cyan), size: CGSize(width: 88, height: 88))
        defer { window.isHidden = true; window.rootViewController = nil }
        let (_, _, bytes) = try raster(window, name: "camera55-front-no-dot")
        // The old four-point black capsule darkened this exact center patch.
        for y in 40..<48 { for x in 40..<48 {
            let i = (y * 88 + x) * 4
            XCTAssertGreaterThan(bytes[i + 1], 200); XCTAssertGreaterThan(bytes[i + 2], 200)
        } }
        await camera.stop()
    }
}
#endif
