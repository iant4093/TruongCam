import Foundation
import Synchronization

// CONTRACTS.md: "Publish bounded latest-state streams (buffer newest one) and
// explicit request outcomes; do not drop loss-critical capture/save events in a
// latest-only UI stream." And: "Unbounded source/frame queues" are release
// blocking.

/// A latest-value mailbox without subscriber backpressure: a new value replaces
/// the unconsumed one. Publication holds only a short mutex; it never waits for a
/// subscriber to consume a value. Used for preview/state snapshots only.
final class LatestValueBroadcaster<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    // Publication order includes replay and finish. The registry lock is never
    // held during yield/finish: AsyncStream termination may remove a subscriber.
    // No native work or subscriber callback runs inside this nonblocking path.
    private let publicationLock = NSLock()
    private var subscribers: [UUID: AsyncStream<Value>.Continuation] = [:]
    private var latest: Value?
    private var isFinished = false
    #if DEBUG || TC_PORTABLE_VERIFIER
    // Tightening-only test seam: pauses publication to prove competing send and
    // replay cannot overtake it. Release builds contain no hook or closure call.
    private let beforeDelivery: (@Sendable (Value) -> Void)?
    init(beforeDelivery: (@Sendable (Value) -> Void)? = nil) { self.beforeDelivery = beforeDelivery }
    #else
    init() {}
    #endif

    func send(_ value: Value) {
        publicationLock.lock()
        defer { publicationLock.unlock() }
        lock.lock()
        if isFinished { lock.unlock(); return }
        latest = value
        let continuations = Array(subscribers.values)
        lock.unlock()
        #if DEBUG || TC_PORTABLE_VERIFIER
        beforeDelivery?(value)
        #endif
        for continuation in continuations { continuation.yield(value) }
    }

    /// Value whose publication currently owns or most recently completed the
    /// publication lock; awaiting subscribers only receive that same order.
    var current: Value? {
        lock.lock(); defer { lock.unlock() }
        return latest
    }

    func finish() {
        publicationLock.lock()
        defer { publicationLock.unlock() }
        lock.lock()
        isFinished = true
        let continuations = Array(subscribers.values)
        subscribers.removeAll()
        lock.unlock()
        for continuation in continuations { continuation.finish() }
    }

    func subscribe(replayLatest: Bool = true) -> AsyncStream<Value> {
        AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            let id = UUID()
            publicationLock.lock()
            defer { publicationLock.unlock() }
            lock.lock()
            let replay = replayLatest ? latest : nil
            let finished = isFinished
            if !finished { subscribers[id] = continuation }
            lock.unlock()
            continuation.onTermination = { [weak self] _ in
                guard let self else { return }
                self.lock.lock()
                self.subscribers.removeValue(forKey: id)
                self.lock.unlock()
            }
            if let replay { continuation.yield(replay) }
            if finished { continuation.finish() }
        }
    }
}

/// A refusal that a caller must not ignore.
enum ChannelError: Error, Hashable, Sendable, CustomStringConvertible {
    /// A second consumer tried to attach to a single-consumer loss-critical channel.
    case consumerAlreadyAttached

    var description: String {
        switch self {
        case .consumerAlreadyAttached:
            return "This loss-critical channel already has its one consumer; a second would split or duplicate records."
        }
    }
}

