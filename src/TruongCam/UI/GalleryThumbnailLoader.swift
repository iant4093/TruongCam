import CoreGraphics
import Foundation
import Observation
import UIKit

// The gallery's disposable preview cache.
//
// LIBRARY.md: thumbnails are derived, bounded and disposable. They never alter an
// original, and a card whose original is missing or unreadable shows an honest
// placeholder rather than a stale rendering presented as the current file.

/// Materializes an already bounded, decoded bitmap away from MainActor. The
/// provider's coordinated read is finished before this copy; no file URL or
/// borrowed storage lease enters this worker. One shared serial owner bounds
/// simultaneous RGBA copies, and cancelled queued work never enters the codec.
final class DisplayImagePreparation: Sendable {
    enum Outcome: Sendable {
        case image(CGImage)
        case unavailable(String)
    }

    static let shared = DisplayImagePreparation()
    private let owner: BlockingIOOwner
    private let makeImage: @Sendable ([UInt8], Int, Int) -> CGImage?

    init(owner: BlockingIOOwner = BlockingIOOwner(label: "com.iantruong.TruongCam.display-image"),
         makeImage: @escaping @Sendable ([UInt8], Int, Int) -> CGImage? = CGImage.rgbaDisplayImage) {
        self.owner = owner
        self.makeImage = makeImage
    }

    func prepare(_ outcome: ThumbnailOutcome) async throws -> Outcome {
        // Placeholder/error results do not need a native conversion or queue hop.
        guard case .image(let bytes, let width, let height, _) = outcome else {
            switch outcome {
            case .unavailable(let reason), .needsFullDecode(let reason): return .unavailable(reason)
            case .image: preconditionFailure("Image case was handled above")
            }
        }
        let makeImage = makeImage
        return try await owner.submit {
            #if DEBUG
            let began = ProcessInfo.processInfo.systemUptime
            defer {
                print("TruongCam timing display-image-conversion=\(Int((ProcessInfo.processInfo.systemUptime-began)*1000))ms edge=\(max(width,height)) main=\(Thread.isMainThread)")
            }
            #endif
            return autoreleasepool { () -> Outcome in
                if let image = makeImage(bytes, width, height) { return .image(image) }
                return .unavailable("The stored preview could not be decoded.")
            }
        }
    }
}

/// Per-card observable thumbnail state.
@MainActor
@Observable
final class ThumbnailModel {
    enum State: Equatable {
        case idle
        case loading
        case loaded(CGImage)
        case unavailable(String)
    }

    private(set) var state: State = .idle
    private var task: Task<Void, Never>?
    private var viewerBound: Int?
    private var viewerFingerprint: String?
    /// The identity the current state describes. REVIEW.md R09: the viewer used a
    /// bare `.task`, so stepping to another source could keep showing the previous
    /// image or apply a stale decode result.
    private(set) var loadedCaptureID: CaptureID?
    struct Request: Hashable {
        let card: LibrarySourceCard
        let sourceRevision: Int
        let rootState: LibraryRootState?
        let targetLongEdge: Int
        let rootURL: URL?
        init(card: LibrarySourceCard, sourceRevision: Int, rootState: LibraryRootState?, targetLongEdge: Int, rootURL: URL? = nil) {
            self.card = card; self.sourceRevision = sourceRevision; self.rootState = rootState
            self.targetLongEdge = targetLongEdge; self.rootURL = rootURL
        }
    }
    private var viewerRequest: Request?
    private var viewerOperation = UUID()
    private var gridRequest: Request?
    private var gridOperation = UUID()
    private let imagePreparation: DisplayImagePreparation

    init(imagePreparation: DisplayImagePreparation = .shared) {
        self.imagePreparation = imagePreparation
    }

    /// A conversion can suspend after the provider's final read check. Retain
    /// the exact folder identity so a release/reconnect cannot publish old bytes
    /// even when equal read-only states describe two different roots.
    private struct SourceRoot: Equatable {
        let state: LibraryRootState?
        let url: URL?
        init(_ source: GalleryThumbnailSource) {
            switch source {
            case .scoped(let store, _): state = store.rootState; url = store.grantedRootURL
            case .unavailable: state = nil; url = nil
            }
        }
    }

