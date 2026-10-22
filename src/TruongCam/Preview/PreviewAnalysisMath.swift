import Accelerate
import Foundation

// PREVIEW_TOOLS.md "Shared analysis pipeline", "Histogram, zebras and exposure
// meter" and "Focus peaking".
//
// This file extends the frozen `PreviewAnalysisMath` namespace declared in
// `src/TruongCam/Core/ServicePorts.swift` (which owns `histogramBinCount`). It is
// pure, synchronous, allocation-bounded math with no AVFoundation dependency, so
// it is exactly what the local logic verifier exercises (TEST_PLAN.md T31–T33).
//
// Rules that shape every function below:
//   * The preview histogram, zebras and peaking describe the PROCESSED PREVIEW,
//     never exact RAW clipping. Nothing here estimates sensor saturation, RAW
//     dynamic range or recoverable headroom.
//   * Statistics never see row padding: the real `bytesPerRow` is honored and
//     only `width` bytes of every row are read.
//   * Code-value normalization happens once, here, with nominal preview
//     endpoints (video range 16…235, full range 0…255). Values below nominal
//     black and above nominal white are clamped deliberately and the clamp is
//     recorded in `LumaNormalizationRecord`.
//   * A BGRA buffer is never reinterpreted as a luma plane. `bgra8` returns a
//     typed `unsupported` outcome; a verified channel-order/color-matrix
//     conversion would have to be implemented and tested separately.

// MARK: - Source format

/// What the caller says the delivered bytes are.
///
/// `PREVIEW_TOOLS.md`: "Never read BGRA as a luma plane: if only BGRA is
/// supported, verify channel order and actual color matrix/primaries and
/// implement a separately tested native conversion, or report analysis
/// unavailable for that tuple." The `.bgra8` case therefore exists only so the
/// result can say *unsupported* in a typed way.
enum LumaSourceFormat: Hashable, Sendable {
    /// One 8-bit luma plane (a YCbCr Y plane or a grayscale plane).
    case planarLuma8(PreviewCodeRange)
    /// The luma plane of an 8-bit bi-planar format (the caller passes Y only).
    case biplanarLuma8(PreviewCodeRange)
    /// Packed 32-bit BGRA. Not a luma plane; unsupported by the luma math.
    case bgra8
    /// Anything else the camera reported.
    case unknown(fourCC: UInt32)

    var isLumaPlane: Bool {
        switch self {
        case .planarLuma8, .biplanarLuma8: return true
        case .bgra8, .unknown: return false
        }
    }

    var codeRange: PreviewCodeRange? {
        switch self {
        case .planarLuma8(let range), .biplanarLuma8(let range): return range
        case .bgra8, .unknown: return nil
        }
    }

    var displayName: String {
        switch self {
        case .planarLuma8(let range): return "8-bit planar luma (\(range.displayName))"
        case .biplanarLuma8(let range): return "8-bit bi-planar luma plane (\(range.displayName))"
        case .bgra8: return "BGRA8"
        case .unknown(let fourCC): return "fourCC '\(LumaSourceFormat.fourCCString(fourCC))'"
        }
    }

    /// Renders a FourCC as four printable ASCII characters.
    static func fourCCString(_ value: UInt32) -> String {
        let bytes: [UInt8] = [
            UInt8((value >> 24) & 0xFF),
            UInt8((value >> 16) & 0xFF),
            UInt8((value >> 8) & 0xFF),
            UInt8(value & 0xFF),
        ]
        return String(bytes.map { byte -> Character in
            guard byte >= 32, byte < 127, let scalar = UnicodeScalar(UInt32(byte)) else { return "?" }
            return Character(scalar)
        })
    }
}

extension PreviewCodeRange {
    var displayName: String {
        switch self {
        case .full: return "full range 0…255"
        case .video: return "video range 16…235"
        }
    }
}

// MARK: - Normalization record

/// A record of the deliberate code-value normalization applied to one sample.
///
/// This is a *preview* code-value mapping, explicitly not scene-linear exposure
/// and not a RAW clipping measurement.
struct LumaNormalizationRecord: Hashable, Sendable {
    let sourceFormat: LumaSourceFormat
    let range: PreviewCodeRange
    let nominalBlack: Double
    let nominalWhite: Double
    /// True when source values at/below nominal black were clamped to 0.
    let clampsAtBlack: Bool
    /// True when source values at/above nominal white were clamped to 255.
    let clampsAtWhite: Bool
    /// True when vImage performed the resample; false means the deterministic
    /// box-average fallback (or no resample at all) was used.
    let usedAccelerateScale: Bool
    let scaledWidth: Int
    let scaledHeight: Int
    let note: String

    var summary: String {
        "\(sourceFormat.displayName) → normalized \(scaledWidth)×\(scaledHeight); "
            + "black \(Int(nominalBlack)) → 0, white \(Int(nominalWhite)) → 255; "
            + "clampBelowBlack=\(clampsAtBlack) clampAboveWhite=\(clampsAtWhite)"
    }
}

