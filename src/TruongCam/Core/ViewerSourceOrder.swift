import Foundation

/// Immutable metadata ordering for one viewer presentation. The ID lookup is
/// built once; gesture samples never filter-copy the complete library.
struct ViewerSourceOrder: Sendable {
    let sources: [LibrarySourceCard]
    private let positions: [CaptureID: Int]

    init(_ sources: [LibrarySourceCard]) {
        self.sources = sources
        positions = sources.enumerated().reduce(into: [:]) { result, entry in
            if result[entry.element.captureID] == nil { result[entry.element.captureID] = entry.offset }
        }
    }

    func source(_ id: CaptureID, excluding deleted: Set<CaptureID> = []) -> LibrarySourceCard? {
        guard !deleted.contains(id), let position = positions[id] else { return nil }
        return sources[position]
    }

    func position(of id: CaptureID) -> Int? { positions[id] }

    func visibleCount(excluding deleted: Set<CaptureID>) -> Int {
        sources.count - deleted.reduce(0) { $0 + (positions[$1] == nil ? 0 : 1) }
    }

    func visiblePosition(of id: CaptureID, excluding deleted: Set<CaptureID>) -> Int? {
        guard !deleted.contains(id), let position = positions[id] else { return nil }
        return position - deleted.reduce(0) { count, removed in
            count + (positions[removed].map { $0 < position } == true ? 1 : 0)
        }
    }

    func neighbor(of id: CaptureID, direction: Int, excluding deleted: Set<CaptureID>) -> LibrarySourceCard? {
        guard direction == -1 || direction == 1, let position = positions[id] else { return nil }
        var next = position + direction
        while sources.indices.contains(next) {
            let source = sources[next]
            if !deleted.contains(source.captureID) { return source }
            next += direction
        }
        return nil
    }

    func successor(deleting id: CaptureID, excluding deleted: Set<CaptureID>) -> LibrarySourceCard? {
        neighbor(of: id, direction: 1, excluding: deleted)
            ?? neighbor(of: id, direction: -1, excluding: deleted)
    }
}

/// Coalesces cumulative, verified mutation snapshots. Repeated progress/render
/// callbacks cannot remove tiles twice, and a new operation/root starts fresh.
/// No scheduled or unverified ID enters a visual-removal batch.
struct VerifiedPhotoRemovalBatch: Sendable {
    private(set) var operationID: UUID?
    private(set) var verifiedIDs: Set<UUID> = []
    private var appliedIDs: Set<UUID> = []

    @discardableResult mutating func record(operationID: UUID, completedIDs: Set<UUID>) -> Bool {
        if self.operationID != operationID {
            self.operationID = operationID; verifiedIDs = []; appliedIDs = []
        }
        // Outcomes for one operation only grow. Count detects duplicate snapshots
        // without comparing/scanning a large retained set on every UI update.
        guard completedIDs.count > verifiedIDs.count else { return false }
        verifiedIDs = completedIDs
        return true
    }

    mutating func drain() -> Set<UUID> {
        let result = verifiedIDs.subtracting(appliedIDs)
        appliedIDs = verifiedIDs
        return result
    }

    mutating func reset() { operationID = nil; verifiedIDs = []; appliedIDs = [] }
}

/// Selection expands only new/changed covers while loading more pages from one
/// frozen index. A first-page replacement or root change revokes every entry.
struct SelectionSequenceExpansionCache: Sendable {
    struct Context: Equatable, Sendable {
        let root: String
        let reloadRevision: UInt64
    }
    private struct Entry: Sendable {
        let tile: LibraryCard
        let sources: [LibrarySourceCard]
    }
    private(set) var context: Context?
    private var entries: [SequenceID: Entry] = [:]

    mutating func prepare(_ context: Context) {
        guard self.context != context else { return }
        self.context = context; entries = [:]
    }
    mutating func reset() { context = nil; entries = [:] }
    func sources(for tile: LibraryCard) -> [LibrarySourceCard]? {
        guard case .sequenceCover(let summary, _) = tile.kind,
              let entry = entries[summary.sequenceID], entry.tile == tile else { return nil }
        return entry.sources
    }
    @discardableResult mutating func insert(_ members: [LibrarySourceCard], for tile: LibraryCard,
                                           libraryID: LibraryID?, context: Context) -> Bool {
        guard self.context == context, let libraryID,
              case .sequenceCover(let summary, _) = tile.kind,
              members.allSatisfy({ $0.libraryID == libraryID && $0.sequenceID == summary.sequenceID }) else { return false }
        entries[summary.sequenceID] = Entry(tile: tile, sources: members)
        return true
    }
}
