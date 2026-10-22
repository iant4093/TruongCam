#if canImport(UIKit) && canImport(XCTest) && !TC_TESTKIT_STANDALONE
import CoreGraphics
import SwiftUI
import Synchronization
import UIKit
import XCTest
@testable import TruongCam

private final class CameraThumbnail59Provider: ThumbnailProviding, @unchecked Sendable {
    private let state = Mutex((count: 0, hold: Optional<HeldLibraryDecode>.none))
    var count: Int { state.withLock { $0.count } }
    func holdNext(_ hold: HeldLibraryDecode) { state.withLock { $0.hold = hold } }
    private func produce() -> ThumbnailOutcome {
        let (number, hold) = state.withLock { value in
            value.count += 1
            let hold = value.hold; value.hold = nil
            return (value.count, hold)
        }
        hold?.hold()
        let pixel: [UInt8] = number == 1 ? [230, 10, 10, 255] : [10, 10, 230, 255]
        return .image(rgbaBytes: pixel, width: 1, height: 1, pixelFingerprint: "camera59-\(number)")
    }
    func thumbnail(identity: String, relativePath: String, fingerprint: String?, targetLongEdge: Int) async -> ThumbnailOutcome { produce() }
    func viewerPreview(identity: String, relativePath: String, boundLongEdge: Int) async -> ThumbnailOutcome { produce() }
    func thumbnail(atAbsoluteURL url: URL, identity: String, fingerprint: String?, targetLongEdge: Int) async -> ThumbnailOutcome { produce() }
    func viewerPreview(atAbsoluteURL url: URL, identity: String, boundLongEdge: Int) async -> ThumbnailOutcome { produce() }
    func thumbnailSynchronously(atAbsoluteURL url: URL, identity: String, fingerprint: String?, targetLongEdge: Int) -> ThumbnailOutcome { produce() }
    func viewerPreviewSynchronously(atAbsoluteURL url: URL, identity: String, boundLongEdge: Int) -> ThumbnailOutcome { produce() }
    func clearMemoryCache() async {}
}

final class CameraThumbnail59NativeTests: XCTestCase {
    @MainActor private func request(_ card: LibrarySourceCard, h: StorageHarness, revision: Int = 1) -> ThumbnailModel.Request {
        ThumbnailModel.Request(card: card, sourceRevision: revision, rootState: h.store.rootState,
            targetLongEdge: CameraGalleryThumbnailModel.targetLongEdge, rootURL: h.store.grantedRootURL)
    }
    @MainActor private func context(_ source: GalleryThumbnailSource, retained: ThumbnailModel.Request?, suppressed: Bool = false,
                                    revision: Int = 1) -> CameraGalleryThumbnailModel.DisplayContext {
        CameraGalleryThumbnailModel.DisplayContext(source: source, sourceRevision: revision,
            retainedCard: retained?.card, requestIsTemporarilySuppressed: suppressed)
    }

    @MainActor func testHeldNewPhotoKeepsOnePriorSnapshotWithoutRelabelingAndPublishesOnlyItsActualReplacement() async throws {
        let fixture = await StorageHarness.make(name: "camera59-held"), h = try XCTUnwrap(fixture)
        let cards = StorageFixture.cards(count: 2, libraryID: h.libraryID, startingAt: StorageFixture.fixedDate)
        let first = request(cards[1], h: h), next = request(cards[0], h: h)
        let provider = CameraThumbnail59Provider(), source = GalleryThumbnailSource.scoped(store: h.store, thumbnails: provider)
        let model = CameraGalleryThumbnailModel()
        await model.load(request: first, source: source, enabled: true)
        let prior = try XCTUnwrap(model.image(for: first)), retained = context(source, retained: first)
        await model.load(request: next, source: source, enabled: false, context: retained)
        XCTAssertTrue(model.displayImage(for: next, context: retained) === prior)
        XCTAssertNil(model.image(for: next), "Retained pixels still identify the previous photo")
        XCTAssertEqual(provider.count, 1, "Camera priority cannot start optional decoding")
        let hold = HeldLibraryDecode(); defer { hold.release() }; provider.holdNext(hold)
        let work = Task { await model.load(request: next, source: source, enabled: true, context: retained) }
        let entered = await LibraryPerformanceSuite.waitUntil { hold.didEnter }; XCTAssertTrue(entered)
        XCTAssertFalse(hold.onMain)
        XCTAssertTrue(model.displayImage(for: next, context: retained) === prior, "Loading cannot flash the placeholder")
        XCTAssertEqual(model.completedRequest, first); XCTAssertNil(model.image(for: next))
        hold.release(); await work.value
        let current = try XCTUnwrap(model.image(for: next))
        XCTAssertFalse(current === prior)
        XCTAssertTrue(model.displayImage(for: next, context: context(source, retained: next)) === current)
        XCTAssertNil(model.image(for: first)); XCTAssertEqual(provider.count, 2)
        XCTAssertFalse(hold.timedOut)
    }

