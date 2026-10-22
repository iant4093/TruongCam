import SwiftUI
import UIKit

/// Touch lifetime is independent of each photo's enabled/busy state. The
/// captured callbacks belong to the model that admitted the press, so teardown
/// or an old release cannot affect a replacement model or newer press.
struct ContinuousShutterSurface: UIViewRepresentable {
    let camera: CameraViewModel
    func makeUIView(context: Context) -> ContinuousShutterTouchView { ContinuousShutterTouchView() }
    func updateUIView(_ view: ContinuousShutterTouchView, context: Context) {
        view.configure(owner: camera.graphIdentity,
            enabled: camera.isShutterEnabled || camera.isContinuousCaptureHeld,
            begin: { camera.beginShutterHold(id: $0) },
            end: { camera.endShutterHold(id: $0) },
            cancel: { camera.cancelShutterHold(id: $0) })
    }
    static func dismantleUIView(_ view: ContinuousShutterTouchView, coordinator: ()) { view.cancelPress() }
}

final class ContinuousShutterTouchView: UIView {
    private var owner: ObjectIdentifier?
    private var enabled = false
    private var begin: ((UUID) -> Bool)?
    private var end: ((UUID) -> Void)?
    private var cancel: ((UUID) -> Void)?
    private var press: (id: UUID, end: (UUID) -> Void, cancel: (UUID) -> Void)?
    private weak var touch: UITouch?
    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        isMultipleTouchEnabled = false
        isAccessibilityElement = false
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    func configure(owner: ObjectIdentifier, enabled: Bool,
                   begin: @escaping (UUID) -> Bool, end: @escaping (UUID) -> Void,
                   cancel: @escaping (UUID) -> Void) {
        if self.owner != owner || !enabled { cancelPress() }
        self.owner = owner; self.enabled = enabled
        self.begin = begin; self.end = end; self.cancel = cancel
    }
    @discardableResult func beginPress(at point: CGPoint) -> Bool {
        guard enabled, press == nil, bounds.contains(point), let begin, let end, let cancel else { return false }
        let id = UUID()
        guard begin(id) else { return false }
        press = (id, end, cancel)
        return true
    }
    func finishPress(at point: CGPoint) {
        guard let press else { return }
        self.press = nil; touch = nil
        if bounds.contains(point) { press.end(press.id) }
        else { press.cancel(press.id) }
    }
    func cancelPress() {
        guard let press else { return }
        self.press = nil; touch = nil
        press.cancel(press.id)
    }
    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard touch == nil, let first = touches.first, beginPress(at: first.location(in: self)) else { return }
        touch = first
    }
    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        if let touch, touches.contains(touch), !bounds.contains(touch.location(in: self)) { cancelPress() }
    }
    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        if let touch, touches.contains(touch) { finishPress(at: touch.location(in: self)) }
    }
    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        if let touch, touches.contains(touch) { cancelPress() }
    }
    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window == nil { cancelPress() }
    }
}
