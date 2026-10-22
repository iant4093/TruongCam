@preconcurrency import AVFoundation
import Foundation
import CoreGraphics
import CoreVideo

// REVIEW.md C02.
//
// `AVCaptureSession` is not `Sendable`, and an actor's synchronous witness for a
// synchronous protocol requirement is not safely callable from another executor.
// The previous code crossed both boundaries and passed only because
// `@preconcurrency` deferred the check.
//
// This bridge replaces that pattern with one explicit, documented box. It is
// established once through a valid async hop out of the camera actor, holds a
// weak reference so it cannot extend the session's lifetime, and is read by
// UIKit on the main thread only to hand the session to
// `AVCaptureVideoPreviewLayer`. The session is never *mutated* through this type;
// all configuration stays on the camera service's serial queue.

/// Read-only, main-thread display handle for the capture session.
///
/// Ownership invariant for the narrow `@unchecked Sendable`: every read and write
/// of `session` happens while `lock` is held. The stored reference is weak, so no
/// caller can retain the session through this box, and the only permitted
/// operation on the returned object is assigning it to a preview layer's
/// `session` property.
final class PreviewDisplayBridge: @unchecked Sendable {
    let nativeAccessGate = PreviewNativeAccessGate()
    private let lock = NSLock()
    private weak var session: AVCaptureSession?
    private var rotations: CameraRotationAngles?
    private var geometry: PreviewGeometrySnapshot?
    private var frame: PreviewTransitionFrame?
    // Decorative cover only. It never acknowledges the current camera, grants
    // capture, supplies analysis, or survives a session teardown.
    private var coverFrame: (PreviewTransitionFrame, DeviceOrientation)?
    private var latestBufferStamp: (ConfigurationGeneration, UInt64, Double)?
    let currentFrameNotifications = LatestValueBroadcaster<PreviewFrameIdentity>()
    private let currentInstant: @Sendable () -> Double
    /// Updated under lock when owned work is actually enqueued, not when a
    /// callback merely asks for a plan and is subsequently rate/backpressure dropped.
    private var lastFrameInstant: Double = -.infinity
    private var lastFrameGeometry: (ConfigurationGeneration, UInt64)?
    private var photoWorkCount = 0
    private var cameraPreparationCount = 0
    var shouldDeferAnalysisForPhoto: Bool {
        lock.lock(); defer { lock.unlock() }; return photoWorkCount > 0
    }
    /// Independent of native preview access: never holds a UI/graph lease while
    /// a photo processes. Native video acknowledgement remains live.
    func prioritizePhotoWork() -> PreviewAnalysisPriorityLease {
        lock.lock(); photoWorkCount += 1; lock.unlock()
        return PreviewAnalysisPriorityLease { [weak self] in
            guard let self else { return }
            self.lock.lock(); self.photoWorkCount -= 1; self.lock.unlock()
        }
    }

    var shouldDeferAnalysisForCameraPreparation: Bool {
        lock.lock(); defer { lock.unlock() }; return cameraPreparationCount > 0
    }
    /// Preparation owns optional CPU work separately from native graph reads.
    /// In particular, a copied outgoing frame must not start expensive math
    /// while permission/queue hops still leave its old generation unchanged.
    /// Ordinary no-op control reads do not acquire this priority.
    func prioritizeCameraPreparation() -> PreviewAnalysisPriorityLease {
        lock.lock(); cameraPreparationCount += 1; lock.unlock()
        return PreviewAnalysisPriorityLease { [weak self] in
            guard let self else { return }
            self.lock.lock(); self.cameraPreparationCount -= 1; self.lock.unlock()
        }
    }

    func setGeometry(_ geometry: PreviewGeometrySnapshot?) {
        lock.lock(); self.geometry = geometry
        if geometry == nil { frame = nil; latestBufferStamp = nil }
        lock.unlock()
    }

    /// Called exclusively from the existing analysis queue, never MainActor.
    /// The pixel buffer remains borrowed inside its sample callback; no buffer
    /// or original is retained. This disposable image is used only while switching.
    /// Acknowledgement never reads or locks the native pixel buffer. The optional
    /// still is derived later from the already-owned analysis planes.
    func acknowledgePreviewBuffer(configuration: ConfigurationGeneration, layout: UInt64) -> PreviewTransitionPlan? {
        let instant = currentInstant()
        lock.lock()
        let geometry = self.geometry
        guard let geometry, geometry.configurationGeneration == configuration,
              geometry.layoutGeneration == layout else { lock.unlock(); return nil }
        let firstCurrentFrame = latestBufferStamp?.0 != configuration || latestBufferStamp?.1 != layout
        latestBufferStamp = (configuration, layout, instant)
        let needsFirstStill = lastFrameGeometry?.0 != configuration || lastFrameGeometry?.1 != layout
        let canRender = needsFirstStill || instant - lastFrameInstant >= 0.5
        lock.unlock()
        if firstCurrentFrame {
            currentFrameNotifications.send(PreviewFrameIdentity(generation: configuration, layout: layout))
        }
        guard canRender else { return nil }
        return PreviewTransitionPlan(geometry: geometry, instant: instant)
    }

