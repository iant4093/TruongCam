import Foundation
#if canImport(XCTest)
@testable import TruongCam
#endif

enum PhotoResourcePreparationSuite {
    private static func signature(device: String = "wide", format: String = "photo",
                                  raw: UInt32 = 1, width: Int = 8064) -> PhotoResourcePreparationOwner.Signature {
        .init(deviceIdentity: device, formatIdentity: format, rawPixelFormat: raw,
              rawFileType: "com.adobe.raw-image", dimensions: .init(width: width, height: 6048))
    }
    static let suite = TCSuite(id: "PhotoResourcePreparation", title: "Optional native photo resource ownership", cases: [
        TCCase(id: "PR01", title: "Unchanged pending and prepared requests survive reopen without another hint") { r in
            let owner = PhotoResourcePreparationOwner(), request = signature()
            guard let first = owner.reserve(request) else { r.check("initial reservation", false); return }
            r.check("pending same tuple does not cancel and restart allocation", owner.reserve(request) == nil)
            r.check("native completion accepted for actual owner", owner.complete(first, prepared: true))
            r.equal("prepared status belongs to resource hint only", owner.snapshot?.phase, .prepared)
            r.check("same request after stop/reopen preserves prepared resources", owner.reserve(request) == nil)
            r.check("duplicate callback cannot rewrite completed status", !owner.complete(first, prepared: false))
            r.equal("successful status remains", owner.snapshot?.phase, .prepared)
        },
        TCCase(id: "PR02", title: "Outgoing tuple retirement rejects late native callbacks across replacement") { r in
            let owner = PhotoResourcePreparationOwner()
            guard let old = owner.reserve(signature()) else { r.check("old reservation", false); return }
            r.check("actual tuple transition retires old hint", owner.retire())
            r.check("retired completion is ignored", !owner.complete(old, prepared: true))
            guard let current = owner.reserve(signature(device: "ultraWide", raw: 2)) else {
                r.check("new camera reservation", false); return
            }
            r.check("old false completion cannot fail incoming hint", !owner.complete(old, prepared: false))
            r.check("old cleanup cannot retire incoming hint", !owner.retire(ifOwnedBy: old))
            r.equal("incoming hint remains pending", owner.snapshot?.phase, .preparing)
            r.check("new completion is accepted", owner.complete(current, prepared: true))
            r.equal("new camera retained", owner.snapshot?.signature.deviceIdentity, "ultraWide")
        },
        TCCase(id: "PR03", title: "Changed native tuple gets fresh identity and failed hints remain retryable") { r in
            let owner = PhotoResourcePreparationOwner()
            var last: PhotoResourcePreparationOwner.Token?
            for request in [signature(), signature(format: "other"), signature(format: "other", raw: 2),
                            signature(format: "other", raw: 2, width: 4032)] {
                guard let token = owner.reserve(request) else { r.check("changed tuple reserves", false); return }
                if let last { r.check("changed tuple cannot accept old completion", !owner.complete(last, prepared: true)) }
                r.equal("current signature is exact request", owner.snapshot?.signature, request)
                last = token
            }
            guard let last else { return }
            r.check("current native failure recorded", owner.complete(last, prepared: false))
            let request = signature(format: "other", raw: 2, width: 4032)
            guard let retry = owner.reserve(request) else { r.check("failed hint may retry", false); return }
            r.check("retry has a new identity", retry != last)
            r.check("old failure cannot downgrade retry", !owner.complete(last, prepared: false))
            r.check("retry completion accepted", owner.complete(retry, prepared: true))
        }
    ])
}
