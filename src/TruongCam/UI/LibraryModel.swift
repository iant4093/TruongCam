import Foundation
import Observation

/// One date group in the gallery. `originalCount` counts individual committed
/// originals, which may be more than the number of visible tiles when a sequence
/// is represented by a single cover.
struct LibraryDayGroup: Identifiable, Hashable, Sendable {
    var id: String { dayKey }
    let dayKey: String
    let displayTitle: String
    let originalCount: Int
    let cards: [LibraryCard]
}

/// Browsing state. Values only: the library never holds original bytes.
@MainActor
@Observable
final class LibraryViewModel {
    private(set) var dayGroups: [LibraryDayGroup] = []
    private(set) var individualOriginalCount = 0
    private(set) var lastReconcileIssue: String?
    private(set) var isLoading = false
    private(set) var selectedSequenceID: SequenceID?
    private(set) var sequenceCards: [LibrarySourceCard] = []

    private let index: (any LibraryIndexing)?
    private let store: (any LibraryStoring)?
    /// Disposable preview source for the grid. Never original bytes.
    var thumbnailSource: GalleryThumbnailSource = .unavailable(reason: "Photo previews are unavailable.")
    private var cursor: LibraryCursor?
    /// True while more pages remain. REVIEW.md S10: `loadNextPage` had no caller,
    /// so only the first page was ever browsable.
    private(set) var hasMorePages = false
    /// How many cursor pages have been loaded. Used as the pagination trigger's
    /// identity so it re-arms for each new page (REVIEW.md R09).
    private(set) var loadedPageCount = 0
    /// Cheap view task identity; metadata arrays are not compared every gesture.
    private(set) var contentRevision: UInt64 = 0
    /// A first-page replacement revokes cached sequence expansions; appending
    /// pages from one index revision can reuse unchanged covers.
    private(set) var reloadRevision: UInt64 = 0
    /// How many source records are currently listed.
    var loadedSourceCount: Int { dayGroups.reduce(0) { $0 + $1.cards.count } }
    /// True when the rebuild stopped at its bound instead of scanning everything.
    private(set) var scanWasTruncated = false

    /// Set when a page failed, so the UI can offer a retry instead of silently
    /// showing a short library.
    private(set) var pageLoadFailure: String?
    private let pageSize = MetadataBounds.maxIndexPageSize
    private struct ReadRoot: Equatable {
        let state: LibraryRootState?
        let url: URL?
    }
    private var readRoot: ReadRoot { ReadRoot(state: store?.rootState, url: store?.grantedRootURL) }
    private var browsingRoot: ReadRoot?
    private var retainedRootURL: URL?
    private var retainedLibraryID: LibraryID?
    private var canReadIndex: Bool {
        guard let store else { return true }
        switch store.rootState {
        case .writable: return true
        case .readOnly(_, let libraryID): return libraryID != nil
        case .unselected, .resolving, .unavailable, .reconciling: return false
        }
    }
    private var pageOperation = UUID()
    private struct SequenceRead: Equatable {
        let id: SequenceID
        let root: ReadRoot
    }
    private var sequenceRead: SequenceRead?
    private var sequenceOperation = UUID()
    private var sequenceTask: Task<[LibrarySourceCard]?, Never>?
    private var newestOriginal: LibrarySourceCard?
    private var newestOriginalRoot: ReadRoot?

    /// Metadata only. A folder release/replacement immediately hides the former
    /// candidate, even before its gallery reload finishes.
    var newestThumbnailSource: LibrarySourceCard? {
        guard canReadIndex, newestOriginalRoot == readRoot,
              let newestOriginal,
              readRoot.state?.libraryID == nil || readRoot.state?.libraryID == newestOriginal.libraryID else { return nil }
        return newestOriginal
    }

    /// A released/replaced grant cannot keep a former root's metadata visible.
    /// The app calls this at explicit release; request entry also detects roots.
    func invalidateRoot() {
        contentRevision &+= 1; reloadRevision &+= 1
        pageOperation = UUID(); isLoading = false
        dayGroups = []; individualOriginalCount = 0; cursor = nil
        hasMorePages = false; loadedPageCount = 0; pageLoadFailure = nil
        lastReconcileIssue = nil; scanWasTruncated = false
        sequenceOperation = UUID(); sequenceTask?.cancel(); sequenceTask = nil
        sequenceRead = nil; selectedSequenceID = nil; sequenceCards = []
        newestOriginal = nil; newestOriginalRoot = nil
        browsingRoot = readRoot
        retainedRootURL = browsingRoot?.url
        retainedLibraryID = browsingRoot?.state?.libraryID
    }