    /// Synchronous native diagnostic seam; the production video handler uses only
    /// acknowledgement plus its one owned-plane copy.
    func readPreviewBuffer(_ buffer: CVPixelBuffer, configuration: ConfigurationGeneration, layout: UInt64) -> PendingPreviewTransition? {
        guard let plan = acknowledgePreviewBuffer(configuration: configuration, layout: layout),
              let samples = Self.transitionSamples(buffer) else { return nil }
        return PendingPreviewTransition(samples: samples, geometry: plan.geometry, instant: plan.instant)
    }

    /// Pure owned-byte rendering runs after the callback's native read lease ends.
    private let frameRenderQueue = DispatchQueue(label: "TruongCam.preview.owned-still", qos: .userInitiated)
    private var pendingRender: PendingPreviewTransition?
    private var isRenderingFrame = false
    /// One worker and one latest owned still, with no native buffer retained.
    func enqueuePreviewBuffer(_ pending: PendingPreviewTransition) {
        lock.lock()
        guard geometry == pending.geometry else { lock.unlock(); return }
        lastFrameInstant = pending.instant
        lastFrameGeometry = (pending.geometry.configurationGeneration, pending.geometry.layoutGeneration)
        pendingRender = pending
        let launch = !isRenderingFrame
        isRenderingFrame = true
        lock.unlock()
        guard launch else { return }
        frameRenderQueue.async { [self] in
            while true {
                lock.lock()
                let next = pendingRender
                pendingRender = nil
                if next == nil { isRenderingFrame = false }
                lock.unlock()
                guard let next else { return }
                publishPreviewBuffer(next)
            }
        }
    }

    func publishPreviewBuffer(_ pending: PendingPreviewTransition) {
        guard let bitmap = pending.samples.render(rotation: pending.geometry.analysisRotationDegrees,
            mirrored: pending.geometry.isMirrored)?.makeImage() else { return }
        let geometry = pending.geometry
        let result = PreviewTransitionFrame(image: bitmap, generation: geometry.configurationGeneration,
            layout: geometry.layoutGeneration, instant: pending.instant)
        lock.lock(); defer { lock.unlock() }
        guard self.geometry == geometry else { return }
        frame = result
        if let orientation = geometry.interfaceOrientation { coverFrame = (result, orientation) }
        lastFrameInstant = pending.instant
        lastFrameGeometry = (geometry.configurationGeneration, geometry.layoutGeneration)
    }

    func recordPreviewBuffer(_ buffer: CVPixelBuffer, configuration: ConfigurationGeneration, layout: UInt64) {
        if let pending = readPreviewBuffer(buffer, configuration: configuration, layout: layout) {
            publishPreviewBuffer(pending)
        }
    }

