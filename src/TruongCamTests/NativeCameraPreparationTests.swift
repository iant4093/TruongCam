#if canImport(UIKit) && canImport(XCTest) && !TC_TESTKIT_STANDALONE
import AVFoundation
import UIKit
import Synchronization
import XCTest
@testable import TruongCam

private actor Preparation58Permission: CameraPermissionPort {
    private var waiters: [CheckedContinuation<CameraAuthorization, Never>] = []
    private(set) var calls = 0
    func currentAuthorization() async -> CameraAuthorization {
        calls += 1
        return await withCheckedContinuation { waiters.append($0) }
    }
    func requestAuthorization() async -> CameraAuthorization { .denied }
    func refuseFirst() { if !waiters.isEmpty { waiters.removeFirst().resume(returning: .denied) } }
}

private struct NativePreparationProbe: Sendable {
    let before: CapturePipelinePreparation.OutputState
    let afterStale: CapturePipelinePreparation.OutputState
    let prepared: CapturePipelinePreparation.OutputState
    let repeated: CapturePipelinePreparation.OutputState
    let staleAccepted: Bool
    let preparedAccepted: Bool
    let repeatedAccepted: Bool
    let missingAnalysisAccepted: Bool
    let missingOriginalAccepted: Bool
    let running: Bool
}

final class NativeCameraPreparationTests: XCTestCase {
    func testPreparationPriorityRetainsNewerOwnerAndReleasesOnSupersessionAndPermissionFailure() async throws {
        let permission = Preparation58Permission()
        let service = AVCaptureCameraService(analysisSink: NativeIdleAnalysisSink(), permission: permission)
        let bridge = await service.previewDisplayBridge()
        let first = Task { await service.prepare(desiredCamera: .wide) }
        for _ in 0..<500 where await permission.calls < 1 { try await Task.sleep(for: .milliseconds(2)) }
        let firstCalls = await permission.calls
        XCTAssertEqual(firstCalls, 1)
        XCTAssertTrue(bridge.shouldDeferAnalysisForCameraPreparation)
        XCTAssertEqual(bridge.nativeAccessGate.snapshot.pauseCount, 0, "Priority is not an early native graph pause.")
        let second = Task { await service.prepare(desiredCamera: .front) }
        for _ in 0..<500 where await permission.calls < 2 { try await Task.sleep(for: .milliseconds(2)) }
        let secondCalls = await permission.calls
        XCTAssertEqual(secondCalls, 2)
        await permission.refuseFirst()
        let superseded = await first.value
        if case .success = superseded { XCTFail("Superseded permission work cannot prepare a native graph") }
        XCTAssertTrue(bridge.shouldDeferAnalysisForCameraPreparation, "Old return cannot release the newer owner's priority.")
        await permission.refuseFirst()
        let refused = await second.value
        if case .success = refused { XCTFail("Denied permission cannot prepare a native graph") }
        XCTAssertFalse(bridge.shouldDeferAnalysisForCameraPreparation, "Failure releases its own counted scope.")
        XCTAssertFalse(bridge.shouldDeferAnalysisForPhoto)
        await service.stop()
    }

