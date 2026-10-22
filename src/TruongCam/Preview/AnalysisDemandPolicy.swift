import Foundation

// PREVIEW_TOOLS.md "Shared analysis pipeline" + CONTRACTS.md "Semantic
// interfaces" (`setAnalysisDemand`) and "Camera, source and library state".
//
// Pure policy: enabled aids + app/scene/lifecycle state + resource pressure →
// the `AnalysisDemand`, the `AnalysisRequest?` and the update-rate policy.
//
// Two rules drive everything here:
//   * Capture/export storage takes precedence over optional analysis, so an
//     in-flight capture/export pauses every optional aid (visibly).
//   * Memory/thermal pressure reduces the update rate and can pause an
//     individual tool; it never evicts pending originals and never presents a
//     stale overlay as a live frame.

/// One optional preview aid. The union of the enabled ones is the analysis
/// demand; there is no per-tool sample queue.
enum PreviewAidKind: String, Hashable, Sendable, CaseIterable {
    case histogram
    case peaking
    case zebras
    case loupe

    var displayLabel: String {
        switch self {
        case .histogram: return "Preview histogram"
        case .peaking: return "Focus peaking"
        case .zebras: return "Preview zebras"
        case .loupe: return "Focus loupe"
        }
    }
}

/// Scheduling targets from PREVIEW_TOOLS.md, subject to profiling. A rate of 0
/// means "do not compute this aid".
struct AnalysisRateLimits: Hashable, Sendable {
    var histogramHz: Double
    var peakingHz: Double
    var zebraHz: Double
    var loupeHz: Double

    static let maskAnalysisHz = 20.0
    static let loupeAnalysisHz = 30.0
    static let nominal = AnalysisRateLimits(histogramHz: 10, peakingHz: maskAnalysisHz, zebraHz: maskAnalysisHz, loupeHz: loupeAnalysisHz)

    /// Native acquisition serves the union demand. A loupe must not inherit the
    /// slower mask cap when both are enabled. Keep the existing non-loupe floor
    /// for current-preview/still delivery; each aid applies its own rate below.
    static func nativeAcquisitionHz(masksEnabled: Bool, loupeEnabled: Bool) -> Double {
        max(15, masksEnabled ? maskAnalysisHz : 0, loupeEnabled ? loupeAnalysisHz : 0)
    }

    init(histogramHz: Double, peakingHz: Double, zebraHz: Double, loupeHz: Double) {
        self.histogramHz = max(0, histogramHz.isFinite ? histogramHz : 0)
        self.peakingHz = max(0, peakingHz.isFinite ? peakingHz : 0)
        self.zebraHz = max(0, zebraHz.isFinite ? zebraHz : 0)
        self.loupeHz = max(0, loupeHz.isFinite ? loupeHz : 0)
    }

    func hertz(for aid: PreviewAidKind) -> Double {
        switch aid {
        case .histogram: return histogramHz
        case .peaking: return peakingHz
        case .zebras: return zebraHz
        case .loupe: return loupeHz
        }
    }

    func interval(for aid: PreviewAidKind) -> Double {
        let hz = hertz(for: aid)
        return hz > 0 ? 1.0 / hz : .infinity
    }

    /// Reduces every rate by `factor` (0...1), keeping at least 1 Hz for aids that
    /// remain enabled so a tool degrades instead of silently vanishing.
    func scaled(by factor: Double) -> AnalysisRateLimits {
        let bounded = min(max(factor.isFinite ? factor : 1, 0), 1)
        func reduce(_ hz: Double) -> Double { hz <= 0 ? 0 : max(1, hz * bounded) }
        return AnalysisRateLimits(histogramHz: reduce(histogramHz),
                                  peakingHz: reduce(peakingHz),
                                  zebraHz: reduce(zebraHz),
                                  loupeHz: reduce(loupeHz))
    }
}

