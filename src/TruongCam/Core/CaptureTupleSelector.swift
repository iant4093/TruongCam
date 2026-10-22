import Foundation

/// Preset ownership is part of the tuple: assigning activeFormat implicitly
/// changes the native session to inputPriority and may remove photo RAW support.
enum CaptureConfigurationMode: String, Hashable, Sendable {
    case photoPreset
    case explicitFormat
}

/// A capture format as the selector needs to see it. Using a value type keeps the
/// selection logic reviewable and unit-testable without a physical device.
struct CaptureFormatFacts: Hashable, Sendable {
    let index: Int
    let advertisedMaxPhotoDimensions: [PixelDimensions]
    /// Bayer pixel formats this format advertises for the DNG container.
    let bayerPixelFormatsForDNG: [UInt32]
    var configurationMode: CaptureConfigurationMode = .explicitFormat

    var largestAdvertisedCeiling: PixelDimensions? {
        advertisedMaxPhotoDimensions.filter(\.isValid).max { $0.pixelCount < $1.pixelCount }
    }
}

enum CaptureTupleSelector {
    struct Selection: Hashable, Sendable {
        let formatIndex: Int
        let requestedDimensions: PixelDimensions
        let activeDNGPixelFormats: [UInt32]
        let notes: [String]
        var configurationMode: CaptureConfigurationMode = .explicitFormat
    }

    /// Picks the largest advertised photo-dimension ceiling on a format that
    /// actually exposes a Bayer RAW pixel format for the DNG container.
    ///
    /// REVIEW.md C04: the previous code assigned no `activeFormat` and published
    /// `selectedFormatIndex: nil`, so callers fell back to `formats.startIndex` —
    /// an arbitrary format unrelated to the device. A format advertising more
    /// pixels but exposing no usable RAW path is explicitly rejected, and the
    /// rejection is reported rather than hidden.
    static func select(from formats: [CaptureFormatFacts]) -> Selection? {
        var best: (index: Int, dimensions: PixelDimensions, rawFormats: [UInt32], mode: CaptureConfigurationMode)?
        var rejections: [String] = []

        for format in formats {
            guard let ceiling = format.largestAdvertisedCeiling else { continue }
            guard !format.bayerPixelFormatsForDNG.isEmpty else {
                rejections.append(
                    "\(format.configurationMode.rawValue) format \(format.index) advertises \(ceiling.width)x\(ceiling.height) but exposes no usable Bayer RAW path")
                continue
            }
            if best == nil || ceiling.pixelCount > best!.dimensions.pixelCount {
                best = (format.index, ceiling, format.bayerPixelFormatsForDNG, format.configurationMode)
            }
        }

        guard let best else { return nil }
        return Selection(
            formatIndex: best.index,
            requestedDimensions: best.dimensions,
            activeDNGPixelFormats: best.rawFormats,
            notes: rejections,
            configurationMode: best.mode)
    }

    /// A format exposes manual/priority control only when its own support query
    /// says so; used to reject a tuple that lost the controls v1 needs.
    static func supportsRequiredControls(
        probe: (FocusModeKind) -> Bool
    ) -> Bool {
        // Overload seam for tests; the camera service supplies real queries.
        probe(.manual) || probe(.continuousAuto)
    }
}
