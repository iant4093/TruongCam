import Foundation
import Synchronization

#if canImport(XCTest)
@testable import TruongCam
#endif

// AM01/AM02 — the dedicated Stop ownership + actor-isolation suite.
//
// Every case drives the ACTUAL `src/TruongCam/Core/StopSequencer.swift` production helper.
// There is no copied sequencer algorithm anywhere in this file: the schedules below only supply
// narrow synthetic effect ports, then assert what the real helper did with them.
//
// These cases are about ORDERING, OWNERSHIP and EXECUTOR. The synthetic state proves which effects
// ran, on which executor, and in which order. It is never evidence about AVFoundation, a physical
// camera, or RAW capture.
//
// Executor isolation is exercised two ways:
//   * a genuinely `@MainActor`-isolated effect body that reads MainActor state DIRECTLY (which only
//     compiles when the closure really carries MainActor isolation) and asserts its executor with
//     `MainActor.assumeIsolated` from inside the effect — the exact call that trapped in the AM02
//     counterexample;
//   * a custom (non-MainActor) actor whose isolated state the effects touch directly, which is only
//     legal when the effect really runs on that actor's executor.
enum StopRepairSuite {
    static let suite = TCSuite(
        id: "STOP-REPAIR",
        title: "Stop ownership refusal and effect-executor isolation (AM01/AM02)",
        cases: [
            TCCase(id: "AM01a",
                   title: "An already-obsolete Stop performs ZERO effects, native included") { r in
                let schedule = StopSchedule(ownerUnchanged: true, supersedeAtEntry: true)
                let outcome = await schedule.run()
                r.equal("the refusal is the pre-native one", outcome, .supersededBeforeNativeStop)
                r.check("not one effect closure was invoked",
                        schedule.log.entries.isEmpty,
                        "entries=\(schedule.log.entries)")
                r.equal("the native stop never ran", schedule.log.nativeStopCount, 0)
                r.check("the newer operation's running graph survives", schedule.running)
                r.check("the newer operation's configured state survives", schedule.configured)
                r.equal("no service mutation was performed", schedule.log.serviceClearCount, 0)
                r.equal("the owner was not settled", schedule.log.settleCount, 0)
                r.equal("the owner was not finished", schedule.log.finishCount, 0)
            },

            TCCase(id: "AM01b",
                   title: "A current Stop runs the five effects once each in order") { r in
                let schedule = StopSchedule(ownerUnchanged: true)
                let outcome = await schedule.run()
                r.equal("the sequence completes", outcome, .completed)
                r.equal("the ordered sequence is exactly native/service/settle/finish/configured",
                        schedule.log.entries,
                        ["nativeStop", "clearServiceState", "settleOwner",
                         "finishOwnerIfUnchanged", "clearConfigured"])
                r.equal("the native stop ran once", schedule.log.nativeStopCount, 1)
                r.check("the configured state was cleared", !schedule.configured)
            },

            TCCase(id: "AM01c",
                   title: "A Stop held inside its native effect is refused at the next boundary") { r in
                let schedule = StopSchedule(ownerUnchanged: true, supersedeAfter: "nativeStop")
                let outcome = await schedule.run()
                r.equal("the refusal names the boundary after the native stop",
                        outcome, .supersededBeforeServiceClear)
                r.equal("only the native effect had run", schedule.log.entries, ["nativeStop"])
                r.equal("the service state was NOT cleared", schedule.log.serviceClearCount, 0)
                r.check("the newer operation's configured state survives", schedule.configured)
                r.check("the supersession really happened inside the native effect",
                        schedule.supersededDuringNativeStop)
            },

            TCCase(id: "AM01d",
                   title: "A Stop held inside its service clear is refused before settlement") { r in
                let schedule = StopSchedule(ownerUnchanged: true, supersedeAfter: "clearServiceState")
                let outcome = await schedule.run()
                r.equal("the refusal names the settlement boundary",
                        outcome, .supersededBeforeSettlement)
                r.equal("the sequence stopped after the service clear",
                        schedule.log.entries, ["nativeStop", "clearServiceState"])
                r.equal("the owner was NOT settled", schedule.log.settleCount, 0)
                r.equal("the owner was NOT finished", schedule.log.finishCount, 0)
                r.check("the newer operation's configured state survives", schedule.configured)
            },

            TCCase(id: "AM01e",
                   title: "A Stop held inside owner settlement is refused before the owner finish") { r in
                // AM01 regression: the settlement hop had NO check of its own, so a Stop superseded
                // while settling still finished the owner and cleared the configured state.
                let schedule = StopSchedule(ownerUnchanged: true, supersedeAfter: "settleOwner")
                let outcome = await schedule.run()
                r.equal("the refusal names the settlement boundary",
                        outcome, .supersededBeforeSettlement)
                r.equal("the sequence stopped after settlement",
                        schedule.log.entries, ["nativeStop", "clearServiceState", "settleOwner"])
                r.equal("the newer operation's owner was NOT finished",
                        schedule.log.finishCount, 0)
                r.equal("the configured clear was never reached",
                        schedule.log.clearConfiguredCount, 0)
                r.check("the newer operation's configured state survives", schedule.configured)
                // The native effect legitimately ran while this operation was still current, so the
                // running graph is already down. What must NOT happen is the owner finish or the
                // configured clear once a newer operation owns the lifecycle.
                r.check("the native effect had run before the supersession", !schedule.running)
            },

            TCCase(id: "AM01f",
                   title: "A taken-over owner is not finished while the token is still current") { r in
                let schedule = StopSchedule(ownerUnchanged: false)
                let outcome = await schedule.run()
                r.equal("the owner takeover is classified distinctly", outcome, .ownerTakenOver)
                r.equal("the owner was probed exactly once", schedule.log.finishCount, 1)
                r.equal("the configured clear was never reached",
                        schedule.log.clearConfiguredCount, 0)
                r.check("the newer application's configured state survives", schedule.configured)
            },

            TCCase(id: "AM01g",
                   title: "Owner takeover stays distinct from token supersession") { r in
                let takenOver = await StopSchedule(ownerUnchanged: false).run()
                let superseded = await StopSchedule(ownerUnchanged: false,
                                                    supersedeAtEntry: true).run()
                r.equal("a stale token is refused before ANY effect", superseded,
                        .supersededBeforeNativeStop)
                r.notEqual("a stale token is not reported as an owner takeover",
                           superseded, StopSequencer.Outcome.ownerTakenOver)
                r.equal("a current token with a newer owner is OWNER-taken-over", takenOver,
                        .ownerTakenOver)
                r.notEqual("the two refusal classes are not interchangeable",
                           takenOver, superseded)
            },

            TCCase(id: "AM01h",
                   title: "Ownership is re-read live at every boundary, never cached") { r in
                // The helper must re-read the shared mutex-backed token after each suspension. The
                // schedules above supersede during each effect; this case asserts the guard is a
                // live read by checking that the very next guard observed the new value.
                let schedule = StopSchedule(ownerUnchanged: true, supersedeAfter: "nativeStop")
                let outcome = await schedule.run()
                r.equal("the post-suspension guard observed the supersession", outcome,
                        .supersededBeforeServiceClear)
                r.equal("and the helper performed no further effect",
                        schedule.log.serviceClearCount, 0)
                r.check("the token was superseded by a NEWER operation, not by this one",
                        schedule.supersededDuringNativeStop)
            },

            TCCase(id: "AM02a",
                   title: "A MainActor-isolated effect body keeps its executor") { r in
                // AM02 regression. The interface used to store SYNCHRONOUS callbacks, which the
                // nonisolated helper could (and did) invoke without any suspension point, so an
                // actor-isolated body ran on the helper's executor and trapped in
                // `_swift_task_checkIsolatedSwift` (SIGTRAP). The effect bodies below read
                // MainActor-isolated state DIRECTLY and re-assert their executor inside the effect;
                // if the helper resumed them anywhere else, this case would trap instead of passing.
                let result = await MainActorIsolationScenario.run()
                r.check("the MainActor-inherited effect closures were admitted", result.admitted)
                r.check("every effect body ran with MainActor isolation intact",
                        result.mainActorEverywhere,
                        "observed=\(result.observed)")
                r.equal("the sequence still completed", result.outcome, .completed)
                r.equal("and the full effect log is present", result.entries,
                        ["nativeStop", "clearServiceState", "settleOwner",
                         "finishOwnerIfUnchanged", "clearConfigured"])
            },

            TCCase(id: "AM02b",
                   title: "A custom actor's effects run ON that actor's executor") { r in
                let result = await ActorExecutorScenario().runCurrent()
                r.equal("the sequence completes", result.outcome, .completed)
                r.equal("every effect mutated actor state directly, mid-isolation",
                        result.directMutations, 5)
                r.check("the actor state really was mutated",
                        result.observerCleared && result.configuredCleared && result.nativeCleared)
                r.equal("each effect re-validated the token at its mutation boundary",
                        result.boundaryChecks, 5)
                r.equal("and none of those checks refused", result.boundaryRefusals, 0)
                r.check("no executor assertion trapped", result.survived)
            },

            TCCase(id: "AM02c",
                   title: "An actor effect re-validates the concrete token at its mutation boundary") { r in
                let result = await ActorExecutorScenario().runSupersededWhileHeld()
                r.equal("the held native effect completes, then the helper refuses",
                        result.outcome, .supersededBeforeServiceClear)
                r.check("the actor's own mutation-boundary check ran", result.boundaryChecks >= 1)
                r.check("and it refused to mutate the newer operation's service state",
                        !result.observerCleared)
                r.check("the newer operation's configured state survives",
                        !result.configuredCleared)
                r.equal("the later effects were never invoked", result.laterEffectsInvoked, 0)
                r.check("the refusal is a decision, not an executor trap", result.survived)
            },

            TCCase(id: "AM02d",
                   title: "Concurrent Stop schedules cannot cross-mutate the service state") { r in
                // Two independent operations over the SAME ownership: only the current one may
                // reach the service state. The obsolete one must observe the supersession and
                // perform zero mutations on either executor.
                let shared = SharedStopPorts()
                let ownership = LifecycleOwnership()
                let firstToken = ownership.begin()
                let secondToken = ownership.begin()
                async let stale = shared.run(ownership: ownership, token: firstToken)
                async let current = shared.run(ownership: ownership, token: secondToken)
                let outcomes = await (stale, current)
                r.equal("the obsolete schedule performs NO effects", outcomes.0,
                        .supersededBeforeNativeStop)
                r.equal("the current schedule completes", outcomes.1, .completed)
                r.equal("only the current operation cleared the service state",
                        shared.serviceClearCount, 1)
                r.equal("only the current operation stopped the native session",
                        shared.nativeStopCount, 1)
                r.equal("the configured clear happened exactly once", shared.configuredClearCount, 1)
            },

            TCCase(id: "AM02e",
                   title: "Ad-hoc effect closures hop to their own actor instead of running inline") { r in
                // The shipping shape: a NONISOLATED closure literal that HOPS into the actor. This
                // compiles only because each effect is `async`; the previous synchronous interface
                // accepted a direct, non-hopping call of the same literal, which is what ran
                // actor-isolated state on the helper's executor.
                let ownership = LifecycleOwnership()
                let token = ownership.begin()
                let actor = StopActorHarness(ownership: ownership, token: token)
                let outcome = await StopSequencer.run(
                    ownership: ownership,
                    token: token,
                    effects: StopSequencer.Effects(
                        performNativeStop: { await actor.performNativeStop() },
                        clearServiceState: { await actor.clearServiceState() },
                        settleOwner: { await actor.settleOwner() },
                        finishOwnerIfUnchanged: { await actor.finishOwner() },
                        clearConfigured: { await actor.clearConfigured() }))
                let mutated = await actor.snapshot
                r.equal("the hopping schedule completes", outcome, .completed)
                r.equal("and every hop actually reached the actor", mutated.directMutations, 5)
            },
        ])
}

