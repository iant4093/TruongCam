import Foundation
import Synchronization
#if canImport(XCTest)
@testable import TruongCam
#endif

/// Replaces a file after one owned accessor finishes and before the next
/// accessor begins. This models a separate coordinated writer, not mutation
/// inside an accessor or an assumed physical-provider defect.
private final class FifthExportCoordinator: CoordinatedFileMutator, @unchecked Sendable {
    private struct Action: Sendable {
        let url: URL
        let body: @Sendable () throws -> Void
    }
    private let pending = Mutex<Action?>(nil)
    private let fired = Mutex(0)
    var fireCount: Int { fired.withLock { $0 } }
    func arm(after url: URL, _ body: @escaping @Sendable () throws -> Void) {
        pending.withLock { $0 = Action(url: url, body: body) }
    }
    func coordinatedWrite<T>(at url: URL, _ body: (URL) throws -> T) throws -> T { try body(url) }
    func coordinatedRead<T>(at url: URL, _ body: (URL) throws -> T) throws -> T {
        let value = try body(url)
        let action = pending.withLock { current -> Action? in
            guard current?.url == url else { return nil }
            let result = current; current = nil; return result
        }
        if let action { fired.withLock { $0 += 1 }; try action.body() }
        return value
    }
}

private struct FifthStorageFixture: Sendable {
    let base: URL
    let root: URL
    let temporary: URL
    let store: LibraryStore
    let coordinator: FifthExportCoordinator
    let libraryID: LibraryID

