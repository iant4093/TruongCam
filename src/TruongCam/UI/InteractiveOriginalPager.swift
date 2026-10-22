import CoreGraphics
import SwiftUI
import UIKit

/// A display request's authority, independent of the photo's position in the
/// viewer. A regrant, folder replacement or source revision invalidates a drag.
struct ViewerPagingContext: Equatable {
    let revision: Int
    let rootState: LibraryRootState
    let rootURL: URL?
}

struct ViewerAdjacentPage {
    let captureID: CaptureID
    let image: CGImage
}

/// The finger moves the current and adjacent fitted canvases together. Only the
/// final accepted page asks the existing viewer owner to change photo identity;
/// this view never opens a file or owns an original's bytes.
struct InteractiveOriginalPager: UIViewRepresentable {
    let image: CGImage
    let captureID: CaptureID
    let position: Int
    let previousCaptureID: CaptureID?
    let nextCaptureID: CaptureID?
    let previousPage: ViewerAdjacentPage?
    let nextPage: ViewerAdjacentPage?
    let hasPrevious: Bool
    let hasNext: Bool
    let navigationEnabled: Bool
    let context: ViewerPagingContext
    let reduceMotion: Bool
    let toggleChrome: () -> Void
    let previous: () -> Void
    let next: () -> Void
    let selectPage: (CaptureID, CaptureID) -> Bool
    var pagingProgress: (CGFloat) -> Void = { _ in }
    var dismissalEnabled = true
    var dismissalProgress: (CGFloat) -> Void = { _ in }
    var dismissViewer: () -> Void = {}

    var zoomable: ZoomableOriginalView {
        ZoomableOriginalView(image: image, toggleChrome: toggleChrome, previous: previous, next: next,
            discretePaging: false, dismissalEnabled: dismissalEnabled,
            dismissalProgress: dismissalProgress, dismissViewer: dismissViewer)
    }
    func makeUIView(context: Context) -> OriginalPagerView { OriginalPagerView(configuration: self) }
    func updateUIView(_ view: OriginalPagerView, context: Context) { view.apply(self) }
    static func dismantleUIView(_ view: OriginalPagerView, coordinator: ()) { view.invalidate() }
}

final class OriginalPagerView: UIView, UIGestureRecognizerDelegate {
    private(set) var configuration: InteractiveOriginalPager
    let track = UIView()
    let previousCanvas = UIImageView()
    let nextCanvas = UIImageView()
    let scroll: OriginalScrollView
    let zoomCoordinator: ZoomableOriginalView.Coordinator
    private(set) var horizontalPan: UIPanGestureRecognizer!
    private(set) var dragOffset: CGFloat = 0
    private(set) var isDragging = false
    private var dragIdentity: CaptureID?
    private var dragContext: ViewerPagingContext?
    private var isSettling = false
    private var expectedCaptureID: CaptureID?
    private var animationEpoch = UUID()
    private var laidOutSize = CGSize.zero
    private var outgoingCanvas: UIImageView?

