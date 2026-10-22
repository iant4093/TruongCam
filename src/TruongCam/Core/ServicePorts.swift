import Foundation

// CONTRACTS.md "Semantic interfaces": owner/command/value table.
//
// These protocols are the frozen seams between services. They exist so each
// service can be exercised with a fake without a device, and so independent
// implementers can work against a stable boundary.

// MARK: - Camera fake boundary

/// The subset of camera behaviour the capture/sequence layer depends on. A fake
/// implementation drives every state machine without AVFoundation.
protocol CameraControlSurface: Sendable {
    var lifecycle: CameraLifecycle { get }
    var capabilitySnapshot: CameraCapabilitySnapshot { get }
    /// Current applied/observed controls, if the session has produced any.
    func currentControlReadback() -> AppliedControlSnapshot?
    /// True when a new native photo request may be admitted.
    func canAdmitCapture() -> Bool
}

// MARK: - Storage boundary

/// Result of selecting or reconnecting a library root.
enum RootSelectionOutcome: Hashable, Sendable {
    /// A new, empty root was verified writable and initialized.
    case initialized(libraryID: LibraryID, generation: RootGeneration)
    /// An existing TruongCam library was recognized and opened.
    case opened(libraryID: LibraryID, generation: RootGeneration, manifest: LibraryManifest)
    /// The root contains a newer major schema: browsable, never written.
    case readOnlyNewerSchema(found: Int, supported: Int)
    /// The root holds a conflicting or foreign manifest.
    case conflictingManifest(reason: String)
    /// The user chose a location inside this app's own container.
    case rejectedOwnContainer
    /// A known cloud/iCloud location was rejected under the local-only policy.
    case rejectedCloudLocation(reason: String)
    /// Locality could not be verified and the authorized local-destination flow
    /// has not confirmed this folder, so it must not become a writable local-only
    /// library (REVIEW.md S08).
    case localityUnconfirmed(reason: String)
    /// The provider could not be written to.
    case unavailable(reason: String)
}

/// Summary of a reconciliation pass over a root.
struct ReconciledLibrary: Hashable, Sendable {
    let libraryID: LibraryID
    let generation: RootGeneration
    let verifiedOriginalCount: Int
    let recoveredRAWCount: Int
    let missingOriginalCount: Int
    let conflictCount: Int
    let pendingCount: Int
    let sequences: [SequenceSummary]
    let issues: [String]
}

/// Minimal sequence description derived from files, used by the library.
struct SequenceSummary: Hashable, Sendable {
    let sequenceID: SequenceID
    let kind: SequenceKind
    let plannedCount: Int
    let committedCount: Int
    let missingIndices: [Int]
    let failedIndices: [Int]
    let skippedDeadlineCount: Int
    let status: SequenceStatus
    let startedAtUTC: Date

    var isComplete: Bool {
        status == .complete && committedCount == plannedCount
            && missingIndices.isEmpty && failedIndices.isEmpty
    }

    /// Human label that never overstates an interrupted run.
    var statusLabel: String {
        switch status {
        case .running: return "Interrupted (was running)"
        case .complete: return isComplete ? "Complete" : "Incomplete"
        case .cancelled: return "Cancelled"
        case .interrupted: return "Interrupted"
        case .failed: return "Failed"
        }
    }
}

/// Publishes the currently granted root URL so read-only consumers such as the
/// thumbnail service can resolve a relative original path.
///
/// The security-scope lease stays owned by the store; consumers must already be
/// inside a coordinated read that the store opened.
protocol LibraryRootLocating: Sendable {
    var grantedRootURL: URL? { get }
}

/// Storage operations owned by LibraryStore.
/// The export operations `ExportPresenter` owns and depends on.
///
/// REVIEW.md J07: depending on the whole `LibraryStoring` forced any test of the
/// real presenter to fake every storage responsibility. This port states exactly what
/// the export owner uses, so its lifetime/consent logic can be executed directly.
protocol ExportPreparing: Sendable {
    func prepareOriginalExport(
        sourceIDs: [CaptureID],
        includeSidecars: Bool
    ) async throws -> ExportSession
    func preparePendingOriginalExport(
        transactionIDs: [TransactionID],
        includeSidecars: Bool
    ) async throws -> ExportSession
    /// Removes exactly ONE prepared session's disposable copies.
    func discardExport(sessionID: UUID) async
    /// Removes disposable copies left over from an earlier launch.
    func clearAbandonedExports() async
}

