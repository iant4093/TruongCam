#if canImport(UIKit) && canImport(XCTest) && !TC_TESTKIT_STANDALONE
import CoreMedia
import CoreVideo
import Synchronization
import XCTest
@testable import TruongCam

private actor GraphHandoffSampleConsumer: AnalysisSampleConsumer {
    func consume(outcome: LumaDownsampleOutcome, geometry: PreviewGeometrySnapshot?) async {}
}

private actor PackedPlaneSampleConsumer: AnalysisSampleConsumer {
    private(set) var sample: LuminanceSample?
    func consume(outcome: LumaDownsampleOutcome, geometry: PreviewGeometrySnapshot?) async {
        sample = outcome.sample
    }
}

final class NativeAnalysisGraphHandoffTests: XCTestCase {
    @MainActor func testPackedNativePlanesExcludePaddingAndSurviveBufferReuse() async throws {
        let sample = SessionOwned(try makeSample(rowAlignment: 64))
        let buffer = try XCTUnwrap(CMSampleBufferGetImageBuffer(sample.value))
        XCTAssertEqual(CVPixelBufferLockBaseAddress(buffer, []), kCVReturnSuccess)
        let ys = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0)
        let cs = CVPixelBufferGetBytesPerRowOfPlane(buffer, 1)
        let y = try XCTUnwrap(CVPixelBufferGetBaseAddressOfPlane(buffer, 0)).assumingMemoryBound(to: UInt8.self)
        let uv = try XCTUnwrap(CVPixelBufferGetBaseAddressOfPlane(buffer, 1)).assumingMemoryBound(to: UInt8.self)
        XCTAssertGreaterThan(ys, 8, "The native fixture must contain real row padding.")
        XCTAssertGreaterThan(cs, 8)
        memset(y, 253, ys * 4); memset(uv, 254, cs * 2)
        var expectedY: [UInt8] = []
        for row in 0..<4 {
            for column in 0..<8 { expectedY.append(UInt8(16 + row * 20 + column)) }
        }
        let expectedUV = (0..<16).map { UInt8(40 + $0 * 7) }
        for row in 0..<4 { for column in 0..<8 { y[row * ys + column] = expectedY[row * 8 + column] } }
        for row in 0..<2 { for column in 0..<8 { uv[row * cs + column] = expectedUV[row * 8 + column] } }
        let chroma = try XCTUnwrap(AnalysisSampleBufferHandler.copyHistogramChroma(pixelBuffer: buffer))
        let histogram = try XCTUnwrap(AnalysisSampleBufferHandler.rgbHistogram(pixelBuffer: buffer))
        CVPixelBufferUnlockBaseAddress(buffer, [])
        XCTAssertEqual(chroma.bytes, expectedUV, "Every packed chroma byte is initialized from active pixels, never native padding.")

