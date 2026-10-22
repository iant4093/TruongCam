import Foundation
#if canImport(XCTest)
@testable import TruongCam
#endif

/// Metadata-only regressions: no phone, real original or Photos operation.
enum UIOptimizations56Suite {
    static let suite = TCSuite(id: "UI-OPTIMIZATIONS-56", title: "Indexed viewer navigation and bounded metadata publication", cases: [
        TCCase(id: "UI56-N", title: "Immutable viewer order skips tombstones without copying the full source list") { r in navigation(r) },
        TCCase(id: "UI56-D", title: "Viewer deletion advances next, then previous, including repeated and partial deletions") { r in deletion(r) },
        TCCase(id: "UI56-B", title: "Verified visual batches deduplicate cumulative snapshots and reset across operations") { r in removalBatches(r) },
        TCCase(id: "UI56-M", title: "Linear page merge preserves interleaving, equal-time order and empty boundaries") { r in await merging(r) },
        TCCase(id: "UI56-P", title: "Actual paged model keeps date groups, individual counts and replacement revisions") { r in await pagination(r) },
        TCCase(id: "UI56-S", title: "Selection expansions reuse exact covers and revoke changed/root/reloaded metadata") { r in selectionCache(r) }
    ])

    private static func source(_ index: Int, library: LibraryID, sequence: SequenceID? = nil) -> LibrarySourceCard {
        LibrarySourceCard(captureID: CaptureID(), libraryID: library,
            relativeOriginalPath: "originals/ui56-\(index).dng",
            capturedAtUTC: Date(timeIntervalSince1970: 1_700_000_000 - Double(index)),
            capturedAtProvenance: .requestTimestamp, availability: .local,
            classification: .verifiedOriginal, rawDimensions: nil, byteCount: nil,
            sequenceID: sequence, sequenceIndex: sequence == nil ? nil : index,
            sequenceKind: sequence == nil ? nil : .exposureBracket,
            isTruongCamCapture: true, modificationFingerprint: "fixture-\(index)")
    }
    private static func tile(_ source: LibrarySourceCard, date: Date? = nil) -> LibraryCard {
        LibraryCard(id: source.id, kind: .single(source), capturedAtUTC: date ?? source.capturedAtUTC, representedOriginalCount: 1)
    }
    private static func cover(_ sequence: SequenceID, source: LibrarySourceCard, count: Int = 2) -> LibraryCard {
        let summary = SequenceSummary(sequenceID: sequence, kind: .exposureBracket,
            plannedCount: count, committedCount: count, missingIndices: [], failedIndices: [],
            skippedDeadlineCount: 0, status: .complete, startedAtUTC: source.capturedAtUTC)
        return LibraryCard(id: "sequence-\(sequence)", kind: .sequenceCover(summary, cover: source),
            capturedAtUTC: source.capturedAtUTC, representedOriginalCount: count)
    }

    private static func navigation(_ r: TCRecorder) {
        let library = LibraryID(), sources = (0..<10_000).map { source($0, library: library) }
        let order = ViewerSourceOrder(sources)
        let deleted = Set([sources[0].captureID, sources[1].captureID, sources[4999].captureID, sources[5001].captureID])
        r.equal("source order remains the same immutable snapshot", order.sources, sources)
        r.equal("direct lookup preserves exact file/fingerprint identity", order.source(sources[5000].captureID), sources[5000])
        r.equal("previous skips deleted neighbor", order.neighbor(of: sources[5000].captureID, direction: -1, excluding: deleted), sources[4998])
        r.equal("next skips deleted neighbor", order.neighbor(of: sources[5000].captureID, direction: 1, excluding: deleted), sources[5002])
        r.equal("visible ordinal counts only earlier deletions", order.visiblePosition(of: sources[5000].captureID, excluding: deleted), 4997)
        r.equal("visible count excludes exact known IDs", order.visibleCount(excluding: deleted.union([CaptureID()])), 9996)
        r.check("deleted current source is not returned", order.source(sources[1].captureID, excluding: deleted) == nil)
        r.check("unknown and invalid-direction requests have no neighbor", order.neighbor(of: CaptureID(), direction: 1, excluding: []) == nil
            && order.neighbor(of: sources[0].captureID, direction: 2, excluding: []) == nil)
        r.check("first and last boundaries hold", order.neighbor(of: sources[0].captureID, direction: -1, excluding: []) == nil
            && order.neighbor(of: sources.last!.captureID, direction: 1, excluding: []) == nil)
    }