    func testStoppedNativeServicePublishesIdleForAReattachedObserver() async throws {
        // Empty Simulator session: no input, permission, sensor start or capture.
        let service = AVCaptureCameraService(analysisSink: NativeIdleAnalysisSink())
        await service.stop()
        let seen = SequenceTestBox<CameraLifecycle?>(nil)
        let stream = service.sessionConditionStream
        let task = Task { var iterator = stream.makeAsyncIterator(); seen.set(await iterator.next()) }
        for _ in 0..<200 where seen.value == nil { try await Task.sleep(for: .milliseconds(1)) }
        task.cancel()
        XCTAssertEqual(seen.value, .idle, "The observer must get the owned stop result instead of a stale failure or no event.")
        let recorded = await service.recordedSessionCondition()
        XCTAssertEqual(recorded, .idle)
    }
    func testHardwareControlsRepairDetachedMissingDelegateAndCaptureAdmissionWithoutStaleInput() async {
        let queue = SerialSessionQueue(label: "TruongCam.test.hardware-reconciliation")
        let checks = await queue.perform { () -> [String: Bool] in
            let port = HardwareAttachmentFixture(), controller = HardwareSessionControls()
            let domain = HardwareControlDomain(generation: .zero, kind: .shutter, title: "Shutter", symbol: "timer",
                options: [.init(title: "Auto", value: .automatic),.init(title: "1/50", value: .number(0.02))])
            let selection = HardwareControlSelection(domain: domain, index: 0)
            let ready = HardwareControlConfiguration(enabled: true, selections: [selection])
            let events = SequenceTestBox<[HardwareControlEvent]>([])
            let owner = UUID()
            func update(_ configuration: HardwareControlConfiguration, _ owner: UUID) -> Bool {
                controller.update(port: port, configuration: configuration, interactionID: owner, queue: queue.queue,
                    emit: { event in events.mutate { $0.append(event) } }, fullscreen: { _ in })
            }
            var result: [String: Bool] = [:]
            port.permitsAttachment = false
            result["transient canAdd refusal is reported"] = !update(ready,owner) && port.controls.isEmpty
            port.permitsAttachment = true
            result["identical desired configuration retries absent picker"] = update(ready,owner) && port.controls.count == 1
            let first = port.controls.first
            port.attached = []
            result["system-detached picker is reattached"] = update(ready,owner) && port.controls.count == 1 && port.controls.first !== first
            port.delegate = nil
            result["lost native delegate is restored"] = update(ready,owner) && port.hasDelegate(controller)
            let suspendedOwner = UUID()
            let suspended = HardwareControlConfiguration(enabled: false, selections: [selection], preservesPresentation: true)
            result["capture keeps native control enabled"] = update(suspended,suspendedOwner) && port.controls.first?.isEnabled == true
            controller.receiveSelection(HardwareControlSelection(domain: domain,index: 1), interactionID: suspendedOwner)
            result["presentation preservation admits no capture-time command"] = events.value.isEmpty
            let resumedOwner = UUID(), oldPicker = port.controls.first
            result["postcapture rebind reconstructs actual native control"] = update(ready,resumedOwner) && port.controls.first !== oldPicker
            controller.receiveSelection(HardwareControlSelection(domain: domain,index: 1), interactionID: owner)
            result["old owner remains fenced after reconstruction"] = events.value.isEmpty
            controller.receiveSelection(HardwareControlSelection(domain: domain,index: 1), interactionID: resumedOwner)
            result["current swipe works after capture without a settings toggle"] = events.value.count == 1
            return result
        }
        for (name, result) in checks { XCTAssertTrue(result,name) }
    }

    func testPreviewMirroringDeliversSynchronousLayoutNotificationsOnMainActor() async {
        let checks = await MainActor.run {
            let fixture = PreviewMirrorNotificationFixture()
            let callbacks = Mutex<[Bool]>([])
            let observation = fixture.observe(\.mirrored, options: [.new]) { _, _ in
                let isMain = Thread.isMainThread
                callbacks.withLock { $0.append(isMain) }
                // Mirrors the synchronous preview-layer -> UIKit layout path
                // from the phone crash; the shared shipping mutation executor
                // must call this while the UI owner is isolated.
                if isMain {
                    MainActor.assumeIsolated {
                        let host = PreviewHostView(frame: CGRect(x: 0, y: 0, width: 300, height: 400))
                        host.setNeedsLayout(); host.layoutIfNeeded()
                    }
                }
            }
            var writes = 0, legalOrder = true
            @MainActor func apply(_ desired: Bool) -> Bool {
                let changes = CapturePipelinePreparation.previewMirroringChanges(supported: true,
                    automatic: fixture.automatic, mirrored: fixture.mirrored, desired: desired)
                return CapturePipelinePreparation.applyPreviewMirroring(changes, isCurrent: { true }) { change in
                    writes += 1
                    switch change {
                    case .enableAutomatic: fixture.automatic = true
                    case .disableAutomatic: fixture.automatic = false
                    case .setMirrored(let value):
                        legalOrder = legalOrder && !fixture.automatic
                        fixture.mirrored = value
                    }
                }
            }
            let front = apply(true) && fixture.mirrored && !fixture.automatic
            let firstWrites = writes
            let repeated = apply(true) && writes == firstWrites
            let rear = apply(false) && !fixture.mirrored
            let newFront = apply(true) && fixture.mirrored
            withExtendedLifetime(observation) {}
            let notifications = callbacks.withLock { $0 }
            return [front, repeated, rear, newFront, legalOrder,
                notifications.count == 3, notifications.allSatisfy { $0 }]
        }
        XCTAssertTrue(checks.allSatisfy { $0 }, "Both facing transitions, synchronous KVO/layout and no-op updates must retain MainActor ownership: \(checks)")
        // This exercises the shipping actor-isolated executor with real KVO and
        // UIKit layout, not actual sensor input or physical mirroring capability.
    }