    /// A tiny CPU copy avoids starting Core Image/Metal just to blur a camera
    /// switch. Actual BGRA or tagged 8-bit YCbCr only; unsupported frames use the
    /// opaque UI fallback. No native buffer survives this read-only lease.
    static func transitionSamples(_ buffer: CVPixelBuffer) -> PreviewTransitionSamples? {
        let format = CVPixelBufferGetPixelFormatType(buffer)
        let bgra = format == kCVPixelFormatType_32BGRA
        let video = format == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        guard bgra || video || format == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
              CVPixelBufferLockBaseAddress(buffer,.readOnly) == kCVReturnSuccess else { return nil }
        defer { CVPixelBufferUnlockBaseAddress(buffer,.readOnly) }
        let width = CVPixelBufferGetWidth(buffer), height = CVPixelBufferGetHeight(buffer)
        guard width > 0, height > 0, width <= 16384, height <= 16384 else { return nil }
        let base: UnsafeMutableRawPointer, stride: Int
        var chroma: UnsafeMutableRawPointer?, chromaStride = 0
        var matrix: PreviewYCbCrMatrix?
        if bgra {
            guard let address = CVPixelBufferGetBaseAddress(buffer) else { return nil }
            base = address; stride = CVPixelBufferGetBytesPerRow(buffer)
            guard stride >= width * 4 else { return nil }
        } else {
            guard CVPixelBufferGetPlaneCount(buffer) == 2,
                  let address = CVPixelBufferGetBaseAddressOfPlane(buffer,0),
                  let uv = CVPixelBufferGetBaseAddressOfPlane(buffer,1),
                  CVPixelBufferGetWidthOfPlane(buffer,1) >= (width+1)/2,
                  CVPixelBufferGetHeightOfPlane(buffer,1) >= (height+1)/2 else { return nil }
            base = address; stride = CVPixelBufferGetBytesPerRowOfPlane(buffer,0)
            chroma = uv; chromaStride = CVPixelBufferGetBytesPerRowOfPlane(buffer,1)
            guard stride >= width, chromaStride >= ((width+1)/2)*2 else { return nil }
            let tag = CVBufferCopyAttachment(buffer,kCVImageBufferYCbCrMatrixKey,nil)
            if tag.map({ CFEqual($0,kCVImageBufferYCbCrMatrix_ITU_R_601_4) }) == true { matrix = .itu601 }
            else if tag.map({ CFEqual($0,kCVImageBufferYCbCrMatrix_ITU_R_709_2) }) == true { matrix = .itu709 }
            else if tag.map({ CFEqual($0,kCVImageBufferYCbCrMatrix_ITU_R_2020) }) == true { matrix = .itu2020 }
            guard matrix != nil else { return nil }
        }
        let scale = min(1,160.0/Double(max(width,height)))
        let w = max(1,Int(Double(width)*scale)), h = max(1,Int(Double(height)*scale))
        var bytes = [UInt8](repeating: 0, count: w * h * 3)
        let source = base.assumingMemoryBound(to: UInt8.self)
        let uv = chroma?.assumingMemoryBound(to: UInt8.self)
        for y in 0..<h { for x in 0..<w {
            let sx = min(width - 1, x * width / w), sy = min(height - 1, y * height / h)
            let i = (y * w + x) * 3
            if bgra {
                let j = sy * stride + sx * 4
                bytes[i] = source[j + 2]; bytes[i + 1] = source[j + 1]; bytes[i + 2] = source[j]
            } else if let uv {
                let j = (sy / 2) * chromaStride + (sx / 2) * 2
                bytes[i] = source[sy * stride + sx]; bytes[i + 1] = uv[j]; bytes[i + 2] = uv[j + 1]
            }
        } }
        return PreviewTransitionSamples(bytes: bytes, width: w, height: h,
            isRGB: bgra, videoRange: video, matrix: matrix)
    }

    static func transitionPixels(_ buffer: CVPixelBuffer, rotation: Int, mirrored: Bool) -> PreviewTransitionPixels? {
        transitionSamples(buffer)?.render(rotation: rotation, mirrored: mirrored)
    }

    static func transitionBitmap(_ buffer: CVPixelBuffer, rotation: Int, mirrored: Bool) -> CGImage? {
        transitionPixels(buffer, rotation: rotation, mirrored: mirrored)?.makeImage()
    }

    func hasCurrentFrame(for geometry: PreviewGeometrySnapshot?) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard let geometry, let stamp=latestBufferStamp else { return false }
        return stamp.0 == geometry.configurationGeneration && stamp.1 == geometry.layoutGeneration
            && currentInstant()-stamp.2 < 1.5
    }

    func frozenFrame(for geometry: PreviewGeometrySnapshot?) -> PreviewTransitionFrame? {
        lock.lock(); defer { lock.unlock() }
        guard let frame, let geometry, frame.generation == geometry.configurationGeneration,
              frame.layout == geometry.layoutGeneration,
              currentInstant() - frame.instant < 1.5 else { return nil }
        return frame
    }

    /// A recent same-screen-orientation image can hide a rapid next switch
    /// before that camera's first optional still has rendered. Deliberately
    /// separate from frozenFrame/hasCurrentFrame: this is never current evidence.
    func decorativeTransitionFrame(for geometry: PreviewGeometrySnapshot?) -> PreviewTransitionFrame? {
        lock.lock(); defer { lock.unlock() }
        guard let geometry, let (image, orientation) = coverFrame,
              orientation == geometry.interfaceOrientation else { return nil }
        let age = currentInstant() - image.instant
        guard age >= 0, age < 1.5 else { return nil }
        return image
    }


    init(currentInstant: @escaping @Sendable () -> Double = { ProcessInfo.processInfo.systemUptime }) {
        self.currentInstant = currentInstant
    }

    /// Installs the session. Called once on the camera service's serial queue.
    func install(_ session: AVCaptureSession?, rotationAngles: CameraRotationAngles? = nil) {
        lock.lock()
        self.session = session
        self.rotations = rotationAngles
        lock.unlock()
    }

    func clear() {
        install(nil)
        lock.lock()
        coverFrame = nil; frame = nil; geometry = nil; latestBufferStamp = nil
        lastFrameGeometry = nil; lastFrameInstant = -.infinity
        lock.unlock()
    }

    /// The session, or nil when the camera has not been prepared or has been
    /// torn down. Safe to call from the main thread.
    var displaySession: AVCaptureSession? {
        lock.lock(); defer { lock.unlock() }
        return session
    }
}

