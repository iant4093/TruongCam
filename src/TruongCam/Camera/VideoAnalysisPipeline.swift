@preconcurrency import AVFoundation
import Foundation

// PREVIEW_TOOLS.md "Shared analysis pipeline".
//
// CameraService owns the AVCaptureVideoDataOutput and its sample-buffer delegate
// on one serial analysis queue. All tools share one sample: there is no per-tool
// frame queue, at most one sample is processed at a time, stale buffers are
// dropped, and scratch storage is reused across frames.
//
// The pipeline never interprets BGRA as a luma plane. A format without a usable
// luma plane produces a typed "analysis unavailable" result instead of a guess.

/// Receives one downsample outcome per accepted frame.
protocol AnalysisSampleConsumer: Sendable {
    func consume(outcome: LumaDownsampleOutcome, geometry: PreviewGeometrySnapshot?) async
}

/// Supplies the generation stamp for a frame at the moment it is acquired.
///
/// REVIEW.md C08: the previous code stamped generations when the sample was
/// *consumed*, reading whatever geometry was current then, so a frame captured
/// before a rotation could be relabelled as belonging to the new layout. The
/// stamp must be read on the analysis queue as the frame arrives.
protocol AnalysisGenerationProviding: Sendable {
    /// The configuration generation and layout generation in effect right now.
    func currentAnalysisGeneration() -> (configuration: ConfigurationGeneration, layout: UInt64, histogramEnabled: Bool, masksEnabled: Bool)
    /// Full inspection coordinates are separate from mask/histogram demand;
    /// the native frame's crop must use the acquisition-time loupe request.
    func currentLoupeRequest() -> AnalysisRequest?
}

extension AnalysisGenerationProviding {
    func currentLoupeRequest() -> AnalysisRequest? { nil }
}

