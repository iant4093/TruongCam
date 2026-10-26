import AVFoundation
import Foundation

// CONTRACTS.md "Semantic interfaces": CameraService owns the session, delegate
// maps and analysis output on one serial configuration queue. This protocol is
// the seam that lets a fake exercise every state machine without a device.

/// Lifecycle of the capture session (CONTRACTS.md "Camera, source and library state").
enum CameraLifecycle: Hashable, Sendable {
    case idle
    case requestingPermission
    case configuring
    case running
    case reconfiguring
    case interrupted(reason: String)
    case stopping
    case unavailable(FailureKind)
    case failed(FailureKind)

    var isRunning: Bool {
        if case .running = self { return true }
        return false
    }

    var displayLabel: String {
        switch self {
        case .idle: return "Idle"
        case .requestingPermission: return "Requesting camera access"
        case .configuring: return "Starting camera"
        case .running: return "Camera running"
        case .reconfiguring: return "Reconfiguring camera"
        case .interrupted(let r): return "Camera interrupted — \(r)"
        case .stopping: return "Stopping camera"
        case .unavailable(let k): return k.userDescription
        case .failed(let k): return k.userDescription
        }
    }
}

/// A settled device control readback. Carries its generation so a late callback
/// from an old generation can be recognized and ignored for control purposes.
/// How trustworthy a readback is as a statement about the device.
///
/// REVIEW.md S05/S06: desired, applied, live and settled were conflated. A setter
/// returning does not mean the hardware has moved, and a cached snapshot is not a
/// live reading.
enum ControlSettlementState: Hashable, Sendable {
    /// The setter accepted the request; the device has not been observed yet.
    case awaitingObservation
    /// Live readings have been taken but are still changing between samples.
    case moving
    /// Consecutive live readings agree, so the values may be reported as settled.
    case settled
    /// The values did not converge inside the settle window. Reported honestly
    /// rather than presented as settled.
    case didNotSettle(observations: Int)
    /// The device reported no measurable value yet. Absence of evidence is not
    /// convergence, so this is never settled.
    case unmeasured(observations: Int)

    var isSettled: Bool { self == .settled }
    var isLiveObservation: Bool {
        switch self {
        case .moving, .settled, .didNotSettle: return true
        case .awaitingObservation, .unmeasured: return false
        }
    }

    /// True when the device reported at least one value, whether or not it has
    /// converged.
    var hasMeasurement: Bool {
        switch self {
        case .moving, .settled, .didNotSettle: return true
        case .awaitingObservation, .unmeasured: return false
        }
    }
}

struct AppliedControlSnapshot: Hashable, Sendable {
    let generation: ConfigurationGeneration
    /// The UI request revision this snapshot answers, when it came from a setter.
    /// Nil means the snapshot was produced by a periodic live read.
    var requestRevision: UInt64?
    /// The VALIDATED, clamped white-balance gains this request asked the device for.
    ///
    /// M01: the native temperature/tint converter resolves the legal gains against the
    /// device limits, and it returns them here so the settlement target is the request's
    /// OWN target rather than an inference from whatever gains are later observed.
    var resolvedWhiteBalanceTarget: WhiteBalanceGains?
    /// What this snapshot may claim. Defaults to a live observation so existing
    /// construction sites cannot accidentally claim a settled state.
    var settlement: ControlSettlementState = .moving
    /// The device's OWN adjusting flags, when the reading carries them.
    ///
    /// REVIEW.md G03: "not supplied" and "not adjusting" are different claims. Nil
    /// means the framework did not report the flag for this reading.
    var isExposureAdjusting: Bool?
    var isFocusAdjusting: Bool?
    var isWhiteBalanceAdjusting: Bool?
    let exposureChoice: ExposureChoice
    let biasEV: Double
    let observedDurationSeconds: Double?
    let observedISO: Double?
    let observedExposureTargetOffset: Double?
    let focusMode: FocusModeKind
    let focusPosition: Double?
    let whiteBalanceMode: WhiteBalanceModeKind
    let whiteBalanceGains: WhiteBalanceGains?
    let lensAperture: Double?
    let videoZoomFactor: Double
    let photoConnectionScale: Double
    let photoConnectionCrop: Double
    let capturedAtUTC: Date
    /// Explicit native capability, not inferred from a missing target.
    var isFixedFocusCamera: Bool = false
    /// Optional native gain conversion, requested only by the hardware WB UI.
    /// Display data only; never a replacement for measured capture metadata.
    var observedWhiteBalanceTemperatureAndTint: WhiteBalanceTemperatureAndTint? = nil
    var apertureChoice: ApertureChoice = .auto
    var isApertureAutomatic: Bool? = nil
    var isFixedApertureCamera: Bool = false
}

