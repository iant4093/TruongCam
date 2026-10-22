import Accelerate
import Foundation
import Synchronization
#if canImport(XCTest)
@testable import TruongCam
#endif

/// Executes the shipping scaler against owned synthetic padded planes. These
/// byte/call-count checks establish cache behavior, not physical-device speed.
enum PreviewScratchCacheSuite {
    private static func plane(width: Int = 64, height: Int = 48, stride: Int = 80, seed: Int = 0) -> [UInt8] {
        var bytes = [UInt8](repeating: 251, count: stride * height)
        for row in 0..<height { for column in 0..<width {
            bytes[row * stride + column] = UInt8(truncatingIfNeeded: row * 11 + column * 7 + seed)
        } }
        return bytes
    }
    private static func scale(_ bytes: [UInt8], width: Int = 64, height: Int = 48, stride: Int = 80,
                              edge: Int = 32, range: PreviewCodeRange = .video, scratch: ReusedScratch,
                              accelerate: Bool = true,
                              operation: PreviewAnalysisMath.LumaScaleOperation = .native) -> LumaDownsampleOutcome {
        bytes.withUnsafeBufferPointer { source in
            PreviewAnalysisMath.downsampleLuma(from: source, width: width, height: height, bytesPerRow: stride,
                range: .biplanarLuma8(range), targetLongEdge: edge, scratch: scratch,
                configurationGeneration: ConfigurationGeneration(56), geometryGeneration: 7,
                capturedAtUTC: StorageFixture.fixedDate, useAccelerate: accelerate, scaleOperation: operation)
        }
    }
    private static func signature(width: Int = 64, height: Int = 48, stride: Int = 80,
                                  destinationWidth: Int = 32, destinationHeight: Int = 24,
                                  destinationStride: Int = 32,
                                  flags: vImage_Flags = vImage_Flags(kvImageHighQualityResampling)) -> ReusedScratch.ScaleQuerySignature {
        ReusedScratch.ScaleQuerySignature(sourceWidth: width, sourceHeight: height, sourceStride: stride,
            destinationWidth: destinationWidth, destinationHeight: destinationHeight,
            destinationStride: destinationStride, flags: flags)
    }
    private static func imageRequest(loupe: Bool = true, peaking: Bool = true, zebras: Bool = true) -> AnalysisRequest {
        let base = ColorLoupeSuite.request(generation: ConfigurationGeneration(56))
        return AnalysisRequest(configurationGeneration: base.configurationGeneration, geometry: base.geometry,
            demand: AnalysisDemand(needsLuminanceSample: true, histogramEnabled: true,
                zebrasEnabled: zebras, peakingEnabled: peaking, loupeEnabled: loupe),
            peakingThreshold: base.peakingThreshold, zebraThreshold: base.zebraThreshold,
            loupeCenter: base.loupeCenter, loupeMagnification: base.loupeMagnification)
    }
    /// Large owned display payloads remain synthetic preview fixtures, never
    /// captures. Each frame owns new storage so the history is nontrivial.
    private static func imageSample(_ request: AnalysisRequest, ordinal: Int) -> LuminanceSample {
        let date = StorageFixture.fixedDate.addingTimeInterval(Double(ordinal))
        var sample = LuminanceSample(width: 640, height: 480,
            luma: [UInt8](repeating: UInt8(200 + ordinal % 40), count: 640 * 480), range: .full,
            configurationGeneration: request.configurationGeneration,
            geometryGeneration: request.geometry?.layoutGeneration ?? 0, capturedAtUTC: date)
        var rgba = [UInt8](repeating: UInt8(ordinal % 200), count: 512 * 384 * 4)
        for offset in stride(from: 3, to: rgba.count, by: 4) { rgba[offset] = 255 }
        let color = LoupeSnapshot(width: 512, height: 384, rgbaBytes: rgba,
            geometryGeneration: request.geometry?.layoutGeneration ?? 0,
            configurationGeneration: request.configurationGeneration, magnification: request.loupeMagnification,
            mappedAtUTC: date, sampledCenter: request.loupeCenter)
        sample.colorLoupe = PreviewColorLoupeSample(snapshot: color, center: request.loupeCenter,
            sourceDimensions: PixelDimensions(width: 1024, height: 768),
            sourceRect: PixelRect(x: 0, y: 0, width: 512, height: 384))
        sample.requiresColorLoupe = true
        return sample
    }