        let generation = SessionGenerationSource(), consumer = PackedPlaneSampleConsumer()
        generation.update(configuration: .zero, layout: 0, histogramEnabled: true)
        let entered = Mutex(false), release = DispatchSemaphore(value: 0), admission = SampleAdmission()
        defer { release.signal() }
        let handler = AnalysisSampleBufferHandler(consumer: consumer, generationProvider: generation,
            admission: admission, beforeOwnedAnalysis: {
                entered.withLock { $0 = true }; _ = release.wait(timeout: .now() + 5)
            })
        await SerialSessionQueue(label: "TruongCam.test.packed-planes").perform {
            handler.processSampleBuffer(sample.value)
        }
        for _ in 0..<1_000 where !entered.withLock({ $0 }) { try await Task.sleep(for: .milliseconds(1)) }
        XCTAssertTrue(entered.withLock { $0 })
        XCTAssertEqual(CVPixelBufferLockBaseAddress(buffer, []), kCVReturnSuccess)
        memset(try XCTUnwrap(CVPixelBufferGetBaseAddressOfPlane(buffer, 0)), 0, ys * 4)
        memset(try XCTUnwrap(CVPixelBufferGetBaseAddressOfPlane(buffer, 1)), 0, cs * 2)
        CVPixelBufferUnlockBaseAddress(buffer, [])
        release.signal()
        for _ in 0..<1_000 where admission.isFrameInFlight { try await Task.sleep(for: .milliseconds(1)) }
        XCTAssertFalse(admission.isFrameInFlight)
        let delivered = await consumer.sample
        let owned = try XCTUnwrap(delivered)
        XCTAssertEqual(owned.width, 8); XCTAssertEqual(owned.height, 4)
        XCTAssertEqual(owned.luma, expectedY, "Every packed luma row survives reuse of the native buffer.")
        XCTAssertEqual(owned.rgbHistogram, histogram, "Packing preserves the independent native-stride RGB reference.")
        XCTAssertEqual(chroma.bytes, expectedUV)
    }

    @MainActor func testHeldActualCallbackDrainsBeforeGraphAndPausedCallbacksCannotPublishFrame() async throws {
        let bridge = PreviewDisplayBridge()
        let generation = SessionGenerationSource()
        let sample = SessionOwned(try makeSample())
        let enteredCallback = Mutex(false)
        let enteredGraph = Mutex(false)
        let clockCalls = Mutex(0)
        let admission = SampleAdmission()
        let releaseCallback = DispatchSemaphore(value: 0)
        defer { releaseCallback.signal() }
        let handler = AnalysisSampleBufferHandler(consumer: GraphHandoffSampleConsumer(),
            generationProvider: generation, admission: admission, displayBridge: bridge, currentInstant: {
                let first = clockCalls.withLock { value in value += 1; return value == 1 }
                if first {
                    enteredCallback.withLock { $0 = true }
                    _ = releaseCallback.wait(timeout: .now() + 3)
                }
                return 100 + Double(clockCalls.withLock { $0 })
            })
        let callback = Task {
            await SerialSessionQueue(label: "TruongCam.test.held-analysis").perform {
                handler.processSampleBuffer(sample.value)
            }
        }
        for _ in 0..<200 where !enteredCallback.withLock({ $0 }) {
            try await Task.sleep(for: .milliseconds(1))
        }
        XCTAssertTrue(enteredCallback.withLock { $0 })
        XCTAssertEqual(bridge.nativeAccessGate.snapshot.frameReadCount, 1)
        let graph = Task { @MainActor in
            let lease = await bridge.nativeAccessGate.pauseAndDrainFrames()
            enteredGraph.withLock { $0 = true }
            return lease
        }
        for _ in 0..<200 where bridge.nativeAccessGate.snapshot.waitingDrainCount == 0 {
            try await Task.sleep(for: .milliseconds(1))
        }
        XCTAssertEqual(bridge.nativeAccessGate.snapshot.waitingDrainCount, 1)
        XCTAssertFalse(enteredGraph.withLock { $0 }, "Graph work must await the borrowed native sample callback.")
        // This is the real handler, called while a graph pause is pending. It
        // must return before the clock hook, buffer lock, bitmap or consumer.
        handler.processSampleBuffer(sample.value)
        XCTAssertEqual(clockCalls.withLock { $0 }, 1)
        XCTAssertEqual(bridge.nativeAccessGate.snapshot.frameReadCount, 1)
        releaseCallback.signal()
        await callback.value
        let lease = await graph.value
        XCTAssertTrue(enteredGraph.withLock { $0 })
        XCTAssertEqual(bridge.nativeAccessGate.snapshot.frameReadCount, 0)
        let geometry = makeGeometry()
        bridge.setGeometry(geometry)
        generation.update(configuration: geometry.configurationGeneration,
            layout: geometry.layoutGeneration, histogramEnabled: false)
        handler.processSampleBuffer(sample.value)
        XCTAssertFalse(bridge.hasCurrentFrame(for: geometry), "Paused callbacks cannot acknowledge the replacement camera.")
        XCTAssertNil(bridge.frozenFrame(for: geometry))
        XCTAssertEqual(clockCalls.withLock { $0 }, 1)
        lease.release()
        // The optional still now shares admitted owned analysis. Let the earlier
        // unlaid-out sample finish, and use a genuinely later acquisition instant.
        for _ in 0..<1_000 where admission.isFrameInFlight { try await Task.sleep(for: .milliseconds(1)) }
        XCTAssertFalse(admission.isFrameInFlight)
        handler.processSampleBuffer(sample.value)
        XCTAssertTrue(bridge.hasCurrentFrame(for: geometry), "A post-commit sample resumes current-frame acknowledgement.")
        for _ in 0..<1_000 where bridge.frozenFrame(for: geometry) == nil { try await Task.sleep(for: .milliseconds(1)) }
        XCTAssertNotNil(bridge.frozenFrame(for: geometry))
        XCTAssertEqual(clockCalls.withLock { $0 }, 2)
        XCTAssertEqual(bridge.nativeAccessGate.snapshot.frameReadCount, 0)
    }

    @MainActor func testColdOwnedMathCannotHoldTheNativeGraphReadLease() async throws {
        let bridge = PreviewDisplayBridge(), generation = SessionGenerationSource()
        let sample = SessionOwned(try makeSample())
        let entered = Mutex(false), release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        let handler = AnalysisSampleBufferHandler(consumer: GraphHandoffSampleConsumer(),
            generationProvider: generation, displayBridge: bridge, beforeOwnedAnalysis: {
                entered.withLock { $0 = true }; _ = release.wait(timeout: .now() + 3)
            })
        let callback = Task { await SerialSessionQueue().perform { handler.processSampleBuffer(sample.value) } }
        for _ in 0..<200 where !entered.withLock({ $0 }) { try await Task.sleep(for: .milliseconds(1)) }
        XCTAssertTrue(entered.withLock { $0 })
        XCTAssertEqual(bridge.nativeAccessGate.snapshot.frameReadCount, 0)
        let lease = await bridge.nativeAccessGate.pauseAndDrainFrames()
        XCTAssertEqual(bridge.nativeAccessGate.snapshot.waitingDrainCount, 0,
            "Cold vImage/owned math must not postpone a camera graph operation.")
        release.signal(); await callback.value; lease.release()
        XCTAssertEqual(bridge.nativeAccessGate.snapshot.pauseCount, 0)
    }

    @MainActor func testOwnedChromaAndTransitionSamplesRemainCorrectAfterNativeBufferChanges() async throws {
        let sample = try makeSample()
        let buffer = try XCTUnwrap(CMSampleBufferGetImageBuffer(sample))
        XCTAssertEqual(CVPixelBufferLockBaseAddress(buffer, .readOnly), kCVReturnSuccess)
        let chroma = try XCTUnwrap(AnalysisSampleBufferHandler.copyHistogramChroma(pixelBuffer: buffer))
        let reference = try XCTUnwrap(AnalysisSampleBufferHandler.rgbHistogram(pixelBuffer: buffer))
        let y = [UInt8](repeating: 120, count: 8 * 4)
        CVPixelBufferUnlockBaseAddress(buffer, .readOnly)
        let transition = try XCTUnwrap(PreviewDisplayBridge.transitionSamples(buffer))
        XCTAssertEqual(CVPixelBufferLockBaseAddress(buffer, []), kCVReturnSuccess)
        memset(try XCTUnwrap(CVPixelBufferGetBaseAddressOfPlane(buffer, 0)), 0,
            CVPixelBufferGetBytesPerRowOfPlane(buffer, 0) * 4)
        memset(try XCTUnwrap(CVPixelBufferGetBaseAddressOfPlane(buffer, 1)), 255,
            CVPixelBufferGetBytesPerRowOfPlane(buffer, 1) * 2)
        CVPixelBufferUnlockBaseAddress(buffer, [])
        XCTAssertEqual(chroma.histogram(luma: y, width: 8, height: 4), reference,
            "Owned chroma keeps the exact existing RGB calculation after the native frame is reused.")
        let pixels = try XCTUnwrap(transition.render(rotation: 90, mirrored: true))
        XCTAssertEqual(pixels.width, 4); XCTAssertEqual(pixels.height, 8)
        XCTAssertEqual(pixels.bytes.first, 120, "Color conversion reads owned pre-mutation bytes.")
        let snapshot = MaskSnapshot(width: 2, height: 2, geometryGeneration: 9,
            configurationGeneration: ConfigurationGeneration(7), peakingMask: [0,255,255,0],
            zebraMask: [255,0,0,255], peakingThreshold: 0.5, zebraThreshold: 0.95, mappedAtUTC: Date())
        let rendered = await PreviewMaskImageRenderer.shared.render(snapshot)
        XCTAssertEqual(rendered?.peaking?.width, 2); XCTAssertEqual(rendered?.zebras?.height, 2)
        XCTAssertEqual(rendered?.layout, 9); XCTAssertEqual(rendered?.capturedAt, snapshot.mappedAtUTC)
    }

    @MainActor func testMaskPreparationCoalescesWithoutCancellingEveryNewFrame() async throws {
        let hold = PrepareHold(), calls = Mutex<[Date]>([]), cancelled = Mutex(false)
        let presentation = PreviewMaskPresentation { sample in
            let first = calls.withLock { value in value.append(sample.mappedAtUTC); return value.count == 1 }
            if first { await hold.wait() }
            cancelled.withLock { $0 = $0 || Task.isCancelled }
            return await PreviewMaskImageRenderer.shared.render(sample)
        }
        func mask(_ date: Date, generation: UInt64 = 7) -> MaskSnapshot {
            MaskSnapshot(width: 2, height: 2, geometryGeneration: 9,
                configurationGeneration: ConfigurationGeneration(generation), peakingMask: [0,255,255,0],
                zebraMask: [255,0,0,255], peakingThreshold: 0.5, zebraThreshold: 0.95, mappedAtUTC: date)
        }
        let first = Date(), middle = first.addingTimeInterval(0.001), newest = first.addingTimeInterval(0.002)
        presentation.submit(mask(first))
        for _ in 0..<200 where !(await hold.didEnter) { try await Task.sleep(for: .milliseconds(1)) }
        let didEnter = await hold.didEnter
        XCTAssertTrue(didEnter)
        presentation.submit(mask(middle)); presentation.submit(mask(newest))
        await hold.release()
        for _ in 0..<500 where presentation.prepared?.capturedAt != newest { try await Task.sleep(for: .milliseconds(1)) }
        XCTAssertEqual(calls.withLock { $0 }, [first, newest], "Only one in-flight render and the newest queued sample survive.")
        XCTAssertFalse(cancelled.withLock { $0 }, "Normal frame updates must not starve image publication by cancellation.")
        XCTAssertEqual(presentation.prepared?.capturedAt, newest)
        presentation.invalidate()
        XCTAssertNil(presentation.prepared)
    }

    func testPreviewAcknowledgementNeedsNoNativeBufferOrCPUStillRead() {
        let bridge = PreviewDisplayBridge(), geometry = makeGeometry()
        bridge.setGeometry(geometry)
        let plan = bridge.acknowledgePreviewBuffer(configuration: geometry.configurationGeneration, layout: geometry.layoutGeneration)
        XCTAssertNotNil(plan)
        XCTAssertTrue(bridge.hasCurrentFrame(for: geometry))
        XCTAssertNil(bridge.frozenFrame(for: geometry), "Acknowledgement never locks/converts an optional still.")
    }

    func testPhotoPriorityDefersOnlyAnalysisAndAlwaysReleasesItsCountedBudget() async throws {
        let bridge = PreviewDisplayBridge(), generation = SessionGenerationSource()
        let geometry = makeGeometry(), admission = SampleAdmission()
        bridge.setGeometry(geometry)
        generation.update(configuration: geometry.configurationGeneration, layout: geometry.layoutGeneration, histogramEnabled: false)
        let handler = AnalysisSampleBufferHandler(consumer: GraphHandoffSampleConsumer(), generationProvider: generation,
            admission: admission, displayBridge: bridge)
        let first = bridge.prioritizePhotoWork(), second = bridge.prioritizePhotoWork()
        XCTAssertTrue(bridge.shouldDeferAnalysisForPhoto)
        handler.processSampleBuffer(try makeSample())
        XCTAssertTrue(bridge.hasCurrentFrame(for: geometry), "Photo priority never closes real preview acknowledgement.")
        XCTAssertFalse(admission.isFrameInFlight)
        XCTAssertEqual(handler.snapshot.accepted, 0, "No cold analysis/conversion competes with RAW serialization.")
        XCTAssertEqual(bridge.nativeAccessGate.snapshot.pauseCount, 0, "Photo priority cannot hold the main preview/graph gate.")
        first.release(); first.release()
        XCTAssertTrue(bridge.shouldDeferAnalysisForPhoto, "One request cannot release another request's budget.")
        second.release()
        XCTAssertFalse(bridge.shouldDeferAnalysisForPhoto)
        handler.processSampleBuffer(try makeSample())
        for _ in 0..<1_000 where admission.isFrameInFlight { try await Task.sleep(for: .milliseconds(1)) }
        XCTAssertEqual(handler.snapshot.accepted, 1, "Analysis resumes without changing native output topology.")
        do { let scoped = bridge.prioritizePhotoWork(); XCTAssertTrue(bridge.shouldDeferAnalysisForPhoto); _ = scoped }
        XCTAssertFalse(bridge.shouldDeferAnalysisForPhoto, "Abandoned scopes also release the budget.")
    }

    func testPreparationPriorityKeepsPreviewAcknowledgementAndPhotoAndGraphOwnersIndependent() async throws {
        let bridge = PreviewDisplayBridge(), generation = SessionGenerationSource()
        let geometry = makeGeometry(), admission = SampleAdmission()
        let ranOwnedWork = Mutex(false)
        bridge.setGeometry(geometry)
        generation.update(configuration: geometry.configurationGeneration, layout: geometry.layoutGeneration, histogramEnabled: false)
        let handler = AnalysisSampleBufferHandler(consumer: GraphHandoffSampleConsumer(), generationProvider: generation,
            admission: admission, displayBridge: bridge, beforeOwnedAnalysis: { ranOwnedWork.withLock { $0 = true } })
        let preparation = bridge.prioritizeCameraPreparation()
        handler.processSampleBuffer(try makeSample())
        try await Task.sleep(for: .milliseconds(10))
        XCTAssertFalse(ranOwnedWork.withLock { $0 }, "Preparation alone rejects before optional native copying and owned math.")
        XCTAssertTrue(bridge.hasCurrentFrame(for: geometry))
        XCTAssertFalse(admission.isFrameInFlight)
        let photo = bridge.prioritizePhotoWork()
        handler.processSampleBuffer(try makeSample())
        XCTAssertTrue(bridge.hasCurrentFrame(for: geometry), "Native readiness acknowledgement stays independent of optional math.")
        XCTAssertEqual(handler.snapshot.accepted, 0)
        XCTAssertFalse(admission.isFrameInFlight)
        XCTAssertEqual(bridge.nativeAccessGate.snapshot.pauseCount, 0)
        preparation.release()
        XCTAssertFalse(bridge.shouldDeferAnalysisForCameraPreparation)
        XCTAssertTrue(bridge.shouldDeferAnalysisForPhoto, "Releasing a preparation cannot spend a live photo's priority.")
        photo.release()
        do { let scoped = bridge.prioritizeCameraPreparation(); XCTAssertTrue(bridge.shouldDeferAnalysisForCameraPreparation); _ = scoped }
        XCTAssertFalse(bridge.shouldDeferAnalysisForCameraPreparation)
        handler.processSampleBuffer(try makeSample())
        for _ in 0..<1_000 where admission.isFrameInFlight { try await Task.sleep(for: .milliseconds(1)) }
        XCTAssertEqual(handler.snapshot.accepted, 1)
    }

    private func makeGeometry() -> PreviewGeometrySnapshot {
        PreviewGeometrySnapshot(configurationGeneration: ConfigurationGeneration(7), layoutGeneration: 9,
            imageDimensions: PixelDimensions(width: 8, height: 4), cleanApertureDimensions: nil,
            previewLayerContentRect: TCRect(x: 0, y: 0, width: 200, height: 100), bufferOrientation: 1,
            isMirrored: false, analysisRotationDegrees: 0, isVideoMirrored: false, capturedAtUTC: Date())
    }

    private func makeSample(rowAlignment: Int? = nil) throws -> CMSampleBuffer {
        var pixel: CVPixelBuffer?
        let attributes = rowAlignment.map { [kCVPixelBufferBytesPerRowAlignmentKey as String: $0] as CFDictionary }
        XCTAssertEqual(CVPixelBufferCreate(nil, 8, 4, kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
            attributes, &pixel), kCVReturnSuccess)
        let buffer = try XCTUnwrap(pixel)
        XCTAssertEqual(CVPixelBufferLockBaseAddress(buffer, []), kCVReturnSuccess)
        if let y = CVPixelBufferGetBaseAddressOfPlane(buffer, 0) {
            memset(y, 120, CVPixelBufferGetBytesPerRowOfPlane(buffer, 0) * 4)
        }
        if let uv = CVPixelBufferGetBaseAddressOfPlane(buffer, 1) {
            memset(uv, 128, CVPixelBufferGetBytesPerRowOfPlane(buffer, 1) * 2)
        }
        CVPixelBufferUnlockBaseAddress(buffer, [])
        CVBufferSetAttachment(buffer, kCVImageBufferYCbCrMatrixKey,
            kCVImageBufferYCbCrMatrix_ITU_R_709_2, .shouldPropagate)
        var format: CMVideoFormatDescription?
        XCTAssertEqual(CMVideoFormatDescriptionCreateForImageBuffer(allocator: kCFAllocatorDefault,
            imageBuffer: buffer, formatDescriptionOut: &format), noErr)
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 30),
            presentationTimeStamp: .zero, decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        XCTAssertEqual(CMSampleBufferCreateReadyWithImageBuffer(allocator: kCFAllocatorDefault,
            imageBuffer: buffer, formatDescription: try XCTUnwrap(format), sampleTiming: &timing,
            sampleBufferOut: &sample), noErr)
        return try XCTUnwrap(sample)
    }
}
#endif
