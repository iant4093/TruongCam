#if canImport(UIKit) && canImport(XCTest) && !TC_TESTKIT_STANDALONE
import CoreGraphics
import SwiftUI
import UIKit
import XCTest
@testable import TruongCam

/// Renders the actual shipping level, so a stale horizon line or unavailable
/// text cannot pass solely because the pure motion state has a new field.
final class FlatLevelNativeTests: XCTestCase {
    @MainActor private func raster(_ state: LevelState, maximumGuideWidth: CGFloat? = nil,
                                   name: String) throws -> (markWidth: Int, greenPixels: Int) {
        let renderer = ImageRenderer(content: LevelOverlay(state: state, maximumGuideWidth: maximumGuideWidth)
            .frame(width: 260, height: 200).background(.black).preferredColorScheme(.dark))
        renderer.scale = 1
        let rendered = try XCTUnwrap(renderer.uiImage), image = try XCTUnwrap(rendered.cgImage)
        let attachment = XCTAttachment(image: rendered)
        attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
        let width = image.width, height = image.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let drew = pixels.withUnsafeMutableBytes { data -> Bool in
            guard let context = CGContext(data: data.baseAddress, width: width, height: height, bitsPerComponent: 8,
                bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        XCTAssertTrue(drew)
        var left = width, right = -1, green = 0
        for y in 0..<height {
            for x in 0..<width {
                let i = (y * width + x) * 4
                if max(pixels[i], max(pixels[i + 1], pixels[i + 2])) > 40 {
                    left = min(left, x); right = max(right, x)
                }
                if Int(pixels[i + 1]) > Int(pixels[i]) + 40 && Int(pixels[i + 1]) > Int(pixels[i + 2]) + 20 {
                    green += 1
                }
            }
        }
        return (max(0, right - left + 1), green)
    }

    @MainActor func testHealthyFlatPhoneRendersSurfaceTargetInsteadOfUnavailableTextOrUndefinedHorizon() throws {
        let angled = LevelSurfaceTilt(rightDegrees: 11, upDegrees: -8, deviationDegrees: 13.6)
        let bounded = LevelOverlay.surfaceOffset(for: angled, maximumTravel: 7)
        XCTAssertEqual(hypot(bounded.width, bounded.height), 7, accuracy: 0.0001)
        XCTAssertEqual(bounded.width / bounded.height, 11.0 / 8.0, accuracy: 0.0001,
            "Compact display travel must preserve the real tilt direction")
        XCTAssertEqual(LevelOverlay.surfaceOffset(for: angled, maximumTravel: -1), .zero)
        XCTAssertEqual(LevelOverlay.surfaceOffset(for: angled, maximumTravel: .nan), .zero)
        let ordinary = LevelOverlay.surfaceOffset(for: angled, maximumTravel: nil)
        XCTAssertEqual(ordinary.width, 17.6, accuracy: 0.0001)
        XCTAssertEqual(ordinary.height, 12.8, accuracy: 0.0001)
        for orientation in [DeviceOrientation.portrait, .landscapeLeft, .landscapeRight] {
            var service = LevelService(orientation: orientation, gain: 1)
            let flat = service.update(gravity: GravityReading(x: 0, y: 0, z: -1))
            let target = try raster(flat, maximumGuideWidth: 32, name: "flat-level53-\(orientation.rawValue)")
            XCTAssertTrue((40...48).contains(target.markWidth), "A compact surface target replaces the unavailable text")
            XCTAssertGreaterThan(target.greenPixels, 20, "A genuinely horizontal surface is visibly level")
            let axes = orientation.screenAxes
            let upright = service.update(gravity: GravityReading(x: -axes.up.x, y: -axes.up.y, z: 0))
            let guide = try raster(upright, name: "horizon-level53-\(orientation.rawValue)")
            XCTAssertGreaterThan(guide.markWidth, 120, "Upright reading retains the real horizon guide")
            let compact = try raster(upright, maximumGuideWidth: 48, name: "compact-horizon53-\(orientation.rawValue)")
            XCTAssertLessThanOrEqual(compact.markWidth, 50, "Compact aids can reserve neighboring loupe space")
        }
        var unavailable = LevelService()
        let missing = unavailable.update(gravity: GravityReading(x: 0, y: 0, z: 0))
        let warning = try raster(missing, name: "missing-level53")
        XCTAssertEqual(warning.greenPixels, 0, "Missing motion must not draw a false level success")
        XCTAssertGreaterThan(warning.markWidth, 60, "Actual unavailable motion retains its visible explanation")
    }
}
#endif