/// One delivered RAW representation, before any file work.
struct DeliveredRAWRepresentation: @unchecked Sendable {
    /// Retained for the transfer only. Ownership moves to the staging writer.
    let bytes: Data
    var isHEIF: Bool { rawPixelFormatType == 0 && rawFileType == "public.heic" }
    var isJPEG: Bool { rawPixelFormatType == 0 && rawFileType == "public.jpeg" }
    let captureID: CaptureID
    let resolvedSettingsUniqueID: Int64
    let nativeBracketIdentity: NativeBracketIdentity?
    let rawPixelFormatType: UInt32
    let rawFileType: String?
    let rawPhotoDimensions: PixelDimensions?
    /// Dimensions of the RAW pixel buffer, when the callback offered one.
    let rawPixelBufferDimensions: PixelDimensions?
    let timestampSeconds: Double?
    let metadata: [String: Any]
}

/// Identity of one bracket step as reported by AVFoundation. Mapping uses this
/// object, never arrival order (CONTRACTS.md "exposure bracket policy").
struct NativeBracketIdentity: Hashable, Sendable {
    /// Position of this step in the submitted `bracketedSettings` array.
    let submittedIndex: Int
    let kind: BracketStepKind
    /// Requested duration, when this is a manual exposure step.
    let requestedDurationSeconds: Double?
    /// Requested ISO, when this is a manual exposure step.
    let requestedISO: Double?
    /// Requested bias, when this is an auto exposure step.
    let requestedBiasEV: Double?
}

enum BracketStepKind: String, Hashable, Sendable {
    case manualExposure
    case autoExposure
    case focus
    case single
}

/// Demand on preview analysis. The union of enabled tools; one sample serves all.
struct AnalysisDemand: Hashable, Sendable {
    var needsLuminanceSample: Bool
    var histogramEnabled: Bool
    var zebrasEnabled: Bool
    var peakingEnabled: Bool
    var loupeEnabled: Bool

    static let none = AnalysisDemand(
        needsLuminanceSample: false, histogramEnabled: false, zebrasEnabled: false,
        peakingEnabled: false, loupeEnabled: false)

    var isEmpty: Bool { !needsLuminanceSample && !histogramEnabled && !zebrasEnabled && !peakingEnabled && !loupeEnabled }
    var wantsVideoOutput: Bool { !isEmpty }
}

/// Geometry snapshot for one preview layout/configuration. Every mask and loupe
/// frame carries the generation it was computed for so stale overlays can be
/// dropped on rotation or lens switch.
///
struct PreviewGeometrySnapshot: Hashable, Sendable {
    let configurationGeneration: ConfigurationGeneration
    let layoutGeneration: UInt64
    let imageDimensions: PixelDimensions
    let cleanApertureDimensions: PixelDimensions?
    let previewLayerContentRect: TCRect
    let bufferOrientation: Int
    let isMirrored: Bool
    /// Rotation applied to the analysis buffer before statistics, in degrees.
    let analysisRotationDegrees: Int
    let isVideoMirrored: Bool
    let capturedAtUTC: Date
    /// Physical screen axes are independent of the front/rear sensor rotation.
    var interfaceOrientation: DeviceOrientation? = nil

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.configurationGeneration == rhs.configurationGeneration
            && lhs.layoutGeneration == rhs.layoutGeneration
            && lhs.imageDimensions == rhs.imageDimensions
            && lhs.cleanApertureDimensions == rhs.cleanApertureDimensions
            && lhs.previewLayerContentRect == rhs.previewLayerContentRect
            && lhs.bufferOrientation == rhs.bufferOrientation
            && lhs.isMirrored == rhs.isMirrored
            && lhs.analysisRotationDegrees == rhs.analysisRotationDegrees
            && lhs.isVideoMirrored == rhs.isVideoMirrored
            && lhs.capturedAtUTC == rhs.capturedAtUTC
            && lhs.interfaceOrientation == rhs.interfaceOrientation
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(configurationGeneration)
        hasher.combine(layoutGeneration)
        hasher.combine(imageDimensions)
        hasher.combine(cleanApertureDimensions)
        hasher.combine(previewLayerContentRect)
        hasher.combine(bufferOrientation)
        hasher.combine(isMirrored)
        hasher.combine(analysisRotationDegrees)
        hasher.combine(isVideoMirrored)
        hasher.combine(capturedAtUTC)
        hasher.combine(interfaceOrientation)
    }
}