protocol LibraryStoring: LibraryRootLocating, ExportPreparing {
    func trashOriginal(card: LibrarySourceCard, generation: RootGeneration) async throws -> PhotoTrashRecord
    func trashedOriginals() async throws -> [PhotoTrashRecord]
    func permanentlyDeleteOriginal(record: PhotoTrashRecord, generation: RootGeneration) async throws
    func restoreOriginal(trashID: UUID, libraryID: LibraryID, generation: RootGeneration) async throws
    /// Explicit user command; moves only validated legacy app metadata, never
    /// DNGs. Verified destination copies precede removal of their legacy records.
    func organizeMetadata() async throws -> Int
    var rootState: LibraryRootState { get }
    var currentManifest: LibraryManifest? { get }
    var selectedRootDescription: String? { get }

    /// Selects (or creates) a root from a user-granted directory URL.
    /// Selects a library root.
    ///
    /// `confirmedLocalDestination` is the user's decision about THIS specific URL,
    /// taken in the authorized local-destination flow. REVIEW.md R07: the previous
    /// mechanism was an initializer-wide flag, which would have accepted any unknown
    /// root rather than the one the user actually confirmed.
    func selectRoot(
        from grantedURL: URL,
        confirmedLocalDestination: Bool
    ) async -> RootSelectionOutcome
    /// Reconnects a previously selected root from its retained bookmark.
    func reconnectStoredRoot() async -> RootSelectionOutcome
    /// Releases the retained grant and forgets the bookmark.
    func releaseRoot() async

    /// Full reconciliation pass: scan, classify, recover.
    func reconcile(onProgress: (@Sendable (ScanProgress) -> Void)?) async throws -> ReconciledLibrary

    /// Stages exact source bytes into internal recovery storage and returns the
    /// handle. Durable on return, or throws.
    func stageSource(bytes: Data, metadata: SourceCaptureMetadata) async throws -> StagedSourceHandle

    /// Publishes a staged source into the library root with verification.
    func commit(handle: StagedSourceHandle) async throws -> CommitReceipt

    /// Retries persistence of an already-staged source under its own identity.
    func retry(transactionID: TransactionID) async throws -> CommitReceipt

    /// Pending originals in internal recovery storage. Not reinstall-safe.
    func pendingOriginals() async -> [PendingOriginal]

    /// Exports exact bytes for the given originals into temporary app storage.

    /// Prepares an export of PENDING originals directly from durable internal
    /// recovery storage. This must work even when the external root is
    /// unavailable, because that is exactly when the recovery action is needed
    /// (REVIEW.md C07).
    func preparePendingOriginalExport(
        transactionIDs: [TransactionID],
        includeSidecars: Bool
    ) async throws -> ExportSession

    /// Removes the disposable copies of exactly ONE export session.
    ///
    /// REVIEW.md J07: cancelling or replacing session A must not touch session B's
    /// copies, and the global abandoned-export sweep is reserved for a safe launch
    /// boundary rather than a completion.

    /// Enumerates EVERY reconciled source record for a rebuild, not just the
    /// extant DNGs.
    ///
    /// REVIEW.md S10: `browsableSourceCards` only walks files that still exist, so
    /// a reconciled "missing original" never reached the rebuilt index and
    /// vanished from the gallery instead of offering reconnect/recovery. This
    /// returns extant sources AND `missingOriginal` records derived from their
    /// sidecars, so counts stay truthful and partial sequences remain visible.
    ///
    /// **Paged, not "first N".** A caller that cannot advance cannot finish: an
    /// earlier version of the rebuild loop re-read the same first page and
    /// re-upserted the same records indefinitely. `after` is an opaque cursor from
    /// the previous page; nil starts at the beginning.
    func reconciledSourceCards(after cursor: ScanCursor?, limit: Int) async throws -> ReconciledCardPage

