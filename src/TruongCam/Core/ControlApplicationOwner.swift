import Foundation

/// App-owned correlation between an issued control application and the observations that
/// belong to it.
///
/// REVIEW.md L01: the revision/target bookkeeping lived inside the AVFoundation adapter,
/// which the portable verifier does not compile — so tests could only ever drive a
/// coordinator against a prebuilt snapshot. This owner is platform-neutral, holds the
/// identity scheme and the settlement target, and `AVCaptureCameraService` USES it, so the
/// algorithm that ships is the algorithm the tests execute.
///
/// This is an app interface, not an Apple API.
actor ControlApplicationOwner {

    /// The identity of ONE issued application.
    struct Application: Hashable, Sendable {
        /// A UNIQUE identity for this concrete issuance, minted by the owner.
        ///
        /// N01: the requested revision alone is not an operation identity — the same
        /// desired revision is legitimately reapplied during startup/recovery — so two
        /// distinct issuances must never compare equal.
        let operationID: UUID = UUID()
        /// The request revision this application was issued under.
        let revision: UInt64
        /// The configuration generation it belongs to. A completion or observation from
        /// another generation can never belong to it.
        let generation: ConfigurationGeneration
    }

    /// How one issued application ended.
    enum CompletionOutcome: Equatable, Sendable {
        /// Every issued native setter callback arrived.
        case acknowledged
        /// The deadline passed with callbacks still outstanding. Those callbacks stay
        /// owned by their group and are never reported as arrival.
        case timedOut
        /// The application was superseded or abandoned before completing.
        case obsolete
        /// No setter was issued, so there was nothing to wait for.
        case nothingIssued
    }

    /// One issuance: the identity plus the group its native callbacks report into.
    struct Issuance: Sendable {
        let application: Application
        let completions: SetterCompletionGroup
    }

    /// The settlement window. Owned HERE so the algorithm that decides whether a reading
    /// is settled is the same one that decides whether a reading belongs to the operation.
    private var settlement = ControlSettlementTracker()
    private var current: Application?
    private var currentTarget: ControlSettlementPolicy.Target = .none
    private var pending: Application?
    /// The operation whose result was PUBLISHED as current. Set only by `publish`, in the
    /// same actor turn as the currentness check (REVIEW.md T01).
    private var published: Application?
    /// The applied snapshot that was published WITH `published`, in the same actor turn.
    private var publishedSnapshot: AppliedControlSnapshot?
    /// AO01: which application the LIVE settlement window belongs to. `endSettlement` must never
    /// clear the window of the application that is still current — that window is a valid, in-force
    /// settlement, and an obsolete cleanup must not erase it.
    private var settlementOwner: Application?

    /// The application currently in force, if any.
    var currentApplication: Application? { current }

    /// The settlement target bound to the current application.
    var target: ControlSettlementPolicy.Target { currentTarget }

    /// Opens an application under a new identity.
    ///
    /// The identity is minted HERE, so a caller cannot invent a colliding one and two
    /// unrelated counters cannot be mistaken for the same application.
    @discardableResult
    func begin(
        revision: UInt64,
        generation: ConfigurationGeneration
    ) -> Application {
        let application = Application(revision: revision, generation: generation)
        // PENDING, not current: the accepted application and its target stay in force
        // until this one is validated and accepted. A rejected or failed successor
        // therefore leaves the last valid state untouched (REVIEW.md M01).
        pending = application
        return application
    }

    /// Opens an issuance: the identity AND the completion group its setters report into.
    func beginIssuance(
        revision: UInt64,
        generation: ConfigurationGeneration
    ) -> Issuance {
        Issuance(application: begin(revision: revision, generation: generation),
                 completions: SetterCompletionGroup())
    }

    /// Waits a bounded time for this issuance's native callbacks and classifies the
    /// outcome. A missing callback can never be reported as arrival, and an application
    /// superseded while waiting is `obsolete` rather than acknowledged.
    func awaitCompletion(
        _ issuance: Issuance,
        timeoutSeconds: Double
    ) async -> CompletionOutcome {
        guard isOwned(issuance.application) else { return .obsolete }
        let arrived = await issuance.completions.awaitAll(timeoutSeconds: timeoutSeconds)
        guard isOwned(issuance.application) else { return .obsolete }
        guard arrived else {
            // The deadline passed with callbacks outstanding: this issuance is abandoned
            // so it can never be accepted behind the caller's back.
            pending = nil
            return .timedOut
        }
        return .acknowledged
    }

    /// Opens the settlement window for a newly acknowledged operation: the target it was
    /// validated against, and a cleared stability history.
    func beginSettlement(target: ControlSettlementPolicy.Target) {
        settlement.setTarget(target)
    }

    /// Clears the settlement window at a stop/reset/terminal boundary, so a later reading
    /// cannot settle against a previous operation's target.
    func endSettlement() {
        settlement.restart()
        settlement.setTarget(nil)
    }

    /// Ends the settlement window ONLY while `observed` is still the application in force.
    ///
    /// AN01: the shipping Stop called `endSettlement()` unconditionally. Core ownership was checked
    /// before and after that awaited callback, but not AT the actor mutation it performs, so a newer
    /// application that took over while the effect was queued had its settlement window and target
    /// destroyed. The check and the mutation now happen in ONE actor turn.
    @discardableResult
    func endSettlement(
        ifOwnedBy observed: Application?,
        authorityIsCurrent: @Sendable () -> Bool
    ) -> Bool {
        // Read concrete operation authority HERE, in the same actor turn as the mutation.
        // A Boolean computed before the actor hop can be true even after Stop/reset took over.
        // Current legitimate cleanup succeeds; newer accepted/pending windows remain untouched.
        guard current == observed else { return false }
        guard authorityIsCurrent() else { return false }
        guard pending == nil else { return false }
        endSettlement()
        settlementOwner = nil
        return true
    }

    /// The settlement state for a reading, but ONLY while `application` is still the
    /// operation in force. A reading from a superseded operation reports `.moving` rather
    /// than borrowing the current operation's settled history.
    func settle(
        _ snapshot: AppliedControlSnapshot,
        for application: Application
    ) -> ControlSettlementState {
        guard isOwned(application) else { return .moving }
        settlementOwner = application
        return settlement.observe(snapshot)
    }

    /// What the native port reported about issuing this operation.
    enum IssueDecision: Sendable {
        /// The validator accepted the request and the native setters were issued.
        case applied
        /// The validator refused the request before any native setter ran.
        case rejected
        /// The native issue step itself failed.
        case failed
    }

    /// How one complete control operation ended.
    enum OperationOutcome: Sendable {
        /// Issued, acknowledged and bound. The payload is the IMMUTABLE RECEIPT of the
        /// operation that actually completed, so a caller never correlates its result by
        /// looking up whichever operation happens to be current afterwards.
        case bound(Application)
        /// The validator refused the request before any native setter ran.
        case rejected
        /// The native issue step itself failed.
        case issueFailed
        /// The callbacks did not arrive within the deadline; the operation was abandoned.
        case timedOut
        /// A newer operation superseded this one before it completed.
        case obsolete
    }

    /// Runs ONE COMPLETE control operation.
    ///
    /// R01: this is the owned algorithm — issue, callback, acceptance, target binding and
    /// settlement-window restart happen in here, in this order, for every caller. The
    /// `issue` closure is the thin native port: it performs the SDK binding for this
    /// operation and reports what the validator decided.
    func runOperation(
        revision: UInt64,
        generation: ConfigurationGeneration,
        timeoutSeconds: Double,
        issue: sending (SetterCompletionGroup) async -> (
            decision: IssueDecision,
            target: ControlSettlementPolicy.Target
        )
    ) async -> OperationOutcome {
        let issuance = beginIssuance(revision: revision, generation: generation)
        let application = issuance.application
        let issued = await issue(issuance.completions)
        switch issued.decision {
        case .failed:
            abandon(application)
            return .issueFailed
        case .rejected:
            // Validation refused it, so the accepted operation and its window are left
            // EXACTLY as they were, and the rejection never binds a target.
            abandon(application)
            return .rejected
        case .applied:
            switch await awaitCompletion(issuance, timeoutSeconds: timeoutSeconds) {
            case .acknowledged, .nothingIssued:
                // Accepted-and-bound only at the acknowledged current-operation boundary;
                // accepting also restarts the settlement window with this request's target.
                guard accept(application, target: issued.target) else {
                    return .obsolete
                }
                beginSettlement(target: issued.target)
                return .bound(application)
            case .timedOut:
                return .timedOut
            case .obsolete:
                return .obsolete
            }
        }
    }

    /// Atomically publishes `receipt` as the bound operation IF it is still the operation in
    /// force.
    ///
    /// T01: the check and the mutation are the same actor turn, so a supersession cannot
    /// interleave between them — unlike an awaited Boolean verdict followed by a mutation.
    /// Returns false when a newer operation has taken over, in which case NOTHING is
    /// published and the newer operation's state is untouched.
    func publish(_ receipt: Application, snapshot: AppliedControlSnapshot) -> Bool {
        // U01: currentness, the receipt AND the applied snapshot are one atomic decision, so
        // no suspension can separate them and A can never publish over a newer B.
        guard current == receipt else { return false }
        published = receipt
        publishedSnapshot = snapshot
        return true
    }

    /// The applied snapshot published with `publishedApplication`, if any.
    var publishedAppliedSnapshot: AppliedControlSnapshot? { publishedSnapshot }

    /// The operation whose result is currently published, if any.
    var publishedApplication: Application? { published }

    /// Observes a reading and confirms the operation is still current IN THE SAME ACTOR
    /// TURN. `nil` means the reading must NOT be published — the operation was superseded
    /// while settlement was being computed.
    func settleIfCurrent(
        _ snapshot: AppliedControlSnapshot,
        for application: Application
    ) -> ControlSettlementState? {
        guard current == application else { return nil }
        return settlement.observe(snapshot)
    }

    /// Whether this concrete operation is still the one in force (pending or current).
    ///
    /// Identity, not just revision: a superseded same-revision issuance is NOT owned.
    func isOwned(_ application: Application) -> Bool {
        pending == application || current == application
    }

    /// Marks an application accepted and binds the target it was validated against.
    ///
    /// Returns false when `application` is no longer the current one — an obsolete,
    /// rejected or superseded request — so a late acceptance cannot bind a stale target.
    @discardableResult
    func accept(
        _ application: Application,
        target: ControlSettlementPolicy.Target
    ) -> Bool {
        // Accept is valid from PENDING (wait-then-accept) or from CURRENT (an idempotent
        // repeat of the same concrete operation).
        guard pending == application || current == application else { return false }
        // O01: clear `pending` ONLY when this acceptance is the one that promotes it. An
        // idempotent repeat of the already-current operation must NOT abandon a newer
        // issuance that was begun in between.
        // Q01: only the acceptance that PROMOTES the operation binds its target. A repeat
        // acceptance of the already-current operation is idempotent and must not rewrite an
        // immutable accepted target.
        let isPromotion = pending == application
        if isPromotion { pending = nil }
        if isPromotion || current != application { currentTarget = target }
        current = application
        settlementOwner = application
        return true
    }

    /// Whether an observation carrying `revision`/`generation` belongs to the CURRENT
    /// application. Absent or mismatched correlation is a refusal, never an assumption.
    /// Whether `application` is the concrete operation in force.
    ///
    /// Q01: this takes the OPERATION TOKEN. Revision + generation cannot identify an
    /// operation — two issuances that share both are still distinct — so a revision-only
    /// check would wrongly confirm a stale same-revision reading.
    func observationBelongs(_ application: Application?) -> Bool {
        guard let application else { return false }
        // ACCEPTED only: an issuance that was merely begun, or that was rejected, cannot
        // authorize a reading to be published as the current settled state.
        return current == application
    }

    /// Forgets the current application at a terminal boundary.
    /// Abandons a pending application without touching the accepted one.
    func abandon(_ application: Application) {
        guard pending == application else { return }
        pending = nil
    }

    func finish() {
        endSettlement()
        settlementOwner = nil
        current = nil
        currentTarget = .none
        pending = nil
        published = nil
        publishedSnapshot = nil
    }

    /// Clears the owner's state ONLY if the application is still the one the caller observed.
    ///
    /// AI02: the check and the clear happen in a SINGLE actor turn, so an owner operation that
    /// became newer while the caller was suspended is not deleted by that obsolete caller. Returns
    /// true when this call cleared the owner.
    @discardableResult
    func finish(ifCurrentIs observed: Application?, pending pendingObserved: Application?) -> Bool {
        guard current == observed, pending == pendingObserved else { return false }
        finish()
        return true
    }

    /// The full owner state a caller observes before an awaited cleanup, so the conditional
    /// finish can tell whether ANY newer ownership (accepted OR pending) took over (AJ02).
    var ownershipSnapshot: Ownership {
        Ownership(current: current, pending: pending)
    }

    struct Ownership: Equatable, Sendable {
        let current: Application?
        let pending: Application?
    }

    /// Clears the owner only if the FULL observed ownership is still in force.
    @discardableResult
    func finish(ifUnchangedSince observed: Ownership,
                authorityIsCurrent: @Sendable () -> Bool = { true }) -> Bool {
        guard authorityIsCurrent(), ownershipSnapshot == observed else { return false }
        finish()
        return true
    }
}
