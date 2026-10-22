import AVFoundation
import Foundation
import SwiftUI
import UIKit

// PREVIEW_TOOLS.md "Session and framing feasibility gate".
//
// A single native `AVCaptureVideoPreviewLayer` is the principal preview. This
// bridge may display the session but never configures it: configuration stays on
// the camera service's serial queue. Setting a session preset, changing the
// active format or adding/removing outputs from here would violate that
// ownership, so none of it happens in this file.

/// Displays the capture session and reports tap/geometry information back.
struct CameraPreviewView: UIViewControllerRepresentable {
    let sessionBox: PreviewSessionBox
    let isMirrored: Bool
    let configurationGeneration: ConfigurationGeneration
    let imageDimensions: PixelDimensions
    let cleanApertureDimensions: PixelDimensions?
    let onTap: (TCPoint) -> Void
    let onTapRejected: () -> Void
    let onGeometryChanged: (PreviewGeometry) -> Void
    /// Reports a new loupe centre while the loupe is enabled (REVIEW.md S07).
    var onLoupeCentreChanged: ((NormalizedDevicePoint) -> Void)?
    /// Whether a pan should move the loupe rather than do nothing.
    var isLoupeActive: Bool = false
    var isConnectionConfigurationEnabled: Bool = true
    var onPreviewReady: ((ConfigurationGeneration, UInt64) -> Bool)?

    /// Geometry in view coordinates, reported from the live layer.
    struct PreviewGeometry: Equatable {
        let contentRect: TCRect
        let viewSize: CGSize
        let imageDimensions: PixelDimensions
        let rotationDegrees: Int
        let layoutGeneration: UInt64
        let configurationGeneration: ConfigurationGeneration
        let isMirrored: Bool
        let cleanApertureDimensions: PixelDimensions?
        let interfaceOrientation: DeviceOrientation
    }

    func makeUIViewController(context: Context) -> PreviewHostController {
        let controller = PreviewHostController()
        let view = controller.previewHost
        view.photoWorkSource = sessionBox.photoWorkSource
        view.observeCurrentFrames(sessionBox.currentFrameNotifications)
        view.setNativeAccessGate(sessionBox.nativeAccessGate)
        view.setConnectionConfigurationEnabled(isConnectionConfigurationEnabled)
        view.bindDisplaySession(sessionBox.session)
        view.rotationAngles = sessionBox.rotationAngles ?? .rear
        view.configurationGeneration = configurationGeneration
        view.imageDimensions = imageDimensions
        view.cleanApertureDimensions = cleanApertureDimensions
        view.updateMirroring(isMirrored)
        view.onPreviewReady = onPreviewReady
        view.onTap = onTap
        view.onTapRejected = onTapRejected
        view.onGeometryChanged = onGeometryChanged
        view.onLoupeCentreChanged = onLoupeCentreChanged
        view.isLoupeActive = isLoupeActive
        return controller
    }

    func updateUIViewController(_ controller: PreviewHostController, context: Context) {
        let uiView = controller.previewHost
        uiView.photoWorkSource = sessionBox.photoWorkSource
        uiView.observeCurrentFrames(sessionBox.currentFrameNotifications)
        uiView.setNativeAccessGate(sessionBox.nativeAccessGate)
        uiView.setConnectionConfigurationEnabled(isConnectionConfigurationEnabled)
        uiView.bindDisplaySession(sessionBox.session)
        uiView.rotationAngles = sessionBox.rotationAngles ?? .rear
        uiView.configurationGeneration = configurationGeneration
        uiView.imageDimensions = imageDimensions
        uiView.cleanApertureDimensions = cleanApertureDimensions
        uiView.updateMirroring(isMirrored)
        uiView.onPreviewReady = onPreviewReady
        uiView.onTap = onTap
        uiView.onTapRejected = onTapRejected
        uiView.onGeometryChanged = onGeometryChanged
        uiView.onLoupeCentreChanged = onLoupeCentreChanged
        uiView.isLoupeActive = isLoupeActive
        uiView.synchronizeConfiguration()
    }
}

