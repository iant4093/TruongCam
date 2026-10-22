#if canImport(UIKit) && canImport(XCTest) && !TC_TESTKIT_STANDALONE
import CoreVideo
import CoreMedia
import Foundation
import XCTest
import UIKit
@testable import TruongCam

private actor NativeSwitchFrameConsumer: AnalysisSampleConsumer {
    func consume(outcome: LumaDownsampleOutcome, geometry: PreviewGeometrySnapshot?) async {}
}

final class NativeSwitchFrameReadinessTests: XCTestCase {
    @MainActor func testPhotoWorkDefersOptionalNativePreviewPollingButNotFrameAccessOrAcknowledgement() throws {
        let bridge = PreviewDisplayBridge()
        let host = PreviewHostView(frame: CGRect(x: 0,y: 0,width: 300,height: 400))
        host.imageDimensions = PixelDimensions(width: 4000,height: 3000)
        host.photoWorkSource = bridge
        let photo = bridge.prioritizePhotoWork()
        let lookups = host.connectionLookupCount, computations = host.geometryComputationCount
        host.updateMirroring(true)
        host.applyInterfaceOrientation(.landscapeLeft)
        host.refreshGeometry(); host.synchronizeConfiguration()
        XCTAssertEqual(host.connectionLookupCount, lookups, "Photo processing must not send optional UI calls into native camera locks.")
        XCTAssertEqual(host.geometryComputationCount, computations)
        XCTAssertFalse(bridge.nativeAccessGate.snapshot.isPaused, "No graph/UI gate is held across photo delivery.")
        let frameRead = try XCTUnwrap(bridge.nativeAccessGate.beginFrameRead())
        let snapshot = geometry(configuration: 1, layout: 1)
        bridge.setGeometry(snapshot)
        _ = bridge.acknowledgePreviewBuffer(configuration: snapshot.configurationGeneration, layout: snapshot.layoutGeneration)
        XCTAssertTrue(bridge.hasCurrentFrame(for: snapshot), "Native live-frame acknowledgement stays available.")
        frameRead.release(); photo.release()
        host.applyInterfaceOrientation(.landscapeLeft); host.refreshGeometry()
        XCTAssertGreaterThan(host.connectionLookupCount, lookups, "Current layout is reconciled after processing.")
        XCTAssertGreaterThan(host.geometryComputationCount, computations)
    }
    func testCurrentFrameNotificationsAreOnePerMatchingCameraLayoutAndRefuseLateFrames() async throws {
        let bridge = PreviewDisplayBridge()
        let observed = SequenceTestBox<[PreviewFrameIdentity]>([])
        let frames = bridge.currentFrameNotifications.subscribe()
        let task = Task { for await frame in frames { observed.mutate { $0.append(frame) } } }
        defer { task.cancel() }
        let first = geometry(configuration: 1, layout: 1)
        bridge.setGeometry(first)
        for _ in 0..<4 {
            _ = bridge.acknowledgePreviewBuffer(configuration: first.configurationGeneration, layout: first.layoutGeneration)
            try await Task.sleep(for: .milliseconds(2))
        }
        XCTAssertEqual(observed.value, [PreviewFrameIdentity(generation: first.configurationGeneration, layout: first.layoutGeneration)],
            "Only a first-current-frame wake is added, not main-thread work on every frame.")
        let next = geometry(configuration: 2, layout: 2)
        bridge.setGeometry(nil); bridge.setGeometry(next)
        _ = bridge.acknowledgePreviewBuffer(configuration: first.configurationGeneration, layout: first.layoutGeneration)
        XCTAssertFalse(bridge.hasCurrentFrame(for: next))
        _ = bridge.acknowledgePreviewBuffer(configuration: next.configurationGeneration, layout: next.layoutGeneration)
        for _ in 0..<200 where observed.value.count < 2 { try await Task.sleep(for: .milliseconds(1)) }
        XCTAssertEqual(observed.value.count, 2)
        XCTAssertEqual(observed.value.last, PreviewFrameIdentity(generation: next.configurationGeneration, layout: next.layoutGeneration))
    }
    func testActualSampleAcknowledgesNewLayoutBeforeAnalysisRateLimit() async throws {
        let clock = VirtualMonotonicClock(start: 100)
        let bridge = PreviewDisplayBridge(currentInstant: { clock.now() })
        let generation = SessionGenerationSource()
        let handler = AnalysisSampleBufferHandler(consumer: NativeSwitchFrameConsumer(), generationProvider: generation,
            displayBridge: bridge, currentInstant: { clock.now() })
        var pixelBuffer: CVPixelBuffer?
        XCTAssertEqual(CVPixelBufferCreate(nil, 8, 4, kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
            nil, &pixelBuffer), kCVReturnSuccess)
        let pixel = try XCTUnwrap(pixelBuffer)
        XCTAssertEqual(CVPixelBufferLockBaseAddress(pixel, []), kCVReturnSuccess)
        if let y = CVPixelBufferGetBaseAddressOfPlane(pixel, 0) {
            memset(y, 120, CVPixelBufferGetBytesPerRowOfPlane(pixel, 0) * 4)
        }
        if let uv = CVPixelBufferGetBaseAddressOfPlane(pixel, 1) {
            memset(uv, 128, CVPixelBufferGetBytesPerRowOfPlane(pixel, 1) * 2)
        }
        CVPixelBufferUnlockBaseAddress(pixel, [])
        CVBufferSetAttachment(pixel, kCVImageBufferYCbCrMatrixKey, kCVImageBufferYCbCrMatrix_ITU_R_709_2, .shouldPropagate)
        var format: CMVideoFormatDescription?
        XCTAssertEqual(CMVideoFormatDescriptionCreateForImageBuffer(allocator: kCFAllocatorDefault,
            imageBuffer: pixel, formatDescriptionOut: &format), noErr)
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 30),
            presentationTimeStamp: .zero, decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        XCTAssertEqual(CMSampleBufferCreateReadyWithImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: pixel,
            formatDescription: try XCTUnwrap(format), sampleTiming: &timing, sampleBufferOut: &sample), noErr)
        let nativeSample = try XCTUnwrap(sample)
        let first = geometry(configuration: 1, layout: 1)
        bridge.setGeometry(first)
        generation.update(configuration: first.configurationGeneration, layout: first.layoutGeneration, histogramEnabled: false)
        handler.processSampleBuffer(nativeSample)
        for _ in 0..<200 where handler.snapshot.accepted == 0 { try await Task.sleep(for: .milliseconds(1)) }
        XCTAssertEqual(handler.snapshot.accepted, 1)

        clock.advance(by: 0.001)
        let current = geometry(configuration: 2, layout: 2)
        bridge.setGeometry(nil)
        bridge.setGeometry(current)
        generation.update(configuration: current.configurationGeneration, layout: current.layoutGeneration, histogramEnabled: false)
        handler.processSampleBuffer(nativeSample)
        XCTAssertTrue(bridge.hasCurrentFrame(for: current),
            "The first matching native sample acknowledges preview even inside the old lens's analysis interval.")
        XCTAssertNil(bridge.frozenFrame(for: current), "The independent bitmap throttle still avoids extra CPU copies.")
        XCTAssertEqual(handler.snapshot.accepted, 1, "Expensive analysis retains its 15-Hz cap.")
        XCTAssertEqual(handler.snapshot.rejected, 0, "The rate-limited sample never reaches locking/downsampling/admission.")
    }

    func testNewCameraAndLayoutAcknowledgeFirstBufferInsideBitmapThrottle() throws {
        let clock = VirtualMonotonicClock(start: 100)
        let bridge = PreviewDisplayBridge(currentInstant: { clock.now() })
        let buffer = try makeBuffer(value: 180)
        let old = geometry(configuration: 1, layout: 10)
        bridge.setGeometry(old)
        bridge.recordPreviewBuffer(buffer, configuration: old.configurationGeneration, layout: old.layoutGeneration)
        XCTAssertNotNil(bridge.frozenFrame(for: old))

        clock.advance(by: 0.01)
        bridge.setGeometry(nil)
        let current = geometry(configuration: 2, layout: 11)
        bridge.setGeometry(current)
        bridge.recordPreviewBuffer(buffer, configuration: current.configurationGeneration, layout: current.layoutGeneration)
        XCTAssertTrue(bridge.hasCurrentFrame(for: current),
            "The first matching frame releases the visual wait without waiting for another CPU blur copy.")
        XCTAssertNotNil(bridge.frozenFrame(for: current), "A new camera/layout gets its first still without waiting for the outgoing camera throttle.")
        XCTAssertFalse(bridge.hasCurrentFrame(for: old), "An old camera/layout cannot acknowledge the new one.")
        bridge.recordPreviewBuffer(buffer, configuration: old.configurationGeneration, layout: old.layoutGeneration)
        XCTAssertTrue(bridge.hasCurrentFrame(for: current), "Late old buffers cannot replace the current acknowledgement.")

        clock.advance(by: 0.5)
        bridge.recordPreviewBuffer(buffer, configuration: current.configurationGeneration, layout: current.layoutGeneration)
        XCTAssertNotNil(bridge.frozenFrame(for: current), "The optional still resumes on its original bounded schedule.")
    }

    func testSameLayoutFreshStampUpdatesWhileBitmapRemainsThrottledAndStaleBuffersCannotRefreshIt() throws {
        let clock = VirtualMonotonicClock(start: 100)
        let bridge = PreviewDisplayBridge(currentInstant: { clock.now() })
        let buffer = try makeBuffer(value: 120)
        let current = geometry(configuration: 3, layout: 12)
        bridge.setGeometry(current)
        bridge.recordPreviewBuffer(buffer, configuration: current.configurationGeneration, layout: current.layoutGeneration)
        clock.advance(by: 0.49)
        bridge.recordPreviewBuffer(buffer, configuration: current.configurationGeneration, layout: current.layoutGeneration)
        XCTAssertEqual(try XCTUnwrap(bridge.frozenFrame(for: current)).instant, 100,
            "Acknowledgement refresh must not create an extra bitmap.")

        clock.advance(to: 101.6)
        XCTAssertTrue(bridge.hasCurrentFrame(for: current),
            "The newer accepted buffer is still fresh although the original bitmap/stamp would have expired.")
        XCTAssertNil(bridge.frozenFrame(for: current), "An old bitmap keeps its independent age limit.")
        clock.advance(to: 102)
        XCTAssertFalse(bridge.hasCurrentFrame(for: current))
        bridge.recordPreviewBuffer(buffer, configuration: ConfigurationGeneration(2), layout: current.layoutGeneration)
        bridge.recordPreviewBuffer(buffer, configuration: current.configurationGeneration, layout: 11)
        XCTAssertFalse(bridge.hasCurrentFrame(for: current), "Wrong camera or layout cannot refresh an expired current stamp.")
        bridge.setGeometry(nil)
        bridge.recordPreviewBuffer(buffer, configuration: current.configurationGeneration, layout: current.layoutGeneration)
        XCTAssertFalse(bridge.hasCurrentFrame(for: current), "Cleared geometry refuses even a formerly current buffer.")
    }

    func testDroppedPlansDoNotConsumeTheStillBudgetAndDecorativeCoverNeverAdmitsPreview() throws {
        let clock = VirtualMonotonicClock(start: 100)
        let bridge = PreviewDisplayBridge(currentInstant: { clock.now() })
        let old = geometry(configuration: 1, layout: 1)
        bridge.setGeometry(old)
        // A rate/backpressure drop after acknowledgement must not postpone a real still.
        XCTAssertNotNil(bridge.acknowledgePreviewBuffer(configuration: old.configurationGeneration, layout: old.layoutGeneration))
        clock.advance(by: 0.01)
        XCTAssertNotNil(bridge.acknowledgePreviewBuffer(configuration: old.configurationGeneration, layout: old.layoutGeneration))
        bridge.recordPreviewBuffer(try makeBuffer(value: 180), configuration: old.configurationGeneration, layout: old.layoutGeneration)
        XCTAssertNotNil(bridge.frozenFrame(for: old))
        let current = geometry(configuration: 2, layout: 2)
        bridge.setGeometry(nil); bridge.setGeometry(current)
        XCTAssertNil(bridge.frozenFrame(for: current))
        XCTAssertFalse(bridge.hasCurrentFrame(for: current))
        XCTAssertEqual(bridge.decorativeTransitionFrame(for: current)?.generation, old.configurationGeneration,
            "A bounded previous blur remains available while the next still renders.")
        XCTAssertFalse(bridge.hasCurrentFrame(for: current), "Decorative covers cannot acknowledge the replacement camera.")
        var rotated = current; rotated.interfaceOrientation = .landscapeLeft
        XCTAssertNil(bridge.decorativeTransitionFrame(for: rotated))
        clock.advance(by: 1.5)
        XCTAssertNil(bridge.decorativeTransitionFrame(for: current), "Old covers expire without repainting their source time.")
        bridge.clear()
        XCTAssertNil(bridge.decorativeTransitionFrame(for: current))
    }

    private func geometry(configuration: UInt64, layout: UInt64) -> PreviewGeometrySnapshot {
        PreviewGeometrySnapshot(configurationGeneration: ConfigurationGeneration(configuration), layoutGeneration: layout,
            imageDimensions: PixelDimensions(width: 8, height: 4), cleanApertureDimensions: nil,
            previewLayerContentRect: TCRect(x: 0, y: 0, width: 200, height: 100), bufferOrientation: 1,
            isMirrored: false, analysisRotationDegrees: 0, isVideoMirrored: false, capturedAtUTC: Date(), interfaceOrientation: .portrait)
    }

    private func makeBuffer(value: UInt8) throws -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        XCTAssertEqual(CVPixelBufferCreate(nil, 8, 4, kCVPixelFormatType_32BGRA,
            [kCVPixelBufferCGImageCompatibilityKey: true] as CFDictionary, &buffer), kCVReturnSuccess)
        let result = try XCTUnwrap(buffer)
        XCTAssertEqual(CVPixelBufferLockBaseAddress(result, []), kCVReturnSuccess)
        defer { CVPixelBufferUnlockBaseAddress(result, []) }
        let base = try XCTUnwrap(CVPixelBufferGetBaseAddress(result)).assumingMemoryBound(to: UInt8.self)
        for y in 0..<4 { for x in 0..<8 {
            let index = y * CVPixelBufferGetBytesPerRow(result) + x * 4
            base[index] = value; base[index + 1] = value; base[index + 2] = value; base[index + 3] = 255
        } }
        return result
    }
}
#endif