/// A single parked waiter, resumable at most once from either a signal or a
/// cancellation (REVIEW.md G07).
///
/// Ownership invariant for the narrow `@unchecked Sendable`: `continuation` and
/// `resumed` are only touched while `lock` is held.
final class WaiterTicket: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Never>?
    private var resumed = false

    func register(_ continuation: CheckedContinuation<Void, Never>) {
        lock.lock()
        if resumed {
            lock.unlock()
            continuation.resume()
            return
        }
        self.continuation = continuation
        lock.unlock()
    }

    /// True once this ticket has been resumed, so a caller can avoid parking.
    var isResumed: Bool {
        lock.lock(); defer { lock.unlock() }
        return resumed
    }

    /// Resumes the waiter exactly once, whatever calls it first.
    ///
    /// H07: the `resumed` flag is set even when NO continuation is installed yet. A
    /// task that was already cancelled runs `onCancel` BEFORE it reaches the await, so
    /// the cancellation must be REMEMBERED; otherwise the later `register` parks a
    /// waiter whose only wake-up already happened, and the abandoned observer never
    /// returns.
    @discardableResult
    func resumeOnce() -> Bool {
        lock.lock()
        guard !resumed else { lock.unlock(); return false }
        resumed = true
        let pending = continuation
        continuation = nil
        lock.unlock()
        pending?.resume()
        return true
    }
}

/// A bounded, ordered sequence that tells its channel when a value was consumed.
///
/// `AsyncStream` cannot express backpressure: `yield` never blocks and
/// `bufferingPolicy` merely chooses which value to discard when its own internal
/// buffer is full. A loss-critical channel therefore cannot use it to prove that a
/// live slow subscriber is bounded (REVIEW.md S02). This sequence keeps the
/// channel's queue per subscriber and reports each consumed element, so the
/// channel always knows how much a subscriber has actually taken.
struct BoundedOrderedSequence<Element: Sendable>: AsyncSequence, Sendable {
    /// True for a sequence produced by `subscribeUnique()`: a reserved, loss-critical
    /// single-consumer stream whose real consumer is the app-owned drainer.
    ///
    /// REVIEW.md L02: `let`, so a COPY cannot switch the mode off and then reach the
    /// records through the iterator. The mode is fixed when the sequence is created.
    let isReservedSingleConsumer: Bool

    final class Storage: Sendable {
        private struct State {
            var queue: [Element] = []
            var isFinished = false
            var hasTerminated = false
            /// True once an iterator has claimed this queue (REVIEW.md H07).
            var iteratorClaimed = false
            /// True once the SINGLE retained drain has been admitted (REVIEW.md K02).
            var drainAdmitted = false
        }

        /// `Synchronization.Mutex` because `dequeue()` is async and the lock must
        /// never be held across the suspension.
        private let mutex = Mutex(State())
        private let onConsumed: @Sendable (Int) -> Void
        private let onTerminated: @Sendable () -> Void
        /// Signalled whenever a value arrives or the stream finishes, so `next()`
        /// can WAIT for work instead of returning nil.
        private let arrival = ArrivalSignal()

        init(onConsumed: @escaping @Sendable (Int) -> Void,
             onTerminated: @escaping @Sendable () -> Void) {
            self.onConsumed = onConsumed
            self.onTerminated = onTerminated
        }

        /// Appends and wakes in one critical section, so a consumer that already
        /// decided the queue was empty cannot park after this wake-up is lost.
        func enqueue(_ value: Element) {
            mutex.withLock { state in
                state.queue.append(value)
                arrival.signal()
            }
        }

        func enqueue(contentsOf values: [Element]) {
            guard !values.isEmpty else { return }
            mutex.withLock { state in
                state.queue.append(contentsOf: values)
                arrival.signal()
            }
        }

        func finish() {
            // The signal MUST be raised inside the same critical section that sets
            // `isFinished`. Otherwise a `dequeue()` that observes the flag as false
            // and then parks its continuation can park after this signal, and no
            // later signal will ever arrive (a real lost-wakeup hang, not a
            // scheduling artifact).
            mutex.withLock { state in
                state.isFinished = true
                arrival.finish()
            }
        }

        /// Admits the ONE retained drain for this stream. False for every later caller,
        /// whatever handle or copy it holds.
        func admitDrain() -> Bool {
            mutex.withLock { state in
                guard !state.drainAdmitted else { return false }
                state.drainAdmitted = true
                return true
            }
        }