/// Typed result of a downsample attempt.
///
/// The frozen `LuminanceSample` cannot express failure, so the function that
/// reads a caller-declared pixel format returns this outcome instead: a caller
/// that says BGRA must never be handed a sample that was guessed from it.
enum LumaDownsampleOutcome: Sendable {
    case sampled(LuminanceSample, record: LumaNormalizationRecord)
    case unsupported(format: LumaSourceFormat, reason: String)
    case invalid(reason: String)

    var sample: LuminanceSample? {
        if case .sampled(let sample, _) = self { return sample }
        return nil
    }

    var record: LumaNormalizationRecord? {
        if case .sampled(_, let record) = self { return record }
        return nil
    }

    var isSampled: Bool { sample != nil }
}

// MARK: - Thresholds

/// Focus peaking sensitivity. PREVIEW_TOOLS.md: "Threshold choices Low=0.06,
/// Normal=0.10, High=0.16 (algorithm starting parameters, not measured optimal
/// device thresholds) … Larger threshold means fewer highlighted edges."
enum PeakingThreshold: String, Hashable, Sendable, CaseIterable {
    case low = "Low"
    case normal = "Normal"
    case high = "High"

    var label: String { rawValue }

    /// Magnitude threshold applied to `sqrt(gx² + gy²) / sqrt(32)`.
    var value: Double {
        switch self {
        case .low: return 0.06
        case .normal: return 0.10
        case .high: return 0.16
        }
    }

    /// Label with the numeric starting parameter, for tool details.
    var detailLabel: String {
        "\(label) peaking threshold \(value) — a display sensitivity parameter, not a measured focus accuracy"
    }
}

/// Preview-zebra threshold as a percentage of normalized preview luma code
/// values. Default 95%. The label never claims sensor saturation or RAW
/// clipping: it is processed-preview code values only.
enum ZebraThreshold: String, Hashable, Sendable, CaseIterable {
    case ninety = "90%"
    case ninetyFive = "95%"
    case hundred = "100%"

    static let `default` = ZebraThreshold.ninetyFive

    var label: String { rawValue }

    /// Integer percentage so the 8-bit threshold is exactly reproducible.
    var percent: Int {
        switch self {
        case .ninety: return 90
        case .ninetyFive: return 95
        case .hundred: return 100
        }
    }

    /// The normalized 0…255 code value at which highlighting starts.
    ///
    /// Computed with integer arithmetic (half-up rounding) so the documented
    /// percentage, the label and the compared byte agree exactly: 90% → 230,
    /// 95% → 242, 100% → 255. The preview plane only has 256 levels, so the
    /// threshold is realized at the nearest representable code value.
    var codeValue: UInt8 {
        UInt8((percent * 255 + 50) / 100)
    }

    /// The threshold expressed in normalized 0…1 units (exactly the quantized
    /// code value divided by 255).
    var normalizedValue: Double { Double(codeValue) / 255.0 }

    /// Concise tool-details text. Deliberately makes no RAW claim.
    var detailLabel: String {
        "Preview zebras at \(label) of normalized preview luma code values (code value \(codeValue) of 255)"
    }
}

// MARK: - Reused scratch

/// Reusable analysis buffers so steady-state analysis adds no per-frame
/// allocation (R10, PREVIEW_TOOLS.md "reuse scratch storage").
///
/// Ownership invariant: one owner (the `MeteringService` actor, or a single test
/// body) uses a scratch instance at a time; the buffers are never shared across
/// isolation domains. The type is deliberately not `Sendable` because there is
/// no safe meaning for sharing it.
///
/// `LuminanceSample` (frozen Core interface) stores its plane as `[UInt8]`, so
/// one bounded output allocation per produced sample is unavoidable, and a
/// snapshot array (mask/loupe/histogram) that escapes into an `AnalysisOutput`
/// necessarily owns its storage too. What scratch removes is every *intermediate*
/// allocation on the hot path: the resampled plane, the vImage temporary buffer,
/// the normalized float plane, both Sobel responses and the mask plane are
/// allocated once and grown only when the working size actually increases. The
/// histogram bins are not kept here: the returned `HistogramSnapshot` owns them.
final class ReusedScratch {
    /// vImage's temporary requirement depends on the complete source and
    /// destination layout and resampling flags, not the frame's pixel values.
    struct ScaleQuerySignature: Equatable {
        let sourceWidth: Int
        let sourceHeight: Int
        let sourceStride: Int
        let destinationWidth: Int
        let destinationHeight: Int
        let destinationStride: Int
        let flags: vImage_Flags
    }
    private var scaleQuery: (signature: ScaleQuerySignature, result: vImage_Error)?
    private(set) var scaleTemporaryQueryCount = 0

    /// Successful zero-byte requirements are cached too. A failed query stays
    /// retryable and never authorizes another layout's old temporary size.
    func scaleTemporaryByteCount(for signature: ScaleQuerySignature, query: () -> vImage_Error) -> vImage_Error {
        if let scaleQuery, scaleQuery.signature == signature { return scaleQuery.result }
        scaleTemporaryQueryCount += 1
        let result = query()
        scaleQuery = result >= 0 ? (signature, result) : nil
        return result
    }
    // The buffer properties are module-internal `var` rather than `private(set)`
    // because the analysis functions in this file must write through their
    // storage in place (`withUnsafeMutableBufferPointer` is a mutating access).
    // Only those functions and the `ensure…` helpers above them mutate them.

