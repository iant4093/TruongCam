import Foundation

/// Maps points between the visible preview image and the capture device's
/// normalized coordinate space.
///
/// PREVIEW_TOOLS.md "Session and framing feasibility gate": a 4:3 view rectangle
/// alone does not prove a full sensor field of view, so letterboxing must be
/// accounted for and a tap outside the visible image must be rejected rather
/// than converted. The mapper also owns the single rotation/mirror application,
/// because mixing Core Image's lower-left origin with UIKit's upper-left origin
/// is a documented failure mode.
struct PreviewGeometryMapper: Hashable, Sendable {
    /// Buffer pixel dimensions as delivered by the capture output.
    let imageDimensions: PixelDimensions
    /// The rect of the preview view actually covered by image content, in view
    /// coordinates (origin top-left).
    let contentRect: TCRect
    let isMirrored: Bool
    /// Rotation applied when displaying the buffer, in degrees clockwise.
    let rotationDegrees: Int
    /// Numeric EXIF-style buffer orientation (1 = identity).
    let bufferOrientation: Int

    init(imageDimensions: PixelDimensions,
         contentRect: TCRect,
         isMirrored: Bool,
         rotationDegrees: Int,
         bufferOrientation: Int) {
        self.imageDimensions = imageDimensions
        self.contentRect = contentRect
        self.isMirrored = isMirrored
        self.rotationDegrees = ((rotationDegrees % 360) + 360) % 360
        self.bufferOrientation = bufferOrientation
    }

    /// Builds a mapper from a preview-layer content rect expressed in `Double`
    /// view coordinates.
    init(imageDimensions: PixelDimensions,
         contentRect: TCRect,
         isMirrored: Bool,
         rotationDegrees: Int) {
        self.init(imageDimensions: imageDimensions,
                  contentRect: contentRect,
                  isMirrored: isMirrored,
                  rotationDegrees: rotationDegrees,
                  bufferOrientation: 1)
    }

    /// Derives the content rect from an aspect-fit presentation of the image
    /// inside `viewSize`, centered with letterboxing.
    init(imageDimensions: PixelDimensions,
         letterboxingIn viewSize: TCSize,
         isMirrored: Bool,
         rotationDegrees: Int,
         bufferOrientation: Int) {
        let rect = PreviewGeometryMapper.aspectFitRect(
            imageDimensions: imageDimensions,
            rotationDegrees: rotationDegrees,
            in: TCRect(origin: .zero, size: viewSize))
        self.init(imageDimensions: imageDimensions,
                  contentRect: rect,
                  isMirrored: isMirrored,
                  rotationDegrees: rotationDegrees,
                  bufferOrientation: bufferOrientation)
    }

    /// Aspect-fit rect for the (possibly rotated) image inside `bounds`.
    static func aspectFitRect(imageDimensions: PixelDimensions,
                              rotationDegrees: Int,
                              in bounds: TCRect) -> TCRect {
        let normalized = ((rotationDegrees % 360) + 360) % 360
        let swaps = normalized == 90 || normalized == 270
        let displayedWidth = Double(swaps ? imageDimensions.height : imageDimensions.width)
        let displayedHeight = Double(swaps ? imageDimensions.width : imageDimensions.height)
        guard displayedWidth > 0, displayedHeight > 0, !bounds.isEmpty else { return bounds }
        let scale = min(bounds.width / displayedWidth, bounds.height / displayedHeight)
        let width = displayedWidth * scale
        let height = displayedHeight * scale
        return TCRect(x: bounds.midX - width / 2,
                      y: bounds.midY - height / 2,
                      width: width,
                      height: height)
    }

    var isDegenerate: Bool {
        contentRect.isEmpty || !imageDimensions.isValid
    }

    /// True when the buffer's presented orientation has swapped axes relative to
    /// the device's natural landscape sensor coordinates.
    private var swapsAxesForDeviceSpace: Bool {
        (rotationDegrees == 90 || rotationDegrees == 270) && bufferOrientation >= 5
    }