/// The video-data delegate. It runs on the analysis queue and does the CPU work
/// there; only small snapshots are handed onward.
///
/// Ownership invariant for the narrow `@unchecked Sendable`: every field is
/// immutable after `init`; `lastAnalysisInstant` belongs to the serial callback
/// queue and `scratch` to the one owned-work queue. Admission bounds work to one
/// frame until its asynchronous consumer completes. The
/// `CVPixelBuffer` lease is locked and unlocked within the same scope, so no
/// pointer outlives its buffer.
final class AnalysisSampleBufferHandler: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
    private let displayBridge: PreviewDisplayBridge?
    private let consumer: any AnalysisSampleConsumer
    private let generationProvider: any AnalysisGenerationProviding
    private let scratch = ReusedScratch()
    private let ownedWorkQueue = DispatchQueue(label: "TruongCam.analysis.owned", qos: .userInitiated)
    /// Rejection counters so a misconfigured pipeline is visible in diagnostics.
    private let counters = SampleCounters()
    /// At most one sample may be in flight: a slow consumer must not accumulate a
    /// backlog of frames or owned arrays (REVIEW.md C08).
    private let admission: SampleAdmission
    private let currentInstant: @Sendable () -> Double
    private let beforeOwnedAnalysis: @Sendable () -> Void
    // Loupe targets 30 Hz, masks 20 Hz and histogram 10 Hz downstream. Drop
    // before buffer locking/scaling; the shared acquisition uses the fastest
    // active aid rather than imposing the masks' slower cap on a live loupe.
    private var lastAnalysisInstant: Double = -.infinity

    init(consumer: any AnalysisSampleConsumer,
         generationProvider: any AnalysisGenerationProviding,
         admission: SampleAdmission = SampleAdmission(),
         displayBridge: PreviewDisplayBridge? = nil,
         currentInstant: @escaping @Sendable () -> Double = { ProcessInfo.processInfo.systemUptime },
         beforeOwnedAnalysis: @escaping @Sendable () -> Void = {}) {
        self.displayBridge = displayBridge
        self.consumer = consumer
        self.generationProvider = generationProvider
        self.admission = admission
        self.currentInstant = currentInstant
        self.beforeOwnedAnalysis = beforeOwnedAnalysis
        super.init()
    }

    func captureOutput(_ output: AVCaptureOutput,
                       didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        processSampleBuffer(sampleBuffer)
    }

    /// The delegate's exact serial-queue body, also exercised with real native
    /// sample buffers without requiring a physical capture connection in tests.
    func processSampleBuffer(_ sampleBuffer: CMSampleBuffer) {
        let frameRead: PreviewNativeAccessGate.FrameReadLease?
        if let gate = displayBridge?.nativeAccessGate {
            guard let admitted = gate.beginFrameRead() else { return }
            frameRead = admitted
        } else {
            frameRead = nil
        }
        // The native buffer and transition bitmap read finish before graph work
        // can resume. Only owned arrays cross into the asynchronous consumer.
        defer { frameRead?.release() }
        let instant = currentInstant()
        let capturedAtUTC = Date()
        #if DEBUG
        let nativeReadBegan = ProcessInfo.processInfo.systemUptime
        #endif
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
            counters.record(rejected: .missingPixelBuffer)
            return
        }
        let stamp = generationProvider.currentAnalysisGeneration()
        let loupeRequest = generationProvider.currentLoupeRequest().flatMap { request in
            request.configurationGeneration == stamp.configuration
                && request.geometry?.layoutGeneration == stamp.layout ? request : nil
        }
        let transition = displayBridge?.acknowledgePreviewBuffer(configuration: stamp.configuration, layout: stamp.layout)
        #if DEBUG
        let transitionReadEnded = ProcessInfo.processInfo.systemUptime
        let transitionMS = Int((transitionReadEnded - nativeReadBegan) * 1000)
        if transitionMS > 100 { print("TruongCam timing preview-frame-ack=\(transitionMS)ms") }
        #endif
        // Current-camera rendering is acknowledged on the first delivered frame.
        // Keep expensive analysis capped independently of preview readiness and
        // of the bridge's separately bounded optional blur bitmap.
        guard displayBridge?.shouldDeferAnalysisForPhoto != true else { return }
        guard displayBridge?.shouldDeferAnalysisForCameraPreparation != true else { return }
        let analysisHz = AnalysisRateLimits.nativeAcquisitionHz(masksEnabled: stamp.masksEnabled,
            loupeEnabled: loupeRequest != nil)
        guard instant - lastAnalysisInstant >= 1.0 / analysisHz - 0.001 else { return }
        // Backpressured callbacks still acknowledge the current preview, but
        // must not lock/inspect another native plane while cold owned work runs.
        guard admission.beginFrame() else {
            counters.record(rejected: .backpressure)
            return
        }
        var transferredAdmission = false
        defer { if !transferredAdmission { admission.endFrame() } }
        guard CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly) == kCVReturnSuccess else {
            counters.record(rejected: .lockFailed)
            return
        }
        #if DEBUG
        let planeLockEnded = ProcessInfo.processInfo.systemUptime
        let lockMS = Int((planeLockEnded - transitionReadEnded) * 1000)
        if lockMS > 100 { print("TruongCam timing analysis-plane-lock=\(lockMS)ms") }
        #endif
        var ownsPixelLock = true
        defer { if ownsPixelLock { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) } }

        let format = CVPixelBufferGetPixelFormatType(pixelBuffer)
        let width = CVPixelBufferGetWidthOfPlane(pixelBuffer, 0)
        let height = CVPixelBufferGetHeightOfPlane(pixelBuffer, 0)
        let bytesPerRow = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 0)
        guard let base = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 0), width > 0, height > 0 else {
            counters.record(rejected: .noLumaPlane)
            return
        }

        // The declared format is derived from the actual FourCC and the actual
        // attachment, never assumed from the requested settings.
        let declared = Self.declaredFormat(pixelBuffer: pixelBuffer, fourCC: format)
        let planeCount = CVPixelBufferGetPlaneCount(pixelBuffer)
        guard width <= 8192, height <= 8192, width <= (16 * 1024 * 1024) / height,
              bytesPerRow >= width else {
            counters.record(rejected: .invalidPlane(reason: "Analysis frame exceeds the bounded copy budget")); return
        }
        _ = planeCount

        lastAnalysisInstant = instant
        // Read the generation stamp now, on the analysis queue, so this frame is
        // labelled with the configuration/layout it was actually captured under.

        // Copy real luma bytes while borrowed, then end ALL native access before
        // vImage, CGImage construction or downstream math can perform cold work.
        // Every byte is overwritten before publication. Avoid zero-filling the
        // same bounded planes first, especially while a graph writer is waiting
        // for this borrowed native read to drain.
        let ownedLuma = [UInt8](unsafeUninitializedCapacity: width * height) { out, initializedCount in
            guard let destination = out.baseAddress else { return }
            for row in 0..<height {
                memcpy(destination + row * width, base + row * bytesPerRow, width)
            }
            initializedCount = width * height
        }
        #if DEBUG
        let lumaCopyEnded = ProcessInfo.processInfo.systemUptime
        #endif
        let rgbSource = (stamp.histogramEnabled || transition != nil || loupeRequest != nil)
            ? Self.copyHistogramChroma(pixelBuffer: pixelBuffer) : nil
        #if DEBUG
        let chromaCopyEnded = ProcessInfo.processInfo.systemUptime
        #endif
        CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly)
        ownsPixelLock = false
        frameRead?.release()
        #if DEBUG
        let nativeEnded = ProcessInfo.processInfo.systemUptime
        let copyMS = Int((nativeEnded - planeLockEnded) * 1000)
        if copyMS > 100 {
            // Log only after releasing both the native buffer and graph lease.
            // A first attachment query or allocation can dominate this span;
            // the split distinguishes it from plane copy work next run.
            let lumaMS = Int((lumaCopyEnded - planeLockEnded) * 1000)
            let chromaMS = Int((chromaCopyEnded - lumaCopyEnded) * 1000)
            print("TruongCam timing analysis-owned-copy=\(copyMS)ms luma=\(lumaMS)ms chroma=\(chromaMS)ms dimensions=\(width)x\(height) bytes=\(ownedLuma.count + (rgbSource?.bytes.count ?? 0))")
        }
        let nativeMS = Int((nativeEnded - nativeReadBegan) * 1000)
        if nativeMS > 100 { print("TruongCam timing analysis-native-read=\(nativeMS)ms") }
        #endif
        transferredAdmission = true
        #if DEBUG
        let ownedQueuedAt = ProcessInfo.processInfo.systemUptime
        #endif
        ownedWorkQueue.async { [self, ownedLuma] in
        #if DEBUG
        let ownedWorkBegan = ProcessInfo.processInfo.systemUptime
        let queueMS = Int((ownedWorkBegan - ownedQueuedAt) * 1000)
        if queueMS > 100 { print("TruongCam timing analysis-owned-queue=\(queueMS)ms") }
        defer {
            let ms = Int((ProcessInfo.processInfo.systemUptime - ownedWorkBegan) * 1000)
            if ms > 100 { print("TruongCam timing analysis-owned-work=\(ms)ms") }
        }
        #endif
        // A copied frame may wait behind a first-use library/framework call on
        // this queue. Recheck after that wait: a newly admitted photo or newer
        // camera/layout owns the resources now, so obsolete math is avoidable.
        var consumerOwnsAdmission = false
        defer { if !consumerOwnsAdmission { admission.endFrame() } }
        beforeOwnedAnalysis()
        guard admitOwnedAnalysis(stamp, loupeRequest: loupeRequest) else { return }
        if let transition, let samples = rgbSource?.transition(luma: ownedLuma, width: width, height: height) {
            displayBridge?.enqueuePreviewBuffer(PendingPreviewTransition(samples: samples,
                geometry: transition.geometry, instant: transition.instant))
        }
        #if DEBUG
        let downsampleBegan = ProcessInfo.processInfo.systemUptime
        #endif
        var outcome = ownedLuma.withUnsafeBufferPointer { luma in
            PreviewAnalysisMath.downsampleLuma(from: luma, width: width, height: height,
                bytesPerRow: width, range: declared, targetLongEdge: stamp.masksEnabled ? 384 : 320, scratch: scratch,
                configurationGeneration: stamp.configuration, geometryGeneration: stamp.layout,
                capturedAtUTC: capturedAtUTC, useAccelerate: true)
        }
        #if DEBUG
        let downsampleMS = Int((ProcessInfo.processInfo.systemUptime - downsampleBegan) * 1000)
        if downsampleMS > 100 { print("TruongCam timing analysis-downsample=\(downsampleMS)ms") }
        #endif
        // Native scaling can itself be a cold synchronous call. It cannot be
        // interrupted safely, but a photo/switch that arrived during it should
        // not also pay for RGB math or receive an obsolete consumer update.
        guard admitOwnedAnalysis(stamp, loupeRequest: loupeRequest) else { return }
        if case .sampled(var sample, let record) = outcome {
            #if DEBUG
            let histogramBegan = ProcessInfo.processInfo.systemUptime
            #endif
            sample.rgbHistogram = stamp.histogramEnabled ? rgbSource?.histogram(luma: ownedLuma, width: width, height: height) : nil
            // Every native sample requires the real color path when used as a
            // loupe. Missing/unsupported chroma never becomes a grayscale crop.
            sample.requiresColorLoupe = true
            if let loupeRequest, let rgbSource {
                sample.colorLoupe = LoupeRenderer.renderColor(luma: ownedLuma, width: width, height: height,
                    chroma: rgbSource.bytes, chromaWidth: rgbSource.width, chromaHeight: rgbSource.height,
                    range: rgbSource.range, matrix: rgbSource.matrix, request: loupeRequest, capturedAtUTC: capturedAtUTC)
            }
            outcome = .sampled(sample, record: record)
            #if DEBUG
            let histogramMS = Int((ProcessInfo.processInfo.systemUptime - histogramBegan) * 1000)
            if histogramMS > 100 { print("TruongCam timing analysis-rgb-histogram=\(histogramMS)ms") }
            #endif
        }
        // Color conversion is bounded but synchronous. A photo, camera or new
        // inspection point that arrived during it owns any subsequent work.
        guard admitOwnedAnalysis(stamp, loupeRequest: loupeRequest) else { return }
        switch outcome {
        case .sampled:
            counters.record(accepted: true)
        case .unsupported(let format, let reason):
            counters.record(rejected: .unsupportedFormat(reason: reason))
            _ = format
        case .invalid(let reason):
            counters.record(rejected: .invalidPlane(reason: reason))
        }

        consumerOwnsAdmission = true
        Task { [consumer, admission] in
            await consumer.consume(outcome: outcome, geometry: nil)
            admission.endFrame()
        }
        }
    }

    /// The owned queue is intentionally independent of native graph reads.
    /// Its one-frame budget still needs current demand/priority at execution,
    /// rather than only at the earlier native-copy admission boundary.
    private func admitOwnedAnalysis(_ stamp: (configuration: ConfigurationGeneration, layout: UInt64, histogramEnabled: Bool, masksEnabled: Bool),
                                    loupeRequest: AnalysisRequest?) -> Bool {
        guard displayBridge?.shouldDeferAnalysisForPhoto != true else {
            counters.record(rejected: .photoPriority)
            return false
        }
        guard displayBridge?.shouldDeferAnalysisForCameraPreparation != true else {
            counters.record(rejected: .cameraPreparationPriority)
            return false
        }
        let current = generationProvider.currentAnalysisGeneration()
        guard current.configuration == stamp.configuration, current.layout == stamp.layout,
              current.histogramEnabled == stamp.histogramEnabled, current.masksEnabled == stamp.masksEnabled,
              generationProvider.currentLoupeRequest() == loupeRequest else {
            counters.record(rejected: .superseded)
            return false
        }
        return true
    }

    /// Called only while the caller owns the read-only CVPixelBuffer lock.
    static func rgbHistogram(pixelBuffer: CVPixelBuffer) -> PreviewRGBHistogram? {
        let format = CVPixelBufferGetPixelFormatType(pixelBuffer)
        guard format == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
                || format == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
              CVPixelBufferGetPlaneCount(pixelBuffer) == 2,
              let y = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 0),
              let cbcr = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 1) else { return nil }
        let attachment = CVBufferCopyAttachment(pixelBuffer, kCVImageBufferYCbCrMatrixKey, nil)
        let matrix: PreviewYCbCrMatrix?
        if attachment.map({ CFEqual($0, kCVImageBufferYCbCrMatrix_ITU_R_709_2) }) == true { matrix = .itu709 }
        else if attachment.map({ CFEqual($0, kCVImageBufferYCbCrMatrix_ITU_R_601_4) }) == true { matrix = .itu601 }
        else if attachment.map({ CFEqual($0, kCVImageBufferYCbCrMatrix_ITU_R_2020) }) == true { matrix = .itu2020 }
        else { matrix = nil }
        let width = CVPixelBufferGetWidthOfPlane(pixelBuffer, 0), height = CVPixelBufferGetHeightOfPlane(pixelBuffer, 0)
        let ys = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 0), cs = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 1)
        let cw = CVPixelBufferGetWidthOfPlane(pixelBuffer, 1), ch = CVPixelBufferGetHeightOfPlane(pixelBuffer, 1)
        return PreviewAnalysisMath.rgbHistogram(
            luma: UnsafeBufferPointer(start: y.assumingMemoryBound(to: UInt8.self), count: ys * height),
            chroma: UnsafeBufferPointer(start: cbcr.assumingMemoryBound(to: UInt8.self), count: cs * ch),
            width: width, height: height, lumaStride: ys, chromaStride: cs, chromaWidth: cw, chromaHeight: ch,
            range: format == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange ? .full : .video, matrix: matrix)
    }

    /// Caller holds the native lock. Copy bytes only; RGB math belongs to owned work.
    static func copyHistogramChroma(pixelBuffer: CVPixelBuffer) -> OwnedHistogramChroma? {
        let format = CVPixelBufferGetPixelFormatType(pixelBuffer)
        guard format == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
                || format == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
              CVPixelBufferGetPlaneCount(pixelBuffer) == 2,
              let address = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 1) else { return nil }
        let width = CVPixelBufferGetWidthOfPlane(pixelBuffer, 1), height = CVPixelBufferGetHeightOfPlane(pixelBuffer, 1)
        let stride = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 1)
        guard width > 0, height > 0, width <= 4096, height <= 4096,
              width * 2 <= (8 * 1024 * 1024) / height, stride >= width * 2 else { return nil }
        let tag = CVBufferCopyAttachment(pixelBuffer, kCVImageBufferYCbCrMatrixKey, nil)
        let matrix: PreviewYCbCrMatrix
        if tag.map({ CFEqual($0, kCVImageBufferYCbCrMatrix_ITU_R_709_2) }) == true { matrix = .itu709 }
        else if tag.map({ CFEqual($0, kCVImageBufferYCbCrMatrix_ITU_R_601_4) }) == true { matrix = .itu601 }
        else if tag.map({ CFEqual($0, kCVImageBufferYCbCrMatrix_ITU_R_2020) }) == true { matrix = .itu2020 }
        else { return nil }
        let bytes = [UInt8](unsafeUninitializedCapacity: width * height * 2) { out, initializedCount in
            guard let destination = out.baseAddress else { return }
            for row in 0..<height { memcpy(destination + row * width * 2, address + row * stride, width * 2) }
            initializedCount = width * height * 2
        }
        return OwnedHistogramChroma(bytes: bytes, width: width, height: height,
            range: format == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange ? .full : .video, matrix: matrix)
    }

    var snapshot: SampleCounters.Snapshot { counters.snapshot }

    /// Maps the actual pixel-buffer format and its attachments onto the luma math
    /// input. Full/video range is read from the buffer attachments when present;
    /// the nominal default is video range for YCbCr.
    static func declaredFormat(pixelBuffer: CVPixelBuffer, fourCC: UInt32) -> LumaSourceFormat {
        switch fourCC {
        case kCVPixelFormatType_420YpCbCr8BiPlanarFullRange:
            return .biplanarLuma8(.full)
        case kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange:
            return .biplanarLuma8(.video)
        case kCVPixelFormatType_420YpCbCr8PlanarFullRange:
            return .planarLuma8(.full)
        case kCVPixelFormatType_420YpCbCr8Planar:
            return .planarLuma8(.video)
        case kCVPixelFormatType_32BGRA:
            // Explicitly unsupported rather than reinterpreted: BGRA has no luma
            // plane, and a guessed channel order would silently corrupt every
            // histogram, peaking and zebra reading.
            return .bgra8
        default:
            // The FourCC is authoritative. REVIEW.md C08: the previous code
            // inferred full range from colour-primary/transfer-function strings
            // containing "Full", which misclassified full-range YCbCr FourCCs.
            // Range is now decided by the pixel format itself.
            return .unknown(fourCC: fourCC)
        }
    }
}