    /// Resampled 8-bit plane (≤ 640-pixel long edge).
    var scaledBytes: [UInt8] = []
    /// vImage scale temporary buffer.
    var scaleTempBytes: [UInt8] = []
    /// Normalized float plane in [0, 1].
    var normalizedFloat: [Float] = []
    /// Horizontal signed Sobel response.
    var gradientX: [Float] = []
    /// Vertical signed Sobel response.
    var gradientY: [Float] = []
    /// Binary mask plane, 0 or 255.
    var maskBytes: [UInt8] = []
    /// Reason the last accelerated resample was skipped, if any. Mutated by the
    /// analysis functions in this file, read-only for everyone else.
    var lastAccelerateFailureReason: String?
    /// Dimensions currently described by `scaledBytes`.
    private(set) var scaledDimensions = PixelDimensions(width: 0, height: 0)
    /// Number of times a buffer had to be (re)allocated. Tests assert this stops
    /// growing once the working size is stable.
    private(set) var bufferGrowthCount = 0
    /// Number of samples analysed against this scratch.
    private(set) var passCount = 0

    init() {}

    /// Bytes currently retained by scratch buffers.
    var retainedByteCount: Int {
        scaledBytes.capacity
            + scaleTempBytes.capacity
            + normalizedFloat.capacity * MemoryLayout<Float>.stride
            + gradientX.capacity * MemoryLayout<Float>.stride
            + gradientY.capacity * MemoryLayout<Float>.stride
            + maskBytes.capacity
    }

    var isReleased: Bool {
        scaledBytes.isEmpty && scaleTempBytes.isEmpty && normalizedFloat.isEmpty
            && gradientX.isEmpty && gradientY.isEmpty && maskBytes.isEmpty
    }

    /// Releases every buffer, e.g. when all tools are off or the view leaves the
    /// screen (PREVIEW_TOOLS.md "Disable analysis work when all consumers are
    /// off"; CONTRACTS.md "release scratch/caches under memory pressure").
    func release() {
        scaledBytes = []
        scaleTempBytes = []
        normalizedFloat = []
        gradientX = []
        gradientY = []
        maskBytes = []
        scaledDimensions = PixelDimensions(width: 0, height: 0)
        scaleQuery = nil
    }

    func markPass() { passCount += 1 }

    /// Reserves the resampled plane, growing only when necessary.
    func ensureScaled(width: Int, height: Int) {
        let count = max(0, width) * max(0, height)
        if scaledBytes.count != count {
            bufferGrowthCount += 1
            scaledBytes = [UInt8](repeating: 0, count: count)
        }
        scaledDimensions = PixelDimensions(width: max(0, width), height: max(0, height))
    }

    func ensureScaleTemp(bytes: Int) {
        guard bytes > 0 else {
            if !scaleTempBytes.isEmpty { scaleTempBytes = [] }
            return
        }
        if scaleTempBytes.count < bytes {
            bufferGrowthCount += 1
            scaleTempBytes = [UInt8](repeating: 0, count: bytes)
        }
    }

    /// Reserves the float + mask planes for `pixelCount` pixels.
    func ensureAnalysisPlanes(pixelCount: Int) {
        let count = max(0, pixelCount)
        if normalizedFloat.count != count {
            bufferGrowthCount += 1
            normalizedFloat = [Float](repeating: 0, count: count)
        }
        if gradientX.count != count {
            bufferGrowthCount += 1
            gradientX = [Float](repeating: 0, count: count)
        }
        if gradientY.count != count {
            bufferGrowthCount += 1
            gradientY = [Float](repeating: 0, count: count)
        }
        if maskBytes.count != count {
            bufferGrowthCount += 1
            maskBytes = [UInt8](repeating: 0, count: count)
        }
    }
}

// MARK: - Math

extension PreviewAnalysisMath {
    /// A narrow synchronous native-call seam. Production uses the exact same
    /// vImage function for the temporary-size query and actual scale; tests can
    /// force an actual scale failure without invalid pointers or changed pixels.
    struct LumaScaleOperation: Sendable {
        let run: @Sendable (inout vImage_Buffer, inout vImage_Buffer, UnsafeMutableRawPointer?, vImage_Flags) -> vImage_Error
        static let native = LumaScaleOperation { source, destination, temporary, flags in
            vImageScale_Planar8(&source, &destination, temporary, flags)
        }
    }
    /// Working image limit for peaking/zebras (PREVIEW_TOOLS.md).
    static let workingLongEdgeLimit = 640
    /// Target long edge of the histogram analysis plane (~192×144 at 4:3).
    static let histogramAnalysisLongEdge = 192
    /// vImage Sobel normalization: `sqrt(gx² + gy²) / sqrt(32)`.
    static let sobelNormalization = 32.0

    // MARK: Dimensions