        /// Claims the one iterator for this queue. False when another already has it.
        func claimIterator() -> Bool {
            mutex.withLock { state in
                guard !state.iteratorClaimed else { return false }
                state.iteratorClaimed = true
                return true
            }
        }

        /// Takes one value and reports one consumed slot to the channel.
        ///
        /// Waits for either a value or real completion. `AsyncSequence` treats a
        /// `nil` from `next()` as end-of-stream, so returning nil merely because the
        /// queue happened to be momentarily empty would silently truncate a live
        /// stream (this broke T09b: a consumer that started before the producer
        /// saw an empty queue and stopped immediately).
        func dequeue() async -> Element? {
            while true {
                // Observe the signal version BEFORE inspecting the queue, then
                // compare-and-park. If an enqueue lands in between, the version has
                // moved and `wait(since:)` returns immediately instead of parking
                // with data already queued (REVIEW.md R10).
                let version = arrival.currentVersion()
                let taken: Element? = mutex.withLock { state -> Element? in
                    guard !state.queue.isEmpty else { return nil }
                    return state.queue.removeFirst()
                }
                if let taken {
                    onConsumed(1)
                    return taken
                }
                let streamEnded = mutex.withLock { $0.isFinished }
                if streamEnded {
                    terminateOnce()
                    return nil
                }
                // A cancelled consumer must END, not re-park: the wait below wakes on
                // cancellation, and without this check the loop would park again and
                // the abandoned observer would never return (REVIEW.md G07).
                if Task.isCancelled {
                    // Stop reading WITHOUT tearing the sequence down: an abandoned
                    // observer must finish, but the channel's subscriber list is not
                    // its to mutate (REVIEW.md H07).
                    return nil
                }
                await arrival.wait(since: version)
            }
        }

        private func terminateOnce() {
            let already = mutex.withLock { state -> Bool in
                let was = state.hasTerminated
                state.hasTerminated = true
                return was
            }
            if !already { onTerminated() }
        }
    }

    /// The queue. Reachable only from this file: the CHANNEL enqueues/finishes through
    /// the producer operations below, and no other file can reach `storage` at all, so
    /// `dequeue()` cannot be called around the admitted drain (REVIEW.md L02).
    fileprivate let storage: Storage

    /// Producer-only: append a record. Only the owning channel's delivery path calls it.
    fileprivate func producerEnqueue(contentsOf values: [Element]) {
        storage.enqueue(contentsOf: values)
    }

    /// Producer-only: end the stream.
    fileprivate func producerFinish() { storage.finish() }

    init(onConsumed: @escaping @Sendable (Int) -> Void,
         onTerminated: @escaping @Sendable () -> Void,
         isReservedSingleConsumer: Bool = false) {
        self.isReservedSingleConsumer = isReservedSingleConsumer
        storage = Storage(onConsumed: onConsumed, onTerminated: onTerminated)
    }

    /// Claims the single iterator for this sequence.
    ///
    /// REVIEW.md H07: copies of a reserved loss-critical sequence shared one dequeue
    /// queue, so a second iterator could consume records the owner had not read yet and
    /// the accepted data was split. The storage grants ONE iterator; any later caller
    /// receives an iterator that ends immediately, so no record is ever diverted.
    func makeAsyncIterator() -> Iterator {
        // A reserved loss-critical sequence is consumed by the app-owned drainer via
        // `claimNext()`. Its AsyncIterator takes AT MOST ONE element, so a copy of that
        // iterator cannot take a record the owner has not read (REVIEW.md I02).
        // K02: a reserved stream exposes NO destructive reader. Observers use the
        // immutable outcomes published elsewhere; only `drainAll` consumes records.
        guard !isReservedSingleConsumer else {
            return Iterator(storage: storage, isExhausted: true)
        }
        guard storage.claimIterator() else {
            return Iterator(storage: storage, isExhausted: true)
        }
        return Iterator(storage: storage, isExhausted: false)
    }

