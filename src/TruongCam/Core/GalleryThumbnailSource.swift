import Foundation

// The gallery's disposable preview source.
//
// REVIEW.md C10: the previous wiring handed the thumbnail service a bare root URL.
// Because the security-scope lease belongs to the store, releasing or switching the
// root could revoke access while a decode was in flight, and the store's
// `withRootReadAccess` helper was never called. The source now resolves the
// original INSIDE the store's balanced lease and hands the provider an absolute
// URL that is only read while that lease is held.

/// Which provider to ask for a card's preview, or why none is available.
enum GalleryThumbnailSource: Sendable {
    /// The store owns the scope; the provider decodes the resolved URL.
    case scoped(store: any LibraryStoring, thumbnails: any ThumbnailProviding)
    case unavailable(reason: String)

    /// Viewer providers may derive their internal fingerprint from identity.
    /// Include source revision here too, so a same-capture replacement cannot
    /// reuse a previous viewer memory entry after the model correctly reloads.
    var grantedRootURL: URL? {
        if case .scoped(let store, _) = self { return store.grantedRootURL }
        return nil
    }

    private static func cacheIdentity(for card: LibrarySourceCard, rootURL: URL?) -> String {
        "\(rootURL?.absoluteString ?? "-")|\(card.libraryID.description)|\(card.captureID.description)|\(card.modificationFingerprint ?? "-")"
    }

    func load(card: LibrarySourceCard, targetLongEdge: Int) async -> ThumbnailOutcome {
        switch self {
        case .scoped(let store, let thumbnails):
            let root = store.rootState
            let rootURL = store.grantedRootURL
            guard root.libraryID == card.libraryID else {
                return .unavailable(reason: "The library folder changed; reload this photo.")
            }
            do {
                // The decode runs SYNCHRONOUSLY inside the store's coordinated-read
                // accessor, with the security scope held (REVIEW.md F01).
                let outcome = try await store.withScopedOriginalRead(relativePath: card.relativeOriginalPath) { url in
                    guard store.rootState == root, store.grantedRootURL == rootURL else { throw CancellationError() }
                    return thumbnails.thumbnailSynchronously(
                        atAbsoluteURL: url,
                        identity: Self.cacheIdentity(for: card, rootURL: rootURL),
                        fingerprint: card.modificationFingerprint,
                        targetLongEdge: targetLongEdge)
                }
                guard !Task.isCancelled, store.rootState == root, store.grantedRootURL == rootURL else {
                    return .unavailable(reason: "The library folder changed; reload this photo.")
                }
                return outcome
            } catch let failure as CaptureFailure {
                return .unavailable(reason: failure.kind.userDescription)
            } catch {
                return .unavailable(reason: "\(error)")
            }
        case .unavailable(let reason):
            return .unavailable(reason: reason)
        }
    }

    func loadViewer(card: LibrarySourceCard, boundLongEdge: Int) async -> ThumbnailOutcome {
        switch self {
        case .scoped(let store, let thumbnails):
            let root = store.rootState
            let rootURL = store.grantedRootURL
            guard root.libraryID == card.libraryID else {
                return .unavailable(reason: "The library folder changed; reload this photo.")
            }
            do {
                let outcome = try await store.withScopedOriginalRead(relativePath: card.relativeOriginalPath) { url in
                    guard store.rootState == root, store.grantedRootURL == rootURL else { throw CancellationError() }
                    return thumbnails.viewerPreviewSynchronously(
                        atAbsoluteURL: url,
                        identity: Self.cacheIdentity(for: card, rootURL: rootURL),
                        boundLongEdge: boundLongEdge)
                }
                guard !Task.isCancelled, store.rootState == root, store.grantedRootURL == rootURL else {
                    return .unavailable(reason: "The library folder changed; reload this photo.")
                }
                return outcome
            } catch let failure as CaptureFailure {
                return .unavailable(reason: failure.kind.userDescription)
            } catch {
                return .unavailable(reason: "\(error)")
            }
        case .unavailable(let reason):
            return .unavailable(reason: reason)
        }
    }
}

extension LibraryStoring {
    /// Resolves a relative original and runs an ASYNC read inside a lease the
    /// reader OWNS for the whole operation.
    ///
    /// REVIEW.md S09: the previous version reopened the root's shared lease, so a
    /// concurrent `releaseRoot` could revoke the scope while the decode was still
    /// running. This takes a reader-owned, root-bound lease, refuses when the
    /// system denies access, and only releases after the body returns.
    /// Resolves an original with the store's own symlink-safe resolver and holds the
    /// reader's lease across the decode.
    ///
    /// REVIEW.md R06: the previous version resolved with a bare lexical
    /// `PathSafety.resolve` rather than the store's checked resolver, and it awaited
    /// an arbitrary async body. Both are now handled by the store:
    ///
    ///   * resolution and containment checks happen inside the store, which owns the
    ///     symlink defenses;
    ///   * the READ itself runs inside the store's coordinated-read accessor on its
    ///     I/O owner, with the scope held for the whole operation.
    ///
    /// The body is therefore synchronous by contract. Dispatching asynchronous work
    /// out of a coordination accessor and then reporting success is the failure mode
    /// CONTRACTS.md warns about, so a caller needing an async decode must copy bytes
    /// out inside `body` and decode outside it.
    /// Reads an original with the store owning resolution, coordination and the
    /// lease, then hands the MATERIALIZED result to an async caller.
    ///
    /// The read body itself must be synchronous and complete inside the coordinated
    /// accessor (REVIEW.md F01). A caller that needs to decode asynchronously reads
    /// its bytes inside `body` — bounded, via the provider — and decodes the result
    /// afterwards, outside the accessor.
    func withScopedOriginalRead<T: Sendable>(
        relativePath: String,
        _ body: @escaping @Sendable (URL) throws -> T
    ) async throws -> T {
        try await readOriginal(relativePath: relativePath, body)
    }
}
