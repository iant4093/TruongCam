#if canImport(UIKit) && canImport(XCTest) && !TC_TESTKIT_STANDALONE
import AVFoundation
import Synchronization
import XCTest
@testable import TruongCam

private final class NativeAnalysisProbe: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {}

final class NativePreviewAccessTests: XCTestCase {
    @MainActor func testMainPreviewStaysResponsiveWhileNativeSubmissionIsHeld() async throws {
        let gate = PreviewNativeAccessGate()
        let view = PreviewHostView(frame: CGRect(x: 0, y: 0, width: 300, height: 400))
        view.setNativeAccessGate(gate)
        view.synchronizeConfiguration()
        let lookups = view.connectionLookupCount
        let entered = Mutex(false)
        let releaseNative = DispatchSemaphore(value: 0)
        defer { releaseNative.signal() }
        let native = Task {
            let lease = gate.pause()
            defer { lease.release() }
            return await SerialSessionQueue().perform {
                entered.withLock { $0 = true }
                return releaseNative.wait(timeout: .now() + 3) == .success
            }
        }
        for _ in 0..<100 where !entered.withLock({ $0 }) {
            try await Task.sleep(for: .milliseconds(2))
        }
        XCTAssertTrue(entered.withLock { $0 })
        XCTAssertTrue(gate.snapshot.isPaused, "The handoff precedes native submission")
        for _ in 0..<100 {
            view.synchronizeConfiguration()
            view.applyInterfaceOrientation(.landscapeRight)
            _ = view.currentContentRect()
        }
        XCTAssertEqual(view.connectionLookupCount, lookups,
            "Main-thread layout remains callable while the native queue is held")
        releaseNative.signal()
        let completed = await native.value
        XCTAssertTrue(completed, "The main thread can release the held native operation")
        XCTAssertFalse(gate.snapshot.isPaused)
    }

    func testActualDelegateBindingRejectsLateDemandAndKeepsTheCurrentQueue() async {
        let result = await SerialSessionQueue().perform {
            let output = AVCaptureVideoDataOutput()
            let first = NativeAnalysisProbe(), replacement = NativeAnalysisProbe()
            let queue = DispatchQueue(label: "TruongCam.preview-test.analysis")
            let owner = LifecycleOwnership()
            let old = owner.begin()
            let installed = AVCaptureCameraService.bindAnalysisDelegate(output, handler: first,
                queue: queue, isCurrent: { owner.isCurrent(old) })
            let current = owner.begin()
            let refused = AVCaptureCameraService.bindAnalysisDelegate(output, handler: replacement,
                queue: queue, isCurrent: { owner.isCurrent(old) })
            let preserved = output.sampleBufferDelegate === first
            let rebound = AVCaptureCameraService.bindAnalysisDelegate(output, handler: replacement,
                queue: queue, isCurrent: { owner.isCurrent(current) })
            let repeated = AVCaptureCameraService.bindAnalysisDelegate(output, handler: replacement,
                queue: queue, isCurrent: { owner.isCurrent(current) })
            let correct = output.sampleBufferDelegate === replacement && output.sampleBufferCallbackQueue === queue
            output.setSampleBufferDelegate(nil, queue: nil)
            return [installed, refused, preserved, rebound, repeated, correct]
        }
        XCTAssertEqual(result, [true, false, true, true, true, true])
    }

    @MainActor func testPausedGraphRejectsQueuedLayoutConnectionAndSessionWork() async throws {
        let gate = PreviewNativeAccessGate()
        let view = PreviewHostView(frame: CGRect(x: 0, y: 0, width: 300, height: 400))
        view.setNativeAccessGate(gate)
        let first = AVCaptureSession(), replacement = AVCaptureSession()
        view.bindDisplaySession(first)
        view.imageDimensions = PixelDimensions(width: 4, height: 3)
        view.synchronizeConfiguration()
        let assignments = view.sessionAssignmentCount
        let lookups = view.connectionLookupCount
        let geometry = view.geometryComputationCount
        let old = gate.pause(), current = gate.pause()
        gate.noteNativeMutation()
        for _ in 0..<100 {
            view.bindDisplaySession(replacement)
            view.updateMirroring(true)
            view.applyInterfaceOrientation(.landscapeLeft)
            view.refreshGeometry()
            view.synchronizeConfiguration()
            _ = view.currentContentRect()
        }
        XCTAssertEqual(view.sessionAssignmentCount, assignments)
        XCTAssertEqual(view.connectionLookupCount, lookups, "A stale SwiftUI enabled flag cannot enter native connection APIs")
        XCTAssertEqual(view.geometryComputationCount, geometry)
        old.release()
        view.synchronizeConfiguration()
        XCTAssertEqual(view.sessionAssignmentCount, assignments, "Old completion cannot bind during current native work")
        current.release()
        view.synchronizeConfiguration()
        XCTAssertEqual(view.sessionAssignmentCount, assignments + 1, "The pending display handle binds after native work drains")
        XCTAssertGreaterThan(view.connectionLookupCount, lookups)
        XCTAssertGreaterThan(view.geometryComputationCount, geometry)
        XCTAssertTrue(view.previewLayer.session === replacement)
        XCTAssertFalse(first.isRunning)
        XCTAssertFalse(replacement.isRunning)
    }

    @MainActor func testDroppedGeometryRetriesWithoutNoOpDemandFeedbackLoop() async throws {
        let gate = PreviewNativeAccessGate()
        let view = PreviewHostView(frame: CGRect(x: 0, y: 0, width: 300, height: 400))
        view.setNativeAccessGate(gate)
        view.imageDimensions = PixelDimensions(width: 4, height: 3)
        var received: [CameraPreviewView.PreviewGeometry] = []
        view.onGeometryChanged = { received.append($0) }
        view.refreshGeometry()
        let pause = gate.pause()
        try await Task.sleep(for: .milliseconds(20))
        XCTAssertTrue(received.isEmpty, "Geometry queued before the native handoff cannot publish inside it")
        pause.release()
        view.synchronizeConfiguration()
        try await Task.sleep(for: .milliseconds(20))
        XCTAssertEqual(received.count, 1, "The undelivered layout retries after a no-op pause")
        let originalLayout = try XCTUnwrap(received.last).layoutGeneration
        for _ in 0..<100 {
            let noOp = gate.pause()
            noOp.release()
            view.synchronizeConfiguration()
        }
        try await Task.sleep(for: .milliseconds(20))
        XCTAssertEqual(received.count, 1, "Unchanged analysis demand must not recursively create new geometry")
        let mutation = gate.pause()
        gate.noteNativeMutation()
        mutation.release()
        view.synchronizeConfiguration()
        try await Task.sleep(for: .milliseconds(20))
        XCTAssertEqual(received.count, 2)
        XCTAssertGreaterThan(try XCTUnwrap(received.last).layoutGeneration, originalLayout,
            "Real native mutation republishes same-angle geometry under a fresh layout identity")
    }
}
#endif
