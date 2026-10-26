import SwiftUI
import UIKit
import Observation

// The selected Precision control surface: compact labeled readouts that open one
// adjustment panel over the lower preview, plus a tools sheet for the aids and
// sequence configuration. Every control keeps at least a 44-point hit target and
// an accessible name that states the full Auto/manual state and value.

/// The viewfinder surface, its overlays and its tap handling.
struct Viewfinder: View {
    @Environment(AppEnvironment.self) private var app
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            Color.black

            if let camera = app.camera {
                CameraPreviewHost(camera: camera)
                    .allowsHitTesting(!camera.isCaptureBusy)
                    .overlay {
                        if camera.isPreviewTransitionVisible {
                            FrozenCameraTransition(frame: camera.frozenSwitchPreview)
                                .transition(.asymmetric(insertion: .identity, removal: .opacity))
                        }
                    }
                    .animation(reduceMotion ? nil : .easeOut(duration: 0.14), value: camera.isPreviewTransitionVisible)
                    .accessibilityLabel("Camera preview")
                    .accessibilityHint("Double tap to focus on the centre of the visible image.")
            } else {
                ProgressView().tint(.white)
            }

            if let camera = app.camera {
                AidOverlays(camera: camera)
                    .allowsHitTesting(false)
                ShutterFlashOverlay(pulse: camera.shutterPulse)
                    .allowsHitTesting(false)
            }
        }
        .clipped()
    }
}

/// An opaque still hides native input/rotation changes. No live material effect:
/// applying a blur to the changing video would still expose its flips underneath.
struct FrozenCameraTransition: View {
    let frame: PreviewTransitionFrame?
    var body: some View {
        ZStack {
            Color.black
            if let frame {
                Image(decorative: frame.image, scale: 1).resizable().scaledToFill()
                    .blur(radius: 18, opaque: true)
                Color.black.opacity(0.18)
            }
        }
        .clipped().allowsHitTesting(false).accessibilityHidden(true)
    }
}

/// A native will-capture callback triggers each shutter response, never a verified save.
/// It covers only the viewfinder so controls stay visible and do not move.
struct ShutterFlashOverlay: View {
    let pulse: UInt64
    var holdDuration: Duration = .milliseconds(35)
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var opacity: Double = 0
    var body: some View {
        Color.white.opacity(opacity).accessibilityHidden(true)
            .task(id: pulse) {
                guard pulse > 0 else { opacity = 0; return }
                opacity = reduceMotion ? 0.035 : 0.08
                do { try await Task.sleep(for: holdDuration) } catch { return }
                guard !Task.isCancelled else { return }
                withAnimation(.easeOut(duration: reduceMotion ? 0.10 : 0.16)) { opacity = 0 }
            }
    }
}

/// Bridges the SwiftUI viewfinder to the display-only preview layer.
private struct CameraPreviewHost: View {
    @Environment(AppEnvironment.self) private var app
    let camera: CameraViewModel

    var body: some View {
        GeometryReader { proxy in
            let contentRect = TCRect(x: 0, y: 0,
                                     width: Double(proxy.size.width),
                                     height: Double(proxy.size.height))
            if let box = camera.previewSessionBox {
                CameraPreviewView(
                    sessionBox: box,
                    isMirrored: camera.capability.selectedCameraKind == .front,
                    configurationGeneration: camera.capability.generation,
                    imageDimensions: camera.activeFormat?.videoDimensions ?? PixelDimensions(width: 0, height: 0),
                    cleanApertureDimensions: camera.activeFormat?.cleanApertureDimensions,
                    onTap: { point in
                        let mapper = currentMapper(contentRect: contentRect)
                        Task { await camera.handleFocusTap(atViewPoint: point, mapper: mapper) }
                    },
                    onTapRejected: { },
                    onGeometryChanged: { geometry in
                        camera.updateGeometry(PreviewGeometrySnapshot(
                            configurationGeneration: geometry.configurationGeneration,
                            layoutGeneration: geometry.layoutGeneration,
                            imageDimensions: geometry.imageDimensions,
                            cleanApertureDimensions: geometry.cleanApertureDimensions,
                            previewLayerContentRect: geometry.contentRect,
                            bufferOrientation: 1,
                            isMirrored: geometry.isMirrored,
                            analysisRotationDegrees: geometry.rotationDegrees,
                            isVideoMirrored: geometry.isMirrored,
                            capturedAtUTC: Date(),
                            interfaceOrientation: geometry.interfaceOrientation))
                    },
                    // REVIEW.md S07: dragging in the preview moves the loupe while
                    // it is enabled, in the same normalized device space the
                    // analysis request carries.
                    onLoupeCentreChanged: { point in
                        camera.setLoupeCenter(point)
                    },
                    isLoupeActive: camera.composition.loupeEnabled,
                    isConnectionConfigurationEnabled: camera.isPreviewConnectionStable,
                    onPreviewReady: { generation, layout in
                        camera.previewDidResume(generation: generation, layout: layout)
                    })
                    .onAppear { camera.setPreviewContentRect(contentRect) }
            } else {
                Color.black
            }
        }
    }

    private func currentMapper(contentRect: TCRect) -> PreviewGeometryMapper {
        camera.previewGeometryMapper(fallbackContentRect: contentRect)
    }
}

/// Grid, level, histogram, meter and the mask overlays. Purely visual: no aid
/// here can change capture settings or the RAW output size.
struct CameraPreviewChromeLayout {
    static let headerInset: CGFloat = 14
    static let headerHeight: CGFloat = 44
    static let edgeInset: CGFloat = 8
    static let separation: CGFloat = 8
    static let loupeSize = CGSize(width: 128, height: 128)
    static let histogramSize = CGSize(width: 120, height: 50)
    static let meterSize = CGSize(width: 28, height: 112)

    let loupe: CGRect
    let histogram: CGRect
    let meter: CGRect
    let maximumLevelGuideWidth: CGFloat?
    let maximumSurfaceTravel: CGFloat?

    /// Share the real leading-header footprint with CameraTopRow. Numeric EV
    /// and format controls keep their touch targets on compact viewfinders.
    static func histogramFrame(inWidth width: CGFloat) -> CGRect {
        let inner = max(0, width - headerInset * 2)
        let leading = max(0, inner - 64 - 44 - separation * 2)
        return CGRect(x: edgeInset, y: edgeInset,
            width: min(histogramSize.width, leading + headerInset - edgeInset),
            height: histogramSize.height)
    }

    @MainActor static func showsHistogram(camera: CameraViewModel, inWidth width: CGFloat) -> Bool {
        camera.composition.histogramEnabled && camera.histogram != nil
            && camera.pendingOriginalCount == 0 && histogramFrame(inWidth: width).width >= 56
    }

    private static func distance(from point: CGPoint, to rect: CGRect) -> CGFloat {
        let dx = max(max(rect.minX - point.x, 0), point.x - rect.maxX)
        let dy = max(max(rect.minY - point.y, 0), point.y - rect.maxY)
        return hypot(dx, dy)
    }