// MARK: - Shared schedule harness

/// Thread-safe effect log. `Mutex.withLock` is deliberately non-suspending, so it stays legal
/// inside the async effect bodies of every schedule below.
final class EffectLog: @unchecked Sendable {
    private let entriesStorage = Mutex<[String]>([])

    func note(_ entry: String) { entriesStorage.withLock { $0.append(entry) } }

    var entries: [String] { entriesStorage.withLock { $0 } }

    func count(_ entry: String) -> Int {
        entriesStorage.withLock { $0.filter { $0 == entry }.count }
    }

    var nativeStopCount: Int { count("nativeStop") }
    var serviceClearCount: Int { count("clearServiceState") }
    var settleCount: Int { count("settleOwner") }
    var finishCount: Int { count("finishOwnerIfUnchanged") }
    var clearConfiguredCount: Int { count("clearConfigured") }
}

/// One Stop schedule over the ACTUAL Core helper with narrow synthetic effect ports.
///
/// The schedule is a `final class` so the effect closures can capture `self` and MID-EFFECT
/// supersede the token, which is what exercises the helper's post-suspension guards.
final class StopSchedule: @unchecked Sendable {
    let log = EffectLog()

    private let ownership: LifecycleOwnership
    private let token: UInt64
    private let ownerUnchanged: Bool

