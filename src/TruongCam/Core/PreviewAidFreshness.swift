import Foundation

/// An overlay is a delayed aid, never the native preview frame itself. Refuse
/// old results, including work delayed by a cold decoder/backend or busy UI.
enum PreviewAidFreshness {
    static let maximumAgeSeconds = 0.12
    /// Preserve a continuous display across ordinary scheduling jitter, then fade
    /// a stalled aid away. Age remains the original source time, never a repaint.
    static func displayOpacity(capturedAt: Date, now: Date) -> Double {
        let age = now.timeIntervalSince(capturedAt)
        guard age >= -0.01, age < 0.35 else { return 0 }
        if age <= 0.20 { return 1 }
        return max(0, (0.35 - age) / 0.15)
    }
    static func isFresh(capturedAt: Date, now: Date) -> Bool {
        let age = now.timeIntervalSince(capturedAt)
        return age >= -0.01 && age <= maximumAgeSeconds
    }
}
