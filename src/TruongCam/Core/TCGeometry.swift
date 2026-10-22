import Foundation

// Portable geometry value types.
//
// CoreGraphics is not available in every context the pure logic runs in (the
// local logic verifier compiles these files without importing CoreGraphics), so
// the frozen contracts use these small `Double`-based types. UIKit-facing code
// converts them at the boundary. This also keeps overlay/letterboxing reasoning
// in one coordinate convention.

struct TCPoint: Hashable, Sendable, Codable {
    var x: Double
    var y: Double

    init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }

    static let zero = TCPoint(x: 0, y: 0)

    var isFinite: Bool { x.isFinite && y.isFinite }
}

struct TCSize: Hashable, Sendable, Codable {
    var width: Double
    var height: Double

    init(width: Double, height: Double) {
        self.width = width
        self.height = height
    }

    static let zero = TCSize(width: 0, height: 0)

    var isFinite: Bool { width.isFinite && height.isFinite }
    var isEmpty: Bool { width <= 0 || height <= 0 }
}

struct TCRect: Hashable, Sendable, Codable {
    var origin: TCPoint
    var size: TCSize

    init(origin: TCPoint, size: TCSize) {
        self.origin = origin
        self.size = size
    }

    init(x: Double, y: Double, width: Double, height: Double) {
        self.origin = TCPoint(x: x, y: y)
        self.size = TCSize(width: width, height: height)
    }

    static let zero = TCRect(origin: .zero, size: .zero)

    var minX: Double { origin.x }
    var minY: Double { origin.y }
    var width: Double { size.width }
    var height: Double { size.height }
    var maxX: Double { origin.x + size.width }
    var maxY: Double { origin.y + size.height }
    var midX: Double { origin.x + size.width / 2 }
    var midY: Double { origin.y + size.height / 2 }
    var isEmpty: Bool { size.isEmpty }

    var isFinite: Bool { origin.isFinite && size.isFinite }

    func contains(_ point: TCPoint) -> Bool {
        guard !isEmpty, point.isFinite else { return false }
        return point.x >= minX && point.x <= maxX && point.y >= minY && point.y <= maxY
    }

    func insetBy(dx: Double, dy: Double) -> TCRect {
        TCRect(x: minX + dx, y: minY + dy,
               width: max(0, width - 2 * dx), height: max(0, height - 2 * dy))
    }

    /// Intersection with another rect, or nil when they do not overlap.
    func intersection(_ other: TCRect) -> TCRect? {
        let x0 = max(minX, other.minX)
        let y0 = max(minY, other.minY)
        let x1 = min(maxX, other.maxX)
        let y1 = min(maxY, other.maxY)
        guard x1 > x0, y1 > y0 else { return nil }
        return TCRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0)
    }

    var integral: TCRect {
        let x0 = minX.rounded(.down)
        let y0 = minY.rounded(.down)
        let x1 = maxX.rounded(.up)
        let y1 = maxY.rounded(.up)
        return TCRect(x: x0, y: y0, width: max(0, x1 - x0), height: max(0, y1 - y0))
    }
}


/// One byte mask, oriented once from unrotated analysis buffers into the preview.
enum PreviewMaskOrientation {
    private static func mirrorRows(_ bytes: [UInt8], width: Int, height: Int) -> [UInt8] {
        var result = bytes
        for y in 0..<height { for x in 0..<width { result[y * width + x] = bytes[y * width + width - 1 - x] } }
        return result
    }
    static func rotate(_ bytes: [UInt8], width: Int, height: Int, degrees: Int, mirrored: Bool = false) -> (bytes: [UInt8], width: Int, height: Int) {
        let dimensions = PixelDimensions(width: width, height: height)
        guard dimensions.isValid, Int64(bytes.count) == dimensions.pixelCount else { return ([], 0, 0) }
        let angle = ((degrees % 360) + 360) % 360
        guard angle == 90 || angle == 180 || angle == 270 else {
            return (mirrored ? mirrorRows(bytes, width: width, height: height) : bytes, width, height)
        }
        let newWidth = angle == 180 ? width : height
        let newHeight = angle == 180 ? height : width
        var result = [UInt8](repeating: 0, count: bytes.count)
        for y in 0..<height {
            for x in 0..<width {
                let nx: Int, ny: Int
                switch angle {
                case 90: nx = height - 1 - y; ny = x
                case 180: nx = width - 1 - x; ny = height - 1 - y
                default: nx = y; ny = width - 1 - x
                }
                result[ny * newWidth + nx] = bytes[y * width + x]
            }
        }
        return (mirrored ? mirrorRows(result, width: newWidth, height: newHeight) : result, newWidth, newHeight)
    }
}

/// Camera-specific native sensor rotations for each interface orientation.
/// Production obtains these from AVCaptureDevice.RotationCoordinator on iOS 27.
struct CameraRotationAngles: Equatable, Sendable {
    let portrait: Int
    let portraitUpsideDown: Int
    let landscapeLeft: Int
    let landscapeRight: Int
    /// Rear-camera fallback for empty-session layout fixtures, not discovery evidence.
    static let rear = CameraRotationAngles(portrait: 90, portraitUpsideDown: 270, landscapeLeft: 180, landscapeRight: 0)
}