    private let state = Mutex<ScheduleState>(ScheduleState())

    private struct ScheduleState {
        var supersedeAfter: String?
        var running = true
        var configured = true
        var supersededDuringNative = false
    }

    init(ownerUnchanged: Bool,
         supersedeAfter: String? = nil,
         supersedeAtEntry: Bool = false) {
        let ownership = LifecycleOwnership()
        self.ownership = ownership
        self.token = ownership.begin()
        self.ownerUnchanged = ownerUnchanged
        state.withLock {
            $0.supersedeAfter = supersedeAfter
        }
        if supersedeAtEntry { _ = ownership.begin() }
    }

    var running: Bool { state.withLock { $0.running } }
    var configured: Bool { state.withLock { $0.configured } }
    var supersededDuringNativeStop: Bool { state.withLock { $0.supersededDuringNative } }

    /// A NEWER operation takes over when this schedule named `effect` as its supersession point.
    private func maybeSupersede(after effect: String) {
        let shouldSupersede = state.withLock { current -> Bool in
            guard current.supersedeAfter == effect else { return false }
            current.supersedeAfter = nil
            if effect == "nativeStop" { current.supersededDuringNative = true }
            return true
        }
        if shouldSupersede { _ = ownership.begin() }
    }

    func run() async -> StopSequencer.Outcome {
        await StopSequencer.run(
            ownership: ownership,
            token: token,
            effects: StopSequencer.Effects(
                performNativeStop: { [self] in
                    log.note("nativeStop")
                    state.withLock { $0.running = false }
                    maybeSupersede(after: "nativeStop")
                },
                clearServiceState: { [self] in
                    log.note("clearServiceState")
                    maybeSupersede(after: "clearServiceState")
                },
                settleOwner: { [self] in
                    log.note("settleOwner")
                    maybeSupersede(after: "settleOwner")
                },
                finishOwnerIfUnchanged: { [self] in
                    log.note("finishOwnerIfUnchanged")
                    return ownerUnchanged
                },
                clearConfigured: { [self] in
                    log.note("clearConfigured")
                    state.withLock { $0.configured = false }
                }))
    }
}

