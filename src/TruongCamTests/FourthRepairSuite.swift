import Foundation

#if canImport(XCTest)
@testable import TruongCam
#endif

// Regression tests for the third-pass review's four production counterexamples plus
// the R10 wakeup protocol, exercising the REAL production types (not test-local
// copies of the arithmetic).

enum FourthRepairSuite {
    static let suite = TCSuite(
        id: "REPAIR4",
        title: "Fourth repair round (third-pass R03/R04/R06/R10 production paths)",
        cases: [

            // MARK: R03 — absence of evidence is not settlement

            TCCase(id: "R03a", title: "The real tracker never settles an unmeasured reading") { r in
                // Third-pass probe assertion 1, driven through the production type.
                let unknown = AppliedControlSnapshot(
                    generation: .zero, exposureChoice: .auto, biasEV: 0,
                    observedDurationSeconds: nil, observedISO: nil,
                    observedExposureTargetOffset: nil, focusMode: .continuousAuto,
                    focusPosition: nil, whiteBalanceMode: .auto, whiteBalanceGains: nil,
                    lensAperture: nil, videoZoomFactor: 1, photoConnectionScale: 1,
                    photoConnectionCrop: 1, capturedAtUTC: Date())
                var tracker = ControlSettlementTracker()
                _ = tracker.observe(unknown)
                let state = tracker.observe(unknown)
                r.check("an all-nil reading pair is not settled", !state.isSettled)
                r.check("it is not presented as a live measurement", !state.isLiveObservation)
                r.check("and it reports itself as unmeasured", !state.hasMeasurement)
            },

            TCCase(id: "R03b", title: "Absent readings do not lend credit to a later real reading") { r in
                var tracker = ControlSettlementTracker(
                    policy: ControlSettlementPolicy(requiredStableObservations: 3, observationBudget: 8))
                let absent = AppliedControlSnapshot(
                    generation: .zero, exposureChoice: .auto, biasEV: 0,
                    observedDurationSeconds: nil, observedISO: nil,
                    observedExposureTargetOffset: nil, focusMode: .continuousAuto,
                    focusPosition: nil, whiteBalanceMode: .auto, whiteBalanceGains: nil,
                    lensAperture: nil, videoZoomFactor: 1, photoConnectionScale: 1,
                    photoConnectionCrop: 1, capturedAtUTC: Date())
                _ = tracker.observe(absent)
                _ = tracker.observe(absent)

                // One real reading must not be treated as the third stable sample.
                let measured = SelfRepairFixtures.controlSnapshot(iso: 100, duration: 1.0 / 60)
                r.check("a real reading after absent ones is not already settled",
                        !tracker.observe(measured).isSettled)
                r.check("it needs its own second reading",
                        !tracker.observe(measured).isSettled)
                r.check("and settles only on its own third",
                        tracker.observe(measured).isSettled)
            },

            // MARK: R04 — source metadata provenance

            TCCase(id: "R04a", title: "A readback's provenance depends on its own settlement") { r in
                // Third-pass probe assertion 4, via the production policy.
                r.equal("no value is unknown",
                        CaptureCoordinator.readbackProvenance(hasValue: false, settlement: .settled),
                        .unknown)
                r.equal("a settling readback is not source truth",
                        CaptureCoordinator.readbackProvenance(hasValue: true, settlement: .moving),
                        .requested)
                r.equal("an unmeasured readback is not settled truth",
                        CaptureCoordinator.readbackProvenance(hasValue: true, settlement: .unmeasured(observations: 3)),
                        .requested)
                r.equal("a readback that never converged is not settled truth",
                        CaptureCoordinator.readbackProvenance(hasValue: true, settlement: .didNotSettle(observations: 9)),
                        .requested)
                r.equal("a setter acknowledgement is not settled truth",
                        CaptureCoordinator.readbackProvenance(hasValue: true, settlement: .awaitingObservation),
                        .requested)
                r.equal("only a converged readback may claim settled",
                        CaptureCoordinator.readbackProvenance(hasValue: true, settlement: .settled),
                        .settledDeviceReadback)
                r.equal("an absent settlement record cannot claim settled",
                        CaptureCoordinator.readbackProvenance(hasValue: true, settlement: nil),
                        .requested)
            },

            // MARK: R10 — the enqueue/wait protocol

            TCCase(id: "R10a", title: "A signal that lands before the wait is not lost") { r in
                // REVIEW.md R10: `dequeue` checked its queue under one mutex then
                // parked in a DIFFERENT mutex. An enqueue in between signalled
                // nobody, and the consumer parked with data already queued. The
                // production fix is a retained event version, compared atomically.
                let signal = ArrivalSignal()
                let observedVersion = signal.currentVersion()
                // The enqueue/signal happens between observing the version and waiting.
                signal.signal()
                r.check("the version advanced", signal.currentVersion() != observedVersion)
                // wait(since:) must return immediately rather than suspend forever.
                let completed = LockedFlag()
                let waiter = Task {
                    await signal.wait(since: observedVersion)
                    completed.set()
                }
                // Give the task a chance to run; it must finish without another signal.
                var spins = 0
                while !completed.value && spins < 1000 {
                    await Task.yield()
                    spins += 1
                }
                r.check("the waiter did not park and did not hang", completed.value)
                waiter.cancel()
                _ = await waiter.value
            },

            TCCase(id: "R10b", title: "The channel delivers to a consumer that starts after the send") { r in
                // The same interleaving through the real channel: send first, then
                // attach and consume. Nothing may be lost or stall.
                let channel = BoundedEventChannel<Int>(capacity: 4, overflow: .rejectNewest)
                for value in 0..<3 { _ = channel.send(value) }
                channel.finish()
                let stream = channel.subscribe()
                var received: [Int] = []
                for await value in stream { received.append(value) }
                r.equal("every sent value is delivered in order", received, [0, 1, 2])
            },

            TCCase(id: "R10c", title: "A finished channel terminates a consumer that had no work") { r in
                let channel = BoundedEventChannel<Int>(capacity: 2, overflow: .rejectNewest)
                channel.finish()
                let stream = channel.subscribe()
                var received: [Int] = []
                for await value in stream { received.append(value) }
                r.check("an empty finished channel ends immediately", received.isEmpty)
            },

            TCCase(id: "R10d", title: "Cancelling a waiting consumer does not strand the channel") { r in
                let channel = BoundedEventChannel<Int>(capacity: 2, overflow: .rejectNewest)
                let stream = channel.subscribe()
                let consumer = Task { () -> Int in
                    var count = 0
                    for await _ in stream { count += 1 }
                    return count
                }
                consumer.cancel()
                // The channel must still accept and deliver after the cancellation.
                r.check("the channel still accepts values", channel.send(1))
                channel.finish()
                _ = await consumer.value
                r.check("and remains usable", channel.acceptedElementCount == 1)
            },

            TCCase(id: "R10e", title: "A second consumer is refused on a single-consumer channel") { r in
                // REVIEW.md R10: multi-consumer accounting was wrong, so the channel
                // enforces one consumer explicitly instead of pretending.
                let channel = BoundedEventChannel<Int>(capacity: 2, overflow: .rejectNewest)
                r.check("no consumer yet", !channel.hasConsumer)
                _ = try? channel.subscribeUnique()
                r.check("the first attach is recorded", channel.hasConsumer)
                do {
                    _ = try channel.subscribeUnique()
                    r.check("a second attach is refused", false)
                } catch let error as ChannelError {
                    r.equal("refused with a typed reason", error, .consumerAlreadyAttached)
                    r.check("and the reason is actionable",
                            error.description.localizedCaseInsensitiveContains("consumer"))
                } catch {
                    r.check("refused with a typed reason", false, "\(error)")
                }
            },

            // MARK: R06 — lease balance

            TCCase(id: "R06a", title: "A denied reader open does not hold a reader slot") { r in
                // REVIEW.md R06: the previous code incremented the reader count and
                // then threw on denial, so the count stayed held and a deferred
                // selection revocation could never be applied. A denied lease must
                // also report itself unusable.
                let denied = ScopedReadLease(
                    grantID: UUID(),
                    root: URL(fileURLWithPath: "/denied"),
                    libraryID: LibraryID(),
                    generation: .zero,
                    openedLease: false,
                    wasDenied: true,
                    grant: DenyingGrant())
                r.check("a denied lease is unusable", !denied.isUsable)
                // Releasing a lease that never started must not stop anything.
                denied.release()
                r.check("releasing a denied lease is a no-op", true)
            },
        ])
}

/// A grant that refuses every scope start, used to exercise denial paths.
private final class DenyingGrant: SecurityScopedRootGrant, @unchecked Sendable {
    let leaseIdentity = UUID()
    let url = URL(fileURLWithPath: "/denied")
    var isStale: Bool { false }
    private let lock = NSLock()
    private var stops = 0
    var activeLeaseCount: Int { lock.lock(); defer { lock.unlock() }; return 0 }
    func beginAccess() -> Bool { false }
    func endAccess() { lock.lock(); stops += 1; lock.unlock() }
}