    /// Takes the next element for the SINGLE app-owned consumer.
    ///
    /// This is the production consumption operation for a reserved stream: it is
    /// callable repeatedly by the one drainer that owns the request. It does not go
    /// through a copyable iterator, so ownership cannot be duplicated (REVIEW.md I02).
    func claimNext() async -> Element? {
        // K02: a reserved stream offers NO individual pull. Consumption happens only
        // through the single admitted drain below, so this can never take a record out
        // from under the owner.
        guard !isReservedSingleConsumer else { return nil }
        return await storage.dequeue()
    }

    /// Runs the ONE admitted retained drain, consuming every record.
    ///
    /// Returns false when another drain already owns this stream. This is the only
    /// destructive operation a reserved stream exposes, so a copied handle, a second
    /// iterator or a bypass call cannot divert a record (REVIEW.md K02).
    @discardableResult
    func drainAll(_ body: sending (Element) async -> Void) async -> Bool {
        guard storage.admitDrain() else { return false }
        while let element = await storage.dequeue() {
            await body(element)
        }
        return true
    }

    struct Iterator: AsyncIteratorProtocol {
        /// PRIVATE: a returned iterator cannot be made to reopen a refused queue, and
        /// cannot reach the underlying storage (REVIEW.md M02).
        private let storage: Storage
        /// Private for the same reason: a caller could otherwise clear it and resume
        /// consuming a queue it was refused.
        private var isExhausted: Bool = false

        init(storage: Storage, isExhausted: Bool) {
            self.storage = storage
            self.isExhausted = isExhausted
        }

        mutating func next() async -> Element? {
            guard !isExhausted else { return nil }
            return await storage.dequeue()
        }
    }
}

/// A one-shot-per-wait signal used to wake a waiting consumer.
///
/// `AsyncStream` is deliberately not used here, because `AsyncStream` cannot
/// express the bounded delivery this channel needs. A simple continuation list is
/// enough and keeps the channel self-contained.
///
/// Ownership invariant for the narrow `@unchecked Sendable`: `waiters` and
/// `isFinished` are only touched while `lock` is held.
final class ArrivalSignal: Sendable {
    private struct State {
        var waiters: [CheckedContinuation<Void, Never>] = []
        /// The tickets currently parked, so a cancellation can wake exactly its own
        /// waiter (REVIEW.md G07).
        var registrations: [WaiterTicket] = []
        var isFinished = false
        /// Incremented on every signal/finish. This is the retained event token a
        /// waiter compares against, which is what closes the enqueue lost-wakeup
        /// window (REVIEW.md R10).
        var version: UInt64 = 0
    }

    /// `Synchronization.Mutex` rather than `NSLock`, because `wait()` is async and
    /// the lock is never held across a suspension point.
    private let mutex = Mutex(State())

    func signal() {
        let pending = mutex.withLock { state -> [WaiterTicket] in
            state.version &+= 1
            let tickets = state.registrations
            state.registrations.removeAll()
            state.waiters.removeAll()
            return tickets
        }
        for ticket in pending { ticket.resumeOnce() }
    }

    func finish() {
        let pending = mutex.withLock { state -> [WaiterTicket] in
            state.isFinished = true
            state.version &+= 1
            let tickets = state.registrations
            state.registrations.removeAll()
            state.waiters.removeAll()
            return tickets
        }
        for ticket in pending { ticket.resumeOnce() }
    }

    /// The current event version. A caller observes this BEFORE checking its own
    /// queue, then passes it to `wait(since:)`.
    func currentVersion() -> UInt64 {
        mutex.withLock { $0.version }
    }