    init(size: CGSize, hasLoupe: Bool, hasHistogram: Bool = false) {
        // The header is a separate overlay on the same viewfinder. Reserve its
        // complete 44-point hit region, not just the visible RAW/JPEG text.
        let center = CGPoint(x: size.width / 2, y: size.height / 2)
        let loupeTop = Self.headerInset + Self.headerHeight + Self.separation
        var side = Self.loupeSize.width
        var candidate = CGRect.zero
        repeat {
            candidate = CGRect(x: max(Self.edgeInset, size.width - side - Self.edgeInset),
                y: loupeTop, width: side, height: side)
            let dx = max(max(candidate.minX - center.x, 0), center.x - candidate.maxX)
            let dy = max(max(candidate.minY - center.y, 0), center.y - candidate.maxY)
            // Small accessibility viewfinders can put the full-size loupe over
            // the level's fixed 44-point target. Compact only its display card;
            // native color-crop pixels and magnification stay unchanged.
            if !hasLoupe || (hypot(dx, dy) >= 22 + Self.separation
                && candidate.maxX <= size.width - Self.edgeInset
                && candidate.maxY <= size.height - 66) { break }
            side -= 1
        } while side >= 64
        loupe = candidate
        histogram = Self.histogramFrame(inWidth: size.width)
        let ordinaryMeterY = max(Self.edgeInset, (size.height - Self.meterSize.height) / 2)
        let belowLoupeY = max(ordinaryMeterY, loupe.maxY + Self.separation)
        let trailingBelow = CGRect(x: max(Self.edgeInset, size.width - Self.meterSize.width - Self.edgeInset),
            y: belowLoupeY, width: Self.meterSize.width, height: Self.meterSize.height)
        let lensPicker = CGRect(x: size.width / 2 - 77, y: size.height - 58, width: 154, height: 48)
        if hasLoupe && trailingBelow.maxY + Self.edgeInset <= size.height
            && !trailingBelow.insetBy(dx: -Self.separation, dy: -Self.separation).intersects(lensPicker) {
            meter = trailingBelow
        } else if hasLoupe {
            // Short landscape frames have no vertical room for both aids on
            // the right. The leading edge below the histogram stays clear of
            // the centered level and bottom lens picker.
            let top = max(ordinaryMeterY, hasHistogram ? histogram.maxY + Self.separation : Self.edgeInset)
            let leading = CGRect(x: Self.edgeInset, y: top, width: Self.meterSize.width, height: Self.meterSize.height)
            let meetsLens = leading.insetBy(dx: -Self.separation, dy: 0).intersects(lensPicker)
            let bottom = meetsLens ? min(size.height - Self.edgeInset, lensPicker.minY - Self.separation)
                : size.height - Self.edgeInset
            meter = CGRect(x: leading.minX, y: leading.minY, width: leading.width,
                height: max(1, min(Self.meterSize.height, bottom - top)))
        } else {
            meter = CGRect(x: max(Self.edgeInset, size.width - Self.meterSize.width - Self.edgeInset),
                y: ordinaryMeterY, width: Self.meterSize.width, height: Self.meterSize.height)
        }
        var safeRadius: CGFloat?
        if hasLoupe {
            safeRadius = Self.distance(from: center, to: loupe.insetBy(dx: -Self.separation, dy: -Self.separation))
        }
        if hasHistogram {
            let histogramRadius = Self.distance(from: center,
                to: histogram.insetBy(dx: -Self.separation, dy: -Self.separation))
            safeRadius = min(safeRadius ?? .infinity, histogramRadius)
        }
        // Reserve the actual expanded rectangles first: subtracting a scalar
        // gap from corner distance does not guarantee that gap on both axes.
        // Include the half-point horizon stroke and the surface ring's radius.
        maximumLevelGuideWidth = safeRadius.map { max(0, $0 - 0.5) * 2 }
        maximumSurfaceTravel = safeRadius.map { max(0, $0 - 11) }
    }
}

struct AidOverlays: View {
    @Environment(AppEnvironment.self) private var app
    let camera: CameraViewModel