/// Native camera boundary. Implementations must not be used from MainActor for
/// configuration work; configuration happens on the service's serial queue.
/// `@preconcurrency` because the conforming production service imports a
/// pre-Swift-6 AVFoundation; the conformance is actor-isolated and therefore
/// serialized at runtime.
@preconcurrency
/// An app-owned producer of the capability of the configuration CURRENTLY in force.
///
/// REVIEW.md K03: after a media-services reset the service rebuilds its graph, but the
/// view model previously had no way to learn the rebuilt capability — `prepare` was its
/// only source, and a running model never re-prepares. Deliberately a SEPARATE protocol so
/// every existing `CameraServicing` conformer keeps compiling. This is an app interface,
/// not an Apple API.
/// Reports that a SUBMITTED request's retained RAW/durable staging is still in flight.
///
/// T02: the coordinator's retained drain deliberately outlives its caller, so the service's
/// teardown gate must know it is still staging before it tears the graph down.
protocol StagingOwnershipReporting: Sendable {
    nonisolated func noteStagingStarted(_ captureID: CaptureID)
    nonisolated func noteStagingFinished(_ captureID: CaptureID)
}

protocol CameraCapabilityProviding: Sendable {
    func currentCapability() async -> CameraCapabilitySnapshot?
}

/// Optional resource hint. It must never take a photo, reconfigure the graph,
/// change output quality/dimensions, or become a capture admission prerequisite.
protocol CaptureFormatPreparing: Sendable {
    func prepareCaptureFormat(_ format: CaptureFileFormat, generation: ConfigurationGeneration) async
}

protocol CameraControlApplying: Sendable {
    /// Applies a whole exposure/focus/WB selection as one revision.
    func applyControls(
        revision: UInt64,
        exposure: ExposureChoice,
        biasEV: Double,
        focus: FocusIntent,
        whiteBalance: WhiteBalanceIntent,
        aperture: ApertureChoice
    ) async -> Result<AppliedControlSnapshot, CaptureFailure>

}

protocol CameraServicing: CameraControlApplying {
    /// Asynchronous because the conforming service is an actor: a synchronous
    /// requirement would cross an isolation boundary and race.
    var lifecycle: CameraLifecycle { get async }
    var capabilitySnapshot: CameraCapabilitySnapshot { get async }

    func prepare(desiredCamera: PhysicalCameraKind?) async -> Result<CameraCapabilitySnapshot, CaptureFailure>
    func start() async -> Result<Void, CaptureFailure>
    func stop() async
    func switchPhysicalCamera(to kind: PhysicalCameraKind) async -> Result<CameraCapabilitySnapshot, CaptureFailure>


    func setFocusPoint(
        normalizedDevicePoint: NormalizedDevicePoint,
        isTapToFocus: Bool
    ) async -> Result<Void, CaptureFailure>

