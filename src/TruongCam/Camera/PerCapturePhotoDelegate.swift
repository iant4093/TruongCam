import Foundation
import Synchronization
@preconcurrency import AVFoundation

/// The AVFoundation delegate. One instance per native request.
final class PerCapturePhotoDelegate: NSObject, AVCapturePhotoCaptureDelegate, @unchecked Sendable {
    let request: PerCaptureRequest
    // AVFoundation may spend hundreds of ms flattening the first photo. Leave
    // its callback immediately and retain the immutable photo on our bounded,
    // per-request serial worker. Terminal publication uses the SAME worker.
    private let serialization = OrderedCaptureWork()
    private let representationCustomizer = NoEmbeddedThumbnailCustomizer()
    /// Maps a submitted bracket step's `AVCaptureBracketedStillImageSettings`
    /// object to its identity. Mapping is by object identity from the submitted
    /// array, never by callback arrival order.
    private let bracketIdentities: [ObjectIdentifier: NativeBracketIdentity]
    private let lock = NSLock()
    private var usedBracketIdentities: Set<ObjectIdentifier> = []
    #if DEBUG
    private let nativeBegan = ProcessInfo.processInfo.systemUptime
    #endif

    init(request: PerCaptureRequest,
         bracketIdentities: [(AVCaptureBracketedStillImageSettings, NativeBracketIdentity)]) {
        self.request = request
        var map: [ObjectIdentifier: NativeBracketIdentity] = [:]
        for (settings, identity) in bracketIdentities {
            map[ObjectIdentifier(settings)] = identity
        }
        self.bracketIdentities = map
        super.init()
    }

    func identity(for settings: AVCaptureBracketedStillImageSettings?) -> NativeBracketIdentity? {
        guard let settings else { return nil }
        lock.lock()
        defer { lock.unlock() }
        let key = ObjectIdentifier(settings)
        // A duplicate callback for the same submitted step is still attributed
        // to that step; the pipeline deduplicates by capture identity.
        usedBracketIdentities.insert(key)
        return bracketIdentities[key]
    }

    // MARK: AVCapturePhotoCaptureDelegate

    func photoOutput(_ output: AVCapturePhotoOutput,
                     willBeginCaptureFor resolvedSettings: AVCaptureResolvedPhotoSettings) {
        guard request.acceptsNativeSettingsID(resolvedSettings.uniqueID) else {
            request.noteRepresentationError("Resolved dimensions belonged to another native request.")
            return
        }
        request.recordResolvedDimensions(Self.dimensions(from: request.rawPixelFormatType == 0 ? resolvedSettings.photoDimensions : resolvedSettings.rawPhotoDimensions))
        #if DEBUG
        let dimensions = request.rawPixelFormatType == 0 ? resolvedSettings.photoDimensions : resolvedSettings.rawPhotoDimensions
        print("TruongCam photo-resolved format=\(request.intent.fileFormat.rawValue) dimensions=\(dimensions.width)x\(dimensions.height) processing=\(resolvedSettings.photoProcessingTimeRange.start.seconds)...\(resolvedSettings.photoProcessingTimeRange.end.seconds) nativeID=\(resolvedSettings.uniqueID)")
        #endif
    }

    func photoOutput(_ output: AVCapturePhotoOutput,
                     willCapturePhotoFor resolvedSettings: AVCaptureResolvedPhotoSettings) {
        // Acquisition is starting; this is not persistence.
        request.recordNativeShutter(settingsID: resolvedSettings.uniqueID)
        #if DEBUG
        print("TruongCam timing native-will-capture=\(Int((ProcessInfo.processInfo.systemUptime - nativeBegan) * 1000))ms nativeID=\(resolvedSettings.uniqueID)")
        #endif
    }

    func photoOutput(_ output: AVCapturePhotoOutput,
                     didFinishProcessingPhoto photo: AVCapturePhoto,
                     error: Error?) {
        #if DEBUG
        let callbackBegan = ProcessInfo.processInfo.systemUptime
        print("TruongCam callback processing main=\(Thread.isMainThread)")
        print("TruongCam timing native-processing-callback=\(Int((callbackBegan-nativeBegan)*1000))ms nativeID=\(photo.resolvedSettings.uniqueID)")
        #endif
        serialization.enqueue { [self, photo] in
            #if DEBUG
            print("TruongCam timing serialization-queue=\(Int((ProcessInfo.processInfo.systemUptime-callbackBegan)*1000))ms main=\(Thread.isMainThread) nativeID=\(photo.resolvedSettings.uniqueID)")
            #endif
            autoreleasepool { serialize(photo: photo, error: error) }
        }
    }