    var body: some View {
        GeometryReader { proxy in
            let hasLoupe = camera.composition.loupeEnabled && camera.loupe != nil
            let hasHistogram = CameraPreviewChromeLayout.showsHistogram(camera: camera, inWidth: proxy.size.width)
            let placement = CameraPreviewChromeLayout(size: proxy.size, hasLoupe: hasLoupe,
                hasHistogram: hasHistogram)
            ZStack {
                if camera.composition.gridMode != .off {
                    GridOverlay(mode: camera.composition.gridMode)
                        .stroke(Color.white.opacity(0.35), lineWidth: 0.5)
                }

                if camera.composition.levelEnabled && !camera.isPreviewTransitionVisible {
                    LevelOverlay(state: camera.levelState, maximumGuideWidth: placement.maximumLevelGuideWidth,
                        maximumSurfaceTravel: placement.maximumSurfaceTravel)
                }

                if let masks = camera.masks, camera.composition.peakingEnabled || camera.composition.zebrasEnabled {
                    FreshPreviewMaskOverlay(snapshot: masks, peakingEnabled: camera.composition.peakingEnabled,
                        zebrasEnabled: camera.composition.zebrasEnabled)
                }

                if camera.composition.loupeEnabled, let loupe = camera.loupe {
                    LoupeOverlay(snapshot: loupe,
                                 label: camera.composition.loupeMagnification >= 4 ? "4× Preview" : "2× Preview",
                                 displayScale: placement.loupe.width / CameraPreviewChromeLayout.loupeSize.width)
                        .frame(width: placement.loupe.width, height: placement.loupe.height)
                        .position(x: placement.loupe.midX, y: placement.loupe.midY)
                }

                if hasHistogram, let histogram = camera.histogram {
                    HistogramOverlay(snapshot: histogram)
                        .frame(width: placement.histogram.width, height: placement.histogram.height)
                        .position(x: placement.histogram.midX, y: placement.histogram.midY)
                }

                // Metering is a read-only observation in manual too; only the
                // compensation action is restricted to automatic exposure modes.
                if camera.surface == .ready && !camera.isPreviewTransitionVisible {
                    ExposureMeterOverlay(offsetEV: camera.observedExposureTargetOffset, height: placement.meter.height)
                        .position(x: placement.meter.midX, y: placement.meter.midY)
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
        }
    }
}

struct GridOverlay: Shape {
    let mode: GridMode

    func path(in rect: CGRect) -> Path {
        var path = Path()
        switch mode {
        case .off:
            break
        case .thirds:
            for index in 1...2 {
                let x = rect.minX + rect.width * CGFloat(index) / 3
                let y = rect.minY + rect.height * CGFloat(index) / 3
                path.move(to: CGPoint(x: x, y: rect.minY))
                path.addLine(to: CGPoint(x: x, y: rect.maxY))
                path.move(to: CGPoint(x: rect.minX, y: y))
                path.addLine(to: CGPoint(x: rect.maxX, y: y))
            }

        }
        return path
    }
}

/// Upright horizon roll and a two-axis surface target when the phone is flat.
/// Missing/unusable motion remains distinct from a healthy flat reading.
struct LevelOverlay: View {
    let state: LevelState?
    var maximumGuideWidth: CGFloat? = nil
    var maximumSurfaceTravel: CGFloat? = nil

    /// Compact layouts may put another aid near the centered surface target.
    /// Bound only its visual displacement, preserving both measured angles and
    /// the direction/level status. Independent x/y clamping would distort it.
    nonisolated static func surfaceOffset(for tilt: LevelSurfaceTilt, maximumTravel: CGFloat?) -> CGSize {
        guard tilt.rightDegrees.isFinite, tilt.upDegrees.isFinite else { return .zero }
        let x = CGFloat(min(max(tilt.rightDegrees, -15), 15) / 15 * 24)
        let y = CGFloat(-min(max(tilt.upDegrees, -15), 15) / 15 * 24)
        guard let maximumTravel else { return CGSize(width: x, height: y) }
        guard maximumTravel.isFinite else { return .zero }
        let length = hypot(x, y), bound = max(0, maximumTravel)
        guard length > bound, length > 0 else { return CGSize(width: x, height: y) }
        let scale = bound / length
        return CGSize(width: x * scale, height: y * scale)
    }

    var body: some View {
        GeometryReader { proxy in
            let roll = state?.rollDegrees ?? 0
            let isLevel = state?.zone == .level
            let isAvailable = state?.isProducingReadings == true && state?.zone != .unavailable
            ZStack {
                if isAvailable, let tilt = state?.surfaceTilt {
                    // Screen-relative gravity gives a stable bubble even though
                    // horizon roll is undefined while looking straight up/down.
                    Circle().stroke(.white.opacity(0.55), lineWidth: 1)
                        .frame(width: 44, height: 44)
                    Rectangle().fill(.white.opacity(0.65)).frame(width: 10, height: 1)
                    Rectangle().fill(.white.opacity(0.65)).frame(width: 1, height: 10)
                    Circle().stroke(isLevel ? Color.green : Color.white.opacity(0.85), lineWidth: 2)
                        .frame(width: 20, height: 20)
                        .offset(Self.surfaceOffset(for: tilt, maximumTravel: maximumSurfaceTravel))
                } else if isAvailable {
                    Rectangle()
                        .fill(isLevel ? Color.green : Color.white.opacity(0.7))
                        .frame(width: min(min(proxy.size.width * 0.5, 180), maximumGuideWidth ?? .infinity), height: 1)
                        .rotationEffect(Angle(degrees: roll))
                        .opacity(isLevel ? 1 : 0.6)
                    if isLevel {
                        Rectangle().fill(Color.green).frame(width: 2, height: 10)
                    }
                } else {
                    Text("Level unavailable")
                        .font(.caption2)
                        .foregroundStyle(.white.opacity(0.8))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(state?.surfaceTilt == nil ? "Camera level" : "Surface level")
            .accessibilityValue(state?.statusLabel ?? "Level unavailable")
        }
    }
}

nonisolated private func overlayMaskImage(_ mask: [UInt8], width: Int, height: Int, green: Bool = false) -> CGImage? {
    guard width > 0, height > 0, width <= 640, height <= 640, mask.count == width * height else { return nil }
    var rgba = [UInt8](repeating: 0, count: mask.count * 4)
    rgba.withUnsafeMutableBufferPointer { out in
        guard let start = out.baseAddress else { return }
        start.withMemoryRebound(to: UInt32.self, capacity: mask.count) { destination in
            mask.withUnsafeBufferPointer { source in
                guard let bytes = source.baseAddress else { return }
                let color: UInt32 = green ? 0xFF00FF00 : 0xFFFFFFFF
                for i in 0..<mask.count { destination.advanced(by: i).pointee = bytes.advanced(by: i).pointee == 0 ? 0 : color }
            }
        }
    }
    return CGImage.rgbaDisplayImage(bytes: rgba, width: width, height: height)
}

struct MaskOverlay: View {
    let mask: [UInt8]
    let width: Int
    let height: Int
    let color: Color
    var preparedImage: CGImage? = nil
    var body: some View {
        if let image = preparedImage ?? overlayMaskImage(mask, width: width, height: height, green: true) {
            Image(decorative: image, scale: 1).resizable().interpolation(.high)
        }
    }
}

struct ZebraOverlay: View {
    let mask: [UInt8]
    let width: Int
    let height: Int
    var preparedImage: CGImage? = nil
    var body: some View {
        if let image = preparedImage ?? overlayMaskImage(mask, width: width, height: height) {
            Canvas { context, size in
                context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(.white.opacity(0.45)))
                var stripes = Path()
                for x in stride(from: -size.height, through: size.width, by: 12) {
                    stripes.move(to: CGPoint(x: x, y: size.height))
                    stripes.addLine(to: CGPoint(x: x + size.height, y: 0))
                }
                context.stroke(stripes, with: .color(.black.opacity(0.8)), lineWidth: 5)
            }
            .mask { Image(decorative: image, scale: 1).resizable().interpolation(.high) }
            .allowsHitTesting(false)
        }
    }
}

struct LoupeOverlay: View {
    let snapshot: LoupeSnapshot
    let label: String
    var displayScale: CGFloat = 1
    @State private var presentation = PreviewLoupePresentation()

    var body: some View {
        VStack(spacing: 2) {
            TimelineView(.periodic(from: .now, by: 1.0 / 30.0)) { timeline in
                ZStack {
                    Color.black
                    if let prepared = presentation.prepared,
                       prepared.configuration == snapshot.configurationGeneration,
                       prepared.layout == snapshot.geometryGeneration,
                       prepared.magnification == snapshot.magnification,
                       prepared.sampledCenter == snapshot.sampledCenter {
                        Image(decorative: prepared.image, scale: 1)
                            .resizable().interpolation(.high).aspectRatio(contentMode: .fill)
                            .opacity(PreviewAidFreshness.displayOpacity(capturedAt: prepared.capturedAt, now: timeline.date))
                    }
                }
            }
            .frame(width: 112 * displayScale, height: 96 * displayScale)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.white.opacity(0.6), lineWidth: 1))

            Text(label)
                .font(.caption2)
                // This display-only annotation stays inside the compact aid;
                // its full wording remains on the loupe's accessible element.
                .dynamicTypeSize(...(displayScale < 1 ? DynamicTypeSize.large : .xxxLarge))
                .padding(.horizontal, 4)
                .background(.black.opacity(0.6), in: Capsule())
                .foregroundStyle(.white)
        }
        .onChange(of: LoupePresentationIdentity(snapshot), initial: true) { _, _ in presentation.submit(snapshot) }
        .onDisappear { presentation.invalidate() }
        .accessibilityLabel("Focus loupe, \(label). Display magnification only; the camera zoom is unchanged.")
    }
}

private struct LoupePresentationIdentity: Equatable {
    let capturedAt: Date
    let configuration: ConfigurationGeneration
    let layout: UInt64
    let magnification: Double
    let sampledCenter: NormalizedDevicePoint?
    init(_ snapshot: LoupeSnapshot) {
        capturedAt = snapshot.mappedAtUTC; configuration = snapshot.configurationGeneration
        layout = snapshot.geometryGeneration; magnification = snapshot.magnification
        sampledCenter = snapshot.sampledCenter
    }
}

/// Immutable providers cross the actor boundary only after construction, as for
/// masks. Repainting the SwiftUI overlay never copies its RGBA plane again.
struct PreparedPreviewLoupe: @unchecked Sendable {
    let image: CGImage
    let capturedAt: Date
    let configuration: ConfigurationGeneration
    let layout: UInt64
    let magnification: Double
    var sampledCenter: NormalizedDevicePoint? = nil
}

@MainActor @Observable final class PreviewLoupePresentation {
    private(set) var prepared: PreparedPreviewLoupe?
    private var pending: LoupeSnapshot?
    private var latestIdentity: LoupePresentationIdentity?
    private var worker: Task<Void, Never>?
    private var revision: UInt64 = 0
    private let render: @Sendable (LoupeSnapshot) async -> PreparedPreviewLoupe?
    private let now: @Sendable () -> Date
    init() { self.render = Self.renderOffMain; self.now = Date.init }
    init(render: @escaping @Sendable (LoupeSnapshot) async -> PreparedPreviewLoupe?,
         now: @escaping @Sendable () -> Date = Date.init) { self.render = render; self.now = now }
    nonisolated private static func renderOffMain(_ snapshot: LoupeSnapshot) async -> PreparedPreviewLoupe? {
        await PreviewMaskImageRenderer.shared.render(snapshot)
    }
    func submit(_ snapshot: LoupeSnapshot) {
        pending = snapshot
        latestIdentity = LoupePresentationIdentity(snapshot)
        guard worker == nil else { return }
        let pass = revision
        worker = Task { [weak self] in
            defer { if let self, self.revision == pass { self.worker = nil } }
            while let self, self.revision == pass, let sample = self.pending {
                self.pending = nil
                let rendered = await self.render(sample)
                guard !Task.isCancelled, self.revision == pass else { return }
                if let rendered, self.latestIdentity?.configuration == rendered.configuration,
                   self.latestIdentity?.layout == rendered.layout,
                   self.latestIdentity?.magnification == rendered.magnification,
                   self.latestIdentity?.sampledCenter == rendered.sampledCenter,
                   PreviewAidFreshness.displayOpacity(capturedAt: rendered.capturedAt, now: self.now()) > 0 {
                    self.prepared = rendered
                }
            }
        }
    }
    func invalidate() {
        revision &+= 1; worker?.cancel(); worker = nil; pending = nil; prepared = nil; latestIdentity = nil
    }
}

struct HistogramOverlay: View {
    let snapshot: HistogramSnapshot

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(snapshot.rgb == nil ? "Luma" : "RGB")
                .font(.system(size: 9)).foregroundStyle(.white.opacity(0.8))
            Canvas { context, size in
                if let rgb = snapshot.rgb, rgb.sampleCount > 0,
                   rgb.red.count == 256, rgb.green.count == 256, rgb.blue.count == 256 {
                    // Shared scale preserves the relationship between the channels.
                    let peak = max(rgb.red.max() ?? 0, rgb.green.max() ?? 0, rgb.blue.max() ?? 0)
                    context.blendMode = .plusLighter
                    for (bins, color) in [(rgb.red, Color.red), (rgb.green, Color.green), (rgb.blue, Color.blue)] {
                        context.fill(Self.shape(bins, peak: peak, size: size), with: .color(color.opacity(0.8)))
                    }
                } else if snapshot.sampleCount > 0 {
                    context.fill(Self.shape(snapshot.bins, peak: snapshot.bins.max() ?? 0, size: size),
                                 with: .color(.white.opacity(0.6)))
                }
            }
        }
        .padding(6)
        .background(.black.opacity(0.45), in: RoundedRectangle(cornerRadius: 8))
        .accessibilityLabel(snapshot.rgb == nil ? "Preview luminance histogram, RGB unavailable" : "Preview red, green and blue histogram")
        .accessibilityValue(snapshot.detailSummary)
    }

    private static func shape(_ bins: [UInt32], peak: UInt32, size: CGSize) -> Path {
        guard peak > 0, !bins.isEmpty else { return Path() }
        var path = Path()
        path.move(to: CGPoint(x: 0, y: size.height))
        for (index, value) in bins.enumerated() {
            let x = size.width * CGFloat(index) / CGFloat(max(1, bins.count - 1))
            path.addLine(to: CGPoint(x: x, y: size.height * (1 - CGFloat(value) / CGFloat(peak))))
        }
        path.addLine(to: CGPoint(x: size.width, y: size.height)); path.closeSubpath()
        return path
    }
}

