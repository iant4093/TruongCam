import CryptoKit
import ImageIO
import Foundation
import Synchronization
import UniformTypeIdentifiers

// LIBRARY.md "Staging and save protocol", "Idempotent recovery", "Gallery
// rebuilding" + CONTRACTS.md "Folder protocol hardening" and
// "Camera, source and library state".
//
// LibraryStore owns the authoritative folder. Its rules, in order of importance:
//   * an original is only reported as committed after the FINAL bytes are
//     re-read, hashed and paired with a validated matching sidecar;
//   * active originals are never overwritten; viewer deletion moves verified
//     files to Trash. Explicit confirmed permanent deletion is restricted to
//     exact verified Trash files, with a durable retryable intent;
//   * internal recovery staging (Application Support) is never used as a cache;
//   * every failure is a typed `CaptureFailure` with the retained-source status.

// MARK: - Retained bookmark storage

/// Persistence for the retained security-scoped bookmark. Injectable so tests
/// never touch the real user defaults.
protocol RootBookmarkStoring: Sendable {
    func loadBookmarkData() -> Data?
    func saveBookmarkData(_ data: Data)
    func clear()
    /// The exact folder the user confirmed as an independent local destination.
    ///
    /// REVIEW.md G05: the decision is bound to a specific folder, so it is stored
    /// beside the bookmark. Nil means nothing was confirmed, and a DIFFERENT
    /// destination never inherits a previous decision.
    func loadConfirmedDestination() -> URL?
    func saveConfirmedDestination(_ url: URL?)
    /// The library identity the confirmation belongs to, so a rebound bookmark for a
    /// different library cannot reuse it.
    func loadConfirmedLibraryID() -> LibraryID?
    func saveConfirmedLibraryID(_ id: LibraryID?)
}

/// Ownership invariant for the narrow `@unchecked Sendable`: `UserDefaults` is
/// documented as thread-safe for concurrent reads and writes, and this type adds no
/// mutable state of its own, so the reference can cross concurrency domains safely.
struct UserDefaultsRootBookmarkStore: RootBookmarkStoring, @unchecked Sendable {
    /// The defaults domain. `.standard` in production; injectable so a test can use its
    /// own isolated suite instead of the process-global domain.
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    static let key = "com.truongcam.library.rootBookmark"

    static let destinationKey = "com.truongcam.library.confirmedDestination"
    static let destinationLibraryKey = "com.truongcam.library.confirmedDestinationLibrary"

    func loadBookmarkData() -> Data? { defaults.data(forKey: Self.key) }
    func saveBookmarkData(_ data: Data) { defaults.set(data, forKey: Self.key) }
    func clear() {
        defaults.removeObject(forKey: Self.key)
        defaults.removeObject(forKey: Self.destinationKey)
        defaults.removeObject(forKey: Self.destinationLibraryKey)
    }

    func loadConfirmedDestination() -> URL? {
        guard let path = defaults.string(forKey: Self.destinationKey) else { return nil }
        return URL(fileURLWithPath: path, isDirectory: true)
    }

    func saveConfirmedDestination(_ url: URL?) {
        if let url {
            defaults.set(url.standardizedFileURL.path, forKey: Self.destinationKey)
        } else {
            defaults.removeObject(forKey: Self.destinationKey)
        }
    }

    func loadConfirmedLibraryID() -> LibraryID? {
        guard let raw = defaults.string(forKey: Self.destinationLibraryKey) else { return nil }
        guard let uuid = UUID(uuidString: raw) else { return nil }
        return LibraryID(uuid)
    }

    func saveConfirmedLibraryID(_ id: LibraryID?) {
        if let id {
            defaults.set(id.rawValue.uuidString, forKey: Self.destinationLibraryKey)
        } else {
            defaults.removeObject(forKey: Self.destinationLibraryKey)
        }
    }
}

#if DEBUG || TC_PORTABLE_VERIFIER
final class InMemoryRootBookmarkStore: RootBookmarkStoring {
    private let state = Mutex<Data?>(nil)
    private let destination = Mutex<URL?>(nil)
    private let destinationLibrary = Mutex<LibraryID?>(nil)

    func loadBookmarkData() -> Data? { state.withLock { $0 } }
    func saveBookmarkData(_ data: Data) { state.withLock { $0 = data } }
    func clear() {
        state.withLock { $0 = nil }
        destination.withLock { $0 = nil }
        destinationLibrary.withLock { $0 = nil }
    }

    func loadConfirmedDestination() -> URL? { destination.withLock { $0 } }

    func saveConfirmedDestination(_ url: URL?) {
        destination.withLock { $0 = url?.standardizedFileURL }
    }

    func loadConfirmedLibraryID() -> LibraryID? { destinationLibrary.withLock { $0 } }

    func saveConfirmedLibraryID(_ id: LibraryID?) { destinationLibrary.withLock { $0 = id } }
}

#endif

// MARK: - Serialization gate

/// FIFO mutual exclusion for root-mutating work. The actor already serialises
/// synchronous state changes, but an `await` inside a commit would otherwise let
/// a second commit or a root switch interleave with it (TEST_PLAN.md T14/T15).
actor LibraryMutationGate {
    private var isHeld = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func acquire() async {
        if !isHeld {
            isHeld = true
            return
        }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }
    func release() {
        if waiters.isEmpty {
            isHeld = false
        } else {
            // Ownership transfers directly to the next waiter; the gate stays
            // held so a third caller cannot slip in.
            waiters.removeFirst().resume()
        }
    }
}

// MARK: - LibraryStore