    private static func deletion(_ r: TCRecorder) {
        let library = LibraryID(), sources = (0..<8).map { source($0, library: library) }
        let order = ViewerSourceOrder(sources)
        for deleted in [Set<CaptureID>(), Set(sources[2...5].map(\.captureID)), Set(sources.dropLast().map(\.captureID))] {
            let visible = sources.filter { !deleted.contains($0.captureID) }
            for current in visible {
                let expected = ViewerDeletionNavigation.successor(deleting: current.captureID, ordered: visible.map(\.captureID))
                r.equal("next-then-previous agrees with existing deletion policy", order.successor(deleting: current.captureID, excluding: deleted)?.captureID, expected)
            }
        }
        var deleted: Set<CaptureID> = [], current = sources[3]
        for _ in sources {
            let next = order.successor(deleting: current.captureID, excluding: deleted)
            deleted.insert(current.captureID)
            r.equal("one verified deletion decrements visible count", order.visibleCount(excluding: deleted), sources.count - deleted.count)
            if let next {
                r.check("successor never revisits a deleted original", !deleted.contains(next.captureID))
                current = next
            } else { r.equal("only the final deletion empties the viewer", deleted.count, sources.count) }
        }
        r.check("empty/orphan ordering has no false successor", ViewerSourceOrder([]).successor(deleting: sources[0].captureID, excluding: []) == nil)
    }

    private static func removalBatches(_ r: TCRecorder) {
        var batch = VerifiedPhotoRemovalBatch()
        let first = UUID(), second = UUID(), a = UUID(), b = UUID(), c = UUID()
        r.check("zero scheduled outcomes remove nothing", !batch.record(operationID: first, completedIDs: []))
        r.check("verified first result schedules one publication", batch.record(operationID: first, completedIDs: [a]))
        r.check("duplicate cumulative result schedules no work", !batch.record(operationID: first, completedIDs: [a]))
        _ = batch.record(operationID: first, completedIDs: [a, b])
        r.equal("one flush combines all verified files", batch.drain(), [a, b])
        r.check("repeated flush has no duplicate removals", batch.drain().isEmpty)
        _ = batch.record(operationID: first, completedIDs: [a, b, c])
        r.equal("partial/failing batch publishes only its new completed result", batch.drain(), [c])
        r.check("older progress snapshot does not resurrect an outcome", !batch.record(operationID: first, completedIDs: [a]))
        _ = batch.record(operationID: second, completedIDs: [a])
        r.equal("a new operation has independent verified ownership", batch.drain(), [a])
        _ = batch.record(operationID: second, completedIDs: [a, b])
        batch.reset()
        r.check("root/disappearance cancellation drops queued visual work", batch.drain().isEmpty && batch.operationID == nil && batch.verifiedIDs.isEmpty)
    }

    @MainActor private static func merging(_ r: TCRecorder) {
        let library = LibraryID(), sources = (0..<7).map { source($0, library: library) }
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let a = tile(sources[0], date: date), b = tile(sources[1], date: date.addingTimeInterval(-2))
        let equalOld = tile(sources[2], date: date.addingTimeInterval(-4))
        let c = tile(sources[3], date: date.addingTimeInterval(1)), d = tile(sources[4], date: date.addingTimeInterval(-1))
        let equalNew = tile(sources[5], date: equalOld.capturedAtUTC), tail = tile(sources[6], date: date.addingTimeInterval(-8))
        let existing = [a, b, equalOld], incoming = [c, d, equalNew, tail]
        r.equal("interleaving and equal-time existing order retained", LibraryViewModel.mergeOrderedCards(existing, incoming).map(\.id), [c, a, d, b, equalOld, equalNew, tail].map(\.id))
        r.equal("empty incoming preserves current page", LibraryViewModel.mergeOrderedCards(existing, []), existing)
        r.equal("empty first page retains incoming", LibraryViewModel.mergeOrderedCards([], incoming), incoming)
        r.check("two empty pages remain empty", LibraryViewModel.mergeOrderedCards([], []).isEmpty)
    }