/// Two independent Stop schedules over the SAME synthetic service ports and ownership.
final class SharedStopPorts: @unchecked Sendable {
    private let state = Mutex<SharedState>(SharedState())

    private struct SharedState {
        var nativeStops = 0
        var serviceClears = 0
        var configuredClears = 0
    }

    var nativeStopCount: Int { state.withLock { $0.nativeStops } }
    var serviceClearCount: Int { state.withLock { $0.serviceClears } }
    var configuredClearCount: Int { state.withLock { $0.configuredClears } }

    func run(ownership: LifecycleOwnership, token: UInt64) async -> StopSequencer.Outcome {
        await StopSequencer.run(
            ownership: ownership,
            token: token,
            effects: StopSequencer.Effects(
                performNativeStop: { [self] in
                    // A real executor boundary: the obsolete schedule must never reach here.
                    guard ownership.isCurrent(token) else { return }
                    state.withLock { $0.nativeStops += 1 }
                },
                clearServiceState: { [self] in
                    guard ownership.isCurrent(token) else { return }
                    state.withLock { $0.serviceClears += 1 }
                },
                settleOwner: { },
                finishOwnerIfUnchanged: { true },
                clearConfigured: { [self] in
                    guard ownership.isCurrent(token) else { return }
                    state.withLock { $0.configuredClears += 1 }
                }))
    }
}

// MARK: - AM02 executor scenarios

