import Foundation

/// Values read from this original's EXIF, not a camera-kind/model lookup or a
/// sidecar UI hint. EXIF's 35 mm field is an unsigned short; zero means unknown.
struct OriginalPhotoFocalLength: Hashable, Sendable {
    let actualMM: Double?
    let equivalentMM: Double?

    init(actualMM: Double?, equivalentMM: Double?) {
        self.actualMM = actualMM.flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
        self.equivalentMM = equivalentMM.flatMap {
            $0.isFinite && $0 >= 1 && $0 <= Double(UInt16.max) && $0.rounded() == $0 ? $0 : nil
        }
    }

    /// The compact strip always uses full-frame-equivalent millimetres. Missing
    /// equivalence must never substitute a physical small-sensor focal length.
    var settingsText: String? { equivalentMM.map { "\(Self.number($0)) mm" } }

    /// Keep the curated Info row compact while making both scales explicit.
    var infoText: String? {
        if let equivalentMM {
            let equivalent = "\(Self.number(equivalentMM)) mm equivalent"
            return equivalent + (actualMM.map { " (\(Self.number($0)) mm actual)" } ?? "")
        }
        return actualMM.map { "\(Self.number($0)) mm actual" }
    }

    private static func number(_ value: Double) -> String { String(format: "%.6g", value) }
}
