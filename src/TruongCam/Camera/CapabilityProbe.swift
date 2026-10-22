import Foundation
@preconcurrency import AVFoundation

// ARCHITECTURE.md "Capability discovery and resolution policy" and HANDOFF.md
// Gate A "Camera probe".
//
// All advertised values here are runtime data read from the installed OS. There
// is no model-name table, no assumed 48 MP support and no invented ISO/shutter
// range. Actual RAW output size stays `unknown` until a real capture is
// inspected on the device.

/// Discovered physical rear cameras plus the RAW facts that only become visible
/// after the output is attached to a session.
struct CameraDiscoveryResult: Sendable {
    let physicalCameras: [PhysicalCameraCapability]
    let attachedRawPixelFormats: [UInt32]
    let attachedRawFileTypes: [String]
    let maxBracketedCapturePhotoCount: Int
    let isAppleProRAWSupported: Bool
    let isAppleProRAWEnabled: Bool
    let notes: [String]
}

/// Reads capability facts off AVFoundation. Everything is snapshot-valued; no
/// AVFoundation reference leaves this file.
struct CameraCapabilityProbe: Sendable {
    /// Rear physical device types v1 understands. Virtual/composite devices are
    /// recorded for diagnostics but never silently substituted for a lens.
    static let physicalRearDeviceTypes: [AVCaptureDevice.DeviceType] = [
        .builtInUltraWideCamera,
        .builtInWideAngleCamera,
        .builtInTelephotoCamera,
    ]

    static func kind(for deviceType: AVCaptureDevice.DeviceType, position: AVCaptureDevice.Position = .back) -> PhysicalCameraKind {
        if position == .front { return .front }
        switch deviceType {
        case .builtInUltraWideCamera: return .ultraWide
        case .builtInWideAngleCamera: return .wide
        case .builtInTelephotoCamera: return .telephoto
        default: return .unknown
        }
    }

    static func deviceTypeName(_ deviceType: AVCaptureDevice.DeviceType) -> String {
        deviceType.rawValue
    }

    /// Enumerates rear physical cameras in a stable, deliberate order
    /// (ultra-wide, wide, telephoto) so the UI can use discovered millimetre labels that select a
    /// physical device rather than a digital zoom factor.
    static func discoverDevices(
        discoverySession: AVCaptureDevice.DiscoverySession
    ) -> [AVCaptureDevice] {
        let devices = discoverySession.devices.filter { device in
            guard Self.physicalRearDeviceTypes.contains(device.deviceType) else { return false }
            // Exclude any virtual/composite device even if it reports a physical
            // type through a continuation stream.
            return !device.isVirtualDevice
        }
        return devices.sorted { lhs, rhs in
            let lhsIndex = physicalRearDeviceTypes.firstIndex(of: lhs.deviceType) ?? Int.max
            let rhsIndex = physicalRearDeviceTypes.firstIndex(of: rhs.deviceType) ?? Int.max
            return lhsIndex == rhsIndex ? lhs.uniqueID < rhs.uniqueID : lhsIndex < rhsIndex
        }
    }