actor LibraryStore: LibraryStoring {
    // MARK: injected dependencies

    private let adapter: FileSystemAdapter
    private let coordinator: CoordinatedFileMutator
    private let wallClock: WallClock
    private let supportDirectory: URL
    private let temporaryDirectory: URL
    private let ownedContainerURLs: [URL]
    private let bookmarkStore: RootBookmarkStoring
    private let capacityReserveBytes: Int64
    private let scanRoundBudget: Int
    private let scopeDriver: SecurityScopeDriver
    private let gate = LibraryMutationGate()

    /// Product-policy staging layout inside the app's own container.
    private static let pendingDirectoryName = "PendingCaptures"
    private static let pendingTransactionName = "transaction.json"
    private static let pendingSidecarName = "sidecar.json"
    private static let exportDirectoryName = "TruongCamExport"
    /// Per-call scan bound. Scans are always bounded, never "scan everything".
    private static let scanBatchEntries = 2_000
    private static let scanRoundLimit = 50

    // MARK: published state (readable without awaiting)

    private struct Published: Sendable {
        var rootState: LibraryRootState = .unselected
        var manifest: LibraryManifest?
        var rootURL: URL?
        var rootDescription: String?
        var generation = RootGeneration.zero
        var grant: BookmarkRootGrant?
        var issues: [String] = []
    }

    private let published = Mutex(Published())
    /// The classification pass from the most recent successful reconciliation.
    ///
    /// REVIEW.md S10's remaining half: the reconciled COUNTS and the card LISTING
    /// were produced by two separate passes over the same folder, so they could
    /// disagree. Both now come from this one scan.
    private let lastReconcileScan = Mutex<ReconcileScanSnapshot?>(nil)
    /// The grant whose SELECTION lease is currently held, if any. Held separately
    /// from `published.grant` so a deferred revocation can stop exactly the grant
    /// it opened (REVIEW.md R06).
    /// Per-grant scope accounting, keyed by the grant's own identity.
    ///
    /// REVIEW.md F01. The previous design used a GLOBAL reader count plus a
    /// replaceable "current selection" slot, which broke in two ways:
    ///
    ///   * a copied lease token released twice decremented the global count twice,
    ///     so closing one reader could revoke a DIFFERENT live reader's scope;
    ///   * a deferred selection revocation was a single global bool, so releasing
    ///     root A and then selecting B meant A's reader close stopped B's selection.
    ///
    /// Accounting is now per grant, and each grant records whether its SELECTION
    /// lease is still open, how many readers it has, and whether a revocation was
    /// deferred. Nothing consults "the current root".
    private let scopeRegistry = ScopeLeaseRegistry()
    /// Grants addressable by identity, so a deferred stop targets the exact grant
    /// and never whichever root happens to be selected later (REVIEW.md F01).
    private let grantsByID = Mutex<[UUID: any SecurityScopedRootGrant]>([:])
    /// Reader releases applied per grant. Diagnostics for balance assertions.
    private let releasesByID = Mutex<[UUID: Int]>([:])

    /// The serial owner that performs actual original reads.
    ///
    /// All disk/decoder work happens here, never on MainActor and never dispatched
    /// out of a coordination accessor that has already returned.
    private let originalReadOwner = BlockingIOOwner()
    /// Current queue depth for cold-read/cancellation diagnostics. Running work
    /// is excluded; at most one accessor executes on this owner at a time.
    nonisolated var queuedOriginalReadCount: Int { originalReadOwner.queuedOperationCount }

    struct ReconcileScanSnapshot: Sendable {
        let libraryID: LibraryID
        let generation: RootGeneration
        let root: URL
        let cards: [LibrarySourceCard]
    }

    /// The exact folder the user confirmed as a local destination, if any. Held so a
    /// confirmation cannot leak to a different unknown root (REVIEW.md R07).
    private var confirmedDestinationURL: URL?
    private let injectedLocalityVerdict: LibraryLocalityVerdict?
    /// Readers currently holding a lease. Root release defers revocation while any
    /// reader is active, so a decode in flight is never revoked (REVIEW.md S09).
    private let userConfirmedUnknownLocality: Bool
    /// The currently granted root URL, exposed for read-only consumers such as
    /// the disposable thumbnail cache. The store still owns the scope lease.
    nonisolated var grantedRootURL: URL? { published.withLock { $0.rootURL } }

    init(
        adapter: FileSystemAdapter = SystemFileSystemAdapter(),
        coordinator: CoordinatedFileMutator = NSFileCoordinatorMutator(),
        wallClock: WallClock = SystemWallClock(),
        supportDirectory: URL? = nil,
        temporaryDirectory: URL? = nil,
        ownedContainerURLs: [URL]? = nil,
        bookmarkStore: RootBookmarkStoring = UserDefaultsRootBookmarkStore(),
        scopeDriver: SecurityScopeDriver = SystemSecurityScopeDriver(),
        capacityReserveBytes: Int64 = 64 * 1024 * 1024,
        /// Test seam may tighten, never enlarge, the production scan ceiling.
        scanRoundLimit: Int = 50,
        /// Test seam: locality evidence to use instead of asking the filesystem.
        /// Production leaves this nil so the real provider facts are consulted.
        injectedLocalityVerdict: LibraryLocalityVerdict? = nil,
        /// Test seam: the authorized local-destination flow's decision. Defaults
        /// to "not yet confirmed", which keeps an unverifiable provider blocked
        /// (REVIEW.md S08).
        userConfirmedUnknownLocality: Bool = false
    ) {
        self.adapter = adapter
        self.coordinator = coordinator
        self.wallClock = wallClock
        self.bookmarkStore = bookmarkStore
        self.scopeDriver = scopeDriver
        self.capacityReserveBytes = capacityReserveBytes
        self.scanRoundBudget = max(1, min(scanRoundLimit, LibraryStore.scanRoundLimit))
        self.injectedLocalityVerdict = injectedLocalityVerdict
        self.userConfirmedUnknownLocality = userConfirmedUnknownLocality

        let fileManager = FileManager.default
        let support = supportDirectory
            ?? fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.temporaryDirectory
        let temporary = temporaryDirectory ?? fileManager.temporaryDirectory
        self.supportDirectory = support.standardizedFileURL
        self.temporaryDirectory = temporary.standardizedFileURL
        self.ownedContainerURLs = ownedContainerURLs
            ?? LibraryStore.defaultOwnedContainerURLs(extra: [self.supportDirectory, self.temporaryDirectory])
    }

    /// Root locations that belong to this app's own container and therefore die
    /// with the app (LIBRARY.md "Local-only storage policy").
    static func defaultOwnedContainerURLs(extra: [URL] = []) -> [URL] {
        let fileManager = FileManager.default
        var urls: [URL] = []
        let directories: [FileManager.SearchPathDirectory] = [
            .documentDirectory, .applicationSupportDirectory, .libraryDirectory, .cachesDirectory,
        ]
        for directory in directories {
            urls.append(contentsOf: fileManager.urls(for: directory, in: .userDomainMask))
        }
        urls.append(fileManager.temporaryDirectory)
        #if os(iOS)
        // On iOS every one of the above already lives inside the app container;
        // the container itself is the authoritative answer.
        urls.append(URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true))
        #endif
        urls.append(contentsOf: extra)
        return urls.map { $0.standardizedFileURL }
    }

    // MARK: LibraryStoring — state

    nonisolated var rootState: LibraryRootState { published.withLock { $0.rootState } }

    nonisolated var currentManifest: LibraryManifest? { published.withLock { $0.manifest } }

    nonisolated var selectedRootDescription: String? { published.withLock { $0.rootDescription } }

    nonisolated func originalURL(for captureID: CaptureID, relativePath: String) -> URL? {
        let root = published.withLock { $0.rootURL }
        guard let root else { return nil }
        do {
            return try PathSafety.resolve(relativePath, under: root)
        } catch {
            return nil
        }
    }

    /// Issues collected by the last root selection/reconcile, for diagnostics.
    nonisolated var lastRootIssues: [String] { published.withLock { $0.issues } }

    /// Whether the ROOT BEING RECONNECTED was confirmed as a local destination.
    ///
    /// Uses the persisted decision so a fresh process keeps the destination the user
    /// chose, and never widens to any unknown root (REVIEW.md G05).
    private func reconnectEligibility(for url: URL) -> Bool {
        let standardized = url.standardizedFileURL
        if let persisted = bookmarkStore.loadConfirmedDestination(),
           persisted.standardizedFileURL == standardized {
            return true
        }
        return confirmedDestinationURL?.standardizedFileURL == standardized
    }

    /// The granted root, if any. Exposed for the index/thumbnail wiring.
    nonisolated var rootURLForConsumers: URL? { published.withLock { $0.rootURL } }

    // MARK: LibraryStoring — root selection

    func selectRoot(
        from grantedURL: URL,
        confirmedLocalDestination: Bool = false
    ) async -> RootSelectionOutcome {
        await gate.acquire()
        let outcome = performRootSelection(
            grantedURL: grantedURL,
            existingGrant: nil,
            confirmedLocalDestination: confirmedLocalDestination)
        await gate.release()
        return outcome
    }

    func reconnectStoredRoot() async -> RootSelectionOutcome {
        await gate.acquire()
        let data = bookmarkStore.loadBookmarkData()
        guard let data else {
            let outcome = RootSelectionOutcome.unavailable(
                reason: "No saved library folder is available. Choose Reconnect library.")
            markUnavailable(reason: "Reconnect library required", libraryID: nil)
            await gate.release()
            return outcome
        }
        let grant: BookmarkRootGrant
        do {
            grant = try BookmarkRootGrant(bookmarkData: data, driver: scopeDriver)
        } catch {
            markUnavailable(reason: "The saved folder permission is no longer valid.", libraryID: nil)
            await gate.release()
            return .unavailable(
                reason: "The saved folder permission could not be resolved. Choose Reconnect library.")
        }
        let outcome = performRootSelection(
            grantedURL: grant.url,
            existingGrant: grant,
            confirmedLocalDestination: reconnectEligibility(for: grant.url))
        await gate.release()
        return outcome
    }

    func releaseRoot() async {
        await gate.acquire()
        // REVIEW.md F01: the deferred selection stop is per GRANT. The previous
        // global "pending revocation" bool plus a replaceable current slot meant
        // releasing root A and then selecting B caused A's reader close to stop B's
        // selection while B was still published as writable.
        if let grant = published.withLock({ $0.grant }) {
            deferSelectionStop(grant)
        }
        published.withLock { current in
            current.grant = nil
            current.rootState = .unselected
            current.manifest = nil
            current.rootURL = nil
            current.rootDescription = nil
            current.issues = []
        }
        bookmarkStore.clear()
        lastReconcileScan.withLock { $0 = nil }
        await gate.release()
    }

    private func performRootSelection(
        grantedURL: URL,
        existingGrant: BookmarkRootGrant?,
        confirmedLocalDestination: Bool = false
    ) -> RootSelectionOutcome {
        let root = existingGrant?.url ?? grantedURL

        // REVIEW.md G05: open the scope BEFORE any provider fact is read. Locality and
        // directory queries are provider operations, and interrogating a
        // security-scoped folder without access can report misleading results.
        let candidateGrant = existingGrant ?? BookmarkRootGrant(url: root, driver: scopeDriver)
        var selectionCommitted = false
        let started = candidateGrant.beginAccess()
        // Track whether the grant actually started, so every early return below
        // balances it (G01/G05).
        defer {
            if started, !selectionCommitted {
                candidateGrant.endAccess()
            }
        }

        // Compare resolved paths only after opening access. Keep the original
        // URL for IO; canonicalization here is solely a retention-policy check.
        if isInsideOwnContainer(root) {
            resetSelection(keepGeneration: true)
            return .rejectedOwnContainer
        }

        // Locality eligibility. A recognised remote location is rejected, and an
        // UNVERIFIABLE provider is not proof of locality, so it stays blocked until
        // the authorized local-destination flow confirms it (REVIEW.md S08).
        let verdict = injectedLocalityVerdict ?? LibraryStore.localityVerdict(for: root)
        recordLocality(verdict)
        // R07: the confirmation is bound to THIS candidate URL. A confirmation
        // given for one folder must not authorize a different unknown folder later,
        // so it is consumed here rather than remembered globally.
        // The persisting store is the source of truth across process restarts.
        let persistedDestination = bookmarkStore.loadConfirmedDestination()
        let confirmedForThisFolder = confirmedLocalDestination
            || (userConfirmedUnknownLocality && confirmedDestinationURL == root)
            || (persistedDestination?.standardizedFileURL == root.standardizedFileURL)
        let policy = LocalityEligibilityPolicy(
            verdict: verdict, userConfirmedUnknownLocality: confirmedForThisFolder)
        if confirmedForThisFolder, !verdict.isVerifiedLocal {
            // Recorded in memory for this attempt; PERSISTED only after the selection
            // validates and publishes (REVIEW.md I05).
            confirmedDestinationURL = root
        } else if !verdict.isVerifiedLocal {
            confirmedDestinationURL = nil
        }
        eligibilityDecision = policy.decision
        switch policy.decision {
        case .eligible:
            break
        case .rejectedRemote(let reason):
            resetSelection(keepGeneration: true)
            return .rejectedCloudLocation(reason: reason)
        case .blockedUnverified(let reason):
            // The folder is usable for reading/export, but it may NOT become a
            // writable local-only library until its locality is confirmed.
            resetSelection(keepGeneration: true)
            return .localityUnconfirmed(reason: reason)
        }

        var directoryFlag: Bool
        do {
            directoryFlag = try adapter.isDirectory(at: root)
        } catch {
            markUnavailable(reason: "The selected folder is not readable.", libraryID: nil)
            return .unavailable(reason: "The selected location could not be read: \(describe(error))")
        }
        if !adapter.fileExists(at: root) { directoryFlag = false }
        guard directoryFlag else {
            markUnavailable(reason: "The selected location is not a folder.", libraryID: nil)
            return .unavailable(reason: "The selected location is not a folder.")
        }

        let grant = candidateGrant
        var issues: [String] = []
        selectionCommitted = true
        // REVIEW.md G01: replacing a selection retires its lease even when this candidate
        // requires no new scope. Existing readers keep their exact old grant
        // alive until they drain; candidate registration still requires a start.
        let previousSelection = published.withLock { $0.grant }
        if let previousSelection, previousSelection.leaseIdentity != grant.leaseIdentity {
            deferSelectionStop(previousSelection)
        }
        if started {
            grantsByID.withLock { table in table[grant.leaseIdentity] = grant }
            scopeRegistry.openSelectionLease(grant.leaseIdentity)
        }
        if !started {
            // A picker-granted URL in this process, or a provider path that needs
            // no explicit scope, can legitimately report false. The root is still
            // only used through the adapter, and a write failure is surfaced as a
            // failure — never as a sandbox-only "Saved".
            issues.append("The system did not start a new security-scoped lease for this folder.")
        }
        if grant.isStale {
            issues.append("The retained folder bookmark was stale and has been refreshed.")
        }

        let manifestURL: URL
        do {
            let path = existingMetadataPath(LibraryLayout.libraryManifestName,
                                            legacy: LibraryLayout.legacyLibraryManifestName, root: root)
            manifestURL = try resolveLibraryURL(path, under: root)
        } catch {
            grant.endAccess()
            abandonCandidate(grant)
            markUnavailable(reason: describe(error), libraryID: nil)
            return .conflictingManifest(reason: describe(error))
        }
        var outcome: RootSelectionOutcome
        var resultingManifest: LibraryManifest?
        var rootState: LibraryRootState

        if adapter.fileExists(at: manifestURL) {
            let readResult = readManifest(at: manifestURL)
            switch readResult {
            case .newerLayout(let found):
                // This grant's disposable browsing identity is never written to
                // Files or accepted as authored metadata. A new selection gets
                // a new identity, including a re-open of the same unknown root.
                _ = advanceGeneration()
                rootState = .readOnly(reason: "newer library layout \(found)", libraryID: LibraryID(grant.leaseIdentity))
                outcome = .readOnlyNewerSchema(found: found, supported: LibraryLayout.supportedLayoutVersion)
                issues.append("The library uses a newer layout and is left untouched.")
            case .newerMajorSchema(let found):
                _ = advanceGeneration()
                rootState = .readOnly(reason: "newer schemaVersion \(found)", libraryID: LibraryID(grant.leaseIdentity))
                outcome = .readOnlyNewerSchema(found: found, supported: truongCamSupportedSchemaVersion)
                issues.append("library.json uses schemaVersion \(found); the library is opened read-only and never rewritten.")
            case .conflicting(let reason):
                grant.endAccess()
                abandonCandidate(grant)
                markUnavailable(reason: reason, libraryID: nil)
                return .conflictingManifest(reason: reason)
            case .opened(let manifest):
                let legacyURL = root.appendingPathComponent(LibraryLayout.legacyLibraryManifestName)
                if manifestURL.path != legacyURL.path, adapter.fileExists(at: legacyURL) {
                    guard case .opened(let legacy) = readManifest(at: legacyURL), legacy.libraryID == manifest.libraryID else {
                        let reason = "The legacy and metadata manifests disagree. Both were preserved for reconciliation."
                        grant.endAccess()
                        abandonCandidate(grant)
                        markUnavailable(reason: reason, libraryID: nil)
                        return .conflictingManifest(reason: reason)
                    }
                }
                resultingManifest = manifest
                let generation = advanceGeneration()
                rootState = .writable(libraryID: manifest.declaredLibraryID, generation: generation)
                outcome = .opened(libraryID: manifest.declaredLibraryID,
                                  generation: generation,
                                  manifest: manifest)
            }
        } else {
            switch initializeNewRoot(at: root, issues: &issues) {
            case .failure(let reason):
                grant.endAccess()
                abandonCandidate(grant)
                markUnavailable(reason: reason, libraryID: nil)
                return .unavailable(reason: reason)
            case .success(let manifest):
                resultingManifest = manifest
                let generation = advanceGeneration()
                rootState = .writable(libraryID: manifest.declaredLibraryID, generation: generation)
                outcome = .initialized(libraryID: manifest.declaredLibraryID, generation: generation)
            }
        }

        // I05: identity gate. A same-path-new-library candidate is a DIFFERENT library,
        // so the previous approval does not carry over; the folder stays read-only until
        // the user confirms it again. This is evaluated on the VALIDATED manifest, i.e.
        // before anything is published or revoked.
        if case .writable(let candidateID, _) = rootState {
            let previouslyApproved = bookmarkStore.loadConfirmedDestination()?
                .standardizedFileURL == root.standardizedFileURL
            if previouslyApproved,
               !confirmedLocalDestination,
               let approvedID = bookmarkStore.loadConfirmedLibraryID(),
               approvedID != candidateID {
                let reason = "This folder now holds a different library, so it needs to be confirmed again before originals are written to it."
                rootState = .readOnly(reason: reason, libraryID: candidateID)
                // The OUTCOME must agree with the state, or the caller sees a successful
                // writable open while a read-only conflict was published. This typed
                // outcome is one the session already handles and it is what offers the
                // user their reconfirmation route (REVIEW.md L05).
                outcome = .localityUnconfirmed(reason: reason)
                // The in-memory candidate approval must be withdrawn too, or the
                // persist step below would write the NEW identity as approved.
                confirmedDestinationURL = nil
            }
        }

        if case .writable = rootState {
            if let data = tryBookmarkData(from: grant, issues: &issues) {
                bookmarkStore.saveBookmarkData(data)
            }
        }

        // H04: the previous selection was ALREADY handled by `deferSelectionStop`
        // above, which stops it exactly once or defers to its last live reader. A
        // second, untracked `endAccess` here stopped a grant the registry still counted
        // as live, so the accounting disagreed with reality.
        let description = describeRoot(root, manifest: resultingManifest, readOnly: !rootState.isWritable)
        published.withLock { current in
            current.grant = grant
            current.rootState = rootState
            current.manifest = resultingManifest
            current.rootURL = root
            current.rootDescription = description
            current.issues = issues
        }
        // H05/I05: bind the durable decision to the LIBRARY IDENTITY and persist it
        // only NOW, after the selection validated and published its manifest. A NEW
        // library at the same path therefore cannot inherit the old approval, and a
        // rejected/corrupt candidate cannot overwrite a previously approved folder.
        let approvedNow = confirmedDestinationURL?.standardizedFileURL == root.standardizedFileURL
        if let libraryID = resultingManifest?.declaredLibraryID, approvedNow {
            bookmarkStore.saveConfirmedDestination(root)
            bookmarkStore.saveConfirmedLibraryID(libraryID)
        }
        return outcome
    }

    private enum ManifestReadResult {
        case opened(LibraryManifest)
        case newerMajorSchema(found: Int)
        case newerLayout(Int)
        case conflicting(String)
    }

    private func readManifest(at url: URL) -> ManifestReadResult {
        let data: Data
        do {
            data = try adapter.readAll(at: url, maxBytes: MetadataBounds.maxSourceSidecarUTF8Bytes)
        } catch {
            return .conflicting("library.json could not be read safely: \(describe(error))")
        }
        let version: Int?
        do {
            version = try PortableJSONReader.peekMajorVersion(in: data)
        } catch {
            return .conflicting("library.json is not valid JSON: \(describe(error))")
        }
        guard let version else {
            return .conflicting("library.json has no schemaVersion field")
        }
        if version > truongCamSupportedSchemaVersion {
            return .newerMajorSchema(found: version)
        }
        guard version == truongCamSupportedSchemaVersion else {
            return .conflicting("library.json declares unsupported schemaVersion \(version)")
        }
        do {
            let manifest = try PortableJSONReader().decode(
                LibraryManifest.self, from: data, limitBytes: MetadataBounds.maxSourceSidecarUTF8Bytes)
            if let layout = manifest.layoutVersion {
                if layout > LibraryLayout.supportedLayoutVersion { return .newerLayout(layout) }
                guard layout == 1 || layout == LibraryLayout.supportedLayoutVersion else {
                    return .conflicting("Unsupported library layout \(layout)")
                }
            }
            guard manifest.application == LibraryManifest.applicationName else {
                return .conflicting("library.json belongs to another application (\(manifest.application))")
            }
            guard manifest.declaresLocalOnly else {
                return .conflicting("library.json declares storagePolicy \(manifest.storagePolicy), not \(LibraryManifest.localOnlyPolicy)")
            }
            return .opened(manifest)
        } catch {
            return .conflicting("library.json is not a valid TruongCam v1 manifest: \(describe(error))")
        }
    }

    private enum InitializationResult {
        case success(LibraryManifest)
        case failure(String)
    }

    /// Initializes an empty root: coordinated tiny write probe first, then the
    /// manifest. An existing unknown manifest is never overwritten because this
    /// path only runs when `library.json` is absent.
    private func initializeNewRoot(at root: URL, issues: inout [String]) -> InitializationResult {
        let probeURL = root.appendingPathComponent(
            "truongcam-write-probe-\(UUID().uuidString.lowercased()).tmp", isDirectory: false)
        let probeBytes = Data("truongcam-write-probe".utf8)
        do {
            try coordinator.coordinatedWrite(at: probeURL) { actual in
                try adapter.writeNewFile(at: actual, bytes: probeBytes)
            }
            let readBack = try adapter.readAll(at: probeURL, maxBytes: 64)
            guard readBack == probeBytes else {
                throw FileAdapterError.ioFailure("The folder write probe read back different bytes")
            }
            try adapter.removeItem(at: probeURL)
        } catch {
            return .failure("The folder cannot be used for a library: \(describe(error))")
        }

        if containsExistingOriginals(at: root) {
            issues.append(
                "This folder already contains files; anything without a TruongCam sidecar is shown as a recovered file, never as claimed TruongCam capture evidence.")
        }

        let manifest = LibraryManifest(libraryID: LibraryID(), createdAtUTC: wallClock.now())
        do {
            let data = try PortableJSONWriter().encode(manifest, explicitNullKeys: [])
            let manifestDestination = try resolveLibraryURL(LibraryLayout.libraryManifestName, under: root)
            try coordinator.coordinatedWrite(at: manifestDestination) { actual in
                try adapter.createDirectory(at: actual.deletingLastPathComponent(), withIntermediateDirectories: true)
                try adapter.writeNewFile(at: actual, bytes: data)
            }
            for directory in [LibraryLayout.originalsDirectoryName, LibraryLayout.metadataSequencesDirectory] {
                let url = root.appendingPathComponent(directory, isDirectory: true)
                try coordinator.coordinatedWrite(at: url) { actual in
                    if !adapter.fileExists(at: actual) {
                        try adapter.createDirectory(at: actual, withIntermediateDirectories: true)
                    }
                }
            }
        } catch {
            return .failure("The library manifest could not be created: \(describe(error))")
        }
        return .success(manifest)
    }

    private func containsExistingOriginals(at root: URL) -> Bool {
        let entries: [ScannedEntry]
        do {
            entries = try adapter.scan(root: root, maxEntries: 1, shouldSkipRelativePath: { relative in
                relative.hasPrefix(LibraryLayout.stagingDirectoryName)
            }, shouldDescendRelativeDirectory: { relative in
                !relative.hasPrefix(LibraryLayout.stagingDirectoryName)
            }, onProgress: nil)
        } catch {
            return false
        }
        return !entries.isEmpty
    }

    private func tryBookmarkData(from grant: BookmarkRootGrant, issues: inout [String]) -> Data? {
        do {
            return try grant.bookmarkData()
        } catch {
            issues.append("The folder bookmark could not be created: \(describe(error))")
            return nil
        }
    }

    private func resetSelection(keepGeneration: Bool) {
        // REVIEW.md G01: stopping the grant here without telling the registry left the
        // registry believing a selection lease was still open. The stop now goes
        // through the same identity-addressed path as every other transition.
        if let grant = published.withLock({ $0.grant }) {
            deferSelectionStop(grant)
        }
        published.withLock { current in
            current.grant = nil
            current.rootState = .unselected
            current.manifest = nil
            current.rootURL = nil
            current.rootDescription = nil
            if !keepGeneration { current.generation = .zero }
        }
    }

    /// Rolls back a candidate that was registered but never adopted.
    ///
    /// REVIEW.md I05: the candidate's selection lease, its scope and its identity-table
    /// entry are all released, so no open-selection accounting can outlive the lease it
    /// describes. A grant with live readers is NOT force-stopped: its stop stays
    /// deferred and it stays addressable until the last reader closes.
    private func abandonCandidate(_ grant: any SecurityScopedRootGrant) {
        if scopeRegistry.requestSelectionStop(grant.leaseIdentity) {
            grant.endAccess()
            grantsByID.withLock { table in _ = table.removeValue(forKey: grant.leaseIdentity) }
            scopeRegistry.forget(grant.leaseIdentity)
        }
    }

    private func markUnavailable(reason: String, libraryID: LibraryID?) {
        published.withLock { current in
            current.rootState = .unavailable(reason: reason, libraryID: libraryID)
            current.issues.append(reason)
        }
    }

    private func advanceGeneration() -> RootGeneration {
        published.withLock { current in
            current.generation = .next(current.generation)
            return current.generation
        }
    }

    private func isInsideOwnContainer(_ url: URL) -> Bool {
        let path = url.resolvingSymlinksInPath().standardizedFileURL.path
        return ownedContainerURLs.contains { owned in
            let ownedPath = owned.resolvingSymlinksInPath().standardizedFileURL.path
            return path == ownedPath || path.hasPrefix(ownedPath + "/")
        }
    }

    /// Known cloud destinations only. A third-party provider folder is *not*
    /// rejected here: LIBRARY.md says its retention depends on its owner, which is
    /// reported as a caveat rather than a silent failure.
    /// Classifies a candidate root's locality from public filesystem evidence.
    ///
    /// REVIEW.md S08: the previous check tested only iCloud path markers and
    /// `volumeIsLocal`, treating "not recognisably iCloud" as verified local. That
    /// is fail-open. The result is now a portable verdict that selection acts on.
    nonisolated static func localityVerdict(for url: URL) -> LibraryLocalityVerdict {
        let path = url.standardizedFileURL.path
        let markers = ["/Mobile Documents/", "com~apple~CloudDocs", "/iCloud Drive", "/iCloud/"]
        for marker in markers where path.contains(marker) {
            return .rejectedRemote(
                reason: "The folder is inside iCloud Drive, which the local-only storage policy rejects.")
        }
        if path.hasSuffix(".icloud") {
            return .rejectedRemote(reason: "The location is an iCloud placeholder file, not a local folder.")
        }

        do {
            let values = try url.resourceValues(forKeys: [
                .isUbiquitousItemKey, .volumeIsLocalKey, .volumeIsInternalKey,
            ])
            if values.isUbiquitousItem == true {
                return .rejectedRemote(
                    reason: "The folder is an iCloud/ubiquitous item, which the local-only storage policy rejects.")
            }
            if let isLocal = values.volumeIsLocal {
                if !isLocal {
                    return .rejectedRemote(
                        reason: "The volume backing this folder is not local, so the local-only storage policy rejects it.")
                }
                let internalNote = (values.volumeIsInternal == true) ? "internal storage" : "local volume"
                // A local volume is necessary but NOT sufficient for provider
                // retention: a cloud provider's materialised cache also lives on a
                // local volume. This reports filesystem evidence only and lets the
                // eligibility policy decide; the independent-owner question stays a
                // device gate (REVIEW.md F05).
                return .localVolume(
                    evidence: "The filesystem reports a local volume (\(internalNote)). Whether this provider keeps originals locally is verified on device.")
            }
            return .unknown(
                reason: "This provider did not report whether the location is local.",
                requiresConfirmation: true)
        } catch {
            return .unknown(
                reason: "The provider did not expose locality information for this folder.",
                requiresConfirmation: true)
        }
    }

    /// The locality evidence recorded for the current selection.
    private(set) var localityVerdict: LibraryLocalityVerdict = .unknown(
        reason: "No folder has been selected.", requiresConfirmation: true)

    /// Records the verdict so the manifest and the UI can report it honestly.
    private func recordLocality(_ verdict: LibraryLocalityVerdict) {
        localityVerdict = verdict
    }

    /// Why the current root is (or is not) eligible to hold permanent originals.
    /// Exposed so a caller can distinguish "verified local" from "accepted by an
    /// explicit product decision" instead of inferring it from a writable state.
    private(set) var eligibilityDecision: LocalityEligibilityPolicy.Decision = .blockedUnverified(
        reason: "No folder has been selected.")

    /// Access to the shared registry, for diagnostics and tests.
    var scopeRegistryForDiagnostics: ScopeLeaseRegistry { scopeRegistry }

    /// Number of leases a reader currently owns. Exposed for tests and diagnostics.
    /// Total readers holding a lease across every grant. Reported for diagnostics;
    /// the real accounting is per grant.
    var activeReaderCount: Int {
        scopeRegistry.totalActiveReaders
    }


    /// Locality evidence recorded for the most recent root decision.
    private(set) var lastLocalityEvidence: String?

    /// Availability implied by a classification. Kept pure so the card listing and
    /// the counts can never describe the same record differently.
    nonisolated static func availability(for classification: SourceClassification) -> SourceAvailability {
        switch classification {
        case .verifiedOriginal, .recoveredRAW, .stagedExternal: return .local
        case .missingOriginal: return .missing
        case .conflict(let reason): return .inaccessible(reason: reason)
        }
    }

    private func describeRoot(_ root: URL, manifest: LibraryManifest?, readOnly: Bool) -> String {
        var parts = [root.lastPathComponent]
        if let manifest { parts.append("library \(manifest.declaredLibraryID.description)") }
        if readOnly { parts.append("read-only") }
        return parts.joined(separator: " · ")
    }

    // MARK: LibraryStoring — staging

    func stageSource(bytes: Data, metadata: SourceCaptureMetadata) async throws -> StagedSourceHandle {
        let snapshot = published.withLock { current -> (LibraryRootState, URL?) in
            (current.rootState, current.rootURL)
        }
        guard case .writable(let libraryID, let generation) = snapshot.0, snapshot.1 != nil else {
            throw CaptureFailure(
                kind: .folderUnavailable(detail: "No writable library folder is selected."),
                operation: "stageSource",
                retainedSourceStatus: bytes.isEmpty ? .none : .inMemoryRepresentationUnstaged)
        }
        guard metadata.libraryID == libraryID else {
            throw CaptureFailure(
                kind: .conflict(detail: "The source belongs to library \(metadata.libraryID.description), not the selected library."),
                operation: "stageSource",
                retainedSourceStatus: .inMemoryRepresentationUnstaged)
        }
        guard !bytes.isEmpty else {
            throw CaptureFailure(kind: .representationUnavailable(detail: "The captured representation was empty."),
                                 operation: "stageSource")
        }
        let matchesDeclaredFormat: Bool
        if metadata.format.isJPEGDeclaration {
            matchesDeclaredFormat = LibraryStore.isJPEGData(bytes)
        } else if metadata.format.isHEIFDeclaration {
            matchesDeclaredFormat = metadata.cameraDeviceType == "front" && LibraryStore.isHEIFData(bytes)
        } else {
            matchesDeclaredFormat = metadata.format.isBayerRAWDeclaration && LibraryStore.looksLikeTIFFContainer(bytes)
        }
        guard matchesDeclaredFormat else {
            throw CaptureFailure(
                kind: .representationUnavailable(
                    detail: "The captured bytes do not match the declared DNG, JPEG or front HEIF format, so they were not staged as an original."),
                operation: "stageSource")
        }

        let projected = Int64(bytes.count) + capacityReserveBytes
        if let capacity = adapter.availableCapacity(at: supportDirectory), capacity < projected {
            throw CaptureFailure(
                kind: .localStorageFull(detail: "About \(bytes.count) bytes are needed for internal recovery staging."),
                operation: "stageSource",
                retainedSourceStatus: .inMemoryRepresentationUnstaged)
        }

        let captureID = metadata.captureID
        let directory = pendingDirectory(for: captureID)
        let sourceURL = directory.appendingPathComponent("source." + metadata.format.fileExtension, isDirectory: false)
        let transactionURL = directory.appendingPathComponent(LibraryStore.pendingTransactionName, isDirectory: false)
        let sidecarURL = directory.appendingPathComponent(LibraryStore.pendingSidecarName, isDirectory: false)
        let transactionID = TransactionID()
        let intendedPath = LibraryLayout.relativeOriginalPath(
            for: captureID, capturedAt: metadata.capturedAtUTC, calendar: wallClock.calendar, format: metadata.format)

        // The digest is computed over bounded chunks of the received bytes
        // before anything is written, so the journal carries the true
        // expectation from its very first write and a crash is always
        // distinguishable from "nothing happened".
        let preflight: HashAndByteCount
        do {
            preflight = try hashBytes(bytes)
        } catch {
            throw mapFailure("stageSource", error: error, retained: .inMemoryRepresentationUnstaged)
        }

        var record = TransactionRecord(
            schemaVersion: truongCamSupportedSchemaVersion,
            transactionID: transactionID.rawValue,
            captureID: captureID.rawValue,
            libraryID: libraryID.rawValue,
            rootGeneration: generation.value,
            phase: .reserved,
            expectedByteCount: preflight.byteCount,
            expectedSHA256: preflight.digest.hex,
            relativeOriginalPath: intendedPath,
            createdAtUTC: wallClock.now(),
            updatedAtUTC: wallClock.now(),
            lastError: nil)

        let staged: HashAndByteCount
        do {
            try adapter.createDirectory(at: directory, withIntermediateDirectories: true)
            try writeJournal(record, at: transactionURL)
            staged = try writeStreamed(bytes, to: sourceURL)
            guard staged == preflight else {
                throw CaptureFailure(
                    kind: .integrityMismatch(
                        detail: "The internal recovery copy does not match the acquired bytes."),
                    operation: "stageSource",
                    retainedSourceStatus: .durableInternalStaging(relativePath: relativePendingPath(for: captureID, format: metadata.format)))
            }
            record.phase = .stagedInternal
            record.updatedAtUTC = wallClock.now()
            try writeJournal(record, at: transactionURL)
            let sidecarData = try PortableJSONWriter().encode(
                makeSidecar(metadata: metadata,
                            relativeOriginalPath: intendedPath,
                            byteCount: preflight.byteCount,
                            sha256: preflight.digest,
                            commitRecordedAtUTC: wallClock.now()),
                explicitNullKeys: SourceSidecar.explicitNullKeyPaths)
            try writeJournalData(sidecarData, at: sidecarURL)
        } catch {
            let retained: RetainedSourceStatus = adapter.fileExists(at: sourceURL)
                ? .durableInternalStaging(relativePath: relativePendingPath(for: captureID, format: metadata.format))
                : .inMemoryRepresentationUnstaged
            throw mapFailure("stageSource", error: error, retained: retained)
        }

        return StagedSourceHandle(
            transactionID: transactionID,
            captureID: captureID,
            libraryID: libraryID,
            pendingRelativePath: relativePendingPath(for: captureID, format: metadata.format),
            byteCount: staged.byteCount,
            sha256: staged.digest,
            metadata: metadata,
            acquisitionTerminalStatus: LibraryStore.terminalStatus(for: metadata.acquisitionStatus, errorDescription: nil),
            originRootGeneration: generation,
            intendedRelativeOriginalPath: intendedPath)
    }

    // MARK: LibraryStoring — commit

    func commit(handle: StagedSourceHandle) async throws -> CommitReceipt {
        await gate.acquire()
        let source = CommitSource(handle: handle)
        do {
            let receipt = try commitPipeline(source)
            lastReconcileScan.withLock { $0 = nil }
            await gate.release()
            return receipt
        } catch {
            let failure = normalizeCommitFailure("commit", error: error, source: source)
            await gate.release()
            throw failure
        }
    }

    func retry(transactionID: TransactionID) async throws -> CommitReceipt {
        await gate.acquire()
        do {
            guard let pending = loadPendingRecord(transactionID: transactionID) else {
                throw CaptureFailure(
                    kind: .providerIOFailed(
                        detail: "No staged source exists for transaction \(transactionID.description)."),
                    operation: "retry",
                    retainedSourceStatus: .none)
            }
            let source = CommitSource(pending: pending)
            let receipt: CommitReceipt
            do {
                receipt = try commitPipeline(source)
                lastReconcileScan.withLock { $0 = nil }
            } catch {
                throw normalizeCommitFailure("retry", error: error, source: source)
            }
            await gate.release()
            return receipt
        } catch {
            await gate.release()
            throw error
        }
    }

    /// Everything the commit pipeline needs about one source. Metadata comes from
    /// the live ownership handle, or from the internal staging snapshot after a
    /// restart; when both are gone, the sidecar already in the folder is the last
    /// trustworthy description of that source.
    private struct CommitSource {
        var transactionID: TransactionID
        var captureID: CaptureID
        var libraryID: LibraryID
        var pendingRelativePath: String
        var byteCount: Int64
        var sha256: SHA256Digest
        var metadata: SourceCaptureMetadata?
        var originRootGeneration: RootGeneration
        var intendedRelativeOriginalPath: String
        var lastError: String?

        init(handle: StagedSourceHandle) {
            self.transactionID = handle.transactionID
            self.captureID = handle.captureID
            self.libraryID = handle.libraryID
            self.pendingRelativePath = handle.pendingRelativePath
            self.byteCount = handle.byteCount
            self.sha256 = handle.sha256
            self.metadata = handle.metadata
            self.originRootGeneration = handle.originRootGeneration
            self.intendedRelativeOriginalPath = handle.intendedRelativeOriginalPath
            self.lastError = nil
        }

        init(pending: PendingRecord) {
            self.transactionID = TransactionID(pending.record.transactionID)
            self.captureID = CaptureID(pending.record.captureID)
            self.libraryID = LibraryID(pending.record.libraryID)
            self.pendingRelativePath = pending.relativePath
            self.byteCount = pending.record.expectedByteCount
            self.sha256 = SHA256Digest(hex: pending.record.expectedSHA256) ?? pending.digestFallback
            self.metadata = pending.sidecar.map(LibraryStore.metadata(from:))
            self.originRootGeneration = RootGeneration(pending.record.rootGeneration)
            self.intendedRelativeOriginalPath = pending.record.relativeOriginalPath
            self.lastError = pending.record.lastError
        }
    }

    /// What is already at the destination. The pipeline decides from this alone
    /// whether it may write, must verify, or must refuse with a conflict.
    private enum DestinationState: Equatable {
        /// Nothing at the destination path.
        case absent
        /// A verified byte-identical original plus a valid matching sidecar.
        case publishedAndComplete(SourceSidecar)
        /// A verified byte-identical original with no sidecar at all.
        case publishedWithoutSidecar
    }

    /// The save pipeline from LIBRARY.md steps 3–7. It never overwrites, never
    /// deletes library content, and only reports success after the FINAL bytes and
    /// the FINAL sidecar have both been re-read and verified.
    private func commitPipeline(_ source: CommitSource) throws -> CommitReceipt {
        let snapshot = published.withLock { current -> (LibraryRootState, URL?) in
            (current.rootState, current.rootURL)
        }
        guard case .writable(let libraryID, let generation) = snapshot.0, let root = snapshot.1 else {
            throw CaptureFailure(kind: .folderUnavailable(detail: "The library folder is not writable."),
                                 operation: "commit",
                                 retainedSourceStatus: retainedStatus(for: source))
        }
        // A pending source keeps its original library identity and destination
        // path. Reconnecting the same library under a new grant generation
        // permits the retry; a different library never silently receives it.
        guard libraryID == source.libraryID else {
            throw CaptureFailure(
                kind: .conflict(detail: "The source belongs to library \(source.libraryID.description)."),
                operation: "commit",
                retainedSourceStatus: retainedStatus(for: source))
        }
        let sourceURL = supportDirectory.appendingPathComponent(source.pendingRelativePath, isDirectory: false)
        // The journal is a sibling of source.dng, never a child of that file.
        let transactionURL = pendingDirectory(for: source.captureID)
            .appendingPathComponent(LibraryStore.pendingTransactionName, isDirectory: false)
        var record = loadRecord(at: transactionURL, captureID: source.captureID) ?? TransactionRecord(
            schemaVersion: truongCamSupportedSchemaVersion,
            transactionID: source.transactionID.rawValue,
            captureID: source.captureID.rawValue,
            libraryID: source.libraryID.rawValue,
            rootGeneration: source.originRootGeneration.value,
            phase: .stagedInternal,
            expectedByteCount: source.byteCount,
            expectedSHA256: source.sha256.hex,
            relativeOriginalPath: source.intendedRelativeOriginalPath,
            createdAtUTC: wallClock.now(),
            updatedAtUTC: wallClock.now(),
            lastError: source.lastError)

        // Identity check: a journal that disagrees with the source is an
        // integrity problem, never something to "fix up".
        guard record.captureID == source.captureID.rawValue,
              record.libraryID == source.libraryID.rawValue,
              record.expectedByteCount == source.byteCount,
              record.expectedSHA256 == source.sha256.hex else {
            throw CaptureFailure(
                kind: .integrityMismatch(
                    detail: "The recovery journal does not match the staged source identity or digest."),
                operation: "commit",
                retainedSourceStatus: retainedStatus(for: source))
        }
        let relativeOriginalPath = record.relativeOriginalPath
        let relativeSidecarPath = sidecarPath(for: relativeOriginalPath, root: root)
        do {
            try PathSafety.validateRelativePath(relativeOriginalPath)
        } catch {
            throw CaptureFailure(kind: .metadataInvalid(detail: "The recorded destination path is unsafe."),
                                 operation: "commit",
                                 retainedSourceStatus: retainedStatus(for: source))
        }
        guard relativeOriginalPath.hasPrefix(LibraryLayout.originalsDirectoryName + "/"),
              relativeOriginalPath.hasSuffix(LibraryLayout.originalFileName(for: source.captureID, format: source.metadata?.format ?? LibraryStore.formatForOriginalPath(source.intendedRelativeOriginalPath))) else {
            throw CaptureFailure(
                kind: .metadataInvalid(detail: "The recorded destination path does not match the capture identity."),
                operation: "commit",
                retainedSourceStatus: retainedStatus(for: source))
        }
        let finalOriginalURL = try resolveLibraryURL(relativeOriginalPath, under: root)
        let finalSidecarURL = try resolveLibraryURL(relativeSidecarPath, under: root)

        // ---- Step 1: what is already published? ------------------------------
        let destination = try resolveDestinationState(
            source: source,
            finalOriginalURL: finalOriginalURL,
            finalSidecarURL: finalSidecarURL,
            relativeOriginalPath: relativeOriginalPath)

        switch destination {
        case .publishedAndComplete(let sidecar):
            // Idempotent success: the exact bytes and a matching sidecar are
            // already published, so nothing is rewritten.
            markCommittedIfPossible(record, at: transactionURL)
            let receipt = makeReceipt(source: source,
                                      rootGeneration: generation,
                                      relativeOriginalPath: relativeOriginalPath,
                                      relativeSidecarPath: relativeSidecarPath,
                                      byteCount: source.byteCount,
                                      digest: source.sha256,
                                      metadata: source.metadata ?? LibraryStore.metadata(from: sidecar))
            cleanupTransactionArtifacts(source: source, stagingDirectory: nil, finalOriginalURL: finalOriginalURL)
            return receipt
        case .absent, .publishedWithoutSidecar:
            break
        }

        var destinationMetadata: SourceCaptureMetadata?
        if case .publishedAndComplete(let sidecar) = destination {
            destinationMetadata = LibraryStore.metadata(from: sidecar)
        }
        guard let metadata = source.metadata
            ?? destinationMetadata
            ?? finalSidecarMetadata(at: finalSidecarURL, captureID: source.captureID) else {
            throw CaptureFailure(
                kind: .metadataInvalid(
                    detail: "No trustworthy metadata snapshot is available to write this source's sidecar."),
                operation: "commit",
                retainedSourceStatus: retainedStatus(for: source))
        }

        let sidecarData: Data
        do {
            sidecarData = try PortableJSONWriter().encode(
                makeSidecar(metadata: metadata,
                            relativeOriginalPath: relativeOriginalPath,
                            byteCount: source.byteCount,
                            sha256: source.sha256,
                            commitRecordedAtUTC: wallClock.now()),
                explicitNullKeys: SourceSidecar.explicitNullKeyPaths)
        } catch {
            throw mapFailure("commit", error: error, retained: retainedStatus(for: source))
        }
        guard sidecarData.count <= MetadataBounds.maxSourceSidecarUTF8Bytes else {
            throw CaptureFailure(kind: .metadataInvalid(detail: "The sidecar exceeds the 256 KiB bound."),
                                 operation: "commit",
                                 retainedSourceStatus: retainedStatus(for: source))
        }

        let stagingDirectory = root
            .appendingPathComponent(LibraryLayout.stagingDirectoryName, isDirectory: true)
            .appendingPathComponent(source.transactionID.description, isDirectory: true)
        let stagedOriginalURL = stagingDirectory.appendingPathComponent("source." + (source.intendedRelativeOriginalPath as NSString).pathExtension + ".partial", isDirectory: false)
        let stagedSidecarURL = stagingDirectory.appendingPathComponent("source.json.partial", isDirectory: false)
        let stagedTransactionURL = stagingDirectory
            .appendingPathComponent(LibraryStore.pendingTransactionName, isDirectory: false)

        do {
            record.phase = .stagingProvider
            record.updatedAtUTC = wallClock.now()
            try writeJournal(record, at: transactionURL)
            try coordinator.coordinatedWrite(at: stagingDirectory) { actual in
                try adapter.createDirectory(at: actual, withIntermediateDirectories: true)
            }

            if destination == .absent {
                // The internal recovery copy is the only source of the exact
                // bytes; verify it before it goes anywhere near the folder.
                guard adapter.fileExists(at: sourceURL) else {
                    throw CaptureFailure(
                        kind: .providerIOFailed(detail: "The internal recovery copy is missing."),
                        operation: "commit",
                        retainedSourceStatus: .none)
                }
                let internalHash = try adapter.hashFile(at: sourceURL,
                                                        chunkBytes: FileAdapterDefaults.hashChunkBytes)
                guard internalHash.byteCount == source.byteCount, internalHash.digest == source.sha256 else {
                    throw CaptureFailure(
                        kind: .integrityMismatch(
                            detail: "The internal recovery copy no longer matches its recorded checksum."),
                        operation: "commit",
                        retainedSourceStatus: .durableInternalStaging(relativePath: source.pendingRelativePath))
                }
                let stagedHash = try copyStreamed(from: sourceURL, to: stagedOriginalURL)
                guard stagedHash.byteCount == source.byteCount, stagedHash.digest == source.sha256 else {
                    throw CaptureFailure(
                        kind: .integrityMismatch(
                            detail: "The provider staging copy did not match the source checksum."),
                        operation: "commit",
                        retainedSourceStatus: .durableInternalStaging(relativePath: source.pendingRelativePath))
                }
                // Read verification of the provider-staged bytes (step 4).
                record.phase = .verifyingProvider
                record.updatedAtUTC = wallClock.now()
                try writeJournal(record, at: transactionURL)
                let verifyStaged = try adapter.hashFile(at: stagedOriginalURL,
                                                        chunkBytes: FileAdapterDefaults.hashChunkBytes)
                guard verifyStaged.byteCount == source.byteCount, verifyStaged.digest == source.sha256 else {
                    throw CaptureFailure(
                        kind: .integrityMismatch(
                            detail: "Re-reading the provider staging copy failed verification."),
                        operation: "commit",
                        retainedSourceStatus: .externalStaging(
                            relativePath: stagingRelativePath(source, "source." + (source.intendedRelativeOriginalPath as NSString).pathExtension + ".partial")))
                }
            }

            // Publish the sidecar last, but stage it before publishing the
            // original so a crash cannot leave a DNG without its evidence.
            try writeOwnedFile(sidecarData, at: stagedSidecarURL)
            let verifiedSidecar = try readAndValidateSidecar(at: stagedSidecarURL, expecting: source.captureID)
            guard let verifiedSidecar,
                  verifiedSidecar.byteCount == source.byteCount,
                  verifiedSidecar.sha256 == source.sha256.hex,
                  verifiedSidecar.relativeOriginalPath == relativeOriginalPath else {
                throw CaptureFailure(
                    kind: .integrityMismatch(detail: "The staged sidecar does not describe the staged original."),
                    operation: "commit",
                    retainedSourceStatus: .externalStaging(
                        relativePath: stagingRelativePath(source, "source.json.partial")))
            }
            do {
                try writeOwnedFile(try PortableJSONWriter().encode(
                    record, explicitNullKeys: TransactionRecord.explicitNullKeyPaths), at: stagedTransactionURL)
            } catch {
                // The external journal is recovery evidence, not the source of
                // truth; a failure to write it is reported, not fatal.
                throw mapFailure("commit", error: error,
                                 retained: .durableInternalStaging(relativePath: source.pendingRelativePath))
            }

            if destination == .absent {
                record.phase = .publishingOriginal
                record.updatedAtUTC = wallClock.now()
                try writeJournal(record, at: transactionURL)
                try coordinator.coordinatedWrite(at: finalOriginalURL) { actual in
                    try adapter.createDirectory(at: actual.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
                    if adapter.fileExists(at: actual) {
                        throw FileAdapterError.alreadyExists(actual.path)
                    }
                    try adapter.moveItem(at: stagedOriginalURL, to: actual)
                }
            }

            // Publish the sidecar last (step 5).
            record.phase = .publishingSidecar
            record.updatedAtUTC = wallClock.now()
            try writeJournal(record, at: transactionURL)
            if adapter.fileExists(at: finalSidecarURL) {
                let existing = try readAndValidateSidecar(at: finalSidecarURL, expecting: source.captureID)
                guard let existing,
                      existing.sha256 == source.sha256.hex,
                      existing.byteCount == source.byteCount,
                      existing.libraryID == source.libraryID.rawValue else {
                    throw CaptureFailure(
                        kind: .conflict(
                            detail: "A different sidecar already exists at \(relativeSidecarPath); nothing was overwritten."),
                        operation: "commit",
                        retainedSourceStatus: retainedStatus(for: source))
                }
            } else {
                try coordinator.coordinatedWrite(at: finalSidecarURL) { actual in
                    try adapter.createDirectory(at: actual.deletingLastPathComponent(), withIntermediateDirectories: true)
                    if adapter.fileExists(at: actual) {
                        throw FileAdapterError.alreadyExists(actual.path)
                    }
                    try adapter.moveItem(at: stagedSidecarURL, to: actual)
                }
            }

            // ---- Step 2: verify the FINAL pair -------------------------------
            record.phase = .verifyingFinal
            record.updatedAtUTC = wallClock.now()
            try writeJournal(record, at: transactionURL)
            let finalHash = try adapter.hashFile(at: finalOriginalURL,
                                                 chunkBytes: FileAdapterDefaults.hashChunkBytes)
            guard finalHash.byteCount == source.byteCount, finalHash.digest == source.sha256 else {
                throw CaptureFailure(
                    kind: .integrityMismatch(
                        detail: "The published original does not match the staged checksum; the source was not committed."),
                    operation: "commit",
                    retainedSourceStatus: retainedStatus(for: source))
            }
            let finalSidecar = try readAndValidateSidecar(at: finalSidecarURL, expecting: source.captureID)
            guard let finalSidecar,
                  finalSidecar.byteCount == finalHash.byteCount,
                  finalSidecar.sha256 == finalHash.digest.hex,
                  finalSidecar.relativeOriginalPath == relativeOriginalPath,
                  finalSidecar.libraryID == source.libraryID.rawValue else {
                throw CaptureFailure(
                    kind: .integrityMismatch(
                        detail: "The published sidecar does not match the published original; the source was not committed."),
                    operation: "commit",
                    retainedSourceStatus: retainedStatus(for: source))
            }

            // Durable committed marker BEFORE any recovery bytes are removed.
            record.phase = .committed
            record.updatedAtUTC = wallClock.now()
            try writeJournal(record, at: transactionURL)

            record.phase = .cleanup
            record.updatedAtUTC = wallClock.now()
            do { try writeJournal(record, at: transactionURL) } catch {
                // The commit is already verified and recorded as committed; a
                // failed cleanup marker only leaves recovery bytes behind.
            }

            let receipt = makeReceipt(source: source,
                                      rootGeneration: generation,
                                      relativeOriginalPath: relativeOriginalPath,
                                      relativeSidecarPath: relativeSidecarPath,
                                      byteCount: finalHash.byteCount,
                                      digest: finalHash.digest,
                                      metadata: metadata)
            cleanupTransactionArtifacts(source: source,
                                        stagingDirectory: stagingDirectory,
                                        finalOriginalURL: finalOriginalURL)
            return receipt
        } catch let failure as CaptureFailure {
            recordFailedPhase(&record, failure: failure, at: transactionURL)
            throw failure
        } catch {
            let failure = mapFailure("commit", error: error, retained: retainedStatus(for: source))
            recordFailedPhase(&record, failure: failure, at: transactionURL)
            throw failure
        }
    }

    private func resolveDestinationState(
        source: CommitSource,
        finalOriginalURL: URL,
        finalSidecarURL: URL,
        relativeOriginalPath: String
    ) throws -> DestinationState {
        guard adapter.fileExists(at: finalOriginalURL) else { return .absent }
        let existing: HashAndByteCount
        do {
            existing = try adapter.hashFile(at: finalOriginalURL, chunkBytes: FileAdapterDefaults.hashChunkBytes)
        } catch {
            throw mapFailure("commit", error: error, retained: retainedStatus(for: source))
        }
        guard existing.digest == source.sha256, existing.byteCount == source.byteCount else {
            // Same identity, different bytes: preserve BOTH and ask for a manual
            // resolution. Never overwrite and never rename-and-hide.
            throw CaptureFailure(
                kind: .conflict(
                    detail: "\(relativeOriginalPath) already exists with different bytes. Both copies were preserved for manual resolution."),
                operation: "commit",
                retainedSourceStatus: retainedStatus(for: source))
        }
        guard adapter.fileExists(at: finalSidecarURL) else { return .publishedWithoutSidecar }
        guard let sidecar = try readAndValidateSidecar(at: finalSidecarURL, expecting: source.captureID),
              sidecar.sha256 == source.sha256.hex,
              sidecar.byteCount == source.byteCount,
              sidecar.libraryID == source.libraryID.rawValue else {
            throw CaptureFailure(
                kind: .conflict(
                    detail: "\(finalSidecarURL.lastPathComponent) already exists and does not describe this original; nothing was overwritten."),
                operation: "commit",
                retainedSourceStatus: retainedStatus(for: source))
        }
        return .publishedAndComplete(sidecar)
    }

    private func finalSidecarMetadata(at url: URL, captureID: CaptureID) -> SourceCaptureMetadata? {
        do {
            guard let sidecar = try readAndValidateSidecar(at: url, expecting: captureID) else { return nil }
            return LibraryStore.metadata(from: sidecar)
        } catch {
            return nil
        }
    }

    private func makeReceipt(source: CommitSource,
                             rootGeneration: RootGeneration,
                             relativeOriginalPath: String,
                             relativeSidecarPath: String,
                             byteCount: Int64,
                             digest: SHA256Digest,
                             metadata: SourceCaptureMetadata) -> CommitReceipt {
        CommitReceipt(
            transactionID: source.transactionID,
            captureID: source.captureID,
            libraryID: source.libraryID,
            rootGeneration: rootGeneration,
            relativeOriginalPath: relativeOriginalPath,
            relativeSidecarPath: relativeSidecarPath,
            verifiedByteCount: byteCount,
            verifiedSHA256: digest,
            isOriginalAvailable: true,
            commitObservedAtUTC: wallClock.now(),
            metadata: metadata)
    }

    /// Marks the local journal committed when the journal still exists. A missing
    /// journal after the destination is fully verified does not make the verified
    /// commit fail: the folder is the authority, not the app's journal.
    private func markCommittedIfPossible(_ record: TransactionRecord, at url: URL) {
        guard adapter.fileExists(at: url.deletingLastPathComponent()) else { return }
        var committed = record
        committed.phase = .committed
        committed.updatedAtUTC = wallClock.now()
        do { try writeJournal(committed, at: url) } catch { /* verified destination stands */ }
    }

    /// Removes only this transaction's own recovery and staging bytes. A failure
    /// here cannot revoke a verified commit, so it is deliberately not fatal.
    private func cleanupTransactionArtifacts(source: CommitSource,
                                            stagingDirectory: URL?,
                                            finalOriginalURL: URL) {
        guard adapter.fileExists(at: finalOriginalURL) else { return }
        let pendingDirectoryURL = pendingDirectory(for: source.captureID)
        if adapter.fileExists(at: pendingDirectoryURL) {
            do { try adapter.removeItem(at: pendingDirectoryURL) } catch { /* recovery bytes only */ }
        }
        if let stagingDirectory, adapter.fileExists(at: stagingDirectory) {
            do { try adapter.removeItem(at: stagingDirectory) } catch { /* own partial bytes only */ }
        }
    }

    private func retainedStatus(for source: CommitSource) -> RetainedSourceStatus {
        let sourceURL = supportDirectory.appendingPathComponent(source.pendingRelativePath, isDirectory: false)
        if adapter.fileExists(at: sourceURL) {
            return .durableInternalStaging(relativePath: source.pendingRelativePath)
        }
        return .none
    }

    /// Refresh retention at the public commit/retry boundary. A failure may
    /// name provider staging even though our durable recovery copy also survives;
    /// prefer that exact internal proof, but never transfer a stale handle alone.
    private func normalizeCommitFailure(_ operation: String, error: Error, source: CommitSource) -> CaptureFailure {
        let currentInternal = retainedStatus(for: source)
        let mapped = mapFailure(operation, error: error, retained: currentInternal)
        let retained: RetainedSourceStatus
        if case .durableInternalStaging = currentInternal {
            retained = currentInternal
        } else if case .externalStaging(let path) = mapped.retainedSourceStatus,
                  let root = grantedRootURL,
                  let url = try? resolveLibraryURL(path, under: root),
                  let hash = try? adapter.hashFile(at: url, chunkBytes: FileAdapterDefaults.hashChunkBytes),
                  hash.byteCount == source.byteCount, hash.digest == source.sha256 {
            retained = .externalStaging(relativePath: path)
        } else {
            retained = .none
        }
        return CaptureFailure(kind: mapped.kind, operation: mapped.operation,
                              retainedSourceStatus: retained, nsErrorDomain: mapped.nsErrorDomain,
                              nsErrorCode: mapped.nsErrorCode, underlyingDescription: mapped.underlyingDescription)
    }

    private func stagingRelativePath(_ source: CommitSource, _ fileName: String) -> String {
        "\(LibraryLayout.stagingDirectoryName)/\(source.transactionID.description)/\(fileName)"
    }

    /// Writes one of this transaction's own staging files, replacing a previous
    /// attempt. Never used for library content.
    private func writeOwnedFile(_ data: Data, at url: URL) throws {
        if adapter.fileExists(at: url) {
            try adapter.removeItem(at: url)
        }
        try adapter.writeNewFile(at: url, bytes: data)
    }

    // MARK: LibraryStoring — pending originals

    func pendingOriginals() async -> [PendingOriginal] {
        loadPendingRecords().map { pending in
            PendingOriginal(
                transactionID: TransactionID(pending.record.transactionID),
                captureID: CaptureID(pending.record.captureID),
                libraryID: LibraryID(pending.record.libraryID),
                pendingRelativePath: pending.relativePath,
                intendedRelativeOriginalPath: pending.record.relativeOriginalPath,
                byteCount: pending.record.expectedByteCount,
                sha256: SHA256Digest(hex: pending.record.expectedSHA256) ?? pending.digestFallback,
                phase: pending.record.phase,
                createdAtUTC: pending.record.createdAtUTC,
                updatedAtUTC: pending.record.updatedAtUTC,
                lastError: pending.record.lastError,
                originRootGeneration: RootGeneration(pending.record.rootGeneration))
        }
    }

    /// Extant browsable sources PLUS reconciled records for originals whose bytes
    /// are no longer present.
    ///
    /// REVIEW.md S10. A sidecar without its DNG is a real, actionable state, and
    /// dropping it made a reinstalled library look smaller than it is. The missing
    /// record is derived from the sidecar's own identity, so it is never presented
    /// as a verified original.
    func reconciledSourceCards(after cursor: ScanCursor?, limit: Int) async throws -> ReconciledCardPage {
        let generation = published.withLock { $0.generation }
        // A cursor from another library generation must not be reused: it would mix
        // records from two different folders.
        if let cursor, cursor.generation != generation {
            return .empty
        }
        let all = try await allReconciledSourceCards()
        let start = cursor?.offset ?? 0
        guard start < all.count else {
            return ReconciledCardPage(cards: [], nextCursor: nil, totalCount: all.count)
        }
        let end = min(start + max(1, limit), all.count)
        let slice = Array(all[start..<end])
        let next = end < all.count
            ? ScanCursor(offset: end, generation: generation)
            : nil
        return ReconciledCardPage(cards: slice, nextCursor: next, totalCount: all.count)
    }

    /// The complete reconciled source list, sorted deterministically.
    ///
    /// Sorting is what makes a cursor stable: the same folder produces the same
    /// order on every page request, so a caller cannot skip or duplicate a record.
    func allReconciledSourceCards() async throws -> [LibrarySourceCard] {
        // Prefer the classification pass the counts came from. Falling back to a
        // fresh scan is only correct before the first reconciliation.
        let reconciledScan = lastReconcileScan.withLock { $0 }
        let current = published.withLock { ($0.generation, $0.rootURL, $0.rootState.libraryID) }
        if let reconciledScan, reconciledScan.generation == current.0,
           reconciledScan.root == current.1, reconciledScan.libraryID == current.2 {
            // Project and sort exactly once per reconciliation. Copy-on-write
            // preserves this stable listing across paged reads without redoing
            // the whole collection for every 200-card page.
            return reconciledScan.cards
        }
        var cards = try await browsableSourceCards(limit: MetadataBounds.maxScanBatchEntries * 100)

        let snapshot = published.withLock { current -> (LibraryRootState, URL?) in
            (current.rootState, current.rootURL)
        }
        guard let root = snapshot.1 else { return cards }
        let libraryID: LibraryID
        switch snapshot.0 {
        case .writable(let id, _): libraryID = id
        case .readOnly(_, let id):
            libraryID = id ?? LibraryStore.stableFallbackLibraryID(for: root)
        case .reconciling(let id, _): libraryID = id
        default: return cards
        }

        // Every DNG path that currently exists, so an orphan sidecar is detectable.
        let entries = try scanEntries(
            root: root,
            subtrees: [LibraryLayout.originalsDirectoryName, LibraryLayout.metadataOriginalsDirectory],
            onProgress: nil)
        var extantOriginalPaths = Set<String>()
        var sidecarPaths: [String] = []
        for entry in entries where !entry.isDirectory && !entry.isSymbolicLink {
            let lowered = entry.relativePath.lowercased()
            if LibraryStore.isSupportedOriginalPath(lowered) { extantOriginalPaths.insert(entry.relativePath) }
            if lowered.hasSuffix(".json") { sidecarPaths.append(entry.relativePath) }
        }

        var missingCards: [LibrarySourceCard] = []
        for sidecarRelative in sidecarPaths {
            // The full listing is unbounded here on purpose: paging happens after
            // the set is complete and deterministically ordered.
            guard missingCards.count < MetadataBounds.maxScanBatchEntries * 100 else { break }
            guard let sidecarURL = try? resolveLibraryURL(sidecarRelative, under: root) else { continue }
            guard case .valid(let sidecar) = readSidecar(at: sidecarURL),
                  sidecar.libraryID == libraryID.rawValue,
                  Self.isSidecarLocation(sidecarRelative, for: sidecar.relativeOriginalPath) else { continue }

            // The sidecar names the original it belongs to. If that original is
            // absent, the source is missing rather than gone from the record.
            let originalRelative = sidecar.relativeOriginalPath
            if extantOriginalPaths.contains(originalRelative) { continue }
            if entries.contains(where: { $0.relativePath == originalRelative && !$0.isDirectory }) { continue }

            let captureID = CaptureID(sidecar.captureID)
            missingCards.append(LibrarySourceCard(
                captureID: captureID,
                libraryID: libraryID,
                relativeOriginalPath: originalRelative,
                capturedAtUTC: sidecar.capturedAtUTC,
                capturedAtProvenance: sidecar.capturedAtProvenance,
                availability: .missing,
                classification: .missingOriginal(
                    reason: "The sidecar is present but its original photo is not in this folder."),
                rawDimensions: sidecar.observed.rawDimensions,
                byteCount: sidecar.byteCount,
                sequenceID: sidecar.sequence.map { SequenceID($0.id) },
                sequenceIndex: sidecar.sequence?.index,
                sequenceKind: sidecar.sequence?.kind,
                isTruongCamCapture: true,
                modificationFingerprint: nil))
        }

        // A missing card must not shadow a real one with the same identity.
        let extantIDs = Set(cards.map(\.captureID))
        cards.append(contentsOf: missingCards.filter { !extantIDs.contains($0.captureID) })
        cards.sort { lhs, rhs in
            if lhs.capturedAtUTC != rhs.capturedAtUTC {
                return lhs.capturedAtUTC > rhs.capturedAtUTC
            }
            return lhs.captureID.description < rhs.captureID.description
        }
        return cards
    }

    /// Enumerates browsable source cards for the gallery rebuild.
    ///
    /// This is the missing producer REVIEW.md C06 identified: the reconciliation
    /// pass computed counts but no caller ever received cards, so the index was
    /// never populated and a fresh install could not reconstruct the gallery.
    ///
    /// Reads metadata and file identity only. It never decodes or hashes an
    /// original, never mutates the library, and treats an unreadable sidecar as a
    /// metadata issue rather than discarding the DNG.
    func browsableSourceCards(limit: Int) async throws -> [LibrarySourceCard] {
        let snapshot = published.withLock { current -> (LibraryRootState, URL?, LibraryManifest?) in
            (current.rootState, current.rootURL, current.manifest)
        }
        guard let root = snapshot.1 else {
            throw CaptureFailure(kind: .folderUnavailable(detail: "No library folder is selected."),
                                 operation: "browsableSourceCards")
        }
        let libraryID: LibraryID
        switch snapshot.0 {
        case .writable(let id, _): libraryID = id
        case .readOnly(_, let id):
            libraryID = id ?? LibraryStore.stableFallbackLibraryID(for: root)
        default:
            throw CaptureFailure(kind: .folderUnavailable(detail: "The library folder is not available."),
                                 operation: "browsableSourceCards")
        }

        let bound = max(1, min(limit, MetadataBounds.maxScanBatchEntries * 20))
        let entries = try scanEntries(
            root: root,
            subtrees: [LibraryLayout.originalsDirectoryName, LibraryLayout.metadataOriginalsDirectory],
            onProgress: nil)

        var sidecarPaths = Set<String>()
        for entry in entries where !entry.isDirectory && !entry.isSymbolicLink {
            if entry.relativePath.lowercased().hasSuffix(".json") {
                sidecarPaths.insert(entry.relativePath)
            }
        }

        var cards: [LibrarySourceCard] = []
        let duplicateIDs = Self.duplicateFilenameCaptureIDs(in: entries.filter { !$0.isDirectory && !$0.isSymbolicLink }.map(\.relativePath))
        for entry in entries where !entry.isDirectory && !entry.isSymbolicLink {
            guard cards.count < bound else { break }
            guard LibraryStore.isSupportedOriginalPath(entry.relativePath) else { continue }
            let path = entry.relativePath
            guard let url = try? resolveLibraryURL(path, under: root) else { continue }
            guard isPhotoContainer(at: url) else { continue }

            let sidecarRelativePath = sidecarPath(for: path, root: root)
            var sidecar: SourceSidecar?
            var metadataIssue: String?
            var rejectedSidecarAuthority = false
            if sidecarPaths.contains(sidecarRelativePath),
               let sidecarURL = try? resolveLibraryURL(sidecarRelativePath, under: root) {
                switch readSidecar(at: sidecarURL) {
                case .valid(let parsed):
                    if let issue = sidecarBindingIssue(parsed, libraryID: libraryID, originalPath: path, root: root) {
                        metadataIssue = issue
                        rejectedSidecarAuthority = true
                    } else { sidecar = parsed }
                case .invalid(let reason): metadataIssue = reason
                case .missing: metadataIssue = "The sidecar could not be read."
                }
            }

            let fileCaptureID = LibraryStore.captureID(fromFileName: (path as NSString).lastPathComponent)
            let captureID: CaptureID
            let classification: SourceClassification
            var isTruongCamCapture = false
            if let sidecar {
                let sidecarID = CaptureID(sidecar.captureID)
                captureID = fileCaptureID ?? sidecarID
                if let fileCaptureID, fileCaptureID != sidecarID {
                    classification = .conflict(reason: "The sidecar names a different capture UUID than the file.")
                } else if let byteCount = entry.byteCount, byteCount != sidecar.byteCount {
                    classification = .conflict(
                        reason: "The sidecar records \(sidecar.byteCount) bytes but the file has \(byteCount).")
                } else {
                    classification = .verifiedOriginal
                    isTruongCamCapture = true
                }
            } else {
                // A DNG with no trustworthy sidecar is browsable as recovered RAW,
                // but is never asserted to be a genuine TruongCam capture.
                captureID = rejectedSidecarAuthority || fileCaptureID.map(duplicateIDs.contains) == true
                    ? LibraryStore.derivedIndexIdentity(for: path)
                    : (fileCaptureID ?? LibraryStore.derivedIndexIdentity(for: path))
                classification = .recoveredRAW(metadataIssue: metadataIssue)
            }

            cards.append(LibrarySourceCard(
                captureID: captureID,
                libraryID: libraryID,
                relativeOriginalPath: path,
                capturedAtUTC: sidecar?.capturedAtUTC ?? entry.modificationDate ?? Date.distantPast,
                capturedAtProvenance: sidecar?.capturedAtProvenance ?? .requestTimestamp,
                availability: .local,
                classification: classification,
                rawDimensions: sidecar?.observed.rawDimensions,
                byteCount: entry.byteCount,
                sequenceID: sidecar?.sequence.map { SequenceID($0.id) },
                sequenceIndex: sidecar?.sequence?.index,
                sequenceKind: sidecar?.sequence?.kind,
                isTruongCamCapture: isTruongCamCapture,
                modificationFingerprint: Self.sourceFingerprint(byteCount: entry.byteCount,
                    modificationDate: entry.modificationDate)))
        }
        return cards
    }

    // MARK: LibraryStoring — reconcile

    func reconcile(onProgress: (@Sendable (ScanProgress) -> Void)?) async throws -> ReconciledLibrary {
        await gate.acquire()
        do {
            let result = try reconcilePipeline(onProgress: onProgress)
            await gate.release()
            return result
        } catch {
            await gate.release()
            throw error
        }
    }

    private func reconcilePipeline(onProgress: (@Sendable (ScanProgress) -> Void)?) throws -> ReconciledLibrary {
        let snapshot = published.withLock { current -> (LibraryRootState, URL?, LibraryManifest?) in
            (current.rootState, current.rootURL, current.manifest)
        }
        guard let root = snapshot.1 else {
            throw CaptureFailure(kind: .folderUnavailable(detail: "No library folder is selected."),
                                 operation: "reconcile")
        }
        let writable: Bool
        let libraryID: LibraryID
        let generation: RootGeneration
        switch snapshot.0 {
        case .writable(let id, let g):
            writable = true
            libraryID = id
            generation = g
        case .readOnly(_, let id):
            writable = false
            libraryID = id ?? LibraryStore.stableFallbackLibraryID(for: root)
            generation = published.withLock { $0.generation }
        default:
            throw CaptureFailure(kind: .folderUnavailable(detail: "No library folder is selected."),
                                 operation: "reconcile")
        }

        var issues: [String] = published.withLock { $0.issues }

        // 1. External staging recovery first, so a completed publish is visible
        //    to the gallery pass below.
        let stagingEntries = try scanEntries(
            root: root,
            subtrees: [LibraryLayout.stagingDirectoryName],
            onProgress: onProgress)
        let recovered = try recoverExternalStaging(
            entries: stagingEntries, root: root, libraryID: libraryID, writable: writable, issues: &issues)

        // 2. Gallery scan: every entry except implementation staging.
        let galleryEntries = try scanEntries(
            root: root,
            subtrees: [LibraryLayout.originalsDirectoryName, LibraryLayout.metadataOriginalsDirectory],
            onProgress: onProgress)

        // 3. Classification.
        var originalPaths: [String] = []
        var sidecarPaths: [String] = []
        for entry in galleryEntries where !entry.isDirectory && !entry.isSymbolicLink {
            let name = (entry.relativePath as NSString).lastPathComponent.lowercased()
            if LibraryStore.isSupportedOriginalPath(name), entry.relativePath.hasPrefix(LibraryLayout.originalsDirectoryName + "/") {
                originalPaths.append(entry.relativePath)
            } else if name.hasSuffix(".json"),
                      entry.relativePath.hasPrefix(LibraryLayout.originalsDirectoryName + "/")
                        || entry.relativePath.hasPrefix(LibraryLayout.metadataOriginalsDirectory + "/") {
                sidecarPaths.append(entry.relativePath)
            }
        }
        for path in recovered { originalPaths.append(path) }
        let duplicateIDs = Self.duplicateFilenameCaptureIDs(in: Array(Set(originalPaths)))

        var records: [ClassifiedOriginal] = []
        var matchedSidecars = Set<String>()
        var verified = 0
        var recoveredRAW = 0
        var conflicts = 0
        var skippedNonContainers = 0
        var renamedButMatched = 0

        for path in Set(originalPaths).sorted() {
            let url = try resolveLibraryURL(path, under: root)
            var byteCount: Int64?
            var modificationDate: Date?
            do {
                let attributes = try adapter.attributes(at: url)
                byteCount = (attributes[.size] as? NSNumber)?.int64Value
                modificationDate = attributes[.modificationDate] as? Date
            } catch {
                byteCount = nil
            }

            guard isPhotoContainer(at: url) else {
                skippedNonContainers += 1
                continue
            }
            let sidecarRelativePath = sidecarPath(for: path, root: root)
            let sidecarResult: SidecarReadResult
            if sidecarPaths.contains(sidecarRelativePath) {
                matchedSidecars.insert(sidecarRelativePath)
                sidecarResult = readSidecar(at: try resolveLibraryURL(sidecarRelativePath, under: root))
            } else {
                sidecarResult = .missing
            }

            let fileCaptureID = LibraryStore.captureID(fromFileName: (path as NSString).lastPathComponent)
            var classification: SourceClassification
            var captureID = fileCaptureID
            var observedMetadata: SourceSidecar?
            var sequenceLink: SourceSequenceLink?
            if case .valid(let sidecar) = sidecarResult,
               let issue = sidecarBindingIssue(sidecar, libraryID: libraryID, originalPath: path, root: root) {
                // A valid document is not authority for a different library or
                // path. Keep its original bytes browsable without importing its
                // capture/sequence identity into the selected library.
                captureID = Self.derivedIndexIdentity(for: path)
                classification = .recoveredRAW(metadataIssue: issue)
            } else if case .valid(let sidecar) = sidecarResult {
                observedMetadata = sidecar
                sequenceLink = sidecar.sequence
                if captureID == nil { captureID = CaptureID(sidecar.captureID) }
                if sidecar.captureID != captureID?.rawValue {
                    classification = .conflict(reason: "The sidecar names a different capture UUID than the file.")
                } else if let byteCount, byteCount != sidecar.byteCount {
                    classification = .conflict(
                        reason: "The sidecar records \(sidecar.byteCount) bytes but the file has \(byteCount).")
                } else if fileCaptureID == nil {
                    // Matched to its sidecar by UUID: the identity is proven even
                    // though the file was renamed. The naming difference is
                    // reported, not hidden.
                    classification = .verifiedOriginal
                    renamedButMatched += 1
                } else {
                    classification = .verifiedOriginal
                }
            } else if case .invalid(let reason) = sidecarResult {
                classification = .recoveredRAW(metadataIssue: reason)
            } else {
                classification = .recoveredRAW(metadataIssue: "No matching sidecar was found.")
            }
            if case .recoveredRAW = classification,
               let fileCaptureID, duplicateIDs.contains(fileCaptureID) {
                captureID = Self.derivedIndexIdentity(for: path)
            }
            if captureID == nil {
                classification = .recoveredRAW(
                    metadataIssue: "The filename does not carry a TruongCam capture UUID.")
            }

            switch classification {
            case .verifiedOriginal: verified += 1
            case .recoveredRAW: recoveredRAW += 1
            case .conflict: conflicts += 1
            default: break
            }

            records.append(ClassifiedOriginal(
                relativePath: path,
                captureID: captureID,
                byteCount: byteCount,
                modificationDate: modificationDate,
                classification: classification,
                sidecar: observedMetadata,
                sequence: sequenceLink,
                rawDimensions: observedMetadata?.observed.rawDimensions,
                capturedAtUTC: observedMetadata?.capturedAtUTC
                    ?? modificationDate
                    ?? wallClock.now(),
                capturedAtProvenance: observedMetadata?.capturedAtProvenance ?? .requestTimestamp,
                isTruongCamCapture: observedMetadata != nil))
        }

        // Orphan sidecars: metadata without bytes. Never counted as originals.
        var missing = 0
        for path in sidecarPaths where !matchedSidecars.contains(path) {
            missing += 1
            let url = try resolveLibraryURL(path, under: root)
            let result = readSidecar(at: url)
            let captureID: CaptureID?
            let sequence: SourceSequenceLink?
            if case .valid(let sidecar) = result {
                guard sidecar.libraryID == libraryID.rawValue,
                      Self.isSidecarLocation(path, for: sidecar.relativeOriginalPath) else {
                    missing -= 1
                    issues.append("Foreign or misplaced metadata was kept as a user file without local capture authority: \(path)")
                    continue
                }
                captureID = CaptureID(sidecar.captureID)
                sequence = sidecar.sequence
            } else {
                captureID = LibraryStore.captureID(fromFileName: (path as NSString).lastPathComponent)
                sequence = nil
                if captureID == nil {
                    missing -= 1
                    issues.append("Unrecognized JSON was kept as a user file: \(path)")
                    continue
                }
            }
            let portablePath = path.hasPrefix(LibraryLayout.metadataDirectoryName + "/")
                ? String(path.dropFirst(LibraryLayout.metadataDirectoryName.count + 1)) : path
            let derivedOriginalPath: String
            if case .valid(let parsed) = result { derivedOriginalPath = parsed.relativeOriginalPath }
            else { derivedOriginalPath = portablePath.hasSuffix(".json") ? String(portablePath.dropLast(5)) + ".dng" : portablePath }
            records.append(ClassifiedOriginal(
                relativePath: derivedOriginalPath,
                captureID: captureID,
                byteCount: nil,
                modificationDate: nil,
                classification: .missingOriginal(reason: "The sidecar exists but its original is missing."),
                sidecar: nil,
                sequence: sequence,
                rawDimensions: nil,
                capturedAtUTC: wallClock.now(),
                capturedAtProvenance: .requestTimestamp,
                isTruongCamCapture: false))
        }

        if skippedNonContainers > 0 {
            issues.append(
                "\(skippedNonContainers) file(s) have bytes that do not match their photo extension; they are listed as library files, not as recovered originals.")
        }
        if renamedButMatched > 0 {
            issues.append(
                "\(renamedButMatched) original(s) were matched to their sidecar by capture UUID after being renamed outside TruongCam.")
        }
        let trash = try trashRecords(root: root)
        let trashedIDs = Set(trash.map(\.captureID))
        let intentionallyMissing = records.filter { record in
            guard let id = record.captureID else { return false }
            if case .missingOriginal = record.classification { return trashedIDs.contains(id) }
            return false
        }.count
        missing -= intentionallyMissing
        records.removeAll { record in
            guard let id = record.captureID else { return false }
            return trashedIDs.contains(id) && !adapter.fileExists(at: root.appendingPathComponent(record.relativePath))
        }
        // Per-source explanation for the UI: counts alone cannot tell the user
        // why a card is missing or recovered.
        var explained = 0
        for record in records {
            guard explained < 20 else { break }
            let explanation: String?
            switch record.classification {
            case .verifiedOriginal:
                explanation = nil
            case .recoveredRAW(let issue):
                explanation = issue ?? "Recovered photo with no matching app record."
            case .missingOriginal(let reason):
                explanation = reason
            case .conflict(let reason):
                explanation = reason
            case .stagedExternal:
                explanation = "External staging evidence is present but not yet published."
            }
            if let explanation {
                issues.append("\(record.relativePath): \(explanation)")
                explained += 1
            }
        }

        // 4. Sequences.
        let sequences = try rebuildSequences(
            root: root, libraryID: libraryID, records: records, writable: writable, issues: &issues)

        let pending = loadPendingRecords().filter { record in
            switch record.record.phase {
            case .committed, .cleanup: return false
            default: return true
            }
        }
        if !pending.isEmpty {
            issues.append(
                "\(pending.count) pending original(s) are held only inside the app and are not reinstall-safe.")
        }
        published.withLock { current in current.issues = issues }

        // Publish the SAME classification the counts were derived from, so the
        // card listing cannot disagree with the counts.
        let cards = records.map { record in
            LibrarySourceCard(
                captureID: record.captureID ?? LibraryStore.derivedIndexIdentity(for: record.relativePath),
                libraryID: libraryID,
                relativeOriginalPath: record.relativePath,
                capturedAtUTC: record.capturedAtUTC,
                capturedAtProvenance: record.capturedAtProvenance,
                availability: Self.availability(for: record.classification),
                classification: record.classification,
                rawDimensions: record.rawDimensions,
                byteCount: record.byteCount,
                sequenceID: record.sequence.map { SequenceID($0.id) },
                sequenceIndex: record.sequence?.index,
                sequenceKind: record.sequence?.kind,
                isTruongCamCapture: record.isTruongCamCapture,
                modificationFingerprint: Self.sourceFingerprint(byteCount: record.byteCount,
                    modificationDate: record.modificationDate))
        }.sorted {
            if $0.capturedAtUTC != $1.capturedAtUTC { return $0.capturedAtUTC > $1.capturedAtUTC }
            return $0.captureID.description < $1.captureID.description
        }
        lastReconcileScan.withLock {
            $0 = ReconcileScanSnapshot(libraryID: libraryID, generation: generation, root: root, cards: cards)
        }

        return ReconciledLibrary(
            libraryID: libraryID,
            generation: generation,
            verifiedOriginalCount: verified,
            recoveredRAWCount: recoveredRAW,
            missingOriginalCount: missing,
            conflictCount: conflicts,
            pendingCount: pending.count,
            sequences: sequences,
            issues: issues)
    }

    /// LIBRARY.md "Idempotent recovery": external staged DNG + valid transaction
    /// record is verified and published when identity, root and access match. The
    /// destination is never overwritten.
    private func recoverExternalStaging(
        entries: [ScannedEntry],
        root: URL,
        libraryID: LibraryID,
        writable: Bool,
        issues: inout [String]
    ) throws -> [String] {
        let prefix = LibraryLayout.stagingDirectoryName + "/"
        let components = Set(entries.compactMap { entry -> String? in
            guard entry.relativePath.hasPrefix(prefix) else { return nil }
            return entry.relativePath.dropFirst(prefix.count).split(separator: "/").first.map(String.init)
        })
        var recoveredPaths: [String] = []
        for component in components.sorted() {
            guard let transactionID = UUID(uuidString: component) else {
                issues.append("Ignored an unrecognised staging directory name: \(component).")
                continue
            }
            do {
                let recovered = try coordinator.coordinatedWrite(at: root) { actualRoot -> String? in
                    guard actualRoot.standardizedFileURL == root.standardizedFileURL else {
                        throw FileAdapterError.coordinationFailure("The library moved during recovery; reconnect it.")
                    }
                    let packet = prefix + component
                    let journalURL = try resolveLibraryURL(packet + "/transaction.json", under: root)
                    let data = try adapter.readAll(at: journalURL, maxBytes: MetadataBounds.maxSourceSidecarUTF8Bytes)
                    let record = try PortableJSONReader().decode(TransactionRecord.self, from: data,
                        limitBytes: MetadataBounds.maxSourceSidecarUTF8Bytes)
                    let format = LibraryStore.formatForOriginalPath(record.relativeOriginalPath)
                    guard record.schemaVersion == truongCamSupportedSchemaVersion,
                          record.transactionID == transactionID, record.libraryID == libraryID.rawValue,
                          record.expectedByteCount > 0,
                          let expected = SHA256Digest(hex: record.expectedSHA256), expected != LibraryStore.zeroDigest,
                          record.relativeOriginalPath.hasPrefix(LibraryLayout.originalsDirectoryName + "/"),
                          (record.relativeOriginalPath as NSString).lastPathComponent == LibraryLayout.originalFileName(for: CaptureID(record.captureID), format: format),
                          record.lastError == nil || record.lastError!.utf8.count <= MetadataBounds.maxStringFieldLength else {
                        throw CaptureFailure(kind: .metadataInvalid(detail: "The staging transaction identity, library, checksum or destination is invalid."), operation: "reconcile.staging")
                    }
                    let finalURL = try resolveLibraryURL(record.relativeOriginalPath, under: root)
                    let sidecarFinalURL = try resolveLibraryURL(sidecarPath(for: record.relativeOriginalPath, root: root), under: root)
                    let originalPartialURL = try resolveLibraryURL(packet + "/source." + (format?.fileExtension ?? "dng") + ".partial", under: root)
                    let sidecarPartialURL = try resolveLibraryURL(packet + "/source.json.partial", under: root)
                    let alreadyPublished = adapter.fileExists(at: finalURL)
                    let hasFinalSidecar = adapter.fileExists(at: sidecarFinalURL)
                    let sidecarURL = adapter.fileExists(at: sidecarPartialURL) ? sidecarPartialURL : sidecarFinalURL
                    func matches(_ sidecar: SourceSidecar) -> Bool {
                        sidecar.captureID == record.captureID && sidecar.libraryID == libraryID.rawValue
                            && sidecar.relativeOriginalPath == record.relativeOriginalPath
                            && sidecar.byteCount == record.expectedByteCount && sidecar.sha256 == expected.hex
                    }
                    guard case .valid(let stagedSidecar) = readSidecar(at: sidecarURL), matches(stagedSidecar) else {
                        throw CaptureFailure(kind: .metadataInvalid(detail: "The staged sidecar does not match the complete transaction."), operation: "reconcile.staging")
                    }
                    if hasFinalSidecar {
                        guard case .valid(let finalSidecar) = readSidecar(at: sidecarFinalURL), matches(finalSidecar) else {
                            throw CaptureFailure(kind: .conflict(detail: "A different completion record occupies the staged destination."), operation: "reconcile.staging")
                        }
                    }
                    let sourceURL = alreadyPublished ? finalURL : originalPartialURL
                    if format?.isJPEGDeclaration == true {
                        guard let imageSource = CGImageSourceCreateWithURL(sourceURL as CFURL, nil),
                              LibraryStore.isProcessedPhotoSource(imageSource, expectedType: .jpeg) else {
                            throw CaptureFailure(kind: .representationUnavailable(detail: "The staged JPEG bytes are not a complete JPEG image."), operation: "reconcile.staging")
                        }
                    }
                    let hash = try adapter.hashFile(at: sourceURL, chunkBytes: FileAdapterDefaults.hashChunkBytes)
                    guard hash.digest == expected, hash.byteCount == record.expectedByteCount else {
                        throw CaptureFailure(kind: .integrityMismatch(detail: "The staged or published original does not match its transaction."), operation: "reconcile.staging")
                    }
                    if alreadyPublished && hasFinalSidecar { return record.relativeOriginalPath }
                    guard writable else { return nil }
                    // All identities, both destinations and original bytes were
                    // checked BEFORE either move. A partial publication remains
                    // retryable; foreign/ambiguous packets are never rewritten.
                    if !alreadyPublished {
                        try adapter.createDirectory(at: finalURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                        try adapter.moveItem(at: originalPartialURL, to: finalURL)
                    }
                    if !hasFinalSidecar {
                        try adapter.createDirectory(at: sidecarFinalURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                        try adapter.moveItem(at: sidecarPartialURL, to: sidecarFinalURL)
                    }
                    let finalHash = try adapter.hashFile(at: finalURL, chunkBytes: FileAdapterDefaults.hashChunkBytes)
                    guard finalHash.digest == expected, finalHash.byteCount == record.expectedByteCount,
                          case .valid(let finalSidecar) = readSidecar(at: sidecarFinalURL), matches(finalSidecar) else {
                        throw CaptureFailure(kind: .integrityMismatch(detail: "Recovered files did not verify after publication."), operation: "reconcile.staging")
                    }
                    return record.relativeOriginalPath
                }
                if let recovered {
                    recoveredPaths.append(recovered)
                    issues.append("Verified an interrupted save from staging \(component); remaining staging evidence was kept.")
                } else {
                    issues.append("Staging \(component) can be completed only with a writable folder; its bytes were kept.")
                }
            } catch {
                issues.append("Staging \(component) could not be completed: \(describe(error)). Its bytes were kept.")
            }
        }
        return recoveredPaths
    }

    /// Rebuilds sequence membership from documents and shot sidecars. A missing
    /// or stale document is *interrupted*, never complete.
    private func rebuildSequences(
        root: URL,
        libraryID: LibraryID,
        records: [ClassifiedOriginal],
        writable: Bool,
        issues: inout [String]
    ) throws -> [SequenceSummary] {
        let sequencesRoot = root.appendingPathComponent(LibraryLayout.sequencesDirectoryName, isDirectory: true)
        var documents: [UUID: SequenceDocument] = [:]
        if adapter.fileExists(at: sequencesRoot) || adapter.fileExists(at: root.appendingPathComponent(LibraryLayout.metadataSequencesDirectory)) {
            let entries = try scanEntries(root: root,
                                          subtrees: [LibraryLayout.sequencesDirectoryName, LibraryLayout.metadataSequencesDirectory],
                                          onProgress: nil)
            for entry in entries where !entry.isDirectory && entry.relativePath.hasSuffix(".json") {
                let url = try resolveLibraryURL(entry.relativePath, under: root)
                do {
                    let data = try adapter.readAll(at: url, maxBytes: MetadataBounds.maxSequenceJSONUTF8Bytes)
                    let document = try PortableJSONReader().decode(
                        SequenceDocument.self, from: data, limitBytes: MetadataBounds.maxSequenceJSONUTF8Bytes)
                    let problems = SequenceDocumentSemanticValidator().validate(document)
                    guard problems.isEmpty, document.libraryID == libraryID.rawValue,
                          url.lastPathComponent == LibraryLayout.sequenceFileName(for: SequenceID(document.sequenceID)) else {
                        let explanation = problems.isEmpty ? "library or filename identity does not match" : problems.joined(separator: "; ")
                        issues.append("Sequence \(document.sequenceID.uuidString) has metadata problems and was preserved without use or rewriting: \(explanation)")
                        continue
                    }
                    documents[document.sequenceID] = document
                } catch {
                    issues.append("A sequence document could not be read safely and was left untouched: \(describe(error))")
                }
            }
        }

        struct Group {
            var kind: SequenceKind?
            var indices: Set<Int> = []
            var earliest: Date?
            var mapped: Bool = false
        }
        var groups: [UUID: Group] = [:]
        var currentMembers: [UUID: SourceSequenceLink] = [:]
        for record in records {
            switch record.classification {
            case .missingOriginal, .stagedExternal, .conflict: continue
            case .verifiedOriginal, .recoveredRAW: break
            }
            guard let link = record.sequence else { continue }
            if let captureID = record.captureID { currentMembers[captureID.rawValue] = link }
            var group = groups[link.id] ?? Group()
            group.kind = link.kind
            group.indices.insert(link.index)
            group.mapped = true
            if let date = record.sidecar?.capturedAtUTC {
                group.earliest = min(group.earliest ?? date, date)
            }
            groups[link.id] = group
        }
        for id in documents.keys where groups[id] == nil {
            groups[id] = Group(kind: documents[id]?.kind, indices: [], earliest: documents[id]?.startedAtUTC, mapped: false)
        }

        // Current classified extant sources, not historical completion claims,
        // are the authority. Trash was already excluded from `records` above;
        // this also handles originals removed externally with orphan sidecars.
        var summaries: [SequenceSummary] = []
        for (id, group) in groups.sorted(by: { $0.key.uuidString < $1.key.uuidString }) {
            let document = documents[id]
            let planned = document?.plannedCount ?? ((group.indices.max() ?? 0) + 1)
            var committed = group.indices
            if let document {
                for completed in document.completedSources {
                    guard let current = currentMembers[completed.captureID],
                          current.id == id, current.index == completed.index else { continue }
                    committed.insert(completed.index)
                }
            }
            let missingIndices = (0..<max(planned, 0)).filter { !committed.contains($0) }
            let failed = document?.failedIndices ?? []
            let skipped = document?.skippedDeadlineCount ?? 0
            var status: SequenceStatus
            if let document {
                if document.status == .running {
                    // A `running` document found on disk belongs to a process that
                    // no longer exists.
                    status = .interrupted
                } else {
                    status = document.status
                }
            } else {
                status = .interrupted
            }
            if status == .complete {
                if committed.count != planned || !missingIndices.isEmpty || !failed.isEmpty {
                    status = .interrupted
                }
            }
            let kind = document?.kind ?? group.kind ?? .interval
            let summary = SequenceSummary(
                sequenceID: SequenceID(id),
                kind: kind,
                plannedCount: planned,
                committedCount: committed.count,
                missingIndices: missingIndices.sorted(),
                failedIndices: failed.sorted(),
                skippedDeadlineCount: skipped,
                status: status,
                startedAtUTC: document?.startedAtUTC ?? group.earliest ?? wallClock.now())
            summaries.append(summary)

            if writable, let document, document.status == .running {
                var recoveredDocument = document
                recoveredDocument.status = .interrupted
                recoveredDocument.endedAtUTC = recoveredDocument.endedAtUTC ?? wallClock.now()
                do {
                    try writeSequenceDocumentUngated(recoveredDocument, root: root)
                    issues.append("Sequence \(id.uuidString) was left running by an earlier process and is now marked interrupted.")
                } catch {
                    issues.append("Sequence \(id.uuidString) is running but its recovery update failed: \(describe(error)).")
                }
            }
        }
        return summaries
    }

    // MARK: Explicit viewer Trash / restore
    func trashOriginal(card: LibrarySourceCard, generation: RootGeneration) async throws -> PhotoTrashRecord {
        await gate.acquire()
        do {
            let record = try trashOriginalUngated(card: card, generation: generation)
            await gate.release()
            return record
        } catch { await gate.release(); throw error }
    }

    private func trashOriginalUngated(card: LibrarySourceCard, generation: RootGeneration) throws -> PhotoTrashRecord {
        let root = try writableRoot(operation: "trashOriginal")
        guard rootState.libraryID == card.libraryID, published.withLock({ $0.generation }) == generation,
              card.relativeOriginalPath.hasPrefix("originals/"), card.isTruongCamCapture else {
            throw CaptureFailure(kind: .metadataInvalid(detail: "This photo or folder changed. Refresh before deleting."), operation: "trashOriginal")
        }
        let source = try resolveLibraryURL(card.relativeOriginalPath, under: root)
        let metadataPath = sidecarPath(for: card.relativeOriginalPath, root: root)
        let metadata = try resolveLibraryURL(metadataPath, under: root)
        return try coordinator.coordinatedWrite(at: root) { coordinatedRoot in
            guard coordinatedRoot.standardizedFileURL == root.standardizedFileURL else {
                throw CaptureFailure(kind: .folderUnavailable(detail: "The selected folder moved. Reconnect it."), operation: "trashOriginal")
            }
            guard case .valid(let sidecar) = readSidecar(at: metadata),
                  sidecar.captureID == card.captureID.rawValue, sidecar.libraryID == card.libraryID.rawValue,
                  sidecar.relativeOriginalPath == card.relativeOriginalPath else {
                throw CaptureFailure(kind: .metadataInvalid(detail: "Delete requires the photo's matching metadata. Manage unrecognized files in Files."), operation: "trashOriginal")
            }
            let originalHash = try adapter.hashFile(at: source, chunkBytes: FileAdapterDefaults.hashChunkBytes)
            guard originalHash.digest.hex == sidecar.sha256, originalHash.byteCount == sidecar.byteCount else {
                throw CaptureFailure(kind: .integrityMismatch(detail: "The original changed; it was not moved or deleted."), operation: "trashOriginal")
            }
            let metadataHash = try adapter.hashFile(at: metadata, chunkBytes: FileAdapterDefaults.hashChunkBytes)
            let record = PhotoTrashRecord(id: UUID(), libraryID: card.libraryID, captureID: card.captureID,
                originalPath: card.relativeOriginalPath, metadataPath: metadataPath,
                originalSHA256: originalHash.digest.hex, metadataSHA256: metadataHash.digest.hex,
                deletedAtUTC: wallClock.now())
            let directory = try resolveLibraryURL(record.directory, under: root)
            try adapter.createDirectory(at: directory, withIntermediateDirectories: true)
            // Durable recovery instructions PRECEDE either move. Interrupted moves
            // remain restorable until an explicitly confirmed permanent deletion.
            try adapter.writeNewFile(at: directory.appendingPathComponent("record.json"), bytes: JSONEncoder().encode(record))
            try adapter.moveItem(at: source, to: directory.appendingPathComponent("original." + (card.relativeOriginalPath as NSString).pathExtension))
            try adapter.moveItem(at: metadata, to: directory.appendingPathComponent("metadata.json"))
            lastReconcileScan.withLock { $0 = nil }
            return record
        }
    }

    func trashedOriginals() async throws -> [PhotoTrashRecord] {
        await gate.acquire()
        do {
            let root = try writableRoot(operation: "trashedOriginals")
            let result = try trashRecords(root: root)
            await gate.release()
            return result
        } catch { await gate.release(); throw error }
    }

    private func trashRecords(root: URL) throws -> [PhotoTrashRecord] {
        let entries = try scanEntries(root: root, subtrees: ["metadata/trash"], onProgress: nil)
        guard entries.count < LibraryStore.scanRoundLimit * LibraryStore.scanBatchEntries else {
            throw CaptureFailure(kind: .metadataInvalid(detail: "Recently Deleted exceeds the safe scan limit. Manage the remaining files in Files before retrying."), operation: "trashedOriginals")
        }
        var records: [UUID: PhotoTrashRecord] = [:]
        for entry in entries where !entry.isDirectory && !entry.isSymbolicLink {
            let isIntent = entry.relativePath.hasSuffix("/delete-intent.json")
            guard isIntent || entry.relativePath.hasSuffix("/record.json") else { continue }
            let url = try resolveLibraryURL(entry.relativePath, under: root)
            let data = try coordinator.coordinatedRead(at: url) { try adapter.readAll(at: $0, maxBytes: 16_384) }
            var record: PhotoTrashRecord
            if isIntent {
                guard let intent = try? JSONDecoder().decode(PhotoTrashPurgeIntent.self, from: data) else { continue }
                record = intent.record; record.purgeStartedAtUTC = intent.confirmedAtUTC
            } else {
                guard let decoded = try? JSONDecoder().decode(PhotoTrashRecord.self, from: data) else { continue }
                record = decoded
            }
            guard record.libraryID == rootState.libraryID,
                  entry.relativePath == record.directory + (isIntent ? "/delete-intent.json" : "/record.json"),
                  record.originalPath.hasPrefix("originals/"),
                  LibraryStore.isSupportedOriginalPath(record.originalPath),
                  [LibraryLayout.metadataSidecarPath(for: record.originalPath), LibraryLayout.relativeSidecarPath(alongside: record.originalPath)].contains(record.metadataPath),
                  record.originalSHA256.count == 64, record.metadataSHA256.count == 64 else { continue }
            _ = try resolveLibraryURL(record.originalPath, under: root)
            _ = try resolveLibraryURL(record.metadataPath, under: root)
            let original = try resolveLibraryURL(record.storedOriginalPath, under: root)
            let metadata = try resolveLibraryURL(record.directory + "/metadata.json", under: root)
            let intentURL = try resolveLibraryURL(record.directory + "/delete-intent.json", under: root)
            let hasIntent = adapter.fileExists(at: intentURL)
            guard adapter.fileExists(at: original) || adapter.fileExists(at: metadata) || hasIntent else { continue }
            if hasIntent && record.purgeStartedAtUTC == nil { record.purgeStartedAtUTC = .distantPast }
            if let attrs = try? adapter.attributes(at: original) {
                record.previewFingerprint = "\(attrs[.size] ?? "-")|\(attrs[.modificationDate] ?? "-")"
            }
            records[record.id] = record
        }
        return records.values.sorted { $0.deletedAtUTC > $1.deletedAtUTC }
    }

    /// A confirmed item has a canonical UUID location. Resolve only that record;
    /// rescanning every unrelated Trash item for each batch member was quadratic.
    private func trashRecord(id: UUID, root: URL) throws -> PhotoTrashRecord? {
        let directory = "metadata/trash/" + id.uuidString.lowercased()
        let recordURL = try resolveLibraryURL(directory + "/record.json", under: root)
        let intentURL = try resolveLibraryURL(directory + "/delete-intent.json", under: root)
        var record: PhotoTrashRecord?
        if adapter.fileExists(at: recordURL) {
            let data = try coordinator.coordinatedRead(at: recordURL) { try adapter.readAll(at: $0, maxBytes: 16_384) }
            guard let decoded = try? JSONDecoder().decode(PhotoTrashRecord.self, from: data) else { return nil }
            record = decoded
        }
        if adapter.fileExists(at: intentURL) {
            let data = try coordinator.coordinatedRead(at: intentURL) { try adapter.readAll(at: $0, maxBytes: 16_384) }
            guard let intent = try? JSONDecoder().decode(PhotoTrashPurgeIntent.self, from: data),
                  record == nil || record!.identifiesSameSource(as: intent.record) else { return nil }
            record = intent.record
            record?.purgeStartedAtUTC = intent.confirmedAtUTC
        }
        guard let record, record.id == id, record.directory == directory,
              record.libraryID == rootState.libraryID,
              record.originalPath.hasPrefix("originals/"),
              LibraryStore.isSupportedOriginalPath(record.originalPath),
              [LibraryLayout.metadataSidecarPath(for: record.originalPath), LibraryLayout.relativeSidecarPath(alongside: record.originalPath)].contains(record.metadataPath),
              SHA256Digest(hex: record.originalSHA256) != nil, SHA256Digest(hex: record.metadataSHA256) != nil else { return nil }
        _ = try resolveLibraryURL(record.originalPath, under: root)
        _ = try resolveLibraryURL(record.metadataPath, under: root)
        let original = try resolveLibraryURL(record.storedOriginalPath, under: root)
        let metadata = try resolveLibraryURL(record.directory + "/metadata.json", under: root)
        guard adapter.fileExists(at: original) || adapter.fileExists(at: metadata) || adapter.fileExists(at: intentURL) else { return nil }
        return record
    }

    func permanentlyDeleteOriginal(record requested: PhotoTrashRecord, generation: RootGeneration) async throws {
        await gate.acquire()
        defer { lastReconcileScan.withLock { $0 = nil } }
        do {
            let root = try writableRoot(operation: "permanentlyDeleteOriginal")
            guard rootState.libraryID == requested.libraryID, published.withLock({ $0.generation }) == generation,
                  let record = try trashRecord(id: requested.id, root: root),
                  record.identifiesSameSource(as: requested) else {
                throw CaptureFailure(kind: .metadataInvalid(detail: "Recently Deleted or the folder changed. Refresh before deleting."), operation: "permanentlyDeleteOriginal")
            }
            try coordinator.coordinatedWrite(at: root) { actual in
                guard actual.standardizedFileURL == root.standardizedFileURL else {
                    throw CaptureFailure(kind: .folderUnavailable(detail: "The folder moved; reconnect it."), operation: "permanentlyDeleteOriginal")
                }
                let intentURL = try resolveLibraryURL(record.directory + "/delete-intent.json", under: root)
                let resuming = adapter.fileExists(at: intentURL)
                var intentBytes: Data
                if resuming {
                    intentBytes = try adapter.readAll(at: intentURL, maxBytes: 16_384)
                    guard let intent = try? JSONDecoder().decode(PhotoTrashPurgeIntent.self, from: intentBytes),
                          intent.record.identifiesSameSource(as: record) else {
                        throw CaptureFailure(kind: .metadataInvalid(detail: "The deletion record changed. Remaining files were kept."), operation: "permanentlyDeleteOriginal")
                    }
                } else {
                    intentBytes = try JSONEncoder().encode(PhotoTrashPurgeIntent(record: record, confirmedAtUTC: wallClock.now()))
                }
                // An interrupted move/restore must first be recovered; this action
                // never deletes a file from the active originals/metadata tree.
                guard !adapter.fileExists(at: try resolveLibraryURL(record.originalPath, under: root)),
                      !adapter.fileExists(at: try resolveLibraryURL(record.metadataPath, under: root)) else {
                    throw CaptureFailure(kind: .metadataInvalid(detail: "Restore this interrupted move before deleting permanently."), operation: "permanentlyDeleteOriginal")
                }
                let pairs = [(record.storedOriginalPath, record.originalSHA256),
                             (record.directory + "/metadata.json", record.metadataSHA256)]
                for (path, hash) in pairs {
                    let url = try resolveLibraryURL(path, under: root)
                    guard adapter.fileExists(at: url) else {
                        if resuming { continue }
                        throw CaptureFailure(kind: .metadataInvalid(detail: "A Trash file is missing. Restore the interrupted move first."), operation: "permanentlyDeleteOriginal")
                    }
                    guard !(try adapter.isDirectory(at: url)),
                          try adapter.hashFile(at: url, chunkBytes: FileAdapterDefaults.hashChunkBytes).digest.hex == hash else {
                        throw CaptureFailure(kind: .integrityMismatch(detail: "A Trash file changed. No unverified file was deleted."), operation: "permanentlyDeleteOriginal")
                    }
                }
                let metadataURL = try resolveLibraryURL(record.directory + "/metadata.json", under: root)
                if adapter.fileExists(at: metadataURL) {
                    guard case .valid(let sidecar) = readSidecar(at: metadataURL),
                          sidecar.captureID == record.captureID.rawValue, sidecar.libraryID == record.libraryID.rawValue,
                          sidecar.relativeOriginalPath == record.originalPath, sidecar.sha256 == record.originalSHA256 else {
                        throw CaptureFailure(kind: .metadataInvalid(detail: "Trash metadata does not match the photo."), operation: "permanentlyDeleteOriginal")
                    }
                }
                if !resuming { try adapter.writeNewFile(at: intentURL, bytes: intentBytes) }
                for (path, hash) in pairs {
                    let url = try resolveLibraryURL(path, under: root)
                    if adapter.fileExists(at: url) {
                        guard try adapter.hashFile(at: url, chunkBytes: FileAdapterDefaults.hashChunkBytes).digest.hex == hash else {
                            throw CaptureFailure(kind: .integrityMismatch(detail: "A Trash file changed during deletion. Remaining files were kept."), operation: "permanentlyDeleteOriginal")
                        }
                        try removeVerifiedTrashFile(at: url)
                    }
                }
                let recordURL = try resolveLibraryURL(record.directory + "/record.json", under: root)
                if adapter.fileExists(at: recordURL) {
                    guard let current = try? JSONDecoder().decode(PhotoTrashRecord.self, from: adapter.readAll(at: recordURL, maxBytes: 16_384)),
                          current.identifiesSameSource(as: record) else {
                        throw CaptureFailure(kind: .metadataInvalid(detail: "The Trash record changed. Deletion can be retried."), operation: "permanentlyDeleteOriginal")
                    }
                    try removeVerifiedTrashFile(at: recordURL)
                }
                guard try adapter.readAll(at: intentURL, maxBytes: 16_384) == intentBytes else {
                    throw CaptureFailure(kind: .metadataInvalid(detail: "The deletion record changed. Refresh and retry."), operation: "permanentlyDeleteOriginal")
                }
                try removeVerifiedTrashFile(at: intentURL)
                // Keep empty directories; never recursively remove an unknown
                // file that another app/user may have placed beside our files.
            }
            await gate.release()
        } catch { await gate.release(); throw error }
    }

    private func removeVerifiedTrashFile(at url: URL) throws {
        try adapter.removeItem(at: url)
        guard !adapter.fileExists(at: url) else {
            throw CaptureFailure(kind: .operationStalled(detail: "The provider has not finished deleting this file. Retry deletion; its recovery record was kept."), operation: "permanentlyDeleteOriginal.verifyRemoval")
        }
    }

    func restoreOriginal(trashID: UUID, libraryID: LibraryID, generation: RootGeneration) async throws {
        await gate.acquire()
        do {
            let root = try writableRoot(operation: "restoreOriginal")
            guard rootState.libraryID == libraryID, published.withLock({ $0.generation }) == generation,
                  let record = try trashRecord(id: trashID, root: root) else {
                throw CaptureFailure(kind: .folderUnavailable(detail: "Trash or the selected folder changed. Refresh and retry."), operation: "restoreOriginal")
            }
            try coordinator.coordinatedWrite(at: root) { actual in
                guard actual.standardizedFileURL == root.standardizedFileURL else {
                    throw CaptureFailure(kind: .folderUnavailable(detail: "The folder moved; reconnect it."), operation: "restoreOriginal")
                }
                guard !adapter.fileExists(at: try resolveLibraryURL(record.directory + "/delete-intent.json", under: root)) else {
                    throw CaptureFailure(kind: .metadataInvalid(detail: "Permanent deletion has started. Retry deleting this item to finish."), operation: "restoreOriginal")
                }
                let pairs = [(record.directory + "/original." + (record.originalPath as NSString).pathExtension, record.originalPath, record.originalSHA256),
                             (record.directory + "/metadata.json", record.metadataPath, record.metadataSHA256)]
                // Preflight BOTH destinations: restoration never overwrites user files,
                // including a conflict in the second half of an interrupted pair.
                for (stored, destination, expectedHash) in pairs {
                    let storedURL = try resolveLibraryURL(stored, under: root)
                    let destinationURL = try resolveLibraryURL(destination, under: root)
                    for url in [storedURL, destinationURL] where adapter.fileExists(at: url) {
                        guard try adapter.hashFile(at: url, chunkBytes: FileAdapterDefaults.hashChunkBytes).digest.hex == expectedHash else {
                            throw CaptureFailure(kind: .integrityMismatch(detail: "A restore file changed or its destination conflicts. All copies were kept."), operation: "restoreOriginal")
                        }
                    }
                    guard adapter.fileExists(at: storedURL) || adapter.fileExists(at: destinationURL) else {
                        throw CaptureFailure(kind: .metadataInvalid(detail: "A Trash file is missing. Remaining files were kept."), operation: "restoreOriginal")
                    }
                }
                let metadataInTrash = try resolveLibraryURL(record.directory + "/metadata.json", under: root)
                let metadataAtDestination = try resolveLibraryURL(record.metadataPath, under: root)
                let metadataURL = adapter.fileExists(at: metadataInTrash) ? metadataInTrash : metadataAtDestination
                guard case .valid(let sidecar) = readSidecar(at: metadataURL),
                      sidecar.captureID == record.captureID.rawValue, sidecar.libraryID == record.libraryID.rawValue,
                      sidecar.relativeOriginalPath == record.originalPath, sidecar.sha256 == record.originalSHA256 else {
                    throw CaptureFailure(kind: .metadataInvalid(detail: "Trash metadata does not match its original. Nothing was restored."), operation: "restoreOriginal")
                }
                for (stored, destination, _) in pairs {
                    let storedURL = try resolveLibraryURL(stored, under: root)
                    let destinationURL = try resolveLibraryURL(destination, under: root)
                    if !adapter.fileExists(at: destinationURL) {
                        try adapter.createDirectory(at: destinationURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                        try adapter.moveItem(at: storedURL, to: destinationURL)
                    } else if adapter.fileExists(at: storedURL) {
                        // Destination was verified byte-identical in preflight.
                        try adapter.removeItem(at: storedURL)
                    }
                }
            }
            lastReconcileScan.withLock { $0 = nil }
            await gate.release()
        } catch { await gate.release(); throw error }
    }

    // MARK: LibraryStoring — export

    func prepareOriginalExport(sourceIDs: [CaptureID], includeSidecars: Bool) async throws -> ExportSession {
        let requested = published.withLock {
            (state: $0.rootState, root: $0.rootURL, generation: $0.generation, grantID: $0.grant?.leaseIdentity)
        }
        await gate.acquire()
        do {
            let lease = try await openScopedRead()
            defer { closeScopedRead(lease) }
            let current = published.withLock {
                (state: $0.rootState, root: $0.rootURL, generation: $0.generation, grantID: $0.grant?.leaseIdentity)
            }
            let readable: Bool
            switch current.state {
            case .writable, .readOnly: readable = true
            default: readable = false
            }
            guard readable, lease.isUsable, let libraryID = current.state.libraryID,
                  requested.state == current.state, requested.root == current.root,
                  requested.generation == current.generation, requested.grantID == current.grantID,
                  lease.libraryID == libraryID, lease.generation == current.generation,
                  lease.root == current.root, lease.grantID == current.grantID else {
                throw CaptureFailure(kind: .folderUnavailable(detail: "The library folder is not readable or access changed."), operation: "prepareOriginalExport")
            }
            let result = try prepareOriginalExportUngated(sourceIDs: sourceIDs, includeSidecars: includeSidecars, root: lease.root, libraryID: libraryID)
            await gate.release()
            return result
        } catch { await gate.release(); throw error }
    }

    private func prepareOriginalExportUngated(sourceIDs: [CaptureID], includeSidecars: Bool, root: URL, libraryID: LibraryID) throws -> ExportSession {
        let sessionID = UUID()
        let sessionRelative = "\(LibraryStore.exportDirectoryName)/\(sessionID.uuidString.lowercased())"
        let sessionDirectory = temporaryDirectory.appendingPathComponent(sessionRelative, isDirectory: true)
        var missingItems: [String] = [], exported: [URL] = []
        var totalBytes: Int64 = 0
        func coordinatedSidecar(_ url: URL) throws -> SidecarReadResult {
            guard adapter.fileExists(at: url) else { return .missing }
            return try coordinator.coordinatedRead(at: url) { actual in
                let relative = url.pathComponents.dropFirst(root.pathComponents.count).joined(separator: "/")
                _ = try PathSafety.assertContained(actual, in: root, relativePath: relative)
                let actualRelative = actual.pathComponents.dropFirst(root.pathComponents.count).joined(separator: "/")
                try PathSafety.assertNoSymlinkComponents(actualRelative, under: root)
                return readSidecar(at: actual)
            }
        }
        do {
            try adapter.createDirectory(at: sessionDirectory, withIntermediateDirectories: true)
            // One bounded catalog for the entire batch, not one full scan per
            // original. The same fallback identity as gallery reconciliation
            // supports foreign/renamed readable originals without inventing UUIDs.
            let wanted = Set(sourceIDs)
            var paths: [CaptureID: [String]] = [:]
            let entries = try coordinator.coordinatedRead(at: root) { actual -> [ScannedEntry] in
                guard actual.standardizedFileURL == root.standardizedFileURL else { throw FileAdapterError.coordinationFailure("The library moved; reconnect it.") }
                return try scanEntries(root: root, subtrees: [LibraryLayout.originalsDirectoryName], onProgress: nil)
            }
            let duplicateIDs = Self.duplicateFilenameCaptureIDs(in: entries.filter { !$0.isDirectory && !$0.isSymbolicLink }.map(\.relativePath))
            for entry in entries where !entry.isDirectory && !entry.isSymbolicLink {
                guard LibraryStore.isSupportedOriginalPath(entry.relativePath) else { continue }
                var identity = LibraryStore.captureID(fromFileName: (entry.relativePath as NSString).lastPathComponent)
                // A UUID-named file can only match its own UUID or its recovered
                // path identity. Do not read unrelated sidecars for a selection.
                if let identity, !wanted.contains(identity),
                   !wanted.contains(Self.derivedIndexIdentity(for: entry.relativePath)) { continue }
                let sidecarURL = try resolveLibraryURL(sidecarPath(for: entry.relativePath, root: root), under: root)
                let sidecarResult = try coordinatedSidecar(sidecarURL)
                if case .valid(let sidecar) = sidecarResult {
                    if sidecarBindingIssue(sidecar, libraryID: libraryID, originalPath: entry.relativePath, root: root) != nil {
                        identity = Self.derivedIndexIdentity(for: entry.relativePath)
                    } else if identity == nil { identity = CaptureID(sidecar.captureID) }
                } else if let fileID = identity, duplicateIDs.contains(fileID) {
                    identity = Self.derivedIndexIdentity(for: entry.relativePath)
                }
                let id = identity ?? LibraryStore.derivedIndexIdentity(for: entry.relativePath)
                if wanted.contains(id) { paths[id, default: []].append(entry.relativePath) }
            }
            var visited = Set<CaptureID>()
            for captureID in sourceIDs where visited.insert(captureID).inserted {
                let matches = paths[captureID] ?? []
                guard matches.count <= 1 else {
                    throw CaptureFailure(kind: .conflict(detail: "Multiple originals share this capture identity; export requires reconciliation."), operation: "prepareOriginalExport")
                }
                guard let relative = matches.first else {
                    missingItems.append("\(captureID.description) (missing)"); continue
                }
                let originalURL = try resolveLibraryURL(relative, under: root)
                let sidecarURL = try resolveLibraryURL(sidecarPath(for: relative, root: root), under: root)
                let sidecarResult = try coordinatedSidecar(sidecarURL)
                let expected: SHA256Digest?
                if case .valid(let sidecar) = sidecarResult {
                    if let issue = sidecarBindingIssue(sidecar, libraryID: libraryID, originalPath: relative, root: root) {
                        guard captureID == Self.derivedIndexIdentity(for: relative), !includeSidecars else {
                            throw CaptureFailure(kind: .metadataInvalid(detail: issue + " Export only the recovered original or resolve its metadata in Files."), operation: "prepareOriginalExport")
                        }
                        // A recovered export verifies source and destination
                        // bytes directly; foreign metadata supplies no checksum.
                        expected = nil
                    } else {
                        guard sidecar.captureID == captureID.rawValue else {
                            throw CaptureFailure(kind: .metadataInvalid(detail: "The original's sidecar belongs to a different capture."), operation: "prepareOriginalExport")
                        }
                        expected = SHA256Digest(hex: sidecar.sha256)
                    }
                } else { expected = nil }
                let exportedOriginalHash: HashAndByteCount
                do {
                    let result = try coordinator.coordinatedRead(at: originalURL) { actual -> (URL, HashAndByteCount) in
                        _ = try PathSafety.assertContained(actual, in: root, relativePath: relative)
                        let actualRelative = actual.pathComponents.dropFirst(root.pathComponents.count).joined(separator: "/")
                        try PathSafety.assertNoSymlinkComponents(actualRelative, under: root)
                        if LibraryStore.formatForOriginalPath(relative)?.isJPEGDeclaration == true,
                           !isPhotoContainer(at: actual) {
                            throw CaptureFailure(kind: .representationUnavailable(detail: "The selected JPEG is no longer a complete JPEG image."), operation: "prepareOriginalExport")
                        }
                        let originalHash = try adapter.hashFile(at: actual, chunkBytes: FileAdapterDefaults.hashChunkBytes)
                        if let expected, originalHash.digest != expected {
                            throw CaptureFailure(kind: .integrityMismatch(detail: "The original does not match its sidecar; nothing was exported."), operation: "prepareOriginalExport")
                        }
                        let sourceDirectory = sessionDirectory.appendingPathComponent(captureID.description, isDirectory: true)
                        try adapter.createDirectory(at: sourceDirectory, withIntermediateDirectories: true)
                        let destination = sourceDirectory.appendingPathComponent(originalURL.lastPathComponent)
                        let copied = try copyStreamed(from: actual, to: destination)
                        let verified = try adapter.hashFile(at: destination, chunkBytes: FileAdapterDefaults.hashChunkBytes)
                        guard copied == originalHash, verified == originalHash else {
                            throw CaptureFailure(kind: .integrityMismatch(detail: "The exported copy did not match the original bytes."), operation: "prepareOriginalExport")
                        }
                        return (destination, verified)
                    }
                    exportedOriginalHash = result.1
                    exported.append(result.0); totalBytes += result.1.byteCount
                } catch let error as FileAdapterError {
                    // Availability may change during a multi-item selection. The
                    // caller must consent to this exact prepared partial subset.
                    switch error {
                    case .notFound, .permissionDenied:
                        missingItems.append("\(captureID.description) (unreadable: \(describe(error)))"); continue
                    default: throw error
                    }
                }
                if includeSidecars, adapter.fileExists(at: sidecarURL) {
                    let metadataResult = try coordinator.coordinatedRead(at: sidecarURL) { actual -> (URL, Int64) in
                        _ = try PathSafety.assertContained(actual, in: root, relativePath: relative)
                        let actualRelative = actual.pathComponents.dropFirst(root.pathComponents.count).joined(separator: "/")
                        try PathSafety.assertNoSymlinkComponents(actualRelative, under: root)
                        // Metadata is coordinated separately from the original.
                        // A replacement after admission is not authority for the
                        // bytes just copied, even when its own copy hashes match.
                        guard case .valid(let admitted) = sidecarResult,
                              case .valid(let current) = readSidecar(at: actual),
                              current == admitted,
                              sidecarBindingIssue(current, libraryID: libraryID, originalPath: relative, root: root) == nil,
                              current.captureID == captureID.rawValue,
                              current.sha256 == exportedOriginalHash.digest.hex,
                              current.byteCount == exportedOriginalHash.byteCount else {
                            throw CaptureFailure(kind: .metadataInvalid(detail: "The photo's metadata changed or does not match its original. Nothing was exported; refresh and retry."), operation: "prepareOriginalExport")
                        }
                        let sourceHash = try adapter.hashFile(at: actual, chunkBytes: FileAdapterDefaults.hashChunkBytes)
                        let destination = sessionDirectory.appendingPathComponent(captureID.description, isDirectory: true)
                            .appendingPathComponent(sidecarURL.lastPathComponent)
                        let copied = try copyStreamed(from: actual, to: destination)
                        let verified = try adapter.hashFile(at: destination, chunkBytes: FileAdapterDefaults.hashChunkBytes)
                        guard copied == sourceHash, verified == sourceHash else {
                            throw CaptureFailure(kind: .integrityMismatch(detail: "The exported metadata copy did not verify."), operation: "prepareOriginalExport")
                        }
                        return (destination, verified.byteCount)
                    }
                    exported.append(metadataResult.0); totalBytes += metadataResult.1
                }
            }
            guard !exported.isEmpty else {
                throw CaptureFailure(kind: .folderUnavailable(detail: "None of the requested originals could be read locally; no preview was substituted."), operation: "prepareOriginalExport")
            }
        } catch {
            try? adapter.removeItem(at: sessionDirectory)
            if let failure = error as? CaptureFailure { throw failure }
            throw mapFailure("prepareOriginalExport", error: error, retained: .none)
        }
        return ExportSession(sessionID: sessionID, directoryRelativePath: sessionRelative,
            fileURLs: exported, includedSidecars: includeSidecars, missingItems: missingItems,
            totalByteCount: totalBytes, preparedAtUTC: wallClock.now())
    }

    /// Runs `body` inside a balanced scope lease on the granted root.
    ///
    /// The lease is taken and released here, and `body` is synchronous by design:
    /// dispatching asynchronous work out of the accessor and then reporting
    /// success is exactly the failure mode CONTRACTS.md warns about.
    func withRootReadAccess<T: Sendable>(
        _ body: @Sendable (URL) throws -> T
    ) async throws -> T {
        let snapshot = published.withLock { current -> (LibraryRootState, URL?, SecurityScopedRootGrant?) in
            (current.rootState, current.rootURL, current.grant)
        }
        guard let root = snapshot.1 else {
            throw CaptureFailure(kind: .folderUnavailable(detail: "No library folder is selected."),
                                 operation: "withRootReadAccess")
        }
        switch snapshot.0 {
        case .writable, .readOnly, .reconciling:
            break
        case .unavailable(let reason, _):
            throw CaptureFailure(kind: .folderUnavailable(detail: reason),
                                 operation: "withRootReadAccess")
        case .unselected, .resolving:
            throw CaptureFailure(kind: .folderUnavailable(detail: "The library folder is not available."),
                                 operation: "withRootReadAccess")
        }

        // REVIEW.md S09: a reader must hold its OWN lease. Reusing the root's
        // long-lived selection lease meant a concurrent `releaseRoot` revoked the
        // scope while the body was still reading, and the matching close went to
        // whatever grant was current afterwards.
        let lease = try await aquireScopedRead()
        defer { releaseScopedRead(lease) }
        do {
            return try body(root)
        } catch {
            throw mapFailure("withRootReadAccess", error: error, retained: .none)
        }
    }

    /// Opens a reader-owned lease. Refuses when no grant exists or the system
    /// denies the scope, so a denied read never silently proceeds.
    func openScopedRead() async throws -> ScopedReadLease {
        let snapshot = published.withLock { current -> (LibraryRootState, URL?, SecurityScopedRootGrant?, RootGeneration) in
            (current.rootState, current.rootURL, current.grant, current.generation)
        }
        guard let root = snapshot.1, let grant = snapshot.2 else {
            throw CaptureFailure(
                kind: .folderUnavailable(detail: "No library folder access has been established."),
                operation: "openScopedRead")
        }
        let libraryID: LibraryID
        switch snapshot.0 {
        case .writable(let id, _): libraryID = id
        case .readOnly(_, let id):
            guard let id else {
                throw CaptureFailure(kind: .folderUnavailable(detail: "The library has no identity."),
                                     operation: "openScopedRead")
            }
            libraryID = id
        case .reconciling(let id, _): libraryID = id
        case .unavailable(let reason, _):
            throw CaptureFailure(kind: .folderUnavailable(detail: reason), operation: "openScopedRead")
        case .unselected, .resolving:
            throw CaptureFailure(kind: .folderUnavailable(detail: "The library folder is not available."),
                                 operation: "openScopedRead")
        }

        // A reader ALWAYS takes its own lease, so releasing or switching the root
        // cannot revoke a read that is still in progress.
        let opened = grant.beginAccess()
        guard opened else {
            // REVIEW.md R06: a denied open previously incremented the reader count
            // and then threw, so the count stayed held forever and the deferred
            // revocation could never be applied.
            return ScopedReadLease(
                grantID: grant.leaseIdentity,
                root: root,
                libraryID: libraryID,
                generation: snapshot.3,
                openedLease: false,
                wasDenied: true,
                grant: grant,
                onRelease: { [weak self] grantID in
                    self?.releaseReaderLease(for: grantID)
                })
        }
        // Register the reader against THIS grant before returning the token, so the
        // count and the token can never disagree. The grant is recorded in the
        // identity table for the whole read, so closing it later stops THIS grant
        // even after the root has been released or another root selected.
        grantsByID.withLock { table in table[grant.leaseIdentity] = grant }
        scopeRegistry.registerReader(for: grant.leaseIdentity)
        return ScopedReadLease(
            grantID: grant.leaseIdentity,
            root: root,
            libraryID: libraryID,
            generation: snapshot.3,
            openedLease: opened,
            wasDenied: !opened,
            grant: grant,
            onRelease: { [weak self] grantID in
                self?.releaseReaderLease(for: grantID)
            })
    }

    /// Stops a grant's selection lease now, or defers it to that grant's last reader.
    ///
    /// The grant stays addressable by identity either way, so a deferred stop is
    /// always applied to the grant that deferred it (REVIEW.md G01).
    private func deferSelectionStop(_ grant: any SecurityScopedRootGrant) {
        grantsByID.withLock { table in table[grant.leaseIdentity] = grant }
        if scopeRegistry.requestSelectionStop(grant.leaseIdentity) {
            grant.endAccess()
        }
        // A false result can also mean this selection never opened a scope.
        // Keep live readers addressable; forget an entirely unleased grant.
        if scopeRegistry.activeReaders(for: grant.leaseIdentity) == 0,
           !scopeRegistry.isSelectionLeaseOpen(grant.leaseIdentity) {
            grantsByID.withLock { table in _ = table.removeValue(forKey: grant.leaseIdentity) }
            scopeRegistry.forget(grant.leaseIdentity)
        }
    }

    /// Applies a reader lease release exactly once, against the exact grant.
    ///
    /// REVIEW.md F01: the release is a closure captured by the token, so a COPIED
    /// token cannot release twice and cannot decrement another reader. When this was
    /// the last reader of a grant whose selection stop was deferred, that grant's
    /// selection lease is stopped here — never the currently selected root's.
    nonisolated private func releaseReaderLease(for grantID: UUID) {
        // Stop the READER's own lease, addressed by identity rather than by "current".
        releasesByID.withLock { table in table[grantID, default: 0] += 1 }
        let grant = grantsByID.withLock { $0[grantID] }
        grant?.endAccess()

        // If this was the last reader and the SELECTION stop was deferred, stop that
        // same grant's selection lease now. Both stops belong to THIS grant.
        if scopeRegistry.unregisterReader(for: grantID) {
            grant?.endAccess()
        }
        let remainingReaders = scopeRegistry.activeReaders(for: grantID)
        let selectionOpen = scopeRegistry.isSelectionLeaseOpen(grantID)
        if remainingReaders == 0, !selectionOpen {
            scopeRegistry.forget(grantID)
            grantsByID.withLock { table in _ = table.removeValue(forKey: grantID) }
        }
    }

    /// Alias used internally so a denial surfaces as a typed failure before any
    /// file operation is attempted.
    private func aquireScopedRead() async throws -> ScopedReadLease {
        let lease = try await openScopedRead()
        guard lease.isUsable else {
            throw CaptureFailure(
                kind: .folderUnavailable(
                    detail: "The system refused access to the selected folder; reconnect it."),
                operation: "openScopedRead")
        }
        return lease
    }

    /// Resolves an original and reads it inside one owned lease and one coordinated
    /// read (REVIEW.md R06).
    ///
    /// The lease is taken for the WHOLE operation, resolution uses the store's own
    /// symlink defences rather than a bare lexical join, and the body runs
    /// synchronously inside the coordinator's read accessor so no work escapes the
    /// accessor. A denied lease refuses before any path is touched.
    func readOriginal<T: Sendable>(
        relativePath: String,
        _ body: @escaping @Sendable (URL) throws -> T
    ) async throws -> T {
        let lease = try await openScopedRead()
        defer { closeScopedRead(lease) }
        guard lease.isUsable else {
            throw CaptureFailure(
                kind: .folderUnavailable(
                    detail: "The system refused access to the selected folder; reconnect it."),
                operation: "readOriginal")
        }
        // The store's resolver applies containment and symlink checks against the
        // lease's own root, not a path the caller supplied.
        _ = try resolveLibraryURL(relativePath, under: lease.root)

        // Both coordination and its complete synchronous accessor run on the
        // serial read owner. Awaiting it releases this actor while cold ImageIO
        // initializes; new root/recovery commands no longer wait behind a decode.
        // The exact reader-owned lease above remains alive through completion.
        let coordinator = coordinator
        return try await originalReadOwner.submit {
            // A queued read may wait behind another decoder. Recheck components
            // at execution and at accessor entry so a changed symlink cannot
            // inherit the earlier admission check or redirect the read elsewhere.
            do {
                let url = try PathSafety.resolve(relativePath, under: lease.root)
                return try coordinator.coordinatedRead(at: url) { actualURL in
                    _ = try PathSafety.assertContained(actualURL, in: lease.root, relativePath: relativePath)
                    let actualRelative = actualURL.pathComponents.dropFirst(lease.root.pathComponents.count).joined(separator: "/")
                    try PathSafety.assertNoSymlinkComponents(actualRelative, under: lease.root)
                    return try body(actualURL)
                }
            } catch let failure as PathSafetyError {
                throw CaptureFailure(kind: .metadataInvalid(detail: "Unsafe original read: \(failure.description)"), operation: "readOriginal")
            }
        }
    }

    /// Balances a reader lease against the exact grant it opened.
    ///
    /// REVIEW.md S09: the previous close read whatever grant was CURRENT, which
    /// could stop a different root's lease. The token owns its grant, so this is
    /// identity-correct by construction.
    nonisolated func closeScopedRead(_ lease: ScopedReadLease) {
        // The token owns exactly-once release; a copied token cannot release twice.
        _ = lease.release()
    }

    /// Releases the lease exactly once.
    private func releaseScopedRead(_ lease: ScopedReadLease) {
        _ = lease.release()
    }


    /// Prepares an export of PENDING originals from durable internal recovery
    /// storage.
    ///
    /// REVIEW.md C07: `prepareOriginalExport` requires a writable external root and
    /// searches the external originals tree, so it cannot serve the promised
    /// "Export pending original" recovery action precisely when the root is
    /// missing. This path reads the internal copy instead, verifies it against the
    /// recorded digest, and never touches the external root.
    func preparePendingOriginalExport(
        transactionIDs: [TransactionID],
        includeSidecars: Bool
    ) async throws -> ExportSession {
        let sessionID = UUID()
        let sessionRelative = "\(LibraryStore.exportDirectoryName)/\(sessionID.uuidString.lowercased())"
        let sessionDirectory = temporaryDirectory.appendingPathComponent(sessionRelative, isDirectory: true)
        var missingItems: [String] = []
        var exported: [URL] = []
        var totalBytes: Int64 = 0

        do {
            try adapter.createDirectory(at: sessionDirectory, withIntermediateDirectories: true)
        } catch {
            throw mapFailure("preparePendingOriginalExport", error: error, retained: .none)
        }

        do {
            // One fresh catalog for this synchronous actor-owned export. Reloading
            // it for every selected transaction rehashed all staged originals N
            // times. Keep the former deterministic first match, then still verify
            // each selected source and its streamed copy immediately below.
            var byTransaction: [UUID: PendingRecord] = [:]
            for pending in loadPendingRecords() where byTransaction[pending.record.transactionID] == nil {
                byTransaction[pending.record.transactionID] = pending
            }
            var requested = Set<TransactionID>()
            for transactionID in transactionIDs where requested.insert(transactionID).inserted {
                guard let pending = byTransaction[transactionID.rawValue] else {
                    missingItems.append("\(transactionID.description) (no internal recovery record)")
                    continue
                }
                let source = supportDirectory.appendingPathComponent(pending.relativePath, isDirectory: false)
                guard adapter.fileExists(at: source) else {
                    missingItems.append("\(transactionID.description) (internal copy missing)")
                    continue
                }

                // Integrity first: an unverified pending copy is never exported as
                // if it were confirmed bytes.
                let actual: HashAndByteCount
                do {
                    actual = try adapter.hashFile(at: source, chunkBytes: FileAdapterDefaults.hashChunkBytes)
                } catch {
                    missingItems.append("\(transactionID.description) (unreadable: \(describe(error)))")
                    continue
                }
                if let expected = SHA256Digest(hex: pending.record.expectedSHA256), expected != actual.digest {
                    throw CaptureFailure(
                        kind: .integrityMismatch(
                            detail: "The internal recovery copy of \(transactionID.description) does not match its recorded checksum; nothing was exported."),
                        operation: "preparePendingOriginalExport")
                }

                // Recovered naming: the file is labelled as a recovery copy so it is
                // never mistaken for a historical integrity guarantee.
                let base = (pending.record.relativeOriginalPath as NSString).lastPathComponent
                let recoveredName = base.isEmpty
                    ? "\(transactionID.description)-recovered." + (pending.relativePath as NSString).pathExtension
                    : (base as NSString).deletingPathExtension + "-recovered." + (pending.relativePath as NSString).pathExtension
                let destination = sessionDirectory.appendingPathComponent(recoveredName, isDirectory: false)
                let copied = try copyStreamed(from: source, to: destination)
                guard copied.digest == actual.digest, copied.byteCount == actual.byteCount else {
                    throw CaptureFailure(
                        kind: .integrityMismatch(
                            detail: "The exported recovery copy did not match the internal source bytes."),
                        operation: "preparePendingOriginalExport")
                }
                exported.append(destination)
                totalBytes += copied.byteCount

                if includeSidecars, let sidecar = pending.sidecar {
                    let sidecarDestination = sessionDirectory
                        .appendingPathComponent("\(transactionID.description)-recovered.json", isDirectory: false)
                    if let data = try? PortableJSONWriter().encode(
                        sidecar, explicitNullKeys: SourceSidecar.explicitNullKeyPaths) {
                        try adapter.writeNewFile(at: sidecarDestination, bytes: data)
                        totalBytes += Int64(data.count)
                        exported.append(sidecarDestination)
                    }
                }
            }
        } catch {
            do { try adapter.removeItem(at: sessionDirectory) } catch { /* our own temp copy */ }
            if let failure = error as? CaptureFailure { throw failure }
            throw mapFailure("preparePendingOriginalExport", error: error, retained: .none)
        }

        guard !exported.isEmpty else {
            do { try adapter.removeItem(at: sessionDirectory) } catch { /* our own temp copy */ }
            throw CaptureFailure(
                kind: .folderUnavailable(
                    detail: "No pending original could be read and verified from internal recovery storage."),
                operation: "preparePendingOriginalExport")
        }

        return ExportSession(
            sessionID: sessionID,
            directoryRelativePath: sessionRelative,
            fileURLs: exported,
            includedSidecars: includeSidecars,
            missingItems: missingItems,
            totalByteCount: totalBytes,
            preparedAtUTC: wallClock.now())
    }

    /// Opens a balanced scope lease on the granted root.
    ///
    /// Returns whether this call performed the start, so the matching close is
    /// exactly balanced even when several readers overlap.
    func openScopedRoot() async throws -> (url: URL, opened: Bool) {
        let snapshot = published.withLock { current -> (LibraryRootState, URL?, SecurityScopedRootGrant?) in
            (current.rootState, current.rootURL, current.grant)
        }
        guard let root = snapshot.1 else {
            throw CaptureFailure(kind: .folderUnavailable(detail: "No library folder is selected."),
                                 operation: "openScopedRoot")
        }
        switch snapshot.0 {
        case .writable, .readOnly, .reconciling:
            break
        case .unavailable(let reason, _):
            throw CaptureFailure(kind: .folderUnavailable(detail: reason), operation: "openScopedRoot")
        case .unselected, .resolving:
            throw CaptureFailure(kind: .folderUnavailable(detail: "The library folder is not available."),
                                 operation: "openScopedRoot")
        }
        guard let grant = snapshot.2 else {
            // No grant object means access was never established; refusing is
            // safer than reading a path we cannot prove is in scope.
            throw CaptureFailure(
                kind: .folderUnavailable(detail: "Folder access has not been established."),
                operation: "openScopedRoot")
        }
        if grant.activeLeaseCount == 0 {
            // A denied start must not silently proceed to the read.
            guard grant.beginAccess() else {
                throw CaptureFailure(
                    kind: .folderUnavailable(
                        detail: "The system refused access to the selected folder; reconnect it."),
                    operation: "openScopedRoot")
            }
            return (root, true)
        }
        return (root, false)
    }

    nonisolated func closeScopedRoot(_ opened: Bool) {
        guard opened else { return }
        let grant = published.withLock { $0.grant }
        grant?.endAccess()
    }

    func discardExport(sessionID: UUID) async {
        // Only this session's own directory, inside the app's disposable export root.
        let sessionDirectory = temporaryDirectory
            .appendingPathComponent(LibraryStore.exportDirectoryName, isDirectory: true)
            .appendingPathComponent(sessionID.uuidString.lowercased(), isDirectory: true)
        guard adapter.fileExists(at: sessionDirectory) else { return }
        try? adapter.removeItem(at: sessionDirectory)
    }

    func clearAbandonedExports() async {
        let exportRoot = temporaryDirectory.appendingPathComponent(LibraryStore.exportDirectoryName, isDirectory: true)
        guard adapter.fileExists(at: exportRoot) else { return }
        // Only the app's own disposable export directory is removed.
        do { try adapter.removeItem(at: exportRoot) } catch { /* disposable */ }
    }

    /// Opt-in organization of legacy metadata. Copies and verifies each bounded
    /// app record before removing that exact unchanged legacy record. A partial
    /// run remains readable through the mixed-layout reader and is retryable.
    func organizeMetadata() async throws -> Int {
        await gate.acquire()
        do {
            let count = try organizeMetadataUngated()
            await gate.release()
            return count
        } catch {
            await gate.release()
            throw error
        }
    }
    private func organizeMetadataUngated() throws -> Int {
        let root = try writableRoot(operation: "organizeMetadata")
        guard let manifest = published.withLock({ $0.manifest }) else {
            throw CaptureFailure(kind: .metadataInvalid(detail: "The library identity is unavailable."), operation: "organizeMetadata")
        }
        let entries = try scanEntries(root: root,
            subtrees: [LibraryLayout.originalsDirectoryName, LibraryLayout.sequencesDirectoryName], onProgress: nil)
        var moved = 0
        for entry in entries where !entry.isDirectory && !entry.isSymbolicLink && entry.relativePath.hasSuffix(".json") {
            let source = try resolveLibraryURL(entry.relativePath, under: root)
            let isSequence = entry.relativePath.hasPrefix(LibraryLayout.sequencesDirectoryName + "/")
            if isSequence {
                guard source.lastPathComponent.hasPrefix(LibraryLayout.sequenceFilePrefix),
                      UUID(uuidString: String(source.deletingPathExtension().lastPathComponent.dropFirst(LibraryLayout.sequenceFilePrefix.count))) != nil else { continue }
            } else if LibraryStore.captureID(fromFileName: source.lastPathComponent) == nil { continue }
            let limit = isSequence ? MetadataBounds.maxSequenceJSONUTF8Bytes : MetadataBounds.maxSourceSidecarUTF8Bytes
            let data = try coordinator.coordinatedRead(at: source) { try adapter.readAll(at: $0, maxBytes: limit) }
            if isSequence {
                guard let document = try? PortableJSONReader().decode(SequenceDocument.self, from: data, limitBytes: limit),
                      document.libraryID == manifest.libraryID,
                      document.schemaVersion == truongCamSupportedSchemaVersion,
                      SequenceDocumentSemanticValidator().validate(document).isEmpty,
                      source.lastPathComponent == LibraryLayout.sequenceFileName(for: SequenceID(document.sequenceID)) else { continue }
            } else {
                guard case .valid(let sidecar) = readSidecar(at: source),
                      sidecar.libraryID == manifest.libraryID,
                      source.lastPathComponent == LibraryLayout.sidecarFileName(for: CaptureID(sidecar.captureID)) else { continue }
            }
            let target = try resolveLibraryURL(LibraryLayout.metadataDirectoryName + "/" + entry.relativePath, under: root)
            try moveVerifiedMetadata(data, from: source, to: target, limit: limit)
            moved += 1
        }
        let legacyManifest = try resolveLibraryURL(LibraryLayout.legacyLibraryManifestName, under: root)
        if adapter.fileExists(at: legacyManifest) {
            let old = try coordinator.coordinatedRead(at: legacyManifest) {
                try adapter.readAll(at: $0, maxBytes: MetadataBounds.maxSourceSidecarUTF8Bytes)
            }
            guard case .opened(let identity) = readManifest(at: legacyManifest), identity.libraryID == manifest.libraryID,
                  var object = try JSONSerialization.jsonObject(with: old) as? [String: Any] else {
                throw CaptureFailure(kind: .conflict(detail: "The legacy library manifest changed during organization."), operation: "organizeMetadata")
            }
            object["layoutVersion"] = LibraryLayout.supportedLayoutVersion
            let updated = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .prettyPrinted])
            let target = try resolveLibraryURL(LibraryLayout.libraryManifestName, under: root)
            if adapter.fileExists(at: target) {
                guard case .opened(let current) = readManifest(at: target), current.libraryID == manifest.libraryID else {
                    throw CaptureFailure(kind: .conflict(detail: "A different manifest occupies the metadata folder."), operation: "organizeMetadata")
                }
                let currentData = try coordinator.coordinatedRead(at: target) {
                    try adapter.readAll(at: $0, maxBytes: MetadataBounds.maxSourceSidecarUTF8Bytes)
                }
                guard var currentObject = try JSONSerialization.jsonObject(with: currentData) as? [String: Any] else {
                    throw CaptureFailure(kind: .metadataInvalid(detail: "The metadata manifest cannot be compared safely."), operation: "organizeMetadata")
                }
                currentObject["layoutVersion"] = LibraryLayout.supportedLayoutVersion
                guard NSDictionary(dictionary: object).isEqual(to: currentObject) else {
                    throw CaptureFailure(kind: .conflict(detail: "The two manifests contain different app records; both were preserved."), operation: "organizeMetadata")
                }
                // Matching identities and complete metadata, including unknown fields.
                try removeUnchangedMetadata(old, at: legacyManifest, limit: MetadataBounds.maxSourceSidecarUTF8Bytes)
            } else {
                try coordinator.coordinatedWrite(at: target) { actual in
                    try adapter.createDirectory(at: actual.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try adapter.writeNewFile(at: actual, bytes: updated)
                }
                let verified = try coordinator.coordinatedRead(at: target) {
                    try adapter.readAll(at: $0, maxBytes: MetadataBounds.maxSourceSidecarUTF8Bytes)
                }
                guard verified == updated else {
                    throw CaptureFailure(kind: .integrityMismatch(detail: "The new manifest did not verify; the legacy record was kept."), operation: "organizeMetadata")
                }
                try removeUnchangedMetadata(old, at: legacyManifest, limit: MetadataBounds.maxSourceSidecarUTF8Bytes)
            }
            moved += 1
        }
        return moved
    }

    private func moveVerifiedMetadata(_ data: Data, from source: URL, to target: URL, limit: Int) throws {
        try coordinator.coordinatedWrite(at: target) { actual in
            if adapter.fileExists(at: actual) {
                guard try adapter.readAll(at: actual, maxBytes: limit) == data else {
                    throw CaptureFailure(kind: .conflict(detail: "Different metadata already exists at \(actual.lastPathComponent); both copies were kept."), operation: "organizeMetadata")
                }
            } else {
                try adapter.createDirectory(at: actual.deletingLastPathComponent(), withIntermediateDirectories: true)
                try adapter.writeNewFile(at: actual, bytes: data)
            }
        }
        let verified = try coordinator.coordinatedRead(at: target) { try adapter.readAll(at: $0, maxBytes: limit) }
        guard verified == data else {
            throw CaptureFailure(kind: .integrityMismatch(detail: "Metadata copy did not verify; the legacy record was kept."), operation: "organizeMetadata")
        }
        try removeUnchangedMetadata(data, at: source, limit: limit)
    }
    private func removeUnchangedMetadata(_ data: Data, at source: URL, limit: Int) throws {
        try coordinator.coordinatedWrite(at: source) { actual in
            guard try adapter.readAll(at: actual, maxBytes: limit) == data else {
                throw CaptureFailure(kind: .conflict(detail: "The legacy metadata changed and was kept."), operation: "organizeMetadata")
            }
            try adapter.removeItem(at: actual)
        }
    }

    // MARK: LibraryStoring — sequence documents

    func writeSequenceDocument(_ document: SequenceDocument) async throws {
        let requested = published.withLock {
            (state: $0.rootState, root: $0.rootURL, generation: $0.generation, grantID: $0.grant?.leaseIdentity)
        }
        await gate.acquire()
        do {
            let current = published.withLock {
                (state: $0.rootState, root: $0.rootURL, generation: $0.generation, grantID: $0.grant?.leaseIdentity)
            }
            guard case .writable(let libraryID, _) = current.state, let root = current.root else {
                throw CaptureFailure(kind: .folderUnavailable(detail: "The library folder is not writable."),
                                     operation: "writeSequenceDocument")
            }
            // A final/interrupted sequence update can arrive after its run's
            // folder was replaced. Neither a foreign document nor a queued
            // request for an earlier grant may create or replace current files.
            guard document.libraryID == libraryID.rawValue,
                  requested.state == current.state, requested.root == current.root,
                  requested.generation == current.generation, requested.grantID == current.grantID else {
                throw CaptureFailure(kind: .metadataInvalid(detail: "The sequence or selected folder changed; no metadata was written."),
                                     operation: "writeSequenceDocument")
            }
            try writeSequenceDocumentUngated(document, root: root)
            await gate.release()
        } catch {
            await gate.release()
            throw error
        }
    }

    private func writeSequenceDocumentUngated(_ document: SequenceDocument, root: URL) throws {
        let problems = SequenceDocumentSemanticValidator().validate(document)
        guard problems.isEmpty else {
            throw CaptureFailure(kind: .metadataInvalid(detail: problems.joined(separator: "; ")),
                                 operation: "writeSequenceDocument")
        }
        let data: Data
        do {
            data = try PortableJSONWriter().encode(
                document, explicitNullKeys: SequenceDocument.explicitNullKeyPaths)
        } catch {
            throw mapFailure("writeSequenceDocument", error: error, retained: .none)
        }
        guard data.count <= MetadataBounds.maxSequenceJSONUTF8Bytes else {
            throw CaptureFailure(kind: .metadataInvalid(detail: "The sequence document exceeds the 2 MiB bound."),
                                 operation: "writeSequenceDocument")
        }
        let relativePath = LibraryLayout.metadataSequencePath(for: SequenceID(document.sequenceID))
        let destination = try resolveLibraryURL(relativePath, under: root)
        let temporary = destination.deletingLastPathComponent()
            .appendingPathComponent("SEQ_\(document.sequenceID.uuidString.lowercased()).\(UUID().uuidString.lowercased()).tmp",
                                    isDirectory: false)
        do {
            try coordinator.coordinatedWrite(at: destination) { actual in
                try adapter.createDirectory(at: actual.deletingLastPathComponent(),
                                            withIntermediateDirectories: true)
                try adapter.writeNewFile(at: temporary, bytes: data)
                if adapter.fileExists(at: actual) {
                    // Replacement is intentional for a sequence document: the
                    // sources' own sidecars can always rebuild membership.
                    try adapter.removeItem(at: actual)
                }
                try adapter.moveItem(at: temporary, to: actual)
            }
        } catch {
            do {
                if adapter.fileExists(at: temporary) { try adapter.removeItem(at: temporary) }
            } catch { /* our own temporary file */ }
            throw mapFailure("writeSequenceDocument", error: error, retained: .none)
        }
    }

    func readSequenceDocument(_ sequenceID: SequenceID) async throws -> SequenceDocument {
        let root = try writableRoot(operation: "readSequenceDocument")
        let relativePath = existingMetadataPath(LibraryLayout.metadataSequencePath(for: sequenceID),
                                               legacy: LibraryLayout.relativeSequencePath(for: sequenceID), root: root)
        let url = try resolveLibraryURL(relativePath, under: root)
        let data: Data
        do {
            data = try adapter.readAll(at: url, maxBytes: MetadataBounds.maxSequenceJSONUTF8Bytes)
        } catch {
            throw mapFailure("readSequenceDocument", error: error, retained: .none)
        }
        do {
            return try PortableJSONReader().decode(
                SequenceDocument.self, from: data, limitBytes: MetadataBounds.maxSequenceJSONUTF8Bytes)
        } catch {
            throw CaptureFailure(kind: .metadataInvalid(detail: describe(error)),
                                 operation: "readSequenceDocument")
        }
    }

    // MARK: - Internals: paths

    private func writableRoot(operation: String) throws -> URL {
        let snapshot = published.withLock { current -> (LibraryRootState, URL?) in
            (current.rootState, current.rootURL)
        }
        guard case .writable = snapshot.0, let root = snapshot.1 else {
            throw CaptureFailure(kind: .folderUnavailable(detail: "The library folder is not writable."),
                                 operation: operation)
        }
        return root
    }

    /// New writes use metadata/. Existing legacy completion records remain in
    /// place and authoritative; upgrading never silently moves/deletes user files.
    private func existingMetadataPath(_ path: String, legacy: String, root: URL) -> String {
        if adapter.fileExists(at: root.appendingPathComponent(path)) { return path }
        if adapter.fileExists(at: root.appendingPathComponent(legacy)) { return legacy }
        return path
    }
    private func sidecarPath(for original: String, root: URL) -> String {
        existingMetadataPath(LibraryLayout.metadataSidecarPath(for: original),
                             legacy: LibraryLayout.relativeSidecarPath(alongside: original), root: root)
    }

    private func resolveLibraryURL(_ relativePath: String, under root: URL) throws -> URL {
        do {
            return try PathSafety.resolve(relativePath, under: root)
        } catch {
            throw CaptureFailure(kind: .metadataInvalid(detail: "Unsafe relative path \(relativePath): \(describe(error))"),
                                 operation: "resolveLibraryURL")
        }
    }

    private func pendingDirectory(for captureID: CaptureID) -> URL {
        supportDirectory
            .appendingPathComponent(LibraryStore.pendingDirectoryName, isDirectory: true)
            .appendingPathComponent(captureID.description, isDirectory: true)
    }

    private func relativePendingPath(for captureID: CaptureID, format: SourceFormatRecord) -> String {
        "\(LibraryStore.pendingDirectoryName)/\(captureID.description)/source.\(format.fileExtension)"
    }

    // MARK: - Internals: scanning

    /// Bounded, root-restricted scan of one or more subtrees. Directories that
    /// are ancestors of a requested subtree are traversed, everything else is
    /// skipped, symlinks are never followed and file contents are never read.
    private func scanEntries(
        root: URL,
        subtrees: [String],
        onProgress: (@Sendable (ScanProgress) -> Void)?
    ) throws -> [ScannedEntry] {
        var collected: [ScannedEntry] = []
        var seen = Set<String>()
        for _ in 0..<scanRoundBudget {
            let snapshot = seen
            let batch: [ScannedEntry]
            do {
                batch = try adapter.scan(
                    root: root,
                    maxEntries: LibraryStore.scanBatchEntries,
                    shouldSkipRelativePath: { relative in
                        if relative.isEmpty { return false }
                        if snapshot.contains(relative) { return true }
                        // A subtree root such as "originals" is not itself inside
                        // "originals/", but it must still be traversed, so the
                        // filter only rejects paths that resolve to a subtree.
                        return !LibraryStore.isWithinAny(subtree: subtrees, relativePath: relative)
                    },
                    shouldDescendRelativeDirectory: { LibraryStore.isWithinAny(subtree: subtrees, relativePath: $0) },
                    onProgress: onProgress)
            } catch {
                throw mapFailure("reconcile", error: error, retained: .none)
            }
            let fresh = batch.filter { !seen.contains($0.relativePath) }
            if fresh.isEmpty { return collected }
            for entry in fresh { seen.insert(entry.relativePath) }
            collected.append(contentsOf: fresh)
        }
        // One bounded probe distinguishes an exactly-full scan from a truncated
        // one. A previous index remains usable when reconciliation throws; no
        // partially enumerated collection is published as a complete library.
        let snapshot = seen
        let remainder = try adapter.scan(root: root, maxEntries: 1, shouldSkipRelativePath: { relative in
            if relative.isEmpty { return false }
            return snapshot.contains(relative)
                || !LibraryStore.isWithinAny(subtree: subtrees, relativePath: relative)
        }, shouldDescendRelativeDirectory: { LibraryStore.isWithinAny(subtree: subtrees, relativePath: $0) },
           onProgress: onProgress)
        guard remainder.isEmpty else {
            throw CaptureFailure(kind: .metadataInvalid(detail: "This library exceeds the safe scan limit. Its previous index was retained; no complete listing was claimed. Manage the folder in Files before retrying."), operation: "reconcile.scanLimit")
        }
        return collected
    }

    nonisolated private static func sourceFingerprint(byteCount: Int64?, modificationDate: Date?) -> String? {
        guard byteCount != nil || modificationDate != nil else { return nil }
        return "\(byteCount.map(String.init) ?? "-")|\(modificationDate.map { String($0.timeIntervalSince1970) } ?? "-")"
    }

    /// True when `relativePath` is inside a requested subtree or is one of its
    /// ancestor directories (so the scan can descend into it).
    static func isWithinAny(subtree subtrees: [String], relativePath: String) -> Bool {
        for subtree in subtrees {
            if relativePath == subtree || relativePath.hasPrefix(subtree + "/") { return true }
            if subtree.hasPrefix(relativePath + "/") { return true }
        }
        return false
    }

    /// A file is treated as a DNG only when its bytes are really a TIFF
    /// container. The name alone is never enough (LIBRARY.md: "Recognize DNG
    /// files with UTType and actual decoding/properties, not filename alone"),
    /// and a thumbnail or JPEG named `.dng` is therefore never a recovered
    /// original.
    private func isDNGContainer(at url: URL) -> Bool {
        // Only the container header is read; the file is never decoded here.
        let header: Data
        do {
            let handle = try adapter.openRead(at: url)
            do {
                header = try handle.read(maxBytes: 8)
                try handle.close()
            } catch {
                do { try handle.close() } catch { /* already failing */ }
                return false
            }
        } catch {
            return false
        }
        guard LibraryStore.looksLikeTIFFContainer(header) else { return false }
        do {
            let values = try url.resourceValues(forKeys: [.contentTypeKey])
            if let type = values.contentType {
                return type.conforms(to: .rawImage) || type.conforms(to: .image)
            }
        } catch {
            // The provider exposed no content type; the container header stands.
        }
        return true
    }

    /// Core's sidecar validator now keeps blocking problems and non-blocking
    /// status notices in separate channels (`SourceValidationReport`), so this is
    /// a straight pass-through: an intact delivered source from a partially
    /// failed request is committable, while the sequence still cannot be reported
    /// complete (CONTRACTS.md).
    static func hardSidecarProblems(_ problems: [String]) -> [String] {
        problems
    }

    /// Validate the native HEIF container and a real primary image. JPEG bytes,
    /// truncated ftyp headers and arbitrary processed formats cannot enter HEIF staging.
    static func isHEIFData(_ bytes: Data) -> Bool {
        guard bytes.count >= 16, String(data: Data(bytes.dropFirst(4).prefix(4)), encoding: .ascii) == "ftyp",
              let source = CGImageSourceCreateWithData(bytes as CFData, nil),
              let type = CGImageSourceGetType(source), UTType(type as String)?.conforms(to: .heic) == true,
              CGImageSourceGetCount(source) > 0,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any],
              let width = properties[kCGImagePropertyPixelWidth as String] as? Int,
              let height = properties[kCGImagePropertyPixelHeight as String] as? Int else { return false }
        return width > 0 && height > 0
    }

    /// JPEG is an explicit processed original. ImageIO must identify a complete
    /// JPEG image with positive dimensions; a filename or SOI prefix alone is not
    /// evidence, and these bytes can never satisfy the Bayer/TIFF branch.
    static func isJPEGData(_ bytes: Data) -> Bool {
        guard bytes.count >= 4, bytes.starts(with: [0xFF, 0xD8, 0xFF]),
              let source = CGImageSourceCreateWithData(bytes as CFData, nil) else { return false }
        return isProcessedPhotoSource(source, expectedType: .jpeg)
    }

    private static func isProcessedPhotoSource(_ source: CGImageSource, expectedType: UTType) -> Bool {
        guard let type = CGImageSourceGetType(source),
              UTType(type as String)?.conforms(to: expectedType) == true,
              CGImageSourceGetCount(source) > 0,
              CGImageSourceGetStatusAtIndex(source, 0) == .statusComplete,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any],
              let width = properties[kCGImagePropertyPixelWidth as String] as? Int,
              let height = properties[kCGImagePropertyPixelHeight as String] as? Int else { return false }
        return width > 0 && height > 0
    }

    /// Includes the conventional alternate JPEG extension when reconnecting an
    /// existing Files folder. New app captures always use the canonical .jpg.
    static func isSupportedOriginalPath(_ path: String) -> Bool {
        ["dng", "heic", "jpg", "jpeg"].contains((path as NSString).pathExtension.lowercased())
    }

    private static func formatForOriginalPath(_ path: String) -> SourceFormatRecord? {
        switch (path as NSString).pathExtension.lowercased() {
        case "heic": return .frontHEIF
        case "jpg", "jpeg": return .jpeg
        default: return nil
        }
    }

    private func isPhotoContainer(at url: URL) -> Bool {
        if url.pathExtension.lowercased() == "dng" { return isDNGContainer(at: url) }
        guard let format = LibraryStore.formatForOriginalPath(url.path),
              let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return false }
        return LibraryStore.isProcessedPhotoSource(source, expectedType: format.isJPEGDeclaration ? .jpeg : .heic)
    }

    static func looksLikeTIFFContainer(_ bytes: Data) -> Bool {
        guard bytes.count >= 4 else { return false }
        let prefix = [UInt8](bytes.prefix(4))
        let littleEndian = prefix[0] == 0x49 && prefix[1] == 0x49 && prefix[2] == 0x2A && prefix[3] == 0x00
        let bigEndian = prefix[0] == 0x4D && prefix[1] == 0x4D && prefix[2] == 0x00 && prefix[3] == 0x2A
        return littleEndian || bigEndian
    }

    // MARK: - Internals: sidecars

    private enum SidecarReadResult {
        case missing
        case valid(SourceSidecar)
        case invalid(String)
    }

    /// Syntax-valid metadata is authority only for this selected library and
    /// original. Preserve a paired local filename rename in the same directory
    /// when its old destination is absent; copied/misplaced records cannot give
    /// a second UUID-named file another capture's or library's authority.
    private func sidecarBindingIssue(_ sidecar: SourceSidecar, libraryID: LibraryID, originalPath: String, root: URL) -> String? {
        if case .readOnly = rootState, currentManifest == nil {
            return "The library uses unsupported metadata; the original is shown as a recovered file."
        }
        if sidecar.libraryID != libraryID.rawValue {
            return "The sidecar belongs to another library; the original is shown as a recovered file."
        }
        if sidecar.relativeOriginalPath != originalPath {
            let pairedRename = Self.captureID(fromFileName: (originalPath as NSString).lastPathComponent) == nil
                && (originalPath as NSString).deletingLastPathComponent == (sidecar.relativeOriginalPath as NSString).deletingLastPathComponent
                && (originalPath as NSString).pathExtension.lowercased() == (sidecar.relativeOriginalPath as NSString).pathExtension.lowercased()
                && !adapter.fileExists(at: root.appendingPathComponent(sidecar.relativeOriginalPath))
            if !pairedRename {
                return "The sidecar names another original path; the original is shown as a recovered file."
            }
        }
        return nil
    }

    private static func isSidecarLocation(_ path: String, for original: String) -> Bool {
        path == LibraryLayout.metadataSidecarPath(for: original)
            || path == LibraryLayout.relativeSidecarPath(alongside: original)
    }

    private func readSidecar(at url: URL) -> SidecarReadResult {
        guard adapter.fileExists(at: url) else { return .missing }
        let data: Data
        do {
            data = try adapter.readAll(at: url, maxBytes: MetadataBounds.maxSourceSidecarUTF8Bytes)
        } catch {
            return .invalid("The sidecar could not be read safely: \(describe(error))")
        }
        let version: Int?
        do {
            version = try PortableJSONReader.peekMajorVersion(in: data)
        } catch {
            return .invalid("The sidecar is not valid JSON: \(describe(error))")
        }
        if let version, version > truongCamSupportedSchemaVersion {
            return .invalid("The sidecar uses newer schemaVersion \(version); it is shown read-only and was not rewritten.")
        }
        do {
            let sidecar = try PortableJSONReader().decode(
                SourceSidecar.self, from: data, limitBytes: MetadataBounds.maxSourceSidecarUTF8Bytes)
            let problems = LibraryStore.hardSidecarProblems(SourceSidecarSemanticValidator().validate(sidecar))
            guard problems.isEmpty else {
                return .invalid("The sidecar failed semantic validation: \(problems.joined(separator: "; "))")
            }
            return .valid(sidecar)
        } catch {
            return .invalid("The sidecar could not be decoded: \(describe(error))")
        }
    }

    /// The internal staging metadata snapshot. It is our own journal file, not
    /// foreign metadata, so it is decoded leniently: an incomplete capture
    /// snapshot must never block recovery of its bytes.
    private func readPendingSidecar(at url: URL) -> SourceSidecar? {
        guard adapter.fileExists(at: url) else { return nil }
        do {
            let data = try adapter.readAll(at: url, maxBytes: MetadataBounds.maxSourceSidecarUTF8Bytes)
            return try PortableJSONReader().decode(
                SourceSidecar.self, from: data, limitBytes: MetadataBounds.maxSourceSidecarUTF8Bytes)
        } catch {
            return nil
        }
    }

    private func readAndValidateSidecar(at url: URL, expecting captureID: CaptureID) throws -> SourceSidecar? {
        guard adapter.fileExists(at: url) else { return nil }
        let result = readSidecar(at: url)
        switch result {
        case .valid(let sidecar):
            guard sidecar.captureID == captureID.rawValue else { return nil }
            return sidecar
        case .invalid, .missing:
            return nil
        }
    }

    private func makeSidecar(metadata: SourceCaptureMetadata,
                             relativeOriginalPath: String,
                             byteCount: Int64,
                             sha256: SHA256Digest?,
                             commitRecordedAtUTC: Date) -> SourceSidecar {
        SourceSidecar(
            schemaVersion: truongCamSupportedSchemaVersion,
            captureID: metadata.captureID.rawValue,
            libraryID: metadata.libraryID.rawValue,
            capturedAtUTC: metadata.capturedAtUTC,
            timezoneOffsetSeconds: metadata.timezoneOffsetSeconds,
            relativeOriginalPath: relativeOriginalPath,
            byteCount: byteCount,
            sha256: sha256?.hex ?? String(repeating: "0", count: 64),
            format: metadata.format,
            deviceModel: metadata.deviceModel,
            osVersion: metadata.osVersion,
            cameraDeviceType: metadata.cameraDeviceType,
            requested: metadata.requested,
            observed: metadata.observed,
            ui: metadata.equivalentFocalLengthMM.map {
                SourceUIHints(equivalentFocalLengthMM: $0, cropGuide: nil)
            },
            sequence: metadata.sequence,
            acquisitionStatus: metadata.acquisitionStatus,
            commitRecordedAtUTC: commitRecordedAtUTC,
            capturedAtProvenance: metadata.capturedAtProvenance)
    }

    static func metadata(from sidecar: SourceSidecar) -> SourceCaptureMetadata {
        SourceCaptureMetadata(
            captureID: CaptureID(sidecar.captureID),
            libraryID: LibraryID(sidecar.libraryID),
            capturedAtUTC: sidecar.capturedAtUTC,
            capturedAtProvenance: sidecar.capturedAtProvenance,
            timezoneOffsetSeconds: sidecar.timezoneOffsetSeconds,
            format: sidecar.format,
            deviceModel: sidecar.deviceModel,
            osVersion: sidecar.osVersion,
            cameraDeviceType: sidecar.cameraDeviceType,
            requested: sidecar.requested,
            observed: sidecar.observed,
            acquisitionStatus: sidecar.acquisitionStatus,
            sequence: sidecar.sequence,
            equivalentFocalLengthMM: sidecar.ui?.equivalentFocalLengthMM)
    }

    private static func terminalStatus(for status: AcquisitionStatus,
                                       errorDescription: String?) -> AcquisitionTerminalStatus {
        switch status {
        case .complete:
            return .success
        case .partialWithRetainedSource:
            return .partialWithRetainedSource(errorDescription: errorDescription ?? "the native request reported an error")
        }
    }

    /// 64 zero characters is always a valid SHA-256 rendering; the fallback is
    /// never used as an integrity claim, only as "no digest recorded yet".
    static let zeroDigest: SHA256Digest = {
        guard let digest = SHA256Digest(hex: String(repeating: "0", count: 64)) else {
            preconditionFailure("64 zero characters is a canonical SHA-256 rendering")
        }
        return digest
    }()

    private func sidecarDigest(_ sidecar: SourceSidecar) -> SHA256Digest {
        SHA256Digest(hex: sidecar.sha256) ?? LibraryStore.zeroDigest
    }

    // MARK: - Internals: streaming I/O

    /// Bounded-chunk digest over already-received bytes. The source is never
    /// hashed twice as one allocation.
    private func hashBytes(_ bytes: Data) throws -> HashAndByteCount {
        var hasher = SHA256()
        bytes.withUnsafeBytes { (buffer: UnsafeRawBufferPointer) in
            var offset = 0
            while offset < buffer.count {
                let end = min(offset + FileAdapterDefaults.hashChunkBytes, buffer.count)
                hasher.update(bufferPointer: UnsafeRawBufferPointer(rebasing: buffer[offset..<end]))
                offset = end
            }
        }
        return HashAndByteCount(digest: try StorageCrypto.digestHex(hasher.finalize().map { $0 }),
                                byteCount: Int64(bytes.count))
    }

    private func writeStreamed(_ bytes: Data, to destination: URL) throws -> HashAndByteCount {
        let writer = try adapter.beginExclusiveCreate(at: destination)
        var hasher = SHA256()
        var total: Int64 = 0
        do {
            var offset = 0
            while offset < bytes.count {
                let end = min(offset + FileAdapterDefaults.hashChunkBytes, bytes.count)
                let chunk = bytes[(bytes.startIndex + offset)..<(bytes.startIndex + end)]
                hasher.update(data: chunk)
                try writer.write(chunk)
                total += Int64(chunk.count)
                offset = end
            }
            try writer.close()
        } catch {
            do { try writer.closeAndDelete() } catch { /* already failing */ }
            throw error
        }
        return HashAndByteCount(digest: try StorageCrypto.digestHex(hasher.finalize().map { $0 }),
                                byteCount: total)
    }

    private func copyStreamed(from source: URL, to destination: URL) throws -> HashAndByteCount {
        let reader = try adapter.openRead(at: source)
        var hasher = SHA256()
        var total: Int64 = 0
        var writer: FileWriteHandle?
        do {
            let handle = try adapter.beginExclusiveCreate(at: destination)
            writer = handle
            while true {
                let chunk = try reader.read(maxBytes: FileAdapterDefaults.hashChunkBytes)
                if chunk.isEmpty { break }
                hasher.update(data: chunk)
                try handle.write(chunk)
                total += Int64(chunk.count)
            }
            try handle.close()
            try reader.close()
        } catch {
            if let writer { do { try writer.closeAndDelete() } catch { /* already failing */ } }
            do { try reader.close() } catch { /* already failing */ }
            throw error
        }
        return HashAndByteCount(digest: try StorageCrypto.digestHex(hasher.finalize().map { $0 }),
                                byteCount: total)
    }

    // MARK: - Internals: journals

    private func writeJournal(_ record: TransactionRecord, at url: URL) throws {
        let data = try PortableJSONWriter().encode(
            record, explicitNullKeys: TransactionRecord.explicitNullKeyPaths)
        try writeJournalData(data, at: url)
    }

    /// Records a failure in the journal when possible. The thrown failure is
    /// already the caller's answer, so a journal write problem here is not
    /// allowed to replace it.
    private func recordFailedPhase(_ record: inout TransactionRecord,
                                   failure: CaptureFailure,
                                   at url: URL) {
        record.phase = .failed
        record.lastError = failure.kind.userDescription
        record.updatedAtUTC = wallClock.now()
        do { try writeJournal(record, at: url) } catch { /* keep the original failure */ }
    }

    /// Internal journal replacement. The journal is our own disposable state: a
    /// crash between the remove and the move leaves `source.dng` plus a
    /// synthesised record, which is exactly what `pendingOriginals()` repairs, so
    /// durable source bytes are never lost to a journal write.
    private func writeJournalData(_ data: Data, at url: URL) throws {
        let temporary = url.deletingLastPathComponent()
            .appendingPathComponent("\(UUID().uuidString.lowercased()).journal.tmp", isDirectory: false)
        try adapter.writeNewFile(at: temporary, bytes: data)
        if adapter.fileExists(at: url) {
            try adapter.removeItem(at: url)
        }
        try adapter.moveItem(at: temporary, to: url)
    }

    private func loadRecord(at url: URL, captureID: CaptureID) -> TransactionRecord? {
        guard adapter.fileExists(at: url) else { return nil }
        do {
            let data = try adapter.readAll(at: url, maxBytes: MetadataBounds.maxSourceSidecarUTF8Bytes)
            let record = try PortableJSONReader().decode(
                TransactionRecord.self, from: data, limitBytes: MetadataBounds.maxSourceSidecarUTF8Bytes)
            guard record.captureID == captureID.rawValue else { return nil }
            return record
        } catch {
            return nil
        }
    }

    private struct PendingRecord {
        var record: TransactionRecord
        var relativePath: String
        var sidecar: SourceSidecar?
        var digestFallback: SHA256Digest
    }

    private func loadPendingRecord(transactionID: TransactionID) -> PendingRecord? {
        loadPendingRecords().first { $0.record.transactionID == transactionID.rawValue }
    }

    /// Reads internal recovery staging. A missing or unreadable journal next to a
    /// complete `source.dng` is *repaired into a derived record* rather than
    /// discarded, because the bytes are the durable fact.
    private func loadPendingRecords() -> [PendingRecord] {
        guard adapter.fileExists(at: supportDirectory) else { return [] }
        let root = supportDirectory.appendingPathComponent(LibraryStore.pendingDirectoryName, isDirectory: true)
        guard adapter.fileExists(at: root) else { return [] }
        let entries: [ScannedEntry]
        do {
            entries = try adapter.scan(root: root, maxEntries: 4_000, shouldSkipRelativePath: { _ in false },
                                       shouldDescendRelativeDirectory: { _ in true }, onProgress: nil)
        } catch {
            return []
        }
        var directories: Set<String> = []
        for entry in entries where entry.isDirectory {
            if !entry.relativePath.contains("/") { directories.insert(entry.relativePath) }
        }
        var results: [PendingRecord] = []
        for directoryName in directories.sorted() {
            guard let captureUUID = UUID(uuidString: directoryName) else { continue }
            let captureID = CaptureID(captureUUID)
            let directory = root.appendingPathComponent(directoryName, isDirectory: true)
            let pendingNames = ["source.dng", "source.heic", "source.jpg", "source.jpeg"]
            guard let pendingName = pendingNames.first(where: { adapter.fileExists(at: directory.appendingPathComponent($0)) }) else { continue }
            let sourceURL = directory.appendingPathComponent(pendingName, isDirectory: false)
            guard adapter.fileExists(at: sourceURL) else { continue }
            let transactionURL = directory.appendingPathComponent(LibraryStore.pendingTransactionName, isDirectory: false)
            var record = loadRecord(at: transactionURL, captureID: captureID)
            let sidecar = readPendingSidecar(
                at: directory.appendingPathComponent(LibraryStore.pendingSidecarName, isDirectory: false))
            let hash = trySynthesisedHash(sourceURL)
            if record == nil {
                guard let hash else { continue }
                // The journal is gone but the bytes are the durable fact. The
                // derived identity is deterministic (so `retry` finds the same
                // transaction again) and the destination date comes from the
                // recovery file's own modification time rather than "now".
                let stagedModification = entries.first {
                    $0.relativePath == "\(directoryName)/\(pendingName)"
                }?.modificationDate ?? wallClock.now()
                record = TransactionRecord(
                    schemaVersion: truongCamSupportedSchemaVersion,
                    transactionID: LibraryStore.stableUUID(seed: "truongcam-pending-transaction:" + captureID.description),
                    captureID: captureID.rawValue,
                    libraryID: sidecar?.libraryID ?? published.withLock { $0.manifest?.libraryID } ?? UUID(),
                    rootGeneration: published.withLock { $0.generation.value },
                    phase: .stagedInternal,
                    expectedByteCount: hash.byteCount,
                    expectedSHA256: hash.digest.hex,
                    relativeOriginalPath: sidecar?.relativeOriginalPath
                        ?? LibraryLayout.relativeOriginalPath(for: captureID,
                                                              capturedAt: stagedModification,
                                                              calendar: wallClock.calendar, format: LibraryStore.formatForOriginalPath(pendingName)),
                    createdAtUTC: stagedModification,
                    updatedAtUTC: wallClock.now(),
                    lastError: "The transaction journal was missing; a record was derived from the recovery bytes.")
            }
            guard var record else { continue }
            if let hash, record.phase == .reserved, hash.byteCount == record.expectedByteCount,
               !record.expectedSHA256.isEmpty, record.expectedSHA256 != String(repeating: "0", count: 64) {
                // Closed but not yet journalled: the bytes are the durable fact.
                record.phase = .stagedInternal
            }
            results.append(PendingRecord(
                record: record,
                relativePath: "\(LibraryStore.pendingDirectoryName)/\(directoryName)/\(pendingName)",
                sidecar: sidecar,
                digestFallback: hash?.digest ?? LibraryStore.zeroDigest))
        }
        return results
    }

    private func trySynthesisedHash(_ url: URL) -> HashAndByteCount? {
        do {
            let hash = try adapter.hashFile(at: url, chunkBytes: FileAdapterDefaults.hashChunkBytes)
            return hash.byteCount > 0 ? hash : nil
        } catch {
            return nil
        }
    }

    // MARK: - Internals: classification records

    private struct ClassifiedOriginal {
        var relativePath: String
        var captureID: CaptureID?
        var byteCount: Int64?
        var modificationDate: Date?
        var classification: SourceClassification
        var sidecar: SourceSidecar?
        var sequence: SourceSequenceLink?
        var rawDimensions: PixelDimensions?
        var capturedAtUTC: Date
        var capturedAtProvenance: CaptureTimeProvenance
        var isTruongCamCapture: Bool
    }

    static func captureID(fromFileName name: String) -> CaptureID? {
        let lower = name.lowercased()
        let fileExtension = (lower as NSString).pathExtension
        guard lower.hasPrefix(LibraryLayout.sourceFilePrefix.lowercased()),
              LibraryStore.isSupportedOriginalPath(lower) || fileExtension == "json" else { return nil }
        let start = lower.index(lower.startIndex, offsetBy: LibraryLayout.sourceFilePrefix.count)
        let end = lower.index(lower.endIndex, offsetBy: -(fileExtension.count + 1))
        guard start < end else { return nil }
        let uuidText = String(lower[start..<end])
        guard uuidText.count == MetadataBounds.maxUUIDStringLength, let uuid = UUID(uuidString: uuidText) else {
            return nil
        }
        return CaptureID(uuid)
    }

    /// A filename alone cannot give several readable paths one disposable row.
    /// Matching local sidecars retain capture authority; recovered copies use
    /// their own path identities consistently in browsing and exact export.
    private static func duplicateFilenameCaptureIDs(in paths: [String]) -> Set<CaptureID> {
        var seen = Set<CaptureID>(), duplicates = Set<CaptureID>()
        for path in paths where LibraryStore.isSupportedOriginalPath(path) {
            guard let id = captureID(fromFileName: (path as NSString).lastPathComponent) else { continue }
            if !seen.insert(id).inserted { duplicates.insert(id) }
        }
        return duplicates
    }

    private static func stableFallbackLibraryID(for url: URL) -> LibraryID {
        LibraryID(stableUUID(seed: url.standardizedFileURL.path))
    }

    /// Derived index identity for a browsable file whose own metadata carries no
    /// capture UUID. This is a *derived* identity for the disposable index and
    /// the gallery card; it never becomes an authoritative sidecar identity and
    /// is never written back into the library (schemas/README.md).
    nonisolated static func derivedIndexIdentity(for relativePath: String) -> CaptureID {
        CaptureID(stableUUID(seed: "truongcam-derived-identity:" + relativePath))
    }

    /// Deterministic UUID from a seed string (SHA-256 truncated to 16 bytes with
    /// RFC 4122 version/variant bits set).
    nonisolated static func stableUUID(seed: String) -> UUID {
        var hasher = SHA256()
        hasher.update(data: Data(seed.utf8))
        var bytes = Array(hasher.finalize().prefix(16))
        bytes[6] = (bytes[6] & 0x0F) | 0x40
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
                           bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
    }

    // MARK: - Internals: failures

    private func describe(_ error: Error) -> String {
        if let failure = error as? CaptureFailure { return failure.description }
        if let adapterError = error as? FileAdapterError { return adapterError.description }
        if let jsonError = error as? PortableJSONError { return jsonError.description }
        if let pathError = error as? PathSafetyError { return pathError.description }
        let ns = error as NSError
        return "\(ns.domain) \(ns.code): \(ns.localizedDescription)"
    }

    /// Maps any error onto the typed product failure vocabulary, keeping the
    /// retained-source status truthful.
    private func mapFailure(_ operation: String, error: Error, retained: RetainedSourceStatus) -> CaptureFailure {
        if let failure = error as? CaptureFailure {
            if failure.retainedSourceStatus == .none, retained != .none {
                return CaptureFailure(kind: failure.kind,
                                      operation: failure.operation,
                                      retainedSourceStatus: retained,
                                      nsErrorDomain: failure.nsErrorDomain,
                                      nsErrorCode: failure.nsErrorCode,
                                      underlyingDescription: failure.underlyingDescription)
            }
            return failure
        }
        if let adapterError = error as? FileAdapterError {
            let kind = adapterError.failureKind
            return CaptureFailure(kind: kind, operation: operation,
                                  retainedSourceStatus: retained,
                                  underlyingDescription: adapterError.description)
        }
        if let jsonError = error as? PortableJSONError {
            let kind: FailureKind
            switch jsonError {
            case .unsupportedMajorSchema:
                kind = .unsupportedSchema(detail: jsonError.description)
            default:
                kind = .metadataInvalid(detail: jsonError.description)
            }
            return CaptureFailure(kind: kind, operation: operation,
                                  retainedSourceStatus: retained,
                                  underlyingDescription: jsonError.description)
        }
        if let pathError = error as? PathSafetyError {
            return CaptureFailure(kind: .metadataInvalid(detail: pathError.description),
                                  operation: operation,
                                  retainedSourceStatus: retained,
                                  underlyingDescription: pathError.description)
        }
        let ns = error as NSError
        return CaptureFailure(kind: .providerIOFailed(detail: ns.localizedDescription),
                              operation: operation,
                              retainedSourceStatus: retained,
                              nsErrorDomain: ns.domain,
                              nsErrorCode: ns.code,
                              underlyingDescription: ns.localizedDescription)
    }
}