    @MainActor func testCancellationAndTemporarilySuppressedMutationKeepTheVerifiedPriorPhotoButEmptyAndDeletedMetadataClearIt() async throws {
        let fixture = await StorageHarness.make(name: "camera59-cancel"), h = try XCTUnwrap(fixture)
        let cards = StorageFixture.cards(count: 2, libraryID: h.libraryID, startingAt: StorageFixture.fixedDate)
        let first = request(cards[1], h: h), next = request(cards[0], h: h)
        let provider = CameraThumbnail59Provider(), source = GalleryThumbnailSource.scoped(store: h.store, thumbnails: provider)
        let model = CameraGalleryThumbnailModel()
        await model.load(request: first, source: source, enabled: true)
        let prior = try XCTUnwrap(model.image(for: first)), retained = context(source, retained: first)
        let hold = HeldLibraryDecode(); defer { hold.release() }; provider.holdNext(hold)
        let work = Task { await model.load(request: next, source: source, enabled: true, context: retained) }
        let entered = await LibraryPerformanceSuite.waitUntil { hold.didEnter }; XCTAssertTrue(entered)
        work.cancel(); model.cancel()
        let temporary = context(source, retained: first, suppressed: true)
        await model.load(request: nil, source: source, enabled: false, context: temporary)
        XCTAssertTrue(model.displayImage(for: nil, context: temporary) === prior)
        hold.release(); await work.value
        XCTAssertTrue(model.image(for: first) === prior); XCTAssertNil(model.image(for: next))
        XCTAssertNil(model.displayImage(for: nil, context: context(source, retained: nil, suppressed: true)), "Verified deletion removes retention authority immediately")
        await model.load(request: nil, source: source, enabled: false, context: context(source, retained: nil, suppressed: true))
        XCTAssertNil(model.completedRequest); XCTAssertNil(model.image(for: first))
        await model.load(request: first, source: source, enabled: true)
        XCTAssertNotNil(model.image(for: first)); XCTAssertEqual(provider.count, 3, "A cleared snapshot cannot resurrect the old ThumbnailModel cache entry")
        XCTAssertNil(model.displayImage(for: nil, context: context(source, retained: first)), "Actual empty-library nil is not a temporary pause")
        await model.load(request: nil, source: source, enabled: false)
        XCTAssertNil(model.completedRequest); XCTAssertFalse(hold.timedOut)
    }

