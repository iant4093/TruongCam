import Foundation
@preconcurrency import AVFoundation
import ImageIO

/// JPEG is an explicitly requested processed original. This factory cannot emit
/// a RAW companion, choose HEIF, or enlarge the committed photo request ceiling.
enum NativeJPEGPhotoSettings {
    static func make(requestedDimensions: PixelDimensions, maximumDimensions: PixelDimensions,
                     supportedFileTypes: [AVFileType], supportedCodecs: [AVVideoCodecType]) throws -> AVCapturePhotoSettings {
        guard supportedFileTypes.contains(.jpg), supportedCodecs.contains(.jpeg),
              requestedDimensions.isValid, requestedDimensions == maximumDimensions,
              let width = Int32(exactly: requestedDimensions.width),
              let height = Int32(exactly: requestedDimensions.height) else {
            throw CaptureFailure(kind: .unsupportedCapability(
                detail: "JPEG or its frozen dimensions are unavailable on this committed photo output."),
                operation: "makeJPEGSettings")
        }
        let settings = AVCapturePhotoSettings(rawPixelFormatType: 0, rawFileType: nil,
            processedFormat: [AVVideoCodecKey: AVVideoCodecType.jpeg], processedFileType: .jpg)
        settings.maxPhotoDimensions = CMVideoDimensions(width: width, height: height)
        settings.photoQualityPrioritization = .speed
        settings.flashMode = .off
        settings.previewPhotoFormat = nil
        return settings
    }

    /// Issue the exact JPEG-only settings ahead of a possible real shutter.
    /// AVFoundation's public preparation API allocates resources without taking
    /// a photo. Its completion is deliberately disconnected from admission.
    @discardableResult
    static func prepareResources(_ settings: AVCapturePhotoSettings,
                                 signature: PhotoResourcePreparationOwner.Signature,
                                 owner: PhotoResourcePreparationOwner,
                                 isCurrent: @escaping @Sendable () -> Bool,
                                 issue: ([AVCapturePhotoSettings], @escaping @Sendable (Bool, Error?) -> Void) -> Void) -> Bool {
        guard isCurrent(), signature.rawPixelFormat == 0,
              signature.rawFileType == AVFileType.jpg.rawValue,
              settings.rawPhotoPixelFormatType == 0, settings.rawFileType == nil,
              settings.processedFileType == .jpg,
              settings.format?[AVVideoCodecKey] as? String == AVVideoCodecType.jpeg.rawValue,
              signature.dimensions == PixelDimensions(width: Int(settings.maxPhotoDimensions.width),
                                                       height: Int(settings.maxPhotoDimensions.height)),
              let token = owner.reserve(signature) else { return false }
        guard isCurrent() else { _ = owner.retire(ifOwnedBy: token); return false }
        #if DEBUG
        let began = ProcessInfo.processInfo.systemUptime
        #endif
        issue([settings]) { prepared, error in
            let current = isCurrent()
            let recorded = owner.complete(token, prepared: current && prepared && error == nil)
            #if DEBUG
            print("TruongCam timing jpeg-resource-preparation=\(Int((ProcessInfo.processInfo.systemUptime - began) * 1000))ms prepared=\(prepared) current=\(current) recorded=\(recorded) error=\(error.map { String(describing: $0) } ?? "none")")
            #endif
        }
        return true
    }
}

/// Applied before serialization, so an unexpected callback never becomes an
/// original of a different format. The persisted bytes receive the same cheap
/// container check; no image decode or re-encoding is performed here.
enum NativePhotoRepresentationPolicy {
    enum Serialization: Equatable { case bayerThumbnailFree, processedOriginal }

    static func serialization(format: CaptureFileFormat, camera: PhysicalCameraKind,
                              rawPixelFormat: UInt32, fileType: String?, isRawPhoto: Bool) -> Serialization? {
        switch format {
        case .bayerDNG:
            return isRawPhoto && rawPixelFormat != 0 && fileType == AVFileType.dng.rawValue
                && AVCapturePhotoOutput.isBayerRAWPixelFormat(rawPixelFormat) ? .bayerThumbnailFree : nil
        case .frontHEIF:
            return !isRawPhoto && camera == .front && rawPixelFormat == 0 && fileType == AVFileType.heic.rawValue
                ? .processedOriginal : nil
        case .jpeg:
            return !isRawPhoto && rawPixelFormat == 0 && fileType == AVFileType.jpg.rawValue
                ? .processedOriginal : nil
        }
    }

    static func containerMatches(_ data: Data, format: CaptureFileFormat) -> Bool {
        guard let source = CGImageSourceCreateWithData(data as CFData,
            [kCGImageSourceShouldCache: false] as CFDictionary),
              CGImageSourceGetCount(source) > 0,
              CGImageSourceGetStatus(source) == .statusComplete,
              let type = CGImageSourceGetType(source) as String? else { return false }
        switch format {
        case .jpeg: return type == AVFileType.jpg.rawValue
        case .frontHEIF: return type == AVFileType.heic.rawValue || type == "public.heif"
        case .bayerDNG: return type == AVFileType.dng.rawValue
        }
    }
}
