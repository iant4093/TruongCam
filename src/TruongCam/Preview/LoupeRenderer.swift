import Foundation

// PREVIEW_TOOLS.md "Focus loupe".
//
// DISPLAY-ONLY MAGNIFICATION. Everything in this file is a pure function over an
// owned preview bytes. It has no AVFoundation, CoreMedia, Camera or
// Capture import, and it takes no camera/session/device parameter, so it is
// structurally incapable of touching a capture device:
//   * it never sets `videoZoomFactor` (Bayer capture stays at native zoom 1.0),
//   * it never changes the photo output connection's scale or crop,
//   * it never changes the RAW output dimensions or which format is active.
// The returned `LoupeSnapshot.magnification` is a display label (2× Preview /
// 4× Preview), not a lens or sensor selection.
//
// `LoupeSnapshot` (frozen Core interface) carries no failure case, so an empty
// buffer (0×0) is the typed "Loupe unavailable" result: the caller must show
// "Loupe unavailable" and must never substitute an old frame as live
// (PREVIEW_TOOLS.md "If analysis fails show Loupe unavailable without
// substituting an old frame as live").

/// A color crop is tied to the exact inspection request that selected it. A
/// center/magnification change cannot relabel an old crop as the current loupe.
struct PreviewColorLoupeSample: Sendable {
    let snapshot: LoupeSnapshot
    let center: NormalizedDevicePoint
    let sourceDimensions: PixelDimensions
    let sourceRect: PixelRect

    func matches(_ request: AnalysisRequest) -> Bool {
        guard let geometry = request.geometry else { return false }
        return request.demand.loupeEnabled
            && snapshot.configurationGeneration == request.configurationGeneration
            && snapshot.geometryGeneration == geometry.layoutGeneration
            && center == request.loupeCenter
            && snapshot.sampledCenter == center
            && snapshot.magnification == LoupeRenderer.effectiveMagnification(request.loupeMagnification)
    }
}

enum LoupeRenderer {
    /// Per-axis bilinear coordinates depend on the crop, not the color channel.
    /// Computing these once avoids repeated clamping/division/Int conversion for
    /// every channel of every output pixel. The weights and arithmetic remain
    /// identical to direct bilinear sampling; no detail or color is discarded.
    private struct SamplingAxis {
        let lower: Int
        let upper: Int
        let fraction: Double

        init(_ position: Double, limit: Int) {
            let clamped = min(Double(limit - 1), max(0, position))
            lower = Int(clamped)
            upper = min(lower + 1, limit - 1)
            fraction = clamped - Double(lower)
        }
    }

    private struct SamplingCoordinate {
        let luma: SamplingAxis
        let chroma: SamplingAxis
    }

    /// PREVIEW_TOOLS.md: loupe output ≤ 256×256.
    static let maxOutputLongEdge = 256
    /// Native color crops are sampled before the small analysis downsample.
    /// Keep the display buffer bounded without enlarging the sensor output.
    static let maxColorOutputLongEdge = 512
    /// Display magnifications offered by the focus panel.
    static let supportedMagnifications: [Double] = [2, 4]
    /// Loupe defaults off with 2× display magnification.
    static let defaultMagnification: Double = 2

