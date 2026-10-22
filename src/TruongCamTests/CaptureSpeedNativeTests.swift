#if canImport(UIKit) && canImport(XCTest) && !TC_TESTKIT_STANDALONE
import SwiftUI
import UIKit
import XCTest
@testable import TruongCam

/// Drives the shipping UIKit handlers without synthesizing a system event or
/// using private touch injection. Only the public location query is substituted.
private final class CaptureSpeed54Touch: UITouch {
    var point = CGPoint(x: 38, y: 38)
    override func location(in view: UIView?) -> CGPoint { point }
}

final class CaptureSpeedNativeTests: XCTestCase {
    @MainActor func testNativePressRetainsItsAdmittingCallbacksAcrossBusyUpdatesAndRejectsDuplicateAdmission() {
        let view = ContinuousShutterTouchView(frame: CGRect(x: 0, y: 0, width: 76, height: 76))
        let owner = NSObject()
        var began: [UUID] = [], oldEnded: [UUID] = [], oldCancelled: [UUID] = []
        var replacementEnded: [UUID] = [], replacementCancelled: [UUID] = []
        view.configure(owner: ObjectIdentifier(owner), enabled: true,
            begin: { began.append($0); return true }, end: { oldEnded.append($0) }, cancel: { oldCancelled.append($0) })
        XCTAssertFalse(view.beginPress(at: CGPoint(x: -1, y: 38)))
        XCTAssertTrue(view.beginPress(at: CGPoint(x: 38, y: 38)))
        XCTAssertFalse(view.beginPress(at: CGPoint(x: 38, y: 38)), "A second finger/update cannot admit another run")
        XCTAssertEqual(began.count, 1)
        // A real in-flight photo keeps this same owner enabled through its held
        // state, even though the ordinary shutter admission becomes busy.
        view.configure(owner: ObjectIdentifier(owner), enabled: true,
            begin: { began.append($0); return true }, end: { replacementEnded.append($0) }, cancel: { replacementCancelled.append($0) })
        view.finishPress(at: CGPoint(x: 38, y: 38))
        view.finishPress(at: CGPoint(x: 38, y: 38)); view.cancelPress()
        XCTAssertEqual(oldEnded, began, "Release belongs to the callbacks that admitted this press")
        XCTAssertTrue(oldCancelled.isEmpty); XCTAssertTrue(replacementEnded.isEmpty); XCTAssertTrue(replacementCancelled.isEmpty)
        XCTAssertFalse(view.isAccessibilityElement, "The touch bridge must not duplicate the accessible Shutter button")
        XCTAssertFalse(view.isMultipleTouchEnabled)
    }

    @MainActor func testNativeDragOutSystemCancelAndDisableRevokeExactlyTheOwnedPress() {
        let view = ContinuousShutterTouchView(frame: CGRect(x: 0, y: 0, width: 76, height: 76))
        let owner = NSObject()
        var began: [UUID] = [], ended: [UUID] = [], cancelled: [UUID] = []
        func configure(_ enabled: Bool) {
            view.configure(owner: ObjectIdentifier(owner), enabled: enabled,
                begin: { began.append($0); return true }, end: { ended.append($0) }, cancel: { cancelled.append($0) })
        }
        configure(true)
        let dragged = CaptureSpeed54Touch()
        view.touchesBegan([dragged], with: nil)
        dragged.point = CGPoint(x: 90, y: 38)
        view.touchesMoved([dragged], with: nil)
        dragged.point = CGPoint(x: 38, y: 38)
        view.touchesMoved([dragged], with: nil)
        view.touchesEnded([dragged], with: nil)
        XCTAssertEqual(cancelled, began, "Dragging out cancels immediately; re-entry cannot revive an old hold")
        XCTAssertTrue(ended.isEmpty)

        let interrupted = CaptureSpeed54Touch()
        view.touchesBegan([interrupted], with: nil)
        view.touchesCancelled([interrupted], with: nil)
        view.touchesEnded([interrupted], with: nil)
        XCTAssertEqual(cancelled.count, 2)
        XCTAssertEqual(Set(cancelled).count, 2)

        XCTAssertTrue(view.beginPress(at: CGPoint(x: 38, y: 38)))
        configure(false)
        view.finishPress(at: CGPoint(x: 38, y: 38)); view.cancelPress()
        XCTAssertEqual(cancelled, began, "Disabling admission cancels once and preserves submitted-photo ownership")
        XCTAssertFalse(view.beginPress(at: CGPoint(x: 38, y: 38)))
        XCTAssertTrue(ended.isEmpty)
    }

