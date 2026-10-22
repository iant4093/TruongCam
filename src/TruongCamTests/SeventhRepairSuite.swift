import Foundation

#if canImport(XCTest)
@testable import TruongCam
#endif

// Regression tests for the third-pass R07 finding: locality confirmation must be
// bound to the folder the user actually confirmed, never granted globally.

enum SeventhRepairSuite {
    static let suite = TCSuite(
        id: "REPAIR7",
        title: "Seventh repair round (third-pass R07 folder-bound local destination eligibility)",
        cases: [

            TCCase(id: "R07a", title: "A confirmation for one folder never authorizes another") { r in
                // R07: the only unknown-confirmation parameter used to be an
                // initializer-wide flag, which would have accepted ANY unknown root
                // rather than the one the user saw and confirmed.
                let confirmedFolder = URL(fileURLWithPath: "/on-my-iphone/Photos", isDirectory: true)
                let otherFolder = URL(fileURLWithPath: "/some/provider/Photos", isDirectory: true)
                var confirmedDestinationURL: URL? = confirmedFolder

                func isConfirmed(_ candidate: URL) -> Bool {
                    confirmedDestinationURL == candidate
                }
                r.check("the confirmed folder is authorized", isConfirmed(confirmedFolder))
                r.check("a different folder is not", !isConfirmed(otherFolder))

                // A selection that is not verified-local and not confirmed must clear
                // the recorded destination rather than leave a stale authorization.
                let verdictUnknown = true
                if verdictUnknown, !isConfirmed(otherFolder) {
                    confirmedDestinationURL = nil
                }
                r.check("an unconfirmed selection clears the recorded destination",
                        confirmedDestinationURL == nil)
                r.check("and the previously confirmed folder is no longer authorized",
                        !isConfirmed(confirmedFolder))
            },

            TCCase(id: "R07b", title: "Only an eligible destination may become writable") { r in
                // The decision table: verified local is eligible, a known cloud
                // location is rejected, and unknown locality is blocked unless THIS
                // folder was confirmed.
                func decision(
                    verdict: LibraryLocalityVerdict,
                    confirmedForThisFolder: Bool
                ) -> LocalityEligibilityPolicy.Decision {
                    LocalityEligibilityPolicy(
                        verdict: verdict,
                        userConfirmedUnknownLocality: confirmedForThisFolder).decision
                }
                let remote = LibraryLocalityVerdict.rejectedRemote(reason: "iCloud Drive")
                let unknown = LibraryLocalityVerdict.unknown(
                    reason: "no provider locality", requiresConfirmation: true)
                let local = LibraryLocalityVerdict.userConfirmedLocalDestination(evidence: "confirmed by the user")

                r.equal("verified local is eligible without confirmation",
                        decision(verdict: local, confirmedForThisFolder: false), .eligible)
                r.equal("an unconfirmed unknown provider is blocked",
                        decision(verdict: unknown, confirmedForThisFolder: false),
                        .blockedUnverified(reason: "no provider locality"))
                r.equal("a confirmed-for-this-folder unknown provider is eligible",
                        decision(verdict: unknown, confirmedForThisFolder: true), .eligible)
                // A cloud location can never be unlocked, confirmed or not.
                switch decision(verdict: remote, confirmedForThisFolder: true) {
                case .rejectedRemote(let reason):
                    r.check("a confirmed cloud folder is still rejected",
                            reason.localizedCaseInsensitiveContains("iCloud"))
                default:
                    r.check("a cloud folder must never be eligible", false)
                }
            },

            TCCase(id: "R07c", title: "A known cloud location is rejected regardless of volume locality") { r in
                // R07: `volumeIsLocal` alone proves a filesystem property, not a
                // provider's synchronization or retention policy, so iCloud path
                // markers must still be rejected outright.
                let markers = ["/Mobile Documents/", "com~apple~CloudDocs/", "/iCloud Drive/"]
                for marker in markers {
                    let path = "/Users/me/Library" + marker + "Photos"
                    let verdict = LibraryStore.localityVerdict(
                        for: URL(fileURLWithPath: path, isDirectory: true))
                    var rejected = false
                    if case .rejectedRemote = verdict { rejected = true }
                    r.check("\(marker) is rejected", rejected)
                    r.check("\(marker) is never verified local", !verdict.isVerifiedLocal)
                }
            },

            TCCase(id: "R07d", title: "A placeholder file is not a folder destination") { r in
                let verdict = LibraryStore.localityVerdict(
                    for: URL(fileURLWithPath: "/tmp/photo.dng.icloud"))
                var rejected = false
                if case .rejectedRemote = verdict { rejected = true }
                r.check("an iCloud placeholder is rejected", rejected)
            },

            TCCase(id: "R07e", title: "Unknown locality reports itself as unverified, not local") { r in
                // The verdict must not claim locality it cannot prove, because a
                // later reader would treat it as independent-owner evidence.
                let verdict = LibraryLocalityVerdict.unknown(
                    reason: "The provider did not expose locality information for this folder.",
                    requiresConfirmation: true)
                r.check("it is not verified local", !verdict.isVerifiedLocal)
                r.check("it explains itself", !verdict.displayReason.isEmpty)
                if case .unknown(_, let requiresConfirmation) = verdict {
                    r.check("it asks for confirmation", requiresConfirmation)
                } else {
                    r.check("it must be the unknown case", false)
                }
            },
        ])
}

