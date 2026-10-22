import Foundation
#if canImport(XCTest)
@testable import TruongCam
#endif

enum ColorLoupeSuite {
    static func request(center: NormalizedDevicePoint = .center, magnification: Double = 2,
                        rotation: Int = 0, mirrored: Bool = false, enabled: Bool = true,
                        generation: ConfigurationGeneration = ConfigurationGeneration(52)) -> AnalysisRequest {
        let dimensions = PixelDimensions(width: 1024, height: 768)
        let geometry = PreviewGeometrySnapshot(configurationGeneration: generation, layoutGeneration: 2,
            imageDimensions: dimensions, cleanApertureDimensions: nil,
            previewLayerContentRect: TCRect(x: 0, y: 0, width: 400, height: 300), bufferOrientation: 1,
            isMirrored: mirrored, analysisRotationDegrees: rotation, isVideoMirrored: false,
            capturedAtUTC: Date(timeIntervalSince1970: 0))
        return AnalysisRequest(configurationGeneration: generation, geometry: geometry,
            demand: AnalysisDemand(needsLuminanceSample: true, histogramEnabled: true, zebrasEnabled: false,
                peakingEnabled: false, loupeEnabled: enabled), peakingThreshold: 0.1, zebraThreshold: 0.95,
            loupeCenter: center, loupeMagnification: magnification)
    }
    static func color(request: AnalysisRequest, width: Int = 1024, height: Int = 768,
                      date: Date = Date(timeIntervalSince1970: 0)) -> PreviewColorLoupeSample? {
        var luma = [UInt8](repeating: 0, count: width * height)
        for row in 0..<height { for column in 0..<width { luma[row * width + column] = column % 2 == 0 ? 48 : 180 } }
        var chroma = [UInt8](repeating: 0, count: (width / 2) * (height / 2) * 2)
        for index in stride(from: 0, to: chroma.count, by: 2) { chroma[index] = 90; chroma[index + 1] = 220 }
        return LoupeRenderer.renderColor(luma: luma, width: width, height: height, chroma: chroma,
            chromaWidth: width / 2, chromaHeight: height / 2, range: .full, matrix: .itu601,
            request: request, capturedAtUTC: date)
    }
    /// Independent direct bilinear oracle retained from the pre-optimization
    /// sampling rule. Do not use the new axis tables to compute expected pixels.
    private static func directColor(luma: [UInt8], width: Int, height: Int, chroma: [UInt8],
                                    chromaWidth: Int, chromaHeight: Int, rect: PixelRect,
                                    range: PreviewCodeRange, matrix: PreviewYCbCrMatrix,
                                    request: AnalysisRequest, date: Date) -> LoupeSnapshot {
        let scale = min(1, 512.0 / Double(max(rect.width, rect.height)))
        let w = max(1, Int((Double(rect.width) * scale).rounded(.down)))
        let h = max(1, Int((Double(rect.height) * scale).rounded(.down)))
        var bytes = [UInt8](repeating: 255, count: w * h * 4)
        func interpolate(_ plane: [UInt8], _ x: Double, _ y: Double, width: Int, height: Int,
                         channels: Int, channel: Int) -> Double {
            let px = min(Double(width - 1), max(0, x)), py = min(Double(height - 1), max(0, y))
            let x0 = Int(px), y0 = Int(py), x1 = min(x0 + 1, width - 1), y1 = min(y0 + 1, height - 1)
            let fx = px - Double(x0), fy = py - Double(y0)
            let top = Double(plane[(y0 * width + x0) * channels + channel]) * (1 - fx)
                + Double(plane[(y0 * width + x1) * channels + channel]) * fx
            let bottom = Double(plane[(y1 * width + x0) * channels + channel]) * (1 - fx)
                + Double(plane[(y1 * width + x1) * channels + channel]) * fx
            return top * (1 - fy) + bottom * fy
        }
        func channel(_ value: Double) -> UInt8 { UInt8((min(1, max(0, value)) * 255).rounded()) }
        let weights = matrix.weights, greenWeight = 1 - weights.red - weights.blue
        for y in 0..<h {
            let sy = min(Double(rect.maxY - 1), max(Double(rect.y),
                Double(rect.y) + (Double(y) + 0.5) * Double(rect.height) / Double(h) - 0.5))
            for x in 0..<w {
                let sx = min(Double(rect.maxX - 1), max(Double(rect.x),
                    Double(rect.x) + (Double(x) + 0.5) * Double(rect.width) / Double(w) - 0.5))
                let yy = (interpolate(luma, sx, sy, width: width, height: height, channels: 1, channel: 0) - range.nominalBlack)
                    / (range == .video ? 219 : 255)
                let cb = (interpolate(chroma, sx / 2, sy / 2, width: chromaWidth, height: chromaHeight, channels: 2, channel: 0) - 128)
                    / (range == .video ? 224 : 255)
                let cr = (interpolate(chroma, sx / 2, sy / 2, width: chromaWidth, height: chromaHeight, channels: 2, channel: 1) - 128)
                    / (range == .video ? 224 : 255)
                let red = yy + 2 * (1 - weights.red) * cr, blue = yy + 2 * (1 - weights.blue) * cb
                let green = (yy - weights.red * red - weights.blue * blue) / greenWeight
                let index = (y * w + x) * 4
                bytes[index] = channel(red); bytes[index + 1] = channel(green); bytes[index + 2] = channel(blue)
            }
        }
        return LoupeSnapshot(width: w, height: h, rgbaBytes: bytes, geometryGeneration: request.geometry?.layoutGeneration ?? 0,
            configurationGeneration: request.configurationGeneration, magnification: LoupeRenderer.effectiveMagnification(request.loupeMagnification),
            mappedAtUTC: date, sampledCenter: request.loupeCenter)
    }
    static let suite = TCSuite(id: "ColorLoupe52", title: "Native-detail color loupe and stale crop rejection", cases: [
        TCCase(id: "CL54A", title: "Precomputed bilinear coordinates preserve every color byte on a scaled non-aligned crop") { r in
            let width = 1210, height = 806, cw = width / 2, ch = height / 2
            let luma = (0..<(width * height)).map { UInt8(truncatingIfNeeded: $0 * 37 + ($0 / width) * 13) }
            let chroma = (0..<(cw * ch * 2)).map { UInt8(truncatingIfNeeded: $0 * 29 + ($0 / (cw * 2)) * 17) }
            let date = Date(timeIntervalSince1970: 54)
            for range in [PreviewCodeRange.full, .video] {
                for matrix in PreviewYCbCrMatrix.allCases {
                    let q = request(center: NormalizedDevicePoint(x: 0.43, y: 0.61), rotation: 90, mirrored: true)
                    guard let actual = LoupeRenderer.renderColor(luma: luma, width: width, height: height,
                        chroma: chroma, chromaWidth: cw, chromaHeight: ch, range: range, matrix: matrix,
                        request: q, capturedAtUTC: date) else { r.check("real color crop", false); continue }
                    let raw = directColor(luma: luma, width: width, height: height, chroma: chroma,
                        chromaWidth: cw, chromaHeight: ch, rect: actual.sourceRect, range: range, matrix: matrix, request: q, date: date)
                    let expected = LoupeRenderer.orient(raw, rotationDegrees: 90, mirrored: true)
                    r.equal("exact bilinear RGBA bytes \(range)/\(matrix)", actual.snapshot.rgbaBytes, expected.rgbaBytes)
                    r.equal("oriented width \(range)/\(matrix)", actual.snapshot.width, expected.width)
                    r.equal("oriented height \(range)/\(matrix)", actual.snapshot.height, expected.height)
                    r.equal("source time unchanged", actual.snapshot.mappedAtUTC, date)
                }
            }
        },
        TCCase(id: "CL52A", title: "The native crop preserves single-pixel detail lost by the small analysis plane") { r in
            guard let crop = color(request: request()) else { r.check("color crop", false); return }
            r.equal("true crop long edge", crop.snapshot.width, 512)
            r.equal("native crop height", crop.snapshot.height, 384)
            r.equal("native source", crop.sourceDimensions, PixelDimensions(width: 1024, height: 768))
            r.equal("actual central pixels", crop.sourceRect, PixelRect(x: 256, y: 192, width: 512, height: 384))
            let b = crop.snapshot.rgbaBytes
            r.check("adjacent native columns still distinct", abs(Int(b[0]) - Int(b[4])) > 70)
            r.check("actual chroma remains color", b[0] > b[2] + 50 && b[4] > b[6] + 50)
            r.check("opaque RGBA and bounded bytes", b.count == 512 * 384 * 4 && stride(from: 3, to: b.count, by: 4).allSatisfy { b[$0] == 255 })
            guard let tiny = color(request: request(), width: 16, height: 12) else { r.check("small native crop", false); return }
            r.equal("small source is never inflated into fake detail", tiny.snapshot.width, 8)
        },
        TCCase(id: "CL52B", title: "Known YUV range and matrix yield real color; unknown chroma is never guessed") { r in
            let q = request()
            for (range, yy, cb, cr) in [(PreviewCodeRange.full, UInt8(76), UInt8(85), UInt8(255)), (.video, 81, 90, 240)] {
                let pixels = LoupeRenderer.renderColor(luma: [UInt8](repeating: yy, count: 16 * 12), width: 16, height: 12,
                    chroma: Array(repeating: [cb, cr], count: 8 * 6).flatMap { $0 }, chromaWidth: 8, chromaHeight: 6,
                    range: range, matrix: .itu601, request: q, capturedAtUTC: Date())
                guard let bytes = pixels?.snapshot.rgbaBytes else { r.check("known range", false); continue }
                r.check("601 red reference \(range)", bytes[0] >= 250 && bytes[1] <= 4 && bytes[2] <= 4)
            }
            r.check("off demand produces no color work", color(request: request(enabled: false)) == nil)
            r.check("outside center rejected", color(request: request(center: NormalizedDevicePoint(x: -0.1, y: 0.5))) == nil)
            let invalid = LoupeRenderer.renderColor(luma: [UInt8](repeating: 80, count: 16 * 12), width: 16, height: 12,
                chroma: [UInt8](repeating: 128, count: 8 * 6 * 2), chromaWidth: 8, chromaHeight: 6,
                range: .full, matrix: nil, request: q, capturedAtUTC: Date())
            r.check("unknown matrix unavailable", invalid == nil)
        },
        TCCase(id: "CL52C", title: "Rotations, mirror and edge inspection preserve actual cropped color") { r in
            guard let base = color(request: request()) else { r.check("base crop", false); return }
            let raw = base.snapshot
            for angle in [0, 90, 180, 270] {
                for mirror in [false, true] {
                    guard let crop = color(request: request(rotation: angle, mirrored: mirror)) else { r.check("oriented crop", false); continue }
                    let swaps = angle % 180 != 0
                    r.equal("oriented width \(angle)/\(mirror)", crop.snapshot.width, swaps ? raw.height : raw.width)
                    r.equal("oriented height \(angle)/\(mirror)", crop.snapshot.height, swaps ? raw.width : raw.height)
                    let sx = 10, sy = 20
                    let x: Int, y: Int
                    switch angle {
                    case 90: x = raw.height - 1 - sy; y = sx
                    case 180: x = raw.width - 1 - sx; y = raw.height - 1 - sy
                    case 270: x = sy; y = raw.width - 1 - sx
                    default: x = sx; y = sy
                    }
                    let targetX = mirror ? crop.snapshot.width - 1 - x : x
                    let source = (sy * raw.width + sx) * 4, destination = (y * crop.snapshot.width + targetX) * 4
                    r.equal("color moves with geometry \(angle)/\(mirror)", Array(crop.snapshot.rgbaBytes[destination..<(destination + 4)]), Array(raw.rgbaBytes[source..<(source + 4)]))
                }
            }
            let edge = color(request: request(center: NormalizedDevicePoint(x: 1, y: 1), magnification: 4))
            r.equal("edge stays within native frame", edge?.sourceRect, PixelRect(x: 768, y: 576, width: 256, height: 192))
        },
        TCCase(id: "CL52E", title: "Queued color output cannot repaint a prior point or magnification in the shipping model") { r in
            guard let h = await StorageHarness.make(name: "color-model52") else { r.check("store fixture", false); return }
            let capability = CaptureFormatUISuite.capability(), service = SyntheticCameraService(capability: CaptureFormatUISuite.capability())
            let model = await CameraViewModel(camera: service,
                capture: CaptureCoordinator(camera: ChainCameraSpy(), store: h.store, clock: SystemMonotonicClock()),
                metering: MeteringService(clock: SystemMonotonicClock()), preferences: SyntheticPreferenceStore(), levelFeed: SyntheticLevelFeed())
            await model.start()
            let q = request(generation: capability.generation)
            await MainActor.run { model.composition.loupeEnabled = true; model.updateGeometry(q.geometry) }
            guard let first = color(request: q, width: 16, height: 12) else { r.check("first crop", false); return }
            await model.consumeAnalysisOutput(.loupe(first.snapshot))
            r.check("first point published", await model.loupe?.sampledCenter == .center)
            let point = NormalizedDevicePoint(x: 0.8, y: 0.2)
            await model.setLoupeCenter(point)
            r.check("moving point clears previous display", await model.loupe == nil)
            await model.consumeAnalysisOutput(.loupe(first.snapshot))
            r.check("queued old point rejected", await model.loupe == nil)
            guard let current = color(request: request(center: point, generation: capability.generation), width: 16, height: 12) else { r.check("current crop", false); return }
            await model.consumeAnalysisOutput(.loupe(current.snapshot))
            r.equal("current point publishes", await model.loupe?.sampledCenter, point)
            await MainActor.run { model.composition.loupeMagnification = 4 }
            r.check("magnification clears prior display", await model.loupe == nil)
            await model.consumeAnalysisOutput(.loupe(current.snapshot))
            r.check("queued old magnification rejected", await model.loupe == nil)
            await model.stop()
        },
        TCCase(id: "CL52D", title: "Moving the loupe rejects old crop instead of relabeling grayscale; other aids continue") { r in
            let clock = VirtualMonotonicClock(start: 0), meter = MeteringService(clock: clock)
            let q = request(), date = Date(timeIntervalSince1970: 0)
            guard let crop = color(request: q, date: date) else { r.check("crop", false); return }
            await meter.setDemand(q)
            var sample = LuminanceSample(width: 8, height: 6, luma: [UInt8](repeating: 80, count: 48), range: .full,
                configurationGeneration: q.configurationGeneration, geometryGeneration: 2, capturedAtUTC: date)
            sample.colorLoupe = crop; sample.requiresColorLoupe = true
            await meter.submit(sample: sample)
            r.equal("current native crop emitted", await meter.emittedLoupeCount, 1)
            await meter.setDemand(request(center: NormalizedDevicePoint(x: 0.8, y: 0.2)))
            clock.advance(by: 1)
            var moved = LuminanceSample(width: 8, height: 6, luma: sample.luma, range: .full,
                configurationGeneration: q.configurationGeneration, geometryGeneration: 2, capturedAtUTC: date.addingTimeInterval(1))
            moved.requiresColorLoupe = true
            moved.colorLoupe = PreviewColorLoupeSample(snapshot: LoupeSnapshot(width: crop.snapshot.width, height: crop.snapshot.height,
                rgbaBytes: crop.snapshot.rgbaBytes, geometryGeneration: 2, configurationGeneration: q.configurationGeneration,
                magnification: 2, mappedAtUTC: moved.capturedAtUTC), center: crop.center, sourceDimensions: crop.sourceDimensions, sourceRect: crop.sourceRect)
            await meter.submit(sample: moved)
            r.equal("old center never repaints", await meter.emittedLoupeCount, 1)
            r.equal("histogram still runs", await meter.emittedHistogramCount, 2)
            r.check("missing current crop is disclosed", await meter.emittedUnavailableCount > 0)
        }
    ])
}