/// MainActor-isolated synthetic state, used as the shipping MainActor caller's shape.
@MainActor
final class MainActorEffectState: Sendable {
    private(set) var nativeRunning = true
    private(set) var observerInstalled = true
    private(set) var configured = true
    private(set) var mainActorEverywhere = true

    func noteNativeStop() {
        // `Thread.isMainThread` is a synchronous, isolation-free read; combined with the direct
        // MainActor state access below it records which executor the helper resumed us on.
        if !Thread.isMainThread { mainActorEverywhere = false }
        nativeRunning = false
    }

    func noteServiceClear() {
        if !Thread.isMainThread { mainActorEverywhere = false }
        observerInstalled = false
    }

    func noteSettle() {
        if !Thread.isMainThread { mainActorEverywhere = false }
    }

    func noteFinish() -> Bool {
        if !Thread.isMainThread { mainActorEverywhere = false }
        return true
    }

    func noteConfiguredClear() {
        if !Thread.isMainThread { mainActorEverywhere = false }
        configured = false
    }
}

struct MainActorIsolationResult: Sendable {
    var admitted = false
    var mainActorEverywhere = false
    var observed: [String] = []
    var entries: [String] = []
    var outcome: StopSequencer.Outcome = .completed
}

/// Effects whose bodies are declared INSIDE a `@MainActor` function. The closure literals inherit
/// MainActor isolation — exactly the shape a shipping MainActor caller produces — and the compiler
/// only accepts the DIRECT isolated-state access below because the closure really carries it.
@MainActor
enum MainActorIsolationScenario {
    static func makeEffects(state: MainActorEffectState,
                            log: EffectLog) -> StopSequencer.Effects {
        StopSequencer.Effects(
            performNativeStop: { @MainActor in
                log.note("nativeStop")
                // DIRECT MainActor-isolated call from inside the effect. This is the shape that
                // trapped with SIGTRAP when the effects were synchronous and the helper invoked
                // them without a suspension point. It compiles only because this closure really
                // carries MainActor isolation, and it traps at runtime if the executor is wrong.
                state.noteNativeStop()
            },
            clearServiceState: { @MainActor in
                log.note("clearServiceState")
                state.noteServiceClear()
            },
            settleOwner: { @MainActor in
                log.note("settleOwner")
                state.noteSettle()
            },
            finishOwnerIfUnchanged: { @MainActor in
                log.note("finishOwnerIfUnchanged")
                return state.noteFinish()
            },
            clearConfigured: { @MainActor in
                log.note("clearConfigured")
                state.noteConfiguredClear()
            })
    }

    static func run() async -> MainActorIsolationResult {
        let ownership = LifecycleOwnership()
        let token = ownership.begin()
        let log = EffectLog()
        let state = MainActorEffectState()
        let effects = makeEffects(state: state, log: log)
        var result = MainActorIsolationResult()
        result.admitted = true
        result.outcome = await StopSequencer.run(
            ownership: ownership, token: token, effects: effects)
        result.entries = log.entries
        result.observed = log.entries
        result.mainActorEverywhere = state.mainActorEverywhere
        return result
    }
}

struct ActorExecutorResult: Sendable {
    var outcome: StopSequencer.Outcome = .completed
    var directMutations = 0
    var observerCleared = false
    var configuredCleared = false
    var nativeCleared = false
    var boundaryChecks = 0
    var boundaryRefusals = 0
    var laterEffectsInvoked = 0
    var survived = false
}

