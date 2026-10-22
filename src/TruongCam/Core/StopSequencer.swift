import Foundation
import Synchronization

/// Owns the lifecycle TOKEN that tells a lifecycle operation whether it is still the current one.
///
/// A newer start does not change `PublicationIdentity`, so the token is what makes an obsolete
/// operation distinguishable. Every lifecycle operation mints a token at its start and re-validates
/// it after EVERY suspension, before each mutation.
final class LifecycleOwnership: Sendable {
    private let token = Mutex<UInt64>(0)

    /// Mints a token for a NEW lifecycle operation.
    func begin() -> UInt64 { token.withLock { $0 &+= 1; return $0 } }

    /// The current token, for an operation that must not obsolete itself.
    var current: UInt64 { token.withLock { $0 } }

    /// True when `candidate` is still the current operation.
    func isCurrent(_ candidate: UInt64) -> Bool { token.withLock { $0 == candidate } }
}

/// Runs the ordered cleanup a Stop performs, re-validating ownership at EVERY boundary.
///
/// AL01/AL02: this sequence — native stop, service clearing, owner settlement, owner finish,
/// configured clearing — must belong to the CONCRETE operation at each mutation. A Boolean verdict
/// taken once before a later awaited mutation is not sufficient, because a newer operation can take
/// over in between. The sequence is Core-owned so the shipping service AND a registered test run
/// the same algorithm.
///
/// AM01 — refusal before the first effect. The FIRST thing `run` does is refuse an operation whose
/// token is already obsolete, so an already-superseded Stop performs **zero** effects, not even the
/// native one. The previous order invoked the native stop and only then checked ownership, which
/// contradicted `Outcome.supersededBeforeNativeStop`'s own contract. Ownership is then re-read after
/// EVERY suspension — including the settlement hop, which previously had no check of its own, so a
/// Stop superseded while settling the owner still finished the owner and cleared the configured
/// state of the newer operation.
///
/// AM02 — the effect executor is part of the contract. Every effect is an `async` closure that
/// carries its OWN executor (`@isolated(any)`). The previous interface stored unqualified
/// SYNCHRONOUS `@Sendable () -> Void` closures in an `@unchecked Sendable` struct and invoked them
/// directly after a suspension in a nonisolated helper. Strict Swift 6 accepted that code, and at
/// runtime the executor check trapped (`_dispatch_assert_queue_fail` /
/// `_swift_task_checkIsolatedSwift`, SIGTRAP), because a synchronous closure has no suspension
/// point at which the callee could resume on the executor the closure actually belongs to.
///
/// An `async` effect cannot be invoked without suspension, so the callee resumes on the executor the
/// closure carries, and an actor-isolated body legally touches its own actor's state. `@isolated(any)`
/// makes that executor part of the closure's VALUE instead of something silently captured at the
/// literal, so the forwarding helper neither strips it nor has to guess it.
///
/// Contract for a caller (the shipped wiring is `AVCaptureCameraService.stop` /
/// `stopAsNestedOperation`):
///  * effect closures are `async`; an actor-isolated body touches its own actor's state directly and
///    needs no `assumeIsolated`;
///  * the caller must STILL re-validate its own concrete token inside the effect, on its own
///    executor, before a mutation whose loss would damage the newer operation. The helper's pre-hop
///    check cannot be atomic with a mutation on another executor: the token can be superseded while
///    the closure is suspended on its way to its actor. The inner check is what makes an obsolete
///    Stop safe at a real actor/native-queue boundary;
///  * `finishOwnerIfUnchanged` keeps using the owner's own snapshot comparison, because the owner
///    can be taken over by a newer application without the lifecycle token changing.
///
/// This helper proves the ORDERING/OWNERSHIP contract of the Core sequence over the ports it is
/// given. It does not prove that a shipping actor serializes `start` against an in-flight `stop`;
/// that is the shipping caller's integration responsibility.
enum StopSequencer {
    /// The effects one Stop performs, in order. Narrow ports; the caller supplies the natives.
    struct Effects: Sendable {
        var performNativeStop: @isolated(any) @Sendable () async -> Void
        var clearServiceState: @isolated(any) @Sendable () async -> Void
        var settleOwner: @isolated(any) @Sendable () async -> Void
        /// Returns false when the observed owner state is no longer in force, meaning the owner
        /// was taken over and MUST NOT be finished.
        var finishOwnerIfUnchanged: @isolated(any) @Sendable () async -> Bool
        var clearConfigured: @isolated(any) @Sendable () async -> Void
    }

    /// The outcome of running the sequence.
    enum Outcome: Equatable, Sendable {
        /// Every effect ran; this operation was current throughout.
        case completed
        /// Superseded before the native stop: NO native effect was performed.
        case supersededBeforeNativeStop
        /// Superseded after the native stop but before the service state was cleared.
        case supersededBeforeServiceClear
        /// Superseded before owner settlement, or while the owner was being settled. The owner was
        /// NOT finished and the configured state was kept, so a newer operation's state survives.
        case supersededBeforeSettlement
        /// The owner had been taken over, so it was NOT finished and the configured state was kept.
        case ownerTakenOver

        var completedCleanup: Bool { self == .completed }
    }

    /// Runs the sequence. `ownership` is re-validated after EVERY suspension.
    ///
    /// Ordering guarantee: the guard that returns `.supersededBeforeNativeStop` runs before ANY
    /// effect closure is even called, so a Stop that is already obsolete performs zero effects.
    static func run(
        ownership: LifecycleOwnership,
        token: UInt64,
        effects: Effects
    ) async -> Outcome {
        // AM01: refused BEFORE the first effect. `isCurrent` is read before any closure is called.
        guard ownership.isCurrent(token) else { return .supersededBeforeNativeStop }

        await effects.performNativeStop()
        guard ownership.isCurrent(token) else { return .supersededBeforeServiceClear }

        await effects.clearServiceState()
        // The service state has ALREADY been cleared here, so the next boundary is settlement.
        guard ownership.isCurrent(token) else { return .supersededBeforeSettlement }

        await effects.settleOwner()
        // AM01: the settlement hop is itself a suspension. Ownership is re-read BEFORE the owner is
        // finished, so a Stop superseded during settlement cannot clear the newer operation's owner
        // or configured state.
        guard ownership.isCurrent(token) else { return .supersededBeforeSettlement }

        // The owner's own snapshot comparison is still authoritative: a newer application can take
        // over the owner without this Stop being the operation that superseded the lifecycle token.
        guard await effects.finishOwnerIfUnchanged() else { return .ownerTakenOver }
        guard ownership.isCurrent(token) else { return .ownerTakenOver }

        await effects.clearConfigured()
        return .completed
    }
}
