#if canImport(UIKit) && canImport(XCTest) && !TC_TESTKIT_STANDALONE
import AVFoundation
import Synchronization
import XCTest
@testable import TruongCam

final class CameraAudit43NativeTests: XCTestCase {
    func testQueuedFocusIssueRejectsReplacedSensorControlLifecycleAndResetOwnership() async {
        let queue = SerialSessionQueue(label: "TruongCam.test.focus-ownership")
        queue.activate()
        let generation = Mutex(ConfigurationGeneration.zero)
        let control = Mutex<UInt64>(1)
        let lifecycle = LifecycleOwnership(), originalLifecycle = lifecycle.begin()
        let reset = Mutex<UInt64>(0), writes = Mutex(0)
        let current: @Sendable () -> Bool = {
            ControlIssueGate.mayIssue(generationAtIssue: .zero, currentGeneration: generation.withLock { $0 },
                invocationAtIssue: 1, currentInvocation: control.withLock { $0 })
                && lifecycle.isCurrent(originalLifecycle) && reset.withLock { $0 == 0 }
        }
        let issue: @Sendable () -> Result<Void, CaptureFailure> = {
            CameraControlBinding.applyFocusPointIfCurrent(isCurrent: current) {
                writes.withLock { $0 += 1 }
                return .success(())
            }
        }
        let valid = await queue.perform(issue)
        if case .failure = valid { XCTFail("Current request must execute") }
        XCTAssertEqual(writes.withLock { $0 }, 1)
        generation.withLock { $0 = ConfigurationGeneration(1) }
        let replacedSensor = await queue.perform(issue)
        if case .success = replacedSensor { XCTFail("Replaced sensor cannot receive old focus") }
        generation.withLock { $0 = .zero }; control.withLock { $0 = 2 }
        let replacedControl = await queue.perform(issue)
        if case .success = replacedControl { XCTFail("New control application owns native focus") }
        control.withLock { $0 = 1 }; reset.withLock { $0 = 1 }
        let resetOwned = await queue.perform(issue)
        if case .success = resetOwned { XCTFail("Reset-owned graph cannot receive old focus") }
        reset.withLock { $0 = 0 }; _ = lifecycle.begin()
        let replacedLifecycle = await queue.perform(issue)
        if case .success = replacedLifecycle { XCTFail("Stopped/restarted camera cannot receive old focus") }
        XCTAssertEqual(writes.withLock { $0 }, 1, "Every stale issue must execute zero native setters")
    }
}
#endif