/// The user's remembered composition-aid preferences. Defaults come from
/// PREVIEW_TOOLS.md "Tools UI, defaults and acceptance": histogram on; peaking,
/// zebras and loupe off; loupe 2×.
struct PreviewAidConfiguration: Hashable, Sendable {
    var isHistogramEnabled: Bool
    var isPeakingEnabled: Bool
    var peakingThreshold: PeakingThreshold
    var isZebrasEnabled: Bool
    var zebraThreshold: ZebraThreshold
    var isLoupeEnabled: Bool
    var loupeMagnification: Double
    var loupeCenter: NormalizedDevicePoint

    static let `default` = PreviewAidConfiguration(isHistogramEnabled: true,
                                                   isPeakingEnabled: false,
                                                   peakingThreshold: .normal,
                                                   isZebrasEnabled: false,
                                                   zebraThreshold: .default,
                                                   isLoupeEnabled: false,
                                                   loupeMagnification: LoupeRenderer.defaultMagnification,
                                                   loupeCenter: .center)

    var enabledAids: [PreviewAidKind] {
        var aids: [PreviewAidKind] = []
        if isHistogramEnabled { aids.append(.histogram) }
        if isPeakingEnabled { aids.append(.peaking) }
        if isZebrasEnabled { aids.append(.zebras) }
        if isLoupeEnabled { aids.append(.loupe) }
        return aids
    }
}

extension NormalizedDevicePoint {
    static let center = NormalizedDevicePoint(x: 0.5, y: 0.5)
}

/// What the app/scene/camera is doing. Only `activeCameraView` admits analysis.
enum PreviewLifecycleState: Hashable, Sendable {
    case activeCameraView
    case cameraNotRunning
    case cameraInterrupted(reason: String)
    case libraryNavigating
    case sceneInactive
    case analysisUnsupported(reason: String)

    var allowsAnalysis: Bool { self == .activeCameraView }

    var statusLabel: String {
        switch self {
        case .activeCameraView: return "Camera view active"
        case .cameraNotRunning: return "Analysis off — camera not running"
        case .cameraInterrupted: return "Preview tools paused while the camera reconnects"
        case .libraryNavigating: return "Analysis off — library is open"
        case .sceneInactive: return "Analysis off — app is not active"
        case .analysisUnsupported: return "Preview tools are temporarily unavailable"
        }
    }
}

/// Coarse pressure classification. `critical` may visibly pause a tool.
enum ResourcePressureLevel: Int, Hashable, Sendable, Comparable {
    case nominal = 0
    case elevated = 1
    case critical = 2

    static func < (lhs: ResourcePressureLevel, rhs: ResourcePressureLevel) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    var displayLabel: String {
        switch self {
        case .nominal: return "Nominal"
        case .elevated: return "Elevated"
        case .critical: return "Critical"
        }
    }
}

/// Inputs about the machine and the storage pipeline.
struct AnalysisResourcePressure: Hashable, Sendable {
    var thermal: ResourcePressureLevel
    var memoryWarningCount: Int
    var isLowPowerMode: Bool
    /// True while a capture or export is using the storage pipeline.
    var captureOrExportInFlight: Bool
    /// Pending originals in internal recovery storage. Reported and retained,
    /// never evicted to make room for analysis (CONTRACTS.md).
    var pendingOriginalCount: Int

    init(thermal: ResourcePressureLevel = .nominal,
         memoryWarningCount: Int = 0,
         isLowPowerMode: Bool = false,
         captureOrExportInFlight: Bool = false,
         pendingOriginalCount: Int = 0) {
        self.thermal = thermal
        self.memoryWarningCount = max(0, memoryWarningCount)
        self.isLowPowerMode = isLowPowerMode
        self.captureOrExportInFlight = captureOrExportInFlight
        self.pendingOriginalCount = max(0, pendingOriginalCount)
    }

    /// The most restrictive pressure that applies.
    var level: ResourcePressureLevel {
        var result = thermal
        if memoryWarningCount > 0 || pendingOriginalCount > 0 || isLowPowerMode {
            result = max(result, .elevated)
        }
        return result
    }