/// Why a frame was not analysed. Counted so a misconfigured pipeline is visible.
enum SampleRejectionReason: Hashable, Sendable {
    case missingPixelBuffer
    case lockFailed
    case noLumaPlane
    case unsupportedFormat(reason: String)
    case invalidPlane(reason: String)
    /// A frame arrived while the previous one was still being analysed.
    case backpressure
    /// Owned bytes waited until a newer camera/layout/demand superseded them.
    case superseded
    /// A photo acquired priority after this frame's native bytes were copied.
    case photoPriority
    case cameraPreparationPriority
}

/// Publishes the acquisition-time generation stamp to the analysis queue.
///
/// The delegate's `currentAnalysisGeneration()` is synchronous because it runs on
/// the analysis queue with a frame in hand. The camera service owns this value and
/// updates it on its serial session queue whenever the configuration generation or
/// the published geometry changes, so a frame is stamped with the state it was
/// actually captured under rather than whatever is current when it is consumed.
///
/// Ownership invariant for the narrow `@unchecked Sendable`: `values` is only read
/// or written while `lock` is held. Both call sites are short and non-blocking, so
/// the analysis queue never waits on the session queue.
final class SessionGenerationSource: AnalysisGenerationProviding, @unchecked Sendable {
    private let lock = NSLock()
    private var values: (configuration: ConfigurationGeneration, layout: UInt64, histogramEnabled: Bool, masksEnabled: Bool) = (.zero, 0, false, false)
    private var loupeRequest: AnalysisRequest?

