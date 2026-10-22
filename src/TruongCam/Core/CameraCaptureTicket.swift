import Foundation
import Synchronization

/// The shipping `CaptureRequestTicket` adapter over the Core request owner.
///
/// AL01: extracted into Core because it depends ONLY on Core types. Core/ and Camera/ are the
/// same app module, so the app is unaffected, but the portable verifier can now compile this
/// adapter and a registered test can drive the REAL submission/retirement owner end to end
/// instead of a fixture that models it.
struct CameraCaptureTicket: CaptureRequestTicket, Sendable {
    let captureID: CaptureID
    private let initialSettingsID: Int64
    let request: PerCaptureRequest
    var uniqueSettingsID: Int64 { request.boundNativeSettingsID ?? initialSettingsID }

    init(captureID: CaptureID, uniqueSettingsID: Int64, request: PerCaptureRequest) {
        self.captureID = captureID
        self.initialSettingsID = uniqueSettingsID
        self.request = request
    }

    /// RAW representations are loss-critical and therefore SINGLE-consumer.
    ///
    /// REVIEW.md F07: this called the unrestricted `subscribe()`, so the comment's
    /// claim was false and a second caller could attach with the old incorrect
    /// multi-subscriber accounting. The ticket now reserves its one consumer
    /// atomically, and a second attach returns the SAME stream rather than creating
    /// a rival — an accepted RAW is never lost to a second observer.
    func representationStream() -> BoundedOrderedSequence<DeliveredRAWRepresentation> {
        request.reserveRepresentationConsumer()
    }

    func representationsOverflowed() -> Int {
        request.refusedRepresentationCount
    }

    func awaitTerminal() async -> NativeRequestOutcome {
        await request.terminal.wait()
    }

    func currentTerminal() -> NativeRequestOutcome? {
        request.terminal.current
    }

    func terminalFailure() -> CaptureFailure? {
        if let failure = request.terminalFailure { return failure }
        if case .failed(let failure) = request.terminal.current { return failure }
        return nil
    }

    var shutterFeedbackEvents: AsyncStream<CaptureShutterFeedback> { request.shutterFeedback.subscribe() }

    var resolvedDimensions: AsyncStream<PixelDimensions?> {
        request.resolvedDimensionsChannel.subscribe()
    }
}
