import Foundation
#if canImport(XCTest)
@testable import TruongCam
#endif

private actor FourthFocusController: FocusPositionControlling {
    let moveHold: PrepareHold?
    let readHold: PrepareHold?
    private(set) var moves = 0
    private(set) var reads = 0
    private var target: Double?
    init(moveHold: PrepareHold? = nil, readHold: PrepareHold? = nil) {
        self.moveHold = moveHold; self.readHold = readHold
    }
    func beginMove(to position: Double) async -> Result<Void, CaptureFailure> {
        moves += 1; target = position
        if let moveHold { await moveHold.wait() }
        return .success(())
    }
    func readback() async -> FocusSettleReadback? {
        reads += 1
        if let readHold { await readHold.wait() }
        return FocusSettleReadback(position: target, state: .settled, provenance: .settledDeviceReadback)
    }
}
private actor FourthFocusObserver: SequencePhaseObserving {
    enum HeldPhase: Sendable { case none, settling, capturing }
    let phase: HeldPhase
    let hold: PrepareHold?
    init(_ phase: HeldPhase = .none, hold: PrepareHold? = nil) { self.phase = phase; self.hold = hold }
    func observe(phase: SequenceRunPhase) async {
        switch (self.phase, phase) {
        case (.settling, .settlingFocus), (.capturing, .capturing):
            if let hold { await hold.wait() }
        default: break
        }
    }
}
private actor FourthFocusExecutor: SingleCaptureExecuting {
    let hold: PrepareHold?
    private(set) var submissions = 0
    init(hold: PrepareHold? = nil) { self.hold = hold }
    func execute(_ intent: CaptureIntent) async -> SingleCaptureExecutionResult {
        submissions += 1
        if let hold { await hold.wait() }
        // Only source ownership/admission is exercised; no original bytes exist.
        return SingleCaptureExecutionResult(captureID: intent.captureID, terminalStatus: .success, persistence: .reserved)
    }
}

enum FourthFocusReviewSuite {
    private static func waitUntil(_ predicate: @escaping @Sendable () async -> Bool) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while !(await predicate()), ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(2)) }
        return await predicate()
    }
    private static func request() -> FocusFrameRequest {
        let intent = CaptureIntent(captureID: CaptureID(), libraryID: LibraryID(), sequenceID: SequenceID(),
            sequenceOrdinal: SourceOrdinal(0), requestedDimensions: PixelDimensions(width: 4000, height: 3000),
            exposure: .manual(durationSeconds: 0.01, iso: 100), biasEV: 0,
            focus: FocusIntent(mode: .manual, position: 0.4, pointOfInterest: nil),
            whiteBalance: WhiteBalanceIntent(mode: .auto, temperatureAndTint: nil),
            configurationGeneration: .zero, rootGeneration: .zero, physicalCameraKind: .wide,
            createdAtUTC: Date(), timezoneOffsetSeconds: 0, mode: .focusBracketSource)
        return FocusFrameRequest(ordinal: SourceOrdinal(0), requestedPosition: 0.4,
            longestPlannedDurationSeconds: 0.01, intent: intent)
    }
    static let suite = TCSuite(id: "FourthFocusReview", title: "Focus-bracket Stop at native move/readback and observer awaits", cases: [
        TCCase(id: "TC46FC", title: "Stop or task cancellation during move, observer or settled readback submits no later focus source") { r in
            for boundary in 0..<4 {
                for cancelsTask in [false, true] {
                    let hold = PrepareHold(), signal = SequenceCancellationSignal()
                    let controller = FourthFocusController(moveHold: boundary == 0 ? hold : nil, readHold: boundary == 2 ? hold : nil)
                    let observer = FourthFocusObserver(boundary == 1 ? .settling : boundary == 3 ? .capturing : .none,
                        hold: boundary == 1 || boundary == 3 ? hold : nil)
                    let executor = FourthFocusExecutor()
                    let driver = FocusBracketDriver(clock: SystemMonotonicClock(), controller: controller,
                        pipeline: SequenceSourcePipeline(executor: executor))
                    let run = Task { await driver.runFrame(request(), cancellation: signal, observer: observer) }
                    r.check("actual requested await is held", await waitUntil { await hold.didEnter })
                    if cancelsTask { run.cancel() } else { signal.request() }
                    await hold.release()
                    let result = await run.value
                    r.equal("no source reaches pipeline after stop", await executor.submissions, 0)
                    r.check("cancelled frame has no acquired source", !result.didAcquire)
                    r.equal("cancel is reported explicitly", result.failure?.kind.stableCode, "cancelled")
                    if boundary < 2 { r.equal("stop prevents even a later native focus read", await controller.reads, 0) }
                }
            }
        },
        TCCase(id: "TC46FI", title: "A signal already requested before a focus frame issues no move or source") { r in
            let signal = SequenceCancellationSignal(), controller = FourthFocusController(), executor = FourthFocusExecutor()
            signal.request()
            let driver = FocusBracketDriver(clock: SystemMonotonicClock(), controller: controller,
                pipeline: SequenceSourcePipeline(executor: executor))
            let result = await driver.runFrame(request(), cancellation: signal, observer: FourthFocusObserver())
            r.equal("no native move after stop", await controller.moves, 0)
            r.equal("no source after stop", await executor.submissions, 0)
            r.check("already-stopped frame is cancelled", result.failure?.kind.stableCode == "cancelled")
        },
        TCCase(id: "TC46FP", title: "A current focus source runs once and an already-submitted source drains through later Stop") { r in
            for stopsAfterSubmission in [false, true] {
                let hold = PrepareHold(), signal = SequenceCancellationSignal(), controller = FourthFocusController()
                let executor = FourthFocusExecutor(hold: stopsAfterSubmission ? hold : nil)
                let driver = FocusBracketDriver(clock: SystemMonotonicClock(), controller: controller,
                    pipeline: SequenceSourcePipeline(executor: executor))
                let run = Task { await driver.runFrame(request(), cancellation: signal, observer: FourthFocusObserver()) }
                if stopsAfterSubmission {
                    r.check("source executor actually owns submission", await waitUntil { await hold.didEnter })
                    signal.request()
                    await hold.release()
                }
                let result = await run.value
                r.equal("one source submission", await executor.submissions, 1)
                r.check("submitted source result is preserved", result.didAcquire)
                r.equal("actual settled position is retained", result.settledPosition, 0.4)
                r.check("later Stop invents no source failure", result.failure == nil)
            }
        }
    ])
}
