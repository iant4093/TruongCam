import Foundation
#if canImport(XCTest)
@testable import TruongCam
#endif

enum OriginalPhotoFocalLengthSuite {
    static let suite = TCSuite(id: "OriginalPhotoFocalLength", title: "Original EXIF focal-length display", cases: [
        TCCase(id: "OF01", title: "Photo settings and compact Info distinguish equivalent and physical millimetres") { r in
            let wide = OriginalPhotoFocalLength(actualMM: 5.96, equivalentMM: 26)
            r.equal("settings show full-frame equivalent", wide.settingsText, "26 mm")
            r.equal("Info names both scales", wide.infoText, "26 mm equivalent (5.96 mm actual)")
            let tele = OriginalPhotoFocalLength(actualMM: 15.66, equivalentMM: 120)
            r.equal("telephoto summary is not a small sensor value", tele.settingsText, "120 mm")
            r.equal("telephoto Info preserves original physical value", tele.infoText, "120 mm equivalent (15.66 mm actual)")
            r.equal("equivalent does not require physical EXIF", OriginalPhotoFocalLength(actualMM: nil, equivalentMM: 77).settingsText, "77 mm")
        },
        TCCase(id: "OF02", title: "Unknown or malformed EXIF equivalence never falls back to physical focal length") { r in
            for invalid: Double? in [nil, 0, -1, .nan, .infinity, -.infinity, 26.5, 65536] {
                let focal = OriginalPhotoFocalLength(actualMM: 5.96, equivalentMM: invalid)
                r.equal("invalid \(String(describing: invalid)) omitted from summary", focal.settingsText, nil)
                r.equal("known physical scale stays explicitly labelled in Info", focal.infoText, "5.96 mm actual")
            }
            r.equal("no made-up settings for absent metadata", OriginalPhotoFocalLength(actualMM: nil, equivalentMM: nil).infoText, nil)
            r.equal("invalid physical metadata omitted", OriginalPhotoFocalLength(actualMM: .infinity, equivalentMM: nil).infoText, nil)
        },
        TCCase(id: "OF03", title: "Original equivalents do not assume an iPhone generation or lens category") { r in
            for mm in [13, 24, 26, 28, 48, 52, 77, 120, 160, 65535] {
                let focal = OriginalPhotoFocalLength(actualMM: 3.5, equivalentMM: Double(mm))
                r.equal("original's \(mm) mm is retained", focal.settingsText, "\(mm) mm")
            }
            r.equal("EXIF lower valid bound retained", OriginalPhotoFocalLength(actualMM: nil, equivalentMM: 1).settingsText, "1 mm")
        }
    ])
}
