#if canImport(UIKit) && canImport(XCTest) && !TC_TESTKIT_STANDALONE
import AVFoundation
import SwiftUI
import UIKit
import XCTest
@testable import TruongCam

final class NativePreviewRotationTests: XCTestCase {
    @MainActor func testSceneAndCanvasMustAgreeBeforeGeometryCanBePublished() async throws {
        let portrait = CGSize(width: 402, height: 536)
        let landscape = CGSize(width: 536, height: 402)
        for orientation in [UIInterfaceOrientation.landscapeLeft, .landscapeRight] {
            XCTAssertTrue(PreviewHostView.layoutMatchesScene(viewSize: landscape, windowSize: landscape, orientation: orientation))
            XCTAssertFalse(PreviewHostView.layoutMatchesScene(viewSize: landscape, windowSize: portrait, orientation: orientation))
            XCTAssertFalse(PreviewHostView.layoutMatchesScene(viewSize: portrait, windowSize: landscape, orientation: orientation))
            XCTAssertFalse(PreviewHostView.layoutMatchesScene(viewSize: landscape, windowSize: landscape, orientation: .portrait))
        }
        XCTAssertTrue(PreviewHostView.layoutMatchesScene(viewSize: portrait, windowSize: portrait, orientation: .portrait))
        XCTAssertFalse(PreviewHostView.layoutMatchesScene(viewSize: .zero, windowSize: portrait, orientation: .portrait))
        XCTAssertFalse(PreviewHostView.layoutMatchesScene(viewSize: portrait, windowSize: portrait, orientation: .unknown))

        let scene = try await connectedScene()
        let controller = PreviewHostController()
        let window = UIWindow(windowScene: scene)
        window.rootViewController = controller
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        try await rotate(window, to: .portrait)
        let host = controller.previewHost
        host.imageDimensions = PixelDimensions(width: 1920, height: 1440)
        host.setNativeAccessGate(PreviewNativeAccessGate())
        var delivered: [CameraPreviewView.PreviewGeometry] = []
        host.onGeometryChanged = { delivered.append($0) }
        host.synchronizeConfiguration()
        // Deliberately hold the scene at portrait while applying a new wide
        // frame, as can happen between UIKit/SwiftUI transition layout passes.
        let originalFrame = window.frame
        window.frame = CGRect(x: 0, y: 0, width: originalFrame.height, height: originalFrame.width)
        controller.view.frame = window.bounds
        window.layoutIfNeeded()
        host.refreshGeometry()
        try await Task.sleep(for: .milliseconds(20))
        XCTAssertEqual(scene.effectiveGeometry.interfaceOrientation, .portrait)
        XCTAssertTrue(delivered.isEmpty, "Queued portrait geometry must not publish into the newly wide canvas.")
        window.frame = originalFrame
        controller.view.frame = window.bounds
        window.layoutIfNeeded()
        host.synchronizeConfiguration()
        try await Task.sleep(for: .milliseconds(20))
        XCTAssertEqual(delivered.last?.interfaceOrientation, .portrait)
        XCTAssertEqual(delivered.last?.viewSize, host.bounds.size)
    }

