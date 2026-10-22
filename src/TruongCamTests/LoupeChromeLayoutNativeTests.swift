#if canImport(UIKit) && canImport(XCTest) && !TC_TESTKIT_STANDALONE
import CoreGraphics
import SwiftUI
import UIKit
import XCTest
@testable import TruongCam

/// Hosts the shipping camera screen, including its separate native-preview and
/// interactive-chrome coordinate spaces. Geometry-only assertions also exercise
/// compact frames, where a right-edge meter cannot sit beside the focus loupe.
final class LoupeChromeLayoutNativeTests: XCTestCase {
    func testLoupeAndMeterClearTheWholeHeaderHistogramLevelAndLensPicker() {
        for width in [165.0, 193.25, 208.25, 292, 347, 550] {
            let bounds = CGRect(x: 13, y: 14, width: width, height: 44)
            for leading in [0.0, 44, 200] {
                for center in [44.0, 106, 180] {
                    for trailing in [44.0, 124] {
                        let frames = CameraHeaderLayout.frames(in: bounds,
                            leading: CGSize(width: leading, height: 44),
                            center: CGSize(width: center, height: 44),
                            trailing: CGSize(width: trailing, height: 44))
                        XCTAssertTrue(bounds.contains(frames.center))
                        XCTAssertTrue(bounds.contains(frames.trailing))
                        XCTAssertGreaterThanOrEqual(frames.center.width, 44)
                        XCTAssertGreaterThanOrEqual(frames.trailing.width, 44)
                        XCTAssertFalse(frames.center.intersects(frames.trailing), "EV and format retain separate targets")
                        if leading > 0 {
                            XCTAssertTrue(bounds.contains(frames.leading))
                            XCTAssertGreaterThanOrEqual(frames.leading.width, 44)
                            XCTAssertFalse(frames.leading.intersects(frames.center), "Pending recovery keeps its own target")
                        }
                        if leading == 0, width >= center + trailing * 2 + 16 {
                            XCTAssertEqual(frames.center.midX, bounds.midX, accuracy: 0.001)
                        }
                    }
                }
            }
        }
        let sizes: [CGSize] = [
            CGSize(width: 375, height: 500), CGSize(width: 402, height: 536),
            CGSize(width: 440, height: 586.67), CGSize(width: 422, height: 316.5),
            CGSize(width: 536, height: 402), CGSize(width: 400, height: 300),
            CGSize(width: 320, height: 426.67), CGSize(width: 221.25, height: 295),
            CGSize(width: 236.25, height: 315)]
        for size in sizes {
            let layout = CameraPreviewChromeLayout(size: size, hasLoupe: true, hasHistogram: true)
            let bounds = CGRect(origin: .zero, size: size)
            let header = CGRect(x: 0, y: 0, width: size.width, height: 58)
            let lenses = CGRect(x: size.width / 2 - 77, y: size.height - 58, width: 154, height: 48)
            XCTAssertTrue(bounds.contains(layout.loupe), "Loupe stays inside \(size)")
            XCTAssertTrue(bounds.contains(layout.meter), "Meter stays inside \(size)")
            XCTAssertFalse(header.intersects(layout.loupe), "Reserve the complete header's touch region")
            XCTAssertTrue(header.contains(layout.histogram), "Histogram returns to the leading header band")
            XCTAssertEqual(layout.histogram.minY, 8, accuracy: 0.001)
            XCTAssertEqual(layout.histogram.height, 50, accuracy: 0.001)
            XCTAssertGreaterThanOrEqual(layout.histogram.width, 75)
            XCTAssertLessThanOrEqual(layout.histogram.width, 120)
            let reserved = layout.histogram.maxX - CameraPreviewChromeLayout.headerInset
            let headerBounds = CGRect(x: 14, y: 14, width: size.width - 28, height: 44)
            let controls = CameraHeaderLayout.frames(in: headerBounds,
                leading: CGSize(width: reserved, height: 44), center: CGSize(width: 106, height: 44),
                trailing: CGSize(width: 44, height: 44), leadingMinimumWidth: reserved, centerMinimumWidth: 64)
            XCTAssertGreaterThanOrEqual(controls.center.minX - layout.histogram.maxX, 8)
            XCTAssertFalse(controls.center.intersects(layout.histogram))
            XCTAssertFalse(controls.trailing.intersects(layout.histogram))
            XCTAssertGreaterThanOrEqual(controls.center.width, 64)
            XCTAssertGreaterThanOrEqual(controls.trailing.width, 44)
            XCTAssertFalse(controls.center.intersects(controls.trailing))
            XCTAssertFalse(layout.histogram.intersects(layout.loupe))
            XCTAssertFalse(layout.histogram.intersects(layout.meter))
            XCTAssertFalse(layout.meter.intersects(layout.loupe))
            XCTAssertFalse(lenses.intersects(layout.loupe))
            XCTAssertFalse(lenses.intersects(layout.meter))
            let center = CGPoint(x: size.width / 2, y: size.height / 2)
            let fixedTarget = CGRect(x: center.x - 22, y: center.y - 22, width: 44, height: 44)
            XCTAssertFalse(layout.loupe.intersects(fixedTarget), "The healthy flat-level target remains visible in compact accessibility frames")
            XCTAssertFalse(layout.histogram.intersects(fixedTarget))
            XCTAssertGreaterThanOrEqual(layout.loupe.width, 64)
            XCTAssertLessThanOrEqual(layout.loupe.width, 128)
            let radius = min(min(size.width * 0.25, 90), (layout.maximumLevelGuideWidth ?? 180) / 2)
            for angle in stride(from: 0.0, to: 360.0, by: 5) {
                let radians = angle * .pi / 180
                let endpoint = CGPoint(x: center.x + CGFloat(cos(radians)) * radius,
                    y: center.y + CGFloat(sin(radians)) * radius)
                XCTAssertFalse(layout.loupe.insetBy(dx: -7, dy: -7).contains(endpoint),
                    "Actual rotated horizon guide clears the loupe at \(angle) degrees in \(size)")
                XCTAssertFalse(layout.histogram.insetBy(dx: -7, dy: -7).contains(endpoint),
                    "Actual rotated horizon guide clears the histogram at \(angle) degrees in \(size)")
                let tilt = LevelSurfaceTilt(rightDegrees: cos(radians) * 15, upDegrees: -sin(radians) * 15,
                    deviationDegrees: 15)
                let offset = LevelOverlay.surfaceOffset(for: tilt, maximumTravel: layout.maximumSurfaceTravel)
                let bubbleCenter = CGPoint(x: center.x + offset.width, y: center.y + offset.height)
                let bubble = CGRect(x: bubbleCenter.x - 11, y: bubbleCenter.y - 11, width: 22, height: 22)
                XCTAssertFalse(layout.loupe.intersects(bubble), "Flat bubble also clears the loupe at \(angle) degrees in \(size)")
                XCTAssertFalse(layout.histogram.intersects(bubble), "Flat bubble clears histogram at \(angle) degrees in \(size)")
            }
            let noLoupe = CameraPreviewChromeLayout(size: size, hasLoupe: false)
            XCTAssertEqual(noLoupe.meter.maxX, size.width - 8, accuracy: 0.001)
            XCTAssertEqual(noLoupe.meter.midY, size.height / 2, accuracy: 0.001)
            XCTAssertNil(noLoupe.maximumLevelGuideWidth)
            XCTAssertNil(noLoupe.maximumSurfaceTravel)
            let histogramOnly = CameraPreviewChromeLayout(size: size, hasLoupe: false, hasHistogram: true)
            XCTAssertNotNil(histogramOnly.maximumLevelGuideWidth)
            XCTAssertNotNil(histogramOnly.maximumSurfaceTravel)
        }
    }