    /// Multiplier applied to the nominal update rates.
    var rateScale: Double {
        var scale = 1.0
        if thermal == .elevated { scale = min(scale, 0.5) }
        if thermal == .critical { scale = min(scale, 0.25) }
        if memoryWarningCount > 0 { scale = min(scale, 0.5) }
        if pendingOriginalCount > 0 { scale = min(scale, 0.5) }
        if isLowPowerMode { scale = min(scale, 0.5) }
        return scale
    }
}

/// A tool that is visibly paused rather than silently missing.
struct PausedPreviewAid: Hashable, Sendable {
    let aid: PreviewAidKind
    let reason: String

    var statusLabel: String { "\(aid.displayLabel) paused — \(reason)" }
}

/// The policy result the camera service and the tools UI both consume.
struct AnalysisDemandDecision: Hashable, Sendable {
    let demand: AnalysisDemand
    let request: AnalysisRequest?
    let rateLimits: AnalysisRateLimits
    let pausedAids: [PausedPreviewAid]
    let pressure: ResourcePressureLevel
    let isPreemptedByCapture: Bool
    /// Pending originals are always retained; this mirrors the input so no caller
    /// can mistake a rate reduction for eviction.
    let pendingOriginalCount: Int
    let retainedPendingOriginals: Bool
    let statusMessage: String

    var isAnalysisActive: Bool { request != nil }
    var wantsVideoOutput: Bool { demand.wantsVideoOutput }
}

/// Pure demand/rate policy.
enum AnalysisDemandPolicy {
    static let nominalRateLimits = AnalysisRateLimits.nominal

    /// Tools paused at critical pressure: the two most expensive display aids.
    static let criticallyPausedAids: [PreviewAidKind] = [.peaking, .loupe]

    static func decide(configuration: PreviewAidConfiguration,
                       lifecycle: PreviewLifecycleState,
                       pressure: AnalysisResourcePressure = AnalysisResourcePressure(),
                       geometry: PreviewGeometrySnapshot?) -> AnalysisDemandDecision {
        let enabled = configuration.enabledAids
        let pressureLevel = pressure.level
        let rates = nominalRateLimits.scaled(by: pressure.rateScale)

        // 1. Lifecycle first: inactive/background/library/unsupported stop analysis
        //    entirely, so no video output is requested and no sample is processed.
        guard lifecycle.allowsAnalysis else {
            return AnalysisDemandDecision(demand: .none,
                                          request: nil,
                                          rateLimits: rates,
                                          pausedAids: [],
                                          pressure: pressureLevel,
                                          isPreemptedByCapture: false,
                                          pendingOriginalCount: pressure.pendingOriginalCount,
                                          retainedPendingOriginals: true,
                                          statusMessage: lifecycle.statusLabel)
        }

        // 2. Capture/export storage takes precedence over optional analysis.
        if pressure.captureOrExportInFlight {
            let paused = enabled.map { PausedPreviewAid(aid: $0, reason: "capture or export storage is using the pipeline") }
            return AnalysisDemandDecision(demand: .none,
                                          request: nil,
                                          rateLimits: rates,
                                          pausedAids: paused,
                                          pressure: pressureLevel,
                                          isPreemptedByCapture: true,
                                          pendingOriginalCount: pressure.pendingOriginalCount,
                                          retainedPendingOriginals: true,
                                          statusMessage: "Preview aids paused while a capture or export is saved; paused aids show no live overlay.")
        }

        // 3. No enabled aid: nothing to demand.
        guard !enabled.isEmpty else {
            return AnalysisDemandDecision(demand: .none,
                                          request: nil,
                                          rateLimits: rates,
                                          pausedAids: [],
                                          pressure: pressureLevel,
                                          isPreemptedByCapture: false,
                                          pendingOriginalCount: pressure.pendingOriginalCount,
                                          retainedPendingOriginals: true,
                                          statusMessage: "All preview aids are off.")
        }

        // 5. Critical pressure visibly pauses the most expensive aids.
        var paused: [PausedPreviewAid] = []
        if pressureLevel == .critical {
            paused = enabled
                .filter { criticallyPausedAids.contains($0) }
                .map { PausedPreviewAid(aid: $0, reason: "critical thermal pressure") }
        }
        let pausedKinds = Set(paused.map(\.aid))
        let running = enabled.filter { !pausedKinds.contains($0) }

        let demand = AnalysisDemand(needsLuminanceSample: !running.isEmpty,
                                    histogramEnabled: running.contains(.histogram),
                                    zebrasEnabled: running.contains(.zebras),
                                    peakingEnabled: running.contains(.peaking),
                                    loupeEnabled: running.contains(.loupe))

        guard !running.isEmpty else {
            return AnalysisDemandDecision(demand: .none,
                                          request: nil,
                                          rateLimits: rates,
                                          pausedAids: paused,
                                          pressure: pressureLevel,
                                          isPreemptedByCapture: false,
                                          pendingOriginalCount: pressure.pendingOriginalCount,
                                          retainedPendingOriginals: true,
                                          statusMessage: statusMessage(pressure: pressureLevel,
                                                                       rates: rates,
                                                                       paused: paused,
                                                                       preempted: false,
                                                                       anythingRunning: false))
        }

        // Geometry gates processing, not native topology. A lens switch/rotation
        // temporarily has no layout; removing and then re-adding the output here
        // reconfigures the live sensor twice for the same enabled tools.
        guard let geometry else {
            return AnalysisDemandDecision(demand: demand, request: nil,
                rateLimits: rates, pausedAids: paused, pressure: pressureLevel,
                isPreemptedByCapture: false, pendingOriginalCount: pressure.pendingOriginalCount,
                retainedPendingOriginals: true,
                statusMessage: "Waiting for the preview geometry before analysis can run.")
        }

        let request = AnalysisRequest(configurationGeneration: geometry.configurationGeneration,
                                      geometry: geometry,
                                      demand: demand,
                                      peakingThreshold: configuration.peakingThreshold.value,
                                      zebraThreshold: configuration.zebraThreshold.normalizedValue,
                                      loupeCenter: configuration.loupeCenter,
                                      loupeMagnification: LoupeRenderer.effectiveMagnification(configuration.loupeMagnification))

        return AnalysisDemandDecision(demand: demand,
                                      request: request,
                                      rateLimits: rates,
                                      pausedAids: paused,
                                      pressure: pressureLevel,
                                      isPreemptedByCapture: false,
                                      pendingOriginalCount: pressure.pendingOriginalCount,
                                      retainedPendingOriginals: true,
                                      statusMessage: statusMessage(pressure: pressureLevel,
                                                                   rates: rates,
                                                                   paused: paused,
                                                                   preempted: false,
                                                                   anythingRunning: true))
    }