struct ExposureMeterOverlay: View {
    let offsetEV: Double?
    var height: CGFloat = 112
    var body: some View {
        Canvas { context, size in
            let top: CGFloat = 8, travel = size.height-16
            for third in ExposureMeterScale.thirds {
                let y = top+CGFloat(9-third)/18*travel
                let width: CGFloat = third == 0 ? 14 : third%3 == 0 ? 10 : 5
                let tick = CGRect(x:3,y:y-(third == 0 ? 1 : 0.5),width:width,height:third == 0 ? 2 : 1)
                context.fill(Path(tick),with:.color(.white.opacity(third == 0 ? 0.95 : third%3 == 0 ? 0.7 : 0.38)))
            }
            if let unit = ExposureMeterScale.unitPosition(offsetEV) {
                let y = top+CGFloat(unit)*travel
                let nearZero = abs(offsetEV ?? 0)<0.25
                var pointer = Path()
                pointer.move(to:CGPoint(x:19,y:y)); pointer.addLine(to:CGPoint(x:25,y:y-3))
                pointer.addLine(to:CGPoint(x:25,y:y+3)); pointer.closeSubpath()
                context.fill(pointer,with:.color(nearZero ? .green : .white))
                if ExposureMeterScale.isClipped(offsetEV) {
                    context.fill(Path(CGRect(x:20,y:y-5,width:2,height:10)),with:.color(.yellow))
                }
            }
        }
        .frame(width:28,height:height)
        .background(.black.opacity(0.30),in:Capsule())
        .accessibilityElement(children:.ignore)
        .accessibilityLabel("Exposure meter")
        .accessibilityValue(offsetEV.flatMap { $0.isFinite ? String(format:"%+.2f EV",$0) : nil } ?? "Unknown")
    }
}

