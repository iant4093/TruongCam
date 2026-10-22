import Foundation

/// Queries each committed native candidate, even when the device's initial
/// format exposes no DNG support. Initial-format facts cannot veto other formats.
enum CaptureFormatDiscovery {
    struct Candidate: Sendable {
        let index: Int
        let dimensions: [PixelDimensions]
    }
    struct Result: Sendable {
        let facts: [CaptureFormatFacts]
        let activationFailures: [String]
        let dngCandidateCount: Int
    }

    /// A verified photo-preset Bayer tuple at the device-wide advertised ceiling
    /// cannot be beaten by an explicit candidate under the existing selector's
    /// ceiling contract. Missing/invalid dimensions or absent RAW demand a scan.
    static func photoReachesAdvertisedCeiling(_ photo: CaptureFormatFacts?, candidates: [Candidate]) -> Bool {
        guard let photo, photo.configurationMode == .photoPreset,
              !photo.bayerPixelFormatsForDNG.isEmpty,
              let ceiling = photo.largestAdvertisedCeiling, !candidates.isEmpty else { return false }
        return candidates.allSatisfy { candidate in
            !candidate.dimensions.isEmpty && candidate.dimensions.allSatisfy {
                $0.isValid && $0.pixelCount <= ceiling.pixelCount
            }
        }
    }

    static func probe(
        candidates: [Candidate],
        activateAndCommit: (Int) throws -> Void,
        dngIsAvailable: () -> Bool,
        bayerFormatsForDNG: () -> [UInt32]
    ) -> Result {
        var facts: [CaptureFormatFacts] = [], failures: [String] = []
        var dngCount = 0
        for candidate in candidates {
            var raw: [UInt32] = []
            do {
                try activateAndCommit(candidate.index)
                if dngIsAvailable() {
                    dngCount += 1
                    raw = bayerFormatsForDNG()
                }
            } catch {
                failures.append("format \(candidate.index): \(error.localizedDescription)")
            }
            facts.append(CaptureFormatFacts(index: candidate.index,
                advertisedMaxPhotoDimensions: candidate.dimensions,
                bayerPixelFormatsForDNG: raw))
        }
        return Result(facts: facts, activationFailures: failures, dngCandidateCount: dngCount)
    }
}