    /// Long-edge-bounded dimensions preserving the frame aspect.
    static func scaledDimensions(width: Int, height: Int, longEdge: Int) -> PixelDimensions {
        guard width > 0, height > 0, longEdge > 0 else { return PixelDimensions(width: 0, height: 0) }
        let longest = max(width, height)
        guard longest > longEdge else { return PixelDimensions(width: width, height: height) }
        let scale = Double(longEdge) / Double(longest)
        let scaledWidth = max(1, min(longEdge, Int((Double(width) * scale).rounded())))
        let scaledHeight = max(1, min(longEdge, Int((Double(height) * scale).rounded())))
        return PixelDimensions(width: scaledWidth, height: scaledHeight)
    }

    /// Dimensions of the plane the histogram actually bins (long edge ≤ 192).
    static func histogramAnalysisDimensions(width: Int, height: Int) -> PixelDimensions {
        scaledDimensions(width: width, height: height, longEdge: histogramAnalysisLongEdge)
    }

    // MARK: Normalization

    /// The single 256-entry normalization table for one preview code range.
    ///
    /// Full range is the identity. Video range maps nominal black 16 → 0 and
    /// nominal white 235 → 255 and clamps everything outside that window
    /// (`PREVIEW_TOOLS.md`: handle values below black/above nominal white
    /// deliberately).
    private static let fullRangeNormalization = makeNormalizationTable(for: .full)
    private static let videoRangeNormalization = makeNormalizationTable(for: .video)

    static func normalizationTable(for range: PreviewCodeRange) -> [UInt8] {
        range == .full ? fullRangeNormalization : videoRangeNormalization
    }

    private static func makeNormalizationTable(for range: PreviewCodeRange) -> [UInt8] {
        var table = [UInt8](repeating: 0, count: 256)
        switch range {
        case .full:
            for value in 0...255 { table[value] = UInt8(value) }
        case .video:
            let black = range.nominalBlack
            let span = range.nominalWhite - range.nominalBlack
            for value in 0...255 {
                let normalized = (Double(value) - black) / span
                table[value] = UInt8(min(max((normalized * 255).rounded(), 0), 255))
            }
        }
        return table
    }

    private static func normalizationRecord(sourceFormat: LumaSourceFormat,
                                            range: PreviewCodeRange,
                                            usedAccelerateScale: Bool,
                                            scaled: PixelDimensions) -> LumaNormalizationRecord {
        LumaNormalizationRecord(
            sourceFormat: sourceFormat,
            range: range,
            nominalBlack: range.nominalBlack,
            nominalWhite: range.nominalWhite,
            clampsAtBlack: range == .video,
            clampsAtWhite: range == .video,
            usedAccelerateScale: usedAccelerateScale,
            scaledWidth: scaled.width,
            scaledHeight: scaled.height,
            note: "Preview code-value normalization for display statistics; "
                + "not scene-linear exposure and not a RAW clipping measurement.")
    }

    // MARK: Downsample

