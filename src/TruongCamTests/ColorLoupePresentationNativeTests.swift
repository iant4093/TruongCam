#if canImport(UIKit) && canImport(XCTest) && !TC_TESTKIT_STANDALONE
import CoreGraphics
import SwiftUI
import Synchronization
import UIKit
import XCTest
@testable import TruongCam

private actor ColorLoupe52RenderGate {
    private var samples: [LoupeSnapshot] = []
    private var completions: [Int: CheckedContinuation<PreparedPreviewLoupe?, Never>] = [:]
    var count: Int { samples.count }
    func render(_ sample: LoupeSnapshot) async -> PreparedPreviewLoupe? {
        let index = samples.count
        samples.append(sample)
        return await withCheckedContinuation { completions[index] = $0 }
    }
    func release(_ index: Int) {
        guard let completion = completions.removeValue(forKey: index) else { return }
        let sample = samples[index]
        guard let image = sample.makeImage() else { completion.resume(returning: nil); return }
        completion.resume(returning: PreparedPreviewLoupe(image: image, capturedAt: sample.mappedAtUTC,
            configuration: sample.configurationGeneration, layout: sample.geometryGeneration,
            magnification: sample.magnification, sampledCenter: sample.sampledCenter))
    }
}

@MainActor @Observable private final class ColorLoupe52VisibleState {
    var sample: LoupeSnapshot
    init(sample: LoupeSnapshot) { self.sample = sample }
}
private struct ColorLoupe52VisibleProbe: View {
    let state: ColorLoupe52VisibleState
    var body: some View {
        LoupeOverlay(snapshot: state.sample, label: "2× Preview")
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(.black).ignoresSafeArea()
    }
}

