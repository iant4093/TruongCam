import Foundation
import Synchronization
#if canImport(XCTest)
@testable import TruongCam
#endif

/// Whole-app storage audit regressions. No source fixtures are user files.
enum StorageAuditSuite {
    private static func write(_ bytes: Data, relative: String, in h: StorageHarness) throws {
        let url = h.root.appendingPathComponent(relative)
        try h.memory.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try h.memory.writeNewFile(at: url, bytes: bytes)
    }

    private static func packet(in h: StorageHarness, mutateRecord: (inout TransactionRecord) -> Void = { _ in },
                               mutateSidecar: (inout SourceSidecar) -> Void = { _ in }) throws -> (prefix: String, path: String, bytes: Data) {
        let capture = CaptureID(), transaction = UUID(), bytes = StorageFixture.rawBytes()
        let path = LibraryLayout.relativeOriginalPath(for: capture, capturedAt: StorageFixture.fixedDate,
            calendar: StorageFixture.utcCalendar)
        let prefix = ".staging/" + transaction.uuidString.lowercased()
        var sidecar = StorageFixture.sidecar(captureID: capture, libraryID: h.libraryID, relativePath: path,
            byteCount: Int64(bytes.count), sha256: StorageFixture.sha256Hex(bytes))
        var record = TransactionRecord(schemaVersion: truongCamSupportedSchemaVersion, transactionID: transaction,
            captureID: capture.rawValue, libraryID: h.libraryID.rawValue, rootGeneration: h.generation.value,
            phase: .verifyingProvider, expectedByteCount: Int64(bytes.count), expectedSHA256: StorageFixture.sha256Hex(bytes),
            relativeOriginalPath: path, createdAtUTC: StorageFixture.fixedDate, updatedAtUTC: StorageFixture.fixedDate, lastError: nil)
        mutateRecord(&record); mutateSidecar(&sidecar)
        try write(bytes, relative: prefix + "/source.dng.partial", in: h)
        try write(StorageFixture.sidecarData(sidecar), relative: prefix + "/source.json.partial", in: h)
        try write(PortableJSONWriter().encode(record, explicitNullKeys: TransactionRecord.explicitNullKeyPaths),
            relative: prefix + "/transaction.json", in: h)
        return (prefix, record.relativeOriginalPath, bytes)
    }

