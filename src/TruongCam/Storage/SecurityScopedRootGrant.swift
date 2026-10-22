import Foundation
import Synchronization

// LIBRARY.md "Selecting and reconnecting a library": retain access to the
// selected directory with a bookmark created using the iOS-supported options,
// and match every successful `startAccessingSecurityScopedResource` with exactly
// one `stopAccessingSecurityScopedResource`.
//
// iOS scopes a bookmark created from a user-granted document-picker URL itself.
// `URL.BookmarkCreationOptions.withSecurityScope` is macOS-only
// (API_UNAVAILABLE(ios)), so this type never touches it.

/// The system calls behind the lease. Injected so tests can prove balanced
/// bookkeeping and revoked-scope behaviour without a sandbox.
protocol SecurityScopeDriver: Sendable {
    func startAccess(_ url: URL) -> Bool
    func stopAccess(_ url: URL)
}

struct SystemSecurityScopeDriver: SecurityScopeDriver {
    func startAccess(_ url: URL) -> Bool { url.startAccessingSecurityScopedResource() }
    func stopAccess(_ url: URL) { url.stopAccessingSecurityScopedResource() }
}

#if DEBUG || TC_PORTABLE_VERIFIER
/// Deterministic test driver. Returns the requested grant results in order.
final class ScriptedSecurityScopeDriver: SecurityScopeDriver {
    private let grants: [Bool]
    private let counter = Mutex<Int>(0)

    init(grants: [Bool] = [true]) { self.grants = grants }

    func startAccess(_ url: URL) -> Bool {
        counter.withLock { index in
            guard !grants.isEmpty else { return false }
            let grant = grants[min(index, grants.count - 1)]
            index += 1
            return grant
        }
    }

    func stopAccess(_ url: URL) {}
}

#endif

final class BookmarkRootGrant: SecurityScopedRootGrant {
    private struct LeaseState {
        var activeLeases = 0
        var beginAttempts = 0
        var deniedBegins = 0
        var endAccessCalls = 0
    }

    let url: URL
    let isStale: Bool
    /// Identity of this specific grant instance.
    let leaseIdentity = UUID()
    private let driver: SecurityScopeDriver
    private let state = Mutex(LeaseState())

    /// Wraps a URL the system already granted (the document-picker result).
    convenience init(url: URL, stale: Bool = false, driver: SecurityScopeDriver = SystemSecurityScopeDriver()) {
        self.init(resolvedURL: url, stale: stale, driver: driver)
    }

    /// Resolves a retained bookmark. Throws when the bookmark can no longer be
    /// resolved, which the caller must surface as an actionable reconnect.
    convenience init(bookmarkData: Data, driver: SecurityScopeDriver = SystemSecurityScopeDriver()) throws {
        var stale = false
        let resolved: URL
        do {
            resolved = try URL(resolvingBookmarkData: bookmarkData,
                               options: [],
                               relativeTo: nil,
                               bookmarkDataIsStale: &stale)
        } catch {
            throw FileAdapterError.classify(error)
        }
        self.init(resolvedURL: resolved, stale: stale, driver: driver)
    }

    private init(resolvedURL: URL, stale: Bool, driver: SecurityScopeDriver) {
        // The picker/bookmark URL carries the sandbox extension. A new URL made
        // by path normalization need not carry that authority. Normalize only
        // for comparisons, never the URL used to start access or make a bookmark.
        self.url = resolvedURL
        self.isStale = stale
        self.driver = driver
    }

    /// Creates a bookmark with the iOS-supported minimal option set.
    func bookmarkData() throws -> Data {
        do {
            return try url.bookmarkData(options: .minimalBookmark,
                                        includingResourceValuesForKeys: nil,
                                        relativeTo: nil)
        } catch {
            throw FileAdapterError.classify(error)
        }
    }

    func beginAccess() -> Bool {
        let granted = driver.startAccess(url)
        state.withLock { current in
            current.beginAttempts += 1
            if granted { current.activeLeases += 1 } else { current.deniedBegins += 1 }
        }
        return granted
    }

    func endAccess() {
        let shouldStop = state.withLock { current -> Bool in
            current.endAccessCalls += 1
            guard current.activeLeases > 0 else { return false }
            current.activeLeases -= 1
            return true
        }
        // Exactly one stop call per successful start: an unbalanced extra end
        // never reaches the system and never drives the count negative.
        if shouldStop { driver.stopAccess(url) }
    }

    // MARK: lease bookkeeping (observable so tests can prove balance)

    /// Successfully started leases that have not been stopped yet.
    var activeLeaseCount: Int { state.withLock { $0.activeLeases } }
    var isBalanced: Bool { state.withLock { $0.activeLeases == 0 } }
    var beginAttemptCount: Int { state.withLock { $0.beginAttempts } }
    var deniedBeginCount: Int { state.withLock { $0.deniedBegins } }
    var endAccessCallCount: Int { state.withLock { $0.endAccessCalls } }
}
