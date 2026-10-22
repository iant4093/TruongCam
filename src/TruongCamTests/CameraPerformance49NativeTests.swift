#if canImport(UIKit) && canImport(XCTest) && !TC_TESTKIT_STANDALONE
import CoreMedia
import CoreVideo
import Synchronization
import XCTest
@testable import TruongCam

private actor Performance49Consumer: AnalysisSampleConsumer {
    private(set) var generations: [ConfigurationGeneration] = []
    private var waiter: CheckedContinuation<Void, Never>?
    private var hold: Bool
    init(hold: Bool = false) { self.hold = hold }
    func consume(outcome: LumaDownsampleOutcome, geometry: PreviewGeometrySnapshot?) async {
        if let sample = outcome.sample { generations.append(sample.configurationGeneration) }
        if hold { await withCheckedContinuation { waiter = $0 } }
    }
    func release() { hold = false; waiter?.resume(); waiter = nil }
}

final class CameraPerformance49NativeTests: XCTestCase {
    @MainActor func testPhotoPriorityAcquiredAfterCopySkipsQueuedMathAndReleasesBudget() async throws {
        let bridge = PreviewDisplayBridge(), source = SessionGenerationSource(), consumer = Performance49Consumer()
        let initialGeometry = geometry(configuration: 1, layout: 1)
        bridge.setGeometry(initialGeometry)
        source.update(configuration: initialGeometry.configurationGeneration, layout: 1, histogramEnabled: true)
        let held = Mutex(false), release = DispatchSemaphore(value: 0), clock = Mutex(0.0)
        defer { release.signal() }
        let admission = SampleAdmission()
        let handler = AnalysisSampleBufferHandler(consumer: consumer, generationProvider: source,
            admission: admission, displayBridge: bridge, currentInstant: {
                clock.withLock { $0 += 1; return $0 }
            }, beforeOwnedAnalysis: {
                let first = held.withLock { value in let first = !value; value = true; return first }
                if first { _ = release.wait(timeout: .now() + 5) }
            })
        let sample = SessionOwned(try sample())
        await SerialSessionQueue(label: "TruongCam.test.performance49.photo").perform {
            handler.processSampleBuffer(sample.value)
        }
        for _ in 0..<1_000 where !held.withLock({ $0 }) { try await Task.sleep(for: .milliseconds(1)) }
        XCTAssertTrue(held.withLock { $0 })
        XCTAssertTrue(admission.isFrameInFlight)
        XCTAssertTrue(bridge.hasCurrentFrame(for: initialGeometry), "Current preview acknowledgement is independent of analysis priority.")
        XCTAssertEqual(bridge.nativeAccessGate.snapshot.frameReadCount, 0)
        let graph = await bridge.nativeAccessGate.pauseAndDrainFrames()
        XCTAssertEqual(bridge.nativeAccessGate.snapshot.waitingDrainCount, 0,
            "The held owned queue must not retain a native graph-read lease.")
        graph.release()
        let photo = bridge.prioritizePhotoWork()
        release.signal()
        try await awaitDrain(admission)
        XCTAssertEqual(handler.snapshot.accepted, 0)
        XCTAssertEqual(handler.snapshot.rejected, 1)
        XCTAssertEqual(handler.snapshot.lastRejection, "photo work acquired priority before owned analysis")
        let rejectedGenerations = await consumer.generations
        XCTAssertTrue(rejectedGenerations.isEmpty)
        photo.release()
        await SerialSessionQueue(label: "TruongCam.test.performance49.photo-resume").perform {
            handler.processSampleBuffer(sample.value)
        }
        try await awaitDrain(admission)
        XCTAssertEqual(handler.snapshot.accepted, 1, "Photo completion resumes current analysis without rebuilding output topology.")
        let resumedGenerations = await consumer.generations
        XCTAssertEqual(resumedGenerations, [ConfigurationGeneration(1)])
    }

