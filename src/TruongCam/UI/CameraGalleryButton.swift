import SwiftUI
import UIKit

/// The camera and gallery deliberately share one 256-pixel disposable decode.
/// This presentation retains only that bounded bitmap, never original bytes.
@MainActor @Observable final class CameraGalleryThumbnailModel {
    static let targetLongEdge = 256
    let thumbnail: ThumbnailModel
    private(set) var completedRequest: ThumbnailModel.Request?
    private var completedImage: CGImage?
    @ObservationIgnored private var completedStore: (any LibraryStoring)?
    private var operation = UUID()
    private var decodeRequest: ThumbnailModel.Request?
    private var decodeRevision = 0

    init(thumbnail: ThumbnailModel = ThumbnailModel()) { self.thumbnail = thumbnail }

    /// The root/provider stamp is separate from a temporarily suppressed decode
    /// request. Fresh index metadata must still identify the retained original;
    /// a previous bitmap is never evidence that a deleted file remains present.
    struct DisplayContext: Hashable {
        let sourceRevision: Int
        let rootState: LibraryRootState?
        let rootURL: URL?
        let retainedCard: LibrarySourceCard?
        let requestIsTemporarilySuppressed: Bool

        init(source: GalleryThumbnailSource, sourceRevision: Int,
             retainedCard: LibrarySourceCard? = nil, requestIsTemporarilySuppressed: Bool = false) {
            self.sourceRevision = sourceRevision
            self.retainedCard = retainedCard
            self.requestIsTemporarilySuppressed = requestIsTemporarilySuppressed
            switch source {
            case .scoped(let store, _): rootState = store.rootState; rootURL = store.grantedRootURL
            case .unavailable: rootState = nil; rootURL = nil
            }
        }

        private var canBrowse: Bool {
            guard rootURL != nil else { return false }
            switch rootState {
            case .writable: return true
            case .readOnly(_, let id): return id != nil
            default: return false
            }
        }

        fileprivate func matches(_ request: ThumbnailModel.Request) -> Bool {
            canBrowse && sourceRevision == request.sourceRevision && rootState == request.rootState
                && rootURL == request.rootURL && rootState?.libraryID == request.card.libraryID
                && request.card.availability == .local
        }
    }

    func load(request: ThumbnailModel.Request?, source: GalleryThumbnailSource, enabled: Bool,
              context suppliedContext: DisplayContext? = nil) async {
        let pass = UUID(); operation = pass
        let context = suppliedContext ?? DisplayContext(source: source,
            sourceRevision: request?.sourceRevision ?? completedRequest?.sourceRevision ?? 0,
            retainedCard: completedRequest?.card)
        if displayImage(for: request, context: context) == nil { clearSnapshot() }
        guard let request, enabled else {
            thumbnail.cancel()
            return
        }
        guard context.matches(request) else { thumbnail.cancel(); return }
        if decodeRequest != request { decodeRevision &+= 1; decodeRequest = request }
        await thumbnail.loadAndWait(card: request.card, source: source,
            targetLongEdge: request.targetLongEdge, sourceRevision: decodeRevision, rootState: request.rootState)
        guard !Task.isCancelled, operation == pass else { return }
        let current = DisplayContext(source: source, sourceRevision: context.sourceRevision)
        guard current.matches(request), thumbnail.loadedCaptureID == request.card.captureID,
              case .loaded(let image) = thumbnail.state else { clearSnapshot(); return }
        completedRequest = request
        completedImage = image
        if case .scoped(let store, _) = source { completedStore = store }
    }

    /// Exact identity lookup remains separate from displaying an honest prior
    /// library photo while a newer candidate is being decoded.
    func image(for request: ThumbnailModel.Request?) -> CGImage? {
        guard let request, completedRequest == request, let completedStore,
              completedStore.rootState == request.rootState, completedStore.grantedRootURL == request.rootURL else { return nil }
        return completedImage
    }