    /// Bounded processed-preview color, sampled directly from owned dense Y/UV
    /// planes. The caller has already ended its native buffer/graph lease. The
    /// crop retains native focus detail that the 320/384-pixel whole-frame mask
    /// plane has discarded; no full-frame RGB image or RAW decode is created.
    static func renderColor(luma: [UInt8], width: Int, height: Int,
                            chroma: [UInt8], chromaWidth: Int, chromaHeight: Int,
                            range: PreviewCodeRange, matrix: PreviewYCbCrMatrix?,
                            request: AnalysisRequest, capturedAtUTC: Date) -> PreviewColorLoupeSample? {
        guard request.demand.loupeEnabled, let geometry = request.geometry,
              geometry.configurationGeneration == request.configurationGeneration,
              request.loupeCenter.isInsideUnitSquare, let matrix,
              width > 0, height > 0, width <= 8192, height <= 8192,
              width <= (16 * 1024 * 1024) / height, luma.count == width * height,
              chromaWidth >= (width + 1) / 2, chromaHeight >= (height + 1) / 2,
              chromaWidth <= 4096, chromaHeight <= 4096,
              chromaWidth * 2 <= (8 * 1024 * 1024) / chromaHeight,
              chroma.count == chromaWidth * chromaHeight * 2 else { return nil }
        let dimensions = PixelDimensions(width: width, height: height)
        let effective = effectiveMagnification(request.loupeMagnification)
        let mapper = PreviewGeometryMapper.analysisPlane(fallbackContentRect: geometry.previewLayerContentRect,
            planeDimensions: dimensions, rotationDegrees: geometry.analysisRotationDegrees,
            bufferOrientation: geometry.bufferOrientation)
        guard let sampled = mapper.clampedLoupeSampleRect(center: request.loupeCenter,
            magnification: effective, imageDimensions: dimensions),
              let rect = clamped(sampled, to: dimensions) else { return nil }
        // Never upscale a small native crop or pretend interpolation adds detail.
        let scale = min(1, Double(maxColorOutputLongEdge) / Double(max(rect.width, rect.height)))
        let outputWidth = max(1, Int((Double(rect.width) * scale).rounded(.down)))
        let outputHeight = max(1, Int((Double(rect.height) * scale).rounded(.down)))
        let weights = matrix.weights, greenWeight = 1 - weights.red - weights.blue
        let yScale = range == .video ? 219.0 : 255.0
        let cScale = range == .video ? 224.0 : 255.0
        let black = range.nominalBlack
        let columns = (0..<outputWidth).map { column -> SamplingCoordinate in
            let sx = min(Double(rect.maxX - 1), max(Double(rect.x),
                Double(rect.x) + (Double(column) + 0.5) * Double(rect.width) / Double(outputWidth) - 0.5))
            return SamplingCoordinate(luma: SamplingAxis(sx, limit: width),
                chroma: SamplingAxis(sx / 2, limit: chromaWidth))
        }
        let rows = (0..<outputHeight).map { row -> SamplingCoordinate in
            let sy = min(Double(rect.maxY - 1), max(Double(rect.y),
                Double(rect.y) + (Double(row) + 0.5) * Double(rect.height) / Double(outputHeight) - 0.5))
            return SamplingCoordinate(luma: SamplingAxis(sy, limit: height),
                chroma: SamplingAxis(sy / 2, limit: chromaHeight))
        }
        var rgba = [UInt8](repeating: 255, count: outputWidth * outputHeight * 4)
        luma.withUnsafeBufferPointer { yPlane in
            chroma.withUnsafeBufferPointer { uvPlane in
                rgba.withUnsafeMutableBufferPointer { target in
                    guard let yy = yPlane.baseAddress, let uv = uvPlane.baseAddress,
                          let out = target.baseAddress else { return }
                    func interpolate(_ plane: UnsafePointer<UInt8>, _ x: SamplingAxis,
                                     row0: Int, row1: Int, fy: Double, channels: Int, channel: Int) -> Double {
                        let top = Double(plane[row0 + x.lower * channels + channel]) * (1 - x.fraction)
                            + Double(plane[row0 + x.upper * channels + channel]) * x.fraction
                        let bottom = Double(plane[row1 + x.lower * channels + channel]) * (1 - x.fraction)
                            + Double(plane[row1 + x.upper * channels + channel]) * x.fraction
                        return top * (1 - fy) + bottom * fy
                    }
                    func channel(_ value: Double) -> UInt8 { UInt8((min(1, max(0, value)) * 255).rounded()) }
                    columns.withUnsafeBufferPointer { xSamples in
                        rows.withUnsafeBufferPointer { ySamples in
                            guard let xx = xSamples.baseAddress, let rowSamples = ySamples.baseAddress else { return }
                            for row in 0..<outputHeight {
                                let sampleY = rowSamples[row]
                                let lumaRow0 = sampleY.luma.lower * width, lumaRow1 = sampleY.luma.upper * width
                                let chromaRow0 = sampleY.chroma.lower * chromaWidth * 2
                                let chromaRow1 = sampleY.chroma.upper * chromaWidth * 2
                                for column in 0..<outputWidth {
                                    let sampleX = xx[column]
                                    let y = (interpolate(yy, sampleX.luma, row0: lumaRow0, row1: lumaRow1,
                                        fy: sampleY.luma.fraction, channels: 1, channel: 0) - black) / yScale
                                    let cb = (interpolate(uv, sampleX.chroma, row0: chromaRow0, row1: chromaRow1,
                                        fy: sampleY.chroma.fraction, channels: 2, channel: 0) - 128) / cScale
                                    let cr = (interpolate(uv, sampleX.chroma, row0: chromaRow0, row1: chromaRow1,
                                        fy: sampleY.chroma.fraction, channels: 2, channel: 1) - 128) / cScale
                                    let red = y + 2 * (1 - weights.red) * cr
                                    let blue = y + 2 * (1 - weights.blue) * cb
                                    let green = (y - weights.red * red - weights.blue * blue) / greenWeight
                                    let offset = (row * outputWidth + column) * 4
                                    out[offset] = channel(red); out[offset + 1] = channel(green); out[offset + 2] = channel(blue)
                                }
                            }
                        }
                    }
                }
            }
        }
        let snapshot = LoupeSnapshot(width: outputWidth, height: outputHeight, rgbaBytes: rgba,
            geometryGeneration: geometry.layoutGeneration, configurationGeneration: request.configurationGeneration,
            magnification: effective, mappedAtUTC: capturedAtUTC, sampledCenter: request.loupeCenter)
        return PreviewColorLoupeSample(snapshot: orient(snapshot, rotationDegrees: geometry.analysisRotationDegrees,
            mirrored: geometry.isMirrored), center: request.loupeCenter, sourceDimensions: dimensions, sourceRect: rect)
    }

