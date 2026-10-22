import Foundation

// CONTRACTS.md "Concrete capability and error snapshots": capability fields must
// distinguish unknown from unsupported. There is no boolean that conflates
// "not tested" with "not available", and no fabricated device profile.

/// Tri-state discovery result. `unknown` means we have not been able to ask.
enum DiscoveryStatus<Value: Hashable & Sendable>: Hashable, Sendable {
    case unknown(reason: String)
    case available(Value)
    case unavailable(reason: String)

    var value: Value? {
        if case .available(let v) = self { return v }
        return nil
    }

    var isAvailable: Bool { value != nil }

    var statusLabel: String {
        switch self {
        case .unknown: return "Unknown"
        case .available: return "Available"
        case .unavailable: return "Unavailable"
        }
    }

    var detailLabel: String {
        switch self {
        case .unknown(let reason): return "Unknown — \(reason)"
        case .available: return "Available"
        case .unavailable(let reason): return "Unavailable — \(reason)"
        }
    }
}

/// Physical rear camera kinds this app understands. Virtual/composite devices
/// are recorded for diagnostics but are never silently substituted for a
/// physical lens.
enum PhysicalCameraKind: String, Hashable, Sendable, Codable, CaseIterable {
    case ultraWide
    case wide
    case telephoto
    case front
    case unknown

    /// Honest fallback names when the discovered device has no nominal
    /// full-frame-equivalent focal length. A kind cannot identify a lens's mm:
    /// different iPhone generations use different optics of the same kind.
    var displayLabel: String {
        switch self {
        case .ultraWide: return "Ultra"
        case .wide: return "Wide"
        case .front: return "Front"
        case .telephoto: return "Tele"
        case .unknown: return "Camera"
        }
    }

    var accessibilityLabel: String {
        switch self {
        case .ultraWide: return "Ultra-wide physical camera"
        case .wide: return "Wide physical camera"
        case .front: return "Front camera"
        case .telephoto: return "Telephoto physical camera"
        case .unknown: return "Unknown physical camera"
        }
    }

    /// Kept source-compatible with older callers. Only an actual device's
    /// capability or original EXIF may supply millimetres; kinds never do.
    var expectedEquivalentFocalLengthMM: Double? { nil }

    static let rearSelectionOrder: [PhysicalCameraKind] = [.ultraWide, .wide, .telephoto]
}

/// A selectable photo-dimension candidate advertised by the active format.
struct PhotoDimensionCandidate: Hashable, Sendable {
    let dimensions: PixelDimensions
    /// True when the candidate came from `supportedMaxPhotoDimensions`.
    let advertised: Bool
}

/// Advertised format facts. Advertised dimensions are a request ceiling, never
/// proof of actual output.
struct FormatCapability: Hashable, Sendable {
    var formatIdentifier: String
    var videoDimensions: PixelDimensions
    var cleanApertureDimensions: PixelDimensions?
    var supportedMaxPhotoDimensions: [PixelDimensions]
    var bayerPixelFormats: [UInt32]
    var rawFileTypes: [String]
    let supportsCustomExposureMode: DiscoveryStatus<Bool>
    var supportedPriorityCombinations: Set<ExposureModeKind>
    var exposureLimits: ExposureLimits
    let minLensAperture: Double?
    let maxLensAperture: Double?
    let focusLimits: FocusLimits
    let whiteBalanceLimits: WhiteBalanceLimits
    var videoFrameRateRanges: [ClosedRange<Double>]
    let isVideoStabilizationSupported: Bool
    let secondaryNativeResolutionZoomFactors: [Double]
}

/// Everything discovered about one physical rear camera. Attach the input and
/// output before asking about raw formats; a disconnected output reporting no
/// formats is not a device-level negative result.
struct PhysicalCameraCapability: Hashable, Sendable {
    let kind: PhysicalCameraKind
    let deviceType: String
    let uniqueDeviceIdentifier: String?
    let modelIdentifier: String
    var formats: [FormatCapability]
    var selectedFormatIndex: Int?
    var bayerRAWDiscovery: DiscoveryStatus<[UInt32]>
    var rawFileTypeDiscovery: DiscoveryStatus<[String]>
    var nativeBracketCountDiscovery: DiscoveryStatus<Int>
    /// Measured on device only. `unknown` until a real capture is inspected.
    let observedRAWDimensions: DiscoveryStatus<PixelDimensions>
    let observedRAWEvidenceOrigin: String?
    let videoZoomFactorAtDiscovery: Double