    /// The last applied/read snapshot. Async because the conforming service is an
    /// actor: a synchronous witness would be an off-executor call (REVIEW.md C02).
    func lastAppliedSnapshot() async -> AppliedControlSnapshot?
    /// Reads the device's actual current control values.
    func currentControlReadback() async -> AppliedControlSnapshot?
    /// Publishes live control readings so the UI observes the device instead of
    /// replaying its own setter snapshot (REVIEW.md C05).
    var controlReadbackStream: AsyncStream<AppliedControlSnapshot> { get }

    /// Recorded native session conditions (interruption, runtime error, media-services
    /// reset, start/stop), so the owner of capture admission can react to what the
    /// framework observed. REVIEW.md F02.
    var sessionConditionStream: AsyncStream<CameraLifecycle> { get }
    /// The condition currently recorded, for a consumer that attaches late.
    func recordedSessionCondition() async -> CameraLifecycle

    /// Submits one capture request. The service retains its own delegate until the
    /// terminal callback, then releases it.
    ///
    /// Async because the conforming service is an actor: a synchronous witness
    /// would be called from another executor, which `@preconcurrency` merely
    /// defers rather than makes safe (REVIEW.md C02).
    func beginCapture(intent: CaptureIntent) async -> any CaptureRequestTicket

    /// Enables/disables the union demand and the video output.
    ///
    /// The full tool configuration (peaking/zebra thresholds, loupe centre and
    /// magnification) travels separately in `setAnalysisRequest`, so enabling an
    /// output can never reset a user's settings (REVIEW.md C08).
    func setAnalysisDemand(_ demand: AnalysisDemand) async
    /// The complete analysis request the UI currently wants, or nil for none.
    func setAnalysisRequest(_ request: AnalysisRequest?) async
    func updatePreviewGeometry(_ geometry: PreviewGeometrySnapshot?) async

    /// Stream of analysis outputs. Latest-only for overlay data; capture events
    /// use their own lossless channel.
    var analysisStream: BoundedOrderedSequence<AnalysisOutput> { get }

    /// The display-only bridge the preview layer renders through.
    ///
    /// Async because establishing the handle crosses the actor boundary properly
    /// instead of exposing an actor-isolated session synchronously. The returned
    /// bridge is immutable and `Sendable`; the session it publishes must only be
    /// assigned to a preview layer, never configured (REVIEW.md C02).
    func previewDisplayBridge() async -> PreviewDisplayBridge

    /// Records the RAW dimensions measured from a real capture on this device.
    /// This is the only path that can move observed dimensions off `unknown`.
    func recordMeasuredRAWDimensions(_ dimensions: PixelDimensions, evidenceOrigin: String) async
}

/// Optional production recovery seam. A native runtime failure may leave work
/// submitted even after the UI's request timed out. Never stop/rebuild over it.
protocol CameraRecoveryStopping: Sendable {
    func stopForTransientRecovery() async -> Result<Void, CaptureFailure>
}

/// Handle for one submitted capture request.
///
/// REVIEW.md C01: the terminal result is an immutable, awaited value rather than
/// a single-consumer stream. `awaitTerminal()` may be called by any number of
/// parties, at any time, and always returns the same recorded outcome; it never
/// synthesises success when the native layer has not reported anything.
protocol CaptureRequestTicket: Sendable {
    var captureID: CaptureID { get }
    var uniqueSettingsID: Int64 { get }
    /// Delivered RAW representations in callback order. Loss-critical: every
    /// representation the delegate produced appears here, and a delivery that
    /// could not be buffered is reported through `representationsOverflowed`.
    func representationStream() -> BoundedOrderedSequence<DeliveredRAWRepresentation>
    /// Representations refused because the bounded backlog was full. Non-zero is
    /// a real delivery failure, not a silent drop.
    func representationsOverflowed() -> Int
    /// Waits for, and returns, the single terminal outcome.
    func awaitTerminal() async -> NativeRequestOutcome
    /// The terminal outcome if it has already arrived, otherwise nil.
    func currentTerminal() -> NativeRequestOutcome?
    /// The first terminal's diagnostic, replayable after awaitTerminal. A
    /// partial outcome must keep its failure separately from retained bytes.
    func terminalFailure() -> CaptureFailure?
    /// Resolved dimensions, latest-value only.
    var resolvedDimensions: AsyncStream<PixelDimensions?> { get }
    var shutterFeedbackEvents: AsyncStream<CaptureShutterFeedback> { get }
}