    /// The complete reconciled list, deterministically ordered. Used for whole-set
    /// classification such as recovered-file issues.
    func allReconciledSourceCards() async throws -> [LibrarySourceCard]

    /// Enumerates the browsable source cards currently present under the root.
    ///
    /// Used to rebuild the disposable index after a reconnect or a fresh install
    /// (REVIEW.md C06). It reads metadata and file identity only; it never decodes
    /// or hashes an original, and it never mutates the library.
    func browsableSourceCards(limit: Int) async throws -> [LibrarySourceCard]

    /// Writes or replaces a sequence document under coordination.
    func writeSequenceDocument(_ document: SequenceDocument) async throws

    /// Reads a sequence document.
    func readSequenceDocument(_ sequenceID: SequenceID) async throws -> SequenceDocument

    /// Absolute URL for a source's original, or nil when unavailable.
    ///
    /// The URL is only valid while a scope lease is open, so callers must not
    /// retain it for later I/O.
    func originalURL(for captureID: CaptureID, relativePath: String) -> URL?

    /// Runs a synchronous read-only operation inside a balanced security-scope
    /// lease. Disposable consumers use this instead of holding their own lease, so
    /// exactly one owner (the store) makes balanced
    /// `startAccessingSecurityScopedResource` calls.
    func withRootReadAccess<T: Sendable>(
        _ body: @Sendable (URL) throws -> T
    ) async throws -> T

    /// Resolves an original and runs a SYNCHRONOUS read inside one owned lease and
    /// one coordinated-read accessor.
    ///
    /// REVIEW.md R06: resolution must use the store's symlink defenses, the scope
    /// must be held through the actual read, and the work must run inside a proper
    /// I/O accessor rather than being dispatched out of one. `body` is therefore
    /// synchronous; it receives the resolved, contained URL and must complete its
    /// read before returning. A caller that needs to decode asynchronously copies the
    /// bytes inside `body` and decodes afterwards.
    /// Runs a SYNCHRONOUS read body inside one owned lease and one coordinated-read
    /// accessor, on the store's I/O owner. This is the real read boundary: the body
    /// completes before the accessor returns, and the scope is held throughout.
    func readOriginal<T: Sendable>(
        relativePath: String,
        _ body: @escaping @Sendable (URL) throws -> T
    ) async throws -> T

    /// Opens a lease that a reader OWNS for the lifetime of its own operation.
    ///
    /// REVIEW.md S09: the previous `(url, opened)` pair let a reader reuse the
    /// root's long-lived selection lease, so `releaseRoot` revoked the scope while
    /// the reader was still decoding, and `closeScopedRoot` closed whatever grant
    /// happened to be current rather than the one it opened.
    ///
    /// The token is bound to the exact root, grant, library and generation it was
    /// opened against, and is balanced only against that grant.
    func openScopedRead() async throws -> ScopedReadLease

    /// Releases a lease previously returned by `openScopedRead`.
    func closeScopedRead(_ lease: ScopedReadLease)
}

/// A retained export session. The share sheet must keep this alive until it is
/// dismissed; only then may the temporary copies be removed.
struct ExportSession: Hashable, Sendable {
    let sessionID: UUID
    let directoryRelativePath: String
    let fileURLs: [URL]
    let includedSidecars: Bool
    let missingItems: [String]
    let totalByteCount: Int64
    let preparedAtUTC: Date
}

// MARK: - Index boundary

/// A page of library metadata cards. Value-only; never original bytes.
struct LibraryPage: Hashable, Sendable {
    let cards: [LibraryCard]
    let nextCursor: LibraryCursor?
    let libraryGeneration: RootGeneration
    /// The database snapshot's identity, including an empty page. Source cards
    /// alone cannot identify an empty or coverless former-root result.
    let indexedLibraryID: LibraryID?
    /// Production reads page/count in one index actor turn. Legacy/synthetic
    /// ports may omit the count and retain the separate metadata query.
    let totalCommittedOriginalCount: Int?
    /// Actual newest individual original, independently of a sequence's cover.
    /// Production resolves this bounded metadata read in the first-page snapshot.
    let newestOriginal: LibrarySourceCard?