/// SwiftUI owns this controller's size; UIKit supplies the matching rotation
/// transaction. Keeping the host alive lets its layer resize and rotate in that
/// transaction instead of showing a newly wide canvas with the old portrait
/// connection until the scene-orientation poll catches up.
@MainActor final class PreviewHostController: UIViewController {
    let previewHost = PreviewHostView()

    override func loadView() { view = previewHost }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        previewHost.synchronizeConfiguration()
    }

    override func viewWillTransition(to size: CGSize, with coordinator: any UIViewControllerTransitionCoordinator) {
        super.viewWillTransition(to: size, with: coordinator)
        coordinator.animate(alongsideTransition: { [weak self] _ in
            self?.reconcileRotationLayout()
        }, completion: { [weak self] _ in
            // Cancellation and rapid opposite rotations both reconcile from the
            // current window/scene, never from a captured old target angle.
            self?.reconcileRotationLayout()
        })
    }

    private func reconcileRotationLayout() {
        guard isViewLoaded, view.window != nil else { return }
        // Do not assign a frame or session here. The containing SwiftUI layout
        // and the camera's serial graph owner retain those responsibilities.
        view.setNeedsLayout()
        view.layoutIfNeeded()
        previewHost.synchronizeConfiguration()
    }
}

/// UIKit host that owns the preview layer, the tap recognizer and geometry
/// reporting. The layer is `.resizeAspect`, so the full sensor frame is always
/// visible and letterboxing is never filled by cropping.
@MainActor final class PreviewHostView: UIView {
    weak var photoWorkSource: PreviewDisplayBridge?
    private weak var observedFrameSource: LatestValueBroadcaster<PreviewFrameIdentity>?
    private var frameReadinessTask: Task<Void, Never>?
    deinit { frameReadinessTask?.cancel() }