    /// Waits only if no event has been signalled since `version`.
    ///
    /// This is the compare-and-park that makes enqueue-vs-wait safe: a signal that
    /// lands after the caller observed `version` bumps the version, so the waiter
    /// returns immediately instead of parking with data already queued.
    ///
    /// REVIEW.md G07: the wait is also CANCELLATION-AWARE. A task cancelled while
    /// parked is woken through the same waiter registry, so an abandoned observer
    /// returns without needing a later send or finish.
    func wait(since version: UInt64) async {
        let shouldPark = mutex.withLock { state -> Bool in
            if state.isFinished { return false }
            if state.version != version { return false }
            return true
        }
        guard shouldPark else { return }

        let ticket = WaiterTicket()
        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                // A task cancelled BEFORE this point already ran `onCancel`, so the
                // ticket is flagged and must not park.
                if ticket.isResumed {
                    continuation.resume()
                    return
                }
                let resumeImmediately = mutex.withLock { state -> Bool in
                    // Re-check under the same lock that registers the waiter, so no
                    // signal can slip between the check and the registration.
                    if state.isFinished || state.version != version { return true }
                    ticket.register(continuation)
                    state.registrations.append(ticket)
                    return false
                }
                if resumeImmediately { continuation.resume() }
            }
        } onCancel: {
            // Wake exactly this waiter and forget its registration. If it already
            // resumed through signal/finish, `resumeOnce` is a no-op; if it has not
            // parked yet, the ticket flag makes the registration path resume instead
            // of parking. Either way the abandoned observer finishes.
            mutex.withLock { state in
                state.registrations.removeAll { $0 === ticket }
            }
            ticket.resumeOnce()
        }
    }
}

/// A bounded, ordered channel for events that must not be silently lost.
///
/// Design (REVIEW.md S02). The previous version had three real defects:
///
///   1. the stream was `.unbounded`, and capacity was checked **only** when no
///      subscriber was attached, so a live-but-slow consumer accepted unlimited
///      values with zero refusals;
///   2. `subscribe` registered the continuation and flushed the backlog outside
///      the lock, so a concurrent `send` could deliver a *newer* value ahead of
///      older queued ones;
///   3. `send` unlocked before yielding to live continuations and ignored the
///      yield result, so a concurrent `finish()` could terminate a continuation
///      after a value had been accepted.
///
/// This replacement keeps the shared buffer and every subscriber window under one
/// lock and counts values a subscriber has actually CONSUMED. Therefore:
///
/// * `send` refuses when a live subscriber is at capacity, so a slow consumer is
///   bounded exactly like an unattached backlog, and each refusal is counted;
/// * delivery order is FIFO by construction, so registration can never reorder a
///   backlog against newer values;
/// * `finish()` only marks the channel closed; every accepted element is still
///   delivered before a subscriber's stream ends.
///
/// Loss-critical channels use `.rejectNewest`. `.dropOldest`/`.dropNewest` remain
/// for latest-value UI streams and always count what they discarded.
final class BoundedEventChannel<Element: Sendable>: @unchecked Sendable {
    enum OverflowBehavior: Sendable {
        case dropOldest
        case dropNewest
        /// Nothing is dropped: the element is refused and counted.
        case rejectNewest
    }

    /// Delivery window for one subscriber.
    ///
    /// Ownership invariant for the narrow `@unchecked Sendable`: every mutable
    /// field is read or written only while the channel's `lock` is held.
    /// `sequence` and `id` are immutable after `init`.
    private final class Subscriber: @unchecked Sendable {
        let id = UUID()
        let sequence: BoundedOrderedSequence<Element>
        var pending = 0
        var isFinished = false
        var isRemoved = false
        init(sequence: BoundedOrderedSequence<Element>) {
            self.sequence = sequence
        }
    }

    private let lock = NSLock()
    private var buffer: [Element] = []
    private var subscribers: [Subscriber] = []
    private var finished = false
    private var droppedCount = 0
    private var overflowCount = 0
    private var sentCount = 0
    private let capacity: Int
    private let overflow: OverflowBehavior

    init(capacity: Int, overflow: OverflowBehavior = .rejectNewest) {
        precondition(capacity > 0, "capacity must be positive")
        self.capacity = capacity
        self.overflow = overflow
    }

