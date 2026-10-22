import Foundation
import ImageIO

#if canImport(XCTest)
@testable import TruongCam
#endif

// Integration-seam regressions for the review repairs.
//
// REVIEW.md C06/C07 were *orchestration* failures: the services existed and passed
// their own unit tests, but nothing ever called them. These cases drive the real
// store and the real index through the production entry points, so a future
// refactor that disconnects them fails here.

enum IntegrationRepairSuite {
    static let suite = TCSuite(
        id: "REPAIR-INT",
        title: "Repaired integration seams (C06 index rebuild, C07 export)",
        cases: [

            // MARK: C06 — reconnect/rebuild actually populates the index

            TCCase(id: "C06a", title: "Committing originals then rebuilding from the files produces browsable cards") { r in
                guard let h = await StorageHarness.make(name: "c06a") else {
                    r.check("harness", false, "selectRoot failed"); return
                }
                // Two committed originals through the real store.
                var committed: [CommitReceipt] = []
                for _ in 0..<2 {
                    let bytes = StorageFixture.rawBytes(byteCount: 2_048, filler: 0x5A)
                    guard let handle = try? await h.store.stageSource(
                        bytes: bytes,
                        metadata: StorageFixture.metadata(captureID: CaptureID(), libraryID: h.libraryID)),
                          let receipt = try? await h.store.commit(handle: handle) else {
                        r.check("seed commit", false, "commit failed"); return
                    }
                    committed.append(receipt)
                }
                r.equal("two commits", committed.count, 2)

                // This is the call C06 said was missing entirely.
                let cards = (try? await h.store.browsableSourceCards(limit: 200)) ?? []
                r.equal("both originals are enumerable", cards.count, 2)
                r.check("cards carry the committed paths",
                        Set(cards.map(\.relativeOriginalPath)) == Set(committed.map(\.relativeOriginalPath)))
                r.check("verified originals are not labelled recovered",
                        cards.allSatisfy { if case .verifiedOriginal = $0.classification { return true }; return false })
                r.check("originals are reported locally available",
                        cards.allSatisfy { $0.availability == .local })
            },

            TCCase(id: "C06b", title: "A rebuilt index pages the recovered cards and survives an empty sandbox") { r in
                guard let h = await StorageHarness.make(name: "c06b") else {
                    r.check("harness", false, "selectRoot failed"); return
                }
                let bytes = StorageFixture.rawBytes(byteCount: 1_024, filler: 0x11)
                guard let handle = try? await h.store.stageSource(
                    bytes: bytes,
                    metadata: StorageFixture.metadata(captureID: CaptureID(), libraryID: h.libraryID)),
                      (try? await h.store.commit(handle: handle)) != nil else {
                    r.check("seed commit", false, "commit failed"); return
                }

                // A brand-new index, exactly as a fresh install would have. The
                // storage harness uses the in-memory file adapter, so a real
                // SQLite file cannot be opened against it; this substitute
                // implements the same LibraryIndexing contract.
                let index = InMemoryLibraryIndex()
                let session = await MainActor.run {
                    LibrarySessionCoordinator(store: h.store, index: index)
                }
                await MainActor.run { }
                await session.rebuildIndex()

                let status = await MainActor.run { session.status }
                if case .ready(let verified, _, _) = status {
                    r.equal("reconcile reported the committed original", verified, 1)
                } else {
                    r.check("rebuild reached ready", false, "status \(status)")
                }

                let page = try? await index.firstPage(size: MetadataBounds.maxIndexPageSize)
                r.equal("index serves one card after rebuild", page?.cards.count, 1)
                r.equal("rebuild does not require the old database",
                        try? await index.totalCommittedOriginalCount(), 1)
            },

            TCCase(id: "C06c", title: "An index failure never reports a committed original as failed") { r in
                guard let h = await StorageHarness.make(name: "c06c") else {
                    r.check("harness", false, "selectRoot failed"); return
                }
                let bytes = StorageFixture.rawBytes(byteCount: 1_024, filler: 0x22)
                guard let handle = try? await h.store.stageSource(
                    bytes: bytes,
                    metadata: StorageFixture.metadata(captureID: CaptureID(), libraryID: h.libraryID)),
                      let receipt = try? await h.store.commit(handle: handle) else {
                    r.check("seed commit", false, "commit failed"); return
                }
                // Point the index at an unwritable location so ingestion fails.
                let badIndex = SQLiteIndex(databaseURL: URL(fileURLWithPath: "/dev/null/truongcam.sqlite"))
                let session = await MainActor.run {
                    LibrarySessionCoordinator(store: h.store, index: badIndex)
                }
                await session.ingestCommitted([receipt])

                let issues = await MainActor.run { session.issues }
                r.check("the index failure is reported",
                        issues.contains { $0.contains("saved") && $0.contains("gallery") },
                        "issues: \(issues)")
                // The durable original is untouched by the index failure.
                let cards = (try? await h.store.browsableSourceCards(limit: 50)) ?? []
                r.equal("the original is still present in the folder", cards.count, 1)
            },

            TCCase(id: "C06d", title: "A DNG with no sidecar is browsable as recovered, never as a TruongCam capture") { r in
                guard let h = await StorageHarness.make(name: "c06d") else {
                    r.check("harness", false, "selectRoot failed"); return
                }
                // Drop a DNG-shaped file straight into the originals tree with no
                // sidecar, as a user copying a file in Files would.
                let orphanID = CaptureID()
                let relative = LibraryLayout.relativeOriginalPath(
                    for: orphanID,
                    capturedAt: Date(timeIntervalSince1970: 1_790_000_000),
                    calendar: Calendar(identifier: .gregorian))
                let url = h.root.appendingPathComponent(relative, isDirectory: false)
                try? h.memory.createDirectory(at: url.deletingLastPathComponent(),
                                              withIntermediateDirectories: true)
                try? h.memory.writeNewFile(at: url, bytes: StorageFixture.rawBytes(byteCount: 512, filler: 0x33))

                let cards = (try? await h.store.browsableSourceCards(limit: 50)) ?? []
                r.equal("the orphan file is browsable", cards.count, 1)
                if let card = cards.first {
                    r.check("it is NOT asserted to be a genuine capture", !card.isTruongCamCapture)
                    if case .recoveredRAW = card.classification {
                        r.check("classified as recovered RAW", true)
                    } else {
                        r.check("classified as recovered RAW", false, "\(card.classification)")
                    }
                }
            },

            // MARK: C07 — export is actually prepared and reachable

            TCCase(id: "C07a", title: "Pending export works from internal storage when the external root is gone") { r in
                guard let h = await StorageHarness.make(name: "c07a") else {
                    r.check("harness", false, "selectRoot failed"); return
                }
                // Stage a source but do NOT commit it: it lives only in internal
                // recovery storage, which is exactly the pending case.
                let bytes = StorageFixture.rawBytes(byteCount: 1_536, filler: 0x44)
                guard let handle = try? await h.store.stageSource(
                    bytes: bytes,
                    metadata: StorageFixture.metadata(captureID: CaptureID(), libraryID: h.libraryID)) else {
                    r.check("stage", false, "stageSource failed"); return
                }
                r.equal("one pending original", (await h.store.pendingOriginals()).count, 1)

                // Release the root: the external folder is now unavailable.
                await h.store.releaseRoot()

                // The recovery export must still work, because that is when it is
                // needed. The old path required a writable external root.
                let session = try? await h.store.preparePendingOriginalExport(
                    transactionIDs: [handle.transactionID], includeSidecars: true)
                guard let session else {
                    r.check("pending export succeeds without the root", false, "preparePendingOriginalExport threw")
                    return
                }
                r.check("an exported file is offered", !session.fileURLs.isEmpty)
                r.check("the copy is labelled as recovered",
                        session.fileURLs.contains { $0.lastPathComponent.contains("recovered") })
                r.check("no missing items", session.missingItems.isEmpty)

                // The exported bytes must equal the staged bytes exactly.
                let exportedDNG = session.fileURLs.first { $0.pathExtension == "dng" }
                if let exportedDNG, let exported = h.memory.fileBytes(at: exportedDNG) {
                    r.equal("exact bytes, no re-encoding", StorageFixture.sha256Hex(exported),
                            StorageFixture.sha256Hex(bytes))
                } else {
                    r.check("exported DNG is readable", false)
                }
            },

            TCCase(id: "C07b", title: "Pending export refuses to export bytes that fail their recorded checksum") { r in
                guard let h = await StorageHarness.make(name: "c07b") else {
                    r.check("harness", false, "selectRoot failed"); return
                }
                let bytes = StorageFixture.rawBytes(byteCount: 1_024, filler: 0x55)
                guard let handle = try? await h.store.stageSource(
                    bytes: bytes,
                    metadata: StorageFixture.metadata(captureID: CaptureID(), libraryID: h.libraryID)) else {
                    r.check("stage", false, "stageSource failed"); return
                }
                // Corrupt the internal recovery copy after staging.
                let internalURL = h.support.appendingPathComponent(handle.pendingRelativePath, isDirectory: false)
                if let existing = h.memory.fileBytes(at: internalURL) {
                    var mutated = existing
                    if !mutated.isEmpty { mutated[0] = mutated[0] &+ 0xFF }
                    try? h.memory.removeItem(at: internalURL)
                    try? h.memory.writeNewFile(at: internalURL, bytes: mutated)
                }

                var threwIntegrity = false
                do {
                    _ = try await h.store.preparePendingOriginalExport(
                        transactionIDs: [handle.transactionID], includeSidecars: false)
                } catch let failure as CaptureFailure {
                    if case .integrityMismatch = failure.kind { threwIntegrity = true }
                } catch { }
                r.check("an integrity mismatch blocks the pending export", threwIntegrity)
            },

            TCCase(id: "C07c", title: "A failed export produces a visible, actionable failure, not silence") { r in
                // The old code was `_ = try? await store.prepareOriginalExport(...)`,
                // so every failure was discarded and no UI state existed. This
                // asserts the failure-mapping path the presenter relies on.
                let failure = CaptureFailure(
                    kind: .folderUnavailable(detail: "No library folder is selected."),
                    operation: "prepareOriginalExport")
                let surfaced = UserFacingFailure.from(failure)
                r.equal("the failure becomes a friendly titled error", surfaced.title, "Reconnect your folder")
                r.check("reconnect is offered for a folder problem",
                        surfaced.actions.contains(.reconnect))
                r.check("pending export is offered as recovery",
                        surfaced.actions.contains(.exportPending))
                r.check("the detail is not empty", !surfaced.detail.isEmpty)

                // An integrity mismatch offers export rather than a retry loop.
                let mismatch = UserFacingFailure.from(CaptureFailure(
                    kind: .integrityMismatch(detail: "checksum differs"), operation: "prepareOriginalExport"))
                r.check("integrity mismatch offers export",
                        mismatch.actions.contains(.exportPending))
            },
        ])
}