/// Measures actual SwiftUI content, including Dynamic Type. Keep EV centered
/// whenever it fits; compact rows give it the remaining leading space instead
/// of overlaying the separate format button's hit region.
struct CameraHeaderLayout: Layout {
    struct Frames { let leading: CGRect; let center: CGRect; let trailing: CGRect }
    var leadingMinimumWidth: CGFloat = 44
    var centerMinimumWidth: CGFloat = 44

    nonisolated static func frames(in bounds: CGRect, leading: CGSize, center: CGSize, trailing: CGSize,
                                  leadingMinimumWidth: CGFloat = 44, centerMinimumWidth: CGFloat = 44) -> Frames {
        let gap: CGFloat = 8
        let leadingMinimum: CGFloat = leading.width > 0 ? min(leading.width, max(44, leadingMinimumWidth)) : 0
        let centerMinimum: CGFloat = center.width > 0 ? max(44, centerMinimumWidth) : 0
        let trailingMinimum: CGFloat = trailing.width > 0 ? 44 : 0
        let gaps = (leadingMinimum > 0 ? gap : 0) + (trailingMinimum > 0 ? gap : 0)
        let centerDesired = min(center.width,
            max(centerMinimum, bounds.width - leadingMinimum - trailingMinimum - gaps))
        let trailingWidth = min(trailing.width,
            max(trailingMinimum, bounds.width - leadingMinimum - centerDesired - gaps))
        let leadingWidth = min(leading.width,
            max(leadingMinimum, bounds.width - trailingWidth - centerDesired - gaps))
        let left = bounds.minX + leadingWidth + (leadingWidth > 0 ? gap : 0)
        let right = bounds.maxX - trailingWidth - (trailingWidth > 0 ? gap : 0)
        let width = min(center.width, max(0, right - left))
        let centeredX = bounds.midX - width / 2
        let centerX = centeredX >= left && centeredX + width <= right ? centeredX : left
        return Frames(leading: CGRect(x: bounds.minX, y: bounds.minY, width: leadingWidth, height: bounds.height),
            center: CGRect(x: centerX, y: bounds.minY, width: width, height: bounds.height),
            trailing: CGRect(x: bounds.maxX - trailingWidth, y: bounds.minY, width: trailingWidth, height: bounds.height))
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let sizes = subviews.map { $0.sizeThatFits(.unspecified) }
        return CGSize(width: proposal.width ?? sizes.reduce(16) { $0 + $1.width },
            height: max(44, sizes.map(\.height).max() ?? 0))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard subviews.count == 3 else { return }
        let frames = Self.frames(in: bounds, leading: subviews[0].sizeThatFits(.unspecified),
            center: subviews[1].sizeThatFits(.unspecified), trailing: subviews[2].sizeThatFits(.unspecified),
            leadingMinimumWidth: leadingMinimumWidth, centerMinimumWidth: centerMinimumWidth)
        for (view, frame) in zip(subviews, [frames.leading, frames.center, frames.trailing]) {
            view.place(at: CGPoint(x: frame.midX, y: frame.midY), anchor: .center,
                proposal: ProposedViewSize(width: frame.width, height: frame.height))
        }
    }
}

/// Centered EV and top-right capture format selection; grid belongs only in Tools.
struct CameraTopRow: View {
    @Environment(AppEnvironment.self) private var app
    var isCompact = false

    var body: some View {
        GeometryReader { proxy in
            let imageWidth = proxy.size.width + CameraPreviewChromeLayout.headerInset * 2
            let hasHistogram = app.camera.map { CameraPreviewChromeLayout.showsHistogram(camera: $0, inWidth: imageWidth) } ?? false
            let histogram = CameraPreviewChromeLayout.histogramFrame(inWidth: imageWidth)
            let reserved = max(0, histogram.maxX - CameraPreviewChromeLayout.headerInset)
            CameraHeaderLayout(leadingMinimumWidth: hasHistogram ? reserved : 44, centerMinimumWidth: hasHistogram ? 64 : 44) {
                HStack(spacing: 0) {
                    if hasHistogram {
                        Color.clear.frame(width: reserved, height: 44).accessibilityHidden(true)
                    } else if let camera = app.camera, camera.pendingOriginalCount > 0 {
                        Button { camera.showPendingRecovery() } label: {
                            ViewThatFits(in: .horizontal) {
                                Label("\(camera.pendingOriginalCount) pending", systemImage: "tray.full")
                                    .font(.caption).lineLimit(1)
                                HStack(spacing: 4) {
                                    Image(systemName: "tray.full").font(.system(size: 12))
                                    Text("\(camera.pendingOriginalCount)").font(.system(size: 11))
                                        .lineLimit(1).minimumScaleFactor(0.5)
                                }
                            }
                            .foregroundStyle(.yellow).frame(minWidth: 44, minHeight: 44)
                        }
                        .accessibilityLabel("Recover \(camera.pendingOriginalCount) pending originals")
                        .accessibilityHint("Retry saving or export the original photo.")
                    }
                }
                .frame(maxWidth: .infinity, minHeight: 44, maxHeight: 44)
                .contentShape(Rectangle()).clipped()
                .allowsHitTesting(!hasHistogram)
                HStack(spacing: 0) {
                    if let camera = app.camera {
                        Button {
                            camera.openPanel = camera.openPanel == .exposureBias ? nil : .exposureBias
                        } label: {
                            Text(ExposureFormatting.bias(camera.biasEV))
                                .font(.caption.monospacedDigit()).lineLimit(1).minimumScaleFactor(0.5)
                                .padding(.horizontal, 10)
                                .frame(minWidth: 44, minHeight: 44).background(.black.opacity(0.55), in: Capsule())
                        }
                        .disabled(!camera.isBiasAvailable || !camera.exposureLimits.isValid)
                        .accessibilityIdentifier("exposureCompensation")
                        .accessibilityLabel("Exposure compensation")
                        .accessibilityHint("Adjusts automatic exposure. In full manual, change shutter or ISO.")
                    }
                }
                .frame(maxWidth: .infinity, minHeight: 44, maxHeight: 44)
                .contentShape(Rectangle()).clipped()
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 8) {
                        captureFormatButton
                        if let text = app.camera?.timerBadgeText {
                            Text(text).font(.system(size: 11, weight: .semibold))
                                .padding(.horizontal, 6).padding(.vertical, 3)
                                .background(.yellow.opacity(0.85), in: Capsule()).foregroundStyle(.black)
                                .fixedSize(horizontal: true, vertical: false)
                                .accessibilityLabel("Timer active").accessibilityValue(text)
                        }
                    }
                    // Countdown feedback and the format accessibility hint retain
                    // timer state. A badge must not compress a real control.
                    captureFormatButton
                }
                .frame(maxWidth: .infinity, minHeight: 44, maxHeight: 44, alignment: .trailing)
                .contentShape(Rectangle()).clipped()
            }
            .frame(minHeight: isCompact ? 44 : nil)
            .foregroundStyle(.white)
        }
        .frame(height: CameraPreviewChromeLayout.headerHeight)
    }

    @ViewBuilder private var captureFormatButton: some View {
        if let camera = app.camera {
            Menu {
                Button {
                    camera.selectCaptureFormat(.bayerDNG)
                } label: {
                    Label("RAW", systemImage: camera.effectiveCaptureFileFormat == .bayerDNG ? "checkmark" : "camera")
                }
                .disabled(camera.capability.bayerCaptureSupported.value != true)
                Button {
                    camera.selectCaptureFormat(.jpeg)
                } label: {
                    Label("JPEG", systemImage: camera.effectiveCaptureFileFormat == .jpeg ? "checkmark" : "photo")
                }
                .disabled(!camera.capability.jpegSupported || camera.capability.jpegMaximumDimensions == nil)
                if camera.capability.frontHEIFSupported && camera.capability.selectedCameraKind == .front
                    && camera.capability.bayerCaptureSupported.value != true {
                    Button {
                        camera.selectCaptureFormat(.frontHEIF)
                    } label: {
                        Label("HEIF · Front", systemImage: camera.effectiveCaptureFileFormat == .frontHEIF ? "checkmark" : "person.crop.square")
                    }
                }
            } label: {
                Text(camera.captureFormatLabel)
                    .font(.system(size: isCompact ? 11 : 12, weight: .semibold))
                    .lineLimit(1).minimumScaleFactor(0.8)
                    .padding(.horizontal, 8)
                    .frame(minWidth: 44, minHeight: 44)
                    .background(.black.opacity(0.55), in: Capsule())
                    .foregroundStyle(.white)
            }
            .disabled(!camera.isCaptureFormatSelectionEnabled)
            .accessibilityIdentifier("captureFormatSelector")
            .accessibilityLabel("Capture format")
            .accessibilityValue(camera.captureFormatAccessibilityLabel)
            .accessibilityHint("Choose the format for new photos." + (camera.timerBadgeText.map { " \($0) is active." } ?? ""))
        }
    }
}