    var droppedElementCount: Int {
        lock.lock(); defer { lock.unlock() }
        return droppedCount
    }

    /// Elements refused because the bounded delivery window was full. A non-zero
    /// value on a loss-critical channel is a delivery failure the caller must
    /// surface, never silently ignore.
    var overflowedElementCount: Int {
        lock.lock(); defer { lock.unlock() }
        return overflowCount
    }

    var acceptedElementCount: Int {
        lock.lock(); defer { lock.unlock() }
        return sentCount
    }

    var isFinished: Bool {
        lock.lock(); defer { lock.unlock() }
        return finished
    }

    /// Values this channel has accepted but not yet handed to any subscriber.
    ///
    /// This is the drain-progress signal. Values already moved into a
    /// subscriber's window are in flight with that consumer, so they are reported
    /// separately by `inFlightCount` rather than counted as backlog: a caller
    /// waiting for the queue to empty must not be blocked by a consumer that is
    /// already holding its window.
    var undeliveredBacklogCount: Int {
        lock.lock(); defer { lock.unlock() }
        return buffer.count
    }

    /// Values handed to subscribers but not yet consumed by them.
    var inFlightCount: Int {
        lock.lock(); defer { lock.unlock() }
        return subscribers.reduce(0) { $0 + $1.pending }
    }

    /// Everything accepted but not yet consumed, backlog plus in-flight.
    var outstandingElementCount: Int {
        lock.lock(); defer { lock.unlock() }
        return buffer.count + subscribers.reduce(0) { $0 + $1.pending }
    }

    /// Delivers one element, or refuses it when the bounded window is full.
    /// Returns true only when the element was accepted for delivery.
    @discardableResult
    func send(_ element: Element) -> Bool {
        lock.lock()
        guard !finished else {
            lock.unlock()
            return false
        }
        if subscribers.contains(where: { !$0.isRemoved && $0.pending >= capacity }) {
            overflowCount += 1
            lock.unlock()
            return false
        }
        guard buffer.count < capacity else {
            overflowCount += 1
            switch overflow {
            case .rejectNewest:
                lock.unlock()
                return false
            case .dropOldest:
                buffer.removeFirst()
                droppedCount += 1
            case .dropNewest:
                droppedCount += 1
                lock.unlock()
                return false
            }
            buffer.append(element)
            sentCount += 1
            let touched = takeLocked()
            lock.unlock()
            deliver(touched)
            return true
        }
        buffer.append(element)
        sentCount += 1
        let touched = takeLocked()
        lock.unlock()
        deliver(touched)
        return true
    }

    /// Marks the channel closed. Everything already accepted is still delivered
    /// before any subscriber's stream ends.
    func finish() {
        lock.lock()
        guard !finished else {
            lock.unlock()
            return
        }
        finished = true
        let touched = takeLocked()
        lock.unlock()
        deliver(touched)
    }

    /// Whether a consumer has already attached. Loss-critical delivery is
    /// single-consumer by contract: two consumers would either duplicate or split
    /// records, and both are silent data corruption for RAW (REVIEW.md R10).
    var hasConsumer: Bool {
        lock.lock(); defer { lock.unlock() }
        return !subscribers.isEmpty
    }

    /// Attaches the channel's single consumer, atomically.
    ///
    /// REVIEW.md F07: the previous version checked `hasConsumer` under one lock
    /// acquisition and then called `subscribe()`, which acquired the lock AGAIN, so
    /// two concurrent attaches could both pass the check and both attach. The
    /// check-and-attach below happens under a single critical section.
    func subscribeUnique() throws -> BoundedOrderedSequence<Element> {
        lock.lock()
        guard subscribers.isEmpty else {
            lock.unlock()
            throw ChannelError.consumerAlreadyAttached
        }
        // The reserved mode is fixed at CREATION, so no copy can change it later
        // (REVIEW.md L02).
        let sequence = makeSubscriberLocked(isReservedSingleConsumer: true)
        lock.unlock()
        return sequence
    }

