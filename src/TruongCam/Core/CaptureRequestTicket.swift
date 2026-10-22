import Foundation
import Synchronization

final class PerCaptureRequest: @unchecked Sendable {
    let captureID: CaptureID
    let intent: CaptureIntent
    let rawPixelFormatType: UInt32
    let rawFileType: String?

    private let lock = NSLock()
    private var expectedRepresentationCount = 1
    private var receivedCount = 0
    private var terminalDelivered = false
    private var nativeSettingsID: Int64?
    private var resolvedDimensions: PixelDimensions?
    private var terminalErrorDescription: String?
    private var recordedFailure: CaptureFailure?
    private var sawRepresentationError = false
    private var nativeShutterCount = 0
    let shutterFeedback = LatestValueBroadcaster<CaptureShutterFeedback>()

    /// Lossless, bounded. Every representation the delegate produces appears
    /// here exactly once, in delivery order.
    /// The RAW channel. PRIVATE to the request: only its own reservation/transfer
    /// operations may attach or consume, so no caller can bypass the single-consumer
    /// contract (REVIEW.md M02).
    private let representations: BoundedEventChannel<DeliveredRAWRepresentation>
    /// The one reserved representation consumer.
    ///
    /// REVIEW.md F07: RAW delivery is single-consumer, so the consumer is RESERVED
    /// once and every later request for the stream receives the same sequence.
    /// A rival subscriber would either duplicate or split records, and losing an
    /// accepted RAW is unacceptable, so a second attach never creates one.
    /// Guards the check → attach → publish sequence. `NSLock` rather than `Mutex`
    /// because the guarded region calls the channel synchronously.
    private var representationConsumer: BoundedOrderedSequence<DeliveredRAWRepresentation>?
    /// Exactly one terminal outcome, readable any number of times by any number
    /// of parties. Never defaults to success.
    let terminal: TerminalOutcomeBox<NativeRequestOutcome>
    /// Resolved dimensions, published as soon as AVFoundation reports them.
    let resolvedDimensionsChannel: LatestValueBroadcaster<PixelDimensions?>

    init(captureID: CaptureID,
         intent: CaptureIntent,
         rawPixelFormatType: UInt32,
         rawFileType: String?,
         maximumRepresentations: Int) {
        self.captureID = captureID
        self.intent = intent
        self.rawPixelFormatType = rawPixelFormatType
        self.rawFileType = rawFileType
        // Loss-critical: a RAW representation must never be silently dropped, so
        // overflow is refused and counted instead.
        self.representations = BoundedEventChannel<DeliveredRAWRepresentation>(
            capacity: max(1, maximumRepresentations) + 2, overflow: .rejectNewest)
        self.terminal = TerminalOutcomeBox()
        self.resolvedDimensionsChannel = LatestValueBroadcaster()
    }