    /// Downscales one delivered luma plane to at most `targetLongEdge` (capped at
    /// 640) pixels on its long edge.
    ///
    /// - Parameters:
    ///   - source: the delivered plane. Only `width` bytes of each of the
    ///     `height` rows are read; `bytesPerRow` may therefore include padding.
    ///   - range: the caller's declared pixel format. BGRA is rejected with a
    ///     typed `unsupported` outcome rather than reinterpreted.
    ///   - targetLongEdge: requested long edge; clamped to the 640 working limit.
    ///   - useAccelerate: test seam. When false the deterministic box-average
    ///     fallback is used; production calls leave it true.
    ///
    /// The returned sample carries normalized code values (nominal black → 0,
    /// nominal white → 255) and one bounded `[UInt8]` allocation. All working
    /// buffers come from `scratch`.
    static func downsampleLuma(from source: UnsafeBufferPointer<UInt8>,
                               width: Int,
                               height: Int,
                               bytesPerRow: Int,
                               range: LumaSourceFormat,
                               targetLongEdge: Int,
                               scratch: ReusedScratch = ReusedScratch(),
                               configurationGeneration: ConfigurationGeneration = .zero,
                               geometryGeneration: UInt64 = 0,
                               capturedAtUTC: Date = Date(),
                               useAccelerate: Bool = true,
                               scaleOperation: LumaScaleOperation = .native) -> LumaDownsampleOutcome {
        guard let codeRange = range.codeRange else {
            let reason = range == .bgra8
                ? "BGRA is not a luma plane; a verified channel-order/color-matrix conversion must be implemented and tested separately."
                : "No luma plane is available for \(range.displayName)."
            return .unsupported(format: range, reason: reason)
        }
        guard width > 0, height > 0 else {
            return .invalid(reason: "Luma plane dimensions must be positive (got \(width)×\(height)).")
        }
        guard bytesPerRow >= width else {
            return .invalid(reason: "bytesPerRow \(bytesPerRow) is smaller than width \(width).")
        }
        let (required, overflow) = bytesPerRow.multipliedReportingOverflow(by: height)
        guard !overflow else {
            return .invalid(reason: "bytesPerRow × height overflows Int.")
        }
        guard let base = source.baseAddress, source.count >= required else {
            return .invalid(reason: "Source plane holds \(source.count) bytes but \(required) are required.")
        }
        guard targetLongEdge > 0 else {
            return .invalid(reason: "targetLongEdge must be positive (got \(targetLongEdge)).")
        }

        let boundedLongEdge = min(targetLongEdge, workingLongEdgeLimit)
        let scaled = scaledDimensions(width: width, height: height, longEdge: boundedLongEdge)
        guard scaled.isValid else {
            return .invalid(reason: "Computed scaled dimensions are invalid.")
        }

        var usedAccelerate = false
        var resampled: [UInt8]
        if scaled.width == width && scaled.height == height {
            // No resample needed; read the source rows directly.
            resampled = []
        } else if useAccelerate, let bytes = acceleratedResample(source: base,
                                                                width: width,
                                                                height: height,
                                                                bytesPerRow: bytesPerRow,
                                                                scaled: scaled,
                                                                scratch: scratch,
                                                                scaleOperation: scaleOperation) {
            usedAccelerate = true
            resampled = bytes
        } else {
            resampled = boxAverageResample(source: base,
                                           width: width,
                                           height: height,
                                           bytesPerRow: bytesPerRow,
                                           scaled: scaled)
        }

        let pixelCount = scaled.width * scaled.height
        let table = normalizationTable(for: codeRange)
        var luma = [UInt8](repeating: 0, count: pixelCount)
        if resampled.isEmpty {
            // Identity size: normalize straight out of the strided source.
            luma.withUnsafeMutableBufferPointer { destination in
                guard let out = destination.baseAddress else { return }
                for row in 0..<scaled.height {
                    let source = base + row * bytesPerRow
                    let destinationRow = out + row * scaled.width
                    for column in 0..<scaled.width {
                        destinationRow[column] = table[Int(source[column])]
                    }
                }
            }
        } else {
            resampled.withUnsafeBufferPointer { input in
                guard let inBase = input.baseAddress else { return }
                luma.withUnsafeMutableBufferPointer { destination in
                    guard let out = destination.baseAddress else { return }
                    for index in 0..<pixelCount {
                        out[index] = table[Int(inBase[index])]
                    }
                }
            }
        }

        let sample = LuminanceSample(width: scaled.width,
                                     height: scaled.height,
                                     luma: luma,
                                     range: codeRange,
                                     configurationGeneration: configurationGeneration,
                                     geometryGeneration: geometryGeneration,
                                     capturedAtUTC: capturedAtUTC)
        let record = normalizationRecord(sourceFormat: range,
                                         range: codeRange,
                                         usedAccelerateScale: usedAccelerate,
                                         scaled: scaled)
        return .sampled(sample, record: record)
    }

    /// vImage resample of the strided source plane into reused scratch storage.
    /// Returns nil (and records the reason on scratch) when vImage reported an
    /// error, so the caller can fall back to the deterministic box average.
    private static func acceleratedResample(source: UnsafePointer<UInt8>,
                                            width: Int,
                                            height: Int,
                                            bytesPerRow: Int,
                                            scaled: PixelDimensions,
                                            scratch: ReusedScratch,
                                            scaleOperation: LumaScaleOperation) -> [UInt8]? {
        scratch.ensureScaled(width: scaled.width, height: scaled.height)
        scratch.lastAccelerateFailureReason = nil

        var sourceBuffer = vImage_Buffer(data: UnsafeMutableRawPointer(mutating: source),
                                         height: vImagePixelCount(height),
                                         width: vImagePixelCount(width),
                                         rowBytes: bytesPerRow)
        let flags = vImage_Flags(kvImageHighQualityResampling)

        // Ask vImage for the temporary-buffer size once, with the same flags as
        // the real call; reuse it afterwards so vImage never allocates internally
        // on the hot path.
        var queryBuffer = vImage_Buffer(data: nil,
                                        height: vImagePixelCount(scaled.height),
                                        width: vImagePixelCount(scaled.width),
                                        rowBytes: scaled.width)
        let signature = ReusedScratch.ScaleQuerySignature(sourceWidth: width, sourceHeight: height, sourceStride: bytesPerRow,
            destinationWidth: scaled.width, destinationHeight: scaled.height, destinationStride: scaled.width, flags: flags)
        let tempSize = scratch.scaleTemporaryByteCount(for: signature) {
            scratch.scaledBytes.withUnsafeMutableBufferPointer { destination -> vImage_Error in
                queryBuffer.data = destination.baseAddress.map(UnsafeMutableRawPointer.init)
                return scaleOperation.run(&sourceBuffer, &queryBuffer, nil,
                    flags | vImage_Flags(kvImageGetTempBufferSize))
            }
        }
        if tempSize > 0 { scratch.ensureScaleTemp(bytes: Int(tempSize)) }

        var error: vImage_Error = kvImageNoError
        scratch.scaledBytes.withUnsafeMutableBufferPointer { destination in
            guard let destinationBase = destination.baseAddress else {
                error = kvImageNullPointerArgument
                return
            }
            var destinationBuffer = vImage_Buffer(data: destinationBase,
                                                  height: vImagePixelCount(scaled.height),
                                                  width: vImagePixelCount(scaled.width),
                                                  rowBytes: scaled.width)
            scratch.scaleTempBytes.withUnsafeMutableBytes { temp in
                error = scaleOperation.run(&sourceBuffer, &destinationBuffer, temp.baseAddress, flags)
            }
        }
        guard error == kvImageNoError else {
            scratch.lastAccelerateFailureReason = "vImageScale_Planar8 failed with \(error)"
            return nil
        }
        return scratch.scaledBytes
    }