    func update(configuration: ConfigurationGeneration, layout: UInt64, histogramEnabled: Bool, masksEnabled: Bool = false,
                request: AnalysisRequest? = nil) {
        lock.lock()
        values = (configuration, layout, histogramEnabled, masksEnabled)
        if let request, request.demand.loupeEnabled,
           request.configurationGeneration == configuration,
           request.geometry?.layoutGeneration == layout {
            loupeRequest = request
        } else { loupeRequest = nil }
        lock.unlock()
    }

    func currentAnalysisGeneration() -> (configuration: ConfigurationGeneration, layout: UInt64, histogramEnabled: Bool, masksEnabled: Bool) {
        lock.lock(); defer { lock.unlock() }
        return values
    }

    func currentLoupeRequest() -> AnalysisRequest? {
        lock.lock(); defer { lock.unlock() }
        return loupeRequest
    }
}

/// Admits at most one analysis frame at a time.
///
/// Ownership invariant for the narrow `@unchecked Sendable`: `inFlight` is only
/// touched while `lock` holds it. `beginFrame`/`endFrame` are called from the
/// analysis queue and the consumer task respectively, so the lock is required.
final class SampleAdmission: @unchecked Sendable {
    private let lock = NSLock()
    private var inFlight = false

    var isFrameInFlight: Bool {
        lock.lock(); defer { lock.unlock() }; return inFlight
    }