    /// Nearest-neighbour upscale is used deliberately: it is deterministic, it
    /// adds no ringing around a focus edge (which matters for a focus aid), and
    /// it needs no interpolation state between frames. The pure renderer
    /// magnifies the normalized preview luma plane as RGBA8 with R = G = B;
    /// colour rendering from the native preview is a separate display path with
    /// identical geometry.
    ///
    /// - Parameters:
    ///   - sample: normalized preview plane (already downsampled, padding-free).
    ///   - center: loupe center in normalized device coordinates.
    ///   - magnification: display magnification (2× / 4× by default).
    ///   - mapper: optional geometry mapper. When nil, the plane is sampled with
    ///     an identity mapping anchored to its own pixel bounds.
    /// - Returns: an RGBA8 snapshot of at most 256×256, or an empty (0×0)
    ///   snapshot meaning "loupe unavailable".
    static func render(sample: LuminanceSample,
                       center: NormalizedDevicePoint,
                       magnification: Double,
                       mapper: PreviewGeometryMapper? = nil) -> LoupeSnapshot {
        let effective = effectiveMagnification(magnification)
        let plane = PixelDimensions(width: sample.width, height: sample.height)
        guard let rect = sampleRect(sample: sample,
                                    center: center,
                                    magnification: effective,
                                    mapper: mapper ?? PreviewGeometryMapper.analysisPlane(planeDimensions: plane)) else {
            return unavailable(sample: sample, magnification: effective)
        }
        let output = outputDimensions(for: rect)
        guard output.isValid else {
            return unavailable(sample: sample, magnification: effective)
        }

        var rgba = [UInt8](repeating: 0, count: output.width * output.height * 4)
        let planeWidth = sample.width
        sample.luma.withUnsafeBufferPointer { luma in
            guard let base = luma.baseAddress else { return }
            rgba.withUnsafeMutableBufferPointer { destination in
                guard let out = destination.baseAddress else { return }
                for outRow in 0..<output.height {
                    let sourceY = min(rect.y + (outRow * rect.height) / output.height, sample.height - 1)
                    for outColumn in 0..<output.width {
                        let sourceX = min(rect.x + (outColumn * rect.width) / output.width, sample.width - 1)
                        let value = base[sourceY * planeWidth + sourceX]
                        let offset = (outRow * output.width + outColumn) * 4
                        out[offset] = value
                        out[offset + 1] = value
                        out[offset + 2] = value
                        out[offset + 3] = 255
                    }
                }
            }
        }
        return LoupeSnapshot(width: output.width,
                             height: output.height,
                             rgbaBytes: rgba,
                             geometryGeneration: sample.geometryGeneration,
                             configurationGeneration: sample.configurationGeneration,
                             magnification: effective,
                             mappedAtUTC: sample.capturedAtUTC)
    }