    init(cards: [LibraryCard], nextCursor: LibraryCursor?, libraryGeneration: RootGeneration,
         indexedLibraryID: LibraryID? = nil, totalCommittedOriginalCount: Int? = nil,
         newestOriginal: LibrarySourceCard? = nil) {
        self.cards = cards
        self.nextCursor = nextCursor
        self.libraryGeneration = libraryGeneration
        let identities = Set(cards.compactMap { card -> LibraryID? in
            switch card.kind {
            case .single(let source): return source.libraryID
            case .sequenceCover(_, let cover): return cover?.libraryID
            }
        })
        self.indexedLibraryID = indexedLibraryID ?? (identities.count == 1 ? identities.first : nil)
        self.totalCommittedOriginalCount = totalCommittedOriginalCount
        self.newestOriginal = newestOriginal
    }
}

struct LibraryCursor: Hashable, Sendable {
    let capturedAtUTC: Date
    let tieBreaker: String
    let libraryGeneration: RootGeneration
    /// Disposable index content identity. A root generation alone cannot detect
    /// a same-folder rebuild or a changed sequence cover between page reads.
    let indexRevision: UUID?

    init(capturedAtUTC: Date, tieBreaker: String, libraryGeneration: RootGeneration,
         indexRevision: UUID? = nil) {
        self.capturedAtUTC = capturedAtUTC
        self.tieBreaker = tieBreaker
        self.libraryGeneration = libraryGeneration
        self.indexRevision = indexRevision
    }
}

enum LibraryIndexPagingError: Error {
    /// The metadata changed; restart at the first page rather than combining
    /// records from two index contents. This is not a provider/file failure.
    case expiredCursor
}

/// One browsable entry. A day group member may be a single source or a
/// sequence cover.
struct LibraryCard: Hashable, Sendable, Identifiable {
    enum Kind: Hashable, Sendable {
        case single(LibrarySourceCard)
        case sequenceCover(SequenceSummary, cover: LibrarySourceCard?)
    }

    var id: String
    let kind: Kind
    let capturedAtUTC: Date
    /// Number of individual committed originals represented by this card.
    let representedOriginalCount: Int
}

struct LibrarySourceCard: Hashable, Sendable, Identifiable {
    var id: String { captureID.description }
    let captureID: CaptureID
    let libraryID: LibraryID
    let relativeOriginalPath: String
    let capturedAtUTC: Date
    let capturedAtProvenance: CaptureTimeProvenance
    let availability: SourceAvailability
    let classification: SourceClassification
    let rawDimensions: PixelDimensions?
    let byteCount: Int64?
    let sequenceID: SequenceID?
    let sequenceIndex: Int?
    let sequenceKind: SequenceKind?
    let isTruongCamCapture: Bool
    /// Fingerprint used to invalidate thumbnails; disposable.
    let modificationFingerprint: String?
}

/// Derived, rebuildable index boundary.
protocol LibraryIndexing: Sendable {
    func reset(libraryID: LibraryID, generation: RootGeneration) async throws
    func ingest(_ receipts: [CommitReceipt]) async throws
    func upsert(scanned: [LibrarySourceCard]) async throws
    func updateSequences(_ summaries: [SequenceSummary]) async throws
    func markUnavailable(captureID: CaptureID, reason: String) async throws
    func firstPage(size: Int) async throws -> LibraryPage
    func page(after cursor: LibraryCursor, size: Int) async throws -> LibraryPage
    func detail(captureID: CaptureID) async throws -> LibrarySourceCard?
    func sources(inSequence sequenceID: SequenceID) async throws -> [LibrarySourceCard]
    func dayGroupCounts() async throws -> [DayGroupCount]
    func totalCommittedOriginalCount() async throws -> Int
}

struct DayGroupCount: Hashable, Sendable {
    /// Local calendar day key, "yyyy-MM-dd".
    let dayKey: String
    let originalCount: Int
    let cardCount: Int
}

// MARK: - Thumbnail boundary

enum ThumbnailOutcome: Sendable {
    case image(rgbaBytes: [UInt8], width: Int, height: Int, pixelFingerprint: String)
    case unavailable(reason: String)
    case needsFullDecode(reason: String)
}