    private func prepareReadRoot() -> ReadRoot {
        let current = readRoot
        if browsingRoot != current {
            let differentURL = current.url.map { retainedRootURL != nil && retainedRootURL != $0 } ?? false
            let differentID = current.state?.libraryID.map { retainedLibraryID != nil && retainedLibraryID != $0 } ?? false
            if current.state == .unselected || differentURL || differentID { invalidateRoot() }
            else {
                // Inaccessible metadata remains browsable as cached data. Loss
                // of access still revokes every in-flight publication owner.
                pageOperation = UUID(); isLoading = false
                sequenceOperation = UUID(); sequenceTask?.cancel(); sequenceTask = nil; sequenceRead = nil
                browsingRoot = current
                if let url = current.url { retainedRootURL = url }
                if let id = current.state?.libraryID { retainedLibraryID = id }
            }
        }
        return current
    }

    private func ownsPage(_ operation: UUID, root: ReadRoot) -> Bool {
        !Task.isCancelled && pageOperation == operation && readRoot == root
    }

    /// An index read can start after the folder changes but before its rebuild
    /// resets the disposable index. Request ownership alone does not identify
    /// the returned records; reject a former root's page at publication too.
    private func pageMatchesRoot(_ page: LibraryPage, root: ReadRoot) -> Bool {
        if let generation = root.state?.generation,
           page.libraryGeneration != generation { return false }
        guard let libraryID = root.state?.libraryID else { return true }
        guard page.indexedLibraryID == libraryID else { return false }
        guard page.newestOriginal.map({ $0.libraryID == libraryID }) ?? true else { return false }
        return page.cards.allSatisfy { card in
            switch card.kind {
            case .single(let source): return source.libraryID == libraryID
            case .sequenceCover(_, let cover): return cover.map { $0.libraryID == libraryID } ?? true
            }
        }
    }

    init(index: (any LibraryIndexing)?, store: (any LibraryStoring)?) {
        self.index = index
        self.store = store
    }

    var firstThumbnailSources: [LibrarySourceCard] {
        // Warm the camera shortcut first at the grid's existing 256-pixel cache
        // size. Its separate member may differ from a grouped sequence cover.
        var sources = newestThumbnailSource.map { [$0] } ?? []
        var seen = Set(sources.map(\.captureID))
        for group in dayGroups {
            for card in group.cards {
                let source: LibrarySourceCard?
                switch card.kind {
                case .single(let value): source = value
                case .sequenceCover(_, let value): source = value
                }
                if let source, seen.insert(source.captureID).inserted { sources.append(source) }
                if sources.count == 9 { return sources }
            }
        }
        return sources
    }

    /// Real local originals only, using the same lease/cache path as grid cells.
    /// A cancelled/new-root request cannot publish or queue the rest of a page.
    func prepareFirstThumbnails() async {
        let source = thumbnailSource, root = source.grantedRootURL, state = store?.rootState
        for card in firstThumbnailSources {
            guard !Task.isCancelled, thumbnailSource.grantedRootURL == root, store?.rootState == state else { return }
            _ = await source.load(card: card, targetLongEdge: 256)
        }
    }

    /// Loads the first page. Pagination is cursor-based and never decodes or
    /// hashes an original.
    func loadFirstPage() async {
        guard let index, !Task.isCancelled else { return }
        let root = prepareReadRoot()
        guard canReadIndex else { return }
        let operation = UUID(); pageOperation = operation
        #if DEBUG
        let began = ProcessInfo.processInfo.systemUptime
        defer { print("TruongCam timing library-first-page=\(Int((ProcessInfo.processInfo.systemUptime-began)*1000))ms cards=\(loadedSourceCount) mainActor=true") }
        #endif
        isLoading = true
        defer { if pageOperation == operation { isLoading = false } }
        do {
            let page = try await index.firstPage(size: pageSize)
            guard ownsPage(operation, root: root), pageMatchesRoot(page, root: root) else { return }
            let total: Int
            if let snapshotCount = page.totalCommittedOriginalCount { total = snapshotCount }
            else { total = try await index.totalCommittedOriginalCount() }
            guard ownsPage(operation, root: root), pageMatchesRoot(page, root: root) else { return }
            guard total >= 0 else { return }
            // Publish the page/count together; a newer reload cannot be partly
            // replaced while the old count query is still awaiting its actor.
            cursor = page.nextCursor
            hasMorePages = page.nextCursor != nil
            pageLoadFailure = nil
            loadedPageCount = 1
            rebuildGroups(from: page.cards)
            individualOriginalCount = total
            newestOriginal = page.newestOriginal
            newestOriginalRoot = root
        } catch {
            guard ownsPage(operation, root: root) else { return }
            newestOriginal = nil; newestOriginalRoot = nil
            AppDiagnostics.record(error, operation: "library.firstPage")
            lastReconcileIssue = "Couldn’t load your photos. Reconnect your library folder and try again."
        }
    }

