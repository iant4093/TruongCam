import SwiftUI

// PREVIEW_TOOLS.md "Tools UI, defaults and acceptance": the sheet contains
// Histogram, Grid, Level, Peaking (off + threshold), Preview zebras (off +
// threshold), timer and sequence configuration. Exposure compensation stays on
// the camera screen. Every aid has a distinct
// accessible name and a non-colour-only enabled indicator.

struct ToolsSheet: View {
    @Bindable var camera: CameraViewModel

    var body: some View {
        NavigationStack {
            Form {
                Section("Composition") {
                    Picker("Grid", selection: gridBinding) {
                        ForEach(GridMode.allCases) { mode in
                            Text(mode.displayName).tag(mode)
                        }
                    }
                    .accessibilityLabel("Grid overlay")
                    .accessibilityValue(camera.composition.gridMode.displayName)

                    Toggle("Histogram", isOn: Binding(
                        get: { camera.composition.histogramEnabled },
                        set: { newValue in
                        camera.composition.histogramEnabled = newValue
                        Task { await camera.updateAnalysisDemand() }
                    }))
                    .accessibilityHint("Uses preview brightness, not RAW clipping.")
                    Toggle("Level", isOn: Binding(
                        get: { camera.composition.levelEnabled },
                        set: { newValue in
                        camera.composition.levelEnabled = newValue
                        Task { await camera.setLevelVisible(newValue) }
                    }))
                }

                Section {
                    Toggle("Focus peaking", isOn: Binding(
                        get: { camera.composition.peakingEnabled },
                        set: { newValue in
                        camera.composition.peakingEnabled = newValue
                        Task { await camera.updateAnalysisDemand() }
                    }))
                    Picker("Peaking threshold", selection: peakingBinding) {
                        ForEach(PeakingThreshold.allCases, id: \.self) { threshold in
                            Text(threshold.label).tag(threshold)
                        }
                    }
                    .disabled(!camera.composition.peakingEnabled)
                    Text("Highlights contrast edges. Texture can look sharp even when focus is off.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } header: {
                    Text("Focus peaking")
                } footer: {
                    Text("Higher thresholds show fewer edges.")
                }

                Section {
                    Toggle("Preview zebras", isOn: Binding(
                        get: { camera.composition.zebrasEnabled },
                        set: { newValue in
                        camera.composition.zebrasEnabled = newValue
                        Task { await camera.updateAnalysisDemand() }
                    }))
                    Picker("Zebra threshold", selection: zebraBinding) {
                        ForEach(ZebraThreshold.allCases, id: \.self) { threshold in
                            Text(threshold.label).tag(threshold)
                        }
                    }
                    .disabled(!camera.composition.zebrasEnabled)
                } header: {
                    Text("Preview zebras")
                } footer: {
                    Text("Threshold uses preview brightness, not RAW clipping.")
                }

                Section {
                    Toggle("Focus loupe", isOn: Binding(
                        get: { camera.composition.loupeEnabled },
                        set: { newValue in
                        camera.composition.loupeEnabled = newValue
                        Task { await camera.updateAnalysisDemand() }
                    }))
                    Picker("Magnification", selection: Binding(
                        get: { camera.composition.loupeMagnification },
                        set: { value in
                            camera.composition.loupeMagnification = value
                            Task { await camera.updateAnalysisDemand() }
                        })) {
                        Text("2× Preview").tag(2.0)
                        Text("4× Preview").tag(4.0)
                    }
                    .pickerStyle(.segmented)
                    .disabled(!camera.composition.loupeEnabled)
                } header: {
                    Text("Focus loupe")
                } footer: {
                    Text("Enlarges the preview. Camera zoom and saved photos stay unchanged.")
                }

                Section {
                    Picker("Capture speed", selection: Binding(
                        get: { camera.captureSpeed }, set: { camera.setCaptureSpeed($0) })) {
                        ForEach(CaptureSpeed.allCases) { speed in
                            Text(speed.displayName).tag(speed)
                        }
                    }
                    .disabled(camera.isCaptureBusy || camera.isContinuousCaptureActive)
                    .accessibilityIdentifier("captureSpeed")
                } header: {
                    Text("Capture speed")
                } footer: {
                    Text("Hold to shoot. Speed depends on capture and saving. Timer and sequences use Single.")
                }

                Section {
                    Picker("Timer", selection: Binding(
                        get: { camera.composition.timerSeconds },
                        set: { camera.setTimerSeconds($0) })) {
                        Text("Off").tag(0)
                        Text("3 seconds").tag(3)
                        Text("10 seconds").tag(10)
                    }
                    .pickerStyle(.segmented)
                    .accessibilityLabel("Self timer")
                } header: {
                    Text("Timer")
                } footer: {
                    Text("Leaving the app, an interruption or a lens change cancels the timer.")
                }

                SequenceToolsSection(camera: camera)
            }
            .navigationTitle("Capture tools")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { camera.isToolsSheetPresented = false }
                }
            }
        }
    }

    private var gridBinding: Binding<GridMode> {
        Binding(
            get: { camera.composition.gridMode },
            set: { newValue in
                camera.composition.gridMode = newValue
                Task { await camera.updateAnalysisDemand() }
            })
    }

    private var peakingBinding: Binding<PeakingThreshold> {
        Binding(
            get: { camera.composition.peakingThreshold },
            set: { newValue in
                camera.composition.peakingThreshold = newValue
                Task { await camera.updateAnalysisDemand() }
            })
    }

    private var zebraBinding: Binding<ZebraThreshold> {
        Binding(
            get: { camera.composition.zebraThreshold },
            set: { newValue in
                camera.composition.zebraThreshold = newValue
                Task { await camera.updateAnalysisDemand() }
            })
    }
}