    static func make(_ name: String) async throws -> FifthStorageFixture {
        let base = StorageFixture.temporaryDirectory("fifth-storage-" + name)
        let root = base.appendingPathComponent("library", isDirectory: true)
        let temporary = base.appendingPathComponent("exports", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let coordinator = FifthExportCoordinator()
        let store = LibraryStore(adapter: SystemFileSystemAdapter(), coordinator: coordinator,
            wallClock: StorageFixture.fixedClock(), supportDirectory: base.appendingPathComponent("support"),
            temporaryDirectory: temporary, ownedContainerURLs: [],
            bookmarkStore: InMemoryRootBookmarkStore(), scopeDriver: ScriptedSecurityScopeDriver(grants: [true]),
            capacityReserveBytes: 0,
            injectedLocalityVerdict: .userConfirmedLocalDestination(evidence: "Isolated synthetic file fixtures only."))
        guard case .initialized(let id, _) = await store.selectRoot(from: root) else {
            throw CocoaError(.fileReadUnknown)
        }
        return FifthStorageFixture(base: base, root: root, temporary: temporary,
                                   store: store, coordinator: coordinator, libraryID: id)
    }

    func exportFilesAreAbsent() -> Bool {
        let directory = temporary.appendingPathComponent("TruongCamExport", isDirectory: true)
        guard FileManager.default.fileExists(atPath: directory.path) else { return true }
        return (try? FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty) == true
    }

    func close() async {
        await store.releaseRoot()
        StorageFixture.removeDirectory(base)
    }
}

/// Actual isolated temporary files, synthetic TIFF payloads, real hashing and
/// the shipping store export path. No real capture or Photos import occurs.
enum FifthStorageReviewSuite {
    static let suite = TCSuite(id: "FifthStorageReview", title: "Metadata ownership at export copy time", cases: [
        TCCase(id: "S547E", title: "A separately replaced sidecar cannot accompany the already copied original") { r in
            for change in ["library", "capture", "path", "checksum", "settings"] {
                var fixture: FifthStorageFixture?
                do {
                    let h = try await FifthStorageFixture.make(change); fixture = h
                    let capture = CaptureID(), bytes = StorageFixture.rawBytes(filler: 0x47)
                    let handle = try await h.store.stageSource(bytes: bytes,
                        metadata: StorageFixture.metadata(captureID: capture, libraryID: h.libraryID))
                    let receipt = try await h.store.commit(handle: handle)
                    let original = h.root.appendingPathComponent(receipt.relativeOriginalPath)
                    let metadata = h.root.appendingPathComponent(receipt.relativeSidecarPath)
                    let initial = try Data(contentsOf: metadata)
                    var sidecar = try PortableJSONReader().decode(SourceSidecar.self, from: initial,
                        limitBytes: MetadataBounds.maxSourceSidecarUTF8Bytes)
                    switch change {
                    case "library": sidecar.libraryID = UUID()
                    case "capture":
                        sidecar.captureID = UUID()
                        sidecar.relativeOriginalPath = (receipt.relativeOriginalPath as NSString).deletingLastPathComponent
                            + "/" + LibraryLayout.originalFileName(for: CaptureID(sidecar.captureID))
                    case "path": sidecar.relativeOriginalPath = "originals/elsewhere/" + original.lastPathComponent
                    case "checksum": sidecar.sha256 = String(repeating: "a", count: 64)
                    default: sidecar.observed.iso = 200
                    }
                    r.check(change + " replacement is semantically valid", SourceSidecarSemanticValidator().validate(sidecar).isEmpty)
                    let replacement = StorageFixture.sidecarData(sidecar)
                    h.coordinator.arm(after: original) { try replacement.write(to: metadata, options: .atomic) }
                    do {
                        let unexpected = try await h.store.prepareOriginalExport(sourceIDs: [capture], includeSidecars: true)
                        r.check(change + " stale metadata export refused", false)
                        await h.store.discardExport(sessionID: unexpected.sessionID)
                    } catch let failure as CaptureFailure {
                        r.equal(change + " typed ownership failure", failure.kind.stableCode, "metadataInvalid")
                    }
                    r.equal(change + " mutation occurred only between read accessors", h.coordinator.fireCount, 1)
                    r.equal(change + " source bytes stay exact", try Data(contentsOf: original), bytes)
                    r.equal(change + " externally changed metadata is never overwritten", try Data(contentsOf: metadata), replacement)
                    r.check(change + " rejected batch disposes all owned copies", h.exportFilesAreAbsent())
                    r.equal(change + " rejected export drains reader scope", await h.store.activeReaderCount, 0)

                    try initial.write(to: metadata, options: .atomic)
                    let positive = try await h.store.prepareOriginalExport(sourceIDs: [capture], includeSidecars: true)
                    r.equal(change + " unchanged pair remains exportable", positive.fileURLs.count, 2)
                    r.equal(change + " positive original exact", try Data(contentsOf: positive.fileURLs.first { $0.pathExtension == "dng" }!), bytes)
                    r.equal(change + " positive metadata exact", try Data(contentsOf: positive.fileURLs.first { $0.pathExtension == "json" }!), initial)
                    await h.store.discardExport(sessionID: positive.sessionID)
                    r.check(change + " positive copies disposed by exact session", h.exportFilesAreAbsent())
                } catch { r.check(change + " export ownership fixture", false, String(describing: error)) }
                if let fixture { await fixture.close() }
            }
        },
        TCCase(id: "S547U", title: "Unknown metadata fields remain unchanged and missing-source consent stays exact") { r in
            var fixture: FifthStorageFixture?
            do {
                let h = try await FifthStorageFixture.make("unknown-fields"); fixture = h
                let capture = CaptureID(), missing = CaptureID(), bytes = StorageFixture.rawBytes(filler: 0x29)
                let handle = try await h.store.stageSource(bytes: bytes,
                    metadata: StorageFixture.metadata(captureID: capture, libraryID: h.libraryID))
                let receipt = try await h.store.commit(handle: handle)
                let original = h.root.appendingPathComponent(receipt.relativeOriginalPath)
                let metadata = h.root.appendingPathComponent(receipt.relativeSidecarPath)
                let initial = try Data(contentsOf: metadata)
                var object = try JSONSerialization.jsonObject(with: initial) as! [String: Any]
                object["futureOptionalValue"] = ["mustRemain": "byte exact"]
                let extra = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
                h.coordinator.arm(after: original) { try extra.write(to: metadata, options: .atomic) }
                let session = try await h.store.prepareOriginalExport(sourceIDs: [capture, capture, missing], includeSidecars: true)
                r.equal("one original and its metadata, without duplicate selection", session.fileURLs.count, 2)
                r.equal("missing item is reported exactly once", session.missingItems.count, 1)
                r.check("exact missing capture is named", session.missingItems.first?.contains(missing.description) == true)
                r.equal("unknown fields preserve exact current metadata bytes", try Data(contentsOf: session.fileURLs.first { $0.pathExtension == "json" }!), extra)
                r.equal("original export remains byte exact", try Data(contentsOf: session.fileURLs.first { $0.pathExtension == "dng" }!), bytes)
                r.equal("total size counts only the exact prepared pair", session.totalByteCount, Int64(bytes.count + extra.count))
                r.equal("unknown field update reached coordinated boundary", h.coordinator.fireCount, 1)
                r.equal("source metadata stays untouched by export", try Data(contentsOf: metadata), extra)
                r.equal("partial prepared export balances scope", await h.store.activeReaderCount, 0)
                await h.store.discardExport(sessionID: session.sessionID)
                r.check("partial session cleanup is exact", h.exportFilesAreAbsent())
            } catch { r.check("unknown-field and partial positive", false, String(describing: error)) }
            if let fixture { await fixture.close() }
        },
        TCCase(id: "S547I", title: "Invalid metadata is not exported as app authority while the original-only recovery path remains usable") { r in
            var fixture: FifthStorageFixture?
            do {
                let h = try await FifthStorageFixture.make("invalid-metadata"); fixture = h
                let capture = CaptureID(), bytes = StorageFixture.rawBytes(filler: 0x32)
                let handle = try await h.store.stageSource(bytes: bytes,
                    metadata: StorageFixture.metadata(captureID: capture, libraryID: h.libraryID))
                let receipt = try await h.store.commit(handle: handle)
                let original = h.root.appendingPathComponent(receipt.relativeOriginalPath)
                let metadata = h.root.appendingPathComponent(receipt.relativeSidecarPath)
                let malformed = Data("{not app metadata}".utf8)
                try malformed.write(to: metadata, options: .atomic)
                do {
                    let unexpected = try await h.store.prepareOriginalExport(sourceIDs: [capture], includeSidecars: true)
                    r.check("invalid app metadata export refused", false)
                    await h.store.discardExport(sessionID: unexpected.sessionID)
                } catch let failure as CaptureFailure {
                    r.equal("invalid metadata typed failure", failure.kind.stableCode, "metadataInvalid")
                }
                r.check("invalid metadata export cleans staged copies", h.exportFilesAreAbsent())
                let session = try await h.store.prepareOriginalExport(sourceIDs: [capture], includeSidecars: false)
                r.equal("recovered original-only export remains usable", session.fileURLs.count, 1)
                r.equal("recovered exact original", try Data(contentsOf: session.fileURLs[0]), bytes)
                r.equal("invalid user metadata is preserved", try Data(contentsOf: metadata), malformed)
                r.equal("source original is preserved", try Data(contentsOf: original), bytes)
                r.equal("reader scopes balance", await h.store.activeReaderCount, 0)
                await h.store.discardExport(sessionID: session.sessionID)
            } catch { r.check("invalid metadata recovery", false, String(describing: error)) }
            if let fixture { await fixture.close() }
        }
    ])
}
