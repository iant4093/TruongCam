import Foundation
#if canImport(XCTest)
@testable import TruongCam
#endif

/// Read/write fixtures are isolated in-memory libraries; no user original is used.
enum SecondStorageReviewSuite {
    static let suite = TCSuite(id: "SecondStorageReview", title: "Selected-library sidecar authority", cases: [
        TCCase(id: "SS43A", title: "Foreign or misplaced valid metadata cannot establish current capture or sequence authority") { r in
            for foreignLibrary in [true, false] {
                guard let h = await StorageHarness.make(name: "ss43-authority-\(foreignLibrary)") else {
                    r.check("fixture", false); continue
                }
                do {
                    let capture = CaptureID(), sequence = SequenceID(), bytes = StorageFixture.rawBytes(filler: 0x41)
                    let link = SourceSequenceLink(id: sequence, kind: .interval, index: SourceOrdinal(0), plannedCount: 1)
                    let handle = try await h.store.stageSource(bytes: bytes,
                        metadata: StorageFixture.metadata(captureID: capture, libraryID: h.libraryID, sequence: link))
                    let receipt = try await h.store.commit(handle: handle)
                    let originalURL = h.root.appendingPathComponent(receipt.relativeOriginalPath)
                    let sidecarURL = h.root.appendingPathComponent(receipt.relativeSidecarPath)
                    let localBytes = h.memory.fileBytes(at: sidecarURL)!
                    var sidecar = try PortableJSONReader().decode(SourceSidecar.self, from: localBytes,
                        limitBytes: MetadataBounds.maxSourceSidecarUTF8Bytes)
                    if foreignLibrary { sidecar.libraryID = UUID() }
                    else { sidecar.relativeOriginalPath = "originals/misplaced/" + originalURL.lastPathComponent }
                    let savedMetadata = StorageFixture.sidecarData(sidecar)
                    h.memory.setBytes(savedMetadata, at: sidecarURL)
                    r.check("test record remains semantically valid", SourceSidecarSemanticValidator().validate(sidecar).isEmpty)
                    var document = SequenceDocument(sequenceID: sequence, libraryID: h.libraryID, kind: .interval,
                        plannedCount: 1, sourcePlan: [], intervalSeconds: 1, baseline: nil, startedAtUTC: StorageFixture.fixedDate)
                    document.completedSources = [SequenceCompletedSource(index: 0, captureID: capture.rawValue)]
                    document.status = .complete; document.endedAtUTC = StorageFixture.fixedDate
                    document.restorationStatus = .restored
                    try await h.store.writeSequenceDocument(document)
                    let beforeReconcile = try await h.store.browsableSourceCards(limit: 20)
                    let reconciliation = try await h.store.reconcile(onProgress: nil)
                    let afterReconcile = try await h.store.allReconciledSourceCards()
                    let derived = LibraryStore.derivedIndexIdentity(for: receipt.relativeOriginalPath)
                    for (name, cards) in [("browse", beforeReconcile), ("reconcile", afterReconcile)] {
                        r.equal(name + " one original", cards.count, 1)
                        guard let card = cards.first else { continue }
                        r.equal(name + " stable recovered identity", card.captureID, derived)
                        r.equal(name + " local bytes remain browsable", card.availability, .local)
                        r.check(name + " no capture authority", !card.isTruongCamCapture)
                        r.check(name + " no sequence authority", card.sequenceID == nil && card.sequenceIndex == nil)
                        if case .recoveredRAW(let issue) = card.classification {
                            r.check(name + " explicit reason", issue?.contains(foreignLibrary ? "another library" : "another original path") == true)
                        } else { r.check(name + " recovered classification", false) }
                    }
                    r.equal("foreign evidence not verified", reconciliation.verifiedOriginalCount, 0)
                    r.equal("extant recovered source counted", reconciliation.recoveredRAWCount, 1)
                    r.equal("no invented missing original", reconciliation.missingOriginalCount, 0)
                    r.equal("no current sequence membership", reconciliation.sequences.first?.committedCount, 0)
                    r.equal("missing sequence ordinal retained", reconciliation.sequences.first?.missingIndices, [0])
                    r.check("historical complete claim becomes interrupted", reconciliation.sequences.first?.isComplete == false)
                    let session = try await h.store.prepareOriginalExport(sourceIDs: [derived], includeSidecars: false)
                    r.equal("only exact original exported", session.fileURLs.count, 1)
                    r.equal("recovered export byte exact", h.memory.fileBytes(at: session.fileURLs[0]), bytes)
                    await h.store.discardExport(sessionID: session.sessionID)
                    do {
                        _ = try await h.store.prepareOriginalExport(sourceIDs: [derived], includeSidecars: true)
                        r.check("foreign app metadata export refused", false)
                    } catch let failure as CaptureFailure {
                        r.equal("foreign app metadata gets typed error", failure.kind.stableCode, "metadataInvalid")
                    }
                    r.equal("original bytes immutable", h.memory.fileBytes(at: originalURL), bytes)
                    r.equal("foreign metadata immutable", h.memory.fileBytes(at: sidecarURL), savedMetadata)
                    h.memory.setBytes(localBytes, at: sidecarURL)
                    r.equal("restoring matching local record restores verified membership", try await h.store.reconcile(onProgress: nil).verifiedOriginalCount, 1)
                    r.check("matching local positive complete", try await h.store.reconcile(onProgress: nil).sequences.first?.isComplete == true)
                } catch { r.check("sidecar authority fixture", false, String(describing: error)) }
            }
        },
        TCCase(id: "SS43R", title: "A local paired filename rename remains verified and exactly exportable without authorizing a duplicate while its original exists") { r in
            guard let h = await StorageHarness.make(name: "ss43-paired-rename") else { r.check("fixture", false); return }
            do {
                let capture = CaptureID(), bytes = StorageFixture.rawBytes(filler: 0x72)
                let handle = try await h.store.stageSource(bytes: bytes,
                    metadata: StorageFixture.metadata(captureID: capture, libraryID: h.libraryID))
                let receipt = try await h.store.commit(handle: handle)
                let original = h.root.appendingPathComponent(receipt.relativeOriginalPath)
                let renamed = original.deletingLastPathComponent().appendingPathComponent("IMG_0001.dng")
                let metadata = original.deletingLastPathComponent().appendingPathComponent("IMG_0001.json")
                let metadataBytes = h.memory.fileBytes(at: h.root.appendingPathComponent(receipt.relativeSidecarPath))!
                try h.memory.moveItem(at: h.root.appendingPathComponent(receipt.relativeSidecarPath), to: metadata)
                try h.memory.writeNewFile(at: renamed, bytes: bytes)
                _ = try await h.store.reconcile(onProgress: nil)
                guard let duplicate = try await h.store.allReconciledSourceCards().first(where: { $0.relativeOriginalPath.hasSuffix("IMG_0001.dng") }) else {
                    r.check("copied original is represented", false); return
                }
                r.equal("copy does not share capture authority", duplicate.captureID,
                    LibraryStore.derivedIndexIdentity(for: duplicate.relativeOriginalPath))
                r.check("old destination exists so pair is not a rename", !duplicate.isTruongCamCapture)
                try h.memory.removeItem(at: original)
                r.equal("paired rename remains verified", try await h.store.reconcile(onProgress: nil).verifiedOriginalCount, 1)
                let cards = try await h.store.allReconciledSourceCards()
                r.equal("same capture identity retained", cards.first?.captureID, capture)
                r.check("matching local metadata authority retained", cards.first?.isTruongCamCapture == true)
                r.equal("browse shares rename contract", try await h.store.browsableSourceCards(limit: 20).first?.captureID, capture)
                let session = try await h.store.prepareOriginalExport(sourceIDs: [capture], includeSidecars: true)
                r.equal("renamed original and sidecar exported", session.fileURLs.count, 2)
                r.equal("renamed exact original exported", h.memory.fileBytes(at: session.fileURLs.first { $0.lastPathComponent == "IMG_0001.dng" }!), bytes)
                r.equal("renamed metadata exported unchanged", h.memory.fileBytes(at: session.fileURLs.first { $0.lastPathComponent == "IMG_0001.json" }!), metadataBytes)
                r.equal("rename metadata not rewritten", h.memory.fileBytes(at: metadata), metadataBytes)
                r.equal("rename original not rewritten", h.memory.fileBytes(at: renamed), bytes)
                await h.store.discardExport(sessionID: session.sessionID)
            } catch { r.check("paired local rename", false, String(describing: error)) }
        },
        TCCase(id: "SS43O", title: "Unmatched foreign or misplaced sidecars remain immutable user records without missing local captures") { r in
            for foreignLibrary in [true, false] {
                guard let h = await StorageHarness.make(name: "ss43-orphan-\(foreignLibrary)") else {
                    r.check("fixture", false); continue
                }
                do {
                    let capture = CaptureID()
                    let path = LibraryLayout.relativeOriginalPath(for: capture, capturedAt: StorageFixture.fixedDate, calendar: StorageFixture.utcCalendar)
                    var sidecar = StorageFixture.sidecar(captureID: capture, libraryID: h.libraryID, relativePath: path,
                        byteCount: 16, sha256: String(repeating: "a", count: 64))
                    if foreignLibrary { sidecar.libraryID = UUID() }
                    else { sidecar.relativeOriginalPath = "originals/elsewhere/" + (path as NSString).lastPathComponent }
                    let bytes = StorageFixture.sidecarData(sidecar)
                    let url = h.root.appendingPathComponent(LibraryLayout.metadataSidecarPath(for: path))
                    try h.memory.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try h.memory.writeNewFile(at: url, bytes: bytes)
                    r.equal("fallback does not invent local missing source", try await h.store.allReconciledSourceCards().count, 0)
                    let result = try await h.store.reconcile(onProgress: nil)
                    r.equal("foreign orphan not missing", result.missingOriginalCount, 0)
                    r.equal("foreign orphan has no sequence", result.sequences.count, 0)
                    r.equal("cached view does not invent source", try await h.store.allReconciledSourceCards().count, 0)
                    r.check("unknown metadata issue surfaced", result.issues.contains { $0.contains("without local capture authority") })
                    r.equal("unknown metadata not rewritten", h.memory.fileBytes(at: url), bytes)
                } catch { r.check("orphan authority fixture", false, String(describing: error)) }
            }
        }
    ])
}