    /// A unique attach that cannot create a rival consumer.
    ///
    /// Used only on the defensive path where a reservation was refused: it returns an
    /// EMPTY sequence rather than an unrestricted second consumer, because attaching a
    /// rival to a loss-critical queue would split or duplicate records
    /// (REVIEW.md G07).
    func subscribeUniqueOrEmpty() -> BoundedOrderedSequence<Element> {
        (try? subscribeUnique()) ?? makeEmptySequence()
    }

    /// A sequence that immediately ends, for a refused attach.
    private func makeEmptySequence() -> BoundedOrderedSequence<Element> {
        let channel = BoundedEventChannel<Element>(capacity: 1)
        channel.finish()
        // Attaching to a finished private channel yields an immediately-ending stream
        // with no shared queue.
        return channel.subscribe()
    }

    /// A sequence of every element this channel holds, in order, followed by
    /// stream end once `finish()` has been called and everything is delivered.
    /// Attaches without the single-consumer check.
    ///
    /// Kept for latest-state UI streams, which legitimately have several observers.
    /// REVIEW.md F07/G07 require loss-critical delivery to go through
    /// `subscribeUnique()`; the capture ticket does.
    func subscribe() -> BoundedOrderedSequence<Element> {
        lock.lock()
        let sequence = makeSubscriberLocked()
        lock.unlock()
        return sequence
    }

    /// The attach body. The caller MUST hold `lock`.
    private func makeSubscriberLocked(
        isReservedSingleConsumer: Bool = false
    ) -> BoundedOrderedSequence<Element> {
        let sequence = BoundedOrderedSequence<Element>(
            onConsumed: { [weak self] count in
                guard let self else { return }
                self.lock.lock()
                for subscriber in self.subscribers where !subscriber.isRemoved {
                    subscriber.pending = max(0, subscriber.pending - count)
                }
                let touched = self.takeLocked()
                self.lock.unlock()
                self.deliver(touched)
            },
            onTerminated: { [weak self] in
                guard let self else { return }
                self.lock.lock()
                self.subscribers.removeAll { $0.isRemoved }
                self.lock.unlock()
            },
            isReservedSingleConsumer: isReservedSingleConsumer)
        let subscriber = Subscriber(sequence: sequence)
        subscribers.append(subscriber)
        let touched = takeLocked()
        deliver(touched)
        return sequence
    }

    @discardableResult
    private func takeLocked() -> [Subscriber] {
        var touched: [Subscriber] = []
        for subscriber in subscribers where !subscriber.isRemoved {
            var moved: [Element] = []
            while subscriber.pending < capacity, !buffer.isEmpty {
                moved.append(buffer.removeFirst())
                subscriber.pending += 1
            }
            if !moved.isEmpty {
                subscriber.sequence.producerEnqueue(contentsOf: moved)
                touched.append(subscriber)
            } else if finished, !subscriber.isFinished {
                subscriber.isFinished = true
                touched.append(subscriber)
            }
        }
        return touched
    }

    private func deliver(_ touched: [Subscriber]) {
        for subscriber in touched where subscriber.isFinished {
            subscriber.sequence.producerFinish()
        }
    }
}

/// A one-shot outcome that any number of parties may read, any number of times.
///
/// REVIEW.md C01 requires that a terminal native result is *stored* rather than
/// inferred: `wait()` suspends until exactly one real outcome has been recorded
/// and then always returns that same value. There is no path that returns a
/// default or a success placeholder when nothing has arrived — callers that need
/// to distinguish "not yet" use `current`.
///
/// Ownership invariant for the narrow `@unchecked Sendable`: `state` is only
/// touched while `lock` is held.
final class TerminalOutcomeBox<Outcome: Sendable>: @unchecked Sendable {
    private struct State {
        var outcome: Outcome?
        var waiters: [CheckedContinuation<Outcome, Never>] = []
    }

