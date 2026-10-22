import Foundation
#if canImport(XCTest)
@testable import TruongCam
#endif

private final class FourthWeakGrant: @unchecked Sendable {
    weak var grant: BookmarkRootGrant?
    init(_ grant: BookmarkRootGrant?) { self.grant = grant }
}

/// Scope ownership uses isolated synthetic libraries and scripted system grants.
/// No source bytes belong to a user or establish physical-provider acceptance.
enum FourthStorageReviewSuite {
    private static func releaseUnstartedSelection(_ h: StorageHarness) async throws -> FourthWeakGrant {
        let lease = try await h.store.openScopedRead()
        let weak = FourthWeakGrant(lease.grant as? BookmarkRootGrant)
        h.store.closeScopedRead(lease)
        await h.store.releaseRoot()
        return weak
    }
    private static func exerciseReplacement(_ r: TCRecorder, heldReader: Bool,
                                            candidateStarts: Bool, readOnly: Bool) async {
        let name = "s446-grant-\(heldReader)-\(candidateStarts)-\(readOnly)"
        // A selection/read, B selection, denied B read, allowed B read/export.
        let driver = ScriptedSecurityScopeDriver(grants: [true, true, candidateStarts, false, true, true])
        guard let h = await StorageHarness.make(name: name, driver: driver) else {
            r.check("initial root", false); return
        }
        do {
            let old = try await h.store.openScopedRead()
            defer { h.store.closeScopedRead(old) }
            let registry = await h.store.scopeRegistryForDiagnostics
            r.check("A reader genuinely opened", old.isUsable)
            r.equal("A owns selection and reader", old.grant.activeLeaseCount, 2)
            if !heldReader { h.store.closeScopedRead(old) }

            let next = h.root.deletingLastPathComponent().appendingPathComponent("library-b", isDirectory: true)
            let relative = "originals/from-b.dng", bytes = StorageFixture.rawBytes(filler: 0x46)
            h.memory.setBytes(bytes, at: next.appendingPathComponent(relative))
            if readOnly {
                h.memory.setBytes(Data("{\"schemaVersion\":\(truongCamSupportedSchemaVersion + 1),\"future\":true}".utf8),
                                  at: next.appendingPathComponent(LibraryLayout.libraryManifestName))
            }
            let outcome = await h.store.selectRoot(from: next)
            if readOnly {
                if case .readOnlyNewerSchema = outcome { r.check("B is selected read-only", true) }
                else { r.check("B is selected read-only", false, String(describing: outcome)) }
            } else {
                if case .initialized = outcome { r.check("B is selected writable", true) }
                else { r.check("B is selected writable", false, String(describing: outcome)) }
            }
            r.equal("B root published", h.store.grantedRootURL, next)
            r.equal("A retires immediately or preserves its held reader", old.grant.activeLeaseCount, heldReader ? 2 : 0)
            r.equal("A selection stop is deferred only for its reader", registry.isSelectionLeaseOpen(old.grantID), heldReader)

            let denied = try await h.store.openScopedRead()
            h.store.closeScopedRead(denied)
            r.check("denied B reader is unusable", !denied.isUsable)
            r.equal("denied B reader adds no lease", denied.grant.activeLeaseCount, candidateStarts ? 1 : 0)
            r.equal("B registers a selection only when it started", registry.isSelectionLeaseOpen(denied.grantID), candidateStarts)
            r.equal("denied B read does not alter A reader", await h.store.activeReaderCount, heldReader ? 1 : 0)

            let observed = try await h.store.readOriginal(relativePath: relative) { url in
                try h.memory.readAll(at: url, maxBytes: 8192)
            }
            r.equal("later allowed B read uses B bytes", observed, bytes)
            let exported = try await h.store.prepareOriginalExport(
                sourceIDs: [LibraryStore.derivedIndexIdentity(for: relative)], includeSidecars: false)
            r.equal("later allowed B export has one original", exported.fileURLs.count, 1)
            if let url = exported.fileURLs.first {
                r.equal("B export is byte exact", h.memory.fileBytes(at: url), bytes)
            }
            await h.store.discardExport(sessionID: exported.sessionID)
            r.equal("B operations preserve A's reader until release", old.grant.activeLeaseCount, heldReader ? 2 : 0)
            r.equal("B operations leave only its actual selection", denied.grant.activeLeaseCount, candidateStarts ? 1 : 0)
            h.store.closeScopedRead(old)
            r.equal("A selection and reader both stop", old.grant.activeLeaseCount, 0)
            r.check("A registry no longer owns a selection", !registry.isSelectionLeaseOpen(old.grantID))
            r.equal("A registry no longer owns a reader", registry.activeReaders(for: old.grantID), 0)
            if let grant = old.grant as? BookmarkRootGrant {
                r.equal("A receives exactly its reader and selection stops", grant.endAccessCallCount, 2)
            }
            await h.store.releaseRoot()
            r.equal("B releases every actual scope", denied.grant.activeLeaseCount, 0)
            r.check("B registry owns no selection", !registry.isSelectionLeaseOpen(denied.grantID))
            r.equal("all registered readers drain", await h.store.activeReaderCount, 0)
            if let grant = denied.grant as? BookmarkRootGrant {
                r.equal("B closes only successfully started leases", grant.endAccessCallCount, candidateStarts ? 3 : 2)
            }
            r.equal("B original remains unchanged", h.memory.fileBytes(at: next.appendingPathComponent(relative)), bytes)
        } catch { r.check("replacement scope ownership", false, String(describing: error)) }
        await h.store.releaseRoot()
    }

