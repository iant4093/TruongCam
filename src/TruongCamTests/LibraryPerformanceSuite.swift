import Foundation
import Synchronization
#if canImport(XCTest)
@testable import TruongCam
#endif

/// A bounded, explicitly released stand-in for cold native decoding. Its wait
/// occurs on the shipping read owner, never on the test's cooperative executor.
final class HeldLibraryDecode: @unchecked Sendable {
    private let gate = DispatchSemaphore(value: 0)
    private let state = Mutex((entered: false, released: false, onMain: false, timedOut: false))
    var didEnter: Bool { state.withLock { $0.entered } }
    var onMain: Bool { state.withLock { $0.onMain } }
    var timedOut: Bool { state.withLock { $0.timedOut } }
    func hold() {
        state.withLock { $0.entered = true; $0.onMain = Thread.isMainThread }
        if gate.wait(timeout: .now() + 5) != .success { state.withLock { $0.timedOut = true } }
    }
    func release() {
        let first = state.withLock { value in
            guard !value.released else { return false }
            value.released = true
            return true
        }
        if first { gate.signal() }
    }
}

final class ObservedLibraryReadCoordinator: CoordinatedFileMutator, @unchecked Sendable {
    private let active = Mutex(0)
    private let redirect = Mutex<URL?>(nil)
    var activeReads: Int { active.withLock { $0 } }
    func redirectReads(to url: URL) { redirect.withLock { $0 = url } }
    func coordinatedRead<T>(at url: URL, _ body: (URL) throws -> T) throws -> T {
        active.withLock { $0 += 1 }
        defer { active.withLock { $0 -= 1 } }
        return try body(redirect.withLock { $0 } ?? url)
    }
    func coordinatedWrite<T>(at url: URL, _ body: (URL) throws -> T) throws -> T { try body(url) }
}

/// Reads no real original. Returns literal RGBA values through the same scoped
/// read and publication paths used by the grid, with optional controlled delay.
final class LibraryPreviewFixture: ThumbnailProviding, @unchecked Sendable {
    let hold: HeldLibraryDecode?
    private let requests = Mutex(0)
    private let recordedIdentities = Mutex<[String]>([])
    var count: Int { requests.withLock { $0 } }
    var identities: [String] { recordedIdentities.withLock { $0 } }
    init(hold: HeldLibraryDecode? = nil) { self.hold = hold }
    private func produce(identity: String) -> ThumbnailOutcome {
        recordedIdentities.withLock { $0.append(identity) }
        let count = requests.withLock { $0 += 1; return $0 }
        hold?.hold()
        return .image(rgbaBytes: [UInt8(count % 255), 0, 0, 255], width: 1, height: 1,
                      pixelFingerprint: "fixture-\(count)")
    }
    func thumbnail(identity: String, relativePath: String, fingerprint: String?, targetLongEdge: Int) async -> ThumbnailOutcome { produce(identity: identity) }
    func viewerPreview(identity: String, relativePath: String, boundLongEdge: Int) async -> ThumbnailOutcome { produce(identity: identity) }
    func thumbnail(atAbsoluteURL url: URL, identity: String, fingerprint: String?, targetLongEdge: Int) async -> ThumbnailOutcome { produce(identity: identity) }
    func viewerPreview(atAbsoluteURL url: URL, identity: String, boundLongEdge: Int) async -> ThumbnailOutcome { produce(identity: identity) }
    func thumbnailSynchronously(atAbsoluteURL url: URL, identity: String, fingerprint: String?, targetLongEdge: Int) -> ThumbnailOutcome { produce(identity: identity) }
    func viewerPreviewSynchronously(atAbsoluteURL url: URL, identity: String, boundLongEdge: Int) -> ThumbnailOutcome { produce(identity: identity) }
    func clearMemoryCache() async {}
}

