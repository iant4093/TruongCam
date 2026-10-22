import Foundation

/// An owned, root-bound security-scope lease for one reader operation.
///
/// REVIEW.md F01. Two properties are required and both are enforced here:
///
///   * **exactly-once close**, even when the token is COPIED. A copied value would
///     otherwise release the same grant twice, and with a shared counter that
///     double-release revoked a *different* live reader's scope.
///   * **identity-bound balance**: the release is applied to the exact grant this
///     token opened, never to whatever grant is current later.
///
/// The token is a `struct` so callers can pass it around freely, but its release
/// state lives in a shared reference box, so all copies observe one consumed flag.
struct ScopedReadLease: @unchecked Sendable {
    /// The exactly-once release state shared by every copy of this token.
    ///
    /// Ownership invariant for the narrow `@unchecked Sendable`: `consumed` is only
    /// read or written while `lock` is held, and the lock is never held across a
    /// suspension.
    final class Owner: @unchecked Sendable {
        let grantID: UUID
        let openedLease: Bool
        private let lock = NSLock()
        private var consumed = false
        /// Called exactly once, on the first release of any copy.
        private let onRelease: @Sendable (UUID) -> Void

        init(grantID: UUID, openedLease: Bool, onRelease: @escaping @Sendable (UUID) -> Void) {
            self.grantID = grantID
            self.openedLease = openedLease
            self.onRelease = onRelease
        }

        /// True when this call is the one that performed the release.
        ///
        /// A token that never acquired the scope (`openedLease == false`) still
        /// becomes consumed — releasing it twice is still a no-op — but it must NOT
        /// run the release hook, because it registered no reader and started no
        /// lease. REVIEW.md G01.
        @discardableResult
        func consume() -> Bool {
            lock.lock()
            guard !consumed else { lock.unlock(); return false }
            consumed = true
            let shouldRelease = openedLease
            lock.unlock()
            if shouldRelease { onRelease(grantID) }
            return true
        }

        var isConsumed: Bool {
            lock.lock(); defer { lock.unlock() }
            return consumed
        }
    }

    /// Identity of the grant this token was opened against.
    let grantID: UUID
    /// The exact root that was current when the token was opened.
    let root: URL
    let libraryID: LibraryID
    let generation: RootGeneration
    /// True when this token performed the start and must therefore perform the stop.
    var openedLease: Bool { owner.openedLease }
    /// True when the system refused the scope, so no read may proceed.
    let wasDenied: Bool
    /// The grant this token opened. Balance is applied to this instance only.
    let grant: any SecurityScopedRootGrant
    /// The shared exactly-once release state.
    private let owner: Owner

    init(
        grantID: UUID,
        root: URL,
        libraryID: LibraryID,
        generation: RootGeneration,
        openedLease: Bool,
        wasDenied: Bool,
        grant: any SecurityScopedRootGrant,
        onRelease: @escaping @Sendable (UUID) -> Void = { _ in }
    ) {
        self.grantID = grantID
        self.root = root
        self.libraryID = libraryID
        self.generation = generation
        self.wasDenied = wasDenied
        self.grant = grant
        self.owner = Owner(grantID: grantID, openedLease: openedLease, onRelease: onRelease)
    }

    var isUsable: Bool { !wasDenied }

    /// True once any copy of this token has been released.
    var isReleased: Bool { owner.isConsumed }

    /// Releases this token exactly once, whatever copy calls it.
    ///
    /// Returns true when THIS call performed the release, so a caller can run
    /// dependent cleanup only once.
    @discardableResult
    func release() -> Bool {
        owner.consume()
    }
}