    static let suite = TCSuite(id: "PreviewScratchCache56", title: "Exact native-scale setup reuse and immutable normalization", cases: [
        TCCase(id: "PC56Q", title: "Stable native layouts query temporary bytes once while every changing frame retains exact output") { r in
            let scratch = ReusedScratch(), calls = Mutex((queries: 0, scales: 0))
            let native = PreviewAnalysisMath.LumaScaleOperation.native
            let observed = PreviewAnalysisMath.LumaScaleOperation { source, destination, temporary, flags in
                calls.withLock {
                    if flags & vImage_Flags(kvImageGetTempBufferSize) != 0 { $0.queries += 1 }
                    else { $0.scales += 1 }
                }
                return native.run(&source, &destination, temporary, flags)
            }
            for frame in 0..<8 {
                let input = plane(seed: frame * 19)
                let actual = scale(input, scratch: scratch, operation: observed)
                let oracle = scale(input, scratch: ReusedScratch())
                guard let sample = actual.sample, let expected = oracle.sample else { r.check("native samples exist", false); return }
                r.equal("all native output bytes match fresh-query oracle", sample.luma, expected.luma)
                r.equal("scaled width retained", sample.width, expected.width)
                r.equal("scaled height retained", sample.height, expected.height)
                r.equal("source configuration unchanged", sample.configurationGeneration, ConfigurationGeneration(56))
                r.equal("source layout unchanged", sample.geometryGeneration, 7)
                r.equal("source time unchanged", sample.capturedAtUTC, StorageFixture.fixedDate)
                r.equal("real accelerated path remains active", actual.record?.usedAccelerateScale, true)
            }
            r.equal("one real vImage temporary-size query", calls.withLock { $0.queries }, 1)
            r.equal("all eight actual native scales execute", calls.withLock { $0.scales }, 8)
            r.equal("scratch counter reflects native query calls", scratch.scaleTemporaryQueryCount, 1)
            scratch.release()
            r.check("release drops retained working buffers", scratch.isReleased)
            _ = scale(plane(), scratch: scratch, operation: observed)
            r.equal("release invalidates setup cache", calls.withLock { $0.queries }, 2)
        },
        TCCase(id: "PC56I", title: "Every source and destination layout field plus flags invalidates temporary-query reuse") { r in
            let scratch = ReusedScratch()
            let keys = [signature(), signature(width: 65), signature(height: 49), signature(stride: 96),
                signature(destinationWidth: 31), signature(destinationHeight: 23), signature(destinationStride: 40),
                signature(flags: vImage_Flags(kvImageNoFlags))]
            var queries = 0
            for (index, key) in keys.enumerated() {
                let first = scratch.scaleTemporaryByteCount(for: key) { queries += 1; return vImage_Error(index * 13) }
                let repeated = scratch.scaleTemporaryByteCount(for: key) { queries += 1; return -99 }
                r.equal("complete-layout result cached", repeated, first)
                r.equal("one query per changed signature", queries, index + 1)
            }
            r.equal("zero-byte requirement is a valid cached success", ReusedScratch().scaleTemporaryByteCount(for: signature()) { 0 }, 0)
            let count = scratch.scaleTemporaryQueryCount
            let failed = scratch.scaleTemporaryByteCount(for: signature(width: 99)) { kvImageNullPointerArgument }
            let retried = scratch.scaleTemporaryByteCount(for: signature(width: 99)) { 0 }
            r.equal("query error is returned intact", failed, kvImageNullPointerArgument)
            r.equal("failed query can retry successfully", retried, 0)
            r.equal("query failure never becomes a cached hit", scratch.scaleTemporaryQueryCount, count + 2)

            let nativeScratch = ReusedScratch()
            _ = scale(plane(), scratch: nativeScratch)
            _ = scale(plane(stride: 96), stride: 96, scratch: nativeScratch)
            _ = scale(plane(height: 40, stride: 96), height: 40, stride: 96, scratch: nativeScratch)
            _ = scale(plane(width: 80, stride: 96), width: 80, stride: 96, scratch: nativeScratch)
            _ = scale(plane(width: 80, stride: 96), width: 80, stride: 96, edge: 24, scratch: nativeScratch)
            r.equal("actual stride/source/destination changes requery native setup", nativeScratch.scaleTemporaryQueryCount, 5)
        },
        TCCase(id: "PC56F", title: "A real scale failure still executes the deterministic fallback under a cached temporary requirement") { r in
            let calls = Mutex((queries: 0, scales: 0)), scratch = ReusedScratch()
            let native = PreviewAnalysisMath.LumaScaleOperation.native
            let failing = PreviewAnalysisMath.LumaScaleOperation { source, destination, temporary, flags in
                if flags & vImage_Flags(kvImageGetTempBufferSize) != 0 {
                    calls.withLock { $0.queries += 1 }
                    return native.run(&source, &destination, temporary, flags)
                }
                calls.withLock { $0.scales += 1 }
                return kvImageNullPointerArgument
            }
            for seed in [0, 47] {
                let input = plane(seed: seed)
                let actual = scale(input, scratch: scratch, operation: failing)
                let oracle = scale(input, scratch: ReusedScratch(), accelerate: false)
                r.equal("native error falls back to exact box-average bytes", actual.sample?.luma, oracle.sample?.luma)
                r.equal("fallback remains explicitly classified", actual.record?.usedAccelerateScale, false)
                r.check("real scale error remains diagnosed", scratch.lastAccelerateFailureReason?.contains("\(kvImageNullPointerArgument)") == true)
            }
            r.equal("successful size requirement reused across failed scales", calls.withLock { $0.queries }, 1)
            r.equal("actual scale is retried for each current frame", calls.withLock { $0.scales }, 2)
            let fallbackScratch = ReusedScratch()
            _ = scale(plane(), scratch: fallbackScratch, accelerate: false)
            r.equal("explicit fallback never invokes native setup", fallbackScratch.scaleTemporaryQueryCount, 0)
        },
        TCCase(id: "PC56L", title: "Immutable range tables preserve every normalization value and cannot be changed by a caller") { r in
            for range in [PreviewCodeRange.full, .video] {
                let original = PreviewAnalysisMath.normalizationTable(for: range)
                r.equal("complete byte-value table", original.count, 256)
                for value in 0...255 {
                    let raw = range == .full ? Double(value) : (Double(value) - 16) / 219 * 255
                    let expected = UInt8(min(255, max(0, raw.rounded())))
                    r.equal("normalization byte \(value) preserved", original[value], expected)
                }
                var local = original; local[0] = 99
                r.equal("caller can modify its own value copy", local[0], 99)
                r.equal("caller mutation cannot poison shared table", PreviewAnalysisMath.normalizationTable(for: range), original)
            }
            let sample = [UInt8](repeating: 16, count: 8 * 8)
            let scratch = ReusedScratch()
            let first = scale(sample, width: 8, height: 8, stride: 8, edge: 8, scratch: scratch)
            r.equal("identity path uses exact black normalization", first.sample?.luma, [UInt8](repeating: 0, count: 64))
            r.equal("identity normalization does not create a native setup query", scratch.scaleTemporaryQueryCount, 0)
        },
        TCCase(id: "PC56R", title: "Disabling image aids releases their diagnostic payloads without resetting scalar counts") { r in
            let clock = VirtualMonotonicClock(start: 0), service = MeteringService(clock: clock)
            let full = imageRequest()
            await service.setDemand(full)
            for ordinal in 0..<4 {
                clock.advance(by: 0.2)
                await service.submit(sample: imageSample(full, ordinal: ordinal))
            }
            r.check("large image history really exists", await service.recentImagePayloadByteCount > 2 * 1024 * 1024)
            let outputs = await service.emittedOutputCount, loupes = await service.emittedLoupeCount
            let masks = await service.emittedMaskCount, histograms = await service.emittedHistogramCount
            await service.setDemand(imageRequest(loupe: false))
            let afterLoupe = await service.recentOutputsForTesting
            r.check("disabled loupe frames leave the diagnostic ring", !afterLoupe.contains { if case .loupe = $0 { true } else { false } })
            r.check("still-enabled mask history remains useful", afterLoupe.contains { if case .masks = $0 { true } else { false } })
            await service.setDemand(imageRequest(loupe: false, peaking: false))
            r.equal("combined snapshots cannot retain a disabled peaking plane", await service.recentImagePayloadByteCount, 0)
            r.equal("no synthetic output emitted by cleanup", await service.emittedOutputCount, outputs)
            r.equal("historical loupe counter preserved", await service.emittedLoupeCount, loupes)
            r.equal("historical mask counter preserved", await service.emittedMaskCount, masks)
            r.equal("historical histogram counter preserved", await service.emittedHistogramCount, histograms)
            await service.setDemand(full)
            clock.advance(by: 0.2)
            await service.submit(sample: imageSample(full, ordinal: 5))
            r.equal("fresh loupe resumes after reenable", await service.emittedLoupeCount, loupes + 1)
            let fresh = await service.recentOutputsForTesting
            r.check("new image owns its original source timestamp", fresh.contains {
                if case .loupe(let value) = $0 { value.mappedAtUTC == StorageFixture.fixedDate.addingTimeInterval(5) } else { false }
            })
            await service.stop()
        },
        TCCase(id: "PC56A", title: "Stop, nil and empty demand discard all diagnostic image ownership and permit a current resume") { r in
            for mode in 0..<3 {
                let clock = VirtualMonotonicClock(start: 0), service = MeteringService(clock: clock)
                let full = imageRequest()
                await service.setDemand(full)
                for ordinal in 0..<3 {
                    clock.advance(by: 0.2)
                    await service.submit(sample: imageSample(full, ordinal: ordinal))
                }
                r.check("stop fixture retains large frames before cleanup", await service.recentImagePayloadByteCount > 1024 * 1024)
                let emitted = await service.emittedOutputCount, loupes = await service.emittedLoupeCount
                if mode == 0 { await service.stop() }
                else if mode == 1 { await service.setDemand(nil) }
                else {
                    await service.setDemand(AnalysisRequest(configurationGeneration: full.configurationGeneration,
                        geometry: full.geometry, demand: .none, peakingThreshold: full.peakingThreshold,
                        zebraThreshold: full.zebraThreshold, loupeCenter: full.loupeCenter,
                        loupeMagnification: full.loupeMagnification))
                }
                r.equal("stopped history owns no image payload", await service.recentImagePayloadByteCount, 0)
                r.equal("stopped diagnostic history is empty", await service.recentOutputsForTesting.count, 0)
                r.equal("stop retains scalar evidence", await service.emittedOutputCount, emitted)
                r.check("scratch released with stopped images", await service.isScratchReleased)
                await service.submit(sample: imageSample(full, ordinal: 6))
                r.equal("stopped samples cannot refill history", await service.recentImagePayloadByteCount, 0)
                r.equal("stopped samples emit nothing", await service.emittedOutputCount, emitted)
                await service.setDemand(full)
                await service.submit(sample: imageSample(full, ordinal: 7))
                r.equal("first current loupe resumes immediately", await service.emittedLoupeCount, loupes + 1)
                r.check("fresh image ownership can resume", await service.recentImagePayloadByteCount > 0)
                await service.stop()
            }
        },
        TCCase(id: "PC56T", title: "Pressure reduction releases diagnostic images while retaining counts and ordinary reduced-rate output") { r in
            let clock = VirtualMonotonicClock(start: 0), service = MeteringService(clock: clock)
            let full = imageRequest()
            await service.setDemand(full)
            for ordinal in 0..<3 {
                clock.advance(by: 0.2)
                await service.submit(sample: imageSample(full, ordinal: ordinal))
            }
            let loupes = await service.emittedLoupeCount, masks = await service.emittedMaskCount
            let emitted = await service.emittedOutputCount
            await service.setRateLimits(.nominal.scaled(by: 0.5))
            r.equal("reduced rates release old large-image history", await service.recentImagePayloadByteCount, 0)
            r.equal("pressure cleanup does not emit or alter evidence", await service.emittedOutputCount, emitted)
            clock.advance(by: 0.2)
            await service.submit(sample: imageSample(full, ordinal: 8))
            r.equal("reduced-rate loupe still emits current data", await service.emittedLoupeCount, loupes + 1)
            r.equal("reduced-rate masks still emit current data", await service.emittedMaskCount, masks + 1)
            let critical = AnalysisDemandPolicy.decide(configuration: PreviewAidConfiguration(isHistogramEnabled: true,
                isPeakingEnabled: true, peakingThreshold: .normal, isZebrasEnabled: true,
                zebraThreshold: .default, isLoupeEnabled: true, loupeMagnification: 2, loupeCenter: .center),
                lifecycle: .activeCameraView, pressure: AnalysisResourcePressure(thermal: .critical), geometry: full.geometry)
            await service.setDemand(critical.request)
            r.equal("critical paused aids do not retain their prior images", await service.recentImagePayloadByteCount, 0)
            r.equal("critical demand preserves historical frame counts", await service.emittedLoupeCount, loupes + 1)
            await service.stop()
        }
    ])
}