    /// Deterministic integer box-average resample used when vImage is unavailable
    /// or reported an error. Reads only the real `width` bytes of every row.
    private static func boxAverageResample(source: UnsafePointer<UInt8>,
                                           width: Int,
                                           height: Int,
                                           bytesPerRow: Int,
                                           scaled: PixelDimensions) -> [UInt8] {
        var output = [UInt8](repeating: 0, count: scaled.width * scaled.height)
        for outRow in 0..<scaled.height {
            let sourceRowStart = outRow * height / scaled.height
            var sourceRowEnd = (outRow + 1) * height / scaled.height
            if sourceRowEnd <= sourceRowStart { sourceRowEnd = sourceRowStart + 1 }
            for outColumn in 0..<scaled.width {
                let columnStart = outColumn * width / scaled.width
                var columnEnd = (outColumn + 1) * width / scaled.width
                if columnEnd <= columnStart { columnEnd = columnStart + 1 }
                var total = 0
                var count = 0
                for row in sourceRowStart..<min(sourceRowEnd, height) {
                    let rowBase = source + row * bytesPerRow
                    for column in columnStart..<min(columnEnd, width) {
                        total += Int(rowBase[column])
                        count += 1
                    }
                }
                let average = count > 0 ? Double(total) / Double(count) : 0
                output[outRow * scaled.width + outColumn] = UInt8(min(max(average.rounded(), 0), 255))
            }
        }
        return output
    }

    // MARK: Histogram

    /// 256-bin histogram of the normalized sample plane.
    ///
    /// The binned plane has a long edge of at most 192 pixels (about 192×144 for
    /// a 4:3 frame) and is derived by deterministic nearest-neighbour
    /// subsampling, so the histogram describes the same aspect and the same
    /// normalized code values as the working plane. Every binned pixel
    /// contributes to exactly one bin, so `bins` sums exactly to `sampleCount`.
    /// Row padding cannot contribute because `LuminanceSample` already holds only
    /// real pixels.
    static func histogram(from sample: LuminanceSample,
                          configurationGeneration: ConfigurationGeneration? = nil,
                          geometryGeneration: UInt64? = nil) -> HistogramSnapshot {
        let generation = configurationGeneration ?? sample.configurationGeneration
        let geometry = geometryGeneration ?? sample.geometryGeneration
        let bins = [UInt32](repeating: 0, count: histogramBinCount)
        let width = sample.width
        let height = sample.height
        guard PixelDimensions(width: width, height: height).isValid,
              sample.luma.count >= width * height else {
            return HistogramSnapshot(bins: bins,
                                     sampleCount: 0,
                                     geometryGeneration: geometry,
                                     configurationGeneration: generation,
                                     isFullRange: sample.range == .full,
                                     mappedAtUTC: sample.capturedAtUTC)
        }
        let plane = histogramAnalysisDimensions(width: width, height: height)
        var counted = bins
        var sampleCount: UInt32 = 0
        sample.luma.withUnsafeBufferPointer { buffer in
            guard let base = buffer.baseAddress else { return }
            for outRow in 0..<plane.height {
                let sourceRow = min(height - 1, outRow * height / plane.height)
                let rowBase = base + sourceRow * width
                for outColumn in 0..<plane.width {
                    let sourceColumn = min(width - 1, outColumn * width / plane.width)
                    counted[Int(rowBase[sourceColumn])] &+= 1
                    sampleCount &+= 1
                }
            }
        }
        return HistogramSnapshot(bins: counted,
                                 sampleCount: sampleCount,
                                 geometryGeneration: geometry,
                                 configurationGeneration: generation,
                                 isFullRange: sample.range == .full,
                                 mappedAtUTC: sample.capturedAtUTC,
                                 rgb: sample.rgbHistogram)
    }

    // MARK: Peaking

