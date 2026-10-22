import Foundation
import Synchronization

// Native test bundles read the app's real types through the module; the
// standalone verifier compiles the app sources into the same executable and
// therefore cannot import a module. XCTest is only available in the native
// bundle, so it gates the import.
#if canImport(XCTest)
@testable import TruongCam
#endif


// Shared test harness.
//
// These files compile two ways:
//   * into the app's XCTest bundle (`TruongCamTests`), where `XCTestCase`
//     subclasses report each registered suite as its own test method;
//   * into the standalone local logic verifier built by
//     `scripts/verify-logic.sh` with `-D TC_TESTKIT_STANDALONE`, where a small
//     executable main runs the same suites and exits non-zero on failure.
//
// The point is that the verification logic is written once and really executes
// in this environment, where no simulator runtime is installed.

/// Evidence class for a check, kept explicit so no result is over-claimed.
enum TCEvidenceClass: String, Sendable {
    /// Real execution of platform-independent logic here on this Mac.
    case localHarness = "LOCAL_HARNESS"
    /// Compiled against the iOS SDK with no device execution.
    case verifiedLocalCompile = "VERIFIED_LOCAL_COMPILE"
    /// Requires the physical iPhone. Never produced by this harness.
    case verifiedDevice = "VERIFIED_DEVICE"
    /// Simulator execution.
    case verifiedSimulator = "VERIFIED_SIMULATOR"
}

struct TCCheckResult: Sendable {
    let name: String
    let passed: Bool
    let detail: String
}

/// One named, self-contained verification case.
struct TCCase: Sendable {
    let id: String
    let title: String
    let evidence: TCEvidenceClass
    let body: @Sendable (TCRecorder) async -> Void

    init(id: String,
         title: String,
         evidence: TCEvidenceClass = .localHarness,
         body: @escaping @Sendable (TCRecorder) async -> Void) {
        self.id = id
        self.title = title
        self.evidence = evidence
        self.body = body
    }
}

struct TCSuite: Sendable {
    let id: String
    let title: String
    let cases: [TCCase]

    init(id: String, title: String, cases: [TCCase]) {
        self.id = id
        self.title = title
        self.cases = cases
    }
}

/// Collects check results for one case. Assertions record failures instead of
/// aborting, so one case reports every problem it found.
final class TCRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var results: [TCCheckResult] = []

    var allPassed: Bool {
        lock.lock(); defer { lock.unlock() }
        return results.allSatisfy(\.passed)
    }

    var failures: [TCCheckResult] {
        lock.lock(); defer { lock.unlock() }
        return results.filter { !$0.passed }
    }

    var checks: [TCCheckResult] {
        lock.lock(); defer { lock.unlock() }
        return results
    }

    func check(_ name: String, _ condition: Bool, _ detail: @autoclosure () -> String = "") {
        let text = condition ? "" : detail()
        lock.lock()
        results.append(TCCheckResult(name: name, passed: condition, detail: text))
        lock.unlock()
    }

    func equal<T: Equatable>(_ name: String, _ actual: T, _ expected: T) {
        check(name, actual == expected, "expected \(expected), got \(actual)")
    }

    func notEqual<T: Equatable>(_ name: String, _ actual: T, _ unexpected: T) {
        check(name, actual != unexpected, "value unexpectedly equals \(unexpected)")
    }

    func close(_ name: String, _ actual: Double, _ expected: Double, tolerance: Double = 1e-9) {
        let delta = abs(actual - expected)
        check(name, delta <= tolerance, "expected \(expected) ± \(tolerance), got \(actual)")
    }

    func approxEqual(_ name: String, _ actual: Double, _ expected: Double, relativeTolerance: Double) {
        let denominator = max(abs(expected), 1e-12)
        let relative = abs(actual - expected) / denominator
        check(name, relative <= relativeTolerance,
              "expected ~\(expected) (rel tol \(relativeTolerance)), got \(actual)")
    }

    func expectThrows<E: Error>(_ name: String, _ body: () throws -> Void, _ describe: (E) -> String = { "\($0)" }) {
        do {
            try body()
            check(name, false, "expected an error, but the call succeeded")
        } catch let error as E {
            check(name, true, describe(error))
        } catch {
            check(name, false, "expected \(E.self), got \(type(of: error)): \(error)")
        }
    }
}

/// Registry of verification suites.
///
/// `tcRegisteredSuites` is a lazily initialized global, which Swift initializes
/// exactly once, thread-safely, on first access. Listing the suites there is the
/// single place to update when a suite file is added; both the XCTest target and
/// the local logic verifier read the same list.
enum TruongCamTestSuites {
    static var all: [TCSuite] { tcRegisteredSuites }
    static var caseCount: Int { all.reduce(0) { $0 + $1.cases.count } }
    static var identifiers: [String] { all.map(\.id) }
}

let tcRegisteredSuites: [TCSuite] = [
    CameraControlSpacing58Suite.suite,
    PreviewScratchCacheSuite.suite,
    CacheReadBoundsSuite.suite,
    UIOptimizations56Suite.suite,
    AppPerformance56Suite.suite,
    CameraLayout55Suite.suite,
    CaptureSpeedSuite.suite,
    ColorLoupeSuite.suite,
    JPEGPreparationUISuite.suite,
    JPEGCoreSuite.suite,
    JPEGStorageSuite.suite,
    CaptureFormatUISuite.suite,
    FriendlyErrorCopySuite.suite,
    FifthCameraReviewSuite.suite,
    FifthStorageReviewSuite.suite,
    FifthIndexReviewSuite.suite,
    FourthCameraReviewSuite.suite,
    FourthFocusReviewSuite.suite,
    FourthStorageReviewSuite.suite,
    FourthIndexReviewSuite.suite,
    ThirdCameraReviewSuite.suite,
    ThirdStorageReviewSuite.suite,
    ThirdUIReviewSuite.suite,
    SecondRootReviewSuite.suite,
    SecondCameraReviewSuite.suite,
    SecondStorageReviewSuite.suite,
    SecondUIAudit43Suite.suite,
    RootAudit43Suite.suite,
    CameraAudit43Suite.suite,
    StorageAuditSuite.suite,
    SharedAudit43Suite.suite,
    StartupRepairSuite.suite,
    LibraryPerformanceSuite.suite,
    GallerySelectionSuite.suite,
    PreviewNativeAccessSuite.suite,
    PhotoResourcePreparationSuite.suite,
    ResetAnalysisTopologySuite.suite,
    OriginalPhotoFocalLengthSuite.suite,
    ContractValueModelSuite.suite,
    RecoveryRepairSuite.suite,
    StopRepairSuite.suite,
    OperationCleanupSuite.suite,
    ExposureModelSuite.suite,
    FocusWhiteBalanceSuite.suite,
    PathSafetySuite.suite,
    MetadataSchemaSuite.suite,
    BoundedChannelSuite.suite,
    StorageSuite.suite,
    SequenceSuite.suite,
    PreviewAnalysisSuite.suite,
    RepairRegressionSuite.suite,
    IntegrationRepairSuite.suite,
    SecondRepairSuite.suite,
    ThirdRepairSuite.suite,
    FourthRepairSuite.suite,
    FifthRepairSuite.suite,
    SixthRepairSuite.suite,
    SeventhRepairSuite.suite,
    SeventhRepairSuiteR06.suite,
    SessionOrderSuite.suite,
    ExportOwnershipSuite.suite,
]

// MARK: - XCTest bridging

#if canImport(XCTest)
import XCTest

/// One XCTest case per registered suite. The per-case detail is aggregated so a
/// single XCTest failure names every failing check.
final class TruongCamRegisteredSuiteTests: XCTestCase {
    func testAllRegisteredSuites() async throws {
        let suites = TruongCamTestSuites.all
        try XCTSkipIf(suites.isEmpty, "No test suites were registered; the test target is misconfigured.")
        var failures: [String] = []
        for suite in suites {
            for testCase in suite.cases {
                let recorder = TCRecorder()
                await testCase.body(recorder)
                if !recorder.allPassed {
                    let detail = recorder.failures
                        .map { "    \($0.name): \($0.detail)" }
                        .joined(separator: "\n")
                    failures.append("\(suite.id)/\(testCase.id) \(testCase.title)\n\(detail)")
                }
            }
        }
        if !failures.isEmpty {
            XCTFail("\(failures.count) verification case(s) failed:\n" + failures.joined(separator: "\n"))
        }
    }

    func testSuitesAreRegistered() {
        XCTAssertGreaterThan(TruongCamTestSuites.caseCount, 0,
                             "Expected at least one registered verification case.")
    }
}
#endif

#if canImport(UIKit) && canImport(XCTest)
import UIKit
import SwiftUI

/// Renders the SHIPPING views with explicitly synthetic camera/storage/image
/// ports. These are UI-layout checks, never device RAW/Files acceptance.
private struct RedesignImagePort: ThumbnailProviding {
    let width: Int
    let height: Int
    var outcome: ThumbnailOutcome {
        .image(rgbaBytes: Array(repeating: [UInt8(30), 180, 30, 255], count: width * height).flatMap { $0 },
               width: width, height: height, pixelFingerprint: "synthetic-ui-layout")
    }
    func thumbnail(identity: String, relativePath: String, fingerprint: String?, targetLongEdge: Int) async -> ThumbnailOutcome { outcome }
    func viewerPreview(identity: String, relativePath: String, boundLongEdge: Int) async -> ThumbnailOutcome { outcome }
    func thumbnail(atAbsoluteURL: URL, identity: String, fingerprint: String?, targetLongEdge: Int) async -> ThumbnailOutcome { outcome }
    func viewerPreview(atAbsoluteURL: URL, identity: String, boundLongEdge: Int) async -> ThumbnailOutcome { outcome }
    func thumbnailSynchronously(atAbsoluteURL: URL, identity: String, fingerprint: String?, targetLongEdge: Int) -> ThumbnailOutcome { outcome }
    func viewerPreviewSynchronously(atAbsoluteURL: URL, identity: String, boundLongEdge: Int) -> ThumbnailOutcome { outcome }
    func clearMemoryCache() async {}
}

/// A bounded coordinated-read hold. It runs on the store's I/O owner, never on
/// the main actor, so the shipping viewer can keep responding during decode.
private final class HeldViewerImagePort: ThumbnailProviding, @unchecked Sendable {
    let firstID: String
    let heldID: String
    private let condition = NSCondition()
    private var held = true
    private var entered = false
    private var reads: [String] = []
    private let sourceIDsByFileName: [String: String]
    init(firstID: String, heldID: String, sourceIDsByFileName: [String: String]) {
        self.firstID = firstID; self.heldID = heldID; self.sourceIDsByFileName = sourceIDsByFileName
    }
    var didEnter: Bool { condition.lock(); defer { condition.unlock() }; return entered }
    var readIDs: [String] { condition.lock(); defer { condition.unlock() }; return reads }
    func release() { condition.lock(); held = false; condition.broadcast(); condition.unlock() }
    private func image(_ identity: String) -> ThumbnailOutcome {
        condition.lock()
        reads.append(identity)
        if identity == heldID {
            entered = true
            let deadline = Date().addingTimeInterval(4)
            while held, condition.wait(until: deadline) { }
        }
        condition.unlock()
        let pixel: [UInt8] = identity == firstID ? [30, 180, 30, 255] : identity == heldID ? [200, 30, 30, 255] : [30, 30, 210, 255]
        return .image(rgbaBytes: Array(repeating: pixel, count: 240 * 320).flatMap { $0 },
                      width: 240, height: 320, pixelFingerprint: identity)
    }
    func thumbnail(identity: String, relativePath: String, fingerprint: String?, targetLongEdge: Int) async -> ThumbnailOutcome { image(identity) }
    func viewerPreview(identity: String, relativePath: String, boundLongEdge: Int) async -> ThumbnailOutcome { image(identity) }
    func thumbnail(atAbsoluteURL: URL, identity: String, fingerprint: String?, targetLongEdge: Int) async -> ThumbnailOutcome { image(identity) }
    func viewerPreview(atAbsoluteURL: URL, identity: String, boundLongEdge: Int) async -> ThumbnailOutcome { image(identity) }
    func thumbnailSynchronously(atAbsoluteURL: URL, identity: String, fingerprint: String?, targetLongEdge: Int) -> ThumbnailOutcome { image(identity) }
    func viewerPreviewSynchronously(atAbsoluteURL url: URL, identity: String, boundLongEdge: Int) -> ThumbnailOutcome {
        // Associate literal fixture pixels/holds with the requested original,
        // independently of the production provider's private cache key format.
        image(sourceIDsByFileName[url.lastPathComponent] ?? identity)
    }
    func clearMemoryCache() async { }
}

