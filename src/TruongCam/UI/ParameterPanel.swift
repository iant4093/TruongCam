import SwiftUI
import UIKit

/// Always occupies the same reserved gap. Hiding/changing controls never moves
/// the capture button or viewfinder. Values remain in the parameter readout.
struct CameraAdjustmentWell: View {
    @Bindable var camera: CameraViewModel
    var controlsViewportHeight: CGFloat? = nil
    var controlsContentHeight: CGFloat = 100
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        ZStack {
            if let panel = camera.openPanel {
                HStack(spacing: 10) {
                    Button { camera.setStripAutomatic(panel) } label: {
                        Text(camera.stripAutomaticLabel(panel)).font(.caption2).frame(width: 44, height: 44)
                    }
                    .foregroundStyle(isAutomatic(panel) ? Color.yellow : Color.white)
                    .accessibilityLabel(autoAccessibility(panel))
                    .disabled(!camera.canSetStripAutomatic(panel))
                    Group {
                        if let viewport = controlsViewportHeight, viewport < controlsContentHeight {
                            ScrollView(.vertical) {
                                controls(panel).frame(maxWidth: .infinity).frame(height: controlsContentHeight)
                            }
                            .scrollBounceBehavior(.basedOnSize)
                            .frame(height: viewport).clipped()
                        } else { controls(panel) }
                    }.frame(maxWidth: .infinity)
                    Button { camera.openPanel = nil } label: {
                        Image(systemName: "xmark").frame(width: 44, height: 44)
                    }.accessibilityLabel("Close adjustment controls")
                }
                .buttonStyle(CameraPressStyle())
                .id(panel)
                .transition(.opacity.combined(with: .offset(y: reduceMotion ? 0 : 6)))
            } else {
                VStack(spacing: 4) {
                    if let paused = camera.pausedAids.first {
                        Text(paused.statusLabel).font(.caption2).foregroundStyle(.orange)
                    }
                }
            }
        }.foregroundStyle(.white).tint(.yellow)
            .disabled(camera.isCaptureBusy)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.18), value: camera.openPanel)
    }
    private func autoAccessibility(_ panel: CameraPanel) -> String {
        if panel == .exposureBias { return "Reset exposure compensation" }
        switch camera.stripAutomaticLabel(panel) {
        case "Auto both": return "Set shutter and ISO to automatic"
        case "Auto all": return "Set aperture, shutter and ISO to automatic"
        default: return "Set \(panel.title) to automatic"
        }
    }
    private func isAutomatic(_ panel: CameraPanel) -> Bool {
        switch panel {
        case .shutter: return !camera.isShutterManual
        case .iso: return !camera.isISOManual
        case .aperture: return !camera.isApertureManual
        case .focus: return camera.focus.mode != .manual
        case .whiteBalance: return camera.whiteBalance.mode == .auto
        case .exposureBias: return camera.biasEV == 0
        }
    }
    @ViewBuilder private func controls(_ panel: CameraPanel) -> some View {
        switch panel {
        case .exposureBias:
            if camera.exposureLimits.isValid, camera.isBiasAvailable {
                let limits = camera.exposureLimits
                let steps = stride(from: ceil(limits.minBiasEV * 3), through: floor(limits.maxBiasEV * 3), by: 1).map { $0 / 3 }
                DetentRuler(values: steps, value: camera.biasEV, label: "Exposure compensation",
                    displayValue: ExposureFormatting.bias(camera.biasEV), onSelect: camera.setBias)
            } else { unavailable("EV adjusts automatic exposure. Use shutter or ISO in manual.") }
        case .shutter:
            if camera.exposureLimits.isValid, camera.supportsExposureMode(.manual) || camera.supportsExposureMode(.shutterPriority) {
                let limits = camera.exposureLimits
                let steps = PhotographicExposureSteps.legal(PhotographicExposureSteps.durations,
                    minimum: limits.minDurationSeconds, maximum: limits.maxDurationSeconds)
                DetentRuler(values: steps, value: camera.exposure.durationTargetSeconds ?? camera.observedDurationSeconds ?? limits.minDurationSeconds,
                    label: "Shutter duration", displayValue: camera.shutterReadout, onSelect: camera.adjustShutterFromStrip)
                    .accessibilityHint(camera.stripManualHint(panel))
            } else { unavailable("Manual exposure unavailable") }
        case .iso:
            if camera.exposureLimits.isValid, camera.supportsExposureMode(.manual) || camera.supportsExposureMode(.isoPriority) {
                let limits = camera.exposureLimits
                let steps = PhotographicExposureSteps.legal(PhotographicExposureSteps.iso,
                    minimum: limits.minISO, maximum: limits.maxISO)
                DetentRuler(values: steps, value: camera.exposure.isoTarget ?? camera.observedISO ?? limits.minISO,
                    label: "ISO", displayValue: camera.isoReadout, onSelect: camera.adjustISOFromStrip)
                    .accessibilityHint(camera.stripManualHint(panel))
            } else { unavailable("Manual exposure unavailable") }
        case .aperture:
            if camera.canAdjustAperture, !camera.apertureStops.isEmpty {
                DetentRuler(values: camera.apertureStops, value: camera.selectedApertureValue,
                    label: "Lens aperture", displayValue: camera.apertureReadout,
                    onSelect: camera.setAperture)
                    .accessibilityHint(camera.stripManualHint(panel))
            } else { unavailable("Aperture unavailable with these exposure settings") }
        case .focus:
            if camera.isManualFocusAvailable {
                DetentRuler(values: (0...50).map { Double($0) / 50 },
                    value: camera.focus.position ?? camera.observedFocusPosition ?? 0.5,
                    label: "Focus position", displayValue: camera.focusReadout, onSelect: camera.setManualFocusPosition)
            } else { unavailable("Manual focus unavailable") }
        case .whiteBalance:
            if camera.isManualWhiteBalanceAvailable {
                let domain = WhiteBalanceSliderDomain.productPolicy
                VStack(spacing: 8) {
                    DetentRuler(values: stride(from: domain.minKelvin, through: domain.maxKelvin, by: 100).map { $0 },
                        value: camera.whiteBalance.temperatureAndTint?.temperature ?? 5500,
                        label: "White balance temperature", displayValue: "\(Int(camera.whiteBalance.temperatureAndTint?.temperature ?? 5500)) K",
                        onSelect: camera.setWhiteBalanceTemperature,
                        caption: "Temp · \(Int(camera.whiteBalance.temperatureAndTint?.temperature ?? 5500)) K")
                        .frame(height: 44)
                    DetentRuler(values: stride(from: domain.minTint, through: domain.maxTint, by: 5).map { $0 },
                        value: camera.whiteBalance.temperatureAndTint?.tint ?? 0,
                        label: "White balance tint", displayValue: String(format: "%+.0f", Double(camera.whiteBalance.temperatureAndTint?.tint ?? 0.0)),
                        onSelect: camera.setWhiteBalanceTint,
                        caption: "Tint · \(String(format: "%+.0f", Double(camera.whiteBalance.temperatureAndTint?.tint ?? 0.0)))")
                        .frame(height: 44)
                }
            } else { unavailable("Manual white balance unavailable") }
        }
    }
    private func unavailable(_ text: String) -> some View {
        Text(text).font(.caption2).foregroundStyle(.secondary).multilineTextAlignment(.center)
    }
}

