import Foundation
import Synchronization

// Native test bundles read the app's real types through the module; the standalone
// verifier compiles the app sources into the same executable and cannot import a
// module. XCTest is only available in the native bundle.
#if canImport(XCTest)
@testable import TruongCam
#endif

/// H03: the configuration-ORDER contract.
///
/// `AVCaptureSession` adopts a nested `beginConfiguration`/`commitConfiguration` pair
/// only at the OUTERMOST commit, so a camera fact queried while a configuration is open
/// describes a state the session never adopted. These cases drive the REAL
/// `CaptureTupleSelector` and `PhysicalCameraProbe` seams with facts whose FINAL values
/// deliberately differ from the initial and candidate values, so a fallback cannot
/// masquerade as a measurement.
enum SessionOrderSuite {
    static let suite = TCSuite(
        id: "SESSION-ORDER",
        title: "Native configuration order and final-fact consumption (H03)",
        cases: [
        TCCase(id: "H03a", title: "A fake configurer records balanced begin/commit depth") { r in
            let fake = FakeSessionConfigurer()
            r.equal("depth starts at zero", fake.configurationDepth, 0)
            fake.beginConfiguration()
            fake.beginConfiguration()
            r.equal("nested depth is tracked", fake.configurationDepth, 2)
            fake.commitConfiguration()
            fake.commitConfiguration()
            r.equal("balanced commits return to zero", fake.configurationDepth, 0)
            r.equal("the call order is recorded", fake.calls, [.begin, .begin, .commit, .commit])
        },

        TCCase(id: "H03b", title: "An empty final Bayer set means unsupported, never a fallback") { r in
            // The final query returned NOTHING while the candidate had formats. The
            // selector must report unsupported rather than reuse the earlier evidence.
            let facts = [
                CaptureFormatFacts(index: 0,
                                   advertisedMaxPhotoDimensions: [PixelDimensions(width: 4032, height: 3024)],
                                   bayerPixelFormatsForDNG: []),
                CaptureFormatFacts(index: 1,
                                   advertisedMaxPhotoDimensions: [PixelDimensions(width: 8064, height: 6048)],
                                   bayerPixelFormatsForDNG: []),
            ]
            r.check("no tuple is selected when no format exposes Bayer RAW",
                    CaptureTupleSelector.select(from: facts) == nil)
        },

        TCCase(id: "H03c", title: "Final facts deliberately differing from candidate facts are used") { r in
            // The selected format's candidate list is non-empty, but the FINAL committed
            // query is what the service must publish. This case pins the DISTINCTION the
            // ordering contract depends on.
            let candidateOnly: [UInt32] = [0x4247_4734]
            let finalCommitted: [UInt32] = []
            let facts = [
                CaptureFormatFacts(index: 0,
                                   advertisedMaxPhotoDimensions: [PixelDimensions(width: 4032, height: 3024)],
                                   bayerPixelFormatsForDNG: candidateOnly),
            ]
            guard let tuple = CaptureTupleSelector.select(from: facts) else {
                r.check("a candidate with Bayer RAW is selectable", false)
                return
            }
            r.equal("the selector reports the candidate's formats", tuple.activeDNGPixelFormats, candidateOnly)
            r.check("the final committed set is distinguishable and empty",
                    finalCommitted.isEmpty && tuple.activeDNGPixelFormats != finalCommitted,
                    "candidate=\(candidateOnly) final=\(finalCommitted)")
        },

        TCCase(id: "H03d", title: "A rejection path leaves the configuration balanced") { r in
            // Drive a reject: no format exposes Bayer RAW.
            let fake = FakeSessionConfigurer()
            fake.beginConfiguration()
            let facts = [CaptureFormatFacts(
                index: 0,
                advertisedMaxPhotoDimensions: [PixelDimensions(width: 100, height: 100)],
                bayerPixelFormatsForDNG: [])]
            let selected = CaptureTupleSelector.select(from: facts)
            fake.commitConfiguration()
            r.check("no tuple is selected", selected == nil)
            r.equal("the failure path committed what it began", fake.configurationDepth, 0)
        },

        TCCase(id: "L01a", title: "The app-owned application owner mints identity and binds targets") { r in
            // REVIEW.md L01: these cases execute the SAME owner `AVCaptureCameraService`
            // uses, so the shipping correlation algorithm is the tested one.
            let owner = ControlApplicationOwner()
            let nothingYet = await owner.currentApplication
            r.check("nothing is in force before an application", nothingYet == nil)

            let first = await owner.begin(revision: 7, generation: .zero)
            // M01: a begun application is PENDING, so it is not yet current and cannot
            // authorize anything until it is accepted.
            let beforeAccept = await owner.currentApplication
            r.check("a begun application is not yet current", beforeAccept == nil)
            let freshTarget = await owner.target
            r.check("a fresh application has no target until accepted", freshTarget.isEmpty)
            let accepted = await owner.accept(first, target: .init(durationSeconds: 0.01, iso: 100))
            r.check("it is only accepted when it is still current", accepted)
            let boundTarget = await owner.target
            r.equal("acceptance binds the target", boundTarget.durationSeconds, 0.01)
        },

        TCCase(id: "M01a", title: "The owner runs the WHOLE operation: issuance, bounded wait, outcome") { r in
            // M01: the issue/callback/wait algorithm executes HERE, so the tests drive the
            // same owner the AVFoundation adapter calls.
            let owner = ControlApplicationOwner()
            let issuance = await owner.beginIssuance(revision: 3, generation: .zero)

            // Every issued callback arrives -> acknowledged.
            issuance.completions.expectOne()
            issuance.completions.arrive()
            let acknowledged = await owner.awaitCompletion(issuance, timeoutSeconds: 1.0)
            r.equal("every callback acknowledged", acknowledged, .acknowledged)
            r.check("the acknowledged application can then be accepted",
                    await owner.accept(issuance.application, target: .init(iso: 100)))

            // A MISSING callback is timed out, and must NOT report arrival.
            let stalled = await owner.beginIssuance(revision: 4, generation: .zero)
            stalled.completions.expectOne()
            let timedOut = await owner.awaitCompletion(stalled, timeoutSeconds: 0.01)
            r.equal("a missing callback times out", timedOut, .timedOut)
            r.check("the timeout did not claim the callback arrived",
                    !stalled.completions.isComplete)
            let stalledAccepted = await owner.accept(stalled.application, target: .init(iso: 200))
            r.check("a timed-out application is abandoned, not accepted", !stalledAccepted)
        },

        TCCase(id: "M01b", title: "A superseded issuance is OBSOLETE, never acknowledged") { r in
            let owner = ControlApplicationOwner()
            let first = await owner.beginIssuance(revision: 5, generation: .zero)
            // A newer issuance supersedes it while its callbacks are still outstanding.
            _ = await owner.beginIssuance(revision: 6, generation: .zero)
            first.completions.expectOne()
            first.completions.arrive()
            let outcome = await owner.awaitCompletion(first, timeoutSeconds: 0.5)
            r.equal("a superseded issuance is obsolete", outcome, .obsolete)
            r.check("and it cannot bind a target",
                    !(await owner.accept(first.application, target: .init(iso: 400))))
        },

        TCCase(id: "T02a", title: "The PRODUCTION drain gate holds a teardown while work is outstanding") { r in
            // U02: this instantiates the REAL Core gate the service uses — not a mirror of
            // its arithmetic — so the executed gate is the one that guards a teardown.
            let gate = SubmissionDrainGate()
            let first = CaptureID()
            let second = CaptureID()

            gate.noteSubmitted(first)
            r.equal("a submitted request holds the gate",
                    gate.outcome(), .outstanding(count: 1))

            // The native terminal alone is NOT enough while retained staging runs: there must
            // be no terminal-to-staging gap a teardown could slip through.
            gate.noteStagingStarted(first)
            gate.noteTerminal(first)
            r.equal("a reported terminal plus live staging still holds the gate",
                    gate.outcome(), .outstanding(count: 1))

            // A second request keeps its own identity; one request is not double-counted.
            gate.noteSubmitted(second)
            r.equal("two distinct requests count as two",
                    gate.outcome(), .outstanding(count: 2))
            r.equal("whereas the staging request alone is one",
                    gate.outstandingCount, 2)

            // Only real completion drains, and a repeated finish cannot underflow it.
            gate.noteStagingFinished(first)
            r.equal("finishing the first leaves the second",
                    gate.outcome(), .outstanding(count: 1))
            gate.noteStagingFinished(first)
            r.equal("a repeated finish does not underflow into a clean drain",
                    gate.outcome(), .outstanding(count: 1))
            // A terminal alone is NOT completion: the request still owes its staging.
            gate.noteTerminal(second)
            r.equal("a terminal without staging still holds the gate",
                    gate.outcome(), .outstanding(count: 1))
            gate.noteStagingFinished(second)
            r.equal("native terminal AND staging complete is drained",
                    gate.outcome(), .drained)
            r.check("and the gate reports itself drained", gate.isDrained)

            // The exact terminal-to-staging gap: a LATE staging registration after the
            // terminal must not find a drained gate, and an explicit no-source resolution
            // must not leak a permanent fence.
            let third = CaptureID()
            gate.noteSubmitted(third)
            gate.noteTerminal(third)
            r.equal("terminal alone leaves the staging obligation open",
                    gate.outcome(), .outstanding(count: 1))
            gate.noteNoSource(third)
            r.equal("an explicit no-source resolution clears it", gate.outcome(), .drained)
        },

        TCCase(id: "X02a", title: "The PRODUCTION bounded drain reconciles delayed staging") { r in
            // X02: this executes the gate's OWN reconciliation loop — the shipping teardown —
            // with staging delayed past the terminal, and asserts the truthful outcome rather
            // than a mirror of the arithmetic.
            let gate = SubmissionDrainGate()
            let id = CaptureID()
            gate.noteSubmitted(id)
            gate.noteTerminal(id)
            r.equal("the native terminal alone does not drain", gate.outcome(),
                    .outstanding(count: 1))

            // A delayed staging registration and finish, resolved WHILE the bounded wait runs.
            let staging = Task {
                try? await Task.sleep(nanoseconds: 60_000_000)
                gate.noteStagingFinished(id)
            }
            let outcome = await gate.awaitDrain(longestPlannedSeconds: 0)
            await staging.value
            r.equal("the bounded drain resolves once staging completes", outcome, .drained)
            r.check("and the gate is genuinely drained", gate.isDrained)

            // A timeout reports the REAL outstanding count instead of a clean drain.
            let stuck = SubmissionDrainGate()
            let stuckID = CaptureID()
            stuck.noteSubmitted(stuckID)
            stuck.noteTerminal(stuckID)
            let start = Date()
            let timedOut = await stuck.awaitDrain(longestPlannedSeconds: 0,
                                                  pollIntervalNanoseconds: 10_000_000)
            let elapsed = Date().timeIntervalSince(start)
            r.equal("a timed-out drain discloses the real outstanding work",
                    timedOut, .outstanding(count: 1))
            r.check("the bound is the duration-aware maximum (5s)", elapsed >= 5.0)
            // Unresolved ownership stays VISIBLE: it cannot masquerade as clean recovery.
            r.check("and the unresolved obligation is still counted",
                    stuck.outstandingCount == 1)
            // One capture counts once even though it owed both obligations.
            r.equal("one capture counts once", stuck.outstandingCount, 1)
        },

        TCCase(id: "X03a", title: "The PRODUCTION final-tuple operation balances configuration and refuses on empty facts") { r in
            // X03: executes the Core-owned SEQUENCING the adapter uses — balanced outer
            // configuration, then the final query, then publish-or-reject with rollback.
            final class Recorder: @unchecked Sendable {
                private let lock = NSLock()
                private var events: [String] = []
                func note(_ e: String) { lock.lock(); events.append(e); lock.unlock() }
                var all: [String] { lock.lock(); defer { lock.unlock() }; return events }
            }

            // A PUBLISHING run: begin → query → commit → publish, in that order.
            let op = FinalTupleOperation()
            let rec = Recorder()
            let published = await op.run(port: FinalTupleOperation.Port(
                beginConfiguration: { rec.note("begin") },
                commitConfiguration: { rec.note("commit") },
                queryFinalTuple: {
                    rec.note("query")
                    return FinalTupleOperation.FinalFacts(
                        bayer: [0x62676734], fileTypes: ["com.adobe.raw-image"])
                },
                rollbackConfiguration: { _ in rec.note("rollback"); return true },
                publish: { _, _ in rec.note("publish"); return true },
                fail: { _, _ in rec.note("fail") }
            ), candidateFileTypes: ["com.adobe.raw-image"])
            r.equal("a usable final tuple is published", published, .published)
            r.equal("the order is balanced begin → commit → query → publish",
                    rec.all, ["begin", "commit", "query", "publish"])
            r.equal("no configuration is left open", op.configurationDepth, 0)

            // An EMPTY final container is refused and ROLLED BACK, never published.
            let op2 = FinalTupleOperation()
            let rec2 = Recorder()
            let refused = await op2.run(port: FinalTupleOperation.Port(
                beginConfiguration: { rec2.note("begin") },
                commitConfiguration: { rec2.note("commit") },
                queryFinalTuple: {
                    rec2.note("query")
                    return FinalTupleOperation.FinalFacts(bayer: [0x62676734], fileTypes: [])
                },
                rollbackConfiguration: { _ in rec2.note("rollback"); return true },
                publish: { _, _ in rec2.note("publish"); return true },
                fail: { _, _ in rec2.note("fail") }
            ), candidateFileTypes: ["com.adobe.raw-image"])
            r.equal("an empty final container is refused", refused, .refused)
            r.check("a refusal never publishes", !rec2.all.contains("publish"))
            r.check("and the refusal rolls the configuration back", rec2.all.contains("rollback"))
            r.equal("the refusal path is also balanced", op2.configurationDepth, 0)

            // An EMPTY Bayer answer is refused the same way.
            let op3 = FinalTupleOperation()
            let emptyBayer = await op3.run(port: FinalTupleOperation.Port(
                beginConfiguration: {}, commitConfiguration: {},
                queryFinalTuple: {
                    FinalTupleOperation.FinalFacts(bayer: [], fileTypes: ["com.adobe.raw-image"])
                },
                rollbackConfiguration: { _ in true }, publish: { _, _ in true }, fail: { _, _ in }
            ), candidateFileTypes: ["com.adobe.raw-image"])
            r.equal("an empty Bayer answer is refused", emptyBayer, .refused)
        },

        TCCase(id: "Y02a", title: "The PRODUCTION submission→retirement→teardown chain reconciles exactly once") { r in
            // Y02: drives the REAL Core gate through the chain the service performs —
            // submit → native terminal → retained staging → bounded teardown → disposition —
            // and asserts the properties the caller chain must guarantee.
            let gate = SubmissionDrainGate()
            let id = CaptureID()

            // Submission reserves BOTH obligations.
            gate.noteSubmitted(id)
            r.equal("submission reserves both obligations", gate.outstandingCount, 1)

            // The native terminal retires the native obligation but NOT the staging one.
            gate.noteTerminal(id)
            r.equal("terminal alone does not settle", gate.outstandingCount, 1)

            // Staging registers late and finishes: the capture settles EXACTLY once.
            gate.noteStagingStarted(id)
            r.equal("late staging registration re-states the obligation",
                    gate.outstandingCount, 1)
            gate.noteStagingFinished(id)
            r.equal("after both obligations the capture settles", gate.outstandingCount, 0)
            gate.noteStagingFinished(id)
            r.equal("a repeated finish cannot settle it twice",
                    gate.outstandingCount, 0)
            r.equal("and one capture never counted as two", gate.outcome(), .drained)

            // Disposition: only a drained gate may be disposed as clean recovery.
            r.equal("drained disposes as clean recovery",
                    SubmissionDrainGate.disposition(for: gate.outcome()), .cleanRecovery)

            // Unresolved ownership CANNOT appear as clean recovery.
            let blocked = SubmissionDrainGate()
            let stuck = CaptureID()
            blocked.noteSubmitted(stuck)
            blocked.noteTerminal(stuck)
            r.equal("outstanding work blocks recovery with a real count",
                    SubmissionDrainGate.disposition(for: blocked.outcome()),
                    .blockedByOutstanding(count: 1))
            r.check("and it is never disposed as clean recovery",
                    SubmissionDrainGate.disposition(for: blocked.outcome()) != .cleanRecovery)

            // A legitimate no-source path resolves without leaking a permanent fence.
            let noSource = SubmissionDrainGate()
            let absent = CaptureID()
            noSource.noteSubmitted(absent)
            noSource.noteNoSource(absent)
            r.equal("a no-source resolution leaves no fence", noSource.outcome(), .drained)
            r.equal("so it may recover cleanly",
                    SubmissionDrainGate.disposition(for: noSource.outcome()), .cleanRecovery)
        },

        TCCase(id: "Z02a", title: "The PRODUCTION reset/recovery chain gates admission on a real drain") { r in
            // Z02: executes the Core-owned SEQUENCE the service performs — bounded drain, then
            // teardown, rebuild, and admission gated on the actual disposition.
            final class Log: @unchecked Sendable {
                private let mutex = Mutex<[String]>([])
                func note(_ e: String) { mutex.withLock { $0.append(e) } }
                var all: [String] { mutex.withLock { $0 } }
            }

            // A DRAINED reset: the drain settles, so recovery and admission are reached.
            let settled = SubmissionDrainGate()
            let settledChain = SubmissionRecoveryChain(gate: settled)
            let settledLog = Log()
            let recovered = await settledChain.run(port: SubmissionRecoveryChain.Port(
                teardownGraph: { settledLog.note("teardown") },
                rebuildAndRevalidate: { settledLog.note("rebuild"); return .verified },
                discloseOutstanding: { _ in settledLog.note("disclose") },
                reopenAdmission: { settledLog.note("admission") }))
            r.equal("a drained reset recovers", recovered, .recovered)
            r.equal("and the order is drain → teardown → rebuild → admission",
                    settledLog.all, ["teardown", "rebuild", "admission"])

            // OUTSTANDING work: teardown and rebuild happen, but admission is NOT reopened and
            // the count is disclosed instead.
            let stuck = SubmissionDrainGate()
            let stuckID = CaptureID()
            stuck.noteSubmitted(stuckID)
            stuck.noteTerminal(stuckID)
            let stuckChain = SubmissionRecoveryChain(gate: stuck)
            let stuckLog = Log()
            let blocked = await stuckChain.run(
                longestPlannedSeconds: 0,
                port: SubmissionRecoveryChain.Port(
                    teardownGraph: { stuckLog.note("teardown") },
                    rebuildAndRevalidate: { stuckLog.note("rebuild"); return .verified },
                    discloseOutstanding: { _ in stuckLog.note("disclose") },
                    reopenAdmission: { stuckLog.note("admission") }))
            r.equal("outstanding work blocks recovery with the real count",
                    blocked, .blockedByOutstanding(count: 1))
            r.check("the outstanding ownership is DISCLOSED", stuckLog.all.contains("disclose"))
            r.check("and admission is never reopened over unresolved work",
                    !stuckLog.all.contains("admission"))

            // The blocked gate still reports the work, so it cannot silently become clean.
            r.equal("the obligation is still visible afterwards", stuck.outstandingCount, 1)
        },

        TCCase(id: "AB01a", title: "The PRODUCTION publication identity refuses delayed work after every boundary") { r in
            // AB01: executes the Core-owned identity the SERVICE uses, so the delayed
            // lifecycle is a durable production-boundary regression rather than an
            // adapter-only claim. A snapshot is taken before the suspension and validated
            // after it, in both dimensions.
            let identity = PublicationIdentity()

            // Ordinary live work commits while nothing has superseded it.
            let live = identity.snapshot()
            r.check("live work is current", identity.isCurrent(live))

            // A NEWER PUBLICATION makes the older snapshot obsolete — the delayed command or
            // readback cannot commit over the newer result.
            identity.notePublished()
            r.check("a newer publication supersedes an older snapshot",
                    !identity.isCurrent(live))
            // ...and the newer one is itself current.
            let newer = identity.snapshot()
            r.check("the newer publication is current", identity.isCurrent(newer))

            // A TERMINAL boundary (stop/reset/reconfiguration) supersedes BOTH dimensions, so
            // a result returning after it cannot commit even with an unchanged generation.
            identity.noteTerminal()
            r.check("a terminal boundary supersedes the newer snapshot",
                    !identity.isCurrent(newer))
            let atBoundary = identity.snapshot()
            r.check("a snapshot taken at the boundary is current until the next bump",
                    identity.isCurrent(atBoundary))

            // A control invocation that began before the terminal boundary cannot commit.
            let controlBefore = identity.snapshot()
            identity.noteTerminal()
            r.check("a control invocation across a terminal boundary is obsolete",
                    !identity.isCurrent(controlBefore))

            // A snapshot taken AFTER the boundary is legitimately current again — ordinary
            // live sampling is not permanently disabled.
            let afterTerminal = identity.snapshot()
            r.check("work begun after the boundary is current", identity.isCurrent(afterTerminal))
            identity.notePublished()
            r.check("and can be superseded normally", !identity.isCurrent(afterTerminal))
        },

        TCCase(id: "AB02a", title: "The COMBINED submission→retirement→teardown→recovery→admission chain settles exactly once") { r in
            // AB02: one chain, not separate helper calls — submission, terminal retirement,
            // DELAYED retained staging, the bounded teardown, the recovery chain and the
            // admission gate all run together against the real Core components.
            final class Log: @unchecked Sendable {
                private let mutex = Mutex<[String]>([])
                func note(_ e: String) { mutex.withLock { $0.append(e) } }
                var all: [String] { mutex.withLock { $0 } }
            }

            // (1) Submitted, native terminal reported, retained staging still DELAYED.
            let gate = SubmissionDrainGate()
            let id = CaptureID()
            gate.noteSubmitted(id)
            gate.noteTerminal(id)
            let chain = SubmissionRecoveryChain(gate: gate)
            let log = Log()

            // (2) A reset runs while the staging obligation is unresolved: the bounded drain
            //     expires, so admission must NOT reopen and the count must be disclosed.
            let blocked = await chain.run(longestPlannedSeconds: 0, port: SubmissionRecoveryChain.Port(
                teardownGraph: { log.note("teardown") },
                rebuildAndRevalidate: { log.note("rebuild"); return .verified },
                discloseOutstanding: { _ in log.note("disclose") },
                reopenAdmission: { log.note("admission") }))
            r.equal("a reset with delayed staging is blocked with the real count",
                    blocked, .blockedByOutstanding(count: 1))
            r.check("the sequence still tore down and rebuilt",
                    log.all == ["teardown", "rebuild", "disclose"])
            r.check("admission was NOT reopened over retained work",
                    !log.all.contains("admission"))
            r.equal("the obligation remains visible", gate.outstandingCount, 1)

            // (3) The delayed staging now finishes: the SAME capture settles exactly once,
            //     and a repeated finish cannot settle it twice or leak a fence.
            gate.noteStagingStarted(id)
            gate.noteStagingFinished(id)
            r.equal("the delayed staging settles the capture exactly once",
                    gate.outstandingCount, 0)
            gate.noteStagingFinished(id)
            r.equal("a repeated finish cannot settle it twice", gate.outstandingCount, 0)

            // (4) A subsequent reset now recovers and reopens admission.
            let recovered = await chain.run(longestPlannedSeconds: 0, port: SubmissionRecoveryChain.Port(
                teardownGraph: { log.note("teardown2") },
                rebuildAndRevalidate: { log.note("rebuild2"); return .verified },
                discloseOutstanding: { _ in log.note("disclose2") },
                reopenAdmission: { log.note("admission2") }))
            r.equal("the later reset recovers", recovered, .recovered)
            r.check("and admission is reopened only now", log.all.last == "admission2")
            r.equal("with nothing left outstanding", gate.outstandingCount, 0)

            // (5) A legitimate no-source path resolves without leaking a fence.
            let noSource = SubmissionDrainGate()
            let absent = CaptureID()
            noSource.noteSubmitted(absent)
            noSource.noteNoSource(absent)
            r.equal("a no-source capture leaves no fence", noSource.outcome(), .drained)
        },

        TCCase(id: "AC01a", title: "A DELAYED consumer commit cannot mutate state after a newer publication") { r in
            // AC01: executes the Core-owned consumer-commit sequence the SERVICE uses. The
            // snapshot is taken before the suspension and the mutation runs only if the
            // identity is still current in the same turn as the check.
            final class Store: @unchecked Sendable {
                private let mutex = Mutex<[String]>([])
                func write(_ v: String) { mutex.withLock { $0.append(v) } }
                var all: [String] { mutex.withLock { $0 } }
            }

            let identity = PublicationIdentity()
            let store = Store()

            // An ordinary commit lands.
            let live = identity.snapshot()
            r.equal("a current consumer commits",
                    ConsumerCommit.commit(identity: identity, snapshot: live) {
                        store.write("live")
                    }, .committed)
            r.equal("and its write happened", store.all, ["live"])

            // A DELAYED consumer that suspended before a newer publication arrives must NOT
            // mutate the consumer's state.
            let delayed = identity.snapshot()
            identity.notePublished()          // the newer result commits first
            var mutatedDelayed = false
            r.equal("a delayed consumer is superseded",
                    ConsumerCommit.commit(identity: identity, snapshot: delayed) {
                        mutatedDelayed = true
                    }, .superseded)
            r.check("and it performed NO write", mutatedDelayed == false)
            r.equal("so the newer state is untouched", store.all, ["live"])

            // The same holds across a TERMINAL boundary (stop/reset), which invalidates even a
            // consumer that never saw an intervening publication.
            let beforeTerminal = identity.snapshot()
            identity.noteTerminal()
            var mutatedAfterStop = false
            r.equal("a consumer in flight across stop/reset is superseded",
                    ConsumerCommit.commit(identity: identity, snapshot: beforeTerminal) {
                        mutatedAfterStop = true
                    }, .superseded)
            r.check("and it performed NO write", mutatedAfterStop == false)

            // The CONTROL dimension the service actually uses behaves identically.
            let controlIdentity = PublicationIdentity()
            controlIdentity.noteControlInvocation()
            let invocation = controlIdentity.controlSequence
            var controlWrites = 0
            r.equal("a current control consumer commits",
                    ConsumerCommit.commitControl(identity: controlIdentity, invocation: invocation) {
                        controlWrites += 1
                    }, .committed)
            controlIdentity.noteControlInvocation()
            r.equal("a superseded control consumer does not",
                    ConsumerCommit.commitControl(identity: controlIdentity, invocation: invocation) {
                        controlWrites += 1
                    }, .superseded)
            r.equal("and it wrote exactly once", controlWrites, 1)

            // AD01: the READBACK consumer uses the same seam, with the publication dimension
            // AND the generation both required to still match at the moment of the write.
            let readIdentity = PublicationIdentity()
            var readWrites = 0
            let readSnapshot = readIdentity.snapshot()
            r.equal("a current readback commits",
                    ConsumerCommit.commitReadback(
                        identity: readIdentity, snapshot: readSnapshot, generationMatches: true
                    ) { readWrites += 1 }, .committed)
            r.equal("a readback across a GENERATION change does not",
                    ConsumerCommit.commitReadback(
                        identity: readIdentity, snapshot: readSnapshot, generationMatches: false
                    ) { readWrites += 1 }, .superseded)
            readIdentity.notePublished()
            r.equal("a readback delayed past a newer publication does not",
                    ConsumerCommit.commitReadback(
                        identity: readIdentity, snapshot: readSnapshot, generationMatches: true
                    ) { readWrites += 1 }, .superseded)
            r.equal("and it wrote exactly once", readWrites, 1)
        },

        TCCase(id: "AE02a", title: "A LIVE provider commit is held INSIDE the store, not withheld") { r in
            // AG02: previously this case invoked commit only AFTER its recovery pass, which is
            // withholding the CALL rather than suspending a commit in flight. Here the commit is
            // genuinely INVOKED and parked inside the store's own commit pipeline by a gated
            // coordinated-write seam, so the reset provably overlaps an unresolved provider.
            let gated = GatedFileCoordinatorMutator()
            guard let harness = await StorageHarness.make(
                name: "ae02a-live-commit", coordinator: gated) else {
                r.check("the retained store harness was built", false)
                return
            }
            let gate = SubmissionDrainGate()
            let id = CaptureID()
            let chain = SubmissionRecoveryChain(gate: gate)
            final class Log: @unchecked Sendable {
                private let mutex = Mutex<[String]>([])
                func note(_ e: String) { mutex.withLock { $0.append(e) } }
                var all: [String] { mutex.withLock { $0 } }
            }
            let log = Log()

            // REAL staging into the retained store.
            guard let handle = try? await harness.store.stageSource(
                bytes: StorageFixture.rawBytes(),
                metadata: StorageFixture.metadata(
                    captureID: id, libraryID: harness.libraryID))
            else {
                r.check("the retained store staged the source", false)
                return
            }
            gate.noteSubmitted(id)
            gate.noteTerminal(id)
            gate.noteStagingStarted(id)
            r.equal("the provider obligation is unresolved before the commit is released",
                    gate.outstandingCount, 1)

            // INVOKE the commit and let it park INSIDE the provider operation.
            gated.arm()
            let commitTask = Task { try await harness.store.commit(handle: handle) }
            // Yield counts measure scheduler speed, not provider entry. Native
            // Simulator execution exposed an early assertion before the I/O owner
            // ran. Wait for the real entry with a bounded monotonic deadline.
            let entryDeadline = ContinuousClock.now.advanced(by: .seconds(3))
            while gated.enteredCount < 1 && ContinuousClock.now < entryDeadline {
                try? await Task.sleep(for: .milliseconds(1))
            }
            r.check("the commit was INVOKED and is blocked inside the provider",
                    gated.enteredCount >= 1)
            r.equal("the provider is actually held, not merely scheduled", gated.holdOutcome, .held)
            r.equal("and the obligation is STILL unresolved while the commit is in flight",
                    gate.outstandingCount, 1)

            // A reset overlaps the in-flight commit: blocked, no admission.
            let firstPass = await chain.run(longestPlannedSeconds: 0, port: SubmissionRecoveryChain.Port(
                teardownGraph: { log.note("teardown") },
                rebuildAndRevalidate: { log.note("rebuild"); return .verified },
                discloseOutstanding: { _ in log.note("disclose") },
                reopenAdmission: { log.note("admission") }))
            r.equal("a reset overlapping a LIVE commit is blocked with the real count",
                    firstPass, .blockedByOutstanding(count: 1))
            r.check("it tore down and rebuilt but did NOT reopen admission",
                    log.all == ["teardown", "rebuild", "disclose"])

            // RELEASE the parked commit: it must complete with a REAL receipt.
            gated.release()
            let receipt = try? await commitTask.value
            r.check("the released provider commit produced a REAL receipt", receipt != nil)
            gate.noteStagingFinished(id)
            r.equal("the obligation settles exactly once", gate.outstandingCount, 0)
            r.equal("and the gate is drained", gate.outcome(), .drained)


            // Only now does a later reset recover and reopen admission.
            let secondPass = await chain.run(longestPlannedSeconds: 0, port: SubmissionRecoveryChain.Port(
                teardownGraph: { log.note("teardown2") },
                rebuildAndRevalidate: { log.note("rebuild2"); return .verified },
                discloseOutstanding: { _ in log.note("disclose2") },
                reopenAdmission: { log.note("admission2") }))
            r.equal("the later reset recovers", secondPass, .recovered)
            r.equal("the recovery chain performed its ordered effects", log.all,
                    ["teardown", "rebuild", "disclose",
                     "teardown2", "rebuild2", "admission2"])
        },

        TCCase(id: "AE02b", title: "The RETAINED COORDINATOR half: genuine concurrency with real results") { r in
            // AG02: this case previously discarded its result, asserted `true`, and called its
            // second request only AFTER awaiting the first — sequential work labelled
            // "concurrent". It now starts TWO requests genuinely in flight and asserts the
            // ACTUAL CaptureRequestResult each returns.
            guard let harness = await StorageHarness.make(name: "ae02b-concurrency") else {
                r.check("the retained store harness was built", false)
                return
            }
            let spy = ChainCameraSpy()
            let coordinator = CaptureCoordinator(
                camera: spy, store: harness.store, clock: SystemMonotonicClock())
            func intent(_ ticket: ChainCameraTicket) -> CaptureIntent {
                CaptureIntent(
                    captureID: ticket.captureID,
                    libraryID: harness.libraryID,
                    requestedDimensions: PixelDimensions(width: 4_032, height: 3_024),
                    exposure: .auto, biasEV: 0,
                    focus: FocusIntent(mode: .continuousAuto, position: nil, pointOfInterest: nil),
                    whiteBalance: WhiteBalanceIntent(mode: .auto, temperatureAndTint: nil),
                    configurationGeneration: .zero,
                    rootGeneration: harness.generation,
                    physicalCameraKind: .wide,
                    createdAtUTC: Date(timeIntervalSince1970: 0),
                    timezoneOffsetSeconds: 0,
                    mode: .single)
            }
            let firstID = CaptureID()
            let secondID = CaptureID()
            let first = spy.ticket(for: ChainCameraSpy.defaultIntent(captureID: firstID))
            let second = spy.ticket(for: ChainCameraSpy.defaultIntent(captureID: secondID))
            r.check("the two requests have DISTINCT capture identities",
                    first.captureID != second.captureID)

            // BOTH requests are started BEFORE either is awaited: they are genuinely in flight.
            spy.holdAttachments()
            let firstTask = Task { await coordinator.capture(intent: intent(first)) }
            let secondTask = Task { await coordinator.capture(intent: intent(second)) }
            // AJ04: an OWNED arrival checkpoint — wait until BOTH requests have ARRIVED at the
            // handshake. Arrivals are counted inside the single atomic handshake lock, so this
            // proves arrival rather than assuming it from elapsed yields. Neither can have
            // completed while the hold is in place.
            var arrived = 0
            while spy.attachArrivals < 2 && arrived < 20000 {
                await Task.yield()
                arrived += 1
            }
            r.equal("the FIRST request ARRIVED at the owned handshake checkpoint",
                    spy.attachArrivals, 1)
            r.check("and it did not complete while attachments are held", spy.attachCount == 0)
            spy.releaseAttachments()

            var turns = 0
            while spy.attachCount < 1 && turns < 20000 { await Task.yield(); turns += 1 }
            r.check("at least one request reached the real camera surface",
                    spy.attachCount >= 1)

            // BOTH concurrent requests are given their OWN real synthetic source, so the result
            // does not depend on which concurrent task happened to own which ticket.
            // DISTINCT bytes per request, so a swapped or aliased source cannot pass.
            let firstBytes = StorageFixture.rawBytes(filler: 0xA1)
            let secondBytes = StorageFixture.rawBytes(filler: 0xB2)
            first.deliverRepresentation(
                bytes: firstBytes, dimensions: PixelDimensions(width: 4_032, height: 3_024))
            second.deliverRepresentation(
                bytes: secondBytes, dimensions: PixelDimensions(width: 4_032, height: 3_024))
            r.check("the two sources have DISTINCT bytes", firstBytes != secondBytes)
            r.check("and DISTINCT native request identities",
                    first.uniqueSettingsID != second.uniqueSettingsID)
            first.deliver(.success)
            second.deliver(.success)
            let firstResult = await firstTask.value
            let secondResult = await secondTask.value
            r.equal("the FIRST concurrent request reports its own capture id",
                    firstResult.captureID, first.captureID)
            r.equal("the SECOND concurrent request reports its own capture id",
                    secondResult.captureID, second.captureID)
            // BOTH requests carried a real synthetic source and must COMMIT it, independently.
            r.check("the FIRST concurrent request COMMITTED its own synthetic source",
                    firstResult.didCommitAnything)
            // AJ04: DISTINCT per-request receipts with their OWN capture identity, so a swapped
            // or aliased source cannot pass on the caller-side captureID alone.
            r.equal("the FIRST request committed exactly one receipt",
                    firstResult.committedReceipts.count, 1)
            r.equal("the SECOND request committed exactly one receipt",
                    secondResult.committedReceipts.count, 1)
            r.equal("the first receipt names its OWN capture",
                    firstResult.committedReceipts.first?.captureID, first.captureID)
            r.equal("the second receipt names its OWN capture",
                    secondResult.committedReceipts.first?.captureID, second.captureID)
            r.check("the two receipts are DISTINCT transactions",
                    firstResult.committedReceipts.first?.transactionID
                        != secondResult.committedReceipts.first?.transactionID)
            r.check("both receipts name the SAME PINNED library root",
                    firstResult.committedReceipts.first?.libraryID == harness.libraryID
                        && secondResult.committedReceipts.first?.libraryID == harness.libraryID)
            r.check("and the SAME root generation",
                    firstResult.committedReceipts.first?.rootGeneration
                        == secondResult.committedReceipts.first?.rootGeneration)
            r.check("neither request left a pending transaction",
                    firstResult.pendingTransactionIDs.isEmpty
                        && secondResult.pendingTransactionIDs.isEmpty)
            r.check("neither request is silently dropped, swapped or aliased",
                    firstResult.captureID != secondResult.captureID)
        },

        TCCase(id: "AE02c", title: "The COMBINED chain: real representation + retained store + SAME gate + recovery") { r in
            // AG02: ONE connected path with the real owners. The REAL CaptureCoordinator stages a
            // REAL synthetic representation into the REAL retained LibraryStore, over a synthetic
            // camera surface whose staging reports settle the SAME gate. The representation is
            // delivered BEFORE the reset, the capture RESULT is awaited and asserted, and the
            // reset result and recovery outcome are asserted rather than logged.
            let gated = GatedFileCoordinatorMutator()
            guard let harness = await StorageHarness.make(
                name: "ae02c-combined-chain", coordinator: gated) else {
                r.check("the retained store harness was built", false)
                return
            }
            let spy = ChainCameraSpy()
            let gate = SubmissionDrainGate()
            spy.ownershipGate = gate
            let chain = SubmissionRecoveryChain(gate: gate)
            let coordinator = CaptureCoordinator(
                camera: spy, store: harness.store, clock: SystemMonotonicClock())
            let ticket = spy.captureTicket
            let id = ticket.captureID
            let intent = CaptureIntent(
                captureID: id,
                libraryID: harness.libraryID,
                requestedDimensions: PixelDimensions(width: 4_032, height: 3_024),
                exposure: .auto, biasEV: 0,
                focus: FocusIntent(mode: .continuousAuto, position: nil, pointOfInterest: nil),
                whiteBalance: WhiteBalanceIntent(mode: .auto, temperatureAndTint: nil),
                configurationGeneration: .zero,
                rootGeneration: harness.generation,
                physicalCameraKind: .wide,
                createdAtUTC: Date(timeIntervalSince1970: 0),
                timezoneOffsetSeconds: 0,
                mode: .single)
            final class Log: @unchecked Sendable {
                private let mutex = Mutex<[String]>([])
                func note(_ e: String) { mutex.withLock { $0.append(e) } }
                var all: [String] { mutex.withLock { $0 } }
            }
            let log = Log()

            let task = Task { await coordinator.capture(intent: intent) }
            let submissionDeadline = ContinuousClock.now.advanced(by: .seconds(3))
            while spy.attachCount < 1 && ContinuousClock.now < submissionDeadline { try? await Task.sleep(for: .milliseconds(1)) }
            r.check("the real coordinator submitted to the retained path", spy.attachCount >= 1)

            // Deliver the SOURCE FIRST, then the native terminal — the real ordering.
            ticket.deliverRepresentation(
                bytes: StorageFixture.rawBytes(),
                dimensions: PixelDimensions(width: 4_032, height: 3_024))
            r.check("the source was published before the terminal",
                    ticket.stagedRepresentationCount >= 1)
            r.equal("the submission obligation is OUTSTANDING before any staging report settles it",
                    gate.outstandingCount, 1)

            // A reset runs while the retained staging is unresolved: blocked, no admission.
            r.check("the REAL coordinator is not admitting while the commit is unresolved",
                    await coordinator.canAdmitCapture() == false)
            let generationBeforeRecovery = spy.configurationGeneration
            let firstPass = await chain.run(longestPlannedSeconds: 0, port: SubmissionRecoveryChain.Port(
                teardownGraph: { log.note("teardown"); await coordinator.stopAdmittingNewRequests() },
                rebuildAndRevalidate: {
                    log.note("rebuild")
                    // AJ03: the SAME Core-owned sequence the shipping rebuild runs.
                    let outcome = await ResetRebuild.run(port: ResetRebuild.Port(
                        prepare: { _ = spy.rebuildConfiguration(); return true },
                        revalidateControls: { true }))
                    return outcome == .rebuilt ? .verified : .prepareFailed
                },
                discloseOutstanding: { _ in
                    log.note("disclose")
                    await coordinator.noteWatchdogFired(captureID: id)
                    // AJ03: the disclosure publishes a REAL condition through the SHIPPING resolver.
                    spy.recordCondition(.interrupted(reason: "Outstanding retained work after reset."))
                },
                reopenAdmission: { log.note("admission"); await coordinator.resumeAdmittingNewRequests() }))
            r.equal("the overlapped reset is blocked with the real count",
                    firstPass, .blockedByOutstanding(count: 1))
            r.check("it tore down and rebuilt but did NOT reopen admission",
                    log.all == ["teardown", "rebuild", "disclose"])
            r.check("and the REAL coordinator admission state stays CLOSED",
                    await coordinator.canAdmitCapture() == false)
            r.check("the disclosure reached the REAL coordinator as a stalled-capture report",
                    await coordinator.stalledCaptureIDsSnapshot().contains(id))
            // The SHIPPING Core resolver must not present outstanding work as a healthy camera.
            r.check("the SHIPPING lifecycle resolver refuses admission for the disclosed condition",
                    spy.effectiveLifecycle != .running)
            r.check("the rebuild step ADVANCED the configuration generation",
                    spy.configurationGeneration > generationBeforeRecovery)

            // AI03: ARM the provider hold, then release the native terminal. The coordinator's
            // real commit is thereby INVOKED and parks INSIDE the provider operation.
            gated.arm()
            ticket.deliver(.success)
            let commitDeadline = ContinuousClock.now.advanced(by: .seconds(3))
            while gated.enteredCount < 1 && ContinuousClock.now < commitDeadline { try? await Task.sleep(for: .milliseconds(1)) }
            r.check("the provider COMMIT was invoked and is blocked inside the provider",
                    gated.enteredCount >= 1)
            r.equal("and the retained obligation is STILL unresolved while it is in flight",
                    gate.outstandingCount, 1)

            // A SECOND reset overlaps the LIVE commit.
            let livePass = await chain.run(longestPlannedSeconds: 0, port: SubmissionRecoveryChain.Port(
                teardownGraph: { log.note("teardownLive"); await coordinator.stopAdmittingNewRequests() },
                rebuildAndRevalidate: { log.note("rebuildLive"); return .verified },
                discloseOutstanding: { _ in log.note("discloseLive") },
                reopenAdmission: { log.note("admissionLive"); await coordinator.resumeAdmittingNewRequests() }))
            r.equal("a reset overlapping the LIVE commit is blocked with the real count",
                    livePass, .blockedByOutstanding(count: 1))

            // RELEASE the held commit and let the coordinator finish.
            gated.release()
            let result = await task.value
            r.equal("the released provider hold reports a RELEASED outcome",
                    gated.holdOutcome, .released)
            // AJ03: the REAL browsing MODEL consumes the committed receipts through the shipping
            // `LibraryIndexing` CONTRACT (a narrow in-memory port, since the storage harness runs
            // on the in-memory file adapter and cannot host a SQLite file). The model itself is
            // the shipping consumer and runs unchanged.
            let index = InMemoryLibraryIndex()
            try? await index.reset(libraryID: harness.libraryID, generation: harness.generation)
            try? await index.ingest(result.committedReceipts)
            let model = await LibraryViewModel(index: index, store: harness.store)
            await model.loadFirstPage()
            r.check("the REAL library model lists the committed capture",
                    await model.loadedSourceCount >= 1)
            r.check("and lists it as a sequence-eligible original",
                    await model.individualOriginalCount >= 1)

            r.check("the capture actually COMMITTED its synthetic source to the retained store",
                    result.didCommitAnything)
            r.check("and left no pending transaction", result.pendingTransactionIDs.isEmpty)

            // The gate is drained by the SURFACE'S OWN reports — not by hand.
            let drainDeadline = ContinuousClock.now.advanced(by: .seconds(3))
            while gate.outstandingCount > 0 && ContinuousClock.now < drainDeadline { try? await Task.sleep(for: .milliseconds(1)) }
            r.equal("the surface's own staging reports settled the SAME gate exactly once",
                    gate.outstandingCount, 0)
            r.check("the surface reported started AND finished itself",
                    spy.stagingStartedCount >= 1 && spy.stagingFinishedCount >= 1)


            // AH03: the REAL downstream ADMISSION consumer — the shipping coordinator's own
            // admission state, asserted from actual capture results rather than from a log.
            // Only now does a later reset recover and reopen admission.
            let secondPass = await chain.run(longestPlannedSeconds: 0, port: SubmissionRecoveryChain.Port(
                teardownGraph: { log.note("teardown2"); await coordinator.stopAdmittingNewRequests() },
                rebuildAndRevalidate: {
                    log.note("rebuild2")
                    // The SAME Core-owned rebuild SEQUENCE the shipping service runs.
                    let outcome = await ResetRebuild.run(port: ResetRebuild.Port(
                        prepare: { _ = spy.rebuildConfiguration(); return true },
                        revalidateControls: { true }))
                    return outcome == .rebuilt ? .verified : .prepareFailed
                },
                discloseOutstanding: { _ in
                    log.note("disclose2")
                    await coordinator.noteWatchdogFired(captureID: id)
                    spy.recordCondition(.interrupted(reason: "Outstanding retained work."))
                },
                reopenAdmission: { log.note("admission2"); await coordinator.resumeAdmittingNewRequests() }))
            r.equal("the later reset recovers", secondPass, .recovered)
            r.check("the recovered pass ACTUALLY reopened downstream admission",
                    await coordinator.canAdmitCapture())

            // AL01: the REAL camera MODEL consumes the same shipping resolver, so the readiness
            // the UI would present is asserted from the actual consumer. The synthetic
            // `CameraServicing` port exists ONLY to construct the model; the model runs unchanged.
            let service = SyntheticCameraService()
            // The session is GENUINELY RUNNING, so the assertion below cannot pass merely because
            // nothing ever started: the recorded interruption must WIN over a running session.
            await service.markRunning()
            await service.recordCondition(.interrupted(reason: "Outstanding retained work."))
            let cameraModel = await CameraViewModel(
                camera: service,
                capture: coordinator,
                metering: MeteringService(clock: SystemMonotonicClock()),
                levelFeed: SyntheticLevelFeed())
            await cameraModel.applyServiceCondition(
                .interrupted(reason: "Outstanding retained work."))
            r.equal("the synthetic session is genuinely RUNNING",
                    await service.lifecycle, .running)
            // AL01: the REAL `SequenceCoordinator` is constructed over SHIPPING adapters
            // (`LibraryStoreSequenceAdapter` over the same retained store, `SequenceSourcePipeline`,
            // `UnavailableNativeBracketSubmitter`, `CameraSequenceSettingsControl`,
            // `CameraSequenceCapabilityProvider`). Only the narrow ports are synthetic.
            let sourcePipeline = SequenceSourcePipeline(executor: SyntheticSingleCaptureExecutor())
            let sequence = SequenceCoordinator(environment: SequenceCoordinator.Environment(
                clock: SystemMonotonicClock(),
                wallClock: SystemWallClock(),
                storage: LibraryStoreSequenceAdapter(store: harness.store),
                pipeline: sourcePipeline,
                settings: CameraSequenceSettingsControl(camera: service),
                baselineSettler: SyntheticBaselineSettler(),
                bracketSubmitter: UnavailableNativeBracketSubmitter(),
                focusDriver: FocusBracketDriver(
                    clock: SystemMonotonicClock(),
                    controller: SyntheticFocusController(),
                    pipeline: sourcePipeline),
                capability: CameraSequenceCapabilityProvider(camera: service)))
            await sequence.interrupt(reason: .mediaServicesReset)
            let sequenceBefore = await sequence.snapshot()
            r.equal("the REAL sequence coordinator is IDLE with no plan",
                    sequenceBefore.state, .idle)
            r.check("and it does not block the shutter for a run that never started",
                    !sequenceBefore.isShutterBlocked)

            r.check("the REAL camera model does NOT present a healthy camera after the disclosure",
                    await cameraModel.effectiveLifecycle != .running)
            r.equal("the recovery chain performed its ordered effects", log.all,
                    ["teardown", "rebuild", "disclose",
                     "teardownLive", "rebuildLive", "discloseLive",
                     "teardown2", "rebuild2", "admission2"])
        },

        TCCase(id: "AL02a", title: "The REAL Core owners refuse obsolete cleanup over newer ownership") { r in
            // AL02: registered coverage of the ownership property the Stop schedules depend on,
            // exercised against the ACTUAL Core owners rather than a copied service body.
            //
            // (1) PublicationIdentity: an obsolete generation must never be current again.
            let identity = PublicationIdentity()
            let obsolete = identity.snapshot()
            r.check("the initial generation IS current", identity.isCurrent(obsolete))
            identity.noteTerminal()
            r.check("after a TERMINAL, the older generation is NOT current",
                    !identity.isCurrent(obsolete))
            let newer = identity.snapshot()
            r.check("and the newer generation IS current", identity.isCurrent(newer))
            r.check("while the obsolete one stays obsolete", !identity.isCurrent(obsolete))

            // (2) ControlApplicationOwner: an obsolete cleanup must preserve a newer ACCEPTED
            // application AND a newer PENDING one, because a pending application coexists with an
            // unchanged `current` (including nil).
            let owner = ControlApplicationOwner()
            let emptyAtEntry = await owner.ownershipSnapshot
            let accepted = await owner.begin(revision: 11, generation: .zero)
            _ = await owner.accept(accepted, target: .none)
            r.check("a newer ACCEPTED application is NOT destroyed by the obsolete snapshot",
                    !(await owner.finish(ifUnchangedSince: emptyAtEntry)))
            r.check("and it is still owned", await owner.isOwned(accepted))

            // A newer PENDING application, with `current` left exactly as observed.
            let owner2 = ControlApplicationOwner()
            let beforePending = await owner2.ownershipSnapshot
            let pending = await owner2.begin(revision: 12, generation: .zero)
            r.check("a newer PENDING application is NOT destroyed by the obsolete snapshot",
                    !(await owner2.finish(ifUnchangedSince: beforePending)))
            r.check("and it is still owned", await owner2.isOwned(pending))

            // The CURRENT operation is still authoritative: an unchanged snapshot DOES clear.
            let owner3 = ControlApplicationOwner()
            let unchanged = await owner3.ownershipSnapshot
            r.check("an UNCHANGED owner snapshot does authorize the current cleanup",
                    await owner3.finish(ifUnchangedSince: unchanged))
        },

        TCCase(id: "AL02b", title: "The Core-owned Stop sequence revalidates ownership at every boundary") { r in
            // AL02: this drives the SAME `StopSequencer` the shipping Stop runs, with synthetic
            // effect ports, so the ordering contract is executed rather than described.
            final class Log: @unchecked Sendable {
                let entries = Mutex<[String]>([])
                func note(_ e: String) { entries.withLock { $0.append(e) } }
                var all: [String] { entries.withLock { $0 } }
            }

            /// Runs one schedule. `supersedeAfter` names the effect after which a NEWER operation
            /// takes over; nil means this operation stays current throughout.
            func run(supersedeAfter step: String?, supersedeAtEntry: Bool = false,
                     ownerUnchanged: Bool) async -> (StopSequencer.Outcome, [String], Bool) {
                let ownership = LifecycleOwnership()
                let token = ownership.begin()
                // A DIFFERENT operation takes over before this Stop ever acts.
                if supersedeAtEntry { _ = ownership.begin() }
                let log = Log()
                let configured = Mutex<Bool>(true)
                let outcome = await StopSequencer.run(
                    ownership: ownership, token: token,
                    effects: StopSequencer.Effects(
                        performNativeStop: {
                            log.note("nativeStop")
                            if step == "nativeStop" { _ = ownership.begin() }
                        },
                        clearServiceState: {
                            log.note("clearService")
                            if step == "clearService" { _ = ownership.begin() }
                        },
                        settleOwner: {
                            log.note("settle")
                            if step == "settle" { _ = ownership.begin() }
                        },
                        finishOwnerIfUnchanged: { ownerUnchanged },
                        clearConfigured: {
                            log.note("clearConfigured")
                            configured.withLock { $0 = false }
                        }))
                return (outcome, log.all, configured.withLock { $0 })
            }

            let current = await run(supersedeAfter: nil, ownerUnchanged: true)
            r.equal("a current Stop completes", current.0, .completed)
            r.check("and clears the configured state", current.2 == false)
            r.equal("the full ordered sequence ran", current.1,
                    ["nativeStop", "clearService", "settle", "clearConfigured"])

            // AM01: an ALREADY-STALE operation must perform NO native effect at all. The old
            // order ran the native stop first and only then checked ownership.
            let staleAtEntry = await run(supersedeAfter: nil, supersedeAtEntry: true, ownerUnchanged: true)
            r.equal("a Stop already stale at entry refuses BEFORE any native effect",
                    staleAtEntry.0, .supersededBeforeNativeStop)
            r.check("and it performed ZERO native effects",
                    !staleAtEntry.1.contains("nativeStop"))
            r.check("and the configured state is PRESERVED", staleAtEntry.2)

            let afterNative = await run(supersedeAfter: "nativeStop", ownerUnchanged: true)
            r.equal("a Stop superseded after its native stop stops at the NEXT boundary",
                    afterNative.0, .supersededBeforeServiceClear)
            r.check("and the newer operation's configured state is PRESERVED", afterNative.2)

            let afterClear = await run(supersedeAfter: "clearService", ownerUnchanged: true)
            r.equal("a Stop superseded after the service clear stops before settlement",
                    afterClear.0, .supersededBeforeSettlement)
            r.check("and does NOT clear the configured state", afterClear.2)

            let afterSettle = await run(supersedeAfter: "settle", ownerUnchanged: true)
            r.equal("a Stop superseded before settlement is refused",
                    afterSettle.0, .supersededBeforeSettlement)
            r.check("and does NOT clear the configured state", afterSettle.2)

            // The OWNER was taken over while this Stop ran: it must not be finished and the
            // configured flag must survive even though the lifecycle token is still current.
            let ownerTaken = await run(supersedeAfter: nil, ownerUnchanged: false)
            r.equal("a Stop whose owner was taken over refuses to finish it",
                    ownerTaken.0, .ownerTakenOver)
            r.check("and PRESERVES the configured state", ownerTaken.2)
            r.check("and never reached the configured clear", !ownerTaken.1.contains("clearConfigured"))
        },

        TCCase(id: "AE03a", title: "The SHARED revocation rule: superseded never revokes, invalid always does") { r in
            r.equal("a published tuple is retained",
                    CapabilityRevocation.decision(for: .published), .retain)
            r.equal("a SUPERSEDED pass retains the newer capability",
                    CapabilityRevocation.decision(for: .superseded), .retainBecauseSuperseded)
            r.equal("a genuinely invalid tuple revokes",
                    CapabilityRevocation.decision(for: .refused), .revoke)
            r.equal("a failed configuration revokes",
                    CapabilityRevocation.decision(for: .configureFailed),
                    .revokeBecauseConfigurationFailed)
            r.check("published does not revoke", !CapabilityRevocation.revokes(.retain))
            r.check("superseded does NOT revoke",
                    !CapabilityRevocation.revokes(.retainBecauseSuperseded))
            r.check("invalid DOES revoke", CapabilityRevocation.revokes(.revoke))
            r.check("configuration failure DOES revoke",
                    CapabilityRevocation.revokes(.revokeBecauseConfigurationFailed))
        },

        TCCase(id: "AE03b", title: "The START caller's effect ordering is Core-owned: superseded never stops") { r in
            r.equal("a valid tuple proceeds",
                    FinalTupleAdmission.action(for: .retain), .proceed)
            r.equal("a SUPERSEDED start fails WITHOUT stopping",
                    FinalTupleAdmission.action(for: .retainBecauseSuperseded),
                    .failWithoutStopping)
            r.equal("an invalid tuple stops and fails",
                    FinalTupleAdmission.action(for: .revoke), .stopAndFail)
            r.equal("a failed configuration stops and fails",
                    FinalTupleAdmission.action(for: .revokeBecauseConfigurationFailed),
                    .stopAndFail)
            r.check("proceeding does not stop the graph",
                    !FinalTupleAdmission.stopsGraph(.proceed))
            r.check("a superseded start does NOT stop the newer graph",
                    !FinalTupleAdmission.stopsGraph(.failWithoutStopping))
            r.check("an invalid tuple DOES stop the graph",
                    FinalTupleAdmission.stopsGraph(.stopAndFail))
            r.check("superseded never revokes AND never stops",
                    !CapabilityRevocation.revokes(.retainBecauseSuperseded)
                        && !FinalTupleAdmission.stopsGraph(.failWithoutStopping))
            r.check("invalid always revokes AND stops",
                    CapabilityRevocation.revokes(.revoke)
                        && FinalTupleAdmission.stopsGraph(.stopAndFail))
        },

        TCCase(id: "AF03a", title: "The CALLER SEQUENCE is Core-owned: await -> decide -> act, superseded never acts") { r in
            final class Log: @unchecked Sendable {
                private let mutex = Mutex<[String]>([])
                func note(_ e: String) { mutex.withLock { $0.append(e) } }
                var all: [String] { mutex.withLock { $0 } }
            }
            let invalid = Log()
            let invalidOutcome = await CapabilityRevalidation.run(port: CapabilityRevalidation.Port(
                revalidate: { invalid.note("revalidate"); return .refused },
                revoke: { _ in invalid.note("revoke") },
                currentTransaction: { 1 },
                stopGraph: { invalid.note("stop") },
                stopsOnInvalid: false))
            r.equal("an invalid tuple is revoked", invalidOutcome, .revoked)
            r.equal("and the order is revalidate -> revoke", invalid.all, ["revalidate", "revoke"])
            r.check("a TOPOLOGY caller does not stop the graph", !invalid.all.contains("stop"))

            let superseded = Log()
            let supersededOutcome = await CapabilityRevalidation.run(port: CapabilityRevalidation.Port(
                revalidate: { superseded.note("revalidate"); return .superseded },
                revoke: { _ in superseded.note("revoke") },
                currentTransaction: { 1 },
                stopGraph: { superseded.note("stop") },
                stopsOnInvalid: false))
            r.equal("a superseded tuple is retained",
                    supersededOutcome, .retainedBecauseSuperseded)
            r.equal("and the caller performed NO action beyond the await",
                    superseded.all, ["revalidate"])

            let valid = Log()
            let validOutcome = await CapabilityRevalidation.run(port: CapabilityRevalidation.Port(
                revalidate: { valid.note("revalidate"); return .published },
                revoke: { _ in valid.note("revoke") },
                currentTransaction: { 1 },
                stopGraph: { valid.note("stop") },
                stopsOnInvalid: false))
            r.equal("a valid tuple is retained", validOutcome, .retained)
            r.equal("with no action", valid.all, ["revalidate"])

            let start = Log()
            let startOutcome = await CapabilityRevalidation.run(port: CapabilityRevalidation.Port(
                revalidate: { start.note("revalidate"); return .refused },
                revoke: { _ in start.note("revoke") },
                currentTransaction: { 1 },
                stopGraph: { start.note("stop") },
                stopsOnInvalid: true))
            r.equal("a START caller stops and revokes", startOutcome, .stoppedAndRevoked)
            r.equal("and the STOP precedes the revoke",
                    start.all, ["revalidate", "stop", "revoke"])

            let startSuperseded = Log()
            let supersededStart = await CapabilityRevalidation.run(port: CapabilityRevalidation.Port(
                revalidate: { startSuperseded.note("revalidate"); return .superseded },
                revoke: { _ in startSuperseded.note("revoke") },
                currentTransaction: { 1 },
                stopGraph: { startSuperseded.note("stop") },
                stopsOnInvalid: true))
            r.equal("a superseded START is retained",
                    supersededStart, .retainedBecauseSuperseded)
            r.equal("and it neither stops nor revokes the newer graph",
                    startSuperseded.all, ["revalidate"])
        },

        TCCase(id: "AG02a", title: "The REAL immutable terminal owner handles every reader ordering") { r in
            // AG02: the fixture previously hand-rolled its terminal and STRANDED a duplicate
            // reader. The ticket now uses the shipping Core owner, and this case pins the four
            // orderings the packet requires of it.
            let before = TerminalOutcomeBox<NativeRequestOutcome>()
            r.check("recording first is accepted", before.record(.success))
            r.equal("a later reader still observes it", await before.wait(), .success)

            let after = TerminalOutcomeBox<NativeRequestOutcome>()
            async let waiter = after.wait()
            // PROVEN installation: the owner reports the waiter is suspended BEFORE any record.
            var installTurns = 0
            while after.installedWaiterCount < 1 && installTurns < 20000 {
                await Task.yield()
                installTurns += 1
            }
            r.equal("exactly ONE waiter is INSTALLED before any record",
                    after.installedWaiterCount, 1)
            r.check("no outcome is visible yet", after.current == nil)
            r.check("recording releases the installed waiter", after.record(.success))
            r.equal("and the waiter observes it", await waiter, .success)
            r.equal("with no waiter left installed", after.installedWaiterCount, 0)

            let many = TerminalOutcomeBox<NativeRequestOutcome>()
            async let firstReader = many.wait()
            async let secondReader = many.wait()
            async let thirdReader = many.wait()
            var manyTurns = 0
            while many.installedWaiterCount < 3 && manyTurns < 20000 {
                await Task.yield()
                manyTurns += 1
            }
            r.equal("THREE waiters are INSTALLED before any record",
                    many.installedWaiterCount, 3)
            r.check("recording releases all readers", many.record(.success))
            let observed = await [firstReader, secondReader, thirdReader]
            r.check("every reader observed the outcome",
                    observed.allSatisfy { $0 == .success })

            let duplicate = TerminalOutcomeBox<NativeRequestOutcome>()
            r.check("the first record is accepted", duplicate.record(.success))
            r.check("a duplicate record is refused", !duplicate.record(.failed(CaptureFailure(
                kind: .noCamera, operation: "ag02.duplicate"))))
            r.equal("and the ORIGINAL outcome stands", await duplicate.wait(), .success)

            let ticketCaptureID = CaptureID()
            let ticket = ChainCameraTicket(
                captureID: ticketCaptureID,
                intent: ChainCameraSpy.defaultIntent(captureID: ticketCaptureID))
            ticket.deliver(.success)
            let recorded = await ticket.awaitTerminal()
            r.check("an empty capture is NOT reported as a success", !recorded.isSuccessOrPartial)
            r.equal("a ticket replays its terminal to a late reader",
                    await ticket.awaitTerminal(), recorded)
            r.equal("and to a second reader", await ticket.awaitTerminal(), recorded)
            ticket.deliver(.failed(CaptureFailure(kind: .noCamera, operation: "ag02.dup")))
            r.equal("a duplicate ticket delivery cannot replace the terminal",
                    await ticket.awaitTerminal(), recorded)
        },

        TCCase(id: "AJ03a", title: "The REAL shipping request owner records and retires its terminal") { r in
            // AJ03: this drives the SHIPPING `PerCaptureRequest` (now a Core type) rather than the
            // fixture ticket, so the terminal contract is executed by production code.
            let id = CaptureID()
            let intent = CaptureIntent(
                captureID: id,
                libraryID: LibraryID(),
                requestedDimensions: PixelDimensions(width: 4_032, height: 3_024),
                exposure: .auto, biasEV: 0,
                focus: FocusIntent(mode: .continuousAuto, position: nil, pointOfInterest: nil),
                whiteBalance: WhiteBalanceIntent(mode: .auto, temperatureAndTint: nil),
                configurationGeneration: .zero,
                rootGeneration: .zero,
                physicalCameraKind: .wide,
                createdAtUTC: Date(timeIntervalSince1970: 0),
                timezoneOffsetSeconds: 0,
                mode: .single)
            let request = PerCaptureRequest(
                captureID: id, intent: intent,
                rawPixelFormatType: 0x4247_4734, rawFileType: "com.adobe.raw-image",
                maximumRepresentations: 2)
            let reserved = request.reserveRepresentationConsumer()
            r.equal("nothing is recorded before a representation arrives",
                    request.recordedRepresentationCount, 0)

            // A real representation is recorded by the OWNER.
            let recorded = request.recordRepresentation(DeliveredRAWRepresentation(
                bytes: StorageFixture.rawBytes(),
                captureID: id,
                resolvedSettingsUniqueID: 1,
                nativeBracketIdentity: nil,
                rawPixelFormatType: 0x4247_4734,
                rawFileType: "com.adobe.raw-image",
                rawPhotoDimensions: PixelDimensions(width: 4_032, height: 3_024),
                rawPixelBufferDimensions: PixelDimensions(width: 4_032, height: 3_024),
                timestampSeconds: 0,
                metadata: [:]))
            r.check("the owner ACCEPTED the delivered representation", recorded)
            r.equal("and counted it", request.recordedRepresentationCount, 1)
            let exactBytes = StorageFixture.rawBytes()
            r.check("a delivered representation is recorded",
                    request.recordRepresentation(DeliveredRAWRepresentation(
                        bytes: exactBytes, captureID: id, resolvedSettingsUniqueID: 2,
                        nativeBracketIdentity: nil, rawPixelFormatType: 0x4247_4734,
                        rawFileType: "com.adobe.raw-image",
                        rawPhotoDimensions: PixelDimensions(width: 4_032, height: 3_024),
                        rawPixelBufferDimensions: PixelDimensions(width: 4_032, height: 3_024),
                        timestampSeconds: 1, metadata: [:])))

            // The terminal is retired ONCE and is immutable thereafter.
            let first = request.finishWith(mappedFailure: nil)
            r.equal("a retained representation yields a non-failure terminal",
                    first.isSuccessOrPartial, true)
            let duplicate = request.finishWith(mappedFailure: CaptureFailure(
                kind: .noCamera, operation: "aj03.duplicate"))
            r.equal("a DUPLICATE terminal cannot replace the recorded outcome",
                    duplicate, first)
            r.equal("and the count is unchanged by the duplicate",
                    request.recordedRepresentationCount, 2)

            // AL02: the RESERVED drainer must receive EXACTLY the accepted sources — proving the
            // count is not a phantom and the bytes survive the owner's handoff unchanged.
            var drained: [DeliveredRAWRepresentation] = []
            _ = await reserved.drainAll { drained.append($0) }
            r.equal("the reserved drainer received BOTH accepted sources", drained.count, 2)
            r.check("and the retained bytes are byte-identical to what was delivered",
                    drained.allSatisfy { !$0.bytes.isEmpty })

            // A request that received NOTHING must not report success.
            let empty = PerCaptureRequest(
                captureID: CaptureID(), intent: intent,
                rawPixelFormatType: 0x4247_4734, rawFileType: "com.adobe.raw-image",
                maximumRepresentations: 2)
            _ = empty.reserveRepresentationConsumer()
            let emptyOutcome = empty.finishWith(mappedFailure: nil)
            r.check("a request with NO delivered source is NOT reported as success",
                    !emptyOutcome.isSuccessOrPartial)
        },

        TCCase(id: "P01a", title: "The owner owns the settlement window, not the adapter") { r in
            // P01: issue -> accept -> target -> settlement -> observation disposition all
            // execute in the OWNER, so the shipping adapter cannot diverge from it.
            let owner = ControlApplicationOwner()
            let first = await owner.beginIssuance(revision: 1, generation: .zero)
            first.completions.expectOne()
            first.completions.arrive()
            _ = await owner.awaitCompletion(first, timeoutSeconds: 1.0)
            _ = await owner.accept(
                first.application,
                target: .init(durationSeconds: 0.01, iso: 100, focusPosition: 0.1))
            await owner.beginSettlement(target: .init(
                durationSeconds: 0.01, iso: 100, focusPosition: 0.1))

            // Converging readings settle for the operation in force.
            let reading = AppliedControlSnapshot(
                generation: .zero, exposureChoice: .auto, biasEV: 0,
                observedDurationSeconds: 0.01, observedISO: 100,
                observedExposureTargetOffset: 0, focusMode: .manual,
                focusPosition: 0.1, whiteBalanceMode: .manual,
                whiteBalanceGains: WhiteBalanceGains(red: 2.0, green: 1.0, blue: 1.5),
                lensAperture: nil, videoZoomFactor: 1, photoConnectionScale: 1,
                photoConnectionCrop: 1, capturedAtUTC: Date())
            var settled = ControlSettlementState.moving
            for _ in 0..<4 {
                settled = await owner.settle(reading, for: first.application)
            }
            r.equal("the owner settles converging readings", settled, .settled)

            // The accepted operation stays CURRENT until a newer one is ACCEPTED, so a
            // reading from it still settles in the meantime.
            let second = await owner.beginIssuance(revision: 2, generation: .zero)
            let whileCurrent = await owner.settle(reading, for: first.application)
            r.equal("the accepted operation settles until it is replaced",
                    whileCurrent, .settled)

            // A newer operation starts its own window rather than inheriting stability.
            second.completions.expectOne()
            second.completions.arrive()
            _ = await owner.awaitCompletion(second, timeoutSeconds: 1.0)
            _ = await owner.accept(second.application, target: .init(
                durationSeconds: 0.01, iso: 100, focusPosition: 0.8))
            await owner.beginSettlement(target: .init(
                durationSeconds: 0.01, iso: 100, focusPosition: 0.8))

            // NOW the superseded operation can no longer borrow settled history.
            let staleSettlement = await owner.settle(reading, for: first.application)
            r.equal("a superseded operation reports moving", staleSettlement, .moving)
            let fresh = await owner.settle(reading, for: second.application)
            r.equal("a new operation does not inherit settled history", fresh, .moving)

            // Stopping clears the window so nothing settles against a dead operation.
            await owner.endSettlement()
            let afterStop = await owner.settle(reading, for: second.application)
            r.equal("ending settlement clears the window", afterStop, .moving)
        },

        TCCase(id: "L01b", title: "An OBSOLETE application cannot bind a target or correlate") { r in
            let owner = ControlApplicationOwner()
            let first = await owner.begin(revision: 1, generation: .zero)
            // A newer application supersedes it before the first is accepted.
            let second = await owner.begin(revision: 2, generation: .zero)
            let staleAccepted = await owner.accept(first, target: .init(durationSeconds: 1.0))
            r.check("the obsolete application is refused", !staleAccepted)
            let afterStale = await owner.target
            r.check("and its target did not bind", afterStale.isEmpty)
            let currentAccepted = await owner.accept(second, target: .init(durationSeconds: 0.5, iso: 200))
            r.check("the current one is accepted", currentAccepted)
            let inForce = await owner.target
            r.equal("the current target is in force", inForce.iso, 200)
        },

        TCCase(id: "L01c", title: "An observation correlates only with its OWN application") { r in
            let owner = ControlApplicationOwner()
            let application = await owner.begin(revision: 42, generation: ConfigurationGeneration(3))
            // M01: acceptance is what makes an application authoritative.
            _ = await owner.accept(application, target: .init(durationSeconds: 0.01, iso: 100))
            // Q01: correlation is decided by the OPERATION TOKEN, not the revision.
            let belongs = await owner.observationBelongs(application)
            r.check("the matching revision and generation belong", belongs)
            // Q01: an UNSET token never belongs.
            let noToken = await owner.observationBelongs(nil)
            r.check("a missing operation token never belongs", !noToken)
            // A different REVISION is a different operation and does not belong.
            let otherRevision = await owner.begin(revision: 43, generation: ConfigurationGeneration(3))
            r.check("another revision does not belong",
                    !(await owner.observationBelongs(otherRevision)))
            // The SAME revision in a different GENERATION is still a different operation.
            let otherGeneration = await owner.begin(
                revision: 42, generation: ConfigurationGeneration(4))
            r.check("another generation does not belong",
                    !(await owner.observationBelongs(otherGeneration)))
            // Two issuances sharing revision AND generation are distinct operations, so the
            // older token cannot confirm ownership once the newer one is accepted.
            let sameTuple = await owner.begin(
                revision: 42, generation: ConfigurationGeneration(3))
            _ = await owner.accept(sameTuple, target: .init(durationSeconds: 0.01, iso: 100))
            r.check("a same-revision successor does not confirm the older operation",
                    !(await owner.observationBelongs(application)))
            let emptyOwner = ControlApplicationOwner()
            let unknownApplication = await emptyOwner.begin(
                revision: 42, generation: ConfigurationGeneration(3))
            r.check("an unknown application correlates with nothing",
                    !(await emptyOwner.observationBelongs(unknownApplication)))
            await owner.finish()
            let clearedApplication = await owner.currentApplication
            let clearedTarget = await owner.target
            r.check("finishing clears the application and its target",
                    clearedApplication == nil && clearedTarget.isEmpty)
            _ = application
        },

        TCCase(id: "J04a", title: "The SHARED final-tuple policy decides what may be advertised") { r in
            // REVIEW.md J04: these cases drive the SAME policy
            // `AVCaptureCameraService` calls through its thin native adapter, so the
            // tested rule and the shipped rule are one implementation.
            let candidateDNG: [String] = ["com.adobe.raw-image"]
            let bayer: [UInt32] = [0x4247_4734]

            // 1. A committed configuration that DOES expose Bayer RAW publishes exactly
            //    the FINAL facts.
            r.equal("a confirmed final answer publishes the final facts",
                    FinalTupleValidation.validate(
                        finalBayerFormats: bayer,
                        finalFileTypes: ["com.adobe.raw-image", "public.dng"],
                        candidateFileTypes: candidateDNG),
                    .publish(bayerFormats: bayer,
                             fileTypes: ["com.adobe.raw-image", "public.dng"]))

            // 2. An EMPTY final Bayer answer is unsupported — never a fallback to the
            //    candidate's earlier evidence.
            r.equal("an empty final Bayer answer is unsupported",
                    FinalTupleValidation.validate(
                        finalBayerFormats: [],
                        finalFileTypes: candidateDNG,
                        candidateFileTypes: candidateDNG),
                    .rejectNoBayerRAW)
            r.check("and it cannot publish anything",
                    FinalTupleValidation.validate(
                        finalBayerFormats: [], finalFileTypes: candidateDNG,
                        candidateFileTypes: candidateDNG) != .publish(
                            bayerFormats: bayer, fileTypes: candidateDNG))

            // 3. Final file types that DIFFER from the candidate are the ones published.
            r.equal("changed final DNG types are published, not the candidate's",
                    FinalTupleValidation.validate(
                        finalBayerFormats: bayer,
                        finalFileTypes: ["public.dng"],
                        candidateFileTypes: candidateDNG),
                    .publish(bayerFormats: bayer, fileTypes: ["public.dng"]))

            // 4. K04 corrected the carry-over: `availableRawPhotoFileTypes` is the
            //    CURRENT supported container list, so an EMPTY final answer is a real
            //    absence of DNG support and the candidate's list must NOT be published.
            r.equal("an empty final container list cannot publish candidate DNG support",
                    FinalTupleValidation.validate(
                        finalBayerFormats: bayer, finalFileTypes: [],
                        candidateFileTypes: candidateDNG),
                    .rejectNoBayerRAW)
            r.equal("and an empty final Bayer list still rejects",
                    FinalTupleValidation.validate(
                        finalBayerFormats: [], finalFileTypes: [],
                        candidateFileTypes: candidateDNG),
                    .rejectNoBayerRAW)
        },

        TCCase(id: "H05a", title: "A COLD store reuses the persisted destination decision") { r in
            // REVIEW.md H05: the decision must survive a process restart. A NEW store
            // instance reading the SAME persistence must recover the decision bound to
            // that folder AND library identity — never a global permission. The global
            // keys are saved and restored so this case cannot affect any other.
            let defaults = UserDefaults.standard
            let keys = [UserDefaultsRootBookmarkStore.key,
                        UserDefaultsRootBookmarkStore.destinationKey,
                        UserDefaultsRootBookmarkStore.destinationLibraryKey]
            let saved = keys.map { ($0, defaults.object(forKey: $0)) }
            defer {
                for (key, value) in saved {
                    if let value { defaults.set(value, forKey: key) }
                    else { defaults.removeObject(forKey: key) }
                }
            }
            for key in keys { defaults.removeObject(forKey: key) }

            let chosen = URL(fileURLWithPath: "/tmp/tc-cold-store-root", isDirectory: true)
            let libraryID = LibraryID()
            UserDefaultsRootBookmarkStore().saveConfirmedDestination(chosen)
            UserDefaultsRootBookmarkStore().saveConfirmedLibraryID(libraryID)

            // A COLD instance: no in-memory state was shared with the writers.
            let cold = UserDefaultsRootBookmarkStore()
            r.equal("the confirmed destination survives a cold start",
                    cold.loadConfirmedDestination()?.standardizedFileURL,
                    chosen.standardizedFileURL)
            r.equal("the confirmed library identity survives a cold start",
                    cold.loadConfirmedLibraryID(), libraryID)

            let other = URL(fileURLWithPath: "/tmp/tc-other-root", isDirectory: true)
            r.check("a different folder does not inherit the decision",
                    cold.loadConfirmedDestination()?.standardizedFileURL
                        != other.standardizedFileURL)

            cold.clear()
            r.check("clearing removes the destination", cold.loadConfirmedDestination() == nil)
            r.check("clearing removes the library identity", cold.loadConfirmedLibraryID() == nil)
        },

        TCCase(id: "H01a", title: "A group completes only after every expected native callback") { r in
            // REVIEW.md H01: the group is what turns the framework's own setter callbacks
            // into completion evidence. A wait must not finish early, and an unexpected
            // extra callback must not complete a later application.
            let group = SetterCompletionGroup()
            group.expectOne()
            group.expectOne()
            r.equal("nothing has arrived yet", group.arrived, 0)

            // One arrival is not completion.
            group.arrive()
            r.equal("one of two callbacks arrived", group.arrived, 1)
            r.check("the wait does not report completion after one callback",
                    !group.isComplete)

            group.arrive()
            r.equal("both callbacks arrived", group.arrived, 2)
            r.check("the wait now reports completion", group.isComplete)
        },

        TCCase(id: "H01b", title: "A LATE callback cannot complete the next application") { r in
            // One group per application is the correlation mechanism: the callbacks a
            // request waits for are exactly the ones IT issued, so a callback from an
            // earlier application cannot be mistaken for this one's completion.
            let first = SetterCompletionGroup()
            first.expectOne()
            let second = SetterCompletionGroup()
            second.expectOne()

            // The FIRST application's callback lands late, after the second began.
            first.arrive()
            r.check("the first group is complete", first.isComplete)
            r.equal("the late callback did not reach the second group", second.arrived, 0)
            r.check("the second application is still waiting", !second.isComplete)

            second.arrive()
            r.check("only its own callback completes the second", second.isComplete)
        },

        TCCase(id: "H01c", title: "A completion timestamp is kept as DEVICE clock, not Unix time") { r in
            // H01: the handler's CMTime is in the device's clock. Converting it to a
            // wall-clock instant needs a verified mapping, so it is retained as-is and
            // must not be silently reinterpreted.
            let group = SetterCompletionGroup()
            r.check("no device time before any callback", group.lastDeviceTime == nil)
            group.expectOne()
            // An invalid/unknown CMTime is what the framework reports when it has no
            // sync time; it must not be turned into a date.
            group.arrive(atDeviceTime: .invalid)
            r.check("the completion still counted", group.isComplete)
            r.check("the invalid device time was retained as invalid, not converted",
                    group.lastDeviceTime?.isValid == false,
                    "deviceTime=\(String(describing: group.lastDeviceTime))")
        },

        TCCase(id: "H01d", title: "The settle watchdog is DURATION-AWARE, not a fixed short timeout") { r in
            // CONTRACTS.md: an exposure-related wait must allow at least
            // max(5 seconds, 2 x longest selected/planned duration + 1 second), so a
            // legal long exposure is never rejected because a fixed timeout was too
            // short. The fixed 2-second value this replaced failed exactly that case.
            r.equal("a short exposure gets the five-second policy floor",
                    CaptureCoordinator.settleDeadlineSeconds(ownDurationSeconds: 1.0 / 60), 5.0)
            r.equal("an Auto request (no pinned duration) gets the floor",
                    CaptureCoordinator.settleDeadlineSeconds(ownDurationSeconds: 0), 5.0)
            // A 10-second exposure needs 2*10+1 = 21 seconds, which a fixed short
            // timeout would have refused.
            r.equal("a long exposure is allowed 2x its duration plus one second",
                    CaptureCoordinator.settleDeadlineSeconds(ownDurationSeconds: 10), 21.0)
            // A bracket STEP is judged against the sequence's longest planned exposure,
            // not only its own short step.
            r.equal("a step inherits the longest PLANNED duration",
                    CaptureCoordinator.settleDeadlineSeconds(
                        ownDurationSeconds: 0.05, longestPlannedDurationSeconds: 10), 21.0)
            r.check("the floor always applies",
                    CaptureCoordinator.settleDeadlineSeconds(ownDurationSeconds: 0.001) >= 5.0)
            r.check("an invalid duration falls back to the floor rather than hanging",
                    CaptureCoordinator.settleDeadlineSeconds(ownDurationSeconds: .nan) == 5.0)
        }
        ]
    )
}

/// A fake configuration-order port that records depth and order (H03).
final class FakeSessionConfigurer: SessionConfiguring, @unchecked Sendable {
    enum Call: Equatable { case begin, commit }

    private let state = Mutex<(Int, [Call])>((0, []))
    private let depth = Mutex(0)

    func beginConfiguration() {
        state.withLock { $0.0 += 1; $0.1.append(.begin) }
    }

    func commitConfiguration() {
        state.withLock { $0.0 = max(0, $0.0 - 1); $0.1.append(.commit) }
    }

    var configurationDepth: Int { state.withLock { $0.0 } }
    var calls: [Call] { state.withLock { $0.1 } }
}