/// The compact readout row. Variable-aperture lenses add one control without
/// changing the reserved row height or moving the shutter.
struct CameraReadoutRow: View {
    @Environment(AppEnvironment.self) private var app

    var body: some View {
        if let camera = app.camera {
            HStack(spacing: camera.isApertureAvailable ? 8 : 12) {
                ForEach(CameraPanel.allCases.filter {
                    $0 != .exposureBias && ($0 != .aperture || camera.isApertureAvailable)
                }) { panel in
                    ReadoutButton(camera: camera, panel: panel, compactLabels: camera.isApertureAvailable)
                }
            }
            .padding(.horizontal, 16)
        }
    }
}

/// Two-column readout arrangement for the landscape rail.
struct CameraReadoutGrid: View {
    @Environment(AppEnvironment.self) private var app

    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: app.camera?.isApertureAvailable == true ? 8 : 16) {
                if let camera = app.camera {
                    ReadoutButton(camera: camera, panel: .shutter, compactLabels: camera.isApertureAvailable)
                    ReadoutButton(camera: camera, panel: .iso, compactLabels: camera.isApertureAvailable)
                    if camera.isApertureAvailable {
                        ReadoutButton(camera: camera, panel: .aperture, compactLabels: true)
                    }
                }
            }
            HStack(spacing: 16) {
                if let camera = app.camera {
                    ReadoutButton(camera: camera, panel: .focus)
                    ReadoutButton(camera: camera, panel: .whiteBalance)
                }
            }
        }
        .padding(.horizontal, 12)
    }
}

private struct ReadoutButton: View {
    @Environment(AppEnvironment.self) private var app
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let camera: CameraViewModel
    let panel: CameraPanel
    var compactLabels = false