/// Output of the shared preview analysis pipeline. Small value snapshots only;
/// the native preview never becomes a full-frame SwiftUI image stream.
enum AnalysisOutput: Sendable {
    case geometryChanged(PreviewGeometrySnapshot)
    case histogram(HistogramSnapshot)
    case masks(MaskSnapshot)
    case loupe(LoupeSnapshot)
    case analysisUnavailable(reason: String)
}

/// Encoded processed-preview RGB channels, not sensor clipping or scene-linear RGB.
struct PreviewRGBHistogram: Hashable, Sendable {
    let red: [UInt32]
    let green: [UInt32]
    let blue: [UInt32]
    let sampleCount: UInt32
    let matrix: String
}

struct HistogramSnapshot: Hashable, Sendable {
    /// Exactly 256 bins; bins sum to `sampleCount`.
    let bins: [UInt32]
    let sampleCount: UInt32
    let geometryGeneration: UInt64
    let configurationGeneration: ConfigurationGeneration
    let isFullRange: Bool
    let mappedAtUTC: Date
    var rgb: PreviewRGBHistogram? = nil

    static func empty(configurationGeneration: ConfigurationGeneration) -> HistogramSnapshot {
        HistogramSnapshot(bins: [UInt32](repeating: 0, count: 256),
                          sampleCount: 0,
                          geometryGeneration: 0,
                          configurationGeneration: configurationGeneration,
                          isFullRange: true,
                          mappedAtUTC: Date())
    }
}

/// Compact binary masks produced by one shared downsampled luma pass. Kept as
/// `[UInt8]` so nothing large crosses an isolation boundary.
struct MaskSnapshot: Hashable, Sendable {
    let width: Int
    let height: Int
    let geometryGeneration: UInt64
    let configurationGeneration: ConfigurationGeneration
    /// One byte per pixel, 0 or 255, row-major. Nil when peaking is off.
    let peakingMask: [UInt8]?
    /// One byte per pixel, 0 or 255, row-major. Nil when zebras are off.
    let zebraMask: [UInt8]?
    let peakingThreshold: Double
    let zebraThreshold: Double
    let mappedAtUTC: Date
}

/// Named RGBA8 display buffer for the focus loupe.
struct LoupeSnapshot: Sendable {
    let width: Int
    let height: Int
    let rgbaBytes: [UInt8]
    let geometryGeneration: UInt64
    let configurationGeneration: ConfigurationGeneration
    /// Display magnification actually applied (2 or 4).
    let magnification: Double
    let mappedAtUTC: Date
    /// Native color crops preserve their inspection point through queued UI work.
    var sampledCenter: NormalizedDevicePoint? = nil
}

/// Ephemeral native shutter cue; never evidence of delivery or saving.
struct CaptureShutterFeedback: Hashable, Sendable {
    let captureID: CaptureID
    let sequenceID: SequenceID?
    let ordinal: Int?
    let plannedCount: Int?
    let generation: ConfigurationGeneration
    let capturedAtUTC: Date
}
extension CaptureRequestTicket {
    func terminalFailure() -> CaptureFailure? {
        switch currentTerminal() {
        case .failed(let failure): return failure
        case .partial(_, let detail):
            return CaptureFailure(kind: .captureFailed(detail: detail), operation: "capturePhoto")
        case .success, nil: return nil
        }
    }
    var shutterFeedbackEvents: AsyncStream<CaptureShutterFeedback> { AsyncStream { $0.finish() } }
}

// Existing callers explicitly request automatic aperture through this overload.
extension CameraControlApplying {
    func applyControls(revision: UInt64, exposure: ExposureChoice, biasEV: Double,
                       focus: FocusIntent, whiteBalance: WhiteBalanceIntent) async -> Result<AppliedControlSnapshot, CaptureFailure> {
        await applyControls(revision: revision, exposure: exposure, biasEV: biasEV,
                            focus: focus, whiteBalance: whiteBalance, aperture: .auto)
    }
}