    @MainActor private func scene() async throws -> UIWindowScene {
        for _ in 0..<300 {
            if let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first { return scene }
            try await Task.sleep(for: .milliseconds(5))
        }
        return try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
    }

    @MainActor private func raster(_ window: UIWindow, name: String, onlyWhenLoupeVisible: Bool = false) throws -> (Int, Int, [UInt8]) {
        let format = UIGraphicsImageRendererFormat(); format.scale = 1; format.opaque = true
        let image = UIGraphicsImageRenderer(bounds: window.bounds, format: format).image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        let bitmap = try XCTUnwrap(image.cgImage), width = bitmap.width, height = bitmap.height
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        let drew = bytes.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue) else { return false }
            context.draw(bitmap, in: CGRect(x: 0, y: 0, width: width, height: height)); return true
        }
        XCTAssertTrue(drew)
        if !onlyWhenLoupeVisible || redPixelCount(bytes) > 2_000 {
            let attachment = XCTAttachment(image: image); attachment.name = name
            attachment.lifetime = .keepAlways; add(attachment)
        }
        return (width, height, bytes)
    }

    private func redPixelCount(_ pixels: [UInt8]) -> Int {
        stride(from: 0, to: pixels.count, by: 4).reduce(into: 0) { count, i in
            let r = Int(pixels[i]), g = Int(pixels[i + 1]), b = Int(pixels[i + 2])
            if r > 100 && r > g + 80 && r > b + 80 { count += 1 }
        }
    }

    @MainActor func testShippingCameraScreenKeepsColorLoupeBelowFormatInPortraitBothLandscapesAndLargeText() async throws {
        let fixture = await StorageHarness.make(name: "loupe54-chrome"), h = try XCTUnwrap(fixture)
        let window = UIWindow(windowScene: try await scene())
        defer { window.isHidden = true; window.rootViewController = nil }
        // The very wide frame exposes a former mismatch: top-row chrome was
        // attached to the entire left area rather than its centered 4:3 image.
        let cases: [(CGSize, DynamicTypeSize, DeviceOrientation)] = [
            (CGSize(width: 375, height: 812), .large, .portrait),
            (CGSize(width: 320, height: 548), .large, .portrait),
            (CGSize(width: 440, height: 860), .large, .portrait),
            (CGSize(width: 874, height: 402), .large, .landscapeLeft),
            (CGSize(width: 874, height: 402), .large, .landscapeRight),
            (CGSize(width: 936, height: 300), .large, .landscapeLeft),
            (CGSize(width: 402, height: 874), .accessibility2, .portrait),
            (CGSize(width: 375, height: 647), .accessibility2, .portrait)]
        for (index, item) in cases.enumerated() {
            let (size, type, orientation) = item
            let service = SyntheticCameraService(capability: CaptureFormatUISuite.capability())
            let camera = CameraViewModel(camera: service,
                capture: CaptureCoordinator(camera: ChainCameraSpy(), store: h.store, clock: SystemMonotonicClock()),
                metering: MeteringService(clock: SystemMonotonicClock()), preferences: SyntheticPreferenceStore(), levelFeed: SyntheticLevelFeed())
            let app = AppEnvironment(); app.attach(camera: camera); app.graphState = .ready
            await camera.start()
            camera.composition.histogramEnabled = true; camera.composition.loupeEnabled = true
            camera.composition.levelEnabled = true; camera.composition.gridMode = .off
            window.frame = CGRect(origin: .zero, size: size)
            window.rootViewController = UIHostingController(rootView: CameraScreen().environment(app)
                .environment(\.dynamicTypeSize, type).preferredColorScheme(.dark).ignoresSafeArea())
            window.makeKeyAndVisible(); window.layoutIfNeeded()
            try await Task.sleep(for: .milliseconds(120))
            let screen = CameraScreenLayout(size: size, bottomSafeArea: 0, accessibility: type.isAccessibilitySize)
            let width = screen.preview.width, height = screen.preview.height, origin = screen.preview.origin
            let geometry = PreviewGeometrySnapshot(configurationGeneration: camera.capability.generation,
                layoutGeneration: UInt64(index + 1), imageDimensions: PixelDimensions(width: 4, height: 3),
                cleanApertureDimensions: nil, previewLayerContentRect: TCRect(x: 0, y: 0, width: Double(width), height: Double(height)),
                bufferOrientation: 1, isMirrored: false, analysisRotationDegrees: 0, isVideoMirrored: false,
                capturedAtUTC: Date(), interfaceOrientation: orientation)
            camera.updateGeometry(geometry)
            await camera.consumeAnalysisOutput(.histogram(HistogramSnapshot(bins: Array(repeating: 1, count: 256),
                sampleCount: 256, geometryGeneration: geometry.layoutGeneration,
                configurationGeneration: geometry.configurationGeneration, isFullRange: true, mappedAtUTC: Date())))
            XCTAssertEqual(camera.histogram?.geometryGeneration, geometry.layoutGeneration)
            // This is a layout test, not a 45 ms cold-decoder benchmark.
            // Feed fresh frames as the camera does, and retain the first actual
            // rendered frame. Staleness policy and geometry assertions remain.
            let rgba: [UInt8] = Array(repeating: [UInt8(250), 0, 0, 255], count: 32 * 24).flatMap { $0 }
            let deadline = ContinuousClock.now.advanced(by: .seconds(3))
            var rendered: (Int, Int, [UInt8])?
            repeat {
                let sample = LoupeSnapshot(width: 32, height: 24, rgbaBytes: rgba,
                    geometryGeneration: geometry.layoutGeneration, configurationGeneration: geometry.configurationGeneration,
                    magnification: 2, mappedAtUTC: Date())
                await camera.consumeAnalysisOutput(.loupe(sample))
                try await Task.sleep(for: .milliseconds(30))
                let candidate = try raster(window, name: "histogram54-shipping-camera-\(index)", onlyWhenLoupeVisible: true)
                if redPixelCount(candidate.2) > 2_000 { rendered = candidate; break }
            } while ContinuousClock.now < deadline
            let (pixelWidth, pixelHeight, pixels) = try rendered ?? raster(window, name: "histogram54-shipping-camera-\(index)-not-ready")
            let caseLabel = "case \(index), \(size), \(type), \(orientation)"
            let expected = CameraPreviewChromeLayout(size: CGSize(width: width, height: height), hasLoupe: true, hasHistogram: true)
            let loupe = expected.loupe.offsetBy(dx: origin.x, dy: origin.y)
            let histogramRect = expected.histogram.offsetBy(dx: origin.x, dy: origin.y)
            // Exclude the caption and rounded border. The luma Canvas is 60%
            // white on black (about153), so >170 misses a correctly drawn fill.
            let histogramChartBody = CGRect(x: histogramRect.minX + 7, y: histogramRect.minY + 22,
                width: histogramRect.width - 14, height: histogramRect.height - 29)
            let meterRect = expected.meter.offsetBy(dx: origin.x, dy: origin.y)
            // Sample only RAW's own label, never the adjacent EV tail. Its
            // fixed-font 44-point menu remains trailing in every layout.
            let formatRect = CGRect(x: origin.x + width - 14 - 44 + 7,
                y: origin.y + 24, width: 30, height: 24)
            var red = 0, headerWhite = 0, histogramGrayFill = 0
            var redBounds = CGRect.null
            for y in 0..<pixelHeight {
                for x in 0..<pixelWidth {
                    let offset = (y * pixelWidth + x) * 4
                    let r = Int(pixels[offset]), g = Int(pixels[offset + 1]), b = Int(pixels[offset + 2])
                    if r > 100 && r > g + 80 && r > b + 80 {
                        red += 1; redBounds = redBounds.union(CGRect(x: x, y: y, width: 1, height: 1))
                    }
                    let point = CGPoint(x: x, y: y)
                    if histogramChartBody.contains(point), r >= 90, r <= 190,
                       abs(r - g) <= 3, abs(g - b) <= 3 { histogramGrayFill += 1 }
                    if r > 170 && g > 170 && b > 170 {
                        if formatRect.contains(point) { headerWhite += 1 }
                    }
                }
            }
            XCTAssertGreaterThan(red, 2_000, "Actual shipping loupe renders: \(caseLabel)")
            XCTAssertTrue(loupe.insetBy(dx: -1, dy: -1).contains(redBounds), "Color pixels stay in the owned loupe rectangle, \(redBounds) vs \(loupe): \(caseLabel)")
            XCTAssertGreaterThan(redBounds.minY, origin.y + 58, "Loupe cannot paint inside format/EV touch targets: \(caseLabel)")
            XCTAssertGreaterThan(headerWhite, 15, "Format menu belongs to actual 4:3 frame including letterbox gutters: \(caseLabel)")
            XCTAssertGreaterThan(histogramGrayFill, 100, "Real luma Canvas fill stays rendered with loupe visible: \(caseLabel)")
            // Fractional compact positions split a thin tick between rows, so
            // testing only almost-white pixels misses real antialiased marks.
            // Require each of the seven full-stop marks at its actual position.
            for third in stride(from: -9, through: 9, by: 3) {
                let tickY = meterRect.minY + 8 + CGFloat(9 - third) / 18 * (meterRect.height - 16)
                var tickPixels = 0
                for y in (Int(floor(tickY)) - 1)...(Int(ceil(tickY)) + 1) where y >= 0 && y < pixelHeight {
                    for x in Int(floor(meterRect.minX + 3))..<Int(ceil(meterRect.minX + 13)) where x >= 0 && x < pixelWidth {
                        let offset = (y * pixelWidth + x) * 4
                        let r = Int(pixels[offset]), g = Int(pixels[offset + 1]), b = Int(pixels[offset + 2])
                        if min(r, min(g, b)) > 70, abs(r - g) <= 3, abs(g - b) <= 3 { tickPixels += 1 }
                    }
                }
                XCTAssertGreaterThanOrEqual(tickPixels, 4, "Full-stop \(third) stays rendered: \(caseLabel)")
            }
            window.rootViewController = nil
            await camera.stop()
        }
    }

    @MainActor func testPendingRecoveryAndTimerRetainSeparateActualHeaderControlsAtLargeText() async throws {
        let fixture = await StorageHarness.make(name: "header54-pending-timer"), h = try XCTUnwrap(fixture)
        let service = SyntheticCameraService(capability: CaptureFormatUISuite.capability())
        let camera = CameraViewModel(camera: service,
            capture: CaptureCoordinator(camera: ChainCameraSpy(), store: h.store, clock: SystemMonotonicClock()),
            metering: MeteringService(clock: SystemMonotonicClock()), preferences: SyntheticPreferenceStore(), levelFeed: SyntheticLevelFeed())
        let app = AppEnvironment(); app.attach(camera: camera); app.graphState = .ready
        await camera.start()
        let geometry = PreviewGeometrySnapshot(configurationGeneration: camera.capability.generation,
            layoutGeneration: 54, imageDimensions: PixelDimensions(width: 4, height: 3),
            cleanApertureDimensions: nil, previewLayerContentRect: TCRect(x: 0, y: 0, width: 375, height: 500),
            bufferOrientation: 1, isMirrored: false, analysisRotationDegrees: 0, isVideoMirrored: false,
            capturedAtUTC: Date(), interfaceOrientation: .portrait)
        camera.composition.histogramEnabled = true
        camera.updateGeometry(geometry)
        await camera.consumeAnalysisOutput(.histogram(HistogramSnapshot(bins: Array(repeating: 1, count: 256),
            sampleCount: 256, geometryGeneration: geometry.layoutGeneration,
            configurationGeneration: geometry.configurationGeneration, isFullRange: true, mappedAtUTC: Date())))
        XCTAssertTrue(CameraPreviewChromeLayout.showsHistogram(camera: camera, inWidth: 221.25))
        camera.setTimerSeconds(30)
        camera.updatePendingOriginalCount(1)
        XCTAssertFalse(CameraPreviewChromeLayout.showsHistogram(camera: camera, inWidth: 221.25),
            "Pending recovery temporarily takes the shared leading header lane")
        XCTAssertTrue(camera.composition.histogramEnabled, "Header priority never changes the user's preference")
        let window = UIWindow(windowScene: try await scene())
        defer { window.isHidden = true; window.rootViewController = nil }
        window.frame = CGRect(x: 0, y: 0, width: 375, height: 647)
        for width in [193.25, 347.0] {
            window.rootViewController = UIHostingController(rootView: CameraTopRow()
                .frame(width: width, height: 44)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .background(.black).environment(app).environment(\.dynamicTypeSize, .accessibility2)
                .preferredColorScheme(.dark).ignoresSafeArea())
            window.makeKeyAndVisible(); window.layoutIfNeeded()
            try await Task.sleep(for: .milliseconds(90))
            let (pixelWidth, pixelHeight, pixels) = try raster(window, name: "header54-pending-timer-\(width)")
            let recoveryRegion = CGRect(x: 0, y: 0, width: 110, height: 44)
            let formatLabel = CGRect(x: width - 37, y: 10, width: 30, height: 24)
            let trailingRegion = CGRect(x: width - 44, y: 0, width: 44, height: 44)
            var recoveryYellow = 0, formatWhite = 0, trailingYellow = 0
            for y in 0..<min(44, pixelHeight) {
                for x in 0..<min(Int(ceil(width)), pixelWidth) {
                    let i = (y * pixelWidth + x) * 4
                    let r = Int(pixels[i]), g = Int(pixels[i + 1]), b = Int(pixels[i + 2])
                    let point = CGPoint(x: x, y: y)
                    let yellow = r > 150 && g > 90 && b < 90
                    if recoveryRegion.contains(point), yellow { recoveryYellow += 1 }
                    if trailingRegion.contains(point), yellow { trailingYellow += 1 }
                    if formatLabel.contains(point), min(r, min(g, b)) > 170 { formatWhite += 1 }
                }
            }
            XCTAssertGreaterThan(recoveryYellow, 5, "Pending recovery stays visible at \(width) points")
            if width < 200 {
                XCTAssertGreaterThan(formatWhite, 15, "RAW remains visible in its own trailing target with pending and timer")
                XCTAssertEqual(trailingYellow, 0, "The noninteractive timer badge yields to real controls when space is tight")
            } else {
                XCTAssertGreaterThan(trailingYellow, 100, "Roomy headers retain the timer badge")
            }
            XCTAssertEqual(camera.pendingOriginalCount, 1)
            XCTAssertEqual(camera.timerSeconds, 30, "Display fallback never changes timer configuration")
        }
        camera.updatePendingOriginalCount(0)
        XCTAssertTrue(CameraPreviewChromeLayout.showsHistogram(camera: camera, inWidth: 221.25),
            "Histogram returns when recovery no longer owns the leading lane")
        await camera.stop()
    }
}
#endif