    func testCameraControlNativePickerAndDelegateBindingsMatchInstalledSDK() async throws {
        let symbolsExist = await MainActor.run {
            ["camera.rotate", "timer", "camera.aperture", "viewfinder", "thermometer.medium", "t.circle", "plusminus"].allSatisfy { UIImage(systemName: $0) != nil }
        }
        XCTAssertTrue(symbolsExist, "Native controls require real SF Symbols.")
        let queue = SerialSessionQueue(label: "TruongCam.test.hardware-controls")
        let result = await queue.perform {
            let picker = AVCaptureIndexPicker("Focus", symbolName: "viewfinder", localizedIndexTitles: ["Auto", "0.2", "0.8"])
            picker.setActionQueue(queue.queue) { _ in }
            picker.selectedIndex = 2; picker.isEnabled = false
            let session = AVCaptureSession(), controller = HardwareSessionControls()
            controller.update(session: session, configuration: HardwareControlConfiguration(enabled: false, selections: []),
                queue: queue.queue, emit: { _ in }, fullscreen: { _ in })
            return (picker.selectedIndex, picker.numberOfIndexes, picker.isEnabled,
                controller.responds(to: #selector(AVCaptureSessionControlsDelegate.sessionControlsWillEnterFullscreenAppearance(_:))),
                controller.responds(to: #selector(AVCaptureSessionControlsDelegate.sessionControlsDidBecomeInactive(_:))))
        }
        XCTAssertEqual(result.0, 2); XCTAssertEqual(result.1, 3); XCTAssertFalse(result.2)
        XCTAssertTrue(result.3); XCTAssertTrue(result.4)
        // This executes native construction/selector bindings, not a physical swipe.
    }

    func testRealOutputPreparationIsConditionalAndMissingConnectionsCannotClaimSuccess() async {
        // Empty Simulator graph only. No device input, startRunning or capture;
        // this exercises the shipping native option adapter and absent-connection
        // fallback without pretending to prove a physical lens configuration.
        let probe = await SerialSessionQueue().perform {
            let session = AVCaptureSession()
            let photo = AVCapturePhotoOutput()
            let video = AVCaptureVideoDataOutput()
            session.beginConfiguration()
            if session.canAddOutput(photo) { session.addOutput(photo) }
            if session.canAddOutput(video) { session.addOutput(video) }
            session.commitConfiguration()
            let before = AVCaptureCameraService.photoPipelineOutputState(photo, video)
            let stale = AVCaptureCameraService.preparePhotoPipelineOptions(photo, video, isCurrent: { false })
            let afterStale = AVCaptureCameraService.photoPipelineOutputState(photo, video)
            session.beginConfiguration()
            let prepared = AVCaptureCameraService.preparePhotoPipelineOptions(photo, video, isCurrent: { true })
            session.commitConfiguration()
            let preparedState = AVCaptureCameraService.photoPipelineOutputState(photo, video)
            let repeated = AVCaptureCameraService.preparePhotoPipelineOptions(photo, video, isCurrent: { true })
            return NativePreparationProbe(before: before, afterStale: afterStale, prepared: preparedState,
                repeated: AVCaptureCameraService.photoPipelineOutputState(photo, video), staleAccepted: stale,
                preparedAccepted: prepared, repeatedAccepted: repeated,
                missingAnalysisAccepted: AVCaptureCameraService.prepareAnalysisConnection(video, isCurrent: { true }),
                missingOriginalAccepted: AVCaptureCameraService.prepareOriginalConnection(photo, isCurrent: { true }),
                running: session.isRunning)
        }
        XCTAssertFalse(probe.staleAccepted)
        XCTAssertEqual(probe.before, probe.afterStale, "An obsolete owner must not set native options")
        XCTAssertTrue(probe.preparedAccepted)
        XCTAssertTrue(CapturePipelinePreparation.outputChanges(probe.prepared).isEmpty)
        XCTAssertTrue(probe.repeatedAccepted)
        XCTAssertEqual(probe.prepared, probe.repeated, "Stable output options do not get changed again")
        XCTAssertFalse(probe.missingAnalysisAccepted, "A connection created only after commit retains the fallback")
        XCTAssertFalse(probe.missingOriginalAccepted)
        XCTAssertFalse(probe.running)
    }
}
private final class HardwareAttachmentFixture: HardwareControlSessionPort {
    let supportsControls = true
    let maxControlsCount = 2
    var attached: [AVCaptureControl] = []
    var controls: [AVCaptureControl] { attached }
    var delegate: HardwareSessionControls?
    var permitsAttachment = true
    func hasDelegate(_ delegate: HardwareSessionControls) -> Bool { self.delegate === delegate }
    func setDelegate(_ delegate: HardwareSessionControls, queue: DispatchQueue) { self.delegate = delegate }
    func canAdd(_ picker: AVCaptureIndexPicker) -> Bool { permitsAttachment && attached.count < maxControlsCount }
    func add(_ picker: AVCaptureIndexPicker) { attached.append(picker) }
    func remove(_ picker: AVCaptureIndexPicker) { attached.removeAll { $0 === picker } }
}
private actor NativeIdleAnalysisSink: PreviewAnalysisSink {
    func consume(outcome: LumaDownsampleOutcome, geometry: PreviewGeometrySnapshot?) async {}
    func setAnalysisRequest(_ request: AnalysisRequest?) async {}
    func updateGeometry(_ geometry: PreviewGeometrySnapshot?) async {}
}
private final class PreviewMirrorNotificationFixture: NSObject {
    @objc dynamic var mirrored = false
    var automatic = true
}
#endif
