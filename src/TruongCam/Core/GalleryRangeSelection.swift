import Foundation

/// One Photos-style sweep, frozen to the loaded ordering and selection at touch
/// down. Reversing restores the original selection outside the current range.
struct GalleryRangeSelection: Sendable {
    let orderedIDs: [CaptureID]
    let baseline: Set<CaptureID>
    let anchor: Int
    let selects: Bool

    init?(orderedIDs: [CaptureID], anchorID: CaptureID, baseline: Set<CaptureID>) {
        guard let anchor = orderedIDs.firstIndex(of: anchorID) else { return nil }
        self.orderedIDs = orderedIDs
        self.baseline = baseline
        self.anchor = anchor
        selects = !baseline.contains(anchorID)
    }

    func selection(through id: CaptureID) -> Set<CaptureID>? {
        guard let end = orderedIDs.firstIndex(of: id) else { return nil }
        let range = Set(orderedIDs[min(anchor, end)...max(anchor, end)])
        return selects ? baseline.union(range) : baseline.subtracting(range)
    }
}