    func displayImage(for request: ThumbnailModel.Request?, context: DisplayContext) -> CGImage? {
        guard let completedRequest, context.matches(completedRequest),
              context.retainedCard == completedRequest.card,
              request != nil || context.requestIsTemporarilySuppressed else { return nil }
        if let request {
            guard context.matches(request) else { return nil }
            if request.card.captureID == completedRequest.card.captureID, request.card != completedRequest.card { return nil }
        }
        return image(for: completedRequest)
    }

    private func clearSnapshot() {
        completedRequest = nil
        completedImage = nil
        completedStore = nil
        decodeRequest = nil
    }

    func cancel() { operation = UUID(); thumbnail.cancel() }
}

/// A fixed library action. Keep one verified prior library photo visible while
/// its replacement loads; missing/deleted sources and root changes show the icon.
struct CameraGalleryButton: View {
    @Environment(AppEnvironment.self) private var app
    @State private var preview = CameraGalleryThumbnailModel()

    private var request: ThumbnailModel.Request? {
        guard !app.photoMutationInProgress, let card = app.library?.newestThumbnailSource,
              card.libraryID == app.libraryRootState.libraryID else { return nil }
        return ThumbnailModel.Request(card: card, sourceRevision: app.libraryThumbnailRevision,
            rootState: app.libraryRootState, targetLongEdge: CameraGalleryThumbnailModel.targetLongEdge,
            rootURL: app.libraryThumbnailSource.grantedRootURL)
    }
    private var canLoad: Bool {
        !app.isPreparingExperience && app.tab == .camera && !app.photoMutationInProgress
            && app.camera?.isHardwareShutterEnabled == true
            && app.camera?.isCaptureBusy == false && app.camera?.isContinuousCaptureActive == false
            && app.camera?.isPreviewTransitionVisible == false
    }
    private var displayContext: CameraGalleryThumbnailModel.DisplayContext {
        let previousID = preview.completedRequest?.card.captureID
        let progress = app.visiblePhotoMutationProgress
        let wasMovedToTrash = progress?.kind == .moveToTrash
            && previousID.map { progress?.completedIDs.contains($0.rawValue) == true } == true
        let retained = wasMovedToTrash ? nil : app.library?.firstThumbnailSources.first { $0.captureID == previousID }
        return CameraGalleryThumbnailModel.DisplayContext(source: app.libraryThumbnailSource,
            sourceRevision: app.libraryThumbnailRevision, retainedCard: retained,
            requestIsTemporarilySuppressed: app.photoMutationInProgress)
    }
    private struct Loading: Hashable {
        let request: ThumbnailModel.Request?
        let enabled: Bool
        let context: CameraGalleryThumbnailModel.DisplayContext
    }

    var body: some View {
        Button { app.tab = .library } label: {
            CameraGalleryButtonLabel(image: preview.displayImage(for: request, context: displayContext))
        }
        .accessibilityLabel("Open photo library")
        .accessibilityIdentifier("openPhotoLibrary")
        .task(id: Loading(request: request, enabled: canLoad, context: displayContext)) {
            await preview.load(request: request, source: app.libraryThumbnailSource, enabled: canLoad, context: displayContext)
        }
        .onDisappear { preview.cancel() }
    }
}

/// Kept independent of the environment so native raster checks exercise the
/// exact shipping hit target and both honest visual states.
struct CameraGalleryButtonLabel: View {
    let image: CGImage?
    var body: some View {
        Group {
            if let image {
                Image(decorative: image, scale: 1)
                    .resizable().scaledToFill()
                    .frame(width: 38, height: 38)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .overlay { RoundedRectangle(cornerRadius: 8).strokeBorder(.white.opacity(0.75), lineWidth: 1) }
            } else {
                Image(systemName: "photo.stack")
            }
        }
        .frame(width: 44, height: 44)
        .contentShape(Rectangle())
        .accessibilityHidden(true)
    }
}
