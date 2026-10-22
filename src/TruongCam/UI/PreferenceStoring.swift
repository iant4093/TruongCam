import Foundation

// The stored snapshot uses primitive fields so it stays a plain Codable value
// independent of the UI enum conformances.

/// Persistence for remembered preferences.
///
/// Composition aids, the preferred physical lens and capture format are remembered. Manual
/// exposure/focus/white-balance choices are deliberately not persisted: a fresh
/// process must start Auto.
protocol PreferenceStoring: Sendable {
    func loadCompositionPreferences() -> CompositionPreferences?
    func storeCompositionPreferences(_ preferences: CompositionPreferences)
    func loadSequencePreferences() -> SequencePlanPreferences?
    func storeSequencePreferences(_ preferences: SequencePlanPreferences)
    func loadPreferredCaptureFormat() -> CaptureFileFormat
    func storePreferredCaptureFormat(_ format: CaptureFileFormat)
    func loadCaptureSpeed() -> CaptureSpeed
    func storeCaptureSpeed(_ speed: CaptureSpeed)
}

extension PreferenceStoring {
    func loadCaptureSpeed() -> CaptureSpeed { .single }
    func storeCaptureSpeed(_ speed: CaptureSpeed) {}
    func loadPreferredCaptureFormat() -> CaptureFileFormat { .bayerDNG }
    func storePreferredCaptureFormat(_ format: CaptureFileFormat) {}
}

struct UserDefaultsPreferenceStore: PreferenceStoring {
    private static let key = "com.iantruong.TruongCam.compositionPreferences.v1"

    init() {}

    private var defaults: UserDefaults { .standard }

    private static let captureSpeedKey = "com.iantruong.TruongCam.captureSpeed.v1"
    func loadCaptureSpeed() -> CaptureSpeed {
        defaults.string(forKey: Self.captureSpeedKey).flatMap(CaptureSpeed.init(rawValue:)) ?? .single
    }
    func storeCaptureSpeed(_ speed: CaptureSpeed) { defaults.set(speed.rawValue, forKey: Self.captureSpeedKey) }

    func loadCompositionPreferences() -> CompositionPreferences? {
        guard let data = defaults.data(forKey: Self.key) else { return nil }
        return try? JSONDecoder().decode(StoredCompositionPreferences.self, from: data).preferences
    }

    func storeCompositionPreferences(_ preferences: CompositionPreferences) {
        guard let data = try? JSONEncoder().encode(StoredCompositionPreferences(preferences)) else { return }
        defaults.set(data, forKey: Self.key)
    }

    private static let captureFormatKey = "com.iantruong.TruongCam.captureFormat.v1"

    func loadPreferredCaptureFormat() -> CaptureFileFormat {
        defaults.string(forKey: Self.captureFormatKey) == CaptureFileFormat.jpeg.rawValue ? .jpeg : .bayerDNG
    }

    func storePreferredCaptureFormat(_ format: CaptureFileFormat) {
        // The legacy front-only HEIF fallback belongs to the RAW preference.
        // It never becomes a silent substitute for an explicit JPEG request.
        defaults.set((format == .jpeg ? CaptureFileFormat.jpeg : .bayerDNG).rawValue, forKey: Self.captureFormatKey)
    }

    private static let sequenceKey = "com.iantruong.TruongCam.sequencePreferences.v1"

    func loadSequencePreferences() -> SequencePlanPreferences? {
        guard let data = defaults.data(forKey: Self.sequenceKey) else { return nil }
        return (try? JSONDecoder().decode(SequencePlanPreferences.self, from: data))?.validated()
    }

    func storeSequencePreferences(_ preferences: SequencePlanPreferences) {
        guard let data = try? JSONEncoder().encode(preferences.validated()) else { return }
        defaults.set(data, forKey: Self.sequenceKey)
    }
}

/// A nonisolated snapshot type so `PreferenceStoring` stays `Sendable` without
/// making the UI struct itself cross actor boundaries.
private struct StoredCompositionPreferences: Codable {
    var gridModeRaw: String
    var histogramEnabled: Bool
    var levelEnabled: Bool
    var peakingEnabled: Bool
    var peakingThresholdRaw: String
    var zebrasEnabled: Bool
    var zebraThresholdRaw: String
    var loupeEnabled: Bool
    var loupeMagnification: Double
    var preferredLensRaw: String
    var timerSeconds: Int

    init(_ preferences: CompositionPreferences) {
        gridModeRaw = preferences.gridMode.rawValue
        histogramEnabled = preferences.histogramEnabled
        levelEnabled = preferences.levelEnabled
        peakingEnabled = preferences.peakingEnabled
        peakingThresholdRaw = preferences.peakingThreshold.rawValue
        zebrasEnabled = preferences.zebrasEnabled
        zebraThresholdRaw = preferences.zebraThreshold.rawValue
        loupeEnabled = preferences.loupeEnabled
        loupeMagnification = preferences.loupeMagnification
        preferredLensRaw = preferences.preferredLens.rawValue
        timerSeconds = preferences.timerSeconds
    }

    var preferences: CompositionPreferences {
        var result = CompositionPreferences()
        // An unrecognized stored value falls back to the documented default
        // instead of failing the whole preference load.
        result.gridMode = GridMode(rawValue: gridModeRaw) ?? .thirds
        result.histogramEnabled = histogramEnabled
        result.levelEnabled = levelEnabled
        result.peakingEnabled = peakingEnabled
        result.peakingThreshold = PeakingThreshold(rawValue: peakingThresholdRaw) ?? .normal
        result.zebrasEnabled = zebrasEnabled
        result.zebraThreshold = ZebraThreshold(rawValue: zebraThresholdRaw) ?? .default
        result.loupeEnabled = loupeEnabled
        result.loupeMagnification = loupeMagnification
        result.preferredLens = PhysicalCameraKind(rawValue: preferredLensRaw) ?? .wide
        result.timerSeconds = timerSeconds
        return result
    }
}