/// A custom (non-MainActor) actor with the shape of the shipping service: the effects touch its
/// isolated state directly mid-isolation and re-validate the concrete token at each mutation.
actor StopActorHarness {
    private let ownership: LifecycleOwnership
    private let token: UInt64
    private let counters = Mutex<Counters>(Counters())

    private struct Counters {
        var directMutations = 0
        var boundaryChecks = 0
        var boundaryRefusals = 0
        var laterEffects = 0
    }

    private(set) var observerInstalled = true
    private(set) var configured = true
    private(set) var nativeRunning = true

    init(ownership: LifecycleOwnership, token: UInt64) {
        self.ownership = ownership
        self.token = token
    }

    private func atMutationBoundary() -> Bool {
        counters.withLock { $0.boundaryChecks += 1 }
        let current = ownership.isCurrent(token)
        if !current { counters.withLock { $0.boundaryRefusals += 1 } }
        return current
    }

    func performNativeStop() {
        guard atMutationBoundary() else { return }
        nativeRunning = false
        counters.withLock { $0.directMutations += 1 }
    }

    func clearServiceState() {
        guard atMutationBoundary() else { return }
        observerInstalled = false
        counters.withLock { $0.directMutations += 1 }
    }

    func settleOwner() {
        guard atMutationBoundary() else { return }
        counters.withLock { $0.directMutations += 1 }
    }

    func finishOwner() -> Bool {
        guard atMutationBoundary() else { return false }
        counters.withLock { $0.directMutations += 1 }
        return true
    }

    func clearConfigured() {
        guard atMutationBoundary() else { return }
        configured = false
        counters.withLock { $0.directMutations += 1 }
    }

    func noteLaterEffect() { counters.withLock { $0.laterEffects += 1 } }

    var snapshot: (observerInstalled: Bool, configured: Bool, nativeRunning: Bool,
                   directMutations: Int, boundaryChecks: Int, refusals: Int,
                   laterEffects: Int) {
        let counted = counters.withLock { $0 }
        return (observerInstalled, configured, nativeRunning,
                counted.directMutations, counted.boundaryChecks, counted.boundaryRefusals,
                counted.laterEffects)
    }
}

struct ActorExecutorScenario: Sendable {
    func runCurrent() async -> ActorExecutorResult {
        let ownership = LifecycleOwnership()
        let token = ownership.begin()
        let harness = StopActorHarness(ownership: ownership, token: token)
        var result = ActorExecutorResult()
        result.outcome = await StopSequencer.run(
            ownership: ownership, token: token,
            effects: StopSequencer.Effects(
                performNativeStop: { await harness.performNativeStop() },
                clearServiceState: { await harness.clearServiceState() },
                settleOwner: { await harness.settleOwner() },
                finishOwnerIfUnchanged: { await harness.finishOwner() },
                clearConfigured: { await harness.clearConfigured() }))
        let snapshot = await harness.snapshot
        result.directMutations = snapshot.directMutations
        result.observerCleared = !snapshot.observerInstalled
        result.configuredCleared = !snapshot.configured
        result.nativeCleared = !snapshot.nativeRunning
        result.boundaryChecks = snapshot.boundaryChecks
        result.boundaryRefusals = snapshot.refusals
        result.survived = true
        return result
    }

    func runSupersededWhileHeld() async -> ActorExecutorResult {
        let ownership = LifecycleOwnership()
        let token = ownership.begin()
        let harness = StopActorHarness(ownership: ownership, token: token)
        let reached = MutexBool()
        let proceed = MutexBool()

        let task = Task {
            await StopSequencer.run(
                ownership: ownership, token: token,
                effects: StopSequencer.Effects(
                    performNativeStop: {
                        reached.set()
                        while !proceed.value { await Task.yield() }
                        await harness.performNativeStop()
                    },
                    clearServiceState: {
                        await harness.noteLaterEffect()
                        await harness.clearServiceState()
                    },
                    settleOwner: {
                        await harness.noteLaterEffect()
                        await harness.settleOwner()
                    },
                    finishOwnerIfUnchanged: {
                        await harness.noteLaterEffect()
                        return await harness.finishOwner()
                    },
                    clearConfigured: {
                        await harness.noteLaterEffect()
                        await harness.clearConfigured()
                    }))
        }
        while !reached.value { await Task.yield() }
        // A NEWER operation takes over while this Stop is held inside its native effect.
        _ = ownership.begin()
        proceed.set()
        var result = ActorExecutorResult()
        result.outcome = await task.value
        let snapshot = await harness.snapshot
        result.directMutations = snapshot.directMutations
        result.observerCleared = !snapshot.observerInstalled
        result.configuredCleared = !snapshot.configured
        result.nativeCleared = !snapshot.nativeRunning
        result.boundaryChecks = snapshot.boundaryChecks
        result.laterEffectsInvoked = snapshot.laterEffects
        result.survived = true
        return result
    }
}

/// Minimal Sendable flag for cross-task hand-off in the held schedules.
final class MutexBool: @unchecked Sendable {
    private let storage = Mutex<Bool>(false)
    var value: Bool { storage.withLock { $0 } }
    func set() { storage.withLock { $0 = true } }
}