    @MainActor func testRealSceneRotationRetainsOneHostAndReconcilesBothLandscapesBehindTheGate() async throws {
        let madeFixture = await StorageHarness.make(name: "native-preview-rotation-53")
        let fixture = try XCTUnwrap(madeFixture)
        let service = SyntheticCameraService(capability: StartupRepairSuite.controlFixture(modes: [.auto, .manual]))
        await service.installDisplaySession(AVCaptureSession())
        let camera = CameraViewModel(camera: service,
            capture: CaptureCoordinator(camera: ChainCameraSpy(), store: fixture.store, clock: SystemMonotonicClock()),
            metering: MeteringService(clock: SystemMonotonicClock()), preferences: SyntheticPreferenceStore(), levelFeed: SyntheticLevelFeed())
        let app = AppEnvironment()
        app.attach(camera: camera)
        app.graphState = .ready
        await camera.start()
        let scene = try await connectedScene()
        let window = UIWindow(windowScene: scene)
        window.rootViewController = UIHostingController(rootView: CameraScreen().environment(app).preferredColorScheme(.dark))
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        try await rotate(window, to: .portrait)
        for _ in 0..<100 where hosts(window).isEmpty { try await Task.sleep(for: .milliseconds(10)) }
        let host = try XCTUnwrap(hosts(window).first)
        let layer = host.previewLayer
        let assignments = host.sessionAssignmentCount
        let gate = try XCTUnwrap(camera.previewSessionBox?.nativeAccessGate)
        host.synchronizeConfiguration()
        _ = try await currentGeometry(service, orientation: .portrait)
        let pause = gate.pause()
        defer { pause.release() }
        let beforePause = await service.previewGeometries.compactMap { $0 }.count
        let computations = host.geometryComputationCount
        try await rotate(window, to: .landscapeLeft)
        let duringPause = await service.previewGeometries.compactMap { $0 }.count
        XCTAssertEqual(duringPause, beforePause, "A rotation cannot publish through a held native graph lease.")
        XCTAssertEqual(host.geometryComputationCount, computations)
        pause.release()
        host.synchronizeConfiguration()
        let left = try await currentGeometry(service, orientation: .landscapeRight)
        XCTAssertTrue(host === hosts(window).first)
        XCTAssertTrue(layer === host.previewLayer)
        XCTAssertGreaterThan(host.bounds.width, host.bounds.height)
        XCTAssertEqual(host.interfaceOrientation, .landscapeRight)
        let leftSize = host.bounds.size
        try await rotate(window, to: .landscapeRight)
        host.synchronizeConfiguration()
        let right = try await currentGeometry(service, orientation: .landscapeLeft)
        XCTAssertEqual(right.interfaceOrientation, .landscapeLeft)
        XCTAssertEqual(leftSize, host.bounds.size, "Opposite landscape rotations need a new angle even at identical bounds.")
        XCTAssertNotEqual(left.analysisRotationDegrees, right.analysisRotationDegrees)
        XCTAssertGreaterThan(right.layoutGeneration, left.layoutGeneration)
        XCTAssertEqual(host.interfaceOrientation, .landscapeLeft)
        XCTAssertTrue(host === hosts(window).first)
        XCTAssertEqual(hosts(window).count, 1)
        XCTAssertEqual(host.sessionAssignmentCount, assignments, "Display rotation must not reattach the native session.")
        try await rotate(window, to: .portrait)
        host.synchronizeConfiguration()
        _ = try await currentGeometry(service, orientation: .portrait)
        XCTAssertTrue(host === hosts(window).first)
        XCTAssertEqual(host.interfaceOrientation, .portrait)
        await camera.stop()
    }

    @MainActor private func connectedScene() async throws -> UIWindowScene {
        for _ in 0..<100 {
            if let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first { return scene }
            try await Task.sleep(for: .milliseconds(20))
        }
        throw CocoaError(.featureUnsupported)
    }

    @MainActor private func rotate(_ window: UIWindow, to orientation: UIInterfaceOrientation) async throws {
        let scene = try XCTUnwrap(window.windowScene)
        let mask: UIInterfaceOrientationMask = orientation == .portrait ? .portrait :
            orientation == .landscapeLeft ? .landscapeLeft : .landscapeRight
        var geometryError: Error?
        window.rootViewController?.setNeedsUpdateOfSupportedInterfaceOrientations()
        scene.requestGeometryUpdate(.iOS(interfaceOrientations: mask)) { geometryError = $0 }
        for _ in 0..<150 {
            if let geometryError { throw geometryError }
            let geometry = scene.effectiveGeometry
            if geometry.interfaceOrientation == orientation,
               (geometry.coordinateSpace.bounds.width > geometry.coordinateSpace.bounds.height) == orientation.isLandscape,
               window.rootViewController?.transitionCoordinator == nil {
                window.frame = geometry.coordinateSpace.bounds
                window.layoutIfNeeded()
                return
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        throw CocoaError(.featureUnsupported)
    }

    @MainActor private func hosts(_ view: UIView) -> [PreviewHostView] {
        (view as? PreviewHostView).map { [$0] } ?? view.subviews.flatMap(hosts)
    }

    @MainActor private func currentGeometry(_ service: SyntheticCameraService, orientation: DeviceOrientation) async throws -> PreviewGeometrySnapshot {
        for _ in 0..<100 {
            if let geometry = await service.previewGeometries.compactMap({ $0 }).last,
               geometry.interfaceOrientation == orientation { return geometry }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw CocoaError(.featureUnsupported)
    }
}
#endif