/// Uses the shipping bitmap worker and shipping SwiftUI overlay. The high-detail
/// source has three independently colored bands and small real pixel features,
/// so a luma conversion, old 256-pixel guard or dropped channel fails visibly.
final class ColorLoupePresentationNativeTests: XCTestCase {
    private func sample(layout: UInt64 = 1, magnification: Double = 2, date: Date = Date(),
                        center: NormalizedDevicePoint = .center) -> LoupeSnapshot {
        let width = LoupeRenderer.maxColorOutputLongEdge, height = width * 3 / 4
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let offset = (y * width + x) * 4
                let channel = min(2, x * 3 / width)
                // Eight-pixel checks remain resolvable in the actual 112-point
                // window, unlike a low-resolution grayscale magnification.
                let bright: UInt8 = ((x / 8 + y / 8) % 2 == 0) ? 245 : 150
                bytes[offset + channel] = bright
                bytes[offset + 3] = 255
            }
        }
        return LoupeSnapshot(width: width, height: height, rgbaBytes: bytes,
            geometryGeneration: layout, configurationGeneration: ConfigurationGeneration(52),
            magnification: magnification, mappedAtUTC: date, sampledCenter: center)
    }

    @MainActor private func wait(_ condition: () async -> Bool) async throws {
        for _ in 0..<200 {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("The current color loupe did not publish")
        throw CocoaError(.featureUnsupported)
    }

    @MainActor func testHighDetailColorImageRendersOffMainAndOnlyCurrentOwnedLayoutPublishes() async throws {
        let input = sample(), threads = Mutex<[Bool]>([])
        let renderer = PreviewMaskImageRenderer(makeLoupeImage: { sample in
            threads.withLock { $0.append(Thread.isMainThread) }
            return sample.makeImage()
        })
        let result = await renderer.render(input)
        let prepared = try XCTUnwrap(result)
        XCTAssertEqual(threads.withLock { $0 }, [false], "Bitmap creation must remain off MainActor")
        XCTAssertEqual(prepared.image.width, input.width)
        XCTAssertGreaterThan(prepared.image.width, 256, "The display path must accept the higher-detail native crop")
        XCTAssertTrue(prepared.image.shouldInterpolate)
        let data = try XCTUnwrap(prepared.image.dataProvider?.data)
        XCTAssertEqual(Data(data as Data), Data(input.rgbaBytes), "Native RGBA detail and color reach presentation intact")

        let clock = Date(), gate = ColorLoupe52RenderGate()
        let presentation = PreviewLoupePresentation(render: { await gate.render($0) }, now: { clock })
        presentation.submit(sample(layout: 1, date: clock))
        try await wait { await gate.count == 1 }
        presentation.submit(sample(layout: 2, date: clock))
        let newest = sample(layout: 3, magnification: 4, date: clock)
        presentation.submit(newest)
        await gate.release(0)
        try await wait { await gate.count == 2 }
        XCTAssertNil(presentation.prepared, "Old geometry cannot paint a high-detail crop into a new layout")
        await gate.release(1)
        try await wait { presentation.prepared?.layout == 3 }
        let current = try XCTUnwrap(presentation.prepared)
        XCTAssertEqual(current.configuration, newest.configurationGeneration)
        XCTAssertEqual(current.magnification, 4)
        let currentData = try XCTUnwrap(current.image.dataProvider?.data)
        XCTAssertEqual(currentData as Data, Data(newest.rgbaBytes), "Latest color bytes stay paired with their owned geometry")
        let firstCenter = NormalizedDevicePoint(x: 0.2, y: 0.3)
        let lastCenter = NormalizedDevicePoint(x: 0.8, y: 0.6)
        presentation.submit(sample(layout: 3, magnification: 4, date: clock, center: firstCenter))
        try await wait { await gate.count == 3 }
        presentation.submit(sample(layout: 3, magnification: 4, date: clock, center: lastCenter))
        await gate.release(2)
        try await wait { await gate.count == 4 }
        XCTAssertEqual(presentation.prepared?.sampledCenter, .center, "Same-layout old point cannot publish while the latest point waits")
        await gate.release(3)
        try await wait { presentation.prepared?.sampledCenter == lastCenter }
        presentation.invalidate()
        XCTAssertNil(presentation.prepared)
    }

    @MainActor func testShippingLoupeOverlayDisplaysRedGreenBlueDetailWithinItsUnchangedFootprint() async throws {
        for _ in 0..<300 {
            if UIApplication.shared.connectedScenes.contains(where: { $0 is UIWindowScene }) { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let state = ColorLoupe52VisibleState(sample: sample())
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 240, height: 200)
        window.rootViewController = UIHostingController(rootView: ColorLoupe52VisibleProbe(state: state).preferredColorScheme(.dark))
        window.makeKeyAndVisible(); window.layoutIfNeeded()
        defer { window.isHidden = true; window.rootViewController = nil }
        try await Task.sleep(for: .milliseconds(100))
        // Refresh after first layout so this tests a live display, not a stale
        // fixture that should correctly fade away after setup.
        state.sample = sample()
        try await Task.sleep(for: .milliseconds(40))
        let format = UIGraphicsImageRendererFormat(); format.scale = 1; format.opaque = true
        let rendered = UIGraphicsImageRenderer(bounds: window.bounds, format: format).image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        let attachment = XCTAttachment(image: rendered)
        attachment.name = "color-loupe52-shipping-overlay"; attachment.lifetime = .keepAlways; add(attachment)
        let image = try XCTUnwrap(rendered.cgImage), width = image.width, height = image.height
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        let drew = bytes.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        XCTAssertTrue(drew)
        var red = 0, green = 0, blue = 0
        var minX = width, maxX = 0, minY = height, maxY = 0
        for y in 0..<height {
            for x in 0..<width {
                let offset = (y * width + x) * 4
                let r = Int(bytes[offset]), g = Int(bytes[offset + 1]), b = Int(bytes[offset + 2])
                let colored = max(r, g, b) > 100 && max(r, g, b) - min(r, g, b) > 80
                if r > 100 && r > g + 80 && r > b + 80 { red += 1 }
                if g > 100 && g > r + 80 && g > b + 80 { green += 1 }
                if b > 100 && b > r + 80 && b > g + 80 { blue += 1 }
                if colored { minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y) }
            }
        }
        XCTAssertGreaterThan(red, 300); XCTAssertGreaterThan(green, 300); XCTAssertGreaterThan(blue, 300)
        XCTAssertGreaterThan(maxX - minX, 100); XCTAssertLessThanOrEqual(maxX - minX, 112)
        XCTAssertGreaterThan(maxY - minY, 85); XCTAssertLessThanOrEqual(maxY - minY, 96)
    }
    @MainActor func testThirtyHzArrivalsKeepOnlyTheNewestPendingImageAndCannotSurviveInvalidation() async throws {
        let clock = Date(), gate = ColorLoupe52RenderGate()
        let presentation = PreviewLoupePresentation(render: { await gate.render($0) }, now: { clock })
        presentation.submit(sample(date: clock.addingTimeInterval(-0.4)))
        try await wait { await gate.count == 1 }
        for index in 1...12 {
            presentation.submit(sample(date: clock.addingTimeInterval(Double(index - 12) / 30)))
        }
        let busyCount = await gate.count
        XCTAssertEqual(busyCount, 1, "Thirty-Hz delivery cannot create a render backlog")
        await gate.release(0)
        try await wait { await gate.count == 2 }
        XCTAssertNil(presentation.prepared, "The old expired frame must not be substituted as live")
        await gate.release(1)
        try await wait { presentation.prepared?.capturedAt == clock }
        let newest = try XCTUnwrap(presentation.prepared)
        XCTAssertEqual(newest.image.width, LoupeRenderer.maxColorOutputLongEdge)
        XCTAssertEqual(newest.sampledCenter, .center)
        presentation.submit(sample(date: clock))
        try await wait { await gate.count == 3 }
        presentation.invalidate()
        await gate.release(2)
        try await Task.sleep(for: .milliseconds(10))
        XCTAssertNil(presentation.prepared, "An in-flight image cannot publish after the loupe is closed")
    }

}
#endif