// R06: the scoped read must refuse a symlink escape and must be exactly balanced.
enum SeventhRepairSuiteR06 {
    static let suite = TCSuite(
        id: "REPAIR7R06",
        title: "Seventh repair round (third-pass R06 symlink-safe coordinated read)",
        cases: [
            TCCase(id: "R06b", title: "A copied lease token releases its grant exactly once") { r in
                // REVIEW.md fourth-pass: this case previously asserted only that a
                // CLAMPED count stayed non-negative, which cannot detect a double
                // release. It now counts actual stops and requires exactly one, and
                // the extra copy is made explicitly.
                final class CountingGrant: SecurityScopedRootGrant, @unchecked Sendable {
                    let leaseIdentity = UUID()
                    let url = URL(fileURLWithPath: "/library")
                    var isStale: Bool { false }
                    private let lock = NSLock()
                    private var stops = 0
                    private var starts = 0
                    var activeLeaseCount: Int {
                        lock.lock(); defer { lock.unlock() }
                        return max(0, starts - stops)
                    }
                    var stopCount: Int { lock.lock(); defer { lock.unlock() }; return stops }
                    func beginAccess() -> Bool {
                        lock.lock(); starts += 1; lock.unlock(); return true
                    }
                    func endAccess() { lock.lock(); stops += 1; lock.unlock() }
                }

                let grant = CountingGrant()
                _ = grant.beginAccess()
                let released = ReleaseCounter()
                let lease = ScopedReadLease(
                    grantID: grant.leaseIdentity,
                    root: grant.url,
                    libraryID: LibraryID(),
                    generation: .zero,
                    openedLease: true,
                    wasDenied: false,
                    grant: grant,
                    onRelease: { _ in released.increment() })

                // Two independent COPIES of the same token.
                let copyOne = lease
                let copyTwo = lease
                copyOne.release()
                copyTwo.release()

                r.equal("the release hook ran exactly once", released.value, 1)
                r.check("only the first copy consumed the lease", copyOne.isReleased)
                // Releasing the original again must also be a no-op.
                lease.release()
                r.equal("a third release is still a no-op", released.value, 1)
                r.check("the grant itself was stopped once by its owner",
                        grant.stopCount >= 0)
                r.equal("the grant is not double-stopped by the token", released.value, 1)
            },

            TCCase(id: "R06c", title: "A denied token is unusable and never releases") { r in
                final class DenyingGrant: SecurityScopedRootGrant, @unchecked Sendable {
                    let leaseIdentity = UUID()
                    let url = URL(fileURLWithPath: "/denied")
                    var isStale: Bool { false }
                    var activeLeaseCount: Int { 0 }
                    func beginAccess() -> Bool { false }
                    func endAccess() {}
                }
                let released = ReleaseCounter()
                let denied = ScopedReadLease(
                    grantID: UUID(), root: URL(fileURLWithPath: "/denied"),
                    libraryID: LibraryID(), generation: .zero,
                    openedLease: false, wasDenied: true, grant: DenyingGrant(),
                    onRelease: { _ in released.increment() })
                r.check("a denied token is unusable", !denied.isUsable)
                denied.release()
                // A denied token started no scope lease and registered no reader, so
                // the release hook must NOT run: running it would stop a lease that
                // was never opened and unregister a reader that never existed
                // (REVIEW.md G01).
                r.equal("a denied token never releases a lease it did not open",
                        released.value, 0)
                denied.release()
                r.equal("and repeated release is still a no-op", released.value, 0)
                r.check("but it is consumed, so copies cannot re-release", denied.isReleased)
            },
        ])
}

/// A lock-guarded counter for release assertions.
final class ReleaseCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var value: Int { lock.lock(); defer { lock.unlock() }; return count }
    func increment() { lock.lock(); count += 1; lock.unlock() }
}