    @MainActor func testReplacementOwnerAndNativeWindowDetachmentCannotReceiveOrRetainAnOldPress() async throws {
        let window = try await host(Color.black, size: CGSize(width: 150, height: 150))
        defer { window.isHidden = true; window.rootViewController = nil }
        let view = ContinuousShutterTouchView(frame: CGRect(x: 30, y: 30, width: 76, height: 76))
        window.addSubview(view)
        let original = NSObject(), replacement = NSObject()
        var originalBegan: [UUID] = [], originalCancelled: [UUID] = []
        var replacementBegan: [UUID] = [], replacementEnded: [UUID] = [], replacementCancelled: [UUID] = []
        view.configure(owner: ObjectIdentifier(original), enabled: true,
            begin: { originalBegan.append($0); return true }, end: { _ in XCTFail("An old press cannot end after owner replacement") },
            cancel: { originalCancelled.append($0) })
        XCTAssertTrue(view.beginPress(at: CGPoint(x: 38, y: 38)))
        view.configure(owner: ObjectIdentifier(replacement), enabled: true,
            begin: { replacementBegan.append($0); return true }, end: { replacementEnded.append($0) },
            cancel: { replacementCancelled.append($0) })
        XCTAssertEqual(originalCancelled, originalBegan)
        view.finishPress(at: CGPoint(x: 38, y: 38))
        XCTAssertTrue(replacementEnded.isEmpty); XCTAssertTrue(replacementCancelled.isEmpty)
        XCTAssertTrue(view.beginPress(at: CGPoint(x: 38, y: 38)))
        XCTAssertNotNil(view.window)
        view.removeFromSuperview()
        XCTAssertNil(view.window)
        XCTAssertEqual(replacementCancelled, replacementBegan, "Actual didMoveToWindow teardown stops the held cadence")
        view.finishPress(at: CGPoint(x: 38, y: 38)); view.cancelPress()
        XCTAssertEqual(replacementCancelled.count, 1); XCTAssertTrue(replacementEnded.isEmpty)
        XCTAssertNotEqual(originalBegan.first, replacementBegan.first)
    }

    @MainActor func testRejectedNativeBeginCannotBecomeAnEndedShotOrCancelANewerPress() {
        let view = ContinuousShutterTouchView(frame: CGRect(x: 0, y: 0, width: 76, height: 76))
        let owner = NSObject()
        var rejected: [UUID] = [], admitted: [UUID] = [], ended: [UUID] = [], cancelled: [UUID] = []
        view.configure(owner: ObjectIdentifier(owner), enabled: true,
            begin: { rejected.append($0); return false }, end: { ended.append($0) }, cancel: { cancelled.append($0) })
        let oldTouch = CaptureSpeed54Touch()
        view.touchesBegan([oldTouch], with: nil)
        view.touchesEnded([oldTouch], with: nil)
        XCTAssertEqual(rejected.count, 1); XCTAssertTrue(ended.isEmpty); XCTAssertTrue(cancelled.isEmpty)
        view.configure(owner: ObjectIdentifier(owner), enabled: true,
            begin: { admitted.append($0); return true }, end: { ended.append($0) }, cancel: { cancelled.append($0) })
        let currentTouch = CaptureSpeed54Touch()
        view.touchesBegan([currentTouch], with: nil)
        view.touchesEnded([oldTouch], with: nil)
        view.touchesCancelled([oldTouch], with: nil)
        XCTAssertTrue(cancelled.isEmpty, "A stale cancelled touch cannot revoke the current press")
        XCTAssertTrue(ended.isEmpty, "A stale rejected touch cannot release the current admitted touch")
        view.touchesEnded([currentTouch], with: nil)
        XCTAssertEqual(ended, admitted); XCTAssertTrue(cancelled.isEmpty)
        XCTAssertNotEqual(rejected.first, admitted.first)
    }