    static let suite = TCSuite(id: "StorageAudit", title: "Stable library scans, packet recovery and exact batch export", cases: [
        TCCase(id: "SA43I", title: "Reconciled recovered identities and fingerprints remain stable across pages and refresh correctly") { r in
            guard let h = await StorageHarness.make(name: "sa43-identities") else { r.check("fixture", false); return }
            do {
                for i in 0..<205 { try write(StorageFixture.rawBytes(byteCount: 16), relative: "originals/user-\(i).dng", in: h) }
                _ = try await h.store.reconcile(onProgress: nil)
                h.memory.resetCounters()
                let first = try await h.store.reconciledSourceCards(after: nil, limit: 100)
                let second = try await h.store.reconciledSourceCards(after: first.nextCursor, limit: 200)
                let all = try await h.store.allReconciledSourceCards()
                r.equal("complete stable paged identity", (first.cards + second.cards).map(\.captureID), all.map(\.captureID))
                r.equal("unique recovered identities", Set(all.map(\.captureID)).count, 205)
                r.check("path-derived identities", all.allSatisfy { $0.captureID == LibraryStore.derivedIndexIdentity(for: $0.relativeOriginalPath) })
                r.check("scanned fingerprints preserved", all.allSatisfy { $0.modificationFingerprint != nil })
                r.equal("cached pages do not rescan", h.memory.scanInvocations, 0)
                r.equal("cached pages do not reread files", h.memory.totalCounters().reads, 0)
                let changed = all[0], oldFingerprint = changed.modificationFingerprint
                h.memory.setBytes(StorageFixture.rawBytes(byteCount: 16, filler: 0x29), at: h.root.appendingPathComponent(changed.relativeOriginalPath))
                _ = try await h.store.reconcile(onProgress: nil)
                let refreshed = try await h.store.allReconciledSourceCards().first { $0.captureID == changed.captureID }
                r.check("same-size edit changes fingerprint", refreshed?.modificationFingerprint != oldFingerprint)
                r.equal("same-size edit preserves identity", refreshed?.captureID, changed.captureID)
                let capture = CaptureID()
                let staged = try await h.store.stageSource(bytes: StorageFixture.rawBytes(), metadata: StorageFixture.metadata(captureID: capture, libraryID: h.libraryID))
                _ = try await h.store.commit(handle: staged)
                r.check("verified commit invalidates old scan", try await h.store.allReconciledSourceCards().contains { $0.captureID == capture })
                await h.store.releaseRoot()
                do { _ = try await h.store.allReconciledSourceCards(); r.check("released root cannot reuse scan", false) }
                catch { r.check("released root cannot reuse scan", true) }
            } catch { r.check("stable cached projection", false, String(describing: error)) }
        },
        TCCase(id: "SA43S", title: "Real nested scans continue past 2000 entries, exclude unrelated trees and disclose an exhausted ceiling") { r in
            let base = StorageFixture.temporaryDirectory("sa43-real-scan")
            defer { StorageFixture.removeDirectory(base) }
            do {
                let root = base.appendingPathComponent("library"), support = base.appendingPathComponent("support")
                let adapter = SystemFileSystemAdapter()
                try adapter.createDirectory(at: root.appendingPathComponent("originals/nested"), withIntermediateDirectories: true)
                try adapter.createDirectory(at: root.appendingPathComponent("unrelated"), withIntermediateDirectories: true)
                for i in 0..<2_010 {
                    try adapter.writeNewFile(at: root.appendingPathComponent("originals/nested/z-user-\(i).dng"), bytes: StorageFixture.rawBytes(byteCount: 16))
                }
                // Real entries named x must not collide with traversal policy.
                try adapter.writeNewFile(at: root.appendingPathComponent("originals/x"), bytes: Data("user file".utf8))
                try adapter.writeNewFile(at: root.appendingPathComponent("originals/nested/x"), bytes: Data("user file".utf8))
                try adapter.writeNewFile(at: root.appendingPathComponent("unrelated/ignore.dng"), bytes: StorageFixture.rawBytes())
                let outside = base.appendingPathComponent("outside")
                try adapter.createDirectory(at: outside, withIntermediateDirectories: true)
                try adapter.writeNewFile(at: outside.appendingPathComponent("outside.dng"), bytes: StorageFixture.rawBytes())
                try FileManager.default.createSymbolicLink(atPath: root.appendingPathComponent("originals/link").path, withDestinationPath: outside.path)
                func store(rounds: Int) -> LibraryStore {
                    LibraryStore(adapter: adapter, coordinator: NSFileCoordinatorMutator(), wallClock: StorageFixture.fixedClock(),
                        supportDirectory: support, temporaryDirectory: base.appendingPathComponent("exports"), ownedContainerURLs: [],
                        bookmarkStore: InMemoryRootBookmarkStore(), scopeDriver: ScriptedSecurityScopeDriver(), capacityReserveBytes: 0,
                        scanRoundLimit: rounds, injectedLocalityVerdict: .userConfirmedLocalDestination(evidence: "Temporary test filesystem"))
                }
                let complete = store(rounds: 50)
                guard case .initialized = await complete.selectRoot(from: root) else { r.check("real root", false); return }
                let result = try await complete.reconcile(onProgress: nil)
                let cards = try await complete.allReconciledSourceCards()
                r.equal("all real originals enumerated", result.recoveredRAWCount, 2_010)
                r.equal("all real cards indexed", cards.count, 2_010)
                try adapter.removeItem(at: root.appendingPathComponent("originals/x"))
                r.equal("real nested x does not prune later batches", try await complete.reconcile(onProgress: nil).recoveredRAWCount, 2_010)
                r.check("unrelated tree excluded", !cards.contains { $0.relativeOriginalPath.contains("ignore") })
                r.check("symlink not traversed", !cards.contains { $0.relativeOriginalPath.contains("outside") })
                let bounded = store(rounds: 1)
                guard case .opened = await bounded.selectRoot(from: root) else { r.check("bounded root", false); return }
                do { _ = try await bounded.reconcile(onProgress: nil); r.check("incomplete scan disclosed", false) }
                catch let failure as CaptureFailure { r.equal("typed scan ceiling", failure.operation, "reconcile.scanLimit") }
                catch { r.check("typed scan ceiling", false, String(describing: error)) }
                r.equal("source retained beyond scan ceiling", try adapter.readAll(at: root.appendingPathComponent("originals/nested/z-user-2009.dng"), maxBytes: 64), StorageFixture.rawBytes(byteCount: 16))
                guard let fake = await StorageHarness.make(name: "sa43-fake-x") else { r.check("fake fixture", false); return }
                for i in 0..<2_010 { try write(StorageFixture.rawBytes(byteCount: 16), relative: "originals/nested/z-user-\(i).dng", in: fake) }
                try write(Data("user file".utf8), relative: "originals/x", in: fake)
                try write(Data("user file".utf8), relative: "originals/nested/x", in: fake)
                r.equal("fake root x does not prune later batches", try await fake.store.reconcile(onProgress: nil).recoveredRAWCount, 2_010)
                try fake.memory.removeItem(at: fake.root.appendingPathComponent("originals/x"))
                r.equal("fake nested x does not prune later batches", try await fake.store.reconcile(onProgress: nil).recoveredRAWCount, 2_010)
                let fakeBounded = LibraryStore(adapter: fake.fault, coordinator: DirectFileCoordinatorMutator(),
                    wallClock: StorageFixture.fixedClock(), supportDirectory: fake.support, temporaryDirectory: fake.temporary,
                    ownedContainerURLs: [], bookmarkStore: InMemoryRootBookmarkStore(), scopeDriver: ScriptedSecurityScopeDriver(),
                    capacityReserveBytes: 0, scanRoundLimit: 1,
                    injectedLocalityVerdict: .userConfirmedLocalDestination(evidence: "Synthetic in-memory fixture"))
                guard case .opened = await fakeBounded.selectRoot(from: fake.root) else { r.check("fake bounded root", false); return }
                do { _ = try await fakeBounded.reconcile(onProgress: nil); r.check("fake incomplete scan disclosed", false) }
                catch let failure as CaptureFailure { r.equal("fake typed scan ceiling", failure.operation, "reconcile.scanLimit") }
            } catch { r.check("real continuation", false, String(describing: error)) }
        },
        TCCase(id: "SA43R", title: "External recovery preflights matching library, transaction, destination and complete sidecar before either move") { r in
            let badRecords: [(String, (inout TransactionRecord) -> Void)] = [
                ("foreign-library", { $0.libraryID = UUID() }),
                ("wrong-transaction", { $0.transactionID = UUID() }),
                ("new-schema", { $0.schemaVersion = 2 }),
                ("wrong-tree", { $0.relativeOriginalPath = "metadata/" + ($0.relativeOriginalPath as NSString).lastPathComponent }),
                ("wrong-capture", { $0.captureID = UUID() }),
                ("zero-count", { $0.expectedByteCount = 0 }),
                ("zero-hash", { $0.expectedSHA256 = String(repeating: "0", count: 64) })
            ]
            do {
                for (name, mutate) in badRecords {
                    guard let h = await StorageHarness.make(name: "sa43-" + name) else { r.check("fixture " + name, false); continue }
                    let packet = try packet(in: h, mutateRecord: mutate)
                    let result = try await h.store.reconcile(onProgress: nil)
                    r.equal(name + " staged original retained", h.memory.fileBytes(at: h.root.appendingPathComponent(packet.prefix + "/source.dng.partial")), packet.bytes)
                    r.check(name + " staged sidecar retained", h.memory.fileExists(at: h.root.appendingPathComponent(packet.prefix + "/source.json.partial")))
                    r.check(name + " nothing published", !h.memory.fileExists(at: h.root.appendingPathComponent(packet.path)))
                    r.check(name + " actionable issue", result.issues.contains { $0.contains("Staging") && $0.contains("kept") })
                }
                let badSidecars: [(String, (inout SourceSidecar) -> Void)] = [
                    ("sidecar-library", { $0.libraryID = UUID() }),
                    ("sidecar-capture", { $0.captureID = UUID() }),
                    ("sidecar-count", { $0.byteCount += 1 }),
                    ("sidecar-hash", { $0.sha256 = String(repeating: "b", count: 64) }),
                    ("sidecar-path", { $0.relativeOriginalPath = "originals/other/" + ($0.relativeOriginalPath as NSString).lastPathComponent })
                ]
                for (name, mutate) in badSidecars {
                    guard let h = await StorageHarness.make(name: "sa43-" + name) else { r.check("fixture " + name, false); continue }
                    let packet = try packet(in: h, mutateSidecar: mutate)
                    _ = try await h.store.reconcile(onProgress: nil)
                    r.equal(name + " original retained", h.memory.fileBytes(at: h.root.appendingPathComponent(packet.prefix + "/source.dng.partial")), packet.bytes)
                    r.check(name + " nothing published", !h.memory.fileExists(at: h.root.appendingPathComponent(packet.path)))
                }
            } catch { r.check("packet preflight", false, String(describing: error)) }
        },
        TCCase(id: "SA43P", title: "Matching staged pairs recover and a published original with missing sidecar completes idempotently") { r in
            do {
                for alreadyPublished in [false, true] {
                    guard let h = await StorageHarness.make(name: "sa43-positive-\(alreadyPublished)") else { r.check("fixture", false); continue }
                    let packet = try packet(in: h)
                    if alreadyPublished {
                        try h.memory.createDirectory(at: h.root.appendingPathComponent(packet.path).deletingLastPathComponent(), withIntermediateDirectories: true)
                        try h.memory.moveItem(at: h.root.appendingPathComponent(packet.prefix + "/source.dng.partial"), to: h.root.appendingPathComponent(packet.path))
                    }
                    let result = try await h.store.reconcile(onProgress: nil)
                    r.equal("exact original published \(alreadyPublished)", h.memory.fileBytes(at: h.root.appendingPathComponent(packet.path)), packet.bytes)
                    r.check("matching sidecar published \(alreadyPublished)", h.memory.fileExists(at: h.root.appendingPathComponent(LibraryLayout.metadataSidecarPath(for: packet.path))))
                    r.equal("pair counted once \(alreadyPublished)", result.verifiedOriginalCount, 1)
                    let again = try await h.store.reconcile(onProgress: nil)
                    r.equal("idempotent recovered pair \(alreadyPublished)", again.verifiedOriginalCount, 1)
                    r.check("journal retained \(alreadyPublished)", h.memory.fileExists(at: h.root.appendingPathComponent(packet.prefix + "/transaction.json")))
                }
            } catch { r.check("positive packet recovery", false, String(describing: error)) }
        },
        TCCase(id: "SA43X", title: "A batch export scans once, exports recovered names and owns scope plus coordination through verified copying") { r in
            let coordinator = ObservedLibraryReadCoordinator()
            guard let h = await StorageHarness.make(name: "sa43-export", coordinator: coordinator) else { r.check("fixture", false); return }
            do {
                var ids: [CaptureID] = []
                for _ in 0..<12 {
                    let capture = CaptureID(); ids.append(capture)
                    let handle = try await h.store.stageSource(bytes: StorageFixture.rawBytes(), metadata: StorageFixture.metadata(captureID: capture, libraryID: h.libraryID))
                    _ = try await h.store.commit(handle: handle)
                }
                let recovered = "originals/external-photo.dng", recoveredBytes = StorageFixture.rawBytes(filler: 0x18)
                try write(recoveredBytes, relative: recovered, in: h)
                ids.append(LibraryStore.derivedIndexIdentity(for: recovered))
                let copyWasCoordinated = Mutex(true), copies = Mutex(0)
                h.fault.setObserver { event in
                    guard event.kind == .write, event.relativePath.hasPrefix("TruongCamExport/") else { return }
                    copies.withLock { $0 += 1 }
                    if coordinator.activeReads == 0 { copyWasCoordinated.withLock { $0 = false } }
                }
                h.memory.resetCounters()
                let exported = try await h.store.prepareOriginalExport(sourceIDs: ids + [ids[0]], includeSidecars: false)
                r.equal("distinct IDs exported once", exported.fileURLs.count, 13)
                r.equal("one bounded collection catalog", h.memory.scanInvocations, 2)
                r.equal("recovered bytes exported by derived ID", h.memory.fileBytes(at: exported.fileURLs.first { $0.lastPathComponent == "external-photo.dng" }!), recoveredBytes)
                r.check("copy accessor covers synchronous work", copyWasCoordinated.withLock { $0 } && copies.withLock { $0 > 0 })
                r.equal("read accessor ended", coordinator.activeReads, 0)
                r.equal("exact reader scope balanced", await h.store.activeReaderCount, 0)
                r.check("normal source destination hash verified", h.memory.counters(at: exported.fileURLs[0]).hashes > 0)
                r.equal("no partial subset", exported.missingItems, [])
                await h.store.discardExport(sessionID: exported.sessionID)
                h.fault.setObserver(nil)
                coordinator.redirectReads(to: h.root.deletingLastPathComponent().appendingPathComponent("outside"))
                do { _ = try await h.store.prepareOriginalExport(sourceIDs: ids, includeSidecars: false); r.check("redirected root refused", false) }
                catch { r.check("redirected root refused", true) }
                r.equal("failed export scope balanced", await h.store.activeReaderCount, 0)
            } catch { r.check("coordinated batch export", false, String(describing: error)) }
        },
        TCCase(id: "SA43C", title: "Distinct recovered originals with the same basename export intact in one batch") { r in
            guard let h = await StorageHarness.make(name: "sa43-export-collisions") else { r.check("fixture", false); return }
            do {
                let paths = ["originals/a/IMG_0001.dng", "originals/b/IMG_0001.dng"]
                let bytes = [StorageFixture.rawBytes(filler: 0x31), StorageFixture.rawBytes(filler: 0x72)]
                for i in paths.indices { try write(bytes[i], relative: paths[i], in: h) }
                _ = try await h.store.reconcile(onProgress: nil)
                let ids = paths.map { LibraryStore.derivedIndexIdentity(for: $0) }
                let session = try await h.store.prepareOriginalExport(sourceIDs: ids, includeSidecars: false)
                r.equal("both recovered originals exported", session.fileURLs.count, 2)
                r.equal("filenames preserved", session.fileURLs.map(\.lastPathComponent), ["IMG_0001.dng", "IMG_0001.dng"])
                r.equal("destinations distinct", Set(session.fileURLs).count, 2)
                r.equal("no missing sources", session.missingItems, [])
                for i in paths.indices {
                    r.equal("exact exported bytes \(i)", h.memory.fileBytes(at: session.fileURLs[i]), bytes[i])
                    r.equal("original unchanged \(i)", h.memory.fileBytes(at: h.root.appendingPathComponent(paths[i])), bytes[i])
                }
                await h.store.discardExport(sessionID: session.sessionID)
            } catch { r.check("collision-safe exact export", false, String(describing: error)) }
        },
        TCCase(id: "SA43D", title: "Failed commit and retry report current internal retention instead of stale external claims") { r in
            guard let h = await StorageHarness.make(name: "sa43-retention") else { r.check("fixture", false); return }
            do {
                let capture = CaptureID(), bytes = StorageFixture.rawBytes()
                let handle = try await h.store.stageSource(bytes: bytes, metadata: StorageFixture.metadata(captureID: capture, libraryID: h.libraryID))
                h.fault.setObserver { event in
                    guard event.kind == .close, event.relativePath.hasPrefix(".staging/"), event.relativePath.hasSuffix("source.dng.partial") else { return }
                    h.memory.setBytes(Data("bad provider copy".utf8), at: h.root.appendingPathComponent(event.relativePath))
                }
                do { _ = try await h.store.commit(handle: handle); r.check("corrupt provider rejected", false) }
                catch let failure as CaptureFailure {
                    r.equal("original failure kind preserved", failure.kind.stableCode, "integrityMismatch")
                    r.equal("original operation preserved", failure.operation, "commit")
                    r.equal("actual internal proof preferred", failure.retainedSourceStatus, .durableInternalStaging(relativePath: handle.pendingRelativePath))
                }
                h.fault.setObserver(nil)
                r.equal("durable internal bytes intact", h.memory.fileBytes(at: h.support.appendingPathComponent(handle.pendingRelativePath)), bytes)
                do { _ = try await h.store.retry(transactionID: handle.transactionID); r.check("occupied bad provider copy refused", false) }
                catch let failure as CaptureFailure { r.equal("retry retains actual internal source", failure.retainedSourceStatus, .durableInternalStaging(relativePath: handle.pendingRelativePath)) }
                let missing = CaptureID()
                let absent = try await h.store.stageSource(bytes: bytes, metadata: StorageFixture.metadata(captureID: missing, libraryID: h.libraryID))
                try h.memory.removeItem(at: h.support.appendingPathComponent(absent.pendingRelativePath))
                do { _ = try await h.store.commit(handle: absent); r.check("missing internal source rejected", false) }
                catch let failure as CaptureFailure { r.equal("stale handle proves no retention", failure.retainedSourceStatus, .none) }
            } catch { r.check("truthful failed commit retention", false, String(describing: error)) }
        },
        TCCase(id: "SA43B", title: "Malformed sequence counts finish boundedly and invalid/foreign documents are never used or rewritten") { r in
            guard let h = await StorageHarness.make(name: "sa43-sequence-bounds") else { r.check("fixture", false); return }
            do {
                var saved: [(URL, Data)] = []
                for count in [Int.min, -1, 0, MetadataBounds.maxSequenceSources + 1, Int.max] {
                    let sequence = SequenceID()
                    let document = SequenceDocument(sequenceID: sequence, libraryID: h.libraryID, kind: .exposureBracket,
                        plannedCount: count, sourcePlan: [], intervalSeconds: nil, baseline: nil, startedAtUTC: StorageFixture.fixedDate)
                    r.check("untrusted count rejected \(count)", !SequenceDocumentSemanticValidator().validate(document).isEmpty)
                    let bytes = try PortableJSONWriter().encode(document, explicitNullKeys: SequenceDocument.explicitNullKeyPaths)
                    let path = LibraryLayout.metadataSequencePath(for: sequence)
                    try write(bytes, relative: path, in: h); saved.append((h.root.appendingPathComponent(path), bytes))
                }
                var foreign = SequenceDocument(sequenceID: SequenceID(), libraryID: LibraryID(), kind: .interval,
                    plannedCount: 1, sourcePlan: [], intervalSeconds: 1, baseline: nil, startedAtUTC: StorageFixture.fixedDate)
                let foreignBytes = try PortableJSONWriter().encode(foreign, explicitNullKeys: SequenceDocument.explicitNullKeyPaths)
                let foreignPath = LibraryLayout.metadataSequencePath(for: SequenceID(foreign.sequenceID))
                try write(foreignBytes, relative: foreignPath, in: h); saved.append((h.root.appendingPathComponent(foreignPath), foreignBytes))
                let result = try await h.store.reconcile(onProgress: nil)
                r.equal("invalid docs create no summary", result.sequences.count, 0)
                r.check("explicit metadata issues", result.issues.filter { $0.contains("without use or rewriting") }.count >= saved.count)
                r.check("all invalid and foreign bytes retained", saved.allSatisfy { h.memory.fileBytes(at: $0.0) == $0.1 })
                foreign.libraryID = h.libraryID.rawValue; foreign.plannedCount = 2
                let captureID = UUID()
                foreign.completedSources = [SequenceCompletedSource(index: 0, captureID: captureID), SequenceCompletedSource(index: 1, captureID: captureID)]
                r.check("duplicate capture UUID rejected", SequenceDocumentSemanticValidator().validate(foreign).contains { $0.contains("duplicate completed capture") })
                foreign.completedSources.removeLast(); foreign.missingIndices = [0]
                r.check("completed/missing overlap rejected", SequenceDocumentSemanticValidator().validate(foreign).contains { $0.contains("both completed and missing") })
            } catch { r.check("bounded sequence quarantine", false, String(describing: error)) }
        },
        TCCase(id: "SA43M", title: "Current sequence membership excludes external missing/Trash sources and returns after verified restore") { r in
            guard let h = await StorageHarness.make(name: "sa43-current-members") else { r.check("fixture", false); return }
            do {
                let sequence = SequenceID(), captures = [CaptureID(), CaptureID()]
                for (index, capture) in captures.enumerated() {
                    let link = SourceSequenceLink(id: sequence, kind: .exposureBracket, index: SourceOrdinal(index), plannedCount: 2)
                    let staged = try await h.store.stageSource(bytes: StorageFixture.rawBytes(), metadata: StorageFixture.metadata(captureID: capture, libraryID: h.libraryID, sequence: link))
                    _ = try await h.store.commit(handle: staged)
                }
                var document = SequenceDocument(sequenceID: sequence, libraryID: h.libraryID, kind: .exposureBracket,
                    plannedCount: 2, sourcePlan: [SequenceSourcePlanEntry(index: 0, offsetEV: -1, focusPosition: nil), SequenceSourcePlanEntry(index: 1, offsetEV: 1, focusPosition: nil)],
                    intervalSeconds: nil, baseline: nil, startedAtUTC: StorageFixture.fixedDate)
                document.completedSources = captures.enumerated().map { SequenceCompletedSource(index: $0.offset, captureID: $0.element.rawValue) }
                document.status = .complete; document.endedAtUTC = StorageFixture.fixedDate; document.restorationStatus = .restored
                try await h.store.writeSequenceDocument(document)
                let initial = try await h.store.reconcile(onProgress: nil)
                r.check("matching existing sources complete", initial.sequences.first?.isComplete == true)
                let cards = try await h.store.allReconciledSourceCards()
                guard let card = cards.first(where: { $0.captureID == captures[0] }) else { r.check("sequence card", false); return }
                let trashed = try await h.store.trashOriginal(card: card, generation: h.generation)
                let afterTrash = try await h.store.reconcile(onProgress: nil)
                r.equal("Trash excluded despite history", afterTrash.sequences.first?.committedCount, 1)
                r.equal("Trash ordinal missing", afterTrash.sequences.first?.missingIndices, [0])
                r.check("Trash sequence incomplete", afterTrash.sequences.first?.isComplete == false)
                try await h.store.restoreOriginal(trashID: trashed.id, libraryID: h.libraryID, generation: h.generation)
                r.check("verified restore returns membership", try await h.store.reconcile(onProgress: nil).sequences.first?.isComplete == true)
                let externalURL = h.finalURL(for: captures[1]), bytes = h.memory.fileBytes(at: externalURL)!
                try h.memory.removeItem(at: externalURL)
                let missing = try await h.store.reconcile(onProgress: nil)
                r.equal("orphan sidecar remains visible", missing.missingOriginalCount, 1)
                r.equal("missing bytes not counted from history", missing.sequences.first?.committedCount, 1)
                r.equal("external missing ordinal", missing.sequences.first?.missingIndices, [1])
                r.check("external missing sequence incomplete", missing.sequences.first?.isComplete == false)
                h.memory.setBytes(bytes, at: externalURL)
                r.check("reconnected source returns membership", try await h.store.reconcile(onProgress: nil).sequences.first?.isComplete == true)
            } catch { r.check("current extant membership", false, String(describing: error)) }
        },
        TCCase(id: "SA43V", title: "Export rejects corrupted destination bytes rather than trusting writes and preserves every original") { r in
            guard let h = await StorageHarness.make(name: "sa43-export-verify") else { r.check("fixture", false); return }
            do {
                let capture = CaptureID(), bytes = StorageFixture.rawBytes()
                let handle = try await h.store.stageSource(bytes: bytes, metadata: StorageFixture.metadata(captureID: capture, libraryID: h.libraryID))
                _ = try await h.store.commit(handle: handle)
                h.fault.setObserver { event in
                    guard event.kind == .close, event.relativePath.hasPrefix("TruongCamExport/") else { return }
                    h.memory.setBytes(Data("wrong persisted bytes".utf8), at: h.temporary.appendingPathComponent(event.relativePath))
                }
                do { _ = try await h.store.prepareOriginalExport(sourceIDs: [capture], includeSidecars: false); r.check("bad persisted copy rejected", false) }
                catch let failure as CaptureFailure { r.check("integrity error", failure.kind.stableCode == "integrityMismatch") }
                catch { r.check("integrity error", false, String(describing: error)) }
                r.equal("source intact", h.memory.fileBytes(at: h.finalURL(for: capture)), bytes)
                r.equal("no lingering export files", h.memory.allPaths().filter { $0.hasPrefix(h.temporary.appendingPathComponent("TruongCamExport").path + "/") }.count, 0)
                r.equal("failed integrity scope balanced", await h.store.activeReaderCount, 0)
            } catch { r.check("verified export bytes", false, String(describing: error)) }
        }
    ])
}