final class RedesignVisualTests: XCTestCase {
    @MainActor private func makeWindow<V: View>(_ view: V) async throws -> UIWindow {
        // Hosted XCTest can start before SwiftUI has connected its first scene,
        // especially while another SDK build is using the host. Yield the main
        // actor for scene delivery; fail normally if it never arrives.
        for _ in 0..<100 {
            if UIApplication.shared.connectedScenes.contains(where: { $0 is UIWindowScene }) { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 402, height: 874)
        window.rootViewController = UIHostingController(rootView: view)
        window.makeKeyAndVisible()
        return window
    }
    @MainActor private func snapshot(_ window: UIWindow, name: String) throws -> UIImage {
        // Capture presented viewer content as well as the root. Drawing only the
        // root controller's view renders the gallery beneath a full-screen cover.
        let view = window
        view.layoutIfNeeded()
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let image = UIGraphicsImageRenderer(bounds: view.bounds, format: format).image { _ in
            view.drawHierarchy(in: view.bounds, afterScreenUpdates: true)
        }
        let attachment = XCTAttachment(image: image)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("TruongCamRedesignVisuals", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try XCTUnwrap(image.pngData()).write(to: directory.appendingPathComponent(name + ".png"))
        print("TC_VISUAL_PATH \(directory.path)")
        return image
    }
    private func pixels(_ image: UIImage) throws -> (bytes: [UInt8], width: Int, height: Int, stride: Int) {
        let cg = try XCTUnwrap(image.cgImage)
        let stride = cg.width * 4
        var bytes = [UInt8](repeating: 0, count: stride * cg.height)
        try bytes.withUnsafeMutableBytes { raw in
            let context = try XCTUnwrap(CGContext(data: raw.baseAddress, width: cg.width, height: cg.height,
                bitsPerComponent: 8, bytesPerRow: stride, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue))
            context.draw(cg, in: CGRect(x: 0, y: 0, width: cg.width, height: cg.height))
        }
        return (bytes, cg.width, cg.height, stride)
    }
    private func shutterY(_ image: UIImage) throws -> Int {
        let p = try pixels(image)
        var maximum = 0, result = -1
        for y in max(0, p.height - 220)..<p.height {
            var white = 0
            for x in (p.width / 2 - 30)..<(p.width / 2 + 30) {
                let offset = y * p.stride + x * 4
                if p.bytes[offset] > 220, p.bytes[offset + 1] > 220, p.bytes[offset + 2] > 220 { white += 1 }
            }
            if white > maximum { maximum = white; result = y }
        }
        XCTAssertGreaterThan(maximum, 40, "The actual rendered shutter must be visible.")
        return result
    }

    @MainActor func testShippingHardwareInteractionFollowsModalEligibility() async throws {
        let fixture=await StorageHarness.make(name:"native-hardware-shutter")
        let h=try XCTUnwrap(fixture)
        let camera=CameraViewModel(camera:SyntheticCameraService(capability:StartupRepairSuite.controlFixture(modes:[.auto,.manual])),
            capture:CaptureCoordinator(camera:ChainCameraSpy(),store:h.store,clock:SystemMonotonicClock()),
            metering:MeteringService(clock:SystemMonotonicClock()),preferences:SyntheticPreferenceStore(),levelFeed:SyntheticLevelFeed())
        let app=AppEnvironment();app.attach(camera:camera);app.attach(store:h.store,index:InMemoryLibraryIndex());app.graphState = .ready
        await camera.start()
        let window=try await makeWindow(CameraScreen().environment(app))
        defer { window.isHidden=true }
        func interactions(_ view:UIView)->[AVCaptureEventInteraction] {
            view.interactions.compactMap { $0 as? AVCaptureEventInteraction } + view.subviews.flatMap(interactions)
        }
        try await Task.sleep(for:.milliseconds(300))
        let hardware=try XCTUnwrap(interactions(window).first,"Shipping SwiftUI modifier must install a real AVKit interaction.")
        XCTAssertTrue(hardware.isEnabled)
        camera.isToolsSheetPresented=true
        try await Task.sleep(for:.milliseconds(300))
        XCTAssertFalse(hardware.isEnabled,"A covered camera must return hardware buttons to the system.")
        camera.isToolsSheetPresented=false
        await camera.handleCameraScreenRevealed()
        try await Task.sleep(for:.milliseconds(100))
        XCTAssertTrue(hardware.isEnabled)
        let presenter = ExportPresenter(store: nil)
        app.exportPresenter = presenter
        let session = ExportSession(sessionID: UUID(), directoryRelativePath: "synthetic/hardware-export",
            fileURLs: [], includedSidecars: false, missingItems: [], totalByteCount: 0,
            preparedAtUTC: StorageFixture.fixedDate)
        // No share controller/file is created by this CameraScreen-only host.
        // It exercises the shipping native hardware modifier against the exact
        // export lifetime states used by an actual native presentation.
        presenter.presentPrepared(session, description: "Synthetic hardware eligibility")
        presenter.presentationWillPresent(sessionID: session.sessionID)
        try await Task.sleep(for:.milliseconds(100))
        XCTAssertFalse(hardware.isEnabled)
        presenter.requestDismissal(sessionID: session.sessionID)
        XCTAssertNil(presenter.presented)
        try await Task.sleep(for:.milliseconds(100))
        XCTAssertFalse(hardware.isEnabled,"Cleared share intent does not mean native dismissal has finished.")
        await presenter.presentationDidDismiss(sessionID: session.sessionID)
        try await Task.sleep(for:.milliseconds(100))
        XCTAssertTrue(hardware.isEnabled,"Only the retired native presentation releases hardware controls.")
        await camera.handleCameraScreenCovered()
    }

    func testCPUSwitchBitmapKeepsPixelOrientationColorStrideAndRejectsUnknownFormats() throws {
        var value: CVPixelBuffer?
        XCTAssertEqual(CVPixelBufferCreate(nil,3,2,kCVPixelFormatType_32BGRA,nil,&value),kCVReturnSuccess)
        let buffer=try XCTUnwrap(value)
        CVPixelBufferLockBaseAddress(buffer,[])
        let source=try XCTUnwrap(CVPixelBufferGetBaseAddress(buffer)).assumingMemoryBound(to:UInt8.self)
        for y in 0..<2 { for x in 0..<3 {
            let i=y*CVPixelBufferGetBytesPerRow(buffer)+x*4, v=UInt8(y*3+x+1)
            source[i]=v+20;source[i+1]=v+10;source[i+2]=v;source[i+3]=255
        } }
        CVPixelBufferUnlockBaseAddress(buffer,[])
        let fixtures:[(Int,Bool,[UInt8])]=[(0,false,[1,2,3,4,5,6]),(0,true,[3,2,1,6,5,4]),
            (90,false,[4,1,5,2,6,3]),(90,true,[1,4,2,5,3,6]),
            (180,false,[6,5,4,3,2,1]),(180,true,[4,5,6,1,2,3]),
            (270,false,[3,6,2,5,1,4]),(270,true,[6,3,5,2,4,1])]
        for (angle,mirror,expected) in fixtures {
            let image=try XCTUnwrap(PreviewDisplayBridge.transitionBitmap(buffer,rotation:angle,mirrored:mirror))
            let data=try XCTUnwrap(image.dataProvider?.data), pointer=try XCTUnwrap(CFDataGetBytePtr(data))
            XCTAssertEqual((0..<6).map { pointer[$0*4] },expected)
            XCTAssertEqual((0..<6).map { pointer[$0*4+1] },expected.map { $0+10 })
            XCTAssertEqual((0..<6).map { pointer[$0*4+2] },expected.map { $0+20 })
        }
        XCTAssertNil(PreviewDisplayBridge.transitionBitmap(buffer,rotation:45,mirrored:false))
        var unknown: CVPixelBuffer?
        XCTAssertEqual(CVPixelBufferCreate(nil,4,4,kCVPixelFormatType_OneComponent8,nil,&unknown),kCVReturnSuccess)
        XCTAssertNil(PreviewDisplayBridge.transitionBitmap(try XCTUnwrap(unknown),rotation:0,mirrored:false))
    }

    func testCPUSwitchBitmapUsesTaggedYCbCrAndUnrenderableFramesStillReleaseCover() throws {
        var output:CVPixelBuffer?
        XCTAssertEqual(CVPixelBufferCreate(nil,4,2,kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,nil,&output),kCVReturnSuccess)
        let buffer=try XCTUnwrap(output)
        CVPixelBufferLockBaseAddress(buffer,[])
        let y=try XCTUnwrap(CVPixelBufferGetBaseAddressOfPlane(buffer,0)).assumingMemoryBound(to:UInt8.self)
        let uv=try XCTUnwrap(CVPixelBufferGetBaseAddressOfPlane(buffer,1)).assumingMemoryBound(to:UInt8.self)
        for row in 0..<2 { for col in 0..<4 { y[row*CVPixelBufferGetBytesPerRowOfPlane(buffer,0)+col]=81 } }
        for col in 0..<2 { uv[col*2]=90;uv[col*2+1]=240 }
        CVPixelBufferUnlockBaseAddress(buffer,[])
        XCTAssertNil(PreviewDisplayBridge.transitionBitmap(buffer,rotation:0,mirrored:false),"Do not guess colors for an untagged buffer.")
        let bridge=PreviewDisplayBridge()
        let geometry=PreviewGeometrySnapshot(configurationGeneration:.zero,layoutGeneration:1,
            imageDimensions:PixelDimensions(width:4,height:2),cleanApertureDimensions:nil,
            previewLayerContentRect:TCRect(x:0,y:0,width:400,height:200),bufferOrientation:1,
            isMirrored:false,analysisRotationDegrees:0,isVideoMirrored:false,capturedAtUTC:Date())
        bridge.setGeometry(geometry)
        bridge.recordPreviewBuffer(buffer,configuration:.zero,layout:1)
        XCTAssertTrue(bridge.hasCurrentFrame(for:geometry),"A missing optional blur bitmap must not trap the user behind the switch cover.")
        XCTAssertNil(bridge.frozenFrame(for:geometry))
        CVBufferSetAttachment(buffer,kCVImageBufferYCbCrMatrixKey,kCVImageBufferYCbCrMatrix_ITU_R_601_4,.shouldPropagate)
        let image=try XCTUnwrap(PreviewDisplayBridge.transitionBitmap(buffer,rotation:0,mirrored:false))
        let data=try XCTUnwrap(image.dataProvider?.data), pixels=try XCTUnwrap(CFDataGetBytePtr(data))
        XCTAssertEqual(pixels[0],254);XCTAssertEqual(pixels[1],0);XCTAssertEqual(pixels[2],0)
        CVBufferSetAttachment(buffer,kCVImageBufferYCbCrMatrixKey,kCVImageBufferYCbCrMatrix_ITU_R_709_2,.shouldPropagate)
        let other=try XCTUnwrap(PreviewDisplayBridge.transitionBitmap(buffer,rotation:0,mirrored:false))
        let otherData=try XCTUnwrap(other.dataProvider?.data)
        XCTAssertNotEqual(data,otherData,"The actual matrix changes the converted colors.")
        bridge.setGeometry(nil)
        XCTAssertFalse(bridge.hasCurrentFrame(for:geometry))
    }

    @MainActor func testMarkedMeterAndCompactHeaderHaveClearTicksAndTopInset() async throws {
        let fixture=await StorageHarness.make(name:"meter-header")
        let h=try XCTUnwrap(fixture)
        let service=SyntheticCameraService(capability:StartupRepairSuite.controlFixture(modes:[.auto,.manual]))
        let camera=CameraViewModel(camera:service,
            capture:CaptureCoordinator(camera:ChainCameraSpy(),store:h.store,clock:SystemMonotonicClock()),
            metering:MeteringService(clock:SystemMonotonicClock()),preferences:SyntheticPreferenceStore(),levelFeed:SyntheticLevelFeed())
        let app=AppEnvironment();app.attach(camera:camera);await camera.start()
        let compact=UIHostingController(rootView:CameraTopRow(isCompact:true).environment(app))
        let fit=compact.sizeThatFits(in:CGSize(width:600,height:200))
        XCTAssertGreaterThanOrEqual(fit.height,44,"The centered EV capsule must belong to a full-height row instead of protruding above a 21-pt row.")
        let meters=HStack(spacing:44) {
            ExposureMeterOverlay(offsetEV:-3)
            ExposureMeterOverlay(offsetEV:0)
            ExposureMeterOverlay(offsetEV:3)
            ExposureMeterOverlay(offsetEV:nil)
        }.padding(40).background(Color.black)
        let window=try await makeWindow(meters)
        defer { window.isHidden=true }
        let image=try snapshot(window,name:"marked-exposure-meters")
        let p=try pixels(image)
        let bright=p.bytes.enumerated().filter { $0.offset%4 != 3 && $0.element>180 }.count
        XCTAssertGreaterThan(bright,300,"Actual meter ticks and the pointer must render visibly.")
        window.rootViewController=UIHostingController(rootView:VStack(spacing:0) {
            CameraTopRow(isCompact:true).environment(app).padding(.horizontal,14).padding(.top,14)
            Spacer()
        }.background(Color.black))
        window.frame=CGRect(x:0,y:0,width:874,height:402)
        try await Task.sleep(for:.milliseconds(150))
        _ = try snapshot(window,name:"landscape-ev-header")
        camera.composition.gridMode = .off
        camera.composition.levelEnabled = false
        camera.composition.histogramEnabled = false
        camera.composition.peakingEnabled = false
        camera.composition.zebrasEnabled = false
        camera.composition.loupeEnabled = false
        camera.setExposureMode(.manual)
        XCTAssertEqual(camera.exposure.mode,.manual)
        XCTAssertFalse(camera.isBiasAvailable)
        let aidHost=UIHostingController(rootView:AidOverlays(camera:camera).environment(app).background(Color.black).preferredColorScheme(.dark))
        aidHost.view.frame=CGRect(x:0,y:0,width:300,height:400)
        window.rootViewController=aidHost
        try await Task.sleep(for:.milliseconds(100))
        let manual=try snapshot(window,name:"manual-marked-meter")
        let manualPixels=try pixels(manual)
        let manualBright=manualPixels.bytes.enumerated().filter { $0.offset%4 != 3 && $0.element>180 }.count
        await service.holdSwitch()
        let switching=Task { await camera.selectLens(.ultraWide) }
        let deadline=ContinuousClock.now.advanced(by:.seconds(2))
        while await service.switchRequests.isEmpty, ContinuousClock.now<deadline { await Task.yield() }
        XCTAssertTrue(camera.isPreviewTransitionVisible)
        try await Task.sleep(for:.milliseconds(50))
        let covered=try snapshot(window,name:"switch-hidden-meter")
        let coveredPixels=try pixels(covered)
        let coveredBright=coveredPixels.bytes.enumerated().filter { $0.offset%4 != 3 && $0.element>180 }.count
        await service.releaseSwitch()
        await switching.value
        XCTAssertEqual(coveredBright,0,"With other aids disabled, switching hides all meter pixels.")
        XCTAssertGreaterThan(manualBright,coveredBright,"Full manual retains the actual meter; it is not confused with compensation eligibility.")
    }

    @MainActor func testSwitchCoverUsesImmutableBoundedBitmapAndRejectsOtherCameraOrLayout() async throws {
        let bridge = PreviewDisplayBridge()
        let geometry = PreviewGeometrySnapshot(configurationGeneration:ConfigurationGeneration(3),layoutGeneration:7,
            imageDimensions:PixelDimensions(width:8,height:4),cleanApertureDimensions:nil,
            previewLayerContentRect:TCRect(x:0,y:0,width:200,height:400),bufferOrientation:1,
            isMirrored:true,analysisRotationDegrees:90,isVideoMirrored:true,capturedAtUTC:Date(),interfaceOrientation:.portrait)
        bridge.setGeometry(geometry)
        var buffer: CVPixelBuffer?
        XCTAssertEqual(CVPixelBufferCreate(nil, 8, 4, kCVPixelFormatType_32BGRA,
            [kCVPixelBufferCGImageCompatibilityKey:true] as CFDictionary,&buffer),kCVReturnSuccess)
        let pixel = try XCTUnwrap(buffer)
        func fill(_ value: UInt8) {
            CVPixelBufferLockBaseAddress(pixel,[])
            defer { CVPixelBufferUnlockBaseAddress(pixel,[]) }
            let bytes = CVPixelBufferGetBaseAddress(pixel)!.assumingMemoryBound(to:UInt8.self)
            for y in 0..<4 { for x in 0..<8 {
                let offset = y * CVPixelBufferGetBytesPerRow(pixel) + x * 4
                bytes[offset]=value; bytes[offset+1]=value; bytes[offset+2]=value; bytes[offset+3]=255
            } }
        }
        fill(180)
        bridge.recordPreviewBuffer(pixel,configuration:ConfigurationGeneration(3),layout:7)
        let frame = try XCTUnwrap(bridge.frozenFrame(for:geometry))
        XCTAssertEqual(frame.image.width,4); XCTAssertEqual(frame.image.height,8)
        XCTAssertLessThanOrEqual(max(frame.image.width,frame.image.height),160)
        let bitmap = UIImage(cgImage:frame.image)
        let before = try pixels(bitmap)
        fill(20)
        XCTAssertEqual(try pixels(bitmap).bytes,before.bytes,"Changing native pixels cannot mutate the frozen still.")
        var other = geometry; other.interfaceOrientation = .landscapeLeft
        // Same dimensions do not authorize a different acquisition/layout.
        let stale = PreviewGeometrySnapshot(configurationGeneration:ConfigurationGeneration(4),layoutGeneration:7,
            imageDimensions:geometry.imageDimensions,cleanApertureDimensions:nil,previewLayerContentRect:geometry.previewLayerContentRect,
            bufferOrientation:1,isMirrored:false,analysisRotationDegrees:270,isVideoMirrored:false,capturedAtUTC:Date())
        XCTAssertNil(bridge.frozenFrame(for:stale))
        bridge.setGeometry(nil)
        XCTAssertNil(bridge.frozenFrame(for:geometry))
        XCTAssertNotEqual(other.interfaceOrientation,geometry.interfaceOrientation)
        let window = try await makeWindow(FrozenCameraTransition(frame:frame))
        defer { window.isHidden=true }
        let cover = try snapshot(window,name:"frozen-switch-cover")
        let coverPixels = try pixels(cover)
        XCTAssertTrue(coverPixels.bytes.enumerated().filter { $0.offset % 4 == 3 }.allSatisfy { $0.element == 255 },"Switch cover must be opaque so the changing live feed cannot show through.")
        _ = try snapshot(window,name:"frozen-switch-cover-second")
    }

    @MainActor func testLaunchPreparationWaitsForOwnedStartupAndResourcesButDoesNotHideFailure() async throws {
        let fixture = await StorageHarness.make(name:"native-launch-preparation")
        let h = try XCTUnwrap(fixture)
        let service = SyntheticCameraService(capability:StartupRepairSuite.controlFixture(modes:[.auto]))
        await service.configureStartDelay(.milliseconds(100))
        await service.installDisplaySession(AVCaptureSession())
        let model = CameraViewModel(camera:service,capture:CaptureCoordinator(camera:ChainCameraSpy(),store:h.store,clock:SystemMonotonicClock()),
            metering:MeteringService(clock:SystemMonotonicClock()),preferences:SyntheticPreferenceStore(),levelFeed:SyntheticLevelFeed())
        let app = AppEnvironment(); app.isPreparingExperience = true; app.attach(camera:model)
        XCTAssertFalse(app.canFinishLaunchPreparation)
        let startup = Task { await model.start() }
        app.launchResourcesReady = true
        XCTAssertFalse(app.canFinishLaunchPreparation,"Warmed display resources cannot imply a ready native camera.")
        await startup.value
        XCTAssertFalse(app.canFinishLaunchPreparation,"Native graph completion alone cannot reveal an unrendered preview.")
        model.updateGeometry(PreviewGeometrySnapshot(configurationGeneration:.zero,layoutGeneration:1,
            imageDimensions:PixelDimensions(width:4000,height:3000),cleanApertureDimensions:nil,
            previewLayerContentRect:TCRect(x:0,y:0,width:300,height:400),bufferOrientation:1,
            isMirrored:false,analysisRotationDegrees:90,isVideoMirrored:false,capturedAtUTC:Date(),interfaceOrientation:.portrait))
        XCTAssertFalse(app.canFinishLaunchPreparation,"Geometry alone cannot replace the preview-layer rendering acknowledgement.")
        XCTAssertFalse(model.previewDidResume(generation:ConfigurationGeneration(99),layout:1))
        XCTAssertFalse(app.canFinishLaunchPreparation)
        XCTAssertTrue(model.previewDidResume(generation:.zero,layout:1))
        XCTAssertTrue(app.canFinishLaunchPreparation)
        app.finishLaunchPreparationIfReady()
        XCTAssertFalse(app.isPreparingExperience)
        await model.handleSceneBecameInactive()
        XCTAssertFalse(app.isPreparingExperience,"A later background/reopen must not repeat the initial setup screen.")
        let window = try await makeWindow(LaunchPreparationView())
        defer { window.isHidden = true }
        _ = try snapshot(window,name:"launch-preparation")
        let failed = CameraViewModel(camera:SyntheticCameraService(preparationFailure:CaptureFailure(kind:.noCamera,operation:"synthetic")),
            capture:CaptureCoordinator(camera:ChainCameraSpy(),store:h.store,clock:SystemMonotonicClock()),
            metering:MeteringService(clock:SystemMonotonicClock()),preferences:SyntheticPreferenceStore(),levelFeed:SyntheticLevelFeed())
        let recovery = AppEnvironment(); recovery.isPreparingExperience = true; recovery.attach(camera:failed)
        await failed.start()
        XCTAssertTrue(recovery.canFinishLaunchPreparation,"Actual startup failure must expose recovery even before display resources finish.")
        recovery.finishLaunchPreparationIfReady()
        XCTAssertFalse(recovery.isPreparingExperience)
        let thumbnails = ThumbnailService(rootURLProvider:{ nil },diskCacheDirectory:h.root.appendingPathComponent("warm-cache"))
        XCTAssertFalse(thumbnails.isRenderContextAllocated,"Constructing a gallery provider must not initialize Core Image or run a synthetic codec warm-up.")
        XCTAssertFalse(FileManager.default.fileExists(atPath:h.root.appendingPathComponent("warm-cache").path),"Resource preparation never accesses/creates a photo cache or original.")
    }

    func testCaptureSerializationFIFOOffloadsCallbackAndCannotPublishTerminalBeforeBytes() async throws {
        let work = OrderedCaptureWork()
        let release = DispatchSemaphore(value:0)
        let began = expectation(description:"worker began")
        let done = expectation(description:"terminal after bytes")
        let order = Mutex<[String]>([])
        let intent = CaptureIntent(captureID:CaptureID(),libraryID:LibraryID(),requestedDimensions:PixelDimensions(width:4032,height:3024),
            exposure:.auto,biasEV:0,focus:FocusIntent(mode:.continuousAuto,position:nil,pointOfInterest:nil),
            whiteBalance:WhiteBalanceIntent(mode:.auto,temperatureAndTint:nil),configurationGeneration:.zero,rootGeneration:RootGeneration(1),
            physicalCameraKind:.wide,createdAtUTC:Date(),timezoneOffsetSeconds:0,mode:.single)
        let request = PerCaptureRequest(captureID:intent.captureID,intent:intent,rawPixelFormatType:0x4247_4734,rawFileType:"com.adobe.raw-image",maximumRepresentations:1)
        XCTAssertTrue(request.bindNativeSettingsID(42))
        work.enqueue {
            XCTAssertFalse(Thread.isMainThread)
            began.fulfill()
            _ = release.wait(timeout:.now()+3)
            XCTAssertTrue(request.recordRepresentation(tcSeqRepresentation(intent)))
            order.withLock { $0.append("bytes") }
        }
        await fulfillment(of:[began],timeout:2)
        work.enqueue {
            _ = request.recordNativeTerminal(settingsID:42,mappedFailure:nil)
            order.withLock { $0.append("terminal") }; done.fulfill()
        }
        XCTAssertNil(request.terminal.current)
        XCTAssertEqual(request.recordedRepresentationCount,0)
        XCTAssertEqual(order.withLock { $0 },[],"Callback returned while native representation is held; terminal remains queued.")
        release.signal()
        await fulfillment(of:[done],timeout:2)
        XCTAssertEqual(order.withLock { $0 },["bytes","terminal"])
        XCTAssertEqual(request.recordedRepresentationCount,1)
        XCTAssertEqual(request.terminal.current,.success,"Held serialization must not become success-without-bytes or discard an intact source.")
    }

    @MainActor func testPreviewDefersNativeAccessDuringSwitchAndCoalescesSteadyGeometry() async throws {
        let host = PreviewHostView(frame: CGRect(x:0,y:0,width:402,height:536))
        host.imageDimensions = PixelDimensions(width:4000,height:3000)
        host.setConnectionConfigurationEnabled(false)
        let displaySession = AVCaptureSession()
        host.bindDisplaySession(displaySession)
        for _ in 0..<1000 { host.bindDisplaySession(displaySession) }
        XCTAssertEqual(host.sessionAssignmentCount,0,"Session attachment is native work too and must wait while rebuilding.")
        host.rotationAngles = CameraRotationAngles(portrait:270,portraitUpsideDown:90,landscapeLeft:0,landscapeRight:180)
        host.configurationGeneration = ConfigurationGeneration(5)
        host.updateMirroring(true)
        for _ in 0..<1000 {
            host.applyInterfaceOrientation(.portrait)
            host.synchronizeConfiguration()
            host.refreshGeometry()
        }
        XCTAssertEqual(host.connectionLookupCount,0,"No native UI-thread connection access while rebuilding.")
        XCTAssertEqual(host.geometryComputationCount,0,"No layer conversion while rebuilding.")
        var geometry: CameraPreviewView.PreviewGeometry?
        host.onGeometryChanged = { geometry = $0 }
        host.setConnectionConfigurationEnabled(true)
        host.synchronizeConfiguration()
        for _ in 0..<1000 { host.bindDisplaySession(displaySession) }
        XCTAssertEqual(host.sessionAssignmentCount,1,"Resume binds the pending display handle once; steady updates reuse it.")
        host.applyInterfaceOrientation(.portrait)
        try await Task.sleep(for:.milliseconds(20))
        XCTAssertEqual(geometry?.rotationDegrees,270,"Apply the selected front camera's angle immediately.")
        XCTAssertEqual(geometry?.interfaceOrientation,.portrait,"Front 270-degree sensor rotation does not invert level axes.")
        let computations = host.geometryComputationCount
        for _ in 0..<1000 { host.refreshGeometry() }
        XCTAssertEqual(host.geometryComputationCount,computations,"Unchanged UI/readback must not repeat expensive native layer conversion.")
        host.applyInterfaceOrientation(.landscapeLeft)
        try await Task.sleep(for:.milliseconds(20))
        XCTAssertEqual(geometry?.rotationDegrees,0)
        XCTAssertEqual(geometry?.interfaceOrientation,.landscapeRight)
        host.applyInterfaceOrientation(.landscapeRight)
        try await Task.sleep(for:.milliseconds(20))
        XCTAssertEqual(geometry?.rotationDegrees,180)
        XCTAssertEqual(geometry?.interfaceOrientation,.landscapeLeft)
        host.configurationGeneration = ConfigurationGeneration(6)
        host.refreshGeometry()
        try await Task.sleep(for:.milliseconds(20))
        XCTAssertEqual(geometry?.configurationGeneration,ConfigurationGeneration(6),"Same-sized replacement graph must republish geometry.")
    }

    @MainActor func testOppositeLandscapePublishesGeometryAtIdenticalBounds() async throws {
        let host = PreviewHostView(frame: CGRect(x: 0,y: 0,width: 480,height: 360))
        host.imageDimensions = PixelDimensions(width: 1920,height: 1440)
        host.configurationGeneration = ConfigurationGeneration(4)
        var received: [CameraPreviewView.PreviewGeometry] = []
        host.onGeometryChanged = { received.append($0) }
        host.applyInterfaceOrientation(.landscapeLeft)
        await Task.yield()
        try await Task.sleep(for: .milliseconds(20))
        let left = try XCTUnwrap(received.last)
        host.applyInterfaceOrientation(.landscapeRight)
        await Task.yield()
        try await Task.sleep(for: .milliseconds(20))
        let right = try XCTUnwrap(received.last)
        XCTAssertEqual(left.viewSize,right.viewSize)
        XCTAssertEqual(left.rotationDegrees,180)
        XCTAssertEqual(right.rotationDegrees,0)
        XCTAssertGreaterThan(right.layoutGeneration,left.layoutGeneration)
        host.refreshGeometry()
        try await Task.sleep(for: .milliseconds(20))
        XCTAssertEqual(received.count,2,"Unchanged geometry must not churn requests.")
        host.configurationGeneration = ConfigurationGeneration(5)
        host.refreshGeometry()
        try await Task.sleep(for: .milliseconds(20))
        XCTAssertEqual(received.last?.configurationGeneration,ConfigurationGeneration(5))
        XCTAssertGreaterThan(try XCTUnwrap(received.last).layoutGeneration,right.layoutGeneration)
        host.rotationAngles = CameraRotationAngles(portrait:90,portraitUpsideDown:270,landscapeLeft:270,landscapeRight:90)
        host.applyInterfaceOrientation(.landscapeLeft)
        try await Task.sleep(for:.milliseconds(20))
        XCTAssertEqual(received.last?.rotationDegrees,270,"Use the selected camera's SDK rotations, not a hardcoded landscape table.")
    }

    @MainActor func testZebraOverlayPaintsOnlyBrightMaskAndShowsStripes() async throws {
        // Execute the SHIPPING Canvas + image-alpha mask, not a pixel renderer
        // copied into the test. Left half is bright; right half has no mask.
        let mask: [UInt8] = (0..<(480 * 360)).map { $0 % 480 < 240 ? 255 : 0 }
        let window = try await makeWindow(ZStack {
            Color(red: 0.2,green: 0.2,blue: 0.2)
            ZebraOverlay(mask:mask,width:480,height:360)
        }.frame(width:320,height:240))
        defer { window.isHidden = true }
        try await Task.sleep(for: .milliseconds(300))
        let p = try pixels(snapshot(window,name:"zebra-visible-mask"))
        let startX = (p.width-320)/2, startY = (p.height-240)/2
        var bright = 0, dark = 0, clearErrors = 0
        for y in (startY+30)..<(startY+210) {
            for x in (startX+20)..<(startX+140) {
                let v = p.bytes[y*p.stride+x*4]
                if v > 90 { bright += 1 }
                if v < 35 { dark += 1 }
            }
            for x in (startX+180)..<(startX+300) {
                let v = p.bytes[y*p.stride+x*4]
                if v < 40 || v > 65 { clearErrors += 1 }
            }
        }
        XCTAssertGreaterThan(bright,1000,"Visible white diagonal zebra regions.")
        XCTAssertGreaterThan(dark,1000,"Visible dark diagonal zebra regions.")
        XCTAssertEqual(clearErrors,0,"Mask must not paint unhighlighted luma.")
    }

    @MainActor func testFrontHEIFModeRendersCenteredControlsInPortraitAndLandscape() async throws {
        let fixture = await StorageHarness.make(name: "native-front-ui")
        let h = try XCTUnwrap(fixture)
        let camera = CameraViewModel(camera: SyntheticCameraService(capability: StartupRepairSuite.controlFixture(modes: [.auto], kind: .front, heif: true)),
            capture: CaptureCoordinator(camera: ChainCameraSpy(), store: h.store, clock: SystemMonotonicClock()),
            metering: MeteringService(clock: SystemMonotonicClock()), preferences: SyntheticPreferenceStore(), levelFeed: SyntheticLevelFeed())
        let app = AppEnvironment(); app.attach(camera: camera); app.attach(store: h.store, index: InMemoryLibraryIndex()); app.graphState = .ready
        await camera.start()
        let window = try await makeWindow(CameraScreen().environment(app).preferredColorScheme(.dark))
        defer { window.isHidden = true }
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertEqual(camera.captureFormatLabel, "HEIF · Front")
        XCTAssertEqual(camera.lensButtons.count, 0)
        _ = try shutterY(snapshot(window, name: "front-heif-portrait"))
        window.frame = CGRect(x: 0, y: 0, width: 874, height: 402)
        window.rootViewController?.view.frame = window.bounds
        window.rootViewController?.view.setNeedsLayout(); window.layoutIfNeeded()
        try await Task.sleep(for: .milliseconds(150))
        _ = try snapshot(window, name: "front-heif-landscape")
        camera.openPanel = .whiteBalance
        try await Task.sleep(for: .milliseconds(150))
        _ = try snapshot(window, name: "front-heif-landscape-wb")
    }

    private func visibleShutterFrame(_ image: UIImage) throws -> CGRect? {
        let p = try pixels(image)
        var visited = [Bool](repeating: false, count: p.width * p.height)
        var best: CGRect?, bestArea = 0
        func white(_ index: Int) -> Bool {
            let i = (index / p.width) * p.stride + (index % p.width) * 4
            return p.bytes[i] > 220 && p.bytes[i+1] > 220 && p.bytes[i+2] > 220
        }
        for start in 0..<visited.count where !visited[start] && white(start) {
            var queue = [start], cursor = 0
            visited[start] = true
            var x0 = p.width, x1 = 0, y0 = p.height, y1 = 0
            while cursor < queue.count {
                let i = queue[cursor]; cursor += 1
                let x = i % p.width, y = i / p.width
                x0 = min(x0,x); x1 = max(x1,x); y0 = min(y0,y); y1 = max(y1,y)
                for (nx,ny) in [(x-1,y),(x+1,y),(x,y-1),(x,y+1)] where nx >= 0 && ny >= 0 && nx < p.width && ny < p.height {
                    let n = ny * p.width + nx
                    if !visited[n] && white(n) { visited[n] = true; queue.append(n) }
                }
            }
            let w = x1-x0+1, h = y1-y0+1
            if queue.count > max(bestArea,1000), w >= 35, h >= 35, Double(w)/Double(h) > 0.7, Double(w)/Double(h) < 1.4 {
                bestArea = queue.count; best = CGRect(x:x0,y:y0,width:w,height:h)
            }
        }
        return best
    }

    @MainActor func testSequenceShutterShowsStopAndPerFrameCounter() async throws {
        let fixture = await StorageHarness.make(name: "sequence-stop-visual")
        let storage = try XCTUnwrap(fixture)
        let sequence = SeqHarness(rootState: storage.store.rootState, plannedCount: 3)
        let camera = CameraViewModel(camera: SyntheticCameraService(capability: StartupRepairSuite.controlFixture(modes: [.auto,.manual], generation: SeqTestSupport.configurationGeneration)),
            capture: CaptureCoordinator(camera: ChainCameraSpy(), store: storage.store, clock: SystemMonotonicClock()),
            metering: MeteringService(clock: sequence.clock), clock: sequence.clock,
            preferences: SyntheticPreferenceStore(), levelFeed: SyntheticLevelFeed())
        let app = AppEnvironment()
        app.attach(store: storage.store, index: SQLiteIndex(databaseURL: FileManager.default.temporaryDirectory.appendingPathComponent("sequence-visual-\(UUID().uuidString).sqlite")))
        app.attach(camera: camera); app.graphState = .ready
        await camera.start(); camera.attach(sequence: sequence.coordinator); camera.updateRootState(storage.store.rootState)
        camera.setExposureBracketEnabled(true)
        let window = try await makeWindow(VStack { Spacer(); CameraShutterRail() }.padding(.horizontal, 16).background(.black).environment(app))
        defer { window.isHidden = true }
        await sequence.executor.setBlocking(true); await camera.activateShutter()
        _ = await driveVirtualClock(sequence.clock, maxSteps: 4_000) { await sequence.executor.blockedCount > 0 }
        let id = try XCTUnwrap(camera.activeSequenceID)
        camera.receiveShutterFeedback(CaptureShutterFeedback(captureID: CaptureID(), sequenceID: id, ordinal: 1, plannedCount: 3,
            generation: camera.capability.generation, capturedAtUTC: Date()))
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(camera.sequenceFrameOrdinal, 2)
        XCTAssertTrue(camera.lastCommittedReceipts.isEmpty, "A shutter cue is not a verified save.")
        let raster = try pixels(snapshot(window, name: "sequence-stop-progress"))
        var red = 0
        for y in 0..<raster.height { for x in 0..<raster.width {
            let i = y * raster.stride + x * 4
            if raster.bytes[i] > 180 && raster.bytes[i+1] < 130 && raster.bytes[i+2] < 130 { red += 1 }
        } }
        XCTAssertGreaterThan(red, 300, "The shipping shutter displays a visible Stop square during the run.")
        camera.cancelSequence(); await sequence.executor.release()
        _ = await driveVirtualClock(sequence.clock) { await !camera.isSequenceRunning }
        await camera.handleCameraScreenCovered()
    }

    @MainActor func testCameraFitsCompactRegularLargeAndLandscapePhoneFrames() async throws {
        let fixture = await StorageHarness.make(name: "responsive-phone-matrix")
        let storage = try XCTUnwrap(fixture)
        let camera = CameraViewModel(camera: SyntheticCameraService(capability: StartupRepairSuite.controlFixture(modes: [.auto,.manual])),
            capture: CaptureCoordinator(camera: ChainCameraSpy(), store: storage.store, clock: SystemMonotonicClock()),
            metering: MeteringService(clock: SystemMonotonicClock()), preferences: SyntheticPreferenceStore(), levelFeed: SyntheticLevelFeed())
        let app = AppEnvironment()
        app.attach(store: storage.store, index: SQLiteIndex(databaseURL: FileManager.default.temporaryDirectory.appendingPathComponent("responsive-\(UUID().uuidString).sqlite")))
        app.attach(camera: camera); app.graphState = .ready
        await camera.start()
        let window = try await makeWindow(CameraScreen().environment(app).preferredColorScheme(.dark))
        defer { window.isHidden = true }
        for size in [CGSize(width:320,height:568), CGSize(width:375,height:667), CGSize(width:390,height:844),
                     CGSize(width:402,height:874), CGSize(width:440,height:956), CGSize(width:568,height:320),
                     CGSize(width:844,height:390), CGSize(width:956,height:440)] {
            window.frame = CGRect(origin: .zero, size: size)
            camera.openPanel = .whiteBalance
            window.layoutIfNeeded(); try await Task.sleep(for: .milliseconds(100))
            let image = try snapshot(window, name: "responsive-\(Int(size.width))-\(Int(size.height))")
            let frame = try XCTUnwrap(visibleShutterFrame(image), "Rendered shutter stays visible at \(size)")
            XCTAssertGreaterThan(frame.minY, 0)
            XCTAssertLessThan(frame.maxY, size.height - 8, "Shutter remains inside the phone at \(size)")
        }
        await camera.stop()
    }

    @MainActor func testCameraControlsDoNotMoveShutter() async throws {
        let fixture = await StorageHarness.make(name: "native-visual-camera")
        let h = try XCTUnwrap(fixture)
        let service = SyntheticCameraService(capability: StartupRepairSuite.controlFixture(modes: [.auto, .manual]))
        let camera = CameraViewModel(camera: service,
            capture: CaptureCoordinator(camera: ChainCameraSpy(), store: h.store, clock: SystemMonotonicClock()),
            metering: MeteringService(clock: SystemMonotonicClock()), preferences: SyntheticPreferenceStore(), levelFeed: SyntheticLevelFeed())
        let app = AppEnvironment()
        let indexURL = FileManager.default.temporaryDirectory.appendingPathComponent("redesign-ui-\(UUID().uuidString).sqlite")
        app.attach(store: h.store, index: SQLiteIndex(databaseURL: indexURL))
        app.attach(camera: camera)
        app.graphState = .ready
        await camera.start()
        let window = try await makeWindow(CameraScreen().environment(app).preferredColorScheme(.dark))
        defer { window.isHidden = true }
        try await Task.sleep(for: .milliseconds(500))
        let initial = try shutterY(snapshot(window, name: "camera-rest"))
        camera.openPanel = .iso
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(try shutterY(snapshot(window, name: "camera-iso")), initial)
        camera.openPanel = .whiteBalance
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(try shutterY(snapshot(window, name: "camera-white-balance")), initial)
        camera.openPanel = nil
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(try shutterY(snapshot(window, name: "camera-controls-closed")), initial)
        await camera.stop()
    }

    @MainActor func testCameraPreviewSurvivesLandscapeLayoutAndBack() async throws {
        let fixture = await StorageHarness.make(name: "native-rotation-layout")
        let h = try XCTUnwrap(fixture)
        let service = SyntheticCameraService(capability: StartupRepairSuite.controlFixture(modes: [.auto, .manual]))
        // An empty native session exercises the real preview layer without opening
        // a simulator/physical camera or claiming sensor rotation validation.
        await service.installDisplaySession(AVCaptureSession())
        let camera = CameraViewModel(camera: service,
            capture: CaptureCoordinator(camera: ChainCameraSpy(), store: h.store, clock: SystemMonotonicClock()),
            metering: MeteringService(clock: SystemMonotonicClock()), preferences: SyntheticPreferenceStore(), levelFeed: SyntheticLevelFeed())
        let app = AppEnvironment(); app.attach(camera: camera); app.graphState = .ready
        await camera.start()
        let window = try await makeWindow(CameraScreen().environment(app).preferredColorScheme(.dark))
        defer { window.isHidden = true }
        func hosts(_ view: UIView) -> [PreviewHostView] {
            (view as? PreviewHostView).map { [$0] } ?? view.subviews.flatMap(hosts)
        }
        try await Task.sleep(for: .milliseconds(300))
        let first = try XCTUnwrap(hosts(window).first)
        XCTAssertEqual(hosts(window).count, 1)
        let rootView = try XCTUnwrap(window.rootViewController?.view)
        let safe = rootView.safeAreaInsets
        let available = CGSize(width: rootView.bounds.width - safe.left - safe.right,
            height: rootView.bounds.height - safe.top - safe.bottom)
        let layout = CameraScreenLayout(size: available, bottomSafeArea: safe.bottom, accessibility: false)
        XCTAssertEqual(first.bounds.width, layout.preview.width, accuracy: 1, "Preview fits above the opaque controls inside inherited safe areas.")
        XCTAssertGreaterThanOrEqual(first.bounds.width, available.width - 24, "Standard portrait retains nearly the full width.")
        let frame = first.convert(first.bounds, to: rootView)
        XCTAssertLessThanOrEqual(frame.maxY + 8, safe.top + layout.controls.minY + 1, "The complete frame clears the controls.")
        XCTAssertEqual(first.bounds.height / first.bounds.width, 4.0 / 3.0, accuracy: 0.01, "Enlarging the canvas preserves the uncropped 3:4 frame.")
        let fullPreview = first.bounds.size
        camera.openPanel = .whiteBalance
        try await Task.sleep(for: .milliseconds(250))
        XCTAssertEqual(first.bounds.size, fullPreview, "WB must not shrink the enlarged preview.")
        camera.openPanel = nil
        var callbackWasSynchronous = false
        var inLayout = true
        first.onGeometryChanged = { _ in if inLayout { callbackWasSynchronous = true } }
        first.imageDimensions = PixelDimensions(width: 1920, height: 1440)
        first.refreshGeometry()
        inLayout = false
        XCTAssertFalse(callbackWasSynchronous, "Geometry must not mutate observation during UIKit layout.")
        window.frame = CGRect(x: 0, y: 0, width: 874, height: 402)
        window.rootViewController?.view.setNeedsLayout()
        try await Task.sleep(for: .milliseconds(300))
        let landscape = try XCTUnwrap(hosts(window).first)
        XCTAssertTrue(first === landscape, "Rotation must not destroy/recreate the native preview layer.")
        XCTAssertGreaterThan(landscape.bounds.width, landscape.bounds.height)
        _ = try snapshot(window, name: "camera-landscape")
        camera.openPanel = .exposureBias
        try await Task.sleep(for: .milliseconds(150))
        let landscapePixels = try pixels(snapshot(window, name: "camera-landscape-EV"))
        let centerX = landscapePixels.width - 130
        var widestShutterRow = 0
        for y in max(0, landscapePixels.height - 140)..<(landscapePixels.height - 35) {
            var bright = 0
            for x in (centerX - 27)...(centerX + 27) {
                let offset = y * landscapePixels.stride + x * 4
                if landscapePixels.bytes[offset] > 60,
                   landscapePixels.bytes[offset + 1] > 60,
                   landscapePixels.bytes[offset + 2] > 60 { bright += 1 }
            }
            widestShutterRow = max(widestShutterRow, bright)
        }
        XCTAssertGreaterThanOrEqual(widestShutterRow, 50, "The capture circle must fit above the bottom safe area in compact landscape.")
        camera.openPanel = .whiteBalance
        try await Task.sleep(for: .milliseconds(150))
        let wbPixels = try pixels(snapshot(window, name: "camera-landscape-white-balance"))
        var rulerGroups = 0, wasYellow = false
        for y in 175..<(wbPixels.height - 132) {
            let offset = y * wbPixels.stride + (wbPixels.width - 131) * 4
            let yellow = wbPixels.bytes[offset] > 180 && wbPixels.bytes[offset + 1] > 130 && wbPixels.bytes[offset + 2] < 100
            if yellow && !wasYellow { rulerGroups += 1 }
            wasYellow = yellow
        }
        XCTAssertGreaterThanOrEqual(rulerGroups, 2, "Both temperature and tint rulers must fit above the fixed landscape shutter.")
        camera.openPanel = .exposureBias
        window.frame = CGRect(x: 0, y: 0, width: 402, height: 874)
        window.rootViewController?.view.setNeedsLayout()
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertTrue(first === hosts(window).first)
        XCTAssertEqual(camera.surface, .ready)
        _ = try snapshot(window, name: "camera-portrait-EV")
        await camera.stop()
    }

    @MainActor func testViewerFitsOrientedBitmapInsteadOfRawDimensions() async throws {
        let fixture = await StorageHarness.make(name: "native-visual-viewer")
        let h = try XCTUnwrap(fixture)
        let app = AppEnvironment()
        app.attachThumbnails(store: h.store, thumbnails: RedesignImagePort(width: 240, height: 320))
        let card = try XCTUnwrap(StorageFixture.cards(count: 1, libraryID: h.libraryID, startingAt: StorageFixture.fixedDate).first)
        // Card says landscape RAW dimensions, decoded bitmap is portrait. The
        // SHIPPING viewer must fit the latter, not squeeze it into a RAW rectangle.
        let viewerModel = ThumbnailModel()
        viewerModel.loadViewer(card: card, source: app.libraryThumbnailSource)
        for _ in 0..<60 {
            if case .loaded = viewerModel.state { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        guard case .loaded = viewerModel.state else {
            XCTFail("The scoped synthetic image must materialize before layout review: \(viewerModel.state)")
            return
        }
        let window = try await makeWindow(NavigationStack {
            SourceDetailView(card: card, orderedSources: [card], viewerModel: viewerModel).environment(app)
        })
        defer { window.isHidden = true }
        try await Task.sleep(for: .milliseconds(600))
        let p = try pixels(snapshot(window, name: "viewer-portrait-fit"))
        var left = p.width, right = -1, top = p.height, bottom = -1
        for y in 0..<p.height {
            for x in 0..<p.width {
                let offset = y * p.stride + x * 4
                let a = Int(p.bytes[offset]), green = Int(p.bytes[offset + 1]), b = Int(p.bytes[offset + 2])
                if green > a + 30, green > b + 10 {
                    left = min(left, x); right = max(right, x); top = min(top, y); bottom = max(bottom, y)
                }
            }
        }
        let width = right - left + 1, height = bottom - top + 1
        XCTAssertGreaterThan(width, Int(Double(p.width) * 0.9), "Portrait preview fills the viewer width.")
        XCTAssertEqual(Double(height) / Double(max(width, 1)), 4.0 / 3.0, accuracy: 0.03)
        XCTAssertEqual(Double(top + bottom) / 2, Double(p.height) / 2, accuracy: 2)
    }

    @MainActor func testViewerDownwardDismissalPreservesZoomAndPaging() async throws {
        let fixture = await StorageHarness.make(name: "native-viewer-dismiss")
        let h = try XCTUnwrap(fixture)
        let app = AppEnvironment()
        app.attachThumbnails(store: h.store, thumbnails: RedesignImagePort(width: 240, height: 320))
        let card = try XCTUnwrap(StorageFixture.cards(count: 1, libraryID: h.libraryID,
                                                     startingAt: StorageFixture.fixedDate).first)
        let model = ThumbnailModel()
        model.loadViewer(card: card, source: app.libraryThumbnailSource)
        for _ in 0..<60 {
            if case .loaded = model.state { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        var presented = true
        let window = try await makeWindow(Text("Gallery fixture").fullScreenCover(isPresented:
            Binding(get: { presented }, set: { presented = $0 })) {
                SourceDetailView(card: card, orderedSources: [card], viewerModel: model).environment(app)
            })
        defer { window.isHidden = true }
        func findScroll(_ view: UIView) -> OriginalScrollView? {
            if let scroll = view as? OriginalScrollView { return scroll }
            return view.subviews.compactMap { findScroll($0) }.first
        }
        var found: OriginalScrollView?
        for _ in 0..<60 {
            found = findScroll(window)
            if found != nil { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        let scroll = try XCTUnwrap(found)
        let coordinator = try XCTUnwrap(scroll.delegate as? ZoomableOriginalView.Coordinator)
        XCTAssertTrue(scroll.isAtFitSize)
        let down = try XCTUnwrap(scroll.gestureRecognizers?.compactMap { $0 as? UIPanGestureRecognizer }
            .first { $0 !== scroll.panGestureRecognizer })
        XCTAssertEqual(down.maximumNumberOfTouches, 1)
        XCTAssertTrue(down.delegate === coordinator)
        XCTAssertEqual(scroll.gestureRecognizers?.compactMap { $0 as? UISwipeGestureRecognizer }.count, 0,
                       "The viewer uses one continuous horizontal pan instead of hard swipe recognizers.")
        let pager = try XCTUnwrap(scroll.superview?.superview as? OriginalPagerView)
        XCTAssertEqual(pager.horizontalPan.maximumNumberOfTouches, 1)
        let pan = ViewerTestPan()
        scroll.addGestureRecognizer(pan)
        pan.testVelocity = CGPoint(x: 10, y: 500)
        XCTAssertTrue(coordinator.gestureRecognizerShouldBegin(pan))
        pan.testVelocity = CGPoint(x: 500, y: 100)
        XCTAssertFalse(coordinator.gestureRecognizerShouldBegin(pan), "Horizontal paging must not start dismissal.")
        pan.testVelocity = CGPoint(x: 0, y: -500)
        XCTAssertFalse(coordinator.gestureRecognizerShouldBegin(pan), "Upward drags do not exit.")

        scroll.setZoomScale(scroll.minimumZoomScale * 2, animated: false)
        pan.testVelocity = CGPoint(x: 0, y: 500)
        XCTAssertFalse(coordinator.gestureRecognizerShouldBegin(pan), "Zoomed dragging must pan, not dismiss.")
        XCTAssertFalse(pager.mayBegin(velocity: CGPoint(x: 500, y: 0)), "Zoomed panning must not page either.")
        scroll.setZoomScale(scroll.minimumZoomScale, animated: false)
        coordinator.parent.dismissalEnabled = false
        XCTAssertFalse(coordinator.gestureRecognizerShouldBegin(pan))
        coordinator.parent.dismissalEnabled = true

        coordinator.updateDismissal(state: .changed, translation: CGPoint(x: 0, y: 50), velocity: .zero, scroll: scroll)
        XCTAssertGreaterThan(scroll.transform.ty, 0, "The photo follows the finger before dismissal.")
        coordinator.updateDismissal(state: .ended, translation: CGPoint(x: 0, y: 50), velocity: .zero, scroll: scroll)
        try await Task.sleep(for: .milliseconds(350))
        XCTAssertTrue(presented, "Short drags spring back.")
        XCTAssertEqual(scroll.transform, .identity)
        coordinator.updateDismissal(state: .changed, translation: CGPoint(x: 0, y: 180), velocity: .zero, scroll: scroll)
        coordinator.updateDismissal(state: .cancelled, translation: CGPoint(x: 0, y: 180), velocity: .zero, scroll: scroll)
        try await Task.sleep(for: .milliseconds(350))
        XCTAssertTrue(presented, "Cancelled gestures do not exit, even beyond the threshold.")
        XCTAssertEqual(scroll.transform, .identity)
        coordinator.parent.dismissalEnabled = false
        coordinator.updateDismissal(state: .ended, translation: CGPoint(x: 0, y: 240),
                                    velocity: CGPoint(x: 0, y: 1200), scroll: scroll)
        XCTAssertTrue(presented, "A mutation that disables dismissal during the gesture must win at release.")
        coordinator.parent.dismissalEnabled = true
        // Exercise the distance path separately without closing the cover yet.
        let actualDismissal = coordinator.parent.dismissViewer
        var distanceDismissals = 0
        coordinator.parent.dismissViewer = { distanceDismissals += 1 }
        coordinator.updateDismissal(state: .ended, translation: CGPoint(x: 0, y: 240), velocity: .zero, scroll: scroll)
        XCTAssertEqual(distanceDismissals, 1)
        coordinator.parent.dismissViewer = actualDismissal
        // A completed flick uses the real SourceDetailView environment dismissal
        // to close its actual fullScreenCover, rather than a test-only callback.
        coordinator.updateDismissal(state: .ended, translation: CGPoint(x: 0, y: 60),
                                    velocity: CGPoint(x: 0, y: 1200), scroll: scroll)
        for _ in 0..<30 {
            if !presented { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTAssertFalse(presented, "Swipe down must return to the underlying gallery presentation.")
    }

    @MainActor func testViewerHoldsPhotoAndRejectsSupersededPageDecode() async throws {
        let fixture = await StorageHarness.make(name: "native-viewer-page-polish")
        let h = try XCTUnwrap(fixture)
        let cards = StorageFixture.cards(count: 3, libraryID: h.libraryID, startingAt: StorageFixture.fixedDate)
        let images = HeldViewerImagePort(firstID: cards[0].captureID.description, heldID: cards[1].captureID.description,
            sourceIDsByFileName: Dictionary(uniqueKeysWithValues: cards.map {
                (URL(fileURLWithPath: $0.relativeOriginalPath).lastPathComponent, $0.captureID.description)
            }))
        defer { images.release() }
        let app = AppEnvironment()
        app.attachThumbnails(store: h.store, thumbnails: images)
        let model = ThumbnailModel()
        await model.loadViewerAndWait(card: cards[0], source: app.libraryThumbnailSource,
            sourceRevision: app.libraryThumbnailRevision, rootState: app.libraryRootState)
        var presented = true
        var steps: [CaptureID] = []
        let window = try await makeWindow(Text("Gallery fixture").fullScreenCover(isPresented:
            Binding(get: { presented }, set: { presented = $0 })) {
                SourceDetailView(card: cards[0], orderedSources: cards,
                    onStep: { steps.append($0.captureID) }, viewerModel: model).environment(app)
            })
        defer { window.isHidden = true }
        func findScroll(_ view: UIView) -> OriginalScrollView? {
            if let scroll = view as? OriginalScrollView { return scroll }
            return view.subviews.compactMap { findScroll($0) }.first
        }
        func backButtonCenter(_ image: UIImage) throws -> Double {
            let p = try pixels(image)
            var sum = 0, count = 0
            // White Back glyph in this fixture's top safe-area row. Coloured
            // photos begin below it, and the grey page counter is excluded.
            for y in 65..<105 {
                for x in 0..<60 {
                    let offset = y * p.stride + x * 4
                    if p.bytes[offset] > 200, p.bytes[offset + 1] > 200, p.bytes[offset + 2] > 200 {
                        sum += x; count += 1
                    }
                }
            }
            XCTAssertGreaterThan(count, 5, "The complete Back glyph must remain visible during paging.")
            return Double(sum) / Double(max(1, count))
        }
        var found: OriginalScrollView?
        for _ in 0..<60 {
            found = findScroll(window)
            if found != nil { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        // Let the cover finish presenting before measuring page-only motion.
        try await Task.sleep(for: .milliseconds(450))
        let firstScroll = try XCTUnwrap(found)
        let initialRaster = try snapshot(window, name: "viewer-before-paging")
        let initialBackX = try backButtonCenter(initialRaster)
        let exportPixels = try pixels(initialRaster)
        var exportXSum = 0, exportPixelCount = 0
        for y in (exportPixels.height - 100)..<(exportPixels.height - 20) {
            for x in (exportPixels.width / 2 - 30)..<(exportPixels.width / 2 + 30) {
                let offset = y * exportPixels.stride + x * 4
                if exportPixels.bytes[offset] > 200, exportPixels.bytes[offset+1] > 200, exportPixels.bytes[offset+2] > 200 {
                    exportXSum += x; exportPixelCount += 1
                }
            }
        }
        XCTAssertGreaterThan(exportPixelCount, 10, "Export glyph must be visible.")
        XCTAssertEqual(Double(exportXSum) / Double(max(1,exportPixelCount)), Double(exportPixels.width) / 2, accuracy: 2.5,
                       "Share is centered independently of the asymmetric Trash/Next group.")
        let firstBitmap = try XCTUnwrap(firstScroll.imageView.image?.cgImage)
        let presenter = window.rootViewController?.presentedViewController
        let coordinator = try XCTUnwrap(firstScroll.delegate as? ZoomableOriginalView.Coordinator)
        coordinator.parent.next()
        for _ in 0..<100 {
            if images.didEnter { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(images.didEnter, "The next source decode must really be held.")
        XCTAssertTrue(findScroll(window) === firstScroll, "Keep the current canvas while decoding instead of replacing it with a spinner.")
        XCTAssertTrue(findScroll(window)?.imageView.image?.cgImage === firstBitmap)
        XCTAssertTrue(steps.isEmpty)
        coordinator.parent.next() // Advance relative to the requested second source.
        coordinator.parent.previous()
        coordinator.parent.next() // Repeated input must coalesce, not queue extra decodes.
        images.release()
        for _ in 0..<100 {
            if !steps.isEmpty { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertEqual(steps, [cards[2].captureID], "The late second-source decode must not override the newer third-source request.")
        XCTAssertEqual(images.readIDs, cards.map { $0.captureID.description },
                       "A held decode and the final target suffice; do not queue a RAW decode for every rapid gesture.")
        try await Task.sleep(for: .milliseconds(400))
        XCTAssertTrue(findScroll(window) === firstScroll, "Continuous paging retains one zoom canvas rather than recreating the view.")
        XCTAssertEqual(try backButtonCenter(snapshot(window, name: "viewer-page-forward-settled")), initialBackX, accuracy: 1)
        XCTAssertTrue(presented)
        XCTAssertTrue(window.rootViewController?.presentedViewController === presenter, "Paging must preserve the same full-screen presentation.")
        let finalScroll = try XCTUnwrap(findScroll(window))
        let displayed = try XCTUnwrap(finalScroll.imageView.image?.cgImage)
        let bitmap = try pixels(UIImage(cgImage: displayed))
        XCTAssertGreaterThan(Int(bitmap.bytes[2]), Int(bitmap.bytes[0]) + 100,
                             "The canvas must actually show the blue third source, not just call its navigation callback.")
        _ = try snapshot(window, name: "viewer-page-after-held-decode")
        let finalCoordinator = try XCTUnwrap(finalScroll.delegate as? ZoomableOriginalView.Coordinator)
        finalCoordinator.parent.previous()
        for _ in 0..<100 {
            if steps.count == 2 { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(steps.last, cards[1].captureID)
        try await Task.sleep(for: .milliseconds(400))
        XCTAssertTrue(findScroll(window) === firstScroll)
        XCTAssertEqual(try backButtonCenter(snapshot(window, name: "viewer-page-backward-settled")), initialBackX, accuracy: 1)
        XCTAssertTrue(window.rootViewController?.presentedViewController === presenter)
    }
    @MainActor func testEmptyViewerKeepsGlassBackAndDownwardDismissalAwayFromHomeIndicator() async throws {
        var exits=0
        let window=try await makeWindow(EmptyPhotoViewer(isDismissalEnabled:true,onDismiss:{exits += 1}))
        defer { window.isHidden=true }
        try await Task.sleep(for:.milliseconds(200))
        func find(_ controller:UIViewController) -> EmptyPhotoViewerController? {
            if let empty=controller as? EmptyPhotoViewerController { return empty }
            return controller.children.compactMap { find($0) }.first
        }
        let controller=try XCTUnwrap(find(try XCTUnwrap(window.rootViewController)))
        let swipe=try XCTUnwrap(controller.view.gestureRecognizers?.compactMap { $0 as? UISwipeGestureRecognizer }.first)
        XCTAssertEqual(swipe.direction,.down);XCTAssertEqual(swipe.numberOfTouchesRequired,1)
        let raster=try pixels(snapshot(window,name:"empty-viewer-glass-back"))
        var whiteInMiddle=0,whiteNearHome=0
        for y in raster.height/2..<(raster.height-20) { for x in raster.width/4..<(raster.width*3/4) {
            let i=y*raster.stride+x*4
            if raster.bytes[i]>180 && raster.bytes[i+1]>180 && raster.bytes[i+2]>180 {
                if y < raster.height*3/4 { whiteInMiddle += 1 } else { whiteNearHome += 1 }
            }
        } }
        XCTAssertGreaterThan(whiteInMiddle,40,"Back label sits near the center below the empty message.")
        XCTAssertEqual(whiteNearHome,0,"Back must not sit against the home indicator.")
        controller.isDismissalEnabled=false;controller.refreshContent();controller.dismissDownward()
        XCTAssertEqual(exits,0,"Photo mutation eligibility is checked again on dismissal.")
        controller.isDismissalEnabled=true;controller.refreshContent();controller.dismissDownward()
        XCTAssertEqual(exits,1,"The registered downward route exits the empty viewer.")
    }

    @MainActor func testRGBHistogramAndShutterFeedbackRender() async throws {
        var red=[UInt32](repeating:0,count:256),green=red,blue=red
        for i in 20..<95 { red[i]=UInt32(min(i-19,95-i)) }
        for i in 80..<155 { green[i]=UInt32(min(i-79,155-i)) }
        for i in 150..<225 { blue[i]=UInt32(min(i-149,225-i)) }
        var histogram=HistogramSnapshot.empty(configurationGeneration:.zero)
        histogram.rgb=PreviewRGBHistogram(red:red,green:green,blue:blue,sampleCount:1406,matrix:"BT.709 fixture")
        let window=try await makeWindow(HistogramOverlay(snapshot:histogram).frame(width:300,height:120).background(.black).preferredColorScheme(.dark))
        defer { window.isHidden=true }
        try await Task.sleep(for:.milliseconds(150))
        let raster=try pixels(snapshot(window,name:"preview-RGB-histogram"))
        var colored=0
        for y in 0..<raster.height { for x in 0..<raster.width {
            let i=y*raster.stride+x*4
            let c=[raster.bytes[i],raster.bytes[i+1],raster.bytes[i+2]]
            if Int(c.max() ?? 0)-Int(c.min() ?? 0)>80 { colored += 1 }
        } }
        XCTAssertGreaterThan(colored,200,"Native Canvas must paint actual distinct RGB channels.")
        window.rootViewController=UIHostingController(rootView:ShutterFlashOverlay(pulse:1,holdDuration:.seconds(1)).background(.black))
        try await Task.sleep(for:.milliseconds(150))
        let flash=try pixels(snapshot(window,name:"shutter-flash-visible"))
        let middle=flash.height/2*flash.stride+flash.width/2*4
        XCTAssertGreaterThan(flash.bytes[middle],3,"Admitted-shot feedback remains visible.")
        XCTAssertLessThan(flash.bytes[middle],95,"Shutter response must remain subtle, not the old bright flash.")
        try await Task.sleep(for:.milliseconds(1300))
        let ended=try pixels(snapshot(window,name:"shutter-flash-cleared"))
        XCTAssertLessThan(ended.bytes[middle],30,"Flash clears without waiting for save completion.")
    }

    @MainActor func testDeletionKeepsBottomActionsFixedWhileProviderIsHeldAndStopFinishesOnlyCurrentPhoto() async throws {
        let coordinator = GatedFileCoordinatorMutator()
        let fixture = await StorageHarness.make(name: "native-delete-progress", coordinator: coordinator)
        let h = try XCTUnwrap(fixture)
        var records: [PhotoTrashRecord] = []
        for _ in 0..<3 { records.append(try await StartupRepairSuite.trashFixture(h)) }
        let index = InMemoryLibraryIndex(), app = AppEnvironment()
        app.attach(store: h.store, index: index)
        app.attach(librarySession: LibrarySessionCoordinator(store: h.store, index: index))
        app.attachThumbnails(store: h.store, thumbnails: RedesignImagePort(width: 120, height: 160))
        let window = try await makeWindow(NavigationStack { PhotoTrashView() }.environment(app).preferredColorScheme(.dark))
        defer { window.isHidden = true; coordinator.release() }
        try await Task.sleep(for: .milliseconds(150))
        func anchors(_ view: UIView) -> [GalleryTrashAnchorView] {
            ((view as? GalleryTrashAnchorView).map { [$0] } ?? []) + view.subviews.flatMap(anchors)
        }
        func footerFrames() -> [CGRect] {
            anchors(window).map { $0.convert($0.bounds, to: window) }.sorted { $0.minX < $1.minX }
        }
        let fixedFrames = footerFrames()
        XCTAssertEqual(fixedFrames.count, 2, "Recover and Delete keep their own bottom targets")
        let start = coordinator.enteredCount
        coordinator.arm()
        var verified: [UUID] = []
        let task = Task { await app.performTrashAction(records, permanently: true, generation: h.generation) { id in
            verified.append(id)
            if verified.count == 1 { coordinator.arm() }
        } }
        let firstHeld = await LibraryPerformanceSuite.waitUntil { coordinator.enteredCount == start + 1 }
        XCTAssertTrue(firstHeld)
        XCTAssertTrue(app.photoMutationInProgress)
        XCTAssertEqual(app.visiblePhotoMutationProgress?.completed, 0, "No completed claim before native removal.")
        XCTAssertEqual(app.visiblePhotoMutationProgress?.total, 3)
        let owner = try XCTUnwrap(app.visiblePhotoMutationProgress?.id)
        try await Task.sleep(for: .milliseconds(80))
        XCTAssertEqual(footerFrames(), fixedFrames, "Starting work cannot insert a progress footer or replace the actions")
        app.stopPhotoMutation(UUID())
        XCTAssertEqual(app.photoMutationProgress?.stopRequested, false, "A stale Stop cannot affect this batch.")
        let duplicate = await app.performTrashAction(records, permanently: true, generation: h.generation)
        XCTAssertTrue(duplicate.completed.isEmpty); XCTAssertNotNil(duplicate.failure)
        XCTAssertEqual(app.photoMutationProgress?.id, owner)
        _ = try snapshot(window, name: "deletion-progress-before-first-completion")
        coordinator.release()
        let secondHeld = await LibraryPerformanceSuite.waitUntil { coordinator.enteredCount == start + 2 }
        XCTAssertTrue(secondHeld)
        XCTAssertEqual(verified, [records[0].id])
        XCTAssertEqual(app.visiblePhotoMutationProgress?.completed, 1)
        XCTAssertEqual(app.photoMutationProgress?.completedIDs, [records[0].id])
        try await Task.sleep(for: .milliseconds(80))
        XCTAssertEqual(footerFrames(), fixedFrames, "Verified per-file updates cannot move the bottom controls")
        _ = try snapshot(window, name: "deletion-fixed-controls-one-of-three")
        // A recreated surface reads the same retained operation immediately.
        let progressWindow = try await makeWindow(NavigationStack { PhotoTrashView() }.environment(app).preferredColorScheme(.dark))
        _ = try snapshot(progressWindow, name: "deletion-progress-retained-on-return")
        app.stopPhotoMutation(owner)
        XCTAssertEqual(app.photoMutationProgress?.stopRequested, true)
        coordinator.release()
        let result = await task.value
        XCTAssertEqual(result.completed, [records[0].id, records[1].id], "Stop finishes the in-flight file, then leaves the next untouched.")
        XCTAssertNotNil(result.failure)
        let remaining = try await h.store.trashedOriginals()
        XCTAssertEqual(remaining.map(\.id), [records[2].id])
        XCTAssertNil(app.photoMutationProgress); XCTAssertFalse(app.photoMutationInProgress)
        try await Task.sleep(for: .milliseconds(100))
        _ = try snapshot(progressWindow, name: "deletion-progress-returned-after-safe-stop")
        progressWindow.isHidden = true
        XCTAssertNotEqual(coordinator.holdOutcome, .timedOut)
    }

    @MainActor func testDeletionFailureKeepsUnverifiedPhotoVisibleAndReportsExactProgress() async throws {
        let fixture = await StorageHarness.make(name: "native-delete-progress-failure")
        let h = try XCTUnwrap(fixture)
        let records = [try await StartupRepairSuite.trashFixture(h), try await StartupRepairSuite.trashFixture(h)]
        let app = AppEnvironment(); app.attach(store: h.store, index: InMemoryLibraryIndex())
        var verified: [UUID] = [], counts: [Int] = []
        h.fault.arm(.removeIgnored)
        let failed = await app.performTrashAction(records, permanently: true, generation: h.generation) { id in
            verified.append(id); counts.append(app.photoMutationProgress?.completed ?? -1)
        }
        XCTAssertTrue(failed.completed.isEmpty); XCTAssertNotNil(failed.failure); XCTAssertTrue(verified.isEmpty)
        let kept = try await h.store.trashedOriginals()
        XCTAssertEqual(kept.count, 2)
        XCTAssertNil(app.photoMutationProgress); XCTAssertFalse(app.photoMutationInProgress)
        let retried = await app.performTrashAction(records + [records[0]], permanently: true, generation: h.generation) { id in
            verified.append(id); counts.append(app.photoMutationProgress?.completed ?? -1)
        }
        XCTAssertEqual(retried.completed.count, 2); XCTAssertNil(retried.failure)
        XCTAssertEqual(counts, [1, 2], "Only verified, distinct completions reach live UI progress.")
        XCTAssertEqual(Set(verified), Set(records.map(\.id)))
        XCTAssertNil(app.photoMutationProgress)
    }

    @MainActor func testRecentlyDeletedGridAndConfirmedBatchPermanentRemoval() async throws {
        let fixture = await StorageHarness.make(name: "recently-deleted-grid")
        let h = try XCTUnwrap(fixture)
        var records: [PhotoTrashRecord] = []
        for _ in 0..<3 { records.append(try await StartupRepairSuite.trashFixture(h)) }
        let index = InMemoryLibraryIndex(), app = AppEnvironment()
        app.attach(store: h.store, index: index)
        app.attach(librarySession: LibrarySessionCoordinator(store: h.store, index: index))
        app.attachThumbnails(store: h.store, thumbnails: RedesignImagePort(width: 120, height: 160))
        let window = try await makeWindow(NavigationStack { PhotoTrashView(selecting: true) }.environment(app).preferredColorScheme(.dark))
        defer { window.isHidden = true }
        try await Task.sleep(for: .milliseconds(250))
        _ = try snapshot(window, name: "recently-deleted-grid")
        func descendants(_ view: UIView) -> [UIView] { [view] + view.subviews.flatMap(descendants) }
        let views = descendants(window)
        let sweep = try XCTUnwrap(views.compactMap { $0 as? GallerySelectionGestureView }.first)
        XCTAssertTrue(sweep.selectionPan.isEnabled)
        sweep.begin(at: CGPoint(x: sweep.bounds.width / 6, y: sweep.bounds.width / 6))
        XCTAssertNotNil(sweep.sweep)
        sweep.finish(cancelled: false)
        try await Task.sleep(for: .milliseconds(60))
        _ = try snapshot(window, name: "recently-deleted-selected-gray")
        let stale = await app.performTrashAction(records, permanently: true, generation: .next(h.generation))
        XCTAssertTrue(stale.completed.isEmpty); XCTAssertNotNil(stale.failure)
        let restored = await app.performTrashAction([records[0]], permanently: false, generation: h.generation)
        XCTAssertEqual(restored.completed.count, 1); XCTAssertNil(restored.failure)
        let deleted = await app.performTrashAction(Array(records.dropFirst()), permanently: true, generation: h.generation)
        XCTAssertEqual(deleted.completed.count, 2); XCTAssertNil(deleted.failure)
        let remainingTrash = try await h.store.trashedOriginals()
        XCTAssertTrue(remainingTrash.isEmpty)
        let remaining = try await h.store.allReconciledSourceCards().filter { $0.availability == .local }
        XCTAssertEqual(remaining.map(\.captureID), [records[0].captureID])
        XCTAssertFalse(app.photoMutationInProgress)
    }

    @MainActor func testGlassViewerInspectorAndIndividualSelectionRender() async throws {
        let fixture = await StorageHarness.make(name: "native-selection-render")
        let h = try XCTUnwrap(fixture)
        for _ in 0..<3 {
            let id = CaptureID()
            let handle = try await h.store.stageSource(bytes: StorageFixture.rawBytes(), metadata: StorageFixture.metadata(captureID: id, libraryID: h.libraryID))
            _ = try await h.store.commit(handle: handle)
        }
        let cards = try await h.store.allReconciledSourceCards()
        let index = InMemoryLibraryIndex()
        try await index.reset(libraryID: h.libraryID, generation: h.generation)
        try await index.upsert(scanned: cards)
        let app = AppEnvironment(); app.attach(store: h.store, index: index)
        app.attachThumbnails(store: h.store, thumbnails: RedesignImagePort(width: 120, height: 160))
        await app.library?.loadFirstPage()
        let window = try await makeWindow(LibraryScreen(selecting: true).environment(app).preferredColorScheme(.dark))
        defer { window.isHidden = true }
        try await Task.sleep(for: .milliseconds(450))
        _ = try snapshot(window, name: "gallery-select-individual-originals")
        func descendants(_ view: UIView) -> [UIView] { [view] + view.subviews.flatMap(descendants) }
        let controls = descendants(window)
        let sweep = try XCTUnwrap(controls.compactMap { $0 as? GallerySelectionGestureView }.first)
        XCTAssertNotNil(sweep.scrollView, "The real SwiftUI selection grid must attach to its native scroller")
        XCTAssertTrue(sweep.selectionPan.isEnabled)
        XCTAssertTrue(sweep.scrollView?.gestureRecognizers?.contains(sweep.selectionPan) == true)
        sweep.begin(at: CGPoint(x: sweep.bounds.width / 6, y: sweep.bounds.width / 6))
        XCTAssertNotNil(sweep.sweep, "Actual SwiftUI tile frames must use the native gesture coordinate space")
        sweep.finish(cancelled: true)
        let trashAnchor = try XCTUnwrap(controls.compactMap { $0 as? GalleryTrashAnchorView }.first)
        XCTAssertEqual(trashAnchor.bounds.width, 44, accuracy: 1)
        XCTAssertEqual(trashAnchor.bounds.height, 44, accuracy: 1)
        let details = PhotoMetadataDetails.parse([kCGImagePropertyExifDictionary as String:
            ["ExposureTime": 1.0 / 60, "ISOSpeedRatings": [320], "FNumber": 1.6, "FocalLength": 5.96,
             "WhiteBalance": 0, "ExposureMode": 0, "ExposureBiasValue": 0],
            kCGImagePropertyTIFFDictionary as String: ["Make": "Apple", "Model": "iPhone 17"],
            kCGImagePropertyDNGDictionary as String: ["DNGVersion": [1, 4, 0, 0], "BitsPerSample": 12]])
        window.rootViewController = UIHostingController(rootView: ScrollView {
            MetadataInspector(card: cards[0], details: details).padding()
        }.preferredColorScheme(.dark))
        try await Task.sleep(for: .milliseconds(250))
        _ = try snapshot(window, name: "viewer-detailed-file-metadata")
    }

}

private final class ViewerTestPan: UIPanGestureRecognizer {
    var testVelocity = CGPoint.zero
    override func velocity(in view: UIView?) -> CGPoint { testVelocity }
}
#endif

#if canImport(UIKit) && canImport(XCTest)
@preconcurrency import AVFoundation
#if canImport(UIKit)
import AVKit
#endif
/// Runtime selector proof is essential for an optional Objective-C callback:
/// a nearly-matching Swift method can compile without implementing the policy.
final class RawRepresentationPolicyTests: XCTestCase {
    func testNativeRGBReadsColorAttachmentAndRejectsUnknownMatrix() throws {
        var output: CVPixelBuffer?
        XCTAssertEqual(CVPixelBufferCreate(kCFAllocatorDefault,4,2,kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,nil,&output),kCVReturnSuccess)
        let buffer=try XCTUnwrap(output)
        XCTAssertEqual(CVPixelBufferLockBaseAddress(buffer,[]),kCVReturnSuccess)
        defer { CVPixelBufferUnlockBaseAddress(buffer,[]) }
        let y=try XCTUnwrap(CVPixelBufferGetBaseAddressOfPlane(buffer,0)).assumingMemoryBound(to:UInt8.self)
        let uv=try XCTUnwrap(CVPixelBufferGetBaseAddressOfPlane(buffer,1)).assumingMemoryBound(to:UInt8.self)
        for row in 0..<2 { for col in 0..<4 { y[row*CVPixelBufferGetBytesPerRowOfPlane(buffer,0)+col]=81 } }
        for col in 0..<2 { uv[col*2]=90;uv[col*2+1]=240 }
        XCTAssertNil(AnalysisSampleBufferHandler.rgbHistogram(pixelBuffer:buffer),"Do not guess the matrix.")
        CVBufferSetAttachment(buffer,kCVImageBufferYCbCrMatrixKey,kCVImageBufferYCbCrMatrix_ITU_R_601_4,.shouldPropagate)
        let rgb=try XCTUnwrap(AnalysisSampleBufferHandler.rgbHistogram(pixelBuffer:buffer))
        XCTAssertEqual(rgb.red[254],8);XCTAssertEqual(rgb.green[0],8);XCTAssertEqual(rgb.sampleCount,8)
        CVBufferSetAttachment(buffer,kCVImageBufferYCbCrMatrixKey,kCVImageBufferYCbCrMatrix_ITU_R_709_2,.shouldPropagate)
        XCTAssertNotEqual(AnalysisSampleBufferHandler.rgbHistogram(pixelBuffer:buffer)?.red,rgb.red,"Attachment selects real conversion coefficients.")
    }

    func testFrontDeviceIdentityIsPositionAware() {
        XCTAssertEqual(CameraCapabilityProbe.kind(for: .builtInWideAngleCamera, position: .front), .front)
        XCTAssertEqual(CameraCapabilityProbe.kind(for: .builtInTrueDepthCamera, position: .front), .front)
        XCTAssertEqual(CameraCapabilityProbe.kind(for: .builtInWideAngleCamera, position: .back), .wide)
    }

    func testThumbnailOnlyCustomizerImplementsNativeSelector() {
        let customizer = NoEmbeddedThumbnailCustomizer()
        XCTAssertTrue(customizer.responds(to: NSSelectorFromString("replacementEmbeddedThumbnailPixelBufferWithPhotoFormat:forPhoto:")))
        XCTAssertFalse(customizer.responds(to: NSSelectorFromString("replacementMetadataForPhoto:")))
        XCTAssertFalse(customizer.responds(to: NSSelectorFromString("replacementDepthDataForPhoto:")))
    }
}
#endif

#if canImport(UIKit) && canImport(XCTest)
import ImageIO

private actor PhotoLibraryRecordingPort: DNGPhotoLibraryWriting {
    let allowed: Bool
    let fail: Bool
    private(set) var authorizationCount = 0
    private(set) var files: [URL] = []
    private(set) var bytes: [Data] = []
    init(allowed: Bool = true, fail: Bool = false) { self.allowed = allowed; self.fail = fail }
    func requestAddAuthorization() async -> Bool { authorizationCount += 1; return allowed }
    func addOriginals(_ files: [URL]) async throws {
        self.files = files
        bytes = try files.map { try Data(contentsOf: $0) }
        if fail { throw CocoaError(.fileWriteOutOfSpace) }
    }
}

private actor HeldPhotosPort: DNGPhotoLibraryWriting {
    private(set) var entered = false
    private(set) var bytes: [Data] = []
    private var gate: CheckedContinuation<Void, Never>?
    private var released = false
    func requestAddAuthorization() async -> Bool { true }
    func addOriginals(_ files: [URL]) async throws {
        entered = true
        if !released { await withCheckedContinuation { gate = $0 } }
        bytes = try files.map { try Data(contentsOf: $0) }
    }
    func release() { released = true; gate?.resume(); gate = nil }
}

private final class HeldMetadataReader: @unchecked Sendable {
    private let condition = NSCondition()
    private var held = true
    private var entered = false
    let firstPath: String
    init(firstPath: String) { self.firstPath = firstPath }
    var didEnter: Bool { condition.lock(); defer { condition.unlock() }; return entered }
    func release() { condition.lock(); held = false; condition.broadcast(); condition.unlock() }
    func read(_ url: URL) -> PhotoMetadataDetails {
        if url.path.hasSuffix(firstPath) {
            condition.lock(); entered = true
            let end = Date().addingTimeInterval(3)
            while held, condition.wait(until: end) { }
            condition.unlock()
        }
        let isFirst = url.path.hasSuffix(firstPath)
        return PhotoMetadataDetails.parse([kCGImagePropertyExifDictionary as String:
            ["ISOSpeedRatings": [isFirst ? 100 : 800], "FocalLength": 5.96,
             "FocalLenIn35mmFilm": isFirst ? 13 : 120]])
    }
}

final class PhotoManagementTests: XCTestCase {
    @MainActor func testMetadataReadCannotReplaceANewerPhotoOrPublishAcrossRootRelease() async throws {
        let fixture = await StorageHarness.make(name: "native-detail-identity")
        let h = try XCTUnwrap(fixture)
        let cards = StorageFixture.cards(count: 2, libraryID: h.libraryID, startingAt: StorageFixture.fixedDate)
        for card in cards { h.memory.setBytes(StorageFixture.rawBytes(), at: h.root.appendingPathComponent(card.relativeOriginalPath)) }
        let reader = HeldMetadataReader(firstPath: cards[0].relativeOriginalPath)
        defer { reader.release() }
        let model = PhotoDetailModel(reader: { reader.read($0) })
        let first = Task { await model.load(card: cards[0], store: h.store) }
        for _ in 0..<100 { if reader.didEnter { break }; try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertTrue(reader.didEnter)
        let second = Task { await model.load(card: cards[1], store: h.store) }
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertEqual(model.captureID, cards[1].captureID)
        XCTAssertNil(model.details)
        reader.release()
        await first.value; await second.value
        XCTAssertEqual(model.details?.iso, "ISO 800", "The late old-photo read cannot publish ISO 100 over the new photo.")
        XCTAssertEqual(model.details?.equivalentFocalLength, "120 mm", "Late old-photo EXIF cannot replace the current photo's equivalent.")
        let held = HeldMetadataReader(firstPath: cards[0].relativeOriginalPath)
        defer { held.release() }
        let releasedModel = PhotoDetailModel(reader: { held.read($0) })
        let oldRoot = Task { await releasedModel.load(card: cards[0], store: h.store) }
        for _ in 0..<100 { if held.didEnter { break }; try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertTrue(held.didEnter)
        await h.store.releaseRoot()
        held.release(); await oldRoot.value
        XCTAssertNil(releasedModel.details, "A root transition invalidates the pending metadata publication.")
    }

    @MainActor func testBatchExportFreezesSelectionAndOptionsAndConfirmsActualAbsences() async throws {
        let fixture = await StorageHarness.make(name: "native-batch-export")
        let h = try XCTUnwrap(fixture)
        for _ in 0..<2 {
            let id = CaptureID()
            let handle = try await h.store.stageSource(bytes: StorageFixture.rawBytes(), metadata: StorageFixture.metadata(captureID: id, libraryID: h.libraryID))
            _ = try await h.store.commit(handle: handle)
        }
        let cards = try await h.store.allReconciledSourceCards()
        let app = AppEnvironment(); app.attach(store: h.store, index: InMemoryLibraryIndex())
        let presenter = ExportPresenter(store: h.store); app.exportPresenter = presenter
        app.setIncludeExportSidecars(true)
        defer { app.setIncludeExportSidecars(false) }
        app.exportSelectedOriginals(cards + [cards[0]])
        app.setIncludeExportSidecars(false)
        for _ in 0..<100 { if presenter.presented != nil { break }; try await Task.sleep(for: .milliseconds(5)) }
        let full = try XCTUnwrap(presenter.presented)
        XCTAssertTrue(full.session.includedSidecars, "Option belongs to the command, not its later scheduled task.")
        XCTAssertEqual(full.session.fileURLs.count, 4, "Deduplicate selected identities before export.")
        XCTAssertTrue(presenter.ownsPresentation(.library))
        await presenter.finished(sessionID: full.session.sessionID)
        try h.memory.removeItem(at: h.root.appendingPathComponent(cards[1].relativeOriginalPath))
        app.exportSelectedOriginals(cards)
        for _ in 0..<100 { if app.pendingPartialExport != nil { break }; try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertNil(presenter.presented, "An actually missing file must require consent before sharing the subset.")
        let pending = try XCTUnwrap(app.pendingPartialExport)
        XCTAssertFalse(pending.absentDescriptions.isEmpty)
        let prepared = try XCTUnwrap(pending.preparedSession)
        XCTAssertEqual(prepared.fileURLs.count, 1)
        app.confirmPendingPartialExport()
        for _ in 0..<100 { if presenter.presented != nil { break }; try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertEqual(presenter.presented?.session.sessionID, prepared.sessionID, "Consent presents the exact already-verified copies.")
        await presenter.finished(sessionID: prepared.sessionID)
        XCTAssertEqual(h.memory.fileBytes(at: h.root.appendingPathComponent(cards[0].relativeOriginalPath)), StorageFixture.rawBytes())
    }

    func testPhotosImportSurvivesShareSessionCopyRemovalUntilNativeCompletion() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("photos-lifetime-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("source.dng"), bytes = Data([1, 4, 9, 16])
        try bytes.write(to: source)
        let port = HeldPhotosPort()
        let operation = Task { try await DNGPhotosExporter(library: port).save([source]) }
        for _ in 0..<100 { if await port.entered { break }; try await Task.sleep(for: .milliseconds(5)) }
        let entered = await port.entered
        XCTAssertTrue(entered)
        try FileManager.default.removeItem(at: source) // Only a synthetic export fixture.
        await port.release()
        let count = try await operation.value, delivered = await port.bytes
        XCTAssertEqual(count, 1); XCTAssertEqual(delivered, [bytes])
    }
    @MainActor func testBatchTrashReportsPartialFailureAndLeavesRemainingSourcesUntouched() async throws {
        let fixture = await StorageHarness.make(name: "native-batch-partial")
        let h = try XCTUnwrap(fixture)
        for _ in 0..<3 {
            let id = CaptureID()
            let handle = try await h.store.stageSource(bytes: StorageFixture.rawBytes(), metadata: StorageFixture.metadata(captureID: id, libraryID: h.libraryID))
            _ = try await h.store.commit(handle: handle)
        }
        let cards = try await h.store.allReconciledSourceCards()
        XCTAssertEqual(cards.count, 3)
        let changedURL = h.root.appendingPathComponent(cards[1].relativeOriginalPath)
        let changed = Data("external change".utf8)
        h.memory.setBytes(changed, at: changedURL)
        let app = AppEnvironment(); app.attach(store: h.store, index: InMemoryLibraryIndex())
        let result = await app.trashOriginals(cards, generation: h.generation)
        XCTAssertEqual(result.completed, [cards[0].captureID])
        XCTAssertNotNil(result.failure)
        XCTAssertEqual(h.memory.fileBytes(at: changedURL), changed, "The changed original must be kept intact.")
        XCTAssertEqual(h.memory.fileBytes(at: h.root.appendingPathComponent(cards[2].relativeOriginalPath)), StorageFixture.rawBytes(),
                       "Stop after the failed verification instead of moving later sources.")
        let trashed = try await h.store.trashedOriginals()
        XCTAssertEqual(trashed.count, 1)
        XCTAssertFalse(app.photoMutationInProgress)
    }
    func testMetadataReportsNativeValuesAndDoesNotInventMissingSettings() throws {
        let properties: [String: Any] = [
            kCGImagePropertyTIFFDictionary as String: ["Make": "Apple", "Model": "iPhone 17"],
            kCGImagePropertyExifDictionary as String: ["ExposureTime": 1.0 / 60, "ISOSpeedRatings": [320],
                "FNumber": 1.6, "FocalLength": 5.96, "FocalLenIn35mmFilm": 26,
                "WhiteBalance": 0, "ExposureBiasValue": -1.0 / 3],
            kCGImagePropertyGPSDictionary as String: ["Latitude": 45.5, "LatitudeRef": "N"],
            "LongValue": String(repeating: "x", count: 2000)]
        let details = PhotoMetadataDetails.parse(properties)
        XCTAssertEqual(details.settings, ["1/60s", "ISO 320", "ƒ/1.6", "26 mm"])
        XCTAssertEqual(details.focalLength, "5.96 mm", "The actual focal length remains separate from the full-frame equivalent.")
        XCTAssertEqual(details.infoFields.first { $0.name == "FocalLength" }?.value, "26 mm equivalent (5.96 mm actual)")
        XCTAssertTrue(details.sections.contains { $0.name == "TIFF" && $0.fields.contains { $0.name == "Model" && $0.value == "iPhone 17" } })
        XCTAssertTrue(details.sections.contains { $0.name == "GPS" && $0.fields.contains { $0.name == "Latitude" && $0.value == "45.5" } })
        XCTAssertEqual(details.sections.last?.fields.first(where: { $0.name == "LongValue" })?.value.count, 512)
        XCTAssertEqual(details.infoFields.map(\.name), ["Make","Model","FocalLength","ExposureBiasValue","WhiteBalance"])
        XCTAssertFalse(details.infoFields.contains { ["Latitude","LongValue","DNGVersion","MakerNote"].contains($0.name) }, "Photo Info excludes raw/internal metadata dumps.")
        XCTAssertTrue(PhotoMetadataDetails.parse([:]).settings.isEmpty)
        XCTAssertTrue(PhotoMetadataDetails.parse([kCGImagePropertyExifDictionary as String: ["ExposureTime": Double.nan, "FNumber": 0]]).settings.isEmpty)
        // A tiny positive EXIF value must not overflow an Int while formatting.
        _ = PhotoMetadataDetails.parse([kCGImagePropertyExifDictionary as String: ["ExposureTime": 1e-300]])

        let directory = StorageFixture.temporaryDirectory("native-photo-info")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { StorageFixture.removeDirectory(directory) }
        let url = directory.appendingPathComponent("metadata.tiff")
        let context = try XCTUnwrap(CGContext(data: nil, width: 16, height: 12, bitsPerComponent: 8, bytesPerRow: 64,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, "public.tiff" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, try XCTUnwrap(context.makeImage()), properties as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        let before = try Data(contentsOf: url)
        let fromFile = try PhotoMetadataDetails.read(at: url)
        XCTAssertEqual(fromFile.shutter, "1/60s")
        XCTAssertEqual(fromFile.iso, "ISO 320")
        XCTAssertEqual(fromFile.equivalentFocalLength, "26 mm")
        XCTAssertTrue(fromFile.settings.contains("26 mm"))
        XCTAssertFalse(fromFile.settings.contains("5.96 mm"))
        XCTAssertEqual(try Data(contentsOf: url), before, "Detailed metadata reading must not rewrite the source.")
    }

    func testPhotosImportCopiesExactDNGsOwnsTheirLifetimeAndReportsDenialAndFailure() async throws {
        let directory = StorageFixture.temporaryDirectory("native-photos-export")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { StorageFixture.removeDirectory(directory) }
        let first = directory.appendingPathComponent("one.dng"), second = directory.appendingPathComponent("two.DNG")
        let sidecar = directory.appendingPathComponent("one.json")
        let a = Data([1, 2, 3, 4]), b = Data([8, 7, 6])
        try a.write(to: first); try b.write(to: second); try Data("{}".utf8).write(to: sidecar)
        let port = PhotoLibraryRecordingPort()
        let count = try await DNGPhotosExporter(library: port).save([first, sidecar, second])
        XCTAssertEqual(count, 2)
        let bytes = await port.bytes, copies = await port.files
        XCTAssertEqual(bytes, [a, b], "PhotoKit receives the unchanged DNG bytes, with no JSON resource.")
        XCTAssertEqual(copies.map(\.lastPathComponent), ["one.dng", "two.DNG"])
        XCTAssertTrue(copies.allSatisfy { ![first, second].contains($0) && !FileManager.default.fileExists(atPath: $0.path) },
                      "Import-owned copies are distinct and cleaned after completion.")
        XCTAssertEqual(try Data(contentsOf: first), a); XCTAssertEqual(try Data(contentsOf: second), b)
        let denied = PhotoLibraryRecordingPort(allowed: false)
        do { _ = try await DNGPhotosExporter(library: denied).save([first]); XCTFail("Permission denial must fail.") } catch {}
        let deniedFiles = await denied.files
        XCTAssertTrue(deniedFiles.isEmpty, "Denied authorization must not reach asset creation.")
        let failing = PhotoLibraryRecordingPort(fail: true)
        do { _ = try await DNGPhotosExporter(library: failing).save([first]); XCTFail("A rejected Photos change must fail.") } catch {}
        let failedCopies = await failing.files
        XCTAssertFalse(failedCopies.isEmpty)
        XCTAssertTrue(failedCopies.allSatisfy { !FileManager.default.fileExists(atPath: $0.path) })
        let unused = PhotoLibraryRecordingPort()
        do { _ = try await DNGPhotosExporter(library: unused).save([sidecar]); XCTFail("JSON-only is not a DNG import.") } catch {}
        let authCount = await unused.authorizationCount
        XCTAssertEqual(authCount, 0)
    }

    @MainActor func testPhotosActionIsOfferedForDNGsWithoutRequestingAccessOnConstruction() async {
        let port = PhotoLibraryRecordingPort(allowed: false)
        let activity = SaveDNGToPhotosActivity(exporter: DNGPhotosExporter(library: port))
        XCTAssertEqual(activity.activityTitle, "Save to Photos")
        XCTAssertTrue(activity.canPerform(withActivityItems: [URL(fileURLWithPath: "/tmp/front.heic")]))
        XCTAssertFalse(activity.canPerform(withActivityItems: [URL(fileURLWithPath: "/tmp/source.json")]))
        let dng = URL(fileURLWithPath: "/tmp/source.dng")
        XCTAssertTrue(activity.canPerform(withActivityItems: [dng]))
        activity.prepare(withActivityItems: [dng])
        XCTAssertTrue(activity.activityViewController is DNGPhotosSaveController)
        let requests = await port.authorizationCount
        XCTAssertEqual(requests, 0, "Constructing a share action must not request Photos access.")
    }

    @MainActor func testBatchTrashUsesVerifiedMovesAndRestoreAndRejectsStaleRoot() async throws {
        let fixture = await StorageHarness.make(name: "native-batch-trash")
        let h = try XCTUnwrap(fixture)
        var ids: [CaptureID] = []
        for _ in 0..<3 {
            let id = CaptureID(); ids.append(id)
            let handle = try await h.store.stageSource(bytes: StorageFixture.rawBytes(), metadata: StorageFixture.metadata(captureID: id, libraryID: h.libraryID))
            _ = try await h.store.commit(handle: handle)
        }
        let cards = try await h.store.allReconciledSourceCards()
        let index = InMemoryLibraryIndex()
        let app = AppEnvironment(); app.attach(store: h.store, index: index)
        let session = LibrarySessionCoordinator(store: h.store, index: index)
        app.attach(librarySession: session)
        let result = await app.trashOriginals(Array(cards.prefix(2)), generation: h.generation)
        XCTAssertEqual(result.completed.count, 2); XCTAssertNil(result.failure)
        let records = try await h.store.trashedOriginals()
        XCTAssertEqual(records.count, 2)
        let remaining = try await h.store.allReconciledSourceCards()
        XCTAssertEqual(remaining.filter { $0.availability == .local }.count, 1)
        let stale = await app.trashOriginals([try XCTUnwrap(remaining.first(where: { $0.availability == .local }))], generation: RootGeneration.next(h.generation))
        XCTAssertTrue(stale.completed.isEmpty); XCTAssertNotNil(stale.failure)
        for record in records { try await app.restoreOriginal(record, generation: h.generation) }
        let restored = try await h.store.allReconciledSourceCards()
        XCTAssertEqual(restored.filter { $0.availability == .local }.count, 3)
        XCTAssertFalse(app.photoMutationInProgress)
    }
}
#endif
