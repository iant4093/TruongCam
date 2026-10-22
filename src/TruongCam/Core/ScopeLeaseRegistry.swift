import Foundation

/// Per-grant security-scope accounting.
///
/// REVIEW.md F01. The previous design tracked a single global reader count and a
/// replaceable "current selection" slot. Two concrete failures followed:
///
///   * a copied lease token released twice decremented the global count twice, so
///     closing one reader could revoke a different live reader's scope;
///   * the deferred selection revocation was one global flag, so releasing root A
///     and then selecting B meant A's reader close stopped B's selection.
///
/// Every counter here is keyed by the grant's own `leaseIdentity`, and nothing ever
/// consults "the current root". A grant that still has readers is never stopped
/// behind their backs; a grant with no readers stops exactly once.
///
/// Ownership invariant for the narrow `@unchecked Sendable`: `grants` is only read
/// or written while `lock` is held, and the calls made under it are non-blocking
/// bookkeeping on already-owned values.
final class ScopeLeaseRegistry: @unchecked Sendable {
    /// Accounting for one exact grant.
    struct GrantState: Sendable {
        /// True while this grant's SELECTION lease is open and must be stopped.
        var selectionLeaseOpen = false
        /// Readers currently holding a lease on this grant.
        var activeReaders = 0
        /// A selection stop was requested while readers were active.
        var selectionStopDeferred = false
    }

    private let lock = NSLock()
    private var grants: [UUID: GrantState] = [:]

    // MARK: Selection lease

    /// Records that this grant opened its selection lease.
    func openSelectionLease(_ grantID: UUID) {
        lock.lock(); defer { lock.unlock() }
        var state = grants[grantID] ?? GrantState()
        state.selectionLeaseOpen = true
        state.selectionStopDeferred = false
        grants[grantID] = state
    }

    /// Requests the selection lease for `grantID` be stopped.
    ///
    /// Returns true when the caller should stop it NOW. Returns false when readers
    /// are still active, in which case the stop is deferred to exactly the last
    /// reader of THAT grant.
    func requestSelectionStop(_ grantID: UUID) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard var state = grants[grantID] else { return false }
        guard state.selectionLeaseOpen else { return false }
        if state.activeReaders > 0 {
            state.selectionStopDeferred = true
            grants[grantID] = state
            return false
        }
        state.selectionLeaseOpen = false
        state.selectionStopDeferred = false
        grants[grantID] = state
        return true
    }

    // MARK: Readers

    /// Registers a reader against an exact grant.
    func registerReader(for grantID: UUID) {
        lock.lock(); defer { lock.unlock() }
        var state = grants[grantID] ?? GrantState()
        state.activeReaders += 1
        grants[grantID] = state
    }

    /// Unregisters one reader from an exact grant.
    ///
    /// Returns true when this was the LAST reader of a grant whose selection stop
    /// was deferred, so the caller must now stop that specific selection lease.
    /// Returns the grant that must be stopped, so the caller never guesses.
    func unregisterReader(for grantID: UUID) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard var state = grants[grantID] else { return false }
        state.activeReaders = max(0, state.activeReaders - 1)
        guard state.activeReaders == 0, state.selectionStopDeferred, state.selectionLeaseOpen else {
            grants[grantID] = state
            return false
        }
        state.selectionLeaseOpen = false
        state.selectionStopDeferred = false
        grants[grantID] = state
        return true
    }

    /// True while a selection lease for this grant is open.
    func isSelectionLeaseOpen(_ grantID: UUID) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return grants[grantID]?.selectionLeaseOpen ?? false
    }

    // MARK: Diagnostics

    var totalActiveReaders: Int {
        lock.lock(); defer { lock.unlock() }
        return grants.values.reduce(0) { $0 + $1.activeReaders }
    }

    func activeReaders(for grantID: UUID) -> Int {
        lock.lock(); defer { lock.unlock() }
        return grants[grantID]?.activeReaders ?? 0
    }

    /// Forgets a grant entirely once it holds no leases. Keeps the table bounded.
    func forget(_ grantID: UUID) {
        lock.lock(); defer { lock.unlock() }
        guard let state = grants[grantID] else { return }
        guard !state.selectionLeaseOpen, state.activeReaders == 0 else { return }
        grants.removeValue(forKey: grantID)
    }
}