    var body: some View {
        Button {
            // Tapping the same selected readout closes its panel. Panel
            // visibility is never capture state.
            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.18)) { camera.openPanel = panel }
        } label: {
            VStack(spacing: 5) {
                Text(shortLabel)
                    .font(.system(size: compactLabels ? 10 : 11, weight: .medium))
                    .foregroundStyle(.white.opacity(0.7))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                Text(valueLabel)
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .foregroundStyle(camera.openPanel == panel ? .yellow : .white)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
            .frame(minWidth: compactLabels ? 44 : 56, maxWidth: .infinity, minHeight: 44)
            .background(camera.openPanel == panel ? .white.opacity(0.08) : .clear, in: RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(CameraPressStyle())
        .accessibilityLabel(panel.title)
        .accessibilityValue(accessibilityValue)
        .accessibilityHint("Selects the persistent adjustment controls above the shutter.")
        .disabled(camera.isCaptureBusy)
        .accessibilityAddTraits(camera.openPanel == panel ? [.isSelected] : [])
        .simultaneousGesture(LongPressGesture(minimumDuration: 0.5).onEnded { _ in
            if panel == .focus { camera.lockFocus() }
        })
        .accessibilityActions {
            if panel == .focus { Button("Lock autofocus") { camera.lockFocus() } }
        }
    }

    private var shortLabel: String {
        switch panel {
        case .shutter: return camera.isShutterManual ? "Shutter · M" : compactLabels ? "Shutter · A" : "Shutter · Auto"
        case .iso: return camera.isISOManual ? "ISO · M" : compactLabels ? "ISO · A" : "ISO · Auto"
        case .aperture:
            return compactLabels ? (camera.isApertureManual ? "ƒ · M" : "ƒ · A")
                : (camera.isApertureManual ? "Aperture · M" : "Aperture · Auto")
        case .focus: return "Focus"
        case .whiteBalance: return "WB"
        case .exposureBias: return "EV"
        }
    }

    private var valueLabel: String {
        switch panel {
        case .shutter: return camera.shutterReadout.replacingOccurrences(of: "Auto · ", with: "")
        case .iso: return camera.isoReadout.replacingOccurrences(of: "Auto · ", with: "")
        case .aperture: return camera.apertureReadout
        case .focus: return camera.focusReadout
        case .whiteBalance: return camera.whiteBalanceReadout
        case .exposureBias: return ExposureFormatting.bias(camera.biasEV)
        }
    }

    private var accessibilityValue: String {
        switch panel {
        case .shutter:
            return camera.isShutterManual
                ? "Manual, \(camera.shutterReadout)"
                : "Automatic, currently \(camera.shutterReadout)"
        case .iso:
            return camera.isISOManual
                ? "Manual, ISO \(camera.isoReadout)"
                : "Automatic, currently ISO \(camera.isoReadout)"
        case .aperture:
            return camera.isApertureManual
                ? "Manual, \(camera.apertureReadout)"
                : "Automatic, currently \(camera.apertureReadout)"
        case .focus:
            switch camera.focus.mode {
            case .manual: return "Manual, position \(camera.focusReadout)"
            case .continuousAuto: return "Continuous autofocus"
            case .lockedAuto: return "Autofocus locked"
            }
        case .exposureBias: return ExposureFormatting.bias(camera.biasEV)
        case .whiteBalance:
            return camera.whiteBalance.mode == .manual
                ? "Manual, \(camera.whiteBalanceReadout)"
                : "Automatic white balance"
        }
    }
}

/// The lower camera area: sequence status, centered shutter, library thumbnail
/// and the manual-adjustment shortcut.
struct CameraShutterRail: View {
    @Environment(AppEnvironment.self) private var app
    var isLandscape = false
    var compactFeedback = false

    var body: some View {
        VStack(spacing: isLandscape ? 4 : 0) {
            ZStack {
                ShutterButton()
                HStack {
                    CameraGalleryButton()
                        .padding(.leading, isLandscape ? 16 : 0)
                    Spacer(minLength: 0)
                    if isLandscape {
                        VStack(spacing: 4) { rotateAction; toolsAction }
                    } else {
                        HStack(spacing: 4) { rotateAction; toolsAction }
                    }
                }
            }
            .frame(height: isLandscape ? 92 : 76)

            if let camera = app.camera {
                CameraShootingModeFooter(camera: camera, compact: isLandscape || compactFeedback)
            }

        }
        .foregroundStyle(.white)
    }
    private var rotateAction: some View {
        Button { Task { await app.camera?.rotateCamera() } } label: {
            Image(systemName: "arrow.triangle.2.circlepath.camera")
                .frame(width: 44, height: 44)
        }
        .buttonStyle(CameraPressStyle())
        .disabled(!(app.camera?.canSwitchCamera ?? false))
        .accessibilityLabel(app.camera?.capability.selectedCameraKind == .front ? "Switch to rear camera" : "Switch to front camera")
        .accessibilityIdentifier("rotateCamera")
    }
    private var toolsAction: some View {
        Button { app.camera?.presentedCameraSheet = .tools } label: {
            Image(systemName: "slider.horizontal.3").frame(width: 44, height: 44)
        }
        .accessibilityLabel("Camera tools")
    }
}

struct ShutterButton: View {
    @Environment(AppEnvironment.self) private var app
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var shutterHaptic: UIImpactFeedbackGenerator?

    var body: some View {
        Button {
            guard let camera = app.camera else { return }
            if camera.isSequenceRunning { camera.cancelSequence(); return }
            guard camera.captureSpeed == .single, camera.isShutterEnabled else { return }
            Task { await camera.activateShutter() }
        } label: {
            ZStack {
                Circle().stroke(Color.white, lineWidth: 3).frame(width: 72, height: 72)
                Group {
                    if app.camera?.isSequenceRunning == true { RoundedRectangle(cornerRadius: 5).fill(.red).frame(width: 28, height: 28) }
                    else { Circle().fill(Color.white).frame(width: 58, height: 58) }
                }
                    .scaleEffect(app.camera?.isCapturing == true ? 0.82 : 1)
                    .animation(reduceMotion ? nil : .easeOut(duration: 0.16), value: app.camera?.isCapturing)
            }
        }
        .frame(width: 76, height: 76)
        .buttonStyle(CameraPressStyle())
        .overlay {
            if let camera = app.camera, camera.captureSpeed != .single {
                ContinuousShutterSurface(camera: camera).accessibilityHidden(true)
            }
        }
        .disabled(!(app.camera?.isShutterEnabled == true || app.camera?.isSequenceRunning == true || app.camera?.isContinuousCaptureHeld == true))
        .opacity(app.camera?.isShutterEnabled == true || app.camera?.isCaptureBusy == true || app.camera?.isContinuousCaptureHeld == true ? 1 : 0.45)
        .accessibilityLabel(app.camera?.isSequenceRunning == true ? "Stop sequence" : "Shutter")
        .accessibilityIdentifier("captureShutter")
        .accessibilityHint(accessibilityHint)
        .accessibilityAction {
            guard let camera = app.camera else { return }
            if camera.isSequenceRunning { camera.cancelSequence() }
            else { Task { await camera.activateShutter() } }
        }
        .onAppear {
            if shutterHaptic == nil { shutterHaptic = UIImpactFeedbackGenerator(style: .medium) }
            shutterHaptic?.prepare()
        }
        .onDisappear { shutterHaptic = nil }
        .onChange(of: app.camera?.shutterPulse) { _, pulse in
            guard let pulse, pulse > 0 else { return }
            #if DEBUG
            let began = ProcessInfo.processInfo.systemUptime
            defer { print("TruongCam timing shutter-haptic=\(Int((ProcessInfo.processInfo.systemUptime - began) * 1000))ms") }
            #endif
            shutterHaptic?.impactOccurred()
            shutterHaptic?.prepare()
        }
    }

    private var accessibilityHint: String {
        guard let camera = app.camera else { return "Camera is not ready." }
        if camera.captureSpeed != .single { return "Hold for continuous photos at up to \(camera.captureSpeed.displayName). Lift to stop. Accessibility activation takes one photo." }
        if camera.isCapturing { return "A capture is in progress." }
        if let timer = camera.timerCountdownSeconds { return "Counting down, \(timer) seconds remaining." }
        if camera.isExposureBracketActive { return "Captures \(camera.sequencePreferences.exposureBracketCount) separate RAW photos at bracketed exposures." }
        switch camera.effectiveCaptureFileFormat {
        case .jpeg: return "Captures one JPEG photo and saves it to the selected folder. No RAW original is taken."
        case .frontHEIF: return "Captures one front HEIF photo and saves it to the selected folder."
        case .bayerDNG: return "Captures one RAW photo and saves it to the selected folder."
        }
    }
}

/// Physical cameras only; selecting a pill never applies digital zoom.
struct PhysicalLensSelector: View {
    @Environment(AppEnvironment.self) private var app
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Namespace private var selection
    var body: some View {
        if let camera = app.camera, !camera.lensButtons.isEmpty {
            let highlighted = camera.isSwitchingLens ? camera.composition.preferredLens : camera.capability.selectedCameraKind
            HStack(spacing: 2) {
                ForEach(camera.lensButtons, id: \.kind) { lens in
                    Button { Task { await camera.selectLens(lens.kind) } } label: {
                        Text(lens.label).font(.caption.weight(.semibold)).monospacedDigit()
                            .lineLimit(1).minimumScaleFactor(0.65)
                            .frame(width: 48, height: 44)
                    }
                    .foregroundStyle(lens.kind == highlighted ? .black : .white)
                    .background {
                        if lens.kind == highlighted {
                            Capsule().fill(.white).matchedGeometryEffect(id: "lens", in: selection)
                        }
                    }
                    .buttonStyle(CameraPressStyle())
                    .disabled(camera.isSwitchingLens)
                    .accessibilityLabel(lens.accessibility)
                    .accessibilityValue(camera.isSwitchingLens && lens.kind == highlighted ? "Switching" : lens.isSelected ? "Selected" : "")
                    .accessibilityAddTraits(lens.isSelected ? .isSelected : [])
                }
            }.padding(2).background(.black.opacity(0.55), in: Capsule())
                .animation(reduceMotion ? nil : .spring(response: 0.3, dampingFraction: 0.88), value: highlighted)
        }
    }
}

/// Small, interruptible feedback. It never delays a button action or animates
/// the measured camera values, and honors the system Reduce Motion setting.
struct CameraPressStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.95 : 1)
            .opacity(configuration.isPressed ? 0.78 : 1)
            .animation(reduceMotion ? nil : .spring(response: 0.2, dampingFraction: 0.85), value: configuration.isPressed)
    }
}