/// A `LibraryIndexing` implementation backed by a dictionary.
///
/// The storage harness runs on the in-memory file adapter, so a real SQLite file
/// cannot be created against it. This provides the same contract so the
/// orchestration seam (reconcile -> reset -> upsert -> page) is still exercised
/// end to end. The real `SQLiteIndex` has its own dedicated suite.
actor InMemoryLibraryIndex: LibraryIndexing {
    private var libraryID: LibraryID?
    private var generation = RootGeneration.zero
    private var cards: [CaptureID: LibrarySourceCard] = [:]
    private var sequences: [SequenceID: [LibrarySourceCard]] = [:]
    private var order: [CaptureID] = []
    private var unavailableReasons: [CaptureID: String] = [:]
    private(set) var sequenceSummaries: [SequenceID: SequenceSummary] = [:]

    func reset(libraryID: LibraryID, generation: RootGeneration) async throws {
        self.libraryID = libraryID
        self.generation = generation
        cards.removeAll()
        sequences.removeAll()
        order.removeAll()
        unavailableReasons.removeAll()
        sequenceSummaries.removeAll()
    }

    func ingest(_ receipts: [CommitReceipt]) async throws {
        for receipt in receipts {
            let card = LibrarySourceCard(
                captureID: receipt.captureID,
                libraryID: receipt.libraryID,
                relativeOriginalPath: receipt.relativeOriginalPath,
                capturedAtUTC: receipt.metadata.capturedAtUTC,
                capturedAtProvenance: receipt.metadata.capturedAtProvenance,
                availability: .local,
                classification: .verifiedOriginal,
                rawDimensions: receipt.metadata.observed.rawDimensions,
                byteCount: receipt.verifiedByteCount,
                sequenceID: receipt.metadata.sequence.map { SequenceID($0.id) },
                sequenceIndex: receipt.metadata.sequence?.index,
                sequenceKind: receipt.metadata.sequence?.kind,
                isTruongCamCapture: true,
                modificationFingerprint: receipt.verifiedSHA256.hex)
            cards[card.captureID] = card
            if !order.contains(card.captureID) { order.append(card.captureID) }
        }
    }

    func upsert(scanned: [LibrarySourceCard]) async throws {
        for card in scanned {
            cards[card.captureID] = card
            if !order.contains(card.captureID) { order.append(card.captureID) }
            if let sequenceID = card.sequenceID {
                sequences[sequenceID, default: []].append(card)
            }
        }
    }

    func updateSequences(_ summaries: [SequenceSummary]) async throws {
        for summary in summaries { sequenceSummaries[summary.sequenceID] = summary }
    }

    func markUnavailable(captureID: CaptureID, reason: String) async throws {
        unavailableReasons[captureID] = reason
    }

    func firstPage(size: Int) async throws -> LibraryPage {
        try await pageSlice(after: nil, size: size)
    }

    func page(after cursor: LibraryCursor, size: Int) async throws -> LibraryPage {
        try await pageSlice(after: cursor, size: size)
    }

    private func pageSlice(after cursor: LibraryCursor?, size: Int) async throws -> LibraryPage {
        let bounded = max(1, min(size, MetadataBounds.maxIndexPageSize))
        let sorted = order.compactMap { cards[$0] }.sorted { $0.capturedAtUTC > $1.capturedAtUTC }
        let startIndex: Int
        if let cursor {
            startIndex = sorted.firstIndex { $0.capturedAtUTC < cursor.capturedAtUTC } ?? sorted.count
        } else {
            startIndex = 0
        }
        let slice = Array(sorted.dropFirst(startIndex).prefix(bounded))
        let next: LibraryCursor? = startIndex + slice.count < sorted.count
            ? slice.last.map { LibraryCursor(capturedAtUTC: $0.capturedAtUTC,
                                            tieBreaker: $0.captureID.description,
                                            libraryGeneration: generation) }
            : nil
        return LibraryPage(
            cards: slice.map { LibraryCard(id: $0.captureID.description,
                                           kind: .single($0),
                                           capturedAtUTC: $0.capturedAtUTC,
                                           representedOriginalCount: 1) },
            nextCursor: next,
            libraryGeneration: generation,
            indexedLibraryID: libraryID, totalCommittedOriginalCount: cards.count)
    }

    func detail(captureID: CaptureID) async throws -> LibrarySourceCard? { cards[captureID] }

    func sources(inSequence sequenceID: SequenceID) async throws -> [LibrarySourceCard] {
        (sequences[sequenceID] ?? []).sorted { ($0.sequenceIndex ?? 0) < ($1.sequenceIndex ?? 0) }
    }

    func dayGroupCounts() async throws -> [DayGroupCount] { [] }

    func totalCommittedOriginalCount() async throws -> Int { cards.count }
}