    /// Preview-geometry overload used by the live pipeline: the mapper is
    /// re-anchored onto the analysis plane the sample actually came from.
    static func render(sample: LuminanceSample,
                       center: NormalizedDevicePoint,
                       magnification: Double,
                       geometry: PreviewGeometrySnapshot) -> LoupeSnapshot {
        let plane = PixelDimensions(width: sample.width, height: sample.height)
        let mapper = PreviewGeometryMapper.analysisPlane(fallbackContentRect: geometry.previewLayerContentRect,
                                                         planeDimensions: plane,
                                                         rotationDegrees: geometry.analysisRotationDegrees,
                                                         bufferOrientation: geometry.bufferOrientation)
        let rendered = render(sample: sample, center: center, magnification: magnification, mapper: mapper)
        guard rendered.width > 0, rendered.height > 0 else { return rendered }
        return orient(rendered, rotationDegrees: geometry.analysisRotationDegrees, mirrored: geometry.isMirrored)
    }

    /// One packed pass preserves RGBA pixels without allocating/rotating four
    /// extracted channel planes and then interleaving a fifth output buffer.
    /// Coordinates follow the same clockwise-rotation, then display-mirror
    /// convention as the preview mask mapper.
    static func orient(_ snapshot: LoupeSnapshot, rotationDegrees: Int, mirrored: Bool) -> LoupeSnapshot {
        let angle = ((rotationDegrees % 360) + 360) % 360
        let rotation = [90, 180, 270].contains(angle) ? angle : 0
        guard snapshot.width > 0, snapshot.height > 0,
              snapshot.width <= maxColorOutputLongEdge, snapshot.height <= maxColorOutputLongEdge,
              snapshot.rgbaBytes.count == snapshot.width * snapshot.height * 4 else { return snapshot }
        guard rotation != 0 || mirrored else { return snapshot }
        let swaps = rotation == 90 || rotation == 270
        let width = swaps ? snapshot.height : snapshot.width
        let height = swaps ? snapshot.width : snapshot.height
        var bytes = [UInt8](repeating: 0, count: snapshot.rgbaBytes.count)
        snapshot.rgbaBytes.withUnsafeBufferPointer { source in
            bytes.withUnsafeMutableBufferPointer { destination in
                guard let input = source.baseAddress, let output = destination.baseAddress else { return }
                for y in 0..<snapshot.height {
                    for x in 0..<snapshot.width {
                        let targetX: Int, targetY: Int
                        switch rotation {
                        case 90: targetX = snapshot.height - 1 - y; targetY = x
                        case 180: targetX = snapshot.width - 1 - x; targetY = snapshot.height - 1 - y
                        case 270: targetX = y; targetY = snapshot.width - 1 - x
                        default: targetX = x; targetY = y
                        }
                        let displayedX = mirrored ? width - 1 - targetX : targetX
                        let from = (y * snapshot.width + x) * 4
                        let to = (targetY * width + displayedX) * 4
                        output[to] = input[from]; output[to + 1] = input[from + 1]
                        output[to + 2] = input[from + 2]; output[to + 3] = input[from + 3]
                    }
                }
            }
        }
        return LoupeSnapshot(width: width, height: height, rgbaBytes: bytes,
            geometryGeneration: snapshot.geometryGeneration, configurationGeneration: snapshot.configurationGeneration,
            magnification: snapshot.magnification, mappedAtUTC: snapshot.mappedAtUTC,
            sampledCenter: snapshot.sampledCenter)
    }