    func observeCurrentFrames(_ source: LatestValueBroadcaster<PreviewFrameIdentity>?) {
        guard observedFrameSource !== source else { return }
        frameReadinessTask?.cancel(); observedFrameSource = source
        guard let source else { return }
        let frames = source.subscribe()
        frameReadinessTask = Task { @MainActor [weak self] in
            for await frame in frames {
                guard !Task.isCancelled else { return }
                guard let self, self.window != nil, let geometry = self.lastReported,
                      frame.generation == geometry.configurationGeneration,
                      frame.layout == geometry.layoutGeneration else { continue }
                // Wake directly on the first current native frame instead of
                // waiting for the orientation timer. All rendering/gate checks remain.
                self.synchronizeConfiguration()
            }
        }
    }
    override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }

    var previewLayer: AVCaptureVideoPreviewLayer {
        // `layerClass` guarantees this cast.
        guard let layer = layer as? AVCaptureVideoPreviewLayer else {
            fatalError("PreviewHostView must be backed by an AVCaptureVideoPreviewLayer")
        }
        return layer
    }

    private weak var boundDisplaySession: AVCaptureSession?
    private weak var pendingDisplaySession: AVCaptureSession?
    private var nativeAccessGate: PreviewNativeAccessGate?
    private var observedAccessRevision: UInt64?
    func setNativeAccessGate(_ gate: PreviewNativeAccessGate?) {
        guard nativeAccessGate !== gate else { return }
        nativeAccessGate = gate
        observedAccessRevision = nil
        invalidateConnectionBindings()
        lastReported = nil
        lastDeliveredGeometry = nil
        lastReadyGeometry = nil
    }
    /// Called on MainActor before every explicit native-layer operation. A
    /// pause itself is also installed on MainActor, so it cannot race between
    /// this check and the end of the current synchronous preview call.
    private func prepareNativeAccess() -> Bool {
        // The native layer continues to display without our polling. Cold photo
        // processing can hold AVFoundation locks even after capturePhoto returns;
        // defer optional MainActor getters/setters, not rendering or frame ACKs.
        guard photoWorkSource?.shouldDeferAnalysisForPhoto != true else { return false }
        if let access = nativeAccessGate?.snapshot {
            if observedAccessRevision != access.revision {
                observedAccessRevision = access.revision
                invalidateConnectionBindings()
                // An async geometry/ready callback dropped during a pause must
                // be regenerated even when layout and sensor angle stayed equal.
                lastReported = nil
                lastDeliveredGeometry = nil
                lastReadyGeometry = nil
            }
            guard !access.isPaused else { return false }
        }
        return connectionConfigurationEnabled
    }
    private(set) var sessionAssignmentCount = 0
    func bindDisplaySession(_ session: AVCaptureSession?) {
        pendingDisplaySession = session
        bindPendingDisplaySession()
    }
    private func bindPendingDisplaySession() {
        guard prepareNativeAccess() else { return }
        // Comparing the display handle avoids a native layer.session getter for
        // every histogram/readback SwiftUI update, including during an input swap.
        guard boundDisplaySession !== pendingDisplaySession else { return }
        previewLayer.videoGravity = .resizeAspect
        previewLayer.session = pendingDisplaySession
        boundDisplaySession = pendingDisplaySession
        sessionAssignmentCount += 1
        invalidateConnectionBindings()
    }

    private var connection: AVCaptureConnection? { previewLayer.connection }
    private var desiredMirroring = false
    var configurationGeneration: ConfigurationGeneration = .zero {
        didSet { if oldValue != configurationGeneration { invalidateConnectionBindings() } }
    }
    var rotationAngles = CameraRotationAngles.rear {
        didSet { if oldValue != rotationAngles { invalidateConnectionBindings() } }
    }
    var imageDimensions = PixelDimensions(width: 0, height: 0)
    var cleanApertureDimensions: PixelDimensions?

    private var connectionConfigurationEnabled = true
    private var rotationApplied = false
    private var mirroringApplied = false
    private var actualMirroring = false
    private(set) var connectionLookupCount = 0
    private(set) var geometryComputationCount = 0
    private struct GeometryInputs: Equatable {
        let bounds: CGRect
        let image: PixelDimensions
        let aperture: PixelDimensions?
        let generation: ConfigurationGeneration
        let rotation: Int
        let mirrored: Bool
        let orientation: DeviceOrientation
    }
    private var lastGeometryInputs: GeometryInputs?

    func setConnectionConfigurationEnabled(_ enabled: Bool) {
        guard connectionConfigurationEnabled != enabled else { return }
        connectionConfigurationEnabled = enabled
        invalidateConnectionBindings()
    }
    private func invalidateConnectionBindings() {
        rotationApplied = false
        mirroringApplied = false
        lastGeometryInputs = nil
    }
    func synchronizeConfiguration() {
        guard prepareNativeAccess() else { return }
        #if DEBUG
        let began = ProcessInfo.processInfo.systemUptime
        defer {
            let ms = Int((ProcessInfo.processInfo.systemUptime - began) * 1000)
            if ms >= 50 { print("TruongCam timing native-preview-sync=\(ms)ms generation=\(configurationGeneration.value)") }
        }
        #endif
        bindPendingDisplaySession()
        guard hasCoherentSceneLayout else { return }
        applyMirroring()
        synchronizeOrientation()
        refreshGeometry()
        publishLatestGeometry()
        // This is a rendering-state check, not a fixed delay or a Saved claim.
        if let lastReported, lastReadyGeometry != lastReported, previewLayer.isPreviewing {
            DispatchQueue.main.async { [weak self] in
                guard let self, self.prepareNativeAccess(),
                      self.lastReported == lastReported,
                      self.geometryMatchesCurrentLayout(lastReported) else { return }
                if self.onPreviewReady?(lastReported.configurationGeneration, lastReported.layoutGeneration) ?? true {
                    self.lastReadyGeometry = lastReported
                }
            }
        }
    }

    private var orientationTimer: Timer?
    private var geometryGeneration: UInt64 = 0
    private(set) var previewRotationDegrees = 90
    private(set) var interfaceOrientation: DeviceOrientation = .portrait
    var onPreviewReady: ((ConfigurationGeneration, UInt64) -> Bool)?

    override func didMoveToWindow() {
        super.didMoveToWindow()
        orientationTimer?.invalidate(); orientationTimer = nil
        guard window != nil else { return }
        synchronizeConfiguration()
        // Opposite landscapes have identical bounds; layoutSubviews alone cannot
        // observe that flip. Read the window's resolved orientation while attached,
        // doing native/geometry work ONLY when its angle actually changes.
        let timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.synchronizeConfiguration() }
        }
        orientationTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func synchronizeOrientation() {
        guard prepareNativeAccess(), let orientation = window?.windowScene?.effectiveGeometry.interfaceOrientation else { return }
        applyInterfaceOrientation(orientation)
    }

    /// During a UIKit rotation these three values can arrive in different layout
    /// passes. Do not publish a portrait-angle/new-landscape-size combination to
    /// analysis or acknowledge it as a current rendered preview.
    static func layoutMatchesScene(viewSize: CGSize, windowSize: CGSize, orientation: UIInterfaceOrientation) -> Bool {
        guard viewSize.width.isFinite, viewSize.height.isFinite,
              windowSize.width.isFinite, windowSize.height.isFinite,
              min(viewSize.width, viewSize.height, windowSize.width, windowSize.height) > 0,
              orientation.isPortrait || orientation.isLandscape else { return false }
        let landscape = orientation.isLandscape
        return (viewSize.width > viewSize.height) == landscape &&
            (windowSize.width > windowSize.height) == landscape
    }

    private var hasCoherentSceneLayout: Bool {
        guard let window, let scene = window.windowScene else { return true }
        return Self.layoutMatchesScene(viewSize: bounds.size, windowSize: window.bounds.size,
            orientation: scene.effectiveGeometry.interfaceOrientation)
    }

    private func geometryMatchesCurrentLayout(_ geometry: CameraPreviewView.PreviewGeometry) -> Bool {
        guard geometry.viewSize == bounds.size, hasCoherentSceneLayout else { return false }
        guard let orientation = window?.windowScene?.effectiveGeometry.interfaceOrientation else { return true }
        return geometry.interfaceOrientation == Self.deviceAxes(for: orientation)
    }

    private static func deviceAxes(for orientation: UIInterfaceOrientation) -> DeviceOrientation? {
        switch orientation {
        case .portrait: .portrait
        case .portraitUpsideDown: .portraitUpsideDown
        // UIKit landscape names describe the interface, opposite physical axes.
        case .landscapeLeft: .landscapeRight
        case .landscapeRight: .landscapeLeft
        default: nil
        }
    }

    func applyInterfaceOrientation(_ orientation: UIInterfaceOrientation) {
        guard prepareNativeAccess() else { return }
        bindPendingDisplaySession()
        guard let axes = Self.deviceAxes(for: orientation) else { return }
        if interfaceOrientation != axes { lastGeometryInputs = nil }
        interfaceOrientation = axes
        let angle: CGFloat
        switch orientation {
        case .portrait: angle = CGFloat(rotationAngles.portrait)
        case .portraitUpsideDown: angle = CGFloat(rotationAngles.portraitUpsideDown)
        case .landscapeLeft: angle = CGFloat(rotationAngles.landscapeLeft)
        case .landscapeRight: angle = CGFloat(rotationAngles.landscapeRight)
        default: return
        }
        // Do not touch native connection getters/setters on every readback,
        // layout or 100-ms orientation poll. Input-generation/readiness changes
        // invalidate this binding, including same-angle replacement connections.
        if previewRotationDegrees == Int(angle), rotationApplied { return }
        connectionLookupCount += 1
        #if DEBUG
        let began = ProcessInfo.processInfo.systemUptime
        defer {
            let ms = Int((ProcessInfo.processInfo.systemUptime - began) * 1000)
            if ms >= 16 { print("TruongCam timing preview-rotation=\(ms)ms generation=\(configurationGeneration.value)") }
        }
        #endif
        if let connection {
            guard connection.isVideoRotationAngleSupported(angle) else { return }
            if connection.videoRotationAngle != angle { connection.videoRotationAngle = angle }
            rotationApplied = true
            lastGeometryInputs = nil
        }
        if previewRotationDegrees != Int(angle) { lastGeometryInputs = nil }
        previewRotationDegrees = Int(angle)
        refreshGeometry()
    }

    func updateMirroring(_ value: Bool) {
        if desiredMirroring != value {
            desiredMirroring = value
            mirroringApplied = false
            lastGeometryInputs = nil
        }
    }

    private func applyMirroring() {
        guard prepareNativeAccess(), !mirroringApplied else { return }
        #if DEBUG
        let began = ProcessInfo.processInfo.systemUptime
        defer {
            let ms = Int((ProcessInfo.processInfo.systemUptime - began) * 1000)
            if ms >= 16 { print("TruongCam timing preview-mirroring-fallback=\(ms)ms generation=\(configurationGeneration.value)") }
        }
        #endif
        connectionLookupCount += 1
        guard let connection else { return }
        // This native connection backs our UIKit layer. Its setters can invoke
        // synchronous KVO/layout, so they must stay on MainActor after the native
        // graph lease has released. Never normalize it on the session queue.
        let generation = configurationGeneration
        let changes = CapturePipelinePreparation.automaticPreviewMirroringChanges(
            supported: connection.isVideoMirroringSupported,
            automatic: connection.automaticallyAdjustsVideoMirroring)
        guard CapturePipelinePreparation.applyPreviewMirroring(changes, isCurrent: {
            self.prepareNativeAccess() && self.configurationGeneration == generation
        }, set: { change in
            switch change {
            case .enableAutomatic: connection.automaticallyAdjustsVideoMirroring = true
            case .disableAutomatic: connection.automaticallyAdjustsVideoMirroring = false
            case .setMirrored(let value): connection.isVideoMirrored = value
            }
        }) else { return }
        actualMirroring = connection.isVideoMirrored
        // Automatic adjustment may finish after a replacement connection first
        // appears. Keep observing until the actual state matches this facing;
        // geometry always describes the actual display, never an assumed flip.
        mirroringApplied = !connection.isVideoMirroringSupported || actualMirroring == desiredMirroring
        lastGeometryInputs = nil
    }

    var onTap: ((TCPoint) -> Void)?
    var onTapRejected: (() -> Void)?
    var onGeometryChanged: ((CameraPreviewView.PreviewGeometry) -> Void)?

    private var lastReported: CameraPreviewView.PreviewGeometry?
    private var lastDeliveredGeometry: CameraPreviewView.PreviewGeometry?
    private var geometryPublishScheduled = false
    private var lastReadyGeometry: CameraPreviewView.PreviewGeometry?

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .black
        let recognizer = UITapGestureRecognizer(target: self, action: #selector(handleTap(_:)))
        addGestureRecognizer(recognizer)
        // REVIEW.md S07: the loupe centre interaction was missing entirely
        // (hardcoded `.center`). A pan moves the loupe while it is enabled; the
        // tap recognizer continues to handle focus so the two do not fight.
        let pan = UIPanGestureRecognizer(target: self, action: #selector(handleLoupePan(_:)))
        pan.require(toFail: recognizer)
        addGestureRecognizer(pan)
    }

    /// Reports a normalized device point for the loupe centre.
    var onLoupeCentreChanged: ((NormalizedDevicePoint) -> Void)?
    /// True while the loupe is enabled, so a pan is not treated as a loupe move.
    var isLoupeActive = false

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("PreviewHostView is created in code only")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        // Session attachment/lens changes can replace or create the connection
        // after updateUIView. Configure that new connection before reporting it.
        synchronizeConfiguration()
    }

    @objc private func handleLoupePan(_ recognizer: UIPanGestureRecognizer) {
        guard prepareNativeAccess(), isLoupeActive else { return }
        let point = recognizer.location(in: self)
        let contentRect = currentContentRect()
        guard contentRect.size.width > 0, contentRect.size.height > 0 else { return }
        // Convert the view point into the normalized device space the analysis
        // request uses. A point in the letterbox is ignored rather than clamped
        // into a misleading position.
        let mapper = PreviewGeometryMapper(imageDimensions: imageDimensions,
            contentRect: contentRect, isMirrored: desiredMirroring,
            rotationDegrees: previewRotationDegrees, bufferOrientation: 1)
        guard let devicePoint = mapper.devicePoint(forViewPoint: TCPoint(x: Double(point.x), y: Double(point.y))) else { return }
        onLoupeCentreChanged?(devicePoint)
    }

    @objc private func handleTap(_ recognizer: UITapGestureRecognizer) {
        guard prepareNativeAccess() else { return }
        let point = recognizer.location(in: self)
        let contentRect = currentContentRect()
        guard contentRect.contains(TCPoint(x: Double(point.x), y: Double(point.y))) else {
            // A tap in the letterbox is not a focus request.
            onTapRejected?()
            return
        }
        onTap?(TCPoint(x: Double(point.x), y: Double(point.y)))
    }

    /// The rect of this view actually covered by image content.
    ///
    /// The preview layer exposes `layerRectConverted(fromMetadataOutputRect:)`,
    /// which is authoritative for the current videoGravity. A `CGRect` of
    /// `.zero`/`null` means the layer has not laid out yet.
    func currentContentRect() -> TCRect {
        guard prepareNativeAccess() else {
            return lastReported?.contentRect ?? TCRect(x: 0, y: 0, width: Double(bounds.width), height: Double(bounds.height))
        }
        let converted = previewLayer.layerRectConverted(
            fromMetadataOutputRect: CGRect(x: 0, y: 0, width: 1, height: 1))
        if converted.isNull || converted.isEmpty || !converted.origin.x.isFinite || !converted.origin.y.isFinite || !converted.width.isFinite || !converted.height.isFinite {
            return TCRect(x: 0, y: 0, width: Double(bounds.width), height: Double(bounds.height))
        }
        return TCRect(x: Double(converted.origin.x),
                      y: Double(converted.origin.y),
                      width: Double(converted.size.width),
                      height: Double(converted.size.height))
    }

    func refreshGeometry() {
        guard prepareNativeAccess(), bounds.width > 0, bounds.height > 0, hasCoherentSceneLayout else { return }
        if let orientation = window?.windowScene?.effectiveGeometry.interfaceOrientation,
           Self.deviceAxes(for: orientation) != interfaceOrientation { return }
        let inputs = GeometryInputs(bounds: bounds, image: imageDimensions, aperture: cleanApertureDimensions,
            generation: configurationGeneration, rotation: previewRotationDegrees, mirrored: actualMirroring, orientation: interfaceOrientation)
        guard inputs != lastGeometryInputs else { return }
        lastGeometryInputs = inputs
        geometryComputationCount += 1
        let contentRect = currentContentRect()
        let dimensions = imageDimensions
        let rotation = CGFloat(previewRotationDegrees)
        func makeGeometry(_ generation: UInt64) -> CameraPreviewView.PreviewGeometry { CameraPreviewView.PreviewGeometry(
            contentRect: contentRect,
            viewSize: bounds.size,
            imageDimensions: dimensions,
            rotationDegrees: Int(rotation.rounded()),
            layoutGeneration: generation,
            configurationGeneration: configurationGeneration,
            isMirrored: actualMirroring,
            cleanApertureDimensions: cleanApertureDimensions,
            interfaceOrientation: interfaceOrientation)
        }
        guard makeGeometry(geometryGeneration) != lastReported else { return }
        geometryGeneration &+= 1
        let geometry = makeGeometry(geometryGeneration)
        lastReported = geometry
        publishLatestGeometry()
    }

    private func publishLatestGeometry() {
        guard !geometryPublishScheduled, let geometry = lastReported, lastDeliveredGeometry != geometry,
              geometryMatchesCurrentLayout(geometry) else { return }
        geometryPublishScheduled = true
        // A pause can arrive after layout but before this callback. Retain the
        // undelivered geometry and retry after access resumes, without inventing
        // a new layout generation for every no-op analysis demand.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.geometryPublishScheduled = false
            guard self.prepareNativeAccess() else { return }
            guard self.lastReported == geometry, self.geometryMatchesCurrentLayout(geometry) else {
                self.publishLatestGeometry()
                return
            }
            self.lastDeliveredGeometry = geometry
            self.onGeometryChanged?(geometry)
        }
    }

}
