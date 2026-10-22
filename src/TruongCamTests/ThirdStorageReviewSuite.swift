import Foundation
#if canImport(XCTest)
@testable import TruongCam
#endif

/// Isolated synthetic source trees and real temporary SQLite files. These
/// storage checks do not decode a real RAW or claim device/provider acceptance.
enum ThirdStorageReviewSuite {
    private static func rootPaths(_ h: StorageHarness) -> Set<String> {
        Set(h.memory.allPaths().filter { $0 == h.root.path || $0.hasPrefix(h.root.path + "/") })
    }

    private static func rootBytes(_ h: StorageHarness) -> [String: Data] {
        Dictionary(uniqueKeysWithValues: rootPaths(h).compactMap { path in
            h.memory.fileBytes(at: URL(fileURLWithPath: path)).map { (path, $0) }
        })
    }

    private static func futureManifest(_ h: StorageHarness, schema: Bool) throws -> Data {
        guard let current = h.memory.fileBytes(at: h.root.appendingPathComponent(LibraryLayout.libraryManifestName)),
              var object = try JSONSerialization.jsonObject(with: current) as? [String: Any] else {
            throw CocoaError(.fileReadCorruptFile)
        }
        object[schema ? "schemaVersion" : "layoutVersion"] = schema
            ? truongCamSupportedSchemaVersion + 1 : LibraryLayout.supportedLayoutVersion + 1
        object["futureField"] = ["mustRemain": "byte exact"]
        return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }

    private static func rejected(_ name: String, r: TCRecorder,
                                 _ body: @Sendable () async throws -> Void) async {
        do { try await body(); r.check(name, false, "A read-only mutation succeeded") }
        catch { r.check(name, true) }
    }