/// Fixed-center ruler: a short, predictable movement selects one photographic
/// detent. No continuous native setter traffic between ticks. VoiceOver exposes
/// the same increments instead of an unrelated continuous range.
private struct DetentRuler: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let values: [Double]
    let value: Double
    let label: String
    let displayValue: String
    let onSelect: (Double) -> Void
    var caption: String? = nil
    @State private var dragOrigin: Int?
    @State private var dragTravel: CGFloat = 0
    private var selected: Int { PhotographicExposureSteps.nearest(value, in: values) }
    private func choose(_ index: Int) {
        guard !values.isEmpty else { return }
        let next = min(max(index, 0), values.count - 1)
        guard values[next] != value else { return }
        onSelect(values[next])
        UISelectionFeedbackGenerator().selectionChanged()
    }
    var body: some View {
        Canvas { context, size in
            let position = dragOrigin.map { CGFloat($0) - dragTravel / 18 } ?? CGFloat(selected)
            for offset in -20...20 {
                let index = Int(position.rounded()) + offset
                guard values.indices.contains(index) else { continue }
                let x = size.width / 2 + (CGFloat(index) - position) * 18
                guard x >= 0, x <= size.width else { continue }
                var tick = Path()
                let labelHeight: CGFloat = caption == nil ? 0 : 16
                let trackHeight = max(0, size.height - labelHeight)
                let height: CGFloat = min(trackHeight, index % 3 == 0 ? 15 : 9)
                let center = labelHeight + trackHeight / 2
                tick.move(to: CGPoint(x: x, y: center - height / 2))
                tick.addLine(to: CGPoint(x: x, y: center + height / 2))
                context.stroke(tick, with: .color(.white.opacity(0.35)), lineWidth: 1)
            }
            let labelHeight: CGFloat = caption == nil ? 0 : 16
            let trackHeight = max(0, size.height - labelHeight)
            let height = min(26, max(0, trackHeight - 4))
            var marker = Path()
            marker.move(to: CGPoint(x: size.width / 2, y: labelHeight + (trackHeight - height) / 2))
            marker.addLine(to: CGPoint(x: size.width / 2, y: labelHeight + (trackHeight + height) / 2))
            context.stroke(marker, with: .color(.yellow), lineWidth: 3)
        }
        .overlay(alignment: .top) {
            if let caption {
                Text(caption).font(.caption2).lineLimit(1).minimumScaleFactor(0.8)
                    .allowsHitTesting(false).accessibilityHidden(true)
            }
        }
        .frame(minHeight: 44)
        .contentShape(Rectangle())
        .gesture(DragGesture(minimumDistance: 2).onChanged { movement in
            if dragOrigin == nil { dragOrigin = selected }
            dragTravel = movement.translation.width
            choose((dragOrigin ?? selected) - Int((movement.translation.width / 18).rounded()))
        }.onEnded { _ in
            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.14)) {
                dragOrigin = nil
                dragTravel = 0
            }
        })
        .accessibilityElement().accessibilityLabel(label).accessibilityValue(displayValue)
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: choose(selected + 1)
            case .decrement: choose(selected - 1)
            @unknown default: break
            }
        }
    }
}