    static let suite = TCSuite(id: "FourthStorageReview", title: "Replaced selection lease ownership", cases: [
        TCCase(id: "S446M", title: "Releasing a selection that never opened a scope retains no unused grant object") { r in
            guard let h = await StorageHarness.make(name: "s446-unleased-release",
                driver: ScriptedSecurityScopeDriver(grants: [false, true])) else { r.check("fixture", false); return }
            do {
                let reference = try await releaseUnstartedSelection(h)
                r.check("unleased selection object is released after its reader drains", reference.grant == nil)
                r.equal("no retained reader", await h.store.activeReaderCount, 0)
            } catch { r.check("unleased selection cleanup", false, String(describing: error)) }
        },
        TCCase(id: "S446G", title: "Replacing A retires its scope even when B starts no new selection scope") { r in
            for heldReader in [false, true] {
                for candidateStarts in [false, true] {
                    await exerciseReplacement(r, heldReader: heldReader, candidateStarts: candidateStarts, readOnly: false)
                }
            }
        },
        TCCase(id: "S446F", title: "A read-only B without a selection scope retains exact reader and export ownership") { r in
            await exerciseReplacement(r, heldReader: true, candidateStarts: false, readOnly: true)
        },
        TCCase(id: "S446E", title: "A candidate rejected before replacement does not retire A's retained scope") { r in
            let driver = ScriptedSecurityScopeDriver(grants: [true, true, false])
            guard let h = await StorageHarness.make(name: "s446-early-reject", driver: driver) else {
                r.check("initial root", false); return
            }
            do {
                let old = try await h.store.openScopedRead()
                defer { h.store.closeScopedRead(old) }
                let registry = await h.store.scopeRegistryForDiagnostics
                let missing = h.root.deletingLastPathComponent().appendingPathComponent("absent-b", isDirectory: true)
                let outcome = await h.store.selectRoot(from: missing)
                if case .unavailable = outcome { r.check("missing candidate is rejected", true) }
                else { r.check("missing candidate is rejected", false, String(describing: outcome)) }
                r.equal("A still owns both scopes before replacement", old.grant.activeLeaseCount, 2)
                r.check("A selection was not retired early", registry.isSelectionLeaseOpen(old.grantID))
                h.store.closeScopedRead(old)
                r.equal("A retains its existing selection", old.grant.activeLeaseCount, 1)
                await h.store.releaseRoot()
                r.equal("explicit release closes A", old.grant.activeLeaseCount, 0)
                r.equal("all readers drain", await h.store.activeReaderCount, 0)
            } catch { r.check("early candidate rejection", false, String(describing: error)) }
            await h.store.releaseRoot()
        },
        TCCase(id: "S446Q", title: "A late sequence document from A cannot create or replace B metadata") { r in
            guard let h = await StorageHarness.make(name: "s446-sequence-authority") else {
                r.check("initial root", false); return
            }
            do {
                let sequence = SequenceID()
                let old = SequenceDocument(sequenceID: sequence, libraryID: h.libraryID, kind: .interval,
                    plannedCount: 1, sourcePlan: [], intervalSeconds: 1, baseline: nil, startedAtUTC: StorageFixture.fixedDate)
                r.check("old document is valid", SequenceDocumentSemanticValidator().validate(old).isEmpty)
                try await h.store.writeSequenceDocument(old)
                let relative = LibraryLayout.metadataSequencePath(for: sequence)
                let oldBytes = h.memory.fileBytes(at: h.root.appendingPathComponent(relative))
                r.check("A current document actually persists", oldBytes != nil)

                let next = h.root.deletingLastPathComponent().appendingPathComponent("library-b", isDirectory: true)
                try h.memory.createDirectory(at: next, withIntermediateDirectories: true)
                guard case .initialized(let nextID, _) = await h.store.selectRoot(from: next) else {
                    r.check("B selected", false); await h.store.releaseRoot(); return
                }
                r.notEqual("B has its own library authority", nextID, h.libraryID)
                let absentSequence = SequenceID()
                let foreignAbsent = SequenceDocument(sequenceID: absentSequence, libraryID: h.libraryID, kind: .interval,
                    plannedCount: 1, sourcePlan: [], intervalSeconds: 1, baseline: nil, startedAtUTC: StorageFixture.fixedDate)
                do {
                    try await h.store.writeSequenceDocument(foreignAbsent)
                    r.check("foreign metadata creation refused", false)
                } catch let failure as CaptureFailure {
                    r.equal("foreign creation has typed failure", failure.kind.stableCode, "metadataInvalid")
                }
                r.check("foreign sequence path remains absent", !h.memory.fileExists(at:
                    next.appendingPathComponent(LibraryLayout.metadataSequencePath(for: absentSequence))))

                var current = SequenceDocument(sequenceID: sequence, libraryID: nextID, kind: .interval,
                    plannedCount: 2, sourcePlan: [], intervalSeconds: 2, baseline: nil, startedAtUTC: StorageFixture.fixedDate)
                try await h.store.writeSequenceDocument(current)
                let currentURL = next.appendingPathComponent(relative)
                let currentBytes = h.memory.fileBytes(at: currentURL)
                r.check("same-library positive persists", currentBytes != nil && currentBytes != oldBytes)
                do {
                    try await h.store.writeSequenceDocument(old)
                    r.check("foreign replacement refused", false)
                } catch let failure as CaptureFailure {
                    r.equal("foreign replacement has typed failure", failure.kind.stableCode, "metadataInvalid")
                }
                r.equal("B document bytes remain exact", h.memory.fileBytes(at: currentURL), currentBytes)
                r.equal("B document retains its library identity", try await h.store.readSequenceDocument(sequence).libraryID, nextID.rawValue)

                guard case .opened = await h.store.selectRoot(from: next) else {
                    r.check("same-library reselect", false); await h.store.releaseRoot(); return
                }
                current.intervalSeconds = 3
                try await h.store.writeSequenceDocument(current)
                r.equal("a fresh current grant still permits its own update", try await h.store.readSequenceDocument(sequence).intervalSeconds, 3)
                let latestBytes = h.memory.fileBytes(at: currentURL)
                h.memory.setBytes(Data("{\"schemaVersion\":\(truongCamSupportedSchemaVersion + 1),\"future\":true}".utf8),
                                  at: next.appendingPathComponent(LibraryLayout.libraryManifestName))
                _ = await h.store.selectRoot(from: next)
                do {
                    try await h.store.writeSequenceDocument(current)
                    r.check("read-only sequence update refused", false)
                } catch let failure as CaptureFailure {
                    r.equal("read-only write has typed failure", failure.kind.stableCode, "folderUnavailable")
                }
                r.equal("read-only selection preserves B document bytes", h.memory.fileBytes(at: currentURL), latestBytes)
                r.equal("original A metadata remains unchanged", h.memory.fileBytes(at: h.root.appendingPathComponent(relative)), oldBytes)
            } catch { r.check("sequence write authority", false, String(describing: error)) }
            await h.store.releaseRoot()
        }
    ])
}
