import Foundation

/// Whether a candidate library root may be treated as an eligible,
/// independently-retained LOCAL destination.
///
/// LIBRARY.md requires permanent originals in a user-selected local On My iPhone
/// folder outside TruongCam's own container, and REVIEW.md S08 found that an
/// unverifiable provider was silently promoted to `storagePolicy=localOnly`
/// because the locality classifier's answer was merely stored in a private string.
///
/// Locality evidence and the product decision to accept an unverifiable provider
/// are therefore separate:
///
///   * `.verifiedLocal` is accepted;
///   * a recognised remote location is rejected outright;
///   * `.unknown` is NOT proof of locality, so it requires an explicit product
///     decision before the root may become writable. Generic "confirm cloud
///     anyway" is never offered.
struct LocalityEligibilityPolicy: Hashable, Sendable {
    /// The locality evidence for the candidate, injectable for tests.
    var verdict: LibraryLocalityVerdict
    /// True only when the user has explicitly accepted this specific destination
    /// through the authorized local-destination flow.
    var userConfirmedUnknownLocality: Bool

    /// Production default: no confirmation has been given.
    static func defaultPolicy(for verdict: LibraryLocalityVerdict) -> LocalityEligibilityPolicy {
        LocalityEligibilityPolicy(verdict: verdict, userConfirmedUnknownLocality: false)
    }

    /// Test seam: synthetic storage whose provider facts are known to be local.
    static func injectedLocal() -> LocalityEligibilityPolicy {
        LocalityEligibilityPolicy(
            verdict: .userConfirmedLocalDestination(evidence: "Injected by the test harness."),
            userConfirmedUnknownLocality: false)
    }

    enum Decision: Hashable, Sendable {
        /// The destination may hold permanent originals.
        case eligible
        /// A recognised remote/cloud location.
        case rejectedRemote(reason: String)
        /// Locality could not be verified and has not been confirmed.
        case blockedUnverified(reason: String)

        var isEligible: Bool { self == .eligible }
    }

    var decision: Decision {
        switch verdict {
        case .userConfirmedLocalDestination:
            return .eligible
        case .localVolume:
            // A local volume alone is not provider locality. Without the user's
            // explicit decision for THIS destination it stays blocked, so a cloud
            // cache on a local volume cannot become a permanent library by default.
            guard userConfirmedUnknownLocality else {
                return .blockedUnverified(
                    reason: "The filesystem reports a local volume, but that does not prove this provider keeps originals locally.")
            }
            return .eligible
        case .rejectedRemote(let reason):
            return .rejectedRemote(reason: reason)
        case .unknown(let reason, _):
            guard userConfirmedUnknownLocality else {
                return .blockedUnverified(reason: reason)
            }
            return .eligible
        }
    }
}

/// Locality classification for a candidate root, expressed as a portable value so
/// selection can be decided without a filesystem and tested with injected facts.
enum LibraryLocalityVerdict: Hashable, Sendable {
    /// The filesystem reports a LOCAL VOLUME with no ubiquity marker.
    ///
    /// REVIEW.md F05: this is filesystem evidence only. It does NOT establish that
    /// the folder's provider keeps originals locally — a cloud provider's
    /// materialised cache also resides on a local volume — so provider retention is
    /// deliberately NOT claimed here and remains a device gate.
    case localVolume(evidence: String)
    /// The user explicitly confirmed this exact folder as their local destination.
    case userConfirmedLocalDestination(evidence: String)
    /// Recognised remote/cloud location.
    case rejectedRemote(reason: String)
    /// The provider exposed no usable locality answer. Not proof of locality.
    case unknown(reason: String, requiresConfirmation: Bool)

    /// True only when locality is either directly evidenced AND confirmed, or the
    /// user confirmed this specific destination. A bare local volume is NOT enough.
    var isVerifiedLocal: Bool {
        if case .userConfirmedLocalDestination = self { return true }
        return false
    }

    /// True when the filesystem at least contradicts a remote provider.
    var isLocalVolumeEvidence: Bool {
        switch self {
        case .localVolume, .userConfirmedLocalDestination: return true
        case .rejectedRemote, .unknown: return false
        }
    }

    var displayReason: String {
        switch self {
        case .localVolume(let evidence): return evidence
        case .userConfirmedLocalDestination(let evidence): return evidence
        case .rejectedRemote(let reason): return reason
        case .unknown(let reason, _): return reason
        }
    }
}
