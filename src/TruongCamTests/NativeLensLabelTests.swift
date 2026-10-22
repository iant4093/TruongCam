#if canImport(UIKit) && canImport(XCTest) && !TC_TESTKIT_STANDALONE
import XCTest
import UIKit
import SwiftUI
import AVFoundation
@testable import TruongCam

final class NativeLensLabelTests: XCTestCase {
    @MainActor func testShippingEquivalentLensSelectorPreservesItsFixedFootprint() async throws {
        let fixture = await StorageHarness.make(name: "native-equivalent-lens-labels")
        let storage = try XCTUnwrap(fixture)
        let capability = StartupRepairSuite.controlFixture(modes: [.auto, .manual])
        let service = SyntheticCameraService(capability: capability)
        let camera = CameraViewModel(camera: service,
            capture: CaptureCoordinator(camera: ChainCameraSpy(), store: storage.store, clock: SystemMonotonicClock()),
            metering: MeteringService(clock: SystemMonotonicClock()), preferences: SyntheticPreferenceStore(), levelFeed: SyntheticLevelFeed())
        let app = AppEnvironment()
        app.attach(camera: camera)
        await camera.start()
        for kinds in [[PhysicalCameraKind.wide], [.ultraWide, .wide], [.ultraWide, .wide, .telephoto]] {
            var snapshot = capability
            snapshot.physicalCameras = kinds.map { kind in
                var physical = StartupRepairSuite.controlFixture(modes: [.auto, .manual], kind: kind).physicalCameras[0]
                physical.nominalEquivalentFocalLengthMM = kind == .wide ? 24 : kind == .ultraWide ? 14 : 120
                return physical
            }
            camera.adoptCapability(snapshot)
            XCTAssertEqual(camera.lensButtons.map(\.kind), kinds, "Labels retain the physical action on single, dual and Pro-style triple topologies.")
            XCTAssertEqual(camera.lensButtons.map(\.label), kinds.map { $0 == .wide ? "24mm" : $0 == .ultraWide ? "14mm" : "120mm" })
            XCTAssertEqual(camera.lensButtons.filter(\.isSelected).map(\.kind), [.wide])

            // Real shipping SwiftUI layout, including a narrow iPhone width and
            // maximum Dynamic Type. A third lens keeps 44-point touch targets.
            for typeSize in [DynamicTypeSize.large, .accessibility5] {
                let host = UIHostingController(rootView: PhysicalLensSelector()
                    .environment(app).environment(\.dynamicTypeSize, typeSize))
                for available in [CGSize(width: 320, height: 568), CGSize(width: 402, height: 874), CGSize(width: 874, height: 402)] {
                    let fitted = host.sizeThatFits(in: available)
                    XCTAssertEqual(fitted.width, CGFloat(kinds.count * 48 + (kinds.count - 1) * 2 + 4), accuracy: 0.5)
                    XCTAssertEqual(fitted.height, 48, accuracy: 0.5, "44-point targets plus unchanged inset.")
                }
            }
        }
        await camera.stop()
    }

    func testPublicPhysicalDiscoveryIncludesTelephotoAndNominalSDKAccessor() {
        XCTAssertEqual(CameraCapabilityProbe.physicalRearDeviceTypes, [.builtInUltraWideCamera, .builtInWideAngleCamera, .builtInTelephotoCamera])
        XCTAssertEqual(CameraCapabilityProbe.kind(for: .builtInTelephotoCamera, position: .back), .telephoto)
        XCTAssertEqual(CameraCapabilityProbe.kind(for: .builtInTrueDepthCamera, position: .front), .front)
        XCTAssertTrue(AVCaptureDevice.instancesRespond(to: NSSelectorFromString("nominalFocalLengthIn35mmFilm")), "The installed public SDK/runtime provides device-specific nominal photo equivalents.")
    }
}
#endif
