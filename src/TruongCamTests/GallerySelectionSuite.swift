import Foundation
#if canImport(XCTest)
@testable import TruongCam
#endif

enum GallerySelectionSuite {
    static let suite = TCSuite(id: "GallerySelection", title: "Gallery sweep selection", cases: [
        TCCase(id: "GS01", title: "Sweep selects across rows and reversal restores the untouched baseline") { r in
            let ids = (0..<15).map { _ in CaptureID() }
            let baseline: Set<CaptureID> = [ids[0], ids[12]]
            guard let sweep = GalleryRangeSelection(orderedIDs: ids, anchorID: ids[2], baseline: baseline) else {
                r.check("valid anchor", false); return
            }
            r.equal("cross-row range", sweep.selection(through: ids[10]), baseline.union(ids[2...10]))
            r.equal("reverse removes only sweep additions", sweep.selection(through: ids[4]), baseline.union(ids[2...4]))
            r.equal("can cross the anchor", sweep.selection(through: ids[1]), baseline.union(ids[1...2]))
            r.equal("return to anchor", sweep.selection(through: ids[2]), baseline.union([ids[2]]))
            r.equal("unloaded ID cannot expand selection", sweep.selection(through: CaptureID()), nil)
        },
        TCCase(id: "GS02", title: "Starting on a selected item deselects and reversal restores baseline selections") { r in
            let ids = (0..<12).map { _ in CaptureID() }
            let baseline = Set(ids[1...9])
            guard let sweep = GalleryRangeSelection(orderedIDs: ids, anchorID: ids[3], baseline: baseline) else {
                r.check("valid anchor", false); return
            }
            r.check("deselect mode", !sweep.selects)
            r.equal("cross-row removal", sweep.selection(through: ids[8]), baseline.subtracting(ids[3...8]))
            r.equal("reversal restores formerly swept cells", sweep.selection(through: ids[4]), baseline.subtracting(ids[3...4]))
            r.equal("cross anchor removal", sweep.selection(through: ids[0]), baseline.subtracting(ids[0...3]))
            r.equal("baseline is retained for cancellation", sweep.baseline, baseline)
        },
        TCCase(id: "GS03", title: "A sweep cannot start on an ID from another root or mutate its frozen ordering") { r in
            let ids = (0..<9).map { _ in CaptureID() }
            r.check("unknown root ID rejected", GalleryRangeSelection(orderedIDs: ids, anchorID: CaptureID(), baseline: []) == nil)
            r.check("empty grid rejected", GalleryRangeSelection(orderedIDs: [], anchorID: ids[0], baseline: []) == nil)
            let sweep = GalleryRangeSelection(orderedIDs: ids, anchorID: ids[4], baseline: [])
            r.equal("loaded ordering frozen", sweep?.orderedIDs, ids)
            r.equal("reverse range uses frozen order", sweep?.selection(through: ids[1]), Set(ids[1...4]))
        }
    ])
}