    private func serialize(photo: AVCapturePhoto, error: Error?) {
        guard request.acceptsNativeSettingsID(photo.resolvedSettings.uniqueID) else {
            request.noteRepresentationError("The photo callback belonged to another native request.")
            return
        }
        if let error {
            request.noteRepresentationError((error as NSError).localizedDescription)
        }

        guard let serializationPolicy = NativePhotoRepresentationPolicy.serialization(
            format: request.intent.fileFormat, camera: request.intent.physicalCameraKind,
            rawPixelFormat: request.rawPixelFormatType, fileType: request.rawFileType,
            isRawPhoto: photo.isRawPhoto) else {
            request.noteRepresentationError("The capture callback did not match its frozen native file format.")
            return
        }
        let isProcessed = serializationPolicy == .processedOriginal
        guard error == nil else { return }
        #if DEBUG
        let serializationBegan = ProcessInfo.processInfo.systemUptime
        print("TruongCam timing native-raw-processed=\(Int((serializationBegan - nativeBegan) * 1000))ms nativeID=\(photo.resolvedSettings.uniqueID)")
        #endif

        // Native serialization strips only the embedded thumbnail. Sensor data
        // and all other metadata stay owned by AVFoundation; acquired file bytes
        // are then persisted verbatim, never parsed/re-encoded by the app.
        let data: Data
        if isProcessed, let original = photo.fileDataRepresentation(), !original.isEmpty {
            data = original
        } else if !isProcessed, let stripped = photo.fileDataRepresentation(with: representationCustomizer), !stripped.isEmpty {
            data = stripped
        } else if !isProcessed, let retained = photo.fileDataRepresentation(), !retained.isEmpty {
            // Do not discard an intact Bayer original merely because thumbnail
            // customization failed. Existing partial-result routing discloses this
            // failure while retaining the source; it is not silent success.
            request.noteRepresentationError("Thumbnail-free serialization failed; the Bayer original was retained with its original preview.")
            data = retained
        } else {
            request.noteRepresentationError("The photo produced no file representation.")
            return
        }

        if isProcessed, !NativePhotoRepresentationPolicy.containerMatches(data, format: request.intent.fileFormat) {
            request.noteRepresentationError("The processed photo's encoded container did not match the requested original format.")
            return
        }

        #if DEBUG
        print("TruongCam timing raw-serialization=\(Int((ProcessInfo.processInfo.systemUptime - serializationBegan) * 1000))ms nativeID=\(photo.resolvedSettings.uniqueID)")
        #endif
        let resolved = photo.resolvedSettings
        let representation = DeliveredRAWRepresentation(
            bytes: data,
            captureID: request.captureID,
            resolvedSettingsUniqueID: resolved.uniqueID,
            nativeBracketIdentity: nil,
            rawPixelFormatType: request.rawPixelFormatType,
            rawFileType: request.rawFileType,
            rawPhotoDimensions: Self.dimensions(from: isProcessed ? resolved.photoDimensions : resolved.rawPhotoDimensions),
            rawPixelBufferDimensions: photo.pixelBuffer.map {
                PixelDimensions(width: CVPixelBufferGetWidth($0),
                                height: CVPixelBufferGetHeight($0))
            },
            timestampSeconds: photo.timestamp.seconds,
            metadata: photo.metadata)
        request.recordResolvedDimensions(representation.rawPhotoDimensions)
        _ = request.recordRepresentation(representation)
    }

    func photoOutput(_ output: AVCapturePhotoOutput,
                     didFinishCaptureFor resolvedSettings: AVCaptureResolvedPhotoSettings,
                     error: Error?) {
        serialization.enqueue { [self] in
            // Do not close the lossless channel or retire native ownership until
            // ALL earlier representations have finished flattening/publication.
            _ = request.recordNativeTerminal(settingsID: resolvedSettings.uniqueID, mappedFailure: error.map {
                AVFoundationFailureMapper.failure(
                    $0, operation: "capturePhoto",
                    retained: request.recordedRepresentationCount > 0
                        ? .inMemoryRepresentationUnstaged : .none)
            })
        }
    }

    // Architecture note (also recorded in IMPLEMENTATION_REPORT.md):
    //
    // Native `AVCapturePhotoBracketSettings` is NOT used in v1, but the original
    // rationale for that was wrong and has been corrected (REVIEW.md S12/S13).
    //
    // What is actually true, verified against the installed iPhoneOS27.0 SDK by
    // `planning/review/2026-10-07/BracketIdentityProbe.swift` (exit 0):
    //
    //   * `AVCapturePhoto.bracketSettings` EXISTS and is the modern
    //     `didFinishProcessingPhoto` counterpart, so a bracketed photo CAN be
    //     attributed to its requested setting;
    //   * `AVCapturePhoto.sequenceCount` / `.sequenceIndex` exist for ordered
    //     multi-photo requests;
    //   * `AVCapturePhotoSettings.availableRawEmbeddedThumbnailPhotoCodecTypes`
    //     is likewise available.
    //
    // An earlier comment claimed none of this was exposed. That claim was false.
    // The remaining, genuine reason v1 ships the serial source bracket is
    // deliberate: native bracketing requires settings-by-identity on a real device
    // before it may be relied on for loss-critical RAW, and
    // `BracketPathResolver` therefore selects `.native` only when
    // `SequenceAdmissionPolicy.testedNativeBracketCounts` reports a count that a
    // device test actually measured. Until then the contract-permitted serial path
    // runs: one ordinary RAW capture per step, each an independent original.

    private static func dimensions(from value: CMVideoDimensions) -> PixelDimensions? {
        guard value.width > 0, value.height > 0 else { return nil }
        return PixelDimensions(width: Int(value.width), height: Int(value.height))
    }
}


/// Only this optional customizer callback is implemented: native metadata,
/// depth and Bayer image data retain their default serialization behavior.
/// Apple's API strips a thumbnail when BOTH its format and pixel buffer are nil.
final class NoEmbeddedThumbnailCustomizer: NSObject, AVCapturePhotoFileDataRepresentationCustomizer {
    func replacementEmbeddedThumbnailPixelBuffer(
        withPhotoFormat format: AutoreleasingUnsafeMutablePointer<NSDictionary?>,
        for photo: AVCapturePhoto
    ) -> Unmanaged<CVPixelBuffer>? {
        format.pointee = nil
        return nil
    }
}

/// One FIFO for photo bytes and the native terminal. Never blocks the caller or
/// detaches a terminal task that could overtake retained-but-unserialized bytes.
final class OrderedCaptureWork: Sendable {
    private let queue = DispatchQueue(label: "com.iantruong.TruongCam.photo-serialization", qos: .userInitiated, autoreleaseFrequency: .workItem)
    func enqueue(_ work: @escaping @Sendable () -> Void) { queue.async(execute: work) }
}