final class PreviewAnalysisPriorityLease: @unchecked Sendable {
    private let lock = NSLock()
    private var onRelease: (@Sendable () -> Void)?
    init(onRelease: @escaping @Sendable () -> Void) { self.onRelease = onRelease }
    func release() {
        lock.lock(); let action = onRelease; onRelease = nil; lock.unlock()
        action?()
    }
    deinit { release() }
}

// One atomic read keeps the session and its camera-specific rotation together.
extension PreviewDisplayBridge {
    var displayBox: PreviewSessionBox? {
        lock.lock(); defer { lock.unlock() }
        guard let session else { return nil }
        return PreviewSessionBox(session: session, rotationAngles: rotations, nativeAccessGate: nativeAccessGate,
            currentFrameNotifications: currentFrameNotifications, photoWorkSource: self)
    }
}

struct PreviewFrameIdentity: Hashable, Sendable {
    let generation: ConfigurationGeneration
    let layout: UInt64
}

/// Immutable display derivative; its pixels/orientation never change during a switch.
struct PreviewTransitionFrame: Sendable {
    let image: CGImage
    let generation: ConfigurationGeneration
    let layout: UInt64
    let instant: Double
}

/// Only owned bounded bytes survive the native pixel-buffer scope.
struct PendingPreviewTransition: Sendable {
    let samples: PreviewTransitionSamples
    let geometry: PreviewGeometrySnapshot
    let instant: Double
}
struct PreviewTransitionPixels: Sendable {
    let bytes: [UInt8]
    let width: Int
    let height: Int
    func makeImage() -> CGImage? {
        guard let provider = CGDataProvider(data: Data(bytes) as CFData) else { return nil }
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }
}

/// One bounded raw sample grid. Color conversion/rotation use owned bytes after native release.
struct PreviewTransitionSamples: Sendable {
    let bytes: [UInt8]
    let width: Int
    let height: Int
    let isRGB: Bool
    let videoRange: Bool
    let matrix: PreviewYCbCrMatrix?

    func render(rotation: Int, mirrored: Bool) -> PreviewTransitionPixels? {
        let angle = ((rotation % 360) + 360) % 360
        guard width > 0, height > 0, width <= 160, height <= 160,
              bytes.count == width * height * 3, [0, 90, 180, 270].contains(angle), isRGB || matrix != nil else { return nil }
        let outW = angle % 180 == 0 ? width : height, outH = angle % 180 == 0 ? height : width
        var rgba = [UInt8](repeating: 255, count: outW * outH * 4)
        func channel(_ value: Double) -> UInt8 { UInt8((min(1, max(0, value)) * 255).rounded()) }
        for y in 0..<height { for x in 0..<width {
            let j = (y * width + x) * 3
            let r: UInt8, g: UInt8, b: UInt8
            if isRGB { r = bytes[j]; g = bytes[j + 1]; b = bytes[j + 2] }
            else if let matrix {
                let weights = matrix.weights
                let yy = (Double(bytes[j]) - (videoRange ? 16 : 0)) / (videoRange ? 219 : 255)
                let cb = (Double(bytes[j + 1]) - 128) / (videoRange ? 224 : 255)
                let cr = (Double(bytes[j + 2]) - 128) / (videoRange ? 224 : 255)
                let rr = yy + 2 * (1 - weights.red) * cr, bb = yy + 2 * (1 - weights.blue) * cb
                r = channel(rr); b = channel(bb)
                g = channel((yy - weights.red * rr - weights.blue * bb) / (1 - weights.red - weights.blue))
            } else { return nil }
            let nx: Int, ny: Int
            switch angle {
            case 90: nx = height - 1 - y; ny = x
            case 180: nx = width - 1 - x; ny = height - 1 - y
            case 270: nx = y; ny = width - 1 - x
            default: nx = x; ny = y
            }
            let i = (ny * outW + (mirrored ? outW - 1 - nx : nx)) * 4
            rgba[i] = r; rgba[i + 1] = g; rgba[i + 2] = b
        } }
        return PreviewTransitionPixels(bytes: rgba, width: outW, height: outH)
    }
}

struct PreviewTransitionPlan: Sendable {
    let geometry: PreviewGeometrySnapshot
    let instant: Double
}
