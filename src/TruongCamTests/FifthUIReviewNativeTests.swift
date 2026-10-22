#if canImport(UIKit) && canImport(XCTest) && !TC_TESTKIT_STANDALONE
import CoreGraphics
import Observation
import SwiftUI
import UIKit
import XCTest
@testable import TruongCam

/// Only bounded synthetic display pixels are replaced. A stable capture ID and
/// representable are retained exactly as a same-source refresh can retain them.
@MainActor @Observable private final class FifthViewerPixels {
    let captureID = CaptureID()
    var image: CGImage
    var dismissalEnabled = true
    init(image: CGImage) { self.image = image }
}

private struct FifthViewerCanvas: View {
    let pixels: FifthViewerPixels
    var body: some View {
        ZoomableOriginalView(image: pixels.image, toggleChrome: {}, previous: {}, next: {},
            dismissalEnabled: pixels.dismissalEnabled)
            .id(pixels.captureID)
            .ignoresSafeArea()
    }
}

final class FifthUIReviewNativeTests: XCTestCase {
    private static func image(width: Int = 40, height: Int = 30, red: UInt8) throws -> CGImage {
        let pixel: [UInt8] = [red, 12, 23, 255]
        let bytes = (0..<(width * height)).flatMap { _ in pixel }
        return try XCTUnwrap(CGImage.rgbaDisplayImage(bytes: bytes, width: width, height: height))
    }

    @MainActor private static func wait(_ predicate: () -> Bool) async throws {
        for _ in 0..<300 {
            if predicate() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("The hosted viewer canvas did not reach the expected publication/layout")
        throw CocoaError(.featureUnsupported)
    }

    @MainActor private static func scroll(in view: UIView) -> OriginalScrollView? {
        if let scroll = view as? OriginalScrollView { return scroll }
        return view.subviews.compactMap { scroll(in: $0) }.first
    }

    @MainActor private static func host(_ pixels: FifthViewerPixels) async throws -> (UIWindow, OriginalScrollView) {
        try await wait { UIApplication.shared.connectedScenes.contains(where: { $0 is UIWindowScene }) }
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 402, height: 874)
        window.rootViewController = UIHostingController(rootView: FifthViewerCanvas(pixels: pixels))
        window.makeKeyAndVisible()
        try await wait { scroll(in: window).map { $0.bounds.width > 0 && $0.minimumZoomScale > 0.0001 } == true }
        return (window, try XCTUnwrap(scroll(in: window)))
    }

    @MainActor func testSameCaptureRefreshReplacesActualCanvasPixelsWithoutRecreatingOrResettingZoom() async throws {
        let first = try Self.image(red: 15), replacement = try Self.image(red: 230)
        let pixels = FifthViewerPixels(image: first)
        let (window, canvas) = try await Self.host(pixels)
        defer { window.isHidden = true; window.rootViewController = nil }
        XCTAssertTrue(canvas.imageView.image?.cgImage === first)
        canvas.setZoomScale(canvas.minimumZoomScale * 2, animated: false)
        let zoom = canvas.zoomScale, imageView = canvas.imageView

        pixels.image = replacement
        try await Self.wait { canvas.imageView.image?.cgImage === replacement }

        XCTAssertTrue(Self.scroll(in: window) === canvas, "A source refresh must update the existing viewer canvas")
        XCTAssertTrue(canvas.imageView === imageView)
        XCTAssertEqual(canvas.zoomScale, zoom, accuracy: 0.0001, "Equal-size pixel replacement keeps the user's zoom")
        XCTAssertEqual(canvas.subviews.filter { $0 === imageView }.count, 1)
        XCTAssertEqual(canvas.imageView.accessibilityLabel, "Photo preview")
    }

    @MainActor func testChangedBitmapDimensionsRefitAtUnchangedViewportInsteadOfUsingPreviousContentGeometry() async throws {
        let pixels = FifthViewerPixels(image: try Self.image(red: 35))
        let (window, canvas) = try await Self.host(pixels)
        defer { window.isHidden = true; window.rootViewController = nil }
        canvas.setZoomScale(canvas.minimumZoomScale * 2.5, animated: false)
        let oldBounds = canvas.bounds.size
        let replacement = try Self.image(width: 20, height: 60, red: 210)

        pixels.image = replacement
        try await Self.wait {
            canvas.layoutIfNeeded()
            return canvas.imageView.image?.cgImage === replacement && canvas.isAtFitSize
                && abs(canvas.minimumZoomScale - min(canvas.bounds.width / 20, canvas.bounds.height / 60)) < 0.0001
        }

        XCTAssertTrue(Self.scroll(in: window) === canvas)
        XCTAssertEqual(canvas.bounds.size, oldBounds, "The test changes pixels, not device orientation or viewport")
        XCTAssertEqual(canvas.zoomScale, canvas.minimumZoomScale, accuracy: 0.0001)
        XCTAssertEqual(canvas.contentSize.width, 20 * canvas.minimumZoomScale, accuracy: 0.01)
        XCTAssertEqual(canvas.contentSize.height, 60 * canvas.minimumZoomScale, accuracy: 0.01)
        XCTAssertEqual(canvas.maximumZoomScale, 4 * canvas.minimumZoomScale, accuracy: 0.0001)
    }

    @MainActor func testUnchangedPixelsAvoidUIImageReplacementAndKeepZoomWhenOnlyGestureEligibilityChanges() async throws {
        let original = try Self.image(red: 55), pixels = FifthViewerPixels(image: original)
        let (window, canvas) = try await Self.host(pixels)
        defer { window.isHidden = true; window.rootViewController = nil }
        canvas.setZoomScale(canvas.minimumZoomScale * 1.75, animated: false)
        let uiImage = try XCTUnwrap(canvas.imageView.image), zoom = canvas.zoomScale
        let coordinator = try XCTUnwrap(canvas.gestureRecognizers?.compactMap {
            $0.delegate as? ZoomableOriginalView.Coordinator
        }.first)

        pixels.dismissalEnabled = false
        try await Self.wait { !coordinator.parent.dismissalEnabled }
        canvas.layoutIfNeeded()

        XCTAssertTrue(Self.scroll(in: window) === canvas)
        XCTAssertTrue(canvas.imageView.image === uiImage, "Routine SwiftUI updates must not allocate another UIImage wrapper")
        XCTAssertTrue(canvas.imageView.image?.cgImage === original)
        XCTAssertEqual(canvas.zoomScale, zoom, accuracy: 0.0001)
        XCTAssertEqual(canvas.imageView.accessibilityLabel, "Photo preview")
    }
}
#endif