    func loadNextPage() async {
        guard let index, !Task.isCancelled else { return }
        let root = prepareReadRoot()
        guard canReadIndex, let cursor, !isLoading else { return }
        let operation = UUID(); pageOperation = operation
        isLoading = true
        defer { if pageOperation == operation { isLoading = false } }
        do {
            let page = try await index.page(after: cursor, size: pageSize)
            guard ownsPage(operation, root: root), pageMatchesRoot(page, root: root) else { return }
            self.cursor = page.nextCursor
            hasMorePages = page.nextCursor != nil
            pageLoadFailure = nil
            loadedPageCount += 1
            append(cards: page.cards)
        } catch LibraryIndexPagingError.expiredCursor {
            guard ownsPage(operation, root: root) else { return }
            // A rebuilt/updated disposable index is ordinary metadata churn.
            // Replace the old page set; do not append into its former cursor or
            // present a file-provider error for an index-only revision change.
            await loadFirstPage()
        } catch {
            guard ownsPage(operation, root: root) else { return }
            AppDiagnostics.record(error, operation: "library.nextPage")
            lastReconcileIssue = "Your photos couldn’t be loaded. Refreshing the library."
            pageLoadFailure = "Couldn’t load more photos. Try refreshing the library."
            await loadFirstPage()
        }
    }

    /// Every individual source in display order, flattened across days. The
    /// gallery viewer navigates this list; a sequence cover is represented by its
    /// own sources rather than by the cover tile (REVIEW.md S12).
    var orderedSources: [LibrarySourceCard] {
        var result: [LibrarySourceCard] = []
        for group in dayGroups {
            for card in group.cards {
                switch card.kind {
                case .single(let source):
                    result.append(source)
                case .sequenceCover(_, let cover):
                    // A cover is optional: a sequence whose original preview could
                    // not be retained still lists its own sources, but it must not
                    // contribute a phantom entry here.
                    if let cover { result.append(cover) }
                }
            }
        }
        return result
    }

    /// The sequence summary for a cover card.
    func summary(for sequenceID: SequenceID) -> SequenceSummary? {
        for group in dayGroups {
            for card in group.cards {
                if case .sequenceCover(let summary, _) = card.kind, summary.sequenceID == sequenceID {
                    return summary
                }
            }
        }
        return nil
    }

    /// The committed sources of one sequence, for drilldown and sequence export.
    func sourcesInSequence(_ sequenceID: SequenceID) async -> [LibrarySourceCard] {
        guard let index, !Task.isCancelled else { return [] }
        let root = prepareReadRoot()
        guard canReadIndex else { return [] }
        let cards = (try? await index.sources(inSequence: sequenceID)) ?? []
        guard !Task.isCancelled, readRoot == root,
              sequenceMatchesRoot(cards, sequenceID: sequenceID, root: root) else { return [] }
        return cards
    }

    /// Request ownership cannot prove that a disposable index has caught up
    /// with a newly selected folder. Every returned member must belong to the
    /// requested sequence and, when known, the selected library.
    private func sequenceMatchesRoot(_ cards: [LibrarySourceCard], sequenceID: SequenceID, root: ReadRoot) -> Bool {
        cards.allSatisfy { card in
            card.sequenceID == sequenceID && (root.state?.libraryID.map { card.libraryID == $0 } ?? true)
        }
    }

