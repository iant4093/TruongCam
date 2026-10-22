import Foundation

/// An opaque position in a reconciled source listing.
///
/// Deliberately opaque and `Hashable` so a caller can only advance by passing back
/// what it was given, which is what prevents a paging loop from silently
/// re-reading its first page.
struct ScanCursor: Hashable, Sendable {
    let offset: Int
    /// The library generation this cursor belongs to. A rebuild that crosses a
    /// generation boundary must restart rather than mix records from two libraries.
    let generation: RootGeneration
}

/// One page of reconciled source records.
struct ReconciledCardPage: Sendable {
    let cards: [LibrarySourceCard]
    /// Nil when this page is the last one.
    let nextCursor: ScanCursor?
    /// Total records the scan believes exist, for progress reporting.
    let totalCount: Int

    var isLastPage: Bool { nextCursor == nil }

    static let empty = ReconciledCardPage(cards: [], nextCursor: nil, totalCount: 0)
}