    /// Converts a view-space point into normalized device coordinates.
    /// Returns nil when the point lies outside the visible image content.
    func devicePoint(forViewPoint viewPoint: TCPoint) -> NormalizedDevicePoint? {
        guard !isDegenerate, viewPoint.isFinite, contentRect.contains(viewPoint) else { return nil }

        let normalizedU = (viewPoint.x - contentRect.minX) / contentRect.width
        let u = isMirrored ? 1 - normalizedU : normalizedU
        let v = (viewPoint.y - contentRect.minY) / contentRect.height
        guard u >= 0, u <= 1, v >= 0, v <= 1 else { return nil }

        // Undo the display rotation to get back to buffer space.
        var bufferU = u
        var bufferV = v
        switch rotationDegrees {
        case 90:
            bufferU = v
            bufferV = 1 - u
        case 180:
            bufferU = 1 - u
            bufferV = 1 - v
        case 270:
            bufferU = 1 - v
            bufferV = u
        default:
            break
        }


        let devicePoint = swapsAxesForDeviceSpace
            ? NormalizedDevicePoint(x: bufferV, y: bufferU)
            : NormalizedDevicePoint(x: bufferU, y: bufferV)
        guard devicePoint.isInsideUnitSquare else { return nil }
        return devicePoint
    }

    /// Converts a normalized device point back to view space. Used to place
    /// focus/metering overlays.
    func viewPoint(forDevicePoint devicePoint: NormalizedDevicePoint) -> TCPoint? {
        guard !isDegenerate, devicePoint.isInsideUnitSquare else { return nil }
        var bufferU = devicePoint.x
        var bufferV = devicePoint.y
        if swapsAxesForDeviceSpace {
            bufferU = devicePoint.y
            bufferV = devicePoint.x
        }
        var u = bufferU
        var v = bufferV
        switch rotationDegrees {
        case 90:
            u = 1 - bufferV
            v = bufferU
        case 180:
            u = 1 - bufferU
            v = 1 - bufferV
        case 270:
            u = bufferV
            v = 1 - bufferU
        default:
            break
        }
        if isMirrored { u = 1 - u }
        guard u >= 0, u <= 1, v >= 0, v <= 1 else { return nil }
        return TCPoint(x: contentRect.minX + u * contentRect.width,
                       y: contentRect.minY + v * contentRect.height)
    }

    /// Maps a normalized mask cell (row-major over the analysis image) into a
    /// view-space rect so peaking/zebra overlays line up with the preview.
    func viewRect(forMaskColumn column: Int,
                  row: Int,
                  maskWidth: Int,
                  maskHeight: Int) -> TCRect? {
        guard maskWidth > 0, maskHeight > 0, !isDegenerate else { return nil }
        guard column >= 0, column < maskWidth, row >= 0, row < maskHeight else { return nil }
        let cellWidth = contentRect.width / Double(maskWidth)
        let cellHeight = contentRect.height / Double(maskHeight)
        return TCRect(x: contentRect.minX + Double(column) * cellWidth,
                      y: contentRect.minY + Double(row) * cellHeight,
                      width: cellWidth,
                      height: cellHeight)
    }

    /// The sampled rectangle for the focus loupe, clamped to actual image
    /// bounds so a loupe near an edge shows real pixels rather than padding.
    func clampedLoupeSampleRect(center: NormalizedDevicePoint,
                                magnification: Double,
                                imageDimensions: PixelDimensions) -> PixelRect? {
        guard magnification > 0, imageDimensions.isValid, center.isFinite else { return nil }
        let sampleWidth = Double(imageDimensions.width) / magnification
        let sampleHeight = Double(imageDimensions.height) / magnification
        guard sampleWidth >= 1, sampleHeight >= 1 else { return nil }

        var bufferX = center.x
        var bufferY = center.y
        if swapsAxesForDeviceSpace {
            bufferX = center.y
            bufferY = center.x
        }
        let centrePixelX = bufferX * Double(imageDimensions.width)
        let centrePixelY = bufferY * Double(imageDimensions.height)

        let maxOriginX = Double(imageDimensions.width) - sampleWidth
        let maxOriginY = Double(imageDimensions.height) - sampleHeight
        let originX = min(max(centrePixelX - sampleWidth / 2, 0), max(0, maxOriginX))
        let originY = min(max(centrePixelY - sampleHeight / 2, 0), max(0, maxOriginY))

        let width = Int(sampleWidth.rounded(.down))
        let height = Int(sampleHeight.rounded(.down))
        guard width >= 1, height >= 1 else { return nil }
        return PixelRect(x: Int(originX.rounded(.down)),
                         y: Int(originY.rounded(.down)),
                         width: width,
                         height: height)
    }
}

/// Integer pixel rectangle used by decoding and mask geometry.
struct PixelRect: Hashable, Sendable {
    let x: Int
    let y: Int
    let width: Int
    let height: Int

    var maxX: Int { x + width }
    var maxY: Int { y + height }
    var isEmpty: Bool { width <= 0 || height <= 0 }
}