/// The reserved footer identifies enabled shooting modes only. Capture feedback
/// stays visual/haptic; failures and recovery retain their dedicated controls.
struct CameraShootingModeFooter: View {
    let camera: CameraViewModel
    let compact: Bool

    var modeLabel: String? {
        var modes: [String] = []
        if camera.captureSpeed != .single { modes.append("Burst · \(camera.captureSpeed.displayName)") }
        else {
            switch camera.activeShutterMode {
            case .single: break
            case .exposureBracket: modes.append("Exposure bracket")
            case .focusBracket: modes.append("Focus bracket")
            case .interval: modes.append("Interval")
            }
        }
        if let seconds = camera.timerSeconds { modes.append("Timer · \(seconds)s") }
        return modes.isEmpty ? nil : modes.joined(separator: " · ")
    }

    var body: some View {
        Group {
            if let modeLabel { Text(modeLabel) }
            else { Color.clear.accessibilityHidden(true) }
        }
        .font(.caption2).foregroundStyle(.white.opacity(0.7))
        .lineLimit(1).minimumScaleFactor(0.8).frame(height: compact ? 20 : 44)
        .accessibilityIdentifier("cameraShootingMode")
    }
}

/// Expiry keeps a stalled/late result from remaining painted over moving video.
/// Immutable images, constructed once per sample on the renderer actor, never per UI tick.
/// CGImages have immutable providers and are only read after construction.
struct PreparedPreviewMasks: @unchecked Sendable {
    let peaking: CGImage?
    let zebras: CGImage?
    let capturedAt: Date
    let configuration: ConfigurationGeneration
    let layout: UInt64
}

actor PreviewMaskImageRenderer {
    static let shared = PreviewMaskImageRenderer()
    private let makeLoupeImage: @Sendable (LoupeSnapshot) -> CGImage?
    init(makeLoupeImage: @escaping @Sendable (LoupeSnapshot) -> CGImage? = { $0.makeImage() }) {
        self.makeLoupeImage = makeLoupeImage
    }
    func render(_ snapshot: LoupeSnapshot) -> PreparedPreviewLoupe? {
        guard !Task.isCancelled, snapshot.width > 0, snapshot.height > 0,
              snapshot.width <= LoupeRenderer.maxColorOutputLongEdge,
              snapshot.height <= LoupeRenderer.maxColorOutputLongEdge,
              snapshot.rgbaBytes.count == snapshot.width * snapshot.height * 4,
              let image = makeLoupeImage(snapshot), !Task.isCancelled else { return nil }
        return PreparedPreviewLoupe(image: image, capturedAt: snapshot.mappedAtUTC,
            configuration: snapshot.configurationGeneration, layout: snapshot.geometryGeneration,
            magnification: snapshot.magnification, sampledCenter: snapshot.sampledCenter)
    }
    func render(_ snapshot: MaskSnapshot) -> PreparedPreviewMasks? {
        guard !Task.isCancelled else { return nil }
        let peaking = snapshot.peakingMask.flatMap { overlayMaskImage($0, width: snapshot.width, height: snapshot.height, green: true) }
        let zebras = snapshot.zebraMask.flatMap { overlayMaskImage($0, width: snapshot.width, height: snapshot.height) }
        guard !Task.isCancelled else { return nil }
        return PreparedPreviewMasks(peaking: peaking, zebras: zebras, capturedAt: snapshot.mappedAtUTC,
            configuration: snapshot.configurationGeneration, layout: snapshot.geometryGeneration)
    }
}

/// One render in flight plus the newest pending sample. A newer frame does not
/// cancel a valid render that is about to publish, avoiding perpetual starvation.
@MainActor @Observable final class PreviewMaskPresentation {
    private(set) var prepared: PreparedPreviewMasks?
    private var pending: MaskSnapshot?
    private var latestGeometry: (ConfigurationGeneration, UInt64)?
    private var worker: Task<Void, Never>?
    private var revision: UInt64 = 0
    private let render: @Sendable (MaskSnapshot) async -> PreparedPreviewMasks?
    init() { self.render = Self.renderOffMain }
    init(render: @escaping @Sendable (MaskSnapshot) async -> PreparedPreviewMasks?) { self.render = render }
    nonisolated private static func renderOffMain(_ snapshot: MaskSnapshot) async -> PreparedPreviewMasks? {
        await PreviewMaskImageRenderer.shared.render(snapshot)
    }
    func submit(_ snapshot: MaskSnapshot) {
        pending = snapshot
        latestGeometry = (snapshot.configurationGeneration, snapshot.geometryGeneration)
        guard worker == nil else { return }
        let pass = revision
        worker = Task { [weak self] in
            defer { if let self, self.revision == pass { self.worker = nil } }
            while let self, self.revision == pass, let sample = self.pending {
                self.pending = nil
                let rendered = await self.render(sample)
                guard !Task.isCancelled, self.revision == pass else { return }
                if let rendered, self.latestGeometry?.0 == rendered.configuration,
                   self.latestGeometry?.1 == rendered.layout,
                   PreviewAidFreshness.displayOpacity(capturedAt: rendered.capturedAt, now: Date()) > 0 {
                    self.prepared = rendered
                }
            }
        }
    }
    func invalidate() {
        revision &+= 1; worker?.cancel(); worker = nil; pending = nil; prepared = nil; latestGeometry = nil
    }
}

struct FreshPreviewMaskOverlay: View {
    let snapshot: MaskSnapshot
    let peakingEnabled: Bool
    let zebrasEnabled: Bool
    @State private var presentation = PreviewMaskPresentation()
    var body: some View {
        TimelineView(.periodic(from: .now, by: 1.0 / 30.0)) { timeline in
            if let prepared = presentation.prepared, prepared.configuration == snapshot.configurationGeneration,
               prepared.layout == snapshot.geometryGeneration {
                ZStack {
                    if peakingEnabled, let image = prepared.peaking {
                        MaskOverlay(mask: [], width: snapshot.width, height: snapshot.height, color: .green,
                            preparedImage: image).opacity(0.55)
                    }
                    if zebrasEnabled, let image = prepared.zebras {
                        ZebraOverlay(mask: [], width: snapshot.width, height: snapshot.height, preparedImage: image)
                    }
                }
                .opacity(PreviewAidFreshness.displayOpacity(capturedAt: prepared.capturedAt, now: timeline.date))
            }
        }
        .onChange(of: snapshot.mappedAtUTC, initial: true) { _, _ in presentation.submit(snapshot) }
        .onDisappear { presentation.invalidate() }
    }
}