    func load(card: LibrarySourceCard,
              source: GalleryThumbnailSource,
              targetLongEdge: Int = 256,
              sourceRevision: Int = 0,
              rootState: LibraryRootState? = nil) {
        viewerBound = nil
        viewerRequest = nil
        let request = Request(card: card, sourceRevision: sourceRevision,
                              rootState: rootState, targetLongEdge: targetLongEdge, rootURL: source.grantedRootURL)
        guard card.availability == .local else {
            cancel()
            gridRequest = request
            if case .inaccessible(let reason) = card.availability {
                AppDiagnostics.record(reason, operation: "photoPreview.\(card.captureID)")
            }
            state = .unavailable("This photo isn’t available in your library folder.")
            return
        }
        if gridRequest == request {
            if case .loaded = state { return }
            if let task, !task.isCancelled { return }
        }
        task?.cancel()
        task = nil
        gridRequest = request
        let operation = UUID(); gridOperation = operation
        state = .loading
        loadedCaptureID = card.captureID
        let sourceRoot = SourceRoot(source)
        let imagePreparation = imagePreparation
        task = Task { [weak self] in
            let outcome = await source.load(card: card, targetLongEdge: targetLongEdge)
            guard let self, self.gridRequest == request, self.gridOperation == operation else { return }
            defer { if self.gridOperation == operation, self.gridRequest == request { self.task = nil } }
            guard !Task.isCancelled else { return }
            do {
                let prepared = try await imagePreparation.prepare(outcome)
                guard !Task.isCancelled, self.gridRequest == request, self.gridOperation == operation else { return }
                guard SourceRoot(source) == sourceRoot else {
                    self.state = .unavailable("The library folder changed; reload this photo.")
                    return
                }
                self.apply(prepared)
            } catch is CancellationError { return }
            catch {
                guard !Task.isCancelled, self.gridRequest == request, self.gridOperation == operation else { return }
                AppDiagnostics.record(error, operation: "photoPreview.prepare")
                self.state = .unavailable("This photo couldn’t be displayed. Try again.")
            }
        }
    }

    /// The SwiftUI cell task owns its request. Disappearing/replaced cells cancel
    /// queued reads so newly visible photos do not wait for obsolete RAW decodes.
    func loadAndWait(card: LibrarySourceCard, source: GalleryThumbnailSource,
                     targetLongEdge: Int = 256, sourceRevision: Int = 0,
                     rootState: LibraryRootState? = nil) async {
        load(card: card, source: source, targetLongEdge: targetLongEdge,
             sourceRevision: sourceRevision, rootState: rootState)
        let waiting = task
        await withTaskCancellationHandler {
            await waiting?.value
        } onCancel: {
            waiting?.cancel()
        }
    }

    func cancel() {
        task?.cancel()
        task = nil
        gridOperation = UUID()
        viewerOperation = UUID()
    }

    /// Requests the largest bounded viewer decode for the detail screen.
    func loadViewer(card: LibrarySourceCard,
                    source: GalleryThumbnailSource,
                    boundLongEdge: Int = 2048,
                    sourceRevision: Int = 0,
                    rootState: LibraryRootState? = nil) {
        gridRequest = nil
        guard card.availability == .local else {
            task?.cancel(); task = nil
            if case .inaccessible(let reason) = card.availability {
                AppDiagnostics.record(reason, operation: "photoPreview.\(card.captureID)")
            }
            state = .unavailable("This photo isn’t available in your library folder.")
            return
        }
        let identity = card.captureID, fingerprint = card.modificationFingerprint
        let request = Request(card: card, sourceRevision: sourceRevision, rootState: rootState,
            targetLongEdge: boundLongEdge, rootURL: source.grantedRootURL)
        let sameRequest = viewerRequest == request
        if sameRequest {
            if case .loaded = state { return }
            if let task, !task.isCancelled { return }
        }
        task?.cancel()
        viewerRequest = request
        let operation = UUID(); viewerOperation = operation
        loadedCaptureID = identity
        viewerFingerprint = fingerprint
        viewerBound = boundLongEdge
        state = .loading
        let sourceRoot = SourceRoot(source)
        let imagePreparation = imagePreparation
        task = Task { [weak self] in
            let outcome = await source.loadViewer(card: card, boundLongEdge: boundLongEdge)
            guard let self, self.viewerRequest == request, self.viewerOperation == operation else { return }
            defer { if self.viewerOperation == operation, self.viewerRequest == request { self.task = nil } }
            guard !Task.isCancelled else { return }
            do {
                let prepared = try await imagePreparation.prepare(outcome)
                guard !Task.isCancelled, self.viewerRequest == request, self.viewerOperation == operation else { return }
                guard SourceRoot(source) == sourceRoot else {
                    self.state = .unavailable("The library folder changed; reload this photo.")
                    return
                }
                self.apply(prepared)
            } catch is CancellationError { return }
            catch {
                guard !Task.isCancelled, self.viewerRequest == request, self.viewerOperation == operation else { return }
                AppDiagnostics.record(error, operation: "photoPreview.prepare")
                self.state = .unavailable("This photo couldn’t be displayed. Try again.")
            }
        }
    }