    @MainActor func testRootReplacementAndUnavailableProviderRejectBothRetainedAndLateHeldPixels() async throws {
        let fixture = await StorageHarness.make(name: "camera59-old-root"), h = try XCTUnwrap(fixture)
        let replacementFixture = await StorageHarness.make(name: "camera59-new-root"), replacement = try XCTUnwrap(replacementFixture)
        let cards = StorageFixture.cards(count: 2, libraryID: h.libraryID, startingAt: StorageFixture.fixedDate)
        let first = request(cards[1], h: h), next = request(cards[0], h: h)
        let provider = CameraThumbnail59Provider(), source = GalleryThumbnailSource.scoped(store: h.store, thumbnails: provider)
        let model = CameraGalleryThumbnailModel()
        await model.load(request: first, source: source, enabled: true)
        let retained = context(source, retained: first)
        let hold = HeldLibraryDecode(); defer { hold.release() }; provider.holdNext(hold)
        let work = Task { await model.load(request: next, source: source, enabled: true, context: retained) }
        let entered = await LibraryPerformanceSuite.waitUntil { hold.didEnter }; XCTAssertTrue(entered)
        let newProvider = CameraThumbnail59Provider(), newSource = GalleryThumbnailSource.scoped(store: replacement.store, thumbnails: newProvider)
        let foreign = request(StorageFixture.cards(count: 1, libraryID: replacement.libraryID, startingAt: StorageFixture.fixedDate)[0], h: replacement)
        let replaced = context(newSource, retained: first)
        XCTAssertNil(model.displayImage(for: foreign, context: replaced), "A prior folder never supplies the new folder's shortcut")
        await model.load(request: foreign, source: newSource, enabled: false, context: replaced)
        await h.store.releaseRoot(); hold.release(); await work.value
        XCTAssertNil(model.completedRequest); XCTAssertNil(model.image(for: first))
        await model.load(request: foreign, source: newSource, enabled: true)
        XCTAssertNotNil(model.image(for: foreign))
        let unavailable = GalleryThumbnailSource.unavailable(reason: "Synthetic provider unavailable")
        let missing = context(unavailable, retained: foreign, suppressed: true)
        XCTAssertNil(model.displayImage(for: nil, context: missing))
        await model.load(request: nil, source: unavailable, enabled: false, context: missing)
        XCTAssertNil(model.completedRequest); XCTAssertNil(model.image(for: foreign))
        await model.load(request: foreign, source: newSource, enabled: true)
        XCTAssertEqual(newProvider.count, 2, "Provider recovery must revalidate rather than resurrect a cleared image")
        await replacement.store.releaseRoot()
        XCTAssertNil(model.image(for: foreign), "Root release hides pixels before another task can run")
        XCTAssertFalse(hold.timedOut)
    }

    @MainActor func testFingerprintAndProviderRevisionReplacementCannotRetainAFormerRepresentation() async throws {
        let fixture = await StorageHarness.make(name: "camera59-fingerprint"), h = try XCTUnwrap(fixture)
        let card = StorageFixture.cards(count: 1, libraryID: h.libraryID, startingAt: StorageFixture.fixedDate)[0]
        let original = request(card, h: h), provider = CameraThumbnail59Provider()
        let source = GalleryThumbnailSource.scoped(store: h.store, thumbnails: provider), model = CameraGalleryThumbnailModel()
        await model.load(request: original, source: source, enabled: true)
        let changed = LibrarySourceCard(captureID: card.captureID, libraryID: card.libraryID, relativeOriginalPath: card.relativeOriginalPath,
            capturedAtUTC: card.capturedAtUTC, capturedAtProvenance: card.capturedAtProvenance, availability: .local,
            classification: card.classification, rawDimensions: card.rawDimensions, byteCount: card.byteCount,
            sequenceID: nil, sequenceIndex: nil, sequenceKind: nil, isTruongCamCapture: true, modificationFingerprint: "replacement-bytes")
        let changedRequest = request(changed, h: h)
        XCTAssertNil(model.displayImage(for: changedRequest, context: context(source, retained: original)))
        let newerProvider = context(source, retained: original, revision: 2)
        XCTAssertNil(model.displayImage(for: request(card, h: h, revision: 2), context: newerProvider))
        await model.load(request: changedRequest, source: source, enabled: false, context: context(source, retained: changedRequest))
        XCTAssertNil(model.completedRequest)
    }