    static let suite = TCSuite(id: "ThirdStorageReview", title: "Read-only original access and duplicate filename ownership", cases: [
        TCCase(id: "S345F", title: "Future schemas and layouts browse and export exact recovered originals without source writes or app metadata authority") { r in
            for newerSchema in [true, false] {
                guard let h = await StorageHarness.make(name: "s345-future-\(newerSchema)") else {
                    r.check("fixture", false); continue
                }
                let directory = StorageFixture.temporaryDirectory("s345-future-db")
                let db = SQLiteIndex(databaseURL: directory.appendingPathComponent("index.sqlite"))
                do {
                    let capture = CaptureID(), sequence = SequenceID(), bytes = StorageFixture.rawBytes(filler: 0x45)
                    let link = SourceSequenceLink(id: sequence, kind: .interval, index: SourceOrdinal(0), plannedCount: 1)
                    let handle = try await h.store.stageSource(bytes: bytes,
                        metadata: StorageFixture.metadata(captureID: capture, libraryID: h.libraryID, sequence: link))
                    let receipt = try await h.store.commit(handle: handle)
                    let document = SequenceDocument(sequenceID: sequence, libraryID: h.libraryID, kind: .interval,
                        plannedCount: 1, sourcePlan: [], intervalSeconds: 1, baseline: nil, startedAtUTC: StorageFixture.fixedDate)
                    try await h.store.writeSequenceDocument(document)
                    let manifestBytes = try futureManifest(h, schema: newerSchema)
                    h.memory.setBytes(manifestBytes, at: h.root.appendingPathComponent(LibraryLayout.libraryManifestName))
                    let originalPaths = rootPaths(h), originalBytes = rootBytes(h)

                    let session = await LibrarySessionCoordinator(store: h.store, index: db)
                    r.check("read-only selection succeeds for browsing", await session.selectRoot(h.root, confirmedLocalDestination: true))
                    guard case .readOnly(_, let browseID) = h.store.rootState, let browseID else {
                        r.check("read-only browse identity", false); throw CocoaError(.fileReadCorruptFile)
                    }
                    r.notEqual("disposable identity grants no original library authority", browseID, h.libraryID)
                    r.check("unknown manifest is not accepted as current", h.store.currentManifest == nil)
                    let model = await LibraryViewModel(index: db, store: h.store)
                    await model.loadFirstPage()
                    let cards = await model.orderedSources
                    r.equal("real SQLite reaches the visible model", cards.count, 1)
                    guard let card = cards.first else { r.check("recovered card exists", false); throw CocoaError(.fileReadCorruptFile) }
                    r.equal("selected readonly browsing identity", card.libraryID, browseID)
                    r.equal("local original remains available", card.availability, .local)
                    r.check("exact export eligibility", card.canExportOriginal)
                    r.check("unsupported app metadata supplies no capture or sequence authority",
                        !card.isTruongCamCapture && card.sequenceID == nil && card.sequenceIndex == nil)
                    r.equal("recovered path identity", card.captureID, LibraryStore.derivedIndexIdentity(for: receipt.relativeOriginalPath))
                    let readBytes = try await h.store.readOriginal(relativePath: receipt.relativeOriginalPath) { url in
                        try h.memory.readAll(at: url, maxBytes: 8192)
                    }
                    r.equal("scoped original read is byte exact", readBytes, bytes)
                    let export = try await h.store.prepareOriginalExport(sourceIDs: [card.captureID], includeSidecars: false)
                    r.equal("one original copy", export.fileURLs.count, 1)
                    r.equal("exact readonly export bytes", h.memory.fileBytes(at: export.fileURLs[0]), bytes)
                    await h.store.discardExport(sessionID: export.sessionID)
                    await rejected("capture staging stays blocked", r: r) {
                        _ = try await h.store.stageSource(bytes: bytes, metadata: StorageFixture.metadata(captureID: CaptureID(), libraryID: browseID))
                    }
                    await rejected("commit stays blocked", r: r) { _ = try await h.store.commit(handle: handle) }
                    await rejected("metadata organization stays blocked", r: r) { _ = try await h.store.organizeMetadata() }
                    await rejected("sequence writes stay blocked", r: r) { try await h.store.writeSequenceDocument(document) }
                    await rejected("recoverable delete stays blocked", r: r) { _ = try await h.store.trashOriginal(card: card, generation: h.generation) }
                    await rejected("unsupported app sidecar cannot be exported as authority", r: r) {
                        _ = try await h.store.prepareOriginalExport(sourceIDs: [card.captureID], includeSidecars: true)
                    }
                    r.equal("no source-tree entries created or removed", rootPaths(h), originalPaths)
                    r.equal("all original and future metadata bytes remain exact", rootBytes(h), originalBytes)
                    r.equal("reader leases balanced", await h.store.activeReaderCount, 0)
                } catch { r.check("future root integration", false, String(describing: error)) }
                await db.closeDatabase()
                StorageFixture.removeDirectory(directory)
            }
        },
        TCCase(id: "S345G", title: "Read-only reselection changes disposable grant authority and a denied reader cannot export") { r in
            guard let h = await StorageHarness.make(name: "s345-reselect") else { r.check("fixture", false); return }
            do {
                let bytes = StorageFixture.rawBytes(), path = "originals/external.dng"
                h.memory.setBytes(bytes, at: h.root.appendingPathComponent(path))
                h.memory.setBytes(try futureManifest(h, schema: true), at: h.root.appendingPathComponent(LibraryLayout.libraryManifestName))
                _ = await h.store.selectRoot(from: h.root)
                let state = h.store.rootState, first = try await h.store.openScopedRead()
                _ = await h.store.selectRoot(from: h.root)
                let second = try await h.store.openScopedRead()
                r.notEqual("same URL reselection invalidates old browsing identity", h.store.rootState, state)
                r.notEqual("each selection owns its exact grant", first.grantID, second.grantID)
                r.notEqual("private read generation advances", first.generation, second.generation)
                r.check("old owned read survives selection replacement", first.isUsable)
                h.store.closeScopedRead(first)
                r.equal("old grant stops after its last reader", first.grant.activeLeaseCount, 0)
                r.equal("closing old reader preserves current selection and reader", second.grant.activeLeaseCount, 2)
                let id = LibraryStore.derivedIndexIdentity(for: path)
                let export = try await h.store.prepareOriginalExport(sourceIDs: [id], includeSidecars: false)
                r.equal("current readonly grant still exports", h.memory.fileBytes(at: export.fileURLs[0]), bytes)
                await h.store.discardExport(sessionID: export.sessionID)
                h.store.closeScopedRead(second)
                r.equal("current reader balanced", await h.store.activeReaderCount, 0)
            } catch { r.check("read-only grant replacement", false, String(describing: error)) }

            guard let denied = StorageHarness.makeRaw(name: "s345-denied", driver: ScriptedSecurityScopeDriver(grants: [true, false, true])) else {
                r.check("denied fixture", false); return
            }
            do {
                let path = "originals/external.dng", bytes = StorageFixture.rawBytes(filler: 0x73)
                let manifest = "{\"schemaVersion\":\(truongCamSupportedSchemaVersion + 1),\"libraryID\":\"\(UUID().uuidString)\",\"future\":true}"
                denied.memory.setBytes(Data(manifest.utf8), at: denied.root.appendingPathComponent(LibraryLayout.libraryManifestName))
                denied.memory.setBytes(bytes, at: denied.root.appendingPathComponent(path))
                _ = await denied.store.selectRoot(from: denied.root)
                let beforePaths = rootPaths(denied), beforeBytes = rootBytes(denied)
                let id = LibraryStore.derivedIndexIdentity(for: path)
                await rejected("denied scope prevents export", r: r) {
                    _ = try await denied.store.prepareOriginalExport(sourceIDs: [id], includeSidecars: false)
                }
                r.equal("denied read retains no reader", await denied.store.activeReaderCount, 0)
                let allowed = try await denied.store.prepareOriginalExport(sourceIDs: [id], includeSidecars: false)
                r.equal("later explicitly allowed scope can export", denied.memory.fileBytes(at: allowed.fileURLs[0]), bytes)
                await denied.store.discardExport(sessionID: allowed.sessionID)
                r.equal("denied and allowed source paths unchanged", rootPaths(denied), beforePaths)
                r.equal("denied and allowed source bytes unchanged", rootBytes(denied), beforeBytes)
            } catch { r.check("denied readonly export", false, String(describing: error)) }
        },
        TCCase(id: "S345D", title: "A UUID-basename copy without app metadata cannot hide or block export of either original") { r in
            guard let h = await StorageHarness.make(name: "s345-duplicate") else { r.check("fixture", false); return }
            let directory = StorageFixture.temporaryDirectory("s345-duplicate-db")
            let db = SQLiteIndex(databaseURL: directory.appendingPathComponent("index.sqlite"))
            do {
                let capture = CaptureID(), bytes = StorageFixture.rawBytes(filler: 0x39)
                let handle = try await h.store.stageSource(bytes: bytes, metadata: StorageFixture.metadata(captureID: capture, libraryID: h.libraryID))
                let receipt = try await h.store.commit(handle: handle)
                let copyPath = "originals/copied/" + LibraryLayout.originalFileName(for: capture)
                h.memory.setBytes(bytes, at: h.root.appendingPathComponent(copyPath))
                let before = rootBytes(h), copiedID = LibraryStore.derivedIndexIdentity(for: copyPath)
                let session = await LibrarySessionCoordinator(store: h.store, index: db)
                await session.rebuildIndex()
                let model = await LibraryViewModel(index: db, store: h.store)
                await model.loadFirstPage()
                let indexed = await model.orderedSources
                r.equal("real SQLite retains both paths", Set(indexed.map(\.relativeOriginalPath)), [receipt.relativeOriginalPath, copyPath])
                r.equal("two distinct visible identities", Set(indexed.map(\.captureID)).count, 2)
                r.equal("authoritative original retains capture UUID", indexed.first { $0.relativeOriginalPath == receipt.relativeOriginalPath }?.captureID, capture)
                r.check("authoritative original remains authored", indexed.first { $0.relativeOriginalPath == receipt.relativeOriginalPath }?.isTruongCamCapture == true)
                r.equal("untrusted copy uses path identity", indexed.first { $0.relativeOriginalPath == copyPath }?.captureID, copiedID)
                r.check("untrusted copy has no capture authority", indexed.first { $0.relativeOriginalPath == copyPath }?.isTruongCamCapture == false)
                r.equal("browse uses the same copy identity", try await h.store.browsableSourceCards(limit: 20).first { $0.relativeOriginalPath == copyPath }?.captureID, copiedID)
                for ids in [[capture], [copiedID], [capture, copiedID]] {
                    let export = try await h.store.prepareOriginalExport(sourceIDs: ids, includeSidecars: false)
                    r.equal("exact requested originals exported", export.fileURLs.count, ids.count)
                    r.check("all copies retain exact original bytes", export.fileURLs.allSatisfy { h.memory.fileBytes(at: $0) == bytes })
                    await h.store.discardExport(sessionID: export.sessionID)
                }
                r.equal("copy review leaves all source bytes unchanged", rootBytes(h), before)

                // Neither filename alone is authority once both paths lack a
                // matching app record. Both must stay separately recoverable.
                try h.memory.removeItem(at: h.root.appendingPathComponent(receipt.relativeSidecarPath))
                await session.rebuildIndex()
                await model.loadFirstPage()
                let recovered = await model.orderedSources
                let expectedIDs = Set([LibraryStore.derivedIndexIdentity(for: receipt.relativeOriginalPath), copiedID])
                r.equal("two untrusted copies retain distinct path identities", Set(recovered.map(\.captureID)), expectedIDs)
                r.check("neither filename invents app authority", recovered.allSatisfy { !$0.isTruongCamCapture && $0.availability == .local })
                let export = try await h.store.prepareOriginalExport(sourceIDs: Array(expectedIDs), includeSidecars: false)
                r.equal("both recovered originals export", export.fileURLs.count, 2)
                r.check("both recovered copies remain exact", export.fileURLs.allSatisfy { h.memory.fileBytes(at: $0) == bytes })
                await h.store.discardExport(sessionID: export.sessionID)
                r.equal("original bytes remain", h.memory.fileBytes(at: h.root.appendingPathComponent(receipt.relativeOriginalPath)), bytes)
                r.equal("copied bytes remain", h.memory.fileBytes(at: h.root.appendingPathComponent(copyPath)), bytes)
            } catch { r.check("duplicate UUID basename integration", false, String(describing: error)) }
            await db.closeDatabase()
            StorageFixture.removeDirectory(directory)
        }
    ])
}