    /// Bound before native submission, so synchronous/early callbacks already
    /// have immutable settings identity. Rebinding a submitted owner is forbidden.
    @discardableResult
    func bindNativeSettingsID(_ value: Int64) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard !terminalDelivered else { return false }
        if let nativeSettingsID { return nativeSettingsID == value }
        nativeSettingsID = value
        return true
    }

    var boundNativeSettingsID: Int64? {
        lock.lock(); defer { lock.unlock() }
        return nativeSettingsID
    }

    func acceptsNativeSettingsID(_ value: Int64) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return nativeSettingsID == value
    }

    /// Foreign native completion cannot retire this request or release its gate.
    @discardableResult
    func recordNativeTerminal(settingsID: Int64, mappedFailure: CaptureFailure?) -> NativeRequestOutcome? {
        guard acceptsNativeSettingsID(settingsID) else {
            noteRepresentationError("A native callback carried another request's settings identity.")
            return nil
        }
        return finishWith(mappedFailure: mappedFailure)
    }

    /// Reserves and returns the single representation consumer.
    ///
    /// The first caller attaches atomically through `subscribeUnique()`; later
    /// callers receive the same reserved sequence. If the channel somehow already
    /// has a consumer that this ticket did not reserve, the reservation fails
    /// loudly rather than silently attaching a second one.
    func reserveRepresentationConsumer() -> BoundedOrderedSequence<DeliveredRAWRepresentation> {
        // One critical section covers check → attach → publish, so two concurrent
        // callers cannot both observe an empty slot (REVIEW.md G07). The channel's own
        // attach is performed inside it, and because delivery is single-consumer the
        // attach cannot fail once the slot is known to be empty.
        reservationLock.lock()
        defer { reservationLock.unlock() }
        if let existing = representationConsumer {
            return existing
        }
        let reserved: BoundedOrderedSequence<DeliveredRAWRepresentation>
        do {
            reserved = try representations.subscribeUnique()
        } catch {
            // Unreachable while this lock guards every attach. It must NOT fall back to
            // unrestricted `subscribe()`: that would attach a rival consumer to a
            // loss-critical queue and split or duplicate RAW records.
            //
            // H07: the refusal must be TYPED and VISIBLE to the real drainer, not a
            // private string nobody reads. The request is finished with a typed failure
            // so `awaitTerminal()` reports it, and the returned sequence ends
            // immediately so no rival can consume the queue.
            reservationRefused = true
            // NO `finishWith`: the native terminal outcome belongs to AVFoundation. A
            // refusal to admit a second reader is reported through the typed
            // `representationReservationRefused` state instead, so already-accepted bytes
            // stay drainable and a later real terminal callback is not pre-empted.
            return representations.subscribeUniqueOrEmpty()
        }
        representationConsumer = reserved
        return reserved
    }

    /// Producer-only: how many records were refused for lack of capacity.
    ///
    /// M02: the channel itself is private, so the owning adapter reads these counters
    /// instead of reaching the producer channel directly.
    var refusedRepresentationCount: Int { representations.overflowedElementCount }

    /// True when a rival attach was refused. Observable by the drainer.
    var representationReservationRefused: Bool {
        reservationLock.lock(); defer { reservationLock.unlock() }
        return reservationRefused
    }

    private let reservationLock = NSLock()
    private var reservationRefused = false

    var expectedCount: Int {
        lock.lock(); defer { lock.unlock() }
        return expectedRepresentationCount
    }

    func setExpectedRepresentationCount(_ count: Int) {
        lock.lock()
        expectedRepresentationCount = max(1, count)
        lock.unlock()
    }

    @discardableResult
    func recordNativeShutter(settingsID: Int64, at date: Date = Date()) -> Bool {
        lock.lock()
        guard !terminalDelivered, nativeSettingsID == settingsID,
              nativeShutterCount < expectedRepresentationCount else { lock.unlock(); return false }
        nativeShutterCount += 1
        lock.unlock()
        shutterFeedback.send(CaptureShutterFeedback(captureID: captureID, sequenceID: intent.sequenceID,
            ordinal: intent.sequenceOrdinal?.value, plannedCount: intent.sequencePlannedCount,
            generation: intent.configurationGeneration, capturedAtUTC: date))
        return true
    }

    func recordResolvedDimensions(_ dimensions: PixelDimensions?) {
        lock.lock()
        if let dimensions { resolvedDimensions = dimensions }
        lock.unlock()
        resolvedDimensionsChannel.send(dimensions)
    }

    /// Records one delivered representation. Returns false when the request has
    /// already reported a terminal outcome (a late duplicate).
    func recordRepresentation(_ representation: DeliveredRAWRepresentation) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        // A late representation after a terminal outcome is refused.
        guard !terminalDelivered else { return false }
        if let nativeSettingsID,
           representation.captureID != captureID || representation.resolvedSettingsUniqueID != nativeSettingsID {
            sawRepresentationError = true
            if terminalErrorDescription == nil {
                terminalErrorDescription = "A RAW callback did not match the submitted native request identity."
            }
            return false
        }
        // Publication is attempted BEFORE the count advances, so the count only ever reflects
        // sources that genuinely reached the channel. A refused publication is visible to the
        // caller and never reported as an accepted source.
        guard representations.send(representation) else {
            return false
        }
        receivedCount += 1
        return true
    }

    func noteRepresentationError(_ description: String) {
        lock.lock()
        sawRepresentationError = true
        if terminalErrorDescription == nil { terminalErrorDescription = description }
        lock.unlock()
    }

    /// Delivers the single terminal outcome exactly once, using the actual
    /// delivered-representation count so an intact source survives a terminal
    /// error as `partialWithRetainedSource`. The recorded value is immutable and
    /// replayable.
    /// The number of representations delivered so far, so a caller that maps a native failure can
    /// classify whether an intact source was retained. Observation only.
    var recordedRepresentationCount: Int {
        lock.lock(); defer { lock.unlock() }
        return receivedCount
    }


    /// Frozen with the first terminal, including when valid representations
    /// make the public outcome partial. Text alone loses native domain/code.
    var terminalFailure: CaptureFailure? {
        lock.lock(); defer { lock.unlock() }
        return recordedFailure
    }

    @discardableResult
    func finishWith(mappedFailure: CaptureFailure?) -> NativeRequestOutcome {
        lock.lock()
        if terminalDelivered {
            // A duplicate callback must not overwrite the recorded outcome, and
            // must never be reported as success on its own.
            lock.unlock()
            return terminal.current ?? .failed(CaptureFailure(
                kind: .operationStalled(detail: "The capture reported completion twice before an outcome was recorded."),
                operation: "capturePhoto"))
        }
        terminalDelivered = true
        let count = receivedCount
        let representationError = terminalErrorDescription
        recordedFailure = mappedFailure ?? representationError.map {
            CaptureFailure(kind: .representationUnavailable(detail: $0), operation: "capturePhoto")
        }
        lock.unlock()

        let outcome: NativeRequestOutcome
        if let failure = mappedFailure {
            if count > 0 {
                outcome = .partial(retainedSourceCount: count, description: failure.kind.userDescription)
            } else {
                outcome = .failed(failure)
            }
        } else if let representationError {
            if count > 0 {
                outcome = .partial(retainedSourceCount: count, description: representationError)
            } else {
                outcome = .failed(CaptureFailure(
                    kind: .representationUnavailable(detail: representationError),
                    operation: "capturePhoto"))
            }
        } else if count == 0 {
            outcome = .failed(CaptureFailure(
                kind: .representationUnavailable(detail: "The camera reported success without delivering RAW data."),
                operation: "capturePhoto"))
        } else {
            outcome = .success
        }

        terminal.record(outcome)
        representations.finish()
        resolvedDimensionsChannel.finish()
        shutterFeedback.finish()
        return outcome
    }

    /// Releases channels if the request is abandoned (hung native session).
    func abandon(description: String) {
        _ = finishWith(mappedFailure: CaptureFailure(
            kind: .operationStalled(detail: description),
            operation: "capturePhoto"))
    }
}