    func loadViewerAndWait(card: LibrarySourceCard, source: GalleryThumbnailSource,
                           sourceRevision: Int = 0, rootState: LibraryRootState? = nil) async {
        loadViewer(card: card, source: source, sourceRevision: sourceRevision, rootState: rootState)
        let waiting = task
        await withTaskCancellationHandler {
            await waiting?.value
        } onCancel: {
            // A viewer page owns its queued read/conversion just as a grid cell
            // does. Already-running coordinated access still drains safely.
            waiting?.cancel()
        }
    }

    private func apply(_ outcome: DisplayImagePreparation.Outcome) {
        #if DEBUG
        let began = ProcessInfo.processInfo.systemUptime
        defer { print("TruongCam timing display-image-publication=\(Int((ProcessInfo.processInfo.systemUptime-began)*1000))ms mainActor=true") }
        #endif
        switch outcome {
        case .image(let image): state = .loaded(image)
        case .unavailable(let reason):
            AppDiagnostics.record(reason, operation: "photoPreview.unavailable")
            state = .unavailable("This photo couldn’t be opened. Reconnect your library folder and try again.")
        }
    }
}

extension CGImage {
    /// Builds a display image from an RGBA8 byte buffer.
    static func rgbaDisplayImage(bytes: [UInt8], width: Int, height: Int) -> CGImage? {
        guard width > 0, height > 0,
              width <= ThumbnailService.maximumViewerLongEdge,
              height <= ThumbnailService.maximumViewerLongEdge,
              bytes.count >= width * height * 4 else { return nil }
        guard let provider = CGDataProvider(data: Data(bytes) as CFData) else { return nil }
        return CGImage(
            width: width,
            height: height,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider,
            decode: nil,
            shouldInterpolate: true,
            intent: .defaultIntent)
    }
}

/// Late metadata reads cannot replace a newer photo's details or cross a root
/// transition. File access and parsing remain inside the store's owned scope.
@MainActor @Observable final class PhotoDetailModel {
    private let reader: @Sendable (URL) throws -> PhotoMetadataDetails
    init(reader: @escaping @Sendable (URL) throws -> PhotoMetadataDetails = PhotoMetadataDetails.read) { self.reader = reader }
    private(set) var captureID: CaptureID?
    private(set) var details: PhotoMetadataDetails?
    private(set) var error: String?
    private var epoch = UUID()
    func load(card: LibrarySourceCard, store: (any LibraryStoring)?) async {
        let operation = UUID(); epoch = operation
        captureID = card.captureID; details = nil; error = nil
        guard card.availability == .local, let store, store.rootState.libraryID == card.libraryID else {
            if case .inaccessible(let reason) = card.availability {
                AppDiagnostics.record(reason, operation: "photoDetails.\(card.captureID)")
            }
            error = "Photo details are unavailable."; return
        }
        let root = store.rootState
        let rootURL = store.grantedRootURL
        let read = reader
        do {
            let result = try await store.readOriginal(relativePath: card.relativeOriginalPath) { url in
                try read(url)
            }
            guard !Task.isCancelled, epoch == operation,
                  store.rootState == root, store.grantedRootURL == rootURL else { return }
            details = result
        } catch {
            guard !Task.isCancelled, epoch == operation,
                  store.rootState == root, store.grantedRootURL == rootURL else { return }
            AppDiagnostics.record(error, operation: "photoDetails.read")
            self.error = "Couldn’t load photo details. Try opening this photo again."
        }
    }
}