    /// Builds the advertised capability record for one device. `rawFormats` and
    /// `rawFileTypes` must come from an output that is already connected to the
    /// session; pass `nil` when the output is not attached, which is recorded as
    /// `unknown` rather than as an unsupported result.
    static func capability(
        for device: AVCaptureDevice,
        selectedFormatIndex: Int?,
        rawFormats: [UInt32]?,
        rawFileTypes: [String]?,
        nativeBracketCount: Int?,
        baseline: PhysicalCameraCapability? = nil
    ) -> PhysicalCameraCapability {
        // Device/session-lifetime passive enumeration is reused; native facts for
        // the selected format and connected Bayer/container answers remain fresh.
        // Reset/failure discards the prepared device/input holding this baseline.
        let nativeFormats = device.formats
        var formats: [FormatCapability]
        if let baseline, baseline.uniqueDeviceIdentifier == device.uniqueID, baseline.formats.count == nativeFormats.count {
            formats = baseline.formats
            if let index = selectedFormatIndex, nativeFormats.indices.contains(index) {
                formats[index] = Self.formatCapability(format:nativeFormats[index],index:index,device:device)
            }
        } else {
            formats = nativeFormats.enumerated().map { index, format in
                Self.formatCapability(format:format,index:index,device:device)
            }
        }

        let bayerDiscovery: DiscoveryStatus<[UInt32]>
        if let rawFormats {
            bayerDiscovery = .available(rawFormats)
        } else {
            bayerDiscovery = .unknown(reason: "RAW formats are only reported after the photo output is connected to a session")
        }

        let fileTypeDiscovery: DiscoveryStatus<[String]>
        if let rawFileTypes {
            fileTypeDiscovery = .available(rawFileTypes)
        } else {
            fileTypeDiscovery = .unknown(reason: "RAW file types are only reported after the photo output is connected")
        }

        let bracketDiscovery: DiscoveryStatus<Int>
        if let nativeBracketCount {
            bracketDiscovery = nativeBracketCount > 0
                ? .available(nativeBracketCount)
                : DiscoveryStatus.unavailable(
                    reason: "This format reports maxBracketedCapturePhotoCount 0")
        } else {
            bracketDiscovery = .unknown(reason: "Bracket count requires a connected photo output")
        }

        return PhysicalCameraCapability(
            kind: kind(for: device.deviceType, position: device.position),
            deviceType: deviceTypeName(device.deviceType),
            uniqueDeviceIdentifier: device.uniqueID,
            modelIdentifier: device.modelID,
            formats: formats,
            selectedFormatIndex: selectedFormatIndex,
            bayerRAWDiscovery: bayerDiscovery,
            rawFileTypeDiscovery: fileTypeDiscovery,
            nativeBracketCountDiscovery: bracketDiscovery,
            // Measurement requires an actual capture; never guessed here.
            observedRAWDimensions: .unknown(reason: "No capture has been measured in this configuration"),
            observedRAWEvidenceOrigin: nil,
            videoZoomFactorAtDiscovery: Double(device.videoZoomFactor),
            nominalEquivalentFocalLengthMM: nominalEquivalentFocalLength(for: device))
    }

    /// iOS 26+ supplies the nominal photo field of view directly. The app's
    /// deployment floor remains iOS 27; do not reverse-engineer photo optics
    /// from cropped video FOV, a zoom ratio or an iPhone model-name table.
    static func nominalEquivalentFocalLength(for device: AVCaptureDevice) -> Double? {
        guard !device.isVirtualDevice else { return nil }
        let value = Double(device.nominalFocalLengthIn35mmFilm)
        return value.isFinite && value > 0 ? value : nil
    }