    init(configuration: InteractiveOriginalPager) {
        self.configuration = configuration
        let zoomable = configuration.zoomable
        zoomCoordinator = ZoomableOriginalView.Coordinator(zoomable)
        scroll = zoomable.makeScroll(coordinator: zoomCoordinator)
        super.init(frame: .zero)
        backgroundColor = .black; clipsToBounds = true
        accessibilityIdentifier = "interactivePhotoPager"
        addSubview(track)
        for canvas in [previousCanvas, nextCanvas] {
            canvas.contentMode = .scaleAspectFit; canvas.backgroundColor = .black
            canvas.isAccessibilityElement = false; track.addSubview(canvas)
        }
        previousCanvas.accessibilityIdentifier = "previousPhotoCanvas"
        nextCanvas.accessibilityIdentifier = "nextPhotoCanvas"
        track.addSubview(scroll)
        horizontalPan = UIPanGestureRecognizer(target: self, action: #selector(pan(_:)))
        horizontalPan.maximumNumberOfTouches = 1; horizontalPan.delegate = self
        addGestureRecognizer(horizontalPan)
        scroll.panGestureRecognizer.require(toFail: horizontalPan)
        for gesture in scroll.gestureRecognizers ?? [] {
            if let down = gesture as? UIPanGestureRecognizer, down !== scroll.panGestureRecognizer {
                horizontalPan.require(toFail: down)
            } else if gesture is UITapGestureRecognizer { gesture.require(toFail: horizontalPan) }
        }
        apply(configuration)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layoutSubviews() {
        super.layoutSubviews()
        if laidOutSize != bounds.size {
            laidOutSize = bounds.size
            reset(animated: false, notify: false)
            track.bounds = CGRect(origin: .zero, size: bounds.size)
            track.center = CGPoint(x: bounds.midX, y: bounds.midY)
            scroll.frame = bounds
            previousCanvas.frame = bounds.offsetBy(dx: -bounds.width, dy: 0)
            nextCanvas.frame = bounds.offsetBy(dx: bounds.width, dy: 0)
        }
        scroll.layoutIfNeeded()
    }

    func apply(_ incoming: InteractiveOriginalPager) {
        let old = configuration, changedPhoto = incoming.captureID != old.captureID
        let revoked = incoming.context != old.context || (old.navigationEnabled && !incoming.navigationEnabled)
        configuration = incoming; zoomCoordinator.parent = incoming.zoomable
        if revoked { reset(animated: false, notify: false) }
        if changedPhoto {
            let completedDrag = expectedCaptureID == incoming.captureID
            let oldImage = scroll.imageView.image
            let forward = incoming.position > old.position
            reset(animated: false, notify: false)
            // A different photo starts fitted even when its dimensions match.
            scroll.refitNextImage()
            scroll.setImage(UIImage(cgImage: incoming.image))
            scroll.layoutIfNeeded()
            if !completedDrag && !incoming.reduceMotion && !revoked, let oldImage, bounds.width > 0 {
                animateProgrammaticPage(oldImage: oldImage, forward: forward)
            }
        } else if scroll.imageView.image?.cgImage !== incoming.image {
            scroll.setImage(UIImage(cgImage: incoming.image))
        }
        setImage(incoming.previousPage?.image, on: previousCanvas)
        setImage(incoming.nextPage?.image, on: nextCanvas)
    }

    private func setImage(_ image: CGImage?, on canvas: UIImageView) {
        if canvas.image?.cgImage !== image { canvas.image = image.map { UIImage(cgImage: $0) } }
    }

    override func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard let pan = gestureRecognizer as? UIPanGestureRecognizer else { return false }
        return mayBegin(velocity: pan.velocity(in: self))
    }
    func mayBegin(velocity: CGPoint) -> Bool {
        configuration.navigationEnabled && scroll.isAtFitSize && !isSettling
            && abs(velocity.x) > abs(velocity.y) * 1.2
            && (configuration.hasPrevious || configuration.hasNext)
    }
    @objc private func pan(_ pan: UIPanGestureRecognizer) {
        updatePan(state: pan.state, translation: pan.translation(in: self), velocity: pan.velocity(in: self))
    }

    /// The same entry point is exercised by the hosted gesture/layout tests.
    func updatePan(state: UIGestureRecognizer.State, translation: CGPoint, velocity: CGPoint) {
        if state == .began {
            guard mayBegin(velocity: velocity) else { return }
            animationEpoch = UUID(); track.layer.removeAllAnimations()
            dragIdentity = configuration.captureID; dragContext = configuration.context
            isDragging = true
        }
        guard isDragging else { return }
        guard configuration.navigationEnabled, scroll.isAtFitSize,
              dragIdentity == configuration.captureID, dragContext == configuration.context else {
            reset(animated: false); return
        }
        switch state {
        case .began, .changed:
            let width = max(1, bounds.width), raw = min(width, max(-width, translation.x))
            let endpoint = (raw > 0 && !configuration.hasPrevious) || (raw < 0 && !configuration.hasNext)
            dragOffset = endpoint ? raw * 0.18 : raw
            track.transform = CGAffineTransform(translationX: dragOffset, y: 0)
            configuration.pagingProgress(min(1, abs(dragOffset) / width))
        case .ended:
            let width = max(1, bounds.width)
            let projected = translation.x + velocity.x * 0.14
            let delta = projected < 0 ? 1 : -1
            let exists = delta == 1 ? configuration.hasNext : configuration.hasPrevious
            let distance = abs(translation.x) > width * 0.27
            let flick = abs(translation.x) > 16 && abs(velocity.x) > 650
            guard exists, distance || flick, projected * translation.x > 0 else { reset(animated: true); return }
            guard let targetID = delta == 1 ? configuration.nextCaptureID : configuration.previousCaptureID else {
                reset(animated: true); return
            }
            let candidate = delta == 1 ? configuration.nextPage : configuration.previousPage
            // If a provider has not supplied the adjacent display yet, keep the
            // current image fitted while the one decode worker prioritizes it.
            guard let candidate else {
                let displayedID = configuration.captureID
                reset(animated: true)
                _ = configuration.selectPage(displayedID, targetID)
                return
            }
            guard candidate.captureID == targetID else { reset(animated: true); return }
            finish(delta: delta, captureID: targetID)
        case .cancelled, .failed: reset(animated: true)
        default: break
        }
    }

    private func finish(delta: Int, captureID: CaptureID) {
        isDragging = false; isSettling = true
        expectedCaptureID = captureID
        let epoch = UUID(); animationEpoch = epoch
        let complete: (Bool) -> Void = { [weak self] _ in
            guard let self, self.animationEpoch == epoch, self.configuration.navigationEnabled,
                  self.dragIdentity == self.configuration.captureID,
                  self.dragContext == self.configuration.context else { return }
            if !self.configuration.selectPage(self.configuration.captureID, captureID) { self.reset(animated: true) }
        }
        let changes = {
            self.dragOffset = CGFloat(-delta) * self.bounds.width
            self.track.transform = CGAffineTransform(translationX: self.dragOffset, y: 0)
            self.configuration.pagingProgress(1)
        }
        if configuration.reduceMotion { changes(); complete(true) }
        else { UIView.animate(withDuration: 0.22, delay: 0, options: [.beginFromCurrentState, .curveEaseOut], animations: changes, completion: complete) }
    }

    private func animateProgrammaticPage(oldImage: UIImage, forward: Bool) {
        let canvas = UIImageView(image: oldImage)
        canvas.contentMode = .scaleAspectFit; canvas.backgroundColor = .black
        canvas.frame = bounds; addSubview(canvas); outgoingCanvas = canvas
        let sign: CGFloat = forward ? 1 : -1
        scroll.transform = CGAffineTransform(translationX: sign * bounds.width, y: 0)
        let epoch = UUID(); animationEpoch = epoch; isSettling = true
        UIView.animate(withDuration: 0.26, delay: 0, options: [.curveEaseInOut, .beginFromCurrentState]) {
            canvas.transform = CGAffineTransform(translationX: -sign * self.bounds.width, y: 0)
            self.scroll.transform = .identity
        } completion: { [weak self, weak canvas] _ in
            canvas?.removeFromSuperview()
            guard let self, self.animationEpoch == epoch else { return }
            self.outgoingCanvas = nil; self.isSettling = false
        }
    }

    private func reset(animated: Bool, notify: Bool = true) {
        animationEpoch = UUID(); isDragging = false; isSettling = false
        dragIdentity = nil; dragContext = nil; expectedCaptureID = nil
        outgoingCanvas?.removeFromSuperview(); outgoingCanvas = nil
        scroll.layer.removeAllAnimations(); scroll.transform = .identity
        track.layer.removeAllAnimations(); dragOffset = 0
        let changes = { self.track.transform = .identity }
        if animated && !configuration.reduceMotion {
            UIView.animate(withDuration: 0.22, delay: 0, options: [.beginFromCurrentState, .curveEaseOut], animations: changes)
        } else { changes() }
        if notify { configuration.pagingProgress(0) }
        else {
            // updateUIView/layout can run inside SwiftUI's publication pass.
            // Notify on the next actor turn, only if no new drag/page owns it.
            let epoch = animationEpoch
            Task { @MainActor [weak self] in
                guard let self, self.animationEpoch == epoch, !self.isDragging else { return }
                self.configuration.pagingProgress(0)
            }
        }
    }
    func invalidate() { reset(animated: false) }
}
