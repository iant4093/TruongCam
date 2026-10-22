import CoreGraphics
import Foundation

/// GeometryReader's size already excludes its inherited safe areas. Reserve an
/// opaque control region, then fit the whole 3:4 image above/beside it. Only the
/// noninteractive portrait caption may enter the bottom safe inset, reserving
/// its last twelve points when available. Interactive controls stay in safe content.
struct CameraScreenLayout: Equatable, Sendable {
    let preview: CGRect
    let controls: CGRect
    let parameterHeight: CGFloat
    let adjustmentViewportHeight: CGFloat
    let naturalAdjustmentHeight: CGFloat
    let shutterRailHeight: CGFloat
    let isLandscape: Bool
    static let readoutHeight: CGFloat = 56
    static let separation: CGFloat = 8
    static let adjustmentShutterSpacing: CGFloat = 8

    init(size: CGSize, bottomSafeArea: CGFloat, accessibility: Bool) {
        let width = max(1, size.width.isFinite ? size.width : 1)
        let height = max(1, size.height.isFinite ? size.height : 1)
        let bottom = max(0, bottomSafeArea.isFinite ? bottomSafeArea : 0)
        isLandscape = width > height
        naturalAdjustmentHeight = accessibility ? 176 : 100
        if isLandscape {
            let rail = min(width, max(245, min(280, width * 0.30)))
            let available = max(1, width - rail)
            let imageWidth = min(available, height * 4 / 3)
            preview = CGRect(x: (available - imageWidth) / 2, y: (height - imageWidth * 3 / 4) / 2,
                             width: imageWidth, height: imageWidth * 3 / 4)
            controls = CGRect(x: available, y: 0, width: rail, height: max(1, height - 6))
            shutterRailHeight = 116
            parameterHeight = max(1, controls.height - shutterRailHeight - Self.adjustmentShutterSpacing)
            adjustmentViewportHeight = naturalAdjustmentHeight
        } else {
            shutterRailHeight = 96 // 76-point shutter plus a quiet 20-point caption.
            // Lower the action row without approaching the home indicator. On
            // ordinary home-inset phones, four points also lower the readouts
            // and rulers; compact/no-inset screens retain the safe fit instead.
            let extensionBelowSafeArea = min(18, max(0, bottom - 12))
            let lowerEdge = max(1, height + extensionBelowSafeArea)
            let preferredMinimumImageHeight = min(width, 240) * 4 / 3
            let naturalParameters = Self.readoutHeight + naturalAdjustmentHeight
            let spaceForParameters = lowerEdge - preferredMinimumImageHeight - Self.separation - shutterRailHeight - Self.adjustmentShutterSpacing
            parameterHeight = min(naturalParameters, max(Self.readoutHeight + 44, spaceForParameters))
            adjustmentViewportHeight = max(44, parameterHeight - Self.readoutHeight)
            controls = CGRect(x: 0, y: max(0, lowerEdge - parameterHeight - Self.adjustmentShutterSpacing - shutterRailHeight),
                              width: width, height: parameterHeight + Self.adjustmentShutterSpacing + shutterRailHeight)
            let imageHeight = max(1, min(width * 4 / 3, controls.minY - Self.separation))
            preview = CGRect(x: (width - imageHeight * 3 / 4) / 2, y: 0,
                             width: imageHeight * 3 / 4, height: imageHeight)
        }
    }
}