    /// Signed 3×3 Sobel focus-peaking mask, one byte per sample pixel (0 or 255,
    /// row-major).
    ///
    /// The normalized plane is converted to float [0, 1], convolved with the
    /// horizontal and vertical signed Sobel kernels using
    /// `vImageConvolve_PlanarF` + `kvImageEdgeExtend`, and combined as
    /// `sqrt(gx² + gy²) / sqrt(32)`, clamped to [0, 1]. Both responses are signed
    /// floats, so reversing an edge cannot clip a negative lobe to zero: the two
    /// directions produce identical magnitudes. The outermost pixel ring is
    /// suppressed because edge extension can leave padding artifacts there.
    ///
    /// Returns an empty array when the analysis could not run at all (a vImage
    /// error), so "peaking unavailable" is distinguishable from "no edges
    /// found", which is an all-zero mask.
    static func peakingMask(from sample: LuminanceSample,
                            threshold: Double,
                            scratch: ReusedScratch = ReusedScratch()) -> [UInt8] {
        let width = sample.width
        let height = sample.height
        guard PixelDimensions(width: width, height: height).isValid else { return [] }
        let pixelCount = width * height
        guard sample.luma.count >= pixelCount else { return [] }
        guard width >= 3, height >= 3 else {
            return [UInt8](repeating: 0, count: pixelCount)
        }
        let clampedThreshold = Float(min(max(threshold.isFinite ? threshold : 1, 0), 1))

        scratch.ensureAnalysisPlanes(pixelCount: pixelCount)
        let horizontalKernel: [Float] = [-1, 0, 1, -2, 0, 2, -1, 0, 1]
        let verticalKernel: [Float] = [-1, -2, -1, 0, 0, 0, 1, 2, 1]
        var failed = false

        sample.luma.withUnsafeBufferPointer { luma -> Void in
            guard let lumaBase = luma.baseAddress else { failed = true; return }
            scratch.normalizedFloat.withUnsafeMutableBufferPointer { normalized -> Void in
                guard let normalizedBase = normalized.baseAddress else { failed = true; return }
                var sourceBuffer = vImage_Buffer(data: UnsafeMutableRawPointer(mutating: lumaBase),
                                                 height: vImagePixelCount(height),
                                                 width: vImagePixelCount(width),
                                                 rowBytes: width)
                var floatBuffer = vImage_Buffer(data: normalizedBase,
                                                height: vImagePixelCount(height),
                                                width: vImagePixelCount(width),
                                                rowBytes: width * MemoryLayout<Float>.stride)
                let conversion = vImageConvert_Planar8toPlanarF(&sourceBuffer, &floatBuffer,
                                                                1.0, 0.0,
                                                                vImage_Flags(kvImageNoFlags))
                guard conversion == kvImageNoError else { failed = true; return }
                scratch.gradientX.withUnsafeMutableBufferPointer { gx -> Void in
                    guard let gxBase = gx.baseAddress else { failed = true; return }
                    scratch.gradientY.withUnsafeMutableBufferPointer { gy -> Void in
                        guard let gyBase = gy.baseAddress else { failed = true; return }
                        var gxBuffer = vImage_Buffer(data: gxBase,
                                                     height: vImagePixelCount(height),
                                                     width: vImagePixelCount(width),
                                                     rowBytes: width * MemoryLayout<Float>.stride)
                        var gyBuffer = vImage_Buffer(data: gyBase,
                                                     height: vImagePixelCount(height),
                                                     width: vImagePixelCount(width),
                                                     rowBytes: width * MemoryLayout<Float>.stride)
                        let horizontalError = vImageConvolve_PlanarF(&floatBuffer, &gxBuffer, nil,
                                                                     0, 0,
                                                                     horizontalKernel, 3, 3, 0,
                                                                     vImage_Flags(kvImageEdgeExtend))
                        let verticalError = vImageConvolve_PlanarF(&floatBuffer, &gyBuffer, nil,
                                                                   0, 0,
                                                                   verticalKernel, 3, 3, 0,
                                                                   vImage_Flags(kvImageEdgeExtend))
                        guard horizontalError == kvImageNoError, verticalError == kvImageNoError else {
                            failed = true
                            return
                        }
                        scratch.maskBytes.withUnsafeMutableBufferPointer { mask -> Void in
                            guard let maskBase = mask.baseAddress else { failed = true; return }
                            let normalization = Float(sqrt(sobelNormalization))
                            for row in 0..<height {
                                let rowOffset = row * width
                                let isBorderRow = row == 0 || row == height - 1
                                for column in 0..<width {
                                    let index = rowOffset + column
                                    if isBorderRow || column == 0 || column == width - 1 {
                                        maskBase[index] = 0
                                        continue
                                    }
                                    let x = gxBase[index]
                                    let y = gyBase[index]
                                    let magnitude = (x * x + y * y).squareRoot() / normalization
                                    maskBase[index] = magnitude >= clampedThreshold ? 255 : 0
                                }
                            }
                        }
                    }
                }
            }
        }
        guard !failed else { return [] }
        return scratch.maskBytes
    }

    // MARK: Zebras

    /// Quantizes a normalized 0…1 zebra threshold to the 8-bit code value that
    /// will be compared.
    static func zebraCodeValue(forNormalizedThreshold threshold: Double) -> UInt8 {
        let finite = threshold.isFinite ? threshold : 1
        let clamped = min(max(finite, 0), 1)
        return UInt8(min(max((clamped * 255).rounded(), 0), 255))
    }