    static func formatCapability(
        format: AVCaptureDevice.Format,
        index: Int,
        device: AVCaptureDevice
    ) -> FormatCapability {
        let dimensions = PixelDimensions(
            width: Int(format.formatDescription.dimensions.width),
            height: Int(format.formatDescription.dimensions.height))

        let cleanAperture: PixelDimensions? = {
            let ext = CMVideoFormatDescriptionGetCleanAperture(
                format.formatDescription, originIsAtTopLeft: false)
            let width = Int(abs(ext.size.width).rounded())
            let height = Int(abs(ext.size.height).rounded())
            guard width > 0, height > 0 else { return nil }
            return PixelDimensions(width: width, height: height)
        }()

        let maxPhotoDimensions = format.supportedMaxPhotoDimensions.map {
            PixelDimensions(width: Int($0.width), height: Int($0.height))
        }

        let isCustomSupported = device.isExposureModeSupported(.custom)
        let supportsCustom: DiscoveryStatus<Bool> = .available(isCustomSupported)

        // Priority combinations are probed with the *Auto* constants, which is
        // what distinguishes a priority mode from a locked value.
        var combinations: Set<ExposureModeKind> = [.auto]
        if isCustomSupported {
            if format.supportsExposureModeCustom(
                lensAperture: AVCaptureDevice.currentLensAperture,
                duration: AVCaptureDevice.currentExposureDuration,
                iso: AVCaptureDevice.autoISO) {
                combinations.insert(.shutterPriority)
            }
            if format.supportsExposureModeCustom(
                lensAperture: AVCaptureDevice.currentLensAperture,
                duration: AVCaptureDevice.autoExposureDuration,
                iso: AVCaptureDevice.currentISO) {
                combinations.insert(.isoPriority)
            }
            if format.supportsExposureModeCustom(
                lensAperture: AVCaptureDevice.currentLensAperture,
                duration: AVCaptureDevice.currentExposureDuration,
                iso: AVCaptureDevice.currentISO) {
                combinations.insert(.manual)
            }
        }

        let exposureLimits = ExposureLimits(
            minDurationSeconds: format.minExposureDuration.seconds,
            maxDurationSeconds: format.maxExposureDuration.seconds,
            minISO: Double(format.minISO),
            maxISO: Double(format.maxISO),
            minBiasEV: Double(device.minExposureTargetBias),
            maxBiasEV: Double(device.maxExposureTargetBias))

        let focusLimits = FocusLimits(
            supportsCustomLensPosition: device.isLockingFocusWithCustomLensPositionSupported,
            supportsPointOfInterest: device.isFocusPointOfInterestSupported,
            supportsContinuousAutoFocus: device.isFocusModeSupported(.continuousAutoFocus),
            supportsAutoFocus: device.isFocusModeSupported(.autoFocus),
            // Endpoint direction is not assumed; it must be measured on device.
            positionZeroDirectionVerified: false)

        let whiteBalanceLimits: WhiteBalanceLimits
        if device.isWhiteBalanceModeSupported(.locked) {
            whiteBalanceLimits = WhiteBalanceLimits.available(
                maxGain: Double(device.maxWhiteBalanceGain),
                supportsCustomGains: device.isLockingWhiteBalanceWithCustomDeviceGainsSupported,
                supportsTemperatureAndTint: true)
        } else {
            whiteBalanceLimits = WhiteBalanceLimits.unavailable
        }

        let frameRates: [ClosedRange<Double>] = format.videoSupportedFrameRateRanges.map {
            let lower = Double($0.minFrameRate)
            let upper = Double($0.maxFrameRate)
            return lower...upper
        }

        return FormatCapability(
            formatIdentifier: "\(index):\(dimensions.width)x\(dimensions.height):\(FourCC.string(from: format.formatDescription.mediaSubType.rawValue))",
            videoDimensions: dimensions,
            cleanApertureDimensions: cleanAperture,
            supportedMaxPhotoDimensions: maxPhotoDimensions,
            bayerPixelFormats: [],
            rawFileTypes: [],
            supportsCustomExposureMode: supportsCustom,
            supportedPriorityCombinations: combinations,
            exposureLimits: exposureLimits,
            minLensAperture: Double(format.minLensAperture),
            maxLensAperture: Double(format.maxLensAperture),
            focusLimits: focusLimits,
            whiteBalanceLimits: whiteBalanceLimits,
            videoFrameRateRanges: frameRates,
            isVideoStabilizationSupported: format.isVideoStabilizationModeSupported(.standard),
            secondaryNativeResolutionZoomFactors: format.secondaryNativeResolutionZoomFactors.map { Double($0) })
    }
}

/// Chooses a real, legal capture tuple on one physical camera.
///
/// REVIEW.md C04: the previous code never assigned `device.activeFormat` and
/// published `selectedFormatIndex: nil`, so every control limit and requested
/// dimension came from an arbitrary first format that had nothing to do with the
/// device. Selection is now explicit, recorded and validated.
extension CMTime {
    /// Seconds for a valid CMTime, or `Double.nan` when the value is not usable.
    /// Invalid times must never be treated as zero.
    var seconds: Double {
        guard isValid, !isIndefinite, !isPositiveInfinity, !isNegativeInfinity else { return .nan }
        let value = Double(value) / Double(timescale)
        return value.isFinite ? value : .nan
    }
}
