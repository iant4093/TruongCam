@preconcurrency import AVFoundation
import Foundation

/// Narrow, display-only access to the capture session.
///
/// Ownership invariant for the narrow `@unchecked Sendable`: the boxed
/// `AVCaptureSession` is only ever *read* by UIKit when the layer renders. It is
/// never mutated through this type; all mutation remains on the camera service's
/// serial queue. `@preconcurrency`-imported AVFoundation reference types are not
/// `Sendable`, so the box documents this single exception instead of annotating
/// the whole model graph.
struct PreviewSessionBox: @unchecked Sendable {
    let session: AVCaptureSession
    var rotationAngles: CameraRotationAngles? = nil
    var nativeAccessGate: PreviewNativeAccessGate? = nil
    var currentFrameNotifications: LatestValueBroadcaster<PreviewFrameIdentity>? = nil
    var photoWorkSource: PreviewDisplayBridge? = nil
}