    @MainActor private func host<V: View>(_ view: V, size: CGSize = CGSize(width: 402, height: 874)) async throws -> UIWindow {
        for _ in 0..<300 {
            if UIApplication.shared.connectedScenes.contains(where: { $0 is UIWindowScene }) { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene); window.frame = CGRect(origin: .zero, size: size)
        window.rootViewController = UIHostingController(rootView: view)
        window.makeKeyAndVisible(); window.layoutIfNeeded()
        try await Task.sleep(for: .milliseconds(100))
        return window
    }

    @MainActor private func descendants<V: UIView>(_ type: V.Type, in root: UIView) -> [V] {
        ((root as? V).map { [$0] } ?? []) + root.subviews.flatMap { descendants(type, in: $0) }
    }

    @MainActor private func wait(_ condition: () -> Bool) async throws {
        for _ in 0..<300 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("The shipping continuous shutter did not reach its owned state")
        throw CocoaError(.featureUnsupported)
    }

    @MainActor func testHostedShippingShutterPreservesReleaseWhileTheFirstNativePhotoIsBusy() async throws {
        let fixture = await StorageHarness.make(name: "native-speed54-busy"), h = try XCTUnwrap(fixture)
        let native = ChainCameraSpy(); native.holdAttachments()
        let (camera, _) = await CaptureFormatUISuite.makeModel(h: h, capability: CaptureFormatUISuite.capability(), native: native)
        camera.setCaptureSpeed(.fps5)
        let app = AppEnvironment(); app.attach(camera: camera)
        camera.updateRootState(.writable(libraryID: h.libraryID, generation: h.generation))
        XCTAssertTrue(camera.isShutterEnabled, "The hosted shutter fixture must attach its writable synthetic root")
        let window = try await host(ShutterButton().environment(app).frame(maxWidth: .infinity, maxHeight: .infinity).background(.black))
        defer {
            camera.stopContinuousCapture(); native.releaseAttachments()
            native.lastCreatedTicket?.deliver(.failed(CaptureFailure(kind: .captureFailed(detail: "Synthetic test terminal without any photo"), operation: "test.speed54")))
            window.isHidden = true; window.rootViewController = nil
        }
        let root = try XCTUnwrap(window.rootViewController?.view)
        let surface = try XCTUnwrap(descendants(ContinuousShutterTouchView.self, in: root).first)
        XCTAssertGreaterThanOrEqual(surface.bounds.width, 44); XCTAssertGreaterThanOrEqual(surface.bounds.height, 44)
        let touch = CaptureSpeed54Touch(); touch.point = CGPoint(x: surface.bounds.midX, y: surface.bounds.midY)
        surface.touchesBegan([touch], with: nil)
        try await wait { native.attachArrivals == 1 && camera.isCapturing }
        XCTAssertTrue(camera.isContinuousCaptureHeld); XCTAssertFalse(camera.isShutterEnabled)
        window.layoutIfNeeded(); try await Task.sleep(for: .milliseconds(30))
        XCTAssertTrue(descendants(ContinuousShutterTouchView.self, in: root).first === surface,
            "A busy update must retain the active touch surface")
        surface.touchesEnded([touch], with: nil)
        XCTAssertFalse(camera.isContinuousCaptureHeld, "Lift is handled while the ordinary shutter is busy")
        XCTAssertTrue(camera.isCapturing, "Release must not cancel already submitted persistence")
        native.releaseAttachments()
        try await wait { native.lastCreatedTicket != nil }
        native.lastCreatedTicket?.deliver(.failed(CaptureFailure(kind: .captureFailed(detail: "Synthetic test terminal without any photo"), operation: "test.speed54")))
        try await wait { !camera.isContinuousCaptureActive && !camera.isCapturing }
        XCTAssertEqual(native.attachArrivals, 1); XCTAssertEqual(camera.continuousCapturedCount, 0)
        XCTAssertTrue(camera.lastCommittedReceipts.isEmpty, "A terminal without source bytes cannot claim a saved photo")
        await camera.stop()
    }

    @MainActor @discardableResult private func attachRaster(_ window: UIWindow, name: String) -> UIImage {
        let format = UIGraphicsImageRendererFormat(); format.scale = 1; format.opaque = true
        let image = UIGraphicsImageRenderer(bounds: window.bounds, format: format).image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        let attachment = XCTAttachment(image: image); attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
        return image
    }

    @MainActor func testShippingShutterAndToolsRenderTheSelectedSpeedWithOneHiddenNativeTouchSurface() async throws {
        let fixture = await StorageHarness.make(name: "native-speed54-controls"), h = try XCTUnwrap(fixture)
        let (camera, _) = await CaptureFormatUISuite.makeModel(h: h, capability: CaptureFormatUISuite.capability())
        let app = AppEnvironment(); app.attach(camera: camera)
        camera.updateRootState(.writable(libraryID: h.libraryID, generation: h.generation))
        XCTAssertTrue(camera.isShutterEnabled, "The hosted shutter fixture must attach its writable synthetic root")
        let window = try await host(ShutterButton().environment(app).frame(maxWidth: .infinity, maxHeight: .infinity).background(.black))
        defer { window.isHidden = true; window.rootViewController = nil }
        let root = try XCTUnwrap(window.rootViewController?.view)
        XCTAssertTrue(descendants(ContinuousShutterTouchView.self, in: root).isEmpty, "Single remains an ordinary button")
        camera.setCaptureSpeed(.fps2)
        try await wait { descendants(ContinuousShutterTouchView.self, in: root).count == 1 }
        let surface = try XCTUnwrap(descendants(ContinuousShutterTouchView.self, in: root).first)
        XCTAssertFalse(surface.isAccessibilityElement)
        // SwiftUI does not vend a complete accessibility tree to this unit-test
        // host. Keep the actual native bridge hidden, and verify real rendering
        // below; VoiceOver default-action delivery remains a phone retest gate.
        attachRaster(window, name: "capture-speed54-shipping-held-shutter")

        window.rootViewController = UIHostingController(rootView: ToolsSheet(camera: camera).preferredColorScheme(.dark))
        window.layoutIfNeeded(); try await Task.sleep(for: .milliseconds(150))
        let toolsRoot = try XCTUnwrap(window.rootViewController?.view)
        let scroll = try XCTUnwrap(descendants(UIScrollView.self, in: toolsRoot).first)
        let maximum = max(0, scroll.contentSize.height - scroll.bounds.height + scroll.adjustedContentInset.bottom)
        scroll.setContentOffset(CGPoint(x: 0, y: min(maximum, 650)), animated: false)
        scroll.layoutIfNeeded(); try await Task.sleep(for: .milliseconds(150))
        let two = attachRaster(window, name: "capture-speed54-shipping-tools-2fps")
        camera.setCaptureSpeed(.fps5)
        window.layoutIfNeeded(); try await Task.sleep(for: .milliseconds(150))
        let five = attachRaster(window, name: "capture-speed54-shipping-tools-5fps")
        let first = try XCTUnwrap(two.cgImage?.dataProvider?.data) as Data
        let second = try XCTUnwrap(five.cgImage?.dataProvider?.data) as Data
        XCTAssertEqual(first.count, second.count)
        let changed = zip(first, second).reduce(0) { $0 + ($1.0 == $1.1 ? 0 : 1) }
        XCTAssertGreaterThan(changed, 5, "The actual Tools picker must visibly render a changed capture speed")
        XCTAssertEqual(camera.captureSpeed, .fps5)
        await camera.stop()
    }
}
#endif