    func beginFrame() -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard !inFlight else { return false }
        inFlight = true
        return true
    }

    func endFrame() {
        lock.lock(); inFlight = false; lock.unlock()
    }
}

/// Lock-protected rejection counters.
final class SampleCounters: @unchecked Sendable {
    struct Snapshot: Hashable, Sendable {
        let accepted: Int
        let rejected: Int
        let lastRejection: String?
    }

    private let lock = NSLock()
    private var accepted = 0
    private var rejected = 0
    private var lastRejection: String?

    func record(accepted: Bool) {
        lock.lock(); self.accepted += 1; lock.unlock()
    }

    func record(rejected reason: SampleRejectionReason) {
        lock.lock()
        rejected += 1
        switch reason {
        case .missingPixelBuffer: lastRejection = "the sample buffer carried no pixel buffer"
        case .lockFailed: lastRejection = "the pixel buffer could not be locked for reading"
        case .noLumaPlane: lastRejection = "the pixel buffer exposed no luma plane"
        case .unsupportedFormat(let text): lastRejection = text
        case .invalidPlane(let text): lastRejection = text
        case .backpressure: lastRejection = "the previous frame was still being analysed"
        case .superseded: lastRejection = "the copied frame was superseded before owned analysis"
        case .photoPriority: lastRejection = "photo work acquired priority before owned analysis"
        case .cameraPreparationPriority: lastRejection = "camera preparation acquired priority before owned analysis"
        }
        lock.unlock()
    }