/// Disposable preview derivation. Never writes to an original.
protocol ThumbnailProviding: Sendable {
    /// Embedded DNG preview, or a bounded native decode fallback.
    func thumbnail(identity: String,
                   relativePath: String,
                   fingerprint: String?,
                   targetLongEdge: Int) async -> ThumbnailOutcome

    /// Bounded display decode for the detail viewer.
    func viewerPreview(identity: String,
                       relativePath: String,
                       boundLongEdge: Int) async -> ThumbnailOutcome

    /// Same as `thumbnail`, but for an already-resolved absolute URL.
    ///
    /// Used by the gallery, which resolves the path INSIDE the store's balanced
    /// security-scope lease. Passing a bare root URL instead let a root release
    /// invalidate the path during decode (REVIEW.md C10).
    func thumbnail(atAbsoluteURL url: URL,
                   identity: String,
                   fingerprint: String?,
                   targetLongEdge: Int) async -> ThumbnailOutcome

    /// Same as `viewerPreview`, for an already-resolved absolute URL.
    func viewerPreview(atAbsoluteURL url: URL,
                       identity: String,
                       boundLongEdge: Int) async -> ThumbnailOutcome

    /// SYNCHRONOUS bounded decode for an already-resolved URL.
    ///
    /// REVIEW.md F01: the coordinated-read accessor is synchronous, so the decode it
    /// guards must be too. Callers on the read boundary use this; the async variants
    /// remain for callers that already hold a scope.
    func thumbnailSynchronously(atAbsoluteURL url: URL,
                                identity: String,
                                fingerprint: String?,
                                targetLongEdge: Int) -> ThumbnailOutcome
    func viewerPreviewSynchronously(atAbsoluteURL url: URL,
                                    identity: String,
                                    boundLongEdge: Int) -> ThumbnailOutcome

    func clearMemoryCache() async
}

// MARK: - Analysis boundary

/// The geometry the analysis pipeline needs for one sample.
struct AnalysisRequest: Hashable, Sendable {
    let configurationGeneration: ConfigurationGeneration
    /// The preview layout this request applies to. Nil means the UI wants this
    /// demand but the layout is not known yet; the request is completed when
    /// geometry first arrives rather than being discarded.
    let geometry: PreviewGeometrySnapshot?
    let demand: AnalysisDemand
    let peakingThreshold: Double
    let zebraThreshold: Double
    let loupeCenter: NormalizedDevicePoint
    let loupeMagnification: Double
}

/// One downsampled luminance plane handed to the analysis pipeline.
struct LuminanceSample: Sendable {
    let width: Int
    let height: Int
    /// One byte per pixel, row-major, padding already excluded.
    let luma: [UInt8]
    /// Code-value range actually observed in the source format.
    let range: PreviewCodeRange
    let configurationGeneration: ConfigurationGeneration
    let geometryGeneration: UInt64
    let capturedAtUTC: Date
    var rgbHistogram: PreviewRGBHistogram? = nil
    /// Optional bounded color crop from owned native preview planes, before
    /// small luma analysis. Never captured RAW or source-file pixels.
    var colorLoupe: PreviewColorLoupeSample? = nil
    /// Requested color must fail visibly rather than silently show grayscale.
    var requiresColorLoupe = false
}

/// Nominal code-value endpoints of the source preview format.
enum PreviewCodeRange: Hashable, Sendable {
    /// Planar full range: nominal 0...255.
    case full
    /// Video range: nominal luma 16...235.
    case video

    var nominalBlack: Double { self == .video ? 16 : 0 }
    var nominalWhite: Double { self == .video ? 235 : 255 }
}

/// Pure image-analysis math shared by the live pipeline and the tests.
enum PreviewAnalysisMath {
    static let histogramBinCount = 256
}

extension LibraryStoring {
    func trashOriginal(card: LibrarySourceCard, generation: RootGeneration) async throws -> PhotoTrashRecord {
        throw CaptureFailure(kind: .unsupportedCapability(detail: "Trash is unavailable."), operation: "trashOriginal")
    }
    func permanentlyDeleteOriginal(record: PhotoTrashRecord, generation: RootGeneration) async throws {
        throw CaptureFailure(kind: .unsupportedCapability(detail: "Permanent deletion is unavailable."), operation: "permanentlyDeleteOriginal")
    }
    func trashedOriginals() async throws -> [PhotoTrashRecord] { [] }
    func restoreOriginal(trashID: UUID, libraryID: LibraryID, generation: RootGeneration) async throws {
        throw CaptureFailure(kind: .unsupportedCapability(detail: "Restore is unavailable."), operation: "restoreOriginal")
    }

