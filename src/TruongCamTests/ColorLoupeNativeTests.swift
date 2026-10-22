#if canImport(UIKit) && canImport(XCTest) && !TC_TESTKIT_STANDALONE
import CoreMedia
import CoreVideo
import Synchronization
import XCTest
@testable import TruongCam

private actor Color52Consumer: AnalysisSampleConsumer {
    private(set) var sample: LuminanceSample?
    private(set) var count = 0
    func consume(outcome: LumaDownsampleOutcome, geometry: PreviewGeometrySnapshot?) async { sample = outcome.sample; count += 1 }
}

final class ColorLoupeNativeTests: XCTestCase {
    private func request() -> AnalysisRequest {
        let q = ColorLoupeSuite.request()
        var demand = q.demand; demand.histogramEnabled = false
        return AnalysisRequest(configurationGeneration: q.configurationGeneration, geometry: q.geometry, demand: demand,
            peakingThreshold: q.peakingThreshold, zebraThreshold: q.zebraThreshold, loupeCenter: q.loupeCenter, loupeMagnification: q.loupeMagnification)
    }
    private func sample(width: Int = 1024, height: Int = 768) throws -> CMSampleBuffer {
        var pixel: CVPixelBuffer?
        let attributes = [kCVPixelBufferBytesPerRowAlignmentKey as String: 2048] as CFDictionary
        XCTAssertEqual(CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
            attributes, &pixel), kCVReturnSuccess)
        let buffer = try XCTUnwrap(pixel)
        XCTAssertEqual(CVPixelBufferLockBaseAddress(buffer, []), kCVReturnSuccess)
        let y = try XCTUnwrap(CVPixelBufferGetBaseAddressOfPlane(buffer, 0)).assumingMemoryBound(to: UInt8.self)
        let uv = try XCTUnwrap(CVPixelBufferGetBaseAddressOfPlane(buffer, 1)).assumingMemoryBound(to: UInt8.self)
        let ys = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0), us = CVPixelBufferGetBytesPerRowOfPlane(buffer, 1)
        XCTAssertGreaterThan(ys, width); XCTAssertGreaterThan(us, width)
        memset(y, 253, ys * height); memset(uv, 254, us * (height / 2))
        for row in 0..<height { for column in 0..<width { y[row * ys + column] = column % 2 == 0 ? 48 : 180 } }
        for row in 0..<(height / 2) { for column in stride(from: 0, to: width, by: 2) { uv[row * us + column] = 90; uv[row * us + column + 1] = 220 } }
        CVPixelBufferUnlockBaseAddress(buffer, [])
        CVBufferSetAttachment(buffer, kCVImageBufferYCbCrMatrixKey, kCVImageBufferYCbCrMatrix_ITU_R_601_4, .shouldPropagate)
        var format: CMVideoFormatDescription?
        XCTAssertEqual(CMVideoFormatDescriptionCreateForImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: buffer, formatDescriptionOut: &format), noErr)
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 30), presentationTimeStamp: .zero, decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        XCTAssertEqual(CMSampleBufferCreateReadyWithImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: buffer,
            formatDescription: try XCTUnwrap(format), sampleTiming: &timing, sampleBufferOut: &sample), noErr)
        return try XCTUnwrap(sample)
    }
    @MainActor private func wait(_ condition: () async -> Bool) async throws {
        for _ in 0..<1000 { if await condition() { return }; try await Task.sleep(for: .milliseconds(2)) }
        XCTFail("Owned color preview work did not reach its expected boundary")
        throw CocoaError(.featureUnsupported)
    }
    @MainActor func testNativeColorCropUsesOwnedActivePixelsWithoutHistogramOrPaddingAndSurvivesBufferReuse() async throws {
        let native = SessionOwned(try sample()), source = SessionGenerationSource(), consumer = Color52Consumer()
        let q = request()
        source.update(configuration: q.configurationGeneration, layout: 2, histogramEnabled: false, request: q)
        let gate = DispatchSemaphore(value: 0), entered = Mutex(false), admission = SampleAdmission()
        defer { gate.signal() }
        let handler = AnalysisSampleBufferHandler(consumer: consumer, generationProvider: source, admission: admission,
            beforeOwnedAnalysis: { entered.withLock { $0 = true }; _ = gate.wait(timeout: .now() + 5) })
        await SerialSessionQueue(label: "TruongCam.test.color52").perform { handler.processSampleBuffer(native.value) }
        try await wait { entered.withLock { $0 } }
        let buffer = try XCTUnwrap(CMSampleBufferGetImageBuffer(native.value))
        XCTAssertEqual(CVPixelBufferLockBaseAddress(buffer, []), kCVReturnSuccess)
        memset(try XCTUnwrap(CVPixelBufferGetBaseAddressOfPlane(buffer, 0)), 0, CVPixelBufferGetBytesPerRowOfPlane(buffer, 0) * 768)
        memset(try XCTUnwrap(CVPixelBufferGetBaseAddressOfPlane(buffer, 1)), 128, CVPixelBufferGetBytesPerRowOfPlane(buffer, 1) * 384)
        CVPixelBufferUnlockBaseAddress(buffer, [])
        gate.signal()
        try await wait { !admission.isFrameInFlight }
        let delivered = await consumer.sample
        let output = try XCTUnwrap(delivered), color = try XCTUnwrap(output.colorLoupe)
        XCTAssertTrue(output.requiresColorLoupe); XCTAssertNil(output.rgbHistogram)
        XCTAssertLessThanOrEqual(output.width, 320, "Masks retain their small working plane")
        XCTAssertEqual(color.snapshot.width, 512, "Loupe keeps native detail before whole-frame downsampling")
        let expected = try XCTUnwrap(ColorLoupeSuite.color(request: q, date: output.capturedAtUTC))
        XCTAssertEqual(color.snapshot.rgbaBytes, expected.snapshot.rgbaBytes, "Native padding/reuse cannot corrupt owned Y or UV")
        XCTAssertEqual(color.snapshot.configurationGeneration, q.configurationGeneration)
        XCTAssertEqual(color.snapshot.geometryGeneration, 2)
    }
    @MainActor func testQueuedNativeColorWorkRejectsChangedCenterAndReleasesSingleFrameAdmission() async throws {
        let native = SessionOwned(try sample()), source = SessionGenerationSource(), consumer = Color52Consumer()
        let q = request()
        source.update(configuration: q.configurationGeneration, layout: 2, histogramEnabled: false, request: q)
        let gate = DispatchSemaphore(value: 0), entered = Mutex(false), admission = SampleAdmission()
        defer { gate.signal() }
        let handler = AnalysisSampleBufferHandler(consumer: consumer, generationProvider: source, admission: admission,
            beforeOwnedAnalysis: { entered.withLock { $0 = true }; _ = gate.wait(timeout: .now() + 5) })
        await SerialSessionQueue(label: "TruongCam.test.stale-color52").perform { handler.processSampleBuffer(native.value) }
        try await wait { entered.withLock { $0 } }
        let moved = ColorLoupeSuite.request(center: NormalizedDevicePoint(x: 0.9, y: 0.1))
        source.update(configuration: q.configurationGeneration, layout: 2, histogramEnabled: true, request: moved)
        gate.signal(); try await wait { !admission.isFrameInFlight }
        let delivered = await consumer.sample
        XCTAssertNil(delivered, "An old center cannot become a new color crop")
        XCTAssertGreaterThan(handler.snapshot.rejected, 0)
    }
    @MainActor func testNativeLoupeAcquisitionAdmitsThirtyHzWithOrWithoutMasksAndNeverQueuesABusyFrame() async throws {
        let native = SessionOwned(try sample(width: 16, height: 12))
        let source = SessionGenerationSource(), consumer = Color52Consumer(), admission = SampleAdmission()
        let clock = Mutex(0.0), queue = SerialSessionQueue(label: "TruongCam.test.loupe54-rate")
        let q = request()
        source.update(configuration: q.configurationGeneration, layout: 2, histogramEnabled: false, request: q)
        let handler = AnalysisSampleBufferHandler(consumer: consumer, generationProvider: source, admission: admission,
            currentInstant: { clock.withLock { $0 } })
        await queue.perform { handler.processSampleBuffer(native.value) }
        try await wait { await consumer.count == 1 && !admission.isFrameInFlight }
        clock.withLock { $0 = 1.0 / 60.0 }
        await queue.perform { handler.processSampleBuffer(native.value) }
        let halfInterval = await consumer.count
        XCTAssertEqual(halfInterval, 1, "Sensor-rate callbacks must not overrun the thirty-Hz cap")
        clock.withLock { $0 = 1.0 / 30.0 }
        await queue.perform { handler.processSampleBuffer(native.value) }
        try await wait { await consumer.count == 2 && !admission.isFrameInFlight }
        var combined = q.demand; combined.peakingEnabled = true
        let both = AnalysisRequest(configurationGeneration: q.configurationGeneration, geometry: q.geometry, demand: combined,
            peakingThreshold: q.peakingThreshold, zebraThreshold: q.zebraThreshold,
            loupeCenter: q.loupeCenter, loupeMagnification: q.loupeMagnification)
        source.update(configuration: q.configurationGeneration, layout: 2, histogramEnabled: false, masksEnabled: true, request: both)
        clock.withLock { $0 = 2.0 / 30.0 }
        await queue.perform { handler.processSampleBuffer(native.value) }
        try await wait { await consumer.count == 3 && !admission.isFrameInFlight }
        XCTAssertTrue(admission.beginFrame())
        clock.withLock { $0 = 3.0 / 30.0 }
        await queue.perform { handler.processSampleBuffer(native.value) }
        let busyCount = await consumer.count
        XCTAssertEqual(busyCount, 3, "A busy frame is dropped before acquiring another native plane")
        XCTAssertGreaterThan(handler.snapshot.rejected, 0)
        admission.endFrame()
        await queue.perform { handler.processSampleBuffer(native.value) }
        try await wait { await consumer.count == 4 && !admission.isFrameInFlight }
        source.update(configuration: q.configurationGeneration, layout: 2, histogramEnabled: false, masksEnabled: true)
        clock.withLock { $0 = 4.0 / 30.0 }
        await queue.perform { handler.processSampleBuffer(native.value) }
        let masksOnlyCount = await consumer.count
        XCTAssertEqual(masksOnlyCount, 4, "Removing the loupe restores the masks' slower native cap")
        clock.withLock { $0 = 3.0 / 30.0 + 1.0 / 20.0 }
        await queue.perform { handler.processSampleBuffer(native.value) }
        try await wait { await consumer.count == 5 && !admission.isFrameInFlight }
    }

}
#endif
