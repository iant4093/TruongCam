import CoreGraphics
import Foundation
import ImageIO
import UIKit

// Display-only conversions for the analysis snapshots.
//
// PREVIEW_TOOLS.md: the loupe magnifies the processed preview only. Nothing in
// this file can change `videoZoomFactor`, the photo connection scale/crop, the
// RAW output size, or the preview's displayed framing.

extension LoupeSnapshot {
    /// Builds a display image from the RGBA8 buffer produced by the renderer.
    /// Returns nil when the buffer is inconsistent, in which case the UI shows
    /// "Loupe unavailable" instead of substituting an old frame.
    func makeImage() -> CGImage? {
        guard width > 0, height > 0,
              width <= LoupeRenderer.maxColorOutputLongEdge, height <= LoupeRenderer.maxColorOutputLongEdge,
              rgbaBytes.count == width * height * 4 else { return nil }
        let bytesPerRow = width * 4
        guard let provider = CGDataProvider(data: Data(rgbaBytes) as CFData) else { return nil }
        return CGImage(
            width: width,
            height: height,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: bytesPerRow,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider,
            decode: nil,
            shouldInterpolate: true,
            intent: .defaultIntent)
    }
}

extension HistogramSnapshot {
    /// Human-readable summary. Deliberately contains no RAW dynamic-range,
    /// clipping-percentage or stop estimate.
    var detailSummary: String {
        guard sampleCount > 0 else { return "No preview samples yet." }
        if let rgb {
            return "Processed preview RGB, \(rgb.sampleCount) samples using \(rgb.matrix). Red, green and blue share a vertical scale. Not RAW clipping."
        }
        let peakBin = bins.enumerated().max { $0.element < $1.element }?.offset ?? 0
        return "Preview luminance, \(sampleCount) samples, peak at code value \(peakBin). This describes the processed preview, not RAW clipping."
    }
}

extension MaskSnapshot {
    var peakingSummary: String {
        "Focus peaking at threshold \(String(format: "%.2f", peakingThreshold)). A contrast-edge display aid, not proof of focus."
    }

    var zebraSummary: String {
        "Preview zebras at \(Int((zebraThreshold * 100).rounded()))% of preview luma code values. Not a sensor saturation measurement."
    }
}