    func organizeMetadata() async throws -> Int {
        throw CaptureFailure(kind: .unsupportedCapability(detail: "Metadata organization is unavailable for this storage service."),
                             operation: "organizeMetadata")
    }
}

/// UI progress follows verified file outcomes, never scheduled work. The root
/// stamp prevents a retained task from painting a different library's progress.
struct PhotoMutationProgress: Equatable, Sendable, Identifiable {
    enum Kind: String, Sendable { case moveToTrash, recover, permanentlyDelete }
    let id = UUID()
    let kind: Kind
    let libraryID: LibraryID
    let generation: RootGeneration
    let root: URL?
    let total: Int
    var completedIDs: Set<UUID> = []
    var completed: Int { completedIDs.count }
    var isRefreshing = false
    var stopRequested = false
    var title: String {
        if isRefreshing { return "Updating library…" }
        if stopRequested { return "Finishing current photo…" }
        switch kind {
        case .moveToTrash: return "Moving to Recently Deleted…"
        case .recover: return "Recovering photos…"
        case .permanentlyDelete: return "Deleting photos…"
        }
    }
    func matches(state: LibraryRootState, root: URL?) -> Bool {
        state == .writable(libraryID: libraryID, generation: generation) && self.root == root
    }
}

/// Local-folder recovery record. metadata/trash is retained with the library and
/// never auto-purged. The original and sidecar bytes are moved without rewriting.
struct PhotoTrashRecord: Codable, Hashable, Sendable, Identifiable {
    let id: UUID
    let libraryID: LibraryID
    let captureID: CaptureID
    let originalPath: String
    let metadataPath: String
    let originalSHA256: String
    let metadataSHA256: String
    let deletedAtUTC: Date
    var purgeStartedAtUTC: Date? = nil
    var previewFingerprint: String? = nil
    var directory: String { "metadata/trash/" + id.uuidString.lowercased() }
    var storedOriginalPath: String { directory + "/original." + (originalPath as NSString).pathExtension }
    func identifiesSameSource(as other: PhotoTrashRecord) -> Bool {
        id == other.id && libraryID == other.libraryID && captureID == other.captureID
            && originalPath == other.originalPath && metadataPath == other.metadataPath
            && originalSHA256 == other.originalSHA256 && metadataSHA256 == other.metadataSHA256
            && deletedAtUTC == other.deletedAtUTC
    }
    var previewCard: LibrarySourceCard {
        LibrarySourceCard(captureID: captureID, libraryID: libraryID, relativeOriginalPath: storedOriginalPath,
            capturedAtUTC: deletedAtUTC, capturedAtProvenance: .requestTimestamp,
            availability: purgeStartedAtUTC == nil ? .local : .missing, classification: .verifiedOriginal,
            rawDimensions: nil, byteCount: nil, sequenceID: nil, sequenceIndex: nil, sequenceKind: nil,
            isTruongCamCapture: false, modificationFingerprint: originalSHA256 + (previewFingerprint ?? ""))
    }
}


/// Durable user-confirmed deletion intent. It remains discoverable even if a
/// provider fails after removing record.json, so a later explicit retry can
/// finish only these exact owned files. No directory is recursively removed.
struct PhotoTrashPurgeIntent: Codable, Sendable {
    let record: PhotoTrashRecord
    let confirmedAtUTC: Date
}


/// After deletion, prefer the following photo; deleting the final item steps
/// back. Empty collections stay in an explicit empty viewer until Back is tapped.
enum ViewerDeletionNavigation {
    static func successor(deleting id: CaptureID, ordered: [CaptureID]) -> CaptureID? {
        guard let index = ordered.firstIndex(of: id) else { return ordered.first }
        if index + 1 < ordered.count { return ordered[index + 1] }
        return index > 0 ? ordered[index - 1] : nil
    }
}
