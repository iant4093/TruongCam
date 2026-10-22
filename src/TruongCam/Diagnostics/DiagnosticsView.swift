import SwiftUI

// HANDOFF.md Gate A: a small native diagnostics route that produces evidence. It
// is not a replacement for product features and never fabricates a measurement.
//
// Reachable only from a debug build (`#if DEBUG`). A release build cannot open
// it, and nothing here runs automatically at start-up: no hidden self-test RAWs
// are captured on ordinary launch.

#if DEBUG
struct DiagnosticsView: View {
    @Environment(AppEnvironment.self) private var app
    @State private var model = DiagnosticsModel()

    var body: some View {
        NavigationStack {
            List {
                Section("Build") {
                    LabeledContent("Version", value: "\(app.buildInfo.marketingVersion) (\(app.buildInfo.buildNumber))")
                    LabeledContent("Bundle", value: app.buildInfo.bundleIdentifier)
                    LabeledContent("Swift", value: app.buildInfo.swiftVersion)
                }

                Section {
                    Button("Run camera capability probe") {
                        Task { await model.runCameraProbe(camera: app.camera) }
                    }
                    .frame(minHeight: 44)
                    Text("Enumerates physical rear cameras, their formats and advertised photo dimensions, then asks the connected photo output for its actual Bayer RAW pixel formats. Requires camera permission.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } header: {
                    Text("Camera")
                } footer: {
                    Text("Advertised dimensions are a request ceiling. The actual RAW size stays unknown until a real capture is measured on this device.")
                }

                Section {
                    Button("Run folder locality check") {
                        Task { await model.runFolderCheck(store: app.libraryStore) }
                    }
                    .frame(minHeight: 44)
                    Text("Reports the resolved root, its owner/provider evidence and whether it is inside this app's container. It does not write to the folder.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } header: {
                    Text("Library folder")
                }

                if !model.log.isEmpty {
                    Section("Probe log") {
                        ForEach(Array(model.log.enumerated()), id: \.offset) { _, line in
                            Text(line)
                                .font(.system(.footnote, design: .monospaced))
                                .textSelection(.enabled)
                        }
                        Button("Copy log") {
                            UIPasteboard.general.string = model.log.joined(separator: "\n")
                        }
                        .frame(minHeight: 44)
                    }
                }

                Section("Honest status") {
                    Text("Device-sensitive acceptance (D01–D11) is NOT_RUN until it is executed on the physical iPhone. Nothing on this screen can mark it verified.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Diagnostics")
        }
    }
}

@MainActor
@Observable
final class DiagnosticsModel {
    private(set) var log: [String] = []

    func runCameraProbe(camera: CameraViewModel?) async {
        log = []
        append("probe started \(ISO8601Coding.shared.string(from: Date()))")
        guard let camera else {
            append("no camera view model is attached")
            return
        }
        await camera.refreshCapabilityForDiagnostics()
        let snapshot = camera.capability
        append("hardware: \(snapshot.hardwareModel)")
        append("os: \(snapshot.osVersion)  sdk: \(snapshot.sdkVersion)")
        append("bayer supported: \(snapshot.bayerCaptureSupported.detailLabel)")
        for physical in snapshot.physicalCameras {
            append("camera \(physical.kind.rawValue) (\(physical.deviceType))")
            append("  formats: \(physical.formats.count)")
            append("  bayer formats: \(physical.bayerRAWDiscovery.detailLabel)")
            append("  raw file types: \(physical.rawFileTypeDiscovery.detailLabel)")
            append("  native bracket count: \(physical.nativeBracketCountDiscovery.detailLabel)")
            append("  measured RAW: \(physical.observedRAWDimensions.detailLabel)")
            for format in physical.formats.prefix(4) {
                let dimensions = format.supportedMaxPhotoDimensions
                    .map { "\($0.width)x\($0.height)" }
                    .joined(separator: ", ")
                append("  format \(format.formatIdentifier)")
                append("    advertised max photo dimensions: \(dimensions.isEmpty ? "none reported" : dimensions)")
                append("    priority combinations: \(format.supportedPriorityCombinations.map { $0.rawValue }.sorted().joined(separator: ","))")
            }
        }
        append("probe finished; actual RAW dimensions still require a real capture")
    }

    func runFolderCheck(store: (any LibraryStoring)?) async {
        log = []
        guard let store else {
            append("no library store is installed in this build")
            return
        }
        append("root state: \(store.rootState.displayLabel)")
        append("selected root: \(store.selectedRootDescription ?? "none")")
        append("library id: \(store.rootState.libraryID?.description ?? "none")")
        append("writable: \(store.rootState.isWritable)")
        append("pending originals: \((await store.pendingOriginals()).count)")
        append("note: this check reports provider evidence only. Full deletion/reinstall retention is a separate device test.")
    }

    private func append(_ line: String) {
        log.append(line)
    }
}
#endif