    @MainActor func testPreparationPrioritySkipsCopiedOutgoingFrameBeforeItsGenerationChanges() async throws {
        let bridge = PreviewDisplayBridge(), source = SessionGenerationSource(), consumer = Performance49Consumer()
        let initialGeometry = geometry(configuration: 1, layout: 1)
        bridge.setGeometry(initialGeometry)
        source.update(configuration: initialGeometry.configurationGeneration, layout: 1, histogramEnabled: true)
        let held = Mutex(false), release = DispatchSemaphore(value: 0), clock = Mutex(0.0)
        defer { release.signal() }
        let admission = SampleAdmission()
        let handler = AnalysisSampleBufferHandler(consumer: consumer, generationProvider: source,
            admission: admission, displayBridge: bridge, currentInstant: {
                clock.withLock { $0 += 1; return $0 }
            }, beforeOwnedAnalysis: {
                let first = held.withLock { value in let first = !value; value = true; return first }
                if first { _ = release.wait(timeout: .now() + 5) }
            })
        let sample = SessionOwned(try sample())
        await SerialSessionQueue(label: "TruongCam.test.performance49.photo").perform {
            handler.processSampleBuffer(sample.value)
        }
        for _ in 0..<1_000 where !held.withLock({ $0 }) { try await Task.sleep(for: .milliseconds(1)) }
        XCTAssertTrue(held.withLock { $0 })
        XCTAssertTrue(admission.isFrameInFlight)
        XCTAssertTrue(bridge.hasCurrentFrame(for: initialGeometry), "Current preview acknowledgement is independent of analysis priority.")
        XCTAssertEqual(bridge.nativeAccessGate.snapshot.frameReadCount, 0)
        let graph = await bridge.nativeAccessGate.pauseAndDrainFrames()
        XCTAssertEqual(bridge.nativeAccessGate.snapshot.waitingDrainCount, 0,
            "The held owned queue must not retain a native graph-read lease.")
        graph.release()
        let preparation = bridge.prioritizeCameraPreparation()
        let overlapping = bridge.prioritizeCameraPreparation()
        preparation.release(); preparation.release()
        XCTAssertTrue(bridge.shouldDeferAnalysisForCameraPreparation)
        XCTAssertFalse(bridge.shouldDeferAnalysisForPhoto)
        release.signal()
        try await awaitDrain(admission)
        XCTAssertEqual(handler.snapshot.accepted, 0)
        XCTAssertEqual(handler.snapshot.rejected, 1)
        XCTAssertEqual(handler.snapshot.lastRejection, "camera preparation acquired priority before owned analysis")
        let rejectedGenerations = await consumer.generations
        XCTAssertTrue(rejectedGenerations.isEmpty)
        overlapping.release()
        XCTAssertFalse(bridge.shouldDeferAnalysisForCameraPreparation)
        await SerialSessionQueue(label: "TruongCam.test.performance49.photo-resume").perform {
            handler.processSampleBuffer(sample.value)
        }
        try await awaitDrain(admission)
        XCTAssertEqual(handler.snapshot.accepted, 1, "Preparation completion resumes current analysis without rebuilding output topology.")
        let resumedGenerations = await consumer.generations
        XCTAssertEqual(resumedGenerations, [ConfigurationGeneration(1)])
    }

