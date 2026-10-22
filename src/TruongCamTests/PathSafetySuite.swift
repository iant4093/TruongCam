import Foundation

// Native test bundles read the app's real types through the module; the
// standalone verifier compiles the app sources into the same executable and
// therefore cannot import a module. XCTest is only available in the native
// bundle, so it gates the import.
#if canImport(XCTest)
@testable import TruongCam
#endif


// TEST_PLAN.md T18 (path traversal / NUL / symlink / oversized) and the
// CONTRACTS.md path bounds.

enum PathSafetySuite {
    private static func privateAliasFixture(_ name: String) -> URL {
        let temporary = StorageFixture.temporaryDirectory(name)
        let path = temporary.path.hasPrefix("/var/") ? "/private" + temporary.path : temporary.path
        return URL(fileURLWithPath: path, isDirectory: true)
    }

    static let suite = TCSuite(
        id: "T18",
        title: "Portable path validation and containment",
        cases: [
            TCCase(id: "T18a", title: "Traversal, absolute, backslash and NUL paths are rejected") { r in
                func rejects(_ path: String, _ label: String) {
                    var threw = false
                    do { try PathSafety.validateRelativePath(path) } catch { threw = true }
                    r.check("rejects \(label)", threw, "path was accepted: \(path)")
                }
                func accepts(_ path: String, _ label: String) {
                    do {
                        try PathSafety.validateRelativePath(path)
                        r.check("accepts \(label)", true)
                    } catch {
                        r.check("accepts \(label)", false, "\(path) -> \(error)")
                    }
                }

                rejects("", "empty path")
                rejects("/etc/passwd", "absolute path")
                rejects("../outside.dng", "leading parent traversal")
                rejects("originals/../../outside.dng", "embedded parent traversal")
                rejects("originals/2026/./10/06/file.dng", "single-dot component")
                rejects("originals\\2026\\file.dng", "backslash separator")
                rejects("originals/2026/file\u{0}.dng", "NUL byte")
                rejects("originals/2026/12:00.dng", "colon in filename")
                rejects("~/Documents/file.dng", "tilde prefix")
                rejects("file:///tmp/x.dng", "file URL")
                rejects(String(repeating: "a", count: 2000), "over-long path")

                accepts("originals/2026/10/06/TC_abc.dng", "normal dated original")
                accepts("library.json", "root manifest")
                accepts("sequences/SEQ_abc.json", "sequence document")
                accepts(".staging/txn/source.dng.partial", "internal staging partial")
            },

            TCCase(id: "T18b", title: "Resolved paths cannot escape the selected root") { r in
                let root = URL(fileURLWithPath: "/tmp/truongcam-root", isDirectory: true)
                let inside = try? PathSafety.resolve("originals/2026/10/06/TC_a.dng", under: root)
                r.check("valid path resolves under root",
                        inside?.path.hasPrefix("/tmp/truongcam-root/") == true)

                // A standardized URL that walks up must be caught by containment
                // even if string validation were bypassed.
                var threw = false
                do {
                    _ = try PathSafety.assertContained(
                        root.appendingPathComponent("originals/../../escape.dng"),
                        in: root, relativePath: "originals/../../escape.dng")
                } catch { threw = true }
                r.check("escaping resolution rejected", threw)

                var siblingThrew = false
                do {
                    _ = try PathSafety.assertContained(
                        URL(fileURLWithPath: "/tmp/truongcam-root-evil/x.dng"),
                        in: root, relativePath: "../truongcam-root-evil/x.dng")
                } catch { siblingThrew = true }
                r.check("sibling-prefix path rejected", siblingThrew)
            },

            TCCase(id: "T18e", title: "Existing private-var root accepts a not-yet-created dated child without rewriting the grant") { r in
                let base = privateAliasFixture("new-destination")
                defer { StorageFixture.removeDirectory(base) }
                do {
                    try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
                    let path = "originals/2026/10/14/TC_probe.dng"
                    let expected = base.appendingPathComponent(path, isDirectory: false)
                    r.check("new dated destination does not yet exist", !FileManager.default.fileExists(atPath: expected.path))
                    let actual = try PathSafety.resolve(path, under: base)
                    r.equal("granted URL spelling preserved", actual.absoluteString, expected.absoluteString)
                    try FileManager.default.createDirectory(at: actual.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try Data([1, 2, 3]).write(to: actual)
                    r.equal("same URL before and after publication", try PathSafety.resolve(path, under: base).absoluteString, expected.absoluteString)
                    r.equal("bytes readable through granted URL", try Data(contentsOf: actual), Data([1, 2, 3]))
                } catch { r.check("new aliased destination resolves and writes", false, "\(error)") }
            },
            TCCase(id: "T18f", title: "Existing and dangling symlinks are refused without weakening containment") { r in
                let base = StorageFixture.temporaryDirectory("save-symlink")
                let root = base.appendingPathComponent("library", isDirectory: true)
                let outside = base.appendingPathComponent("outside", isDirectory: true)
                defer { StorageFixture.removeDirectory(base) }
                do {
                    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
                    try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
                    for (name, target) in [("escape", outside), ("dangling", outside.appendingPathComponent("missing")), ("internal", root)] {
                        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent(name), withDestinationURL: target)
                        do {
                            _ = try PathSafety.resolve("\(name)/file.dng", under: root)
                            r.check("rejects \(name) symlink", false)
                        } catch let error as PathSafetyError {
                            r.equal("rejects \(name) symlink", error, .symlinkEscape("\(name)/file.dng"))
                        }
                    }
                    var siblingRejected = false
                    do {
                        _ = try PathSafety.assertContained(root.appendingPathComponent("../library-evil/file.dng"), in: root, relativePath: "../library-evil/file.dng")
                    } catch { siblingRejected = true }
                    r.check("dot traversal and sibling prefix still refused", siblingRejected)
                } catch { r.check("symlink fixture", false, "\(error)") }
            },
            TCCase(id: "T18g", title: "Real filesystem saves a fresh dated original, retains failed staging and retries without duplicate") { r in
                let base = privateAliasFixture("connected-save")
                let root = base.appendingPathComponent("library", isDirectory: true)
                let support = base.appendingPathComponent("support", isDirectory: true)
                defer { StorageFixture.removeDirectory(base) }
                let store = LibraryStore(adapter: SystemFileSystemAdapter(), coordinator: DirectFileCoordinatorMutator(),
                    wallClock: StorageFixture.fixedClock(), supportDirectory: support,
                    temporaryDirectory: base.appendingPathComponent("temporary"), ownedContainerURLs: [],
                    bookmarkStore: InMemoryRootBookmarkStore(), scopeDriver: ScriptedSecurityScopeDriver(grants: [true]),
                    capacityReserveBytes: 0,
                    injectedLocalityVerdict: .userConfirmedLocalDestination(evidence: "isolated Mac filesystem fixture"))
                do {
                    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
                    guard case .initialized(let libraryID, _) = await store.selectRoot(from: root) else {
                        r.check("isolated library selected", false); return
                    }
                    r.equal("store preserves exact granted root", store.grantedRootURL?.absoluteString, root.absoluteString)
                    let bytes = StorageFixture.rawBytes()
                    let first = try await store.stageSource(bytes: bytes,
                        metadata: StorageFixture.metadata(captureID: CaptureID(), libraryID: libraryID))
                    let receipt = try await store.commit(handle: first)
                    r.equal("final original exact bytes", try Data(contentsOf: root.appendingPathComponent(receipt.relativeOriginalPath)), bytes)
                    r.check("completion sidecar exists", FileManager.default.fileExists(atPath: root.appendingPathComponent(receipt.relativeSidecarPath).path))
                    let second = try await store.stageSource(bytes: bytes,
                        metadata: StorageFixture.metadata(captureID: CaptureID(), libraryID: libraryID))
                    let blocked = root.appendingPathComponent(second.intendedRelativeOriginalPath)
                    let outside = base.appendingPathComponent("outside.dng")
                    try bytes.write(to: outside)
                    try FileManager.default.createSymbolicLink(at: blocked, withDestinationURL: outside)
                    for retry in [false, true] {
                        do {
                            if retry { _ = try await store.retry(transactionID: second.transactionID) }
                            else { _ = try await store.commit(handle: second) }
                            r.check("symlink publication refused (retry=\(retry))", false)
                        } catch let failure as CaptureFailure {
                            r.equal("failure reports retained internal original (retry=\(retry))", failure.retainedSourceStatus,
                                .durableInternalStaging(relativePath: second.pendingRelativePath))
                            r.check("failure identifies symlink (retry=\(retry))", failure.description.contains("symlink"))
                        }
                    }
                    r.equal("outside bytes untouched", try Data(contentsOf: outside), bytes)
                    r.equal("pending source exact bytes", try Data(contentsOf: support.appendingPathComponent(second.pendingRelativePath)), bytes)
                    try FileManager.default.removeItem(at: blocked)
                    let recovered = try await store.retry(transactionID: second.transactionID)
                    r.equal("retry keeps original capture identity", recovered.captureID, second.captureID)
                    r.equal("retry publishes exact bytes", try Data(contentsOf: blocked), bytes)
                    let repeated = try await store.commit(handle: second)
                    r.equal("repeated commit is idempotent", repeated.captureID, second.captureID)
                    let read = try await store.readOriginal(relativePath: recovered.relativeOriginalPath) { try Data(contentsOf: $0) }
                    r.equal("scoped production read returns exact bytes", read, bytes)
                    r.equal("no pending sources after verification", await store.pendingOriginals().count, 0)
                } catch { r.check("connected filesystem commit/retry/read", false, "\(error)") }
                await store.releaseRoot()
            },
            TCCase(id: "T18c", title: "Component and length bounds are enforced") { r in
                let long = (0..<40).map { "c\($0)" }.joined(separator: "/")
                var threw = false
                do { try PathSafety.validateRelativePath(long) } catch { threw = true }
                r.check("component count bounded", threw)

                var byteThrew = false
                do { try PathSafety.validateRelativePath("a/" + String(repeating: "b", count: 1030)) } catch { byteThrew = true }
                r.check("UTF-8 byte bound enforced", byteThrew)

                // Bounds are constants shared with the parser.
                r.equal("path byte bound", MetadataBounds.maxRelativePathUTF8Bytes, 1024)
                r.equal("source sidecar bound", MetadataBounds.maxSourceSidecarUTF8Bytes, 262_144)
                r.equal("sequence bound", MetadataBounds.maxSequenceJSONUTF8Bytes, 2_097_152)
                r.equal("scan batch bound", MetadataBounds.maxScanBatchEntries, 200)
                r.equal("index page bound", MetadataBounds.maxIndexPageSize, 60)
                r.equal("sequence source bound", MetadataBounds.maxSequenceSources, 999)
            },

            TCCase(id: "T18d", title: "Undated filename and relative path construction is deterministic") { r in
                let captureID = CaptureID(UUID(uuidString: "11111111-2222-3333-4444-555555555555")!)
                r.equal("original filename",
                        LibraryLayout.originalFileName(for: captureID),
                        "TC_11111111-2222-3333-4444-555555555555.dng")
                r.equal("sidecar filename",
                        LibraryLayout.sidecarFileName(for: captureID),
                        "TC_11111111-2222-3333-4444-555555555555.json")

                var calendar = Calendar(identifier: .gregorian)
                calendar.timeZone = TimeZone(identifier: "UTC")!
                let date = Date(timeIntervalSince1970: 1_790_000_000) // 2026-09-22T...Z
                let path = LibraryLayout.relativeOriginalPath(
                    for: captureID, capturedAt: date, calendar: calendar)
                r.check("path is under originals", path.hasPrefix("originals/"))
                r.check("path ends with the DNG name", path.hasSuffix("TC_11111111-2222-3333-4444-555555555555.dng"))
                try? PathSafety.validateRelativePath(path)
                r.equal("sidecar sits alongside",
                        LibraryLayout.relativeSidecarPath(alongside: path),
                        String(path.dropLast(4)) + ".json")

                let sequenceID = SequenceID(UUID(uuidString: "99999999-8888-7777-6666-555555555555")!)
                r.equal("sequence document path",
                        LibraryLayout.relativeSequencePath(for: sequenceID),
                        "sequences/SEQ_99999999-8888-7777-6666-555555555555.json")
            },
        ])
}