    /// Highlights-only preview zebra mask, one byte per sample pixel (0 or 255).
    ///
    /// A pixel is highlighted when its normalized preview luma code value is
    /// greater than or equal to the threshold code value, so a value exactly at
    /// the threshold counts as highlighted. The sample plane already holds
    /// normalized code values, which is what makes the video-range endpoint
    /// mapping (nominal white 235 → 255, nominal black 16 → 0) testable here.
    ///
    /// This mask never writes into the original or into the histogram input, and
    /// the labels make no RAW-saturation claim.
    static func zebraMask(from sample: LuminanceSample, thresholdCodeValue: UInt8) -> [UInt8] {
        guard PixelDimensions(width: sample.width, height: sample.height).isValid else { return [] }
        let pixelCount = sample.width * sample.height
        guard sample.luma.count >= pixelCount else { return [] }
        var mask = [UInt8](repeating: 0, count: pixelCount)
        sample.luma.withUnsafeBufferPointer { luma in
            guard let base = luma.baseAddress else { return }
            mask.withUnsafeMutableBufferPointer { output in
                guard let out = output.baseAddress else { return }
                for index in 0..<pixelCount {
                    out[index] = base[index] >= thresholdCodeValue ? 255 : 0
                }
            }
        }
        return mask
    }

    static func zebraMask(from sample: LuminanceSample, threshold: ZebraThreshold) -> [UInt8] {
        zebraMask(from: sample, thresholdCodeValue: threshold.codeValue)
    }

    static func zebraMask(from sample: LuminanceSample, threshold: Double) -> [UInt8] {
        zebraMask(from: sample, thresholdCodeValue: zebraCodeValue(forNormalizedThreshold: threshold))
    }

    // MARK: Labels

    /// Tool-details sentence required by PREVIEW_TOOLS.md. Kept here so no UI
    /// string can drift into a RAW-clipping claim.
    static let zebraLimitationNote =
        "Preview zebras mark processed preview code values; they never measure sensor saturation or RAW clipping."

    static let peakingLimitationNote =
        "Focus peaking marks contrast edges in the processed preview; grain and texture can light up even when focus is poor. It is not proof that a subject is in focus."

    static let loupeLimitationNote =
        "The loupe magnifies the processed preview for display only; it never changes videoZoomFactor, the photo connection scale or the RAW output size."
}


/// Known Y′CbCr matrices only. Unknown attachment means RGB unavailable; luma
/// aids continue without inventing channels. Values remain encoded preview RGB.
enum PreviewYCbCrMatrix: String, Sendable, CaseIterable {
    case itu601 = "BT.601", itu709 = "BT.709", itu2020 = "BT.2020"
    var weights: (red: Double, blue: Double) {
        switch self {
        case .itu601: return (0.299, 0.114)
        case .itu709: return (0.2126, 0.0722)
        case .itu2020: return (0.2627, 0.0593)
        }
    }
}

extension PreviewAnalysisMath {
    /// Samples at most 192×192 pixels from a locked 8-bit 4:2:0 bi-planar frame.
    /// Row padding and chroma stride are explicit; no native buffer escapes its lease.
    static func rgbHistogram(luma: UnsafeBufferPointer<UInt8>, chroma: UnsafeBufferPointer<UInt8>,
                             width: Int, height: Int, lumaStride: Int, chromaStride: Int,
                             chromaWidth: Int, chromaHeight: Int, range: PreviewCodeRange,
                             matrix: PreviewYCbCrMatrix?) -> PreviewRGBHistogram? {
        guard let matrix, width > 0, height > 0, width <= 16384, height <= 16384,
              lumaStride >= width, lumaStride <= 131072,
              chromaWidth >= (width + 1) / 2, chromaHeight >= (height + 1) / 2,
              chromaWidth <= 8192, chromaHeight <= 8192,
              chromaStride >= chromaWidth * 2, chromaStride <= 131072,
              luma.count >= lumaStride * height, chroma.count >= chromaStride * chromaHeight else { return nil }
        let plane = histogramAnalysisDimensions(width: width, height: height)
        var red = [UInt32](repeating: 0, count: 256)
        var green = red, blue = red
        let weights = matrix.weights, kg = 1 - weights.red - weights.blue
        let yScale = range == .video ? 219.0 : 255.0
        let cScale = range == .video ? 224.0 : 255.0
        func bin(_ value: Double) -> Int { Int((min(1, max(0, value)) * 255).rounded()) }
        for row in 0..<plane.height {
            let y = min(height - 1, row * height / plane.height)
            for column in 0..<plane.width {
                let x = min(width - 1, column * width / plane.width)
                let cy = y / 2, cx = x / 2
                let yy = (Double(luma[y * lumaStride + x]) - range.nominalBlack) / yScale
                let cb = (Double(chroma[cy * chromaStride + cx * 2]) - 128) / cScale
                let cr = (Double(chroma[cy * chromaStride + cx * 2 + 1]) - 128) / cScale
                let rr = yy + 2 * (1 - weights.red) * cr
                let bb = yy + 2 * (1 - weights.blue) * cb
                let gg = (yy - weights.red * rr - weights.blue * bb) / kg
                red[bin(rr)] += 1; green[bin(gg)] += 1; blue[bin(bb)] += 1
            }
        }
        return PreviewRGBHistogram(red: red, green: green, blue: blue,
                                   sampleCount: UInt32(plane.width * plane.height), matrix: matrix.rawValue)
    }
}
