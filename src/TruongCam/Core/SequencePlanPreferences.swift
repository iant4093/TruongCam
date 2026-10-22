import Foundation

/// Remembered sequence-plan settings.
///
/// REVIEW.md C11: the tools sheet started three hardcoded default plans with no
/// way to change the source count, EV step, focus endpoints or interval cadence.
/// These are the user's values, persisted across launches; every field is still
/// validated against the plan's own bounds before anything is submitted.
struct SequencePlanPreferences: Hashable, Sendable, Codable {
    var shutterMode: SequenceShutterMode = .single
    var isExposureBracketEnabled: Bool {
        get { shutterMode == .exposureBracket }
        set { if newValue { shutterMode = .exposureBracket } else if shutterMode == .exposureBracket { shutterMode = .single } }
    }
    var exposureBracketCount: Int = 3
    var exposureBracketStepEV: Double = 1
    var focusBracketCount: Int = 5
    var focusBracketStart: Double = 0.2
    var focusBracketEnd: Double = 0.8
    var intervalCount: Int = 10
    var intervalSeconds: Double = 5

    init() {}

    private enum CodingKeys: String, CodingKey {
        case shutterMode, isExposureBracketEnabled, exposureBracketCount, exposureBracketStepEV
        case focusBracketCount, focusBracketStart, focusBracketEnd, intervalCount, intervalSeconds
    }

    init(from decoder: Decoder) throws {
        self.init()
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let legacyBracket = try values.decodeIfPresent(Bool.self, forKey: .isExposureBracketEnabled) ?? false
        shutterMode = (try? values.decodeIfPresent(SequenceShutterMode.self, forKey: .shutterMode)) ?? (legacyBracket ? .exposureBracket : .single)
        exposureBracketCount = try values.decodeIfPresent(Int.self, forKey: .exposureBracketCount) ?? 3
        exposureBracketStepEV = try values.decodeIfPresent(Double.self, forKey: .exposureBracketStepEV) ?? 1
        focusBracketCount = try values.decodeIfPresent(Int.self, forKey: .focusBracketCount) ?? 5
        focusBracketStart = try values.decodeIfPresent(Double.self, forKey: .focusBracketStart) ?? 0.2
        focusBracketEnd = try values.decodeIfPresent(Double.self, forKey: .focusBracketEnd) ?? 0.8
        intervalCount = try values.decodeIfPresent(Int.self, forKey: .intervalCount) ?? 10
        intervalSeconds = try values.decodeIfPresent(Double.self, forKey: .intervalSeconds) ?? 5
    }

    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(shutterMode, forKey: .shutterMode)
        try values.encode(isExposureBracketEnabled, forKey: .isExposureBracketEnabled)
        try values.encode(exposureBracketCount, forKey: .exposureBracketCount)
        try values.encode(exposureBracketStepEV, forKey: .exposureBracketStepEV)
        try values.encode(focusBracketCount, forKey: .focusBracketCount)
        try values.encode(focusBracketStart, forKey: .focusBracketStart)
        try values.encode(focusBracketEnd, forKey: .focusBracketEnd)
        try values.encode(intervalCount, forKey: .intervalCount)
        try values.encode(intervalSeconds, forKey: .intervalSeconds)
    }

    /// Clamps every field into the plan's own product bounds. Bounds live in the
    /// plan types so policy is not duplicated here.
    func validated() -> SequencePlanPreferences {
        var result = self
        if !(2...expandedBracketCountRange).contains(exposureBracketCount) {
            result.exposureBracketCount = 3
        }
        if !ExposureBracketSteps.contains(exposureBracketStepEV) { result.exposureBracketStepEV = 1 }
        if !(2...9).contains(focusBracketCount) { result.focusBracketCount = 5 }
        result.focusBracketStart = min(max(focusBracketStart, 0), 1)
        result.focusBracketEnd = min(max(focusBracketEnd, 0), 1)
        if !(1...999).contains(intervalCount) { result.intervalCount = 10 }
        if !(1...3600).contains(intervalSeconds) { result.intervalSeconds = 5 }
        return result
    }

    /// Product-policy ceiling for a bracket count; the coordinator still rejects a
    /// count the tested path does not support.
    private var expandedBracketCountRange: Int { 5 }
}

/// Exposure-bracket step choices from CONTRACTS.md.
let ExposureBracketSteps: [Double] = [1.0 / 3.0, 2.0 / 3.0, 1, 2]

/// One shutter behavior at a time; sequence modes cannot accidentally multiply each other.
enum SequenceShutterMode: String, Codable, Hashable, Sendable, CaseIterable {
    case single, exposureBracket, focusBracket, interval
    var displayName: String {
        switch self {
        case .single: return "Single photo"
        case .exposureBracket: return "Exposure bracket"
        case .focusBracket: return "Focus bracket"
        case .interval: return "Interval"
        }
    }
}