    /// AVCaptureDevice.nominalFocalLengthIn35mmFilm, a nominal diagonal
    /// full-frame-equivalent measurement. It is not the physical lens focal
    /// length, a digital zoom factor, actual photo EXIF or a RAW capability.
    /// Missing on historical/synthetic snapshots; zero/nonfinite SDK values
    /// remain unknown rather than inheriting an iPhone-specific model table.
    var nominalEquivalentFocalLengthMM: Double? = nil

    var validNominalEquivalentFocalLengthMM: Double? {
        guard let value = nominalEquivalentFocalLengthMM, value.isFinite, value > 0 else { return nil }
        return value
    }

    var lensDisplayLabel: String {
        guard let value = validNominalEquivalentFocalLengthMM else { return kind.displayLabel }
        return Self.nominalMillimetresLabel(value)
    }

    var lensAccessibilityLabel: String {
        guard let value = validNominalEquivalentFocalLengthMM else { return kind.accessibilityLabel }
        let millimetres = Self.nominalMillimetresLabel(value).dropLast(2)
        return "\(kind.accessibilityLabel), approximately \(millimetres) millimetres full-frame equivalent"
    }

    private static func nominalMillimetresLabel(_ value: Double) -> String {
        let digits = String(format: "%.1f", locale: Locale(identifier: "en_US_POSIX"), value)
        return (digits.hasSuffix(".0") ? String(digits.dropLast(2)) : digits) + "mm"
    }
}

/// The whole-camera snapshot for one configuration generation.
struct CameraCapabilitySnapshot: Hashable, Sendable {
    let generation: ConfigurationGeneration
    let hardwareModel: String
    let osVersion: String
    let sdkVersion: String
    var physicalCameras: [PhysicalCameraCapability]
    let selectedCameraKind: PhysicalCameraKind?
    let configuredPhotoDimensions: PixelDimensions?
    let configuredPhotoDimensionsEvidence: String
    let previewAnalysisFormat: PreviewAnalysisFormat?
    var bayerCaptureSupported: DiscoveryStatus<Bool>
    let probeTimestampUTC: Date
    let notes: [String]

    /// Explicit front-only processed capture authorization, confirmed by the connected output.
    var frontHEIFSupported = false
    /// Confirmed processed-only JPEG codec/container support of the current graph.
    var jpegSupported = false
    var jpegMaximumDimensions: PixelDimensions? = nil
    var photoCaptureSupport: DiscoveryStatus<Bool> {
        jpegSupported || (frontHEIFSupported && selectedCameraKind == .front) ? .available(true) : bayerCaptureSupported
    }

    static func empty(generation: ConfigurationGeneration, reason: String) -> CameraCapabilitySnapshot {
        CameraCapabilitySnapshot(
            generation: generation,
            hardwareModel: "unknown",
            osVersion: "unknown",
            sdkVersion: "unknown",
            physicalCameras: [],
            selectedCameraKind: nil,
            configuredPhotoDimensions: nil,
            configuredPhotoDimensionsEvidence: reason,
            previewAnalysisFormat: nil,
            bayerCaptureSupported: .unknown(reason: reason),
            probeTimestampUTC: Date(),
            notes: [reason])
    }

    func camera(_ kind: PhysicalCameraKind) -> PhysicalCameraCapability? {
        physicalCameras.first { $0.kind == kind }
    }
}

/// Actual pixel format/geometry of the analysis video connection. Recorded
/// because a wrong assumption here silently corrupts every preview aid.
struct PreviewAnalysisFormat: Hashable, Sendable {
    let pixelFormatFourCC: UInt32
    let fourCCDisplay: String
    let dimensions: PixelDimensions
    var cleanApertureDimensions: PixelDimensions?
    let isPlanar: Bool
    let planeCount: Int
    /// Full range (0…255 nominal) versus video range (16…235 nominal luma).
    let isFullRange: Bool
    let lumaBytesPerRow: Int
    let colorPrimaries: String?
    let transferFunction: String?
    let ycbcrMatrix: String?
    let evidence: String
}

/// Optional embedded thumbnail pixel format requested alongside the RAW.
struct EmbeddedThumbnailChoice: Hashable, Sendable {
    let codecFourCC: UInt32
    let codecDisplay: String
    let pixelDimensions: PixelDimensions?
}