    @MainActor func testQueuedFramesDiscardChangedCameraLayoutOrDemandButFreshFrameResumes() async throws {
        for change in 0..<3 {
            let source = SessionGenerationSource(), bridge = PreviewDisplayBridge(), consumer = Performance49Consumer()
            source.update(configuration: ConfigurationGeneration(1), layout: 1, histogramEnabled: true)
            bridge.setGeometry(geometry(configuration: 1, layout: 1))
            let entered = Mutex(false), release = DispatchSemaphore(value: 0), clock = Mutex(0.0)
            defer { release.signal() }
            let admission = SampleAdmission()
            let handler = AnalysisSampleBufferHandler(consumer: consumer, generationProvider: source,
                admission: admission, displayBridge: bridge, currentInstant: {
                    clock.withLock { $0 += 1; return $0 }
                }, beforeOwnedAnalysis: {
                    let first = entered.withLock { value in let first = !value; value = true; return first }
                    if first { _ = release.wait(timeout: .now() + 5) }
                })
            let sample = SessionOwned(try sample())
            await SerialSessionQueue(label: "TruongCam.test.performance49.stale").perform {
                handler.processSampleBuffer(sample.value)
            }
            for _ in 0..<1_000 where !entered.withLock({ $0 }) { try await Task.sleep(for: .milliseconds(1)) }
            XCTAssertTrue(entered.withLock { $0 })
            let generation = ConfigurationGeneration(change == 0 ? 2 : 1)
            let layout: UInt64 = change == 1 ? 2 : 1
            source.update(configuration: generation, layout: layout, histogramEnabled: change != 2)
            bridge.setGeometry(geometry(configuration: generation.value, layout: layout))
            release.signal()
            try await awaitDrain(admission)
            XCTAssertEqual(handler.snapshot.accepted, 0)
            XCTAssertEqual(handler.snapshot.rejected, 1)
            XCTAssertEqual(handler.snapshot.lastRejection, "the copied frame was superseded before owned analysis")
            let rejectedGenerations = await consumer.generations
            XCTAssertTrue(rejectedGenerations.isEmpty, "Changed acquisition identity/demand must not run the old consumer.")
            await SerialSessionQueue(label: "TruongCam.test.performance49.fresh").perform {
                handler.processSampleBuffer(sample.value)
            }
            try await awaitDrain(admission)
            XCTAssertEqual(handler.snapshot.accepted, 1)
            let resumedGenerations = await consumer.generations
            XCTAssertEqual(resumedGenerations, [generation])
        }
    }

    @MainActor func testAcceptedOwnedFrameRetainsBackpressureUntilItsConsumerFinishes() async throws {
        let source = SessionGenerationSource(), consumer = Performance49Consumer(hold: true)
        source.update(configuration: ConfigurationGeneration(4), layout: 8, histogramEnabled: true)
        let admission = SampleAdmission(), clock = Mutex(0.0)
        let handler = AnalysisSampleBufferHandler(consumer: consumer, generationProvider: source,
            admission: admission, currentInstant: { clock.withLock { $0 += 1; return $0 } })
        let sample = SessionOwned(try sample())
        let queue = SerialSessionQueue(label: "TruongCam.test.performance49.consumer")
        await queue.perform { handler.processSampleBuffer(sample.value) }
        for _ in 0..<1_000 {
            if await consumer.generations.count == 1 { break }
            try await Task.sleep(for: .milliseconds(1))
        }
        XCTAssertTrue(admission.isFrameInFlight)
        await queue.perform { handler.processSampleBuffer(sample.value) }
        XCTAssertEqual(handler.snapshot.accepted, 1)
        XCTAssertEqual(handler.snapshot.lastRejection, "the previous frame was still being analysed")
        XCTAssertTrue(admission.isFrameInFlight, "The owned-queue defer must transfer its budget rather than release a live consumer.")
        await consumer.release()
        try await awaitDrain(admission)
        await queue.perform { handler.processSampleBuffer(sample.value) }
        try await awaitDrain(admission)
        XCTAssertEqual(handler.snapshot.accepted, 2)
        let generations = await consumer.generations
        XCTAssertEqual(generations, [ConfigurationGeneration(4), ConfigurationGeneration(4)])
    }

    @MainActor private func awaitDrain(_ admission: SampleAdmission) async throws {
        for _ in 0..<2_000 where admission.isFrameInFlight { try await Task.sleep(for: .milliseconds(1)) }
        XCTAssertFalse(admission.isFrameInFlight, "Every dropped/finished frame releases its one-frame admission budget.")
    }
    private func geometry(configuration: UInt64, layout: UInt64) -> PreviewGeometrySnapshot {
        PreviewGeometrySnapshot(configurationGeneration: ConfigurationGeneration(configuration), layoutGeneration: layout,
            imageDimensions: PixelDimensions(width: 8, height: 4), cleanApertureDimensions: nil,
            previewLayerContentRect: TCRect(x: 0, y: 0, width: 200, height: 100), bufferOrientation: 1,
            isMirrored: false, analysisRotationDegrees: 0, isVideoMirrored: false, capturedAtUTC: Date())
    }
    private func sample() throws -> CMSampleBuffer {
        var pixel: CVPixelBuffer?
        XCTAssertEqual(CVPixelBufferCreate(nil, 8, 4, kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
            nil, &pixel), kCVReturnSuccess)
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