    /// The sampled rectangle in preview-plane pixels, clamped to the real image
    /// bounds through `PreviewGeometryMapper.clampedLoupeSampleRect`.
    ///
    /// A loupe near an edge therefore shows real preview pixels rather than the
    /// view's letterbox or padding. The rectangle is expressed in the preview
    /// plane's own coordinate space: the mapper's `imageDimensions` describe the
    /// plane being sampled, and its rotation/mirroring describe the transform
    /// from normalized device space into that plane.
    static func sampleRect(sample: LuminanceSample,
                           center: NormalizedDevicePoint,
                           magnification: Double,
                           mapper: PreviewGeometryMapper) -> PixelRect? {
        let plane = PixelDimensions(width: sample.width, height: sample.height)
        guard plane.isValid, sample.luma.count >= plane.width * plane.height else { return nil }
        let anchored = PreviewGeometryMapper.analysisPlane(fallbackContentRect: mapper.contentRect,
                                                           planeDimensions: plane,
                                                           rotationDegrees: mapper.rotationDegrees,
                                                           bufferOrientation: mapper.bufferOrientation)
        guard let rect = anchored.clampedLoupeSampleRect(center: center,
                                                         magnification: effectiveMagnification(magnification),
                                                         imageDimensions: plane) else {
            return nil
        }
        return clamped(rect, to: plane)
    }

    /// Output buffer size for a sampled rectangle: at most 256 pixels on either
    /// edge, preserving the rectangle's aspect.
    static func outputDimensions(for rect: PixelRect) -> PixelDimensions {
        guard !rect.isEmpty else { return PixelDimensions(width: 0, height: 0) }
        let scale = min(Double(maxOutputLongEdge) / Double(rect.width),
                        Double(maxOutputLongEdge) / Double(rect.height))
        let width = max(1, min(maxOutputLongEdge, Int((Double(rect.width) * scale).rounded(.down))))
        let height = max(1, min(maxOutputLongEdge, Int((Double(rect.height) * scale).rounded(.down))))
        return PixelDimensions(width: width, height: height)
    }

    /// Clamps display magnification into a sane display-only range. Non-finite or
    /// non-positive values fall back to the documented 2× default.
    static func effectiveMagnification(_ magnification: Double) -> Double {
        guard magnification.isFinite, magnification > 0 else { return defaultMagnification }
        return min(max(magnification, 1), supportedMagnifications.max() ?? 4)
    }

    private static func clamped(_ rect: PixelRect, to plane: PixelDimensions) -> PixelRect? {
        guard !rect.isEmpty else { return nil }
        let x = min(max(rect.x, 0), max(0, plane.width - 1))
        let y = min(max(rect.y, 0), max(0, plane.height - 1))
        let width = min(rect.width, plane.width - x)
        let height = min(rect.height, plane.height - y)
        guard width >= 1, height >= 1 else { return nil }
        return PixelRect(x: x, y: y, width: width, height: height)
    }

    private static func unavailable(sample: LuminanceSample, magnification: Double) -> LoupeSnapshot {
        LoupeSnapshot(width: 0,
                      height: 0,
                      rgbaBytes: [],
                      geometryGeneration: sample.geometryGeneration,
                      configurationGeneration: sample.configurationGeneration,
                      magnification: magnification,
                      mappedAtUTC: sample.capturedAtUTC)
    }
}

extension PreviewGeometryMapper {
    /// Builds the mapper used to sample a preview plane.
    ///
    /// The sampled plane is the *analysis* plane: mirroring is a display
    /// transform and is not applied to the plane's own pixels, so the loupe
    /// presents plane pixels in plane order (flipping the surrounding preview is
    /// the display layer's job). Rotation is the analysis rotation already
    /// applied to the plane, and `bufferOrientation` is carried through so the
    /// device↔buffer axis swap stays consistent with the rest of the pipeline.
    static func analysisPlane(fallbackContentRect: TCRect?,
                              planeDimensions: PixelDimensions,
                              rotationDegrees: Int = 0,
                              bufferOrientation: Int = 1) -> PreviewGeometryMapper {
        let rect = fallbackContentRect.flatMap { $0.isEmpty ? nil : $0 }
            ?? TCRect(x: 0, y: 0, width: Double(planeDimensions.width), height: Double(planeDimensions.height))
        return PreviewGeometryMapper(imageDimensions: planeDimensions,
                                     contentRect: rect,
                                     isMirrored: false,
                                     rotationDegrees: rotationDegrees,
                                     bufferOrientation: bufferOrientation)
    }

    /// Identity mapper anchored to the plane's own pixel bounds.
    static func analysisPlane(planeDimensions: PixelDimensions) -> PreviewGeometryMapper {
        analysisPlane(fallbackContentRect: nil,
                      planeDimensions: planeDimensions,
                      rotationDegrees: 0,
                      bufferOrientation: 1)
    }
}
