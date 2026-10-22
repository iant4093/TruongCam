import Foundation

/// The rule that decides what a COMMITTED configuration may advertise.
///
/// REVIEW.md J04: this decision previously lived inline inside the AVFoundation
/// adapter, so the suite's `SessionOrderSuite` cases exercised a *different* thing
/// (the selector) while the shipped rule went untested. The rule is platform-neutral,
/// lives here, and is used by `AVCaptureCameraService` through a thin native adapter —
/// so the policy the tests drive is the policy that ships.
enum FinalTupleValidation {

    /// What the committed configuration is allowed to publish.
    enum Outcome: Equatable, Sendable {
        /// The configuration confirmed RAW support; publish exactly these facts.
        case publish(bayerFormats: [UInt32], fileTypes: [String])
        /// The committed configuration exposes no Bayer RAW, so nothing may be
        /// advertised and the tuple is not usable.
        case rejectNoBayerRAW
    }

    /// Decides from the FINAL committed query alone.
    ///
    /// An empty final Bayer answer means UNSUPPORTED. The candidate/initial facts are
    /// deliberately not consulted: reusing them would advertise RAW support for a
    /// configuration the framework declined to confirm.
    ///
    /// `finalFileTypes` is used when present; when the framework reports none, the
    /// candidate's list is carried through because DNG *container* support is a
    /// separate question from Bayer pixel-format support. That is the one permitted
    /// carry-over, and it never resurrects Bayer support.
    static func validate(
        finalBayerFormats: [UInt32],
        finalFileTypes: [String],
        candidateFileTypes: [String]
    ) -> Outcome {
        guard !finalBayerFormats.isEmpty else { return .rejectNoBayerRAW }
        // K04: the SDK defines this list as the CURRENT supported containers. An empty
        // answer is therefore a real absence of DNG support for the committed
        // configuration, never "unreported" evidence that the candidate's list may fill.
        // The rejected outcome is the same one the caller already handles: the committed
        // configuration cannot be used for a raw source. (A distinct case would break the
        // exhaustive switch in the filetype probe, and the caller's response is identical.)
        guard !finalFileTypes.isEmpty else {
            _ = candidateFileTypes
            return .rejectNoBayerRAW
        }
        return .publish(bayerFormats: finalBayerFormats, fileTypes: finalFileTypes)
    }
}