/// Sequence configuration.
///
/// REVIEW.md C11: this used to be three hardcoded start buttons with no way to
/// change the source count, EV step, focus endpoints or interval cadence. Every
/// field is now editable within the plan's own bounds and remembered across
/// launches; the coordinator still validates a plan before anything is submitted.
private struct SequenceToolsSection: View {
    @Bindable var camera: CameraViewModel

    var body: some View {
        Section {
            if camera.isSequenceRunning {
                let status = camera.sequenceStatusLine ?? "Capturing…"
                Text(status).font(.subheadline)
                Button("Cancel sequence", role: .destructive) {
                    camera.cancelSequence()
                }
                .frame(minHeight: 44)
            } else {
                if !camera.isSequenceCaptureAvailable {
                    Text("Choose RAW for brackets and interval shooting. Settings are remembered.")
                        .font(.subheadline).foregroundStyle(.secondary)
                }
                Group {
                    exposureBracketControls
                    focusBracketControls
                    intervalControls
                }
                .disabled(!camera.isSequenceCaptureAvailable)
            }
        } header: {
            Text("Sequences")
        } footer: {
            Text("Saves separate, unmerged originals one at a time. Capture or save errors stop the sequence; captured photos are kept.")
        }
    }

    @ViewBuilder
    private var exposureBracketControls: some View {
        VStack(alignment: .leading, spacing: 6) {
            Toggle("Exposure bracket", isOn: Binding(
                get: { camera.sequencePreferences.isExposureBracketEnabled },
                set: { camera.setExposureBracketEnabled($0) }))
                .accessibilityIdentifier("exposureBracketToggle")
            Stepper("Sources: \(camera.sequencePreferences.exposureBracketCount)",
                    value: countBinding(\.exposureBracketCount), in: 3...5, step: 2)
                .frame(minHeight: 44)
            Picker("Step", selection: stepBinding) {
                Text("1/3 EV").tag(1.0 / 3.0)
                Text("2/3 EV").tag(2.0 / 3.0)
                Text("1 EV").tag(1.0)
                Text("2 EV").tag(2.0)
            }
            .pickerStyle(.menu)
            Text("EV offsets: \(offsetSummary).")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text("Each shutter press takes this bracket, including timer and camera buttons.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var focusBracketControls: some View {
        VStack(alignment: .leading, spacing: 6) {
            Toggle("Focus bracket", isOn: Binding(
                get: { camera.sequencePreferences.shutterMode == .focusBracket },
                set: { camera.setShutterMode(.focusBracket, enabled: $0) }))
                .accessibilityIdentifier("focusBracketToggle")
                .disabled(!camera.isManualFocusAvailable && camera.sequencePreferences.shutterMode != .focusBracket)
            Stepper("Sources: \(camera.sequencePreferences.focusBracketCount)",
                    value: countBinding(\.focusBracketCount), in: 2...9)
                .frame(minHeight: 44)
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text("Start position")
                    Spacer()
                    Text(String(format: "%.2f", camera.sequencePreferences.focusBracketStart))
                        .foregroundStyle(.secondary)
                }
                Slider(value: positionBinding(\.focusBracketStart), in: 0...1, step: 0.05)
                    .accessibilityLabel("Focus bracket start position")
                    .accessibilityValue(String(format: "%.2f of 1", camera.sequencePreferences.focusBracketStart))
            }
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text("End position")
                    Spacer()
                    Text(String(format: "%.2f", camera.sequencePreferences.focusBracketEnd))
                        .foregroundStyle(.secondary)
                }
                Slider(value: positionBinding(\.focusBracketEnd), in: 0...1, step: 0.05)
                    .accessibilityLabel("Focus bracket end position")
                    .accessibilityValue(String(format: "%.2f of 1", camera.sequencePreferences.focusBracketEnd))
            }
            Text("Steps are even in lens position, not subject distance.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text("Each shutter press takes this bracket. One multi-shot mode at a time.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var intervalControls: some View {
        VStack(alignment: .leading, spacing: 6) {
            Toggle("Interval", isOn: Binding(
                get: { camera.sequencePreferences.shutterMode == .interval },
                set: { camera.setShutterMode(.interval, enabled: $0) }))
                .accessibilityIdentifier("intervalToggle")
            Stepper("Originals: \(camera.sequencePreferences.intervalCount)",
                    value: countBinding(\.intervalCount), in: 1...999)
                .frame(minHeight: 44)
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text("Interval")
                    Spacer()
                    Text(String(format: "%.0f s", camera.sequencePreferences.intervalSeconds))
                        .foregroundStyle(.secondary)
                }
                Slider(value: cadenceBinding, in: 1...300, step: 1)
                    .accessibilityLabel("Interval cadence")
                    .accessibilityValue(String(format: "%.0f seconds", camera.sequencePreferences.intervalSeconds))
            }
            Text("Choose how many photos to keep. Missed times are skipped.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text("Shutter starts; Stop ends. Photos save separately.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var offsetSummary: String {
        let step = camera.sequencePreferences.exposureBracketStepEV
        let count = camera.sequencePreferences.exposureBracketCount
        let offsets = count == 5
            ? [-2 * step, -step, 0, step, 2 * step]
            : [-step, 0, step]
        return offsets.map { String(format: "%+.2f", $0) }.joined(separator: ", ")
    }

    private func countBinding(_ key: WritableKeyPath<SequencePlanPreferences, Int>) -> Binding<Int> {
        Binding(
            get: { camera.sequencePreferences[keyPath: key] },
            set: { camera.sequencePreferences[keyPath: key] = $0 })
    }

    private func positionBinding(_ key: WritableKeyPath<SequencePlanPreferences, Double>) -> Binding<Double> {
        Binding(
            get: { camera.sequencePreferences[keyPath: key] },
            set: { camera.sequencePreferences[keyPath: key] = $0 })
    }

    private var stepBinding: Binding<Double> {
        Binding(
            get: { camera.sequencePreferences.exposureBracketStepEV },
            set: { camera.sequencePreferences.exposureBracketStepEV = $0 })
    }

    private var cadenceBinding: Binding<Double> {
        Binding(
            get: { camera.sequencePreferences.intervalSeconds },
            set: { camera.sequencePreferences.intervalSeconds = $0 })
    }
}