    func selectSequence(_ sequenceID: SequenceID?) async {
        guard !Task.isCancelled else { return }
        let root = prepareReadRoot()
        guard let sequenceID, let index else {
            sequenceOperation = UUID(); sequenceTask?.cancel(); sequenceTask = nil; sequenceRead = nil
            selectedSequenceID = nil; sequenceCards = []
            return
        }
        guard canReadIndex else {
            if selectedSequenceID != sequenceID { selectedSequenceID = sequenceID; sequenceCards = [] }
            return
        }
        let request = SequenceRead(id: sequenceID, root: root)
        let operation: UUID
        let task: Task<[LibrarySourceCard]?, Never>
        if sequenceRead == request, let pending = sequenceTask {
            // The command and a returning destination can join the same exact
            // in-flight read without queueing another identical index query.
            operation = sequenceOperation; task = pending
        } else {
            sequenceTask?.cancel()
            operation = UUID(); sequenceOperation = operation; sequenceRead = request
            selectedSequenceID = sequenceID; sequenceCards = []
            task = Task { try? await index.sources(inSequence: sequenceID) }
            sequenceTask = task
        }
        defer { if sequenceOperation == operation { sequenceTask = nil } }
        let cards = await task.value
        guard !Task.isCancelled, sequenceOperation == operation, sequenceRead == request,
              readRoot == root, selectedSequenceID == sequenceID else { return }
        let members = cards ?? []
        guard sequenceMatchesRoot(members, sequenceID: sequenceID, root: root) else { return }
        sequenceCards = members
    }

    private func rebuildGroups(from cards: [LibraryCard]) {
        contentRevision &+= 1; reloadRevision &+= 1
        let grouped = Dictionary(grouping: cards) { Self.dayKey(for: $0.capturedAtUTC) }
        dayGroups = grouped.keys.sorted(by: >).map { key in
            let groupCards = grouped[key] ?? []
            return LibraryDayGroup(
                dayKey: key,
                displayTitle: Self.displayTitle(for: key, in: groupCards),
                originalCount: groupCards.reduce(0) { $0 + $1.representedOriginalCount },
                cards: groupCards.sorted { $0.capturedAtUTC > $1.capturedAtUTC })
        }
    }

    private func append(cards: [LibraryCard]) {
        guard !cards.isEmpty else { return }
        contentRevision &+= 1
        var existing = dayGroups
        let grouped = Dictionary(grouping: cards) { Self.dayKey(for: $0.capturedAtUTC) }
        for (key, groupCards) in grouped {
            if let index = existing.firstIndex(where: { $0.dayKey == key }) {
                let incoming = groupCards.sorted { $0.capturedAtUTC > $1.capturedAtUTC }
                existing[index] = LibraryDayGroup(
                    dayKey: key,
                    displayTitle: existing[index].displayTitle,
                    originalCount: existing[index].originalCount + incoming.reduce(0) { $0 + $1.representedOriginalCount },
                    cards: Self.mergeOrderedCards(existing[index].cards, incoming))
            } else {
                existing.append(LibraryDayGroup(
                    dayKey: key,
                    displayTitle: Self.displayTitle(for: key, in: groupCards),
                    originalCount: groupCards.reduce(0) { $0 + $1.representedOriginalCount },
                    cards: groupCards.sorted { $0.capturedAtUTC > $1.capturedAtUTC }))
            }
        }
        dayGroups = existing.sorted { $0.dayKey > $1.dayKey }
    }

    /// Both inputs are descending metadata pages. A linear merge preserves
    /// equal-time order (existing before incoming) without sorting the entire
    /// loaded day again for every page. Unusual synthetic page order stays valid.
    static func mergeOrderedCards(_ existing: [LibraryCard], _ incoming: [LibraryCard]) -> [LibraryCard] {
        var merged: [LibraryCard] = []
        merged.reserveCapacity(existing.count + incoming.count)
        var left = 0, right = 0
        while left < existing.count && right < incoming.count {
            if existing[left].capturedAtUTC >= incoming[right].capturedAtUTC {
                merged.append(existing[left]); left += 1
            } else {
                merged.append(incoming[right]); right += 1
            }
        }
        merged.append(contentsOf: existing[left...])
        merged.append(contentsOf: incoming[right...])
        return merged
    }

    static func dayKey(for date: Date) -> String {
        let components = Calendar.current.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d",
                      components.year ?? 1970, components.month ?? 1, components.day ?? 1)
    }

    static func displayTitle(for dayKey: String, in cards: [LibraryCard]) -> String {
        guard let date = cards.first?.capturedAtUTC else { return dayKey }
        let calendar = Calendar.current
        if calendar.isDateInToday(date) { return "Today" }
        if calendar.isDateInYesterday(date) { return "Yesterday" }
        return date.formatted(.dateTime.year().month(.wide).day())
    }
}

extension LibrarySourceCard {
    /// Export requires an intact local original. A thumbnail is never a
    /// substitute, and a missing source disables export until it is restored.
    var canExportOriginal: Bool {
        availability == .local && classification.isBrowsableOriginal
    }
}