    private let lock = NSLock()
    private var state = State()

    init() {}

    /// The recorded outcome, or nil while it is still unknown.
    var current: Outcome? {
        lock.lock(); defer { lock.unlock() }
        return state.outcome
    }

    var hasOutcome: Bool {
        lock.lock(); defer { lock.unlock() }
        return state.outcome != nil
    }

    /// How many consumers are currently SUSPENDED in `wait()`.
    ///
    /// Observation only — nothing in production reads it, so it is inert at runtime. It exists so
    /// a test can PROVE a waiter was installed before `record` instead of inferring it from
    /// `current == nil`, which is true whether or not any waiter has arrived.
    var installedWaiterCount: Int {
        lock.lock(); defer { lock.unlock() }
        return state.waiters.count
    }

    /// Records the single terminal outcome. Later records are ignored so the
    /// first real result wins and cannot be overwritten by a duplicate callback.
    /// Returns true when this call is the one that recorded it.
    @discardableResult
    func record(_ outcome: Outcome) -> Bool {
        lock.lock()
        guard state.outcome == nil else {
            lock.unlock()
            return false
        }
        state.outcome = outcome
        let waiters = state.waiters
        state.waiters.removeAll()
        lock.unlock()
        for waiter in waiters { waiter.resume(returning: outcome) }
        return true
    }

    /// Suspends until an outcome exists, then returns it. Safe to call from any
    /// number of consumers, before or after `record`.
    func wait() async -> Outcome {
        await withCheckedContinuation { (continuation: CheckedContinuation<Outcome, Never>) in
            lock.lock()
            if let outcome = state.outcome {
                lock.unlock()
                continuation.resume(returning: outcome)
                return
            }
            state.waiters.append(continuation)
            lock.unlock()
        }
    }
}

/// An async mutual-exclusion gate. Used for admission: only one native photo
/// request, and only one source save, may be in flight.
actor AsyncGate {
    private var isHeld = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(isHeld: Bool = false) { self.isHeld = isHeld }

    var held: Bool { isHeld }

    func acquire() async {
        if !isHeld {
            isHeld = true
            return
        }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            waiters.append(continuation)
        }
    }

    func release() {
        if waiters.isEmpty {
            isHeld = false
            return
        }
        let next = waiters.removeFirst()
        next.resume()
    }

    /// Attempts to take the gate without waiting.
    func tryAcquire() -> Bool {
        if isHeld { return false }
        isHeld = true
        return true
    }
}

/// Coalesces rapid requests so only the newest desired value is eventually
/// applied, with at most one settlement in flight (TEST_PLAN.md T04). Stale
/// completions are ignored by revision, never by arrival timing.
actor CoalescingApplier<Value: Sendable> {
    private var latestDesired: Value?
    private var isApplying = false
    /// Highest revision ever accepted. A lower revision is stale by definition
    /// and must never overwrite a newer desired value (TEST_PLAN.md T04).
    private var acceptedRevision: UInt64 = 0
    private var appliedCount = 0

    /// The number of actual apply operations performed; used by tests to prove
    /// that 100 slider updates do not become 100 device operations.
    var applyCount: Int { appliedCount }

    /// Submits a new desired value. Returns immediately; the newest revision
    /// wins, and an out-of-order (stale) revision is ignored.
    func submit(_ value: Value, revision: UInt64) {
        guard revision >= acceptedRevision else { return }
        acceptedRevision = revision
        latestDesired = value
    }

    /// Runs `apply` with the newest desired value until none remain.
    func drain(_ apply: @Sendable (Value) async -> Void) async {
        if isApplying { return }
        isApplying = true
        defer { isApplying = false }
        while let next = latestDesired {
            latestDesired = nil
            appliedCount += 1
            await apply(next)
        }
    }
}
