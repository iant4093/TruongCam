import Foundation
import Synchronization

#if canImport(XCTest)
@testable import TruongCam
#endif

/// Narrow synthetic conformances so the REAL `SequenceCoordinator` can be constructed and driven in
/// the portable verifier without a device, a native bracket path or a motion sensor.
///
/// AL01: every type here satisfies a SHIPPING contract; the coordinator above them runs unchanged.
/// These ports make no native claim.

/// `SequenceBaselineSettling` — an immediate, deterministic baseline.
struct SyntheticBaselineSettler: SequenceBaselineSettling {
    struct Snapshot: Sendable {}
    func settle(
        _ request: BaselineSettlementRequest,
        cancellation: SequenceCancellationSignal
    ) async -> Result<SequenceBaselineSnapshot, BaselineSettlementFailure> {
        .failure(.readbackUnavailable(
            reason: "synthetic fixture: no sensor baseline",
            samplesObserved: 0))
    }
}

/// `FocusPositionControlling` — accepts moves and reports the requested position back.
actor SyntheticFocusController: FocusPositionControlling {
    private var position: Double?
    func beginMove(to position: Double) async -> Result<Void, CaptureFailure> {
        self.position = position
        return .success(())
    }
    func readback() async -> FocusSettleReadback? {
        FocusSettleReadback(position: position, state: .settled, provenance: .settledDeviceReadback)
    }
}

/// `SingleCaptureExecuting` — reports a synthetic terminal result and never touches a camera.
struct SyntheticSingleCaptureExecutor: SingleCaptureExecuting {
    /// AO03: when `blocking`, the submission is held open so the plan stays genuinely ACTIVE.
    let gate = SyntheticExecutionGate()

    func execute(_ intent: CaptureIntent) async -> SingleCaptureExecutionResult {
        await gate.enter()
        return SingleCaptureExecutionResult(
            captureID: intent.captureID,
            terminalStatus: .failed(errorDescription: "synthetic fixture: no native capture"),
            persistence: .reserved)
    }
}

/// Holds a synthetic submission open, so an ACTIVE plan can be observed rather than assumed.
final class SyntheticExecutionGate: @unchecked Sendable {
    private let mutex = Mutex((blocking: false, entered: 0, release: Optional<CheckedContinuation<Void, Never>>.none))
    var submittedCount: Int { mutex.withLock { $0.entered } }
    func setBlocking(_ value: Bool) { mutex.withLock { $0.blocking = value } }
    func enter() async {
        let shouldBlock = mutex.withLock { s -> Bool in s.entered += 1; return s.blocking && s.release == nil }
        guard shouldBlock else { return }
        await withCheckedContinuation { c in
            let taken = mutex.withLock { s -> Bool in
                guard s.release == nil else { return false }
                s.release = c
                return true
            }
            if !taken { c.resume() }
        }
    }
    func release() {
        let c = mutex.withLock { s -> Optional<CheckedContinuation<Void, Never>> in
            let held = s.release; s.release = nil; return held
        }
        c?.resume()
    }
}