enum LibraryPerformanceSuite {
    static func waitUntil(_ predicate: @escaping @Sendable () -> Bool) async -> Bool {
        // This waits for fixture/worker readiness, not a latency benchmark.
        // Hosted Simulator scheduling can exceed one second. Keep the wait
        // bounded below HeldLibraryDecode's five-second deadlock watchdog;
        // assertions still verify the actual hold, ownership and publication.
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while !predicate(), !Task.isCancelled, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(2))
        }
        return predicate()
    }
    static let suite = TCSuite(id: "LibraryPerformance", title: "Bounded cold library reads and current-root publication", cases: [
        TCCase(id: "LP41", title: "Idle real-thumbnail preparation bounds the first page and cancellation releases queued reads") { r in
            guard let h = await StorageHarness.make(name: "lp41-prefetch") else { r.check("fixture", false); return }
            let cards = (0..<12).map { i in LibrarySourceCard(captureID: CaptureID(), libraryID: h.libraryID,
                relativeOriginalPath: "originals/preview-\(i).dng", capturedAtUTC: StorageFixture.fixedDate,
                capturedAtProvenance: .requestTimestamp, availability: .local, classification: .verifiedOriginal,
                rawDimensions: nil, byteCount: nil, sequenceID: nil, sequenceIndex: nil, sequenceKind: nil,
                isTruongCamCapture: true, modificationFingerprint: "fixture") }
            do {
                let index = InMemoryLibraryIndex(); try await index.reset(libraryID: h.libraryID, generation: h.generation)
                try await index.upsert(scanned: cards)
                let model = await LibraryViewModel(index: index, store: h.store), provider = LibraryPreviewFixture()
                await MainActor.run { model.thumbnailSource = .scoped(store: h.store, thumbnails: provider) }
                await model.loadFirstPage(); await model.prepareFirstThumbnails()
                r.equal("only first visible page is primed", provider.count, 9)
                r.equal("bounded visible source list", await model.firstThumbnailSources.count, 9)
                let hold = HeldLibraryDecode(); defer { hold.release() }
                let heldProvider = LibraryPreviewFixture(hold: hold)
                await MainActor.run { model.thumbnailSource = .scoped(store: h.store, thumbnails: heldProvider) }
                let preparation = Task { await model.prepareFirstThumbnails() }
                r.check("owned real read path entered", await waitUntil { hold.didEnter })
                r.check("first decode stays off main", !hold.onMain)
                preparation.cancel(); await h.store.releaseRoot(); hold.release(); await preparation.value
                r.equal("cancelled/root-changed work does not decode remainder", heldProvider.count, 1)
                r.equal("read leases drain", await h.store.activeReaderCount, 0)
                r.check("test did not time out", !hold.timedOut)
            } catch { r.check("thumbnail preparation", false, String(describing: error)) }
        },
        TCCase(id: "LP01", title: "A held cold decode leaves the store responsive and owns scope through accessor completion") { r in
            let coordinator = ObservedLibraryReadCoordinator()
            guard let h = await StorageHarness.make(name: "cold-read-responsive", coordinator: coordinator) else { r.check("fixture", false); return }
            do {
                let diagnosticLease = try await h.store.openScopedRead()
                let grant = diagnosticLease.grant
                h.store.closeScopedRead(diagnosticLease)
                let hold = HeldLibraryDecode(); defer { hold.release() }
                let read = Task { try await h.store.readOriginal(relativePath: "originals/held.dng") { url in
                    hold.hold()
                    return (url.path, coordinator.activeReads)
                } }
                r.check("real read accessor entered", await waitUntil { hold.didEnter })
                r.check("decode is off main", !hold.onMain)
                r.equal("accessor remains active while held", coordinator.activeReads, 1)
                r.equal("selection plus reader are held", grant.activeLeaseCount, 2)
                let releasedRoot = Mutex(false)
                let command = Task { _ = await h.store.pendingOriginals(); await h.store.releaseRoot(); releasedRoot.withLock { $0 = true } }
                r.check("storage command and root release finish before decode", await waitUntil { releasedRoot.withLock { $0 } })
                r.equal("release does not revoke active reader or deferred selection", grant.activeLeaseCount, 2)
                hold.release()
                let result = try await read.value
                await command.value
                r.check("read stays bound to original root", result.0.hasPrefix(h.root.path + "/"))
                r.equal("body completed before accessor returned", result.1, 1)
                r.equal("accessor completed", coordinator.activeReads, 0)
                r.equal("exact old grant balanced after drain", grant.activeLeaseCount, 0)
                r.equal("all reader accounting balanced", await h.store.activeReaderCount, 0)
                r.check("controlled read never timed out", !hold.timedOut)
            } catch { r.check("held scoped read", false, String(describing: error)) }
        },
        TCCase(id: "LP02", title: "Cancelled queued tiles skip decode and all reader leases drain exactly once") { r in
            guard let h = await StorageHarness.make(name: "cold-read-cancel") else { r.check("fixture", false); return }
            let hold = HeldLibraryDecode(); defer { hold.release() }
            let callbacks = Mutex(0)
            do {
                let registry = await h.store.scopeRegistryForDiagnostics
                let read = Task { try await h.store.readOriginal(relativePath: "originals/held.dng") { _ in hold.hold(); return 7 } }
                r.check("first read entered", await waitUntil { hold.didEnter })
                let queued = (0..<12).map { index in Task {
                    try await h.store.readOriginal(relativePath: "originals/queued-\(index).dng") { _ in callbacks.withLock { $0 += 1 }; return index }
                } }
                r.check("all queued requests suspend instead of blocking actor", await waitUntil { registry.totalActiveReaders == 13 })
                r.check("all obsolete requests reached the bounded owner", await waitUntil { h.store.queuedOriginalReadCount == 12 })
                r.equal("no parallel decode storm", callbacks.withLock { $0 }, 0)
                queued.forEach { $0.cancel() }
                hold.release()
                r.equal("running read completes intact", try await read.value, 7)
                var cancellations = 0
                for task in queued { do { _ = try await task.value } catch is CancellationError { cancellations += 1 } catch {} }
                r.equal("every obsolete request cancelled", cancellations, 12)
                r.equal("no obsolete body ran", callbacks.withLock { $0 }, 0)
                r.equal("no leaked reader", await h.store.activeReaderCount, 0)
                await h.store.releaseRoot()
                r.check("running read drained before its lease closed", !hold.timedOut)
            } catch { r.check("queued cancellation", false, String(describing: error)) }
        },
        TCCase(id: "LP03", title: "A thumbnail finishing after root release cannot publish an old-root image") { r in
            guard let h = await StorageHarness.make(name: "cold-read-stale") else { r.check("fixture", false); return }
            let card = StorageFixture.cards(count: 1, libraryID: h.libraryID, startingAt: StorageFixture.fixedDate)[0]
            let hold = HeldLibraryDecode(); defer { hold.release() }
            let provider = LibraryPreviewFixture(hold: hold)
            let source = GalleryThumbnailSource.scoped(store: h.store, thumbnails: provider)
            let request = Task { await source.load(card: card, targetLongEdge: 256) }
            r.check("native-boundary body entered", await waitUntil { hold.didEnter })
            await h.store.releaseRoot()
            hold.release()
            if case .unavailable = await request.value { r.check("old-root image refused", true) }
            else { r.check("old-root image refused", false) }
            _ = await source.load(card: card, targetLongEdge: 256)
            r.equal("unselected root does not touch decoder", provider.count, 1)
            r.equal("reader scope balanced", await h.store.activeReaderCount, 0)
        },
        TCCase(id: "LP04", title: "A queued path replaced with a symlink is rejected before its read body runs") { r in
            let base = StorageFixture.temporaryDirectory("queued-read-symlink-\(UUID().uuidString)")
            defer { StorageFixture.removeDirectory(base) }
            let root = base.appendingPathComponent("library", isDirectory: true)
            let coordinator = ObservedLibraryReadCoordinator()
            let hold = HeldLibraryDecode(); defer { hold.release() }
            let callback = Mutex(false)
            do {
                try FileManager.default.createDirectory(at: root.appendingPathComponent("originals"), withIntermediateDirectories: true)
                let queuedURL = root.appendingPathComponent("originals/queued.dng")
                let outside = base.appendingPathComponent("outside.dng")
                try Data([1]).write(to: queuedURL)
                try Data([99]).write(to: outside)
                guard let h = StorageHarness.makeRaw(name: "queued-symlink", root: root, coordinator: coordinator),
                      case .initialized = await h.store.selectRoot(from: root) else { r.check("fixture", false); return }
                let registry = await h.store.scopeRegistryForDiagnostics
                let first = Task { try await h.store.readOriginal(relativePath: "originals/held.dng") { _ in hold.hold(); return 1 } }
                r.check("first read entered", await waitUntil { hold.didEnter })
                let queued = Task { try await h.store.readOriginal(relativePath: "originals/queued.dng") { url in
                    callback.withLock { $0 = true }; return try Data(contentsOf: url)
                } }
                r.check("queued request acquired its reader lease", await waitUntil { registry.totalActiveReaders == 2 })
                r.check("request passed admission and is waiting on owner", await waitUntil { h.store.queuedOriginalReadCount == 1 })
                try FileManager.default.removeItem(at: queuedURL)
                try FileManager.default.createSymbolicLink(at: queuedURL, withDestinationURL: outside)
                hold.release()
                _ = try await first.value
                do { _ = try await queued.value; r.check("queued symlink rejected", false) }
                catch { r.check("queued symlink rejected", true) }
                r.check("outside bytes never read", !callback.withLock { $0 })
                r.equal("all leases balanced after rejection", await h.store.activeReaderCount, 0)
                coordinator.redirectReads(to: outside)
                do {
                    _ = try await h.store.readOriginal(relativePath: "originals/safe.dng") { _ in callback.withLock { $0 = true }; return 1 }
                    r.check("outside accessor redirection rejected", false)
                } catch { r.check("outside accessor redirection rejected", true) }
                r.check("redirected body never ran", !callback.withLock { $0 })
                await h.store.releaseRoot()
            } catch { r.check("queued symlink fixture", false, String(describing: error)) }
        },
        TCCase(id: "LP05", title: "Read-only folders with equal state and library identity still cannot exchange late pixels") { r in
            let bookmarks = InMemoryRootBookmarkStore()
            guard let h = await StorageHarness.make(name: "readonly-root-identity", bookmarks: bookmarks) else { r.check("fixture", false); return }
            let other = h.root.deletingLastPathComponent().appendingPathComponent("other-library", isDirectory: true)
            guard let manifest = h.memory.fileBytes(at: h.root.appendingPathComponent(LibraryLayout.libraryManifestName)) else { r.check("manifest", false); return }
            h.memory.setBytes(manifest, at: other.appendingPathComponent(LibraryLayout.libraryManifestName))
            bookmarks.saveConfirmedDestination(h.root); bookmarks.saveConfirmedLibraryID(LibraryID())
            _ = await h.store.selectRoot(from: h.root)
            let oldState = h.store.rootState
            guard case .readOnly = oldState else { r.check("first root read-only", false); return }
            let card = StorageFixture.cards(count: 1, libraryID: h.libraryID, startingAt: StorageFixture.fixedDate)[0]
            let hold = HeldLibraryDecode(); defer { hold.release() }
            let provider = LibraryPreviewFixture(hold: hold)
            let source = GalleryThumbnailSource.scoped(store: h.store, thumbnails: provider)
            let first = Task { await source.load(card: card, targetLongEdge: 256) }
            r.check("old-root accessor entered", await waitUntil { hold.didEnter })
            let queued = Task { await source.loadViewer(card: card, boundLongEdge: 2048) }
            r.check("viewer waits on owned queue", await waitUntil { h.store.queuedOriginalReadCount == 1 })
            bookmarks.saveConfirmedDestination(other); bookmarks.saveConfirmedLibraryID(LibraryID())
            _ = await h.store.selectRoot(from: other)
            r.equal("state alone cannot distinguish these roots", h.store.rootState, oldState)
            r.equal("new folder is selected", h.store.grantedRootURL?.path, other.path)
            hold.release()
            if case .unavailable = await first.value { r.check("old pixels rejected by root URL", true) }
            else { r.check("old pixels rejected by root URL", false) }
            if case .unavailable = await queued.value { r.check("queued old-root viewer refused", true) }
            else { r.check("queued old-root viewer refused", false) }
            r.equal("new-root data never decoded under old identity", provider.count, 1)
            r.equal("all leases balanced", await h.store.activeReaderCount, 0)
            r.check("no timeout masked actor blocking", !hold.timedOut)
            await h.store.releaseRoot()
        }
    ])
}