    @MainActor private static func pagination(_ r: TCRecorder) async {
        let library = LibraryID(), index = InMemoryLibraryIndex()
        let sources = (0..<(MetadataBounds.maxIndexPageSize * 3 + 7)).map { source($0, library: library) }
        do {
            try await index.reset(libraryID: library, generation: .zero)
            try await index.upsert(scanned: sources)
            let model = LibraryViewModel(index: index, store: nil)
            await model.loadFirstPage()
            let firstRevision = model.contentRevision, reloadRevision = model.reloadRevision
            while model.hasMorePages { await model.loadNextPage() }
            r.equal("all loaded originals retain display order", model.orderedSources.map(\.captureID), sources.map(\.captureID))
            r.equal("same-day original count remains exact", model.dayGroups.reduce(0) { $0 + $1.originalCount }, sources.count)
            r.equal("bounded pages all published", model.loadedPageCount, 4)
            r.check("append advances cheap task identity", model.contentRevision > firstRevision)
            r.equal("append retains cached expansion authority", model.reloadRevision, reloadRevision)
            await model.loadFirstPage()
            r.check("replacement first page revokes old expansions", model.reloadRevision > reloadRevision)
            r.equal("replacement drops old appended cards", model.loadedSourceCount, MetadataBounds.maxIndexPageSize)
            let previous = model.contentRevision
            model.invalidateRoot()
            r.check("root revocation replaces identity and metadata", model.contentRevision > previous && model.dayGroups.isEmpty)
        } catch { r.check("metadata pagination fixture", false, String(describing: error)) }
    }

    private static func selectionCache(_ r: TCRecorder) {
        var cache = SelectionSequenceExpansionCache()
        let library = LibraryID(), sequence = SequenceID()
        let sources = [source(0, library: library, sequence: sequence), source(1, library: library, sequence: sequence)]
        let tile = cover(sequence, source: sources[0]), changed = cover(sequence, source: sources[0], count: 3)
        let context = SelectionSequenceExpansionCache.Context(root: "root-a", reloadRevision: 1)
        cache.prepare(context)
        r.check("new cover requires one metadata query", cache.sources(for: tile) == nil)
        r.check("current exact members enter the cache", cache.insert(sources, for: tile, libraryID: library, context: context))
        cache.prepare(context)
        r.equal("same frozen index/page append reuses exact members", cache.sources(for: tile), sources)
        r.check("changed cover requires a new query", cache.sources(for: changed) == nil)
        r.check("mixed library or sequence members are rejected", !cache.insert(sources + [source(2, library: LibraryID(), sequence: sequence)], for: tile, libraryID: library, context: context)
            && !cache.insert(sources + [source(2, library: library, sequence: SequenceID())], for: tile, libraryID: library, context: context))
        let refreshed = SelectionSequenceExpansionCache.Context(root: "root-a", reloadRevision: 2)
        cache.prepare(refreshed)
        r.check("first-page replacement clears expansion", cache.sources(for: tile) == nil)
        r.check("late cancelled/replaced-context result cannot populate cache", !cache.insert(sources, for: tile, libraryID: library, context: context))
        _ = cache.insert(sources, for: tile, libraryID: library, context: refreshed)
        cache.prepare(.init(root: "root-b", reloadRevision: 2))
        r.check("equal revision in replacement root is independent", cache.sources(for: tile) == nil)
        cache.reset()
        r.check("release drops authority", cache.context == nil && cache.sources(for: tile) == nil)
    }
}
