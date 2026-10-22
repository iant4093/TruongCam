import Foundation

/// A passive setter plan for a first-visit input, never evidence of Bayer RAW
/// support or permission to capture. The adapter reads these native dimensions
/// after attaching the new input and choosing .photo, in the same configuration
/// transaction that applies the returned ceiling. No activeFormat is assigned.
///
/// AVCapturePhotoOutput.maxPhotoDimensions must be advertised by the CURRENT
/// activeFormat. Reserve the complete device ceiling only when that exact format
/// supports it; uncertainty keeps the ordinary committed discovery path. The
/// committed Bayer/container/tuple queries still decide capture capability.
enum FreshPhotoCeilingReservation {
    static func plannedCeiling(candidateDimensions: [[PixelDimensions]],
                               currentFormatDimensions: [PixelDimensions]) -> PixelDimensions? {
        guard !candidateDimensions.isEmpty, !currentFormatDimensions.isEmpty,
              candidateDimensions.contains(currentFormatDimensions) else { return nil }
        var largest: PixelDimensions?
        var largestPixels: Int64 = 0
        var ambiguousLargest = false
        for dimensions in candidateDimensions {
            for dimension in dimensions {
                guard let pixels = nativePixelCount(dimension) else { return nil }
                if pixels > largestPixels {
                    largest = dimension
                    largestPixels = pixels
                    ambiguousLargest = false
                } else if pixels == largestPixels, largest != dimension {
                    // Equal-area, differently shaped maxima leave native tuple
                    // selection to the existing committed discovery operation.
                    ambiguousLargest = true
                }
            }
        }
        guard let largest, !ambiguousLargest else { return nil }
        for dimension in currentFormatDimensions {
            guard nativePixelCount(dimension) != nil else { return nil }
        }
        return currentFormatDimensions.contains(largest) ? largest : nil
    }

    private static func nativePixelCount(_ dimensions: PixelDimensions) -> Int64? {
        guard dimensions.isValid, dimensions.width <= Int(Int32.max),
              dimensions.height <= Int(Int32.max) else { return nil }
        return Int64(dimensions.width) * Int64(dimensions.height)
    }
}