    var snapshot: Snapshot {
        lock.lock(); defer { lock.unlock() }
        return Snapshot(accepted: accepted, rejected: rejected, lastRejection: lastRejection)
    }
}

/// Immutable dense chroma; native row padding and native object lifetime end at copying.
struct OwnedHistogramChroma: Sendable {
    let bytes: [UInt8]
    let width: Int
    let height: Int
    let range: PreviewCodeRange
    let matrix: PreviewYCbCrMatrix
    func transition(luma: [UInt8], width lumaWidth: Int, height lumaHeight: Int) -> PreviewTransitionSamples? {
        guard lumaWidth > 0, lumaHeight > 0, luma.count == lumaWidth * lumaHeight,
              width >= (lumaWidth + 1) / 2, height >= (lumaHeight + 1) / 2,
              bytes.count == width * height * 2 else { return nil }
        let scale = min(1, 160.0 / Double(max(lumaWidth, lumaHeight)))
        let w = max(1, Int(Double(lumaWidth) * scale)), h = max(1, Int(Double(lumaHeight) * scale))
        var sample = [UInt8](repeating: 0, count: w * h * 3)
        for y in 0..<h { for x in 0..<w {
            let sx = min(lumaWidth - 1, x * lumaWidth / w), sy = min(lumaHeight - 1, y * lumaHeight / h)
            let i = (y * w + x) * 3, c = ((sy / 2) * width + sx / 2) * 2
            sample[i] = luma[sy * lumaWidth + sx]; sample[i + 1] = bytes[c]; sample[i + 2] = bytes[c + 1]
        } }
        return PreviewTransitionSamples(bytes: sample, width: w, height: h, isRGB: false,
            videoRange: range == .video, matrix: matrix)
    }
    func histogram(luma: [UInt8], width lumaWidth: Int, height lumaHeight: Int) -> PreviewRGBHistogram? {
        luma.withUnsafeBufferPointer { y in bytes.withUnsafeBufferPointer { uv in
            PreviewAnalysisMath.rgbHistogram(luma: y, chroma: uv, width: lumaWidth, height: lumaHeight,
                lumaStride: lumaWidth, chromaStride: width * 2, chromaWidth: width, chromaHeight: height,
                range: range, matrix: matrix)
        } }
    }
}
