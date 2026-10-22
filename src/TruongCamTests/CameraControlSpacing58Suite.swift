import CoreGraphics
import Foundation
#if canImport(XCTest)
@testable import TruongCam
#endif

enum CameraControlSpacing58Suite {
    static let suite = TCSuite(id: "CameraControlSpacing58", title: "Lower fixed controls with a separate adjustment-to-shutter gap", cases: [
        TCCase(id: "CS58P", title: "Ordinary portrait lowers the readouts a little and the shutter further without shrinking the whole frame") { r in
            let layout = CameraScreenLayout(size: CGSize(width: 402, height: 778), bottomSafeArea: 34, accessibility: false)
            // Build57 at these same safe-content dimensions: readout y532,
            // shutter y688, complete preview height524. These independent
            // reference coordinates distinguish a new gap from a blank spacer
            // that merely pushes the frame or safe-area controls off screen.
            r.close("readouts and rulers move down four points", Double(layout.controls.minY), 536)
            let shutterTop = layout.controls.minY + layout.parameterHeight + CameraScreenLayout.adjustmentShutterSpacing
            r.close("the shutter moves down twelve points", Double(shutterTop), 700)
            r.close("the newly reserved breathing room is eight points", Double(CameraScreenLayout.adjustmentShutterSpacing), 8)
            r.close("all WB content remains reserved", Double(layout.adjustmentViewportHeight), 100)
            r.close("uncropped frame grows with the reclaimed clearance", Double(layout.preview.height), 528)
            r.close("uncropped portrait aspect", Double(layout.preview.width / layout.preview.height), 0.75)
            r.check("shutter stays inside safe content", shutterTop + 76 <= 778)
            r.check("caption finishes above the home-indicator edge", layout.controls.maxY <= 778 + 34 - 12)
        },
        TCCase(id: "CS58M", title: "Compact, notched, large and accessibility layouts retain safe targets and the fixed gap") { r in
            let phones: [(CGFloat, CGFloat, CGFloat, CGFloat)] = [
                (320, 568, 20, 0), (375, 667, 20, 0), (375, 812, 44, 34),
                (390, 844, 47, 34), (402, 874, 62, 34), (430, 932, 59, 34), (440, 956, 62, 34)
            ]
            for (width, height, top, bottom) in phones {
                for accessibility in [false, true] {
                    let safeHeight = height - top - bottom
                    let layout = CameraScreenLayout(size: CGSize(width: width, height: safeHeight), bottomSafeArea: bottom, accessibility: accessibility)
                    let label = "\(width)x\(height), AX=\(accessibility)"
                    let wellTop = layout.controls.minY + CameraScreenLayout.readoutHeight
                    let wellBottom = wellTop + layout.adjustmentViewportHeight
                    let shutterTop = layout.controls.maxY - layout.shutterRailHeight
                    r.close("separate gap remains fixed \(label)", Double(shutterTop - wellBottom), 8)
                    r.check("Auto and close retain a full target \(label)", layout.adjustmentViewportHeight >= 44)
                    r.check("WB content can scroll rather than shrink its targets \(label)", layout.naturalAdjustmentHeight >= 96)
                    r.check("preview never overlaps controls \(label)", layout.preview.maxY + 7.999 <= layout.controls.minY)
                    r.check("preview remains inside safe content \(label)", CGRect(x: 0, y: 0, width: width, height: safeHeight).contains(layout.preview))
                    r.close("preview stays uncropped \(label)", Double(layout.preview.width / layout.preview.height), 0.75)
                    r.check("interactive shutter remains above safe edge \(label)", shutterTop + 76 <= safeHeight)
                    r.check("whole caption stays on screen \(label)", layout.controls.maxY <= safeHeight + bottom)
                    r.check("caption avoids the home indicator \(label)", bottom == 0 || layout.controls.maxY <= safeHeight + bottom - 12)
                    r.close("shutter remains centered \(label)", Double(layout.controls.midX), Double(width / 2))
                }
            }
            let compact = CameraScreenLayout(size: CGSize(width: 320, height: 548), bottomSafeArea: 0, accessibility: true)
            r.close("short no-inset phones keep their full caption on screen", Double(compact.controls.maxY), 548)
            r.close("short phones preserve their minimum complete frame", Double(compact.preview.height), 320)
        },
        TCCase(id: "CS58L", title: "Both landscape safe-area directions preserve shutter position and an independent scroll-to-shutter gap") { r in
            for size in [CGSize(width: 528, height: 320), CGSize(width: 724, height: 354), CGSize(width: 750, height: 381), CGSize(width: 832, height: 419)] {
                for bottom in [CGFloat(0), 21] {
                    for accessibility in [false, true] {
                        let layout = CameraScreenLayout(size: size, bottomSafeArea: bottom, accessibility: accessibility)
                        let bounds = CGRect(origin: .zero, size: size)
                        let shutterTop = layout.controls.minY + layout.parameterHeight + CameraScreenLayout.adjustmentShutterSpacing
                        r.close("landscape shutter stays at its prior bottom anchor", Double(shutterTop), Double(size.height - 6 - 116))
                        r.close("landscape gap is outside the parameter scroll", Double(shutterTop - layout.controls.minY - layout.parameterHeight), 8)
                        r.check("shutter has its complete rail", layout.shutterRailHeight >= 112)
                        r.check("parameters remain reachable", layout.parameterHeight >= 44)
                        r.check("frame and controls fit either safe-area direction", bounds.contains(layout.preview) && bounds.contains(layout.controls))
                        r.check("landscape image remains clear", !layout.preview.intersects(layout.controls))
                        r.close("uncropped landscape aspect", Double(layout.preview.width / layout.preview.height), 4.0 / 3)
                    }
                }
            }
        }
    ])
}