    @MainActor private func host<V: View>(_ view: V) async throws -> UIWindow {
        for _ in 0..<300 {
            if UIApplication.shared.connectedScenes.contains(where: { $0 is UIWindowScene }) { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene); window.frame = CGRect(x: 0, y: 0, width: 88, height: 88)
        window.rootViewController = UIHostingController(rootView: view.ignoresSafeArea())
        window.makeKeyAndVisible(); window.layoutIfNeeded()
        return window
    }
    @MainActor private func colorCounts(_ window: UIWindow) throws -> (red: Int, blue: Int) {
        window.layoutIfNeeded()
        let format = UIGraphicsImageRendererFormat(); format.scale = 1; format.opaque = true
        let image = UIGraphicsImageRenderer(bounds: window.bounds, format: format).image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        let bitmap = try XCTUnwrap(image.cgImage), width = bitmap.width, height = bitmap.height
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        try bytes.withUnsafeMutableBytes { memory in
            let context = try XCTUnwrap(CGContext(data: memory.baseAddress, width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue))
            context.draw(bitmap, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
        var red = 0, blue = 0
        for i in stride(from: 0, to: bytes.count, by: 4) {
            if bytes[i] > 180 && bytes[i + 1] < 40 && bytes[i + 2] < 40 { red += 1 }
            if bytes[i + 2] > 180 && bytes[i] < 40 && bytes[i + 1] < 40 { blue += 1 }
        }
        return (red, blue)
    }

    @MainActor func testShippingCameraButtonKeepsPriorPixelsThroughDisabledLoadingAndHeldReplacement() async throws {
        let fixture = await StorageHarness.make(name: "camera59-shipping"), h = try XCTUnwrap(fixture)
        let directory = StorageFixture.temporaryDirectory("camera59-shipping-index")
        let index = SQLiteIndex(databaseURL: directory.appendingPathComponent("index.sqlite"))
        let cards = StorageFixture.cards(count: 2, libraryID: h.libraryID, startingAt: StorageFixture.fixedDate)
        try await index.reset(libraryID: h.libraryID, generation: h.generation); try await index.upsert(scanned: [cards[1]])
        let provider = CameraThumbnail59Provider(), app = AppEnvironment()
        app.attach(store: h.store, index: index); app.attachThumbnails(store: h.store, thumbnails: provider)
        let (camera, _) = await CaptureFormatUISuite.makeModel(h: h, capability: CaptureFormatUISuite.capability())
        app.attach(camera: camera); await app.library?.loadFirstPage()
        XCTAssertTrue(camera.isHardwareShutterEnabled)
        let window = try await host(CameraGalleryButton().environment(app).foregroundStyle(.white)
            .frame(maxWidth: .infinity, maxHeight: .infinity).background(.black))
        defer { window.isHidden = true; window.rootViewController = nil }
        for _ in 0..<200 where provider.count == 0 { try await Task.sleep(for: .milliseconds(5)) }
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertGreaterThan(try colorCounts(window).red, 850)
        app.isPreparingExperience = true
        try await index.upsert(scanned: [cards[0]]); await app.library?.loadFirstPage()
        try await Task.sleep(for: .milliseconds(60))
        XCTAssertEqual(provider.count, 1)
        XCTAssertGreaterThan(try colorCounts(window).red, 850, "Disabled optional work keeps the same actual photo")
        let hold = HeldLibraryDecode(); defer { hold.release() }; provider.holdNext(hold)
        app.isPreparingExperience = false
        let entered = await LibraryPerformanceSuite.waitUntil { hold.didEnter }; XCTAssertTrue(entered)
        XCTAssertGreaterThan(try colorCounts(window).red, 850, "A held decode never replaces the shipping label with a placeholder")
        hold.release()
        for _ in 0..<200 {
            if try colorCounts(window).blue > 850 { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertGreaterThan(try colorCounts(window).blue, 850)
        await h.store.releaseRoot(); app.refreshLibraryRootState()
        try await Task.sleep(for: .milliseconds(60))
        let released = try colorCounts(window)
        XCTAssertEqual(released.red, 0); XCTAssertEqual(released.blue, 0)
        await camera.stop(); await index.closeDatabase(); StorageFixture.removeDirectory(directory)
        XCTAssertFalse(hold.timedOut)
    }
}
#endif