    /// Honest status text: it names the reduction or pause and never implies a
    /// stale overlay is live.
    static func statusMessage(pressure: ResourcePressureLevel,
                              rates: AnalysisRateLimits,
                              paused: [PausedPreviewAid],
                              preempted: Bool,
                              anythingRunning: Bool) -> String {
        if preempted {
            return "Preview aids paused while a capture or export is saved; paused aids show no live overlay."
        }
        guard anythingRunning else {
            return "Preview aids paused under \(pressure.displayLabel.lowercased()) pressure; no live overlay is shown for paused aids."
        }
        switch pressure {
        case .nominal:
            return paused.isEmpty
                ? "Preview aids running at nominal rate."
                : "Preview aids running; \(paused.map(\.statusLabel).joined(separator: ", "))."
        case .elevated:
            return "Preview aids running at a reduced rate under elevated pressure "
                + "(histogram ≤\(Int(rates.histogramHz)) Hz, peaking/zebras ≤\(Int(max(rates.peakingHz, rates.zebraHz))) Hz, loupe ≤\(Int(rates.loupeHz)) Hz)."
        case .critical:
            return "Preview aids reduced and partially paused under critical pressure "
                + "(histogram ≤\(Int(rates.histogramHz)) Hz, peaking/zebras ≤\(Int(max(rates.peakingHz, rates.zebraHz))) Hz, loupe ≤\(Int(rates.loupeHz)) Hz); "
                + (paused.isEmpty ? "no aid is paused." : paused.map(\.statusLabel).joined(separator: ", ") + ".")
        }
    }
}
