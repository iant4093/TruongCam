import Foundation
#if canImport(XCTest)
@testable import TruongCam
#endif

/// Presentation-only checks: typed diagnostics/retention remain separate from
/// concise copy, with no real camera, user library or system-log read required.
enum FriendlyErrorCopySuite {
    static let poison = "POISON_NATIVE /private/library/TC_debug.dng generation=48 checksum=deadbeef"
    static let suite = TCSuite(id: "FriendlyErrorCopy", title: "Plain error copy with full local diagnostics and unchanged recovery", cases: [
        TCCase(id: "EC48M", title: "All typed failures hide native payloads while preserving routing and diagnostics") { r in
            let kinds: [FailureKind] = [.permissionDenied(domain: poison), .noCamera,
                .unsupportedCapability(detail: poison), .invalidSettings(detail: poison), .cameraInterrupted(detail: poison),
                .captureFailed(detail: poison), .representationUnavailable(detail: poison), .localStorageFull(detail: poison),
                .folderUnavailable(detail: poison), .providerIOFailed(detail: poison), .integrityMismatch(detail: poison),
                .conflict(detail: poison), .metadataInvalid(detail: poison), .unsupportedSchema(detail: poison),
                .operationStalled(detail: poison), .restorationFailed(detail: poison), .cancelled(detail: poison),
                .notImplemented(detail: poison)]
            for kind in kinds {
                let failure = CaptureFailure(kind: kind, operation: "nativeOperation_48", nsErrorDomain: "POISON_NATIVE.domain",
                    nsErrorCode: -48, underlyingDescription: poison)
                let presented = UserFacingFailure.from(failure)
                let copy = presented.displayTitle + " " + presented.detail
                r.check("\(kind.stableCode) has short actionable copy", !presented.detail.isEmpty && presented.detail.count < 230)
                r.check("\(kind.stableCode) hides native payload", !copy.contains("POISON_NATIVE") && !copy.contains("/private") && !copy.contains("nativeOperation_48"))
                r.notEqual("\(kind.stableCode) heading is not a stable code", presented.title, kind.stableCode)
                r.equal("\(kind.stableCode) routing code survives", presented.origin, kind.stableCode)
                let diagnostic = AppDiagnostics.description(for: failure, operation: "test.mapping")
                r.check("\(kind.stableCode) keeps full diagnostic", diagnostic.contains(failure.description) && diagnostic.contains(poison) && diagnostic.contains("-48"))
                r.equal("\(kind.stableCode) typed failure stays unchanged", failure.kind, kind)
            }
        },
        TCCase(id: "EC48R", title: "Pending recovery and partial outcomes are truthful without exposing file paths") { r in
            let pending = CaptureFailure(kind: .folderUnavailable(detail: poison), operation: "test.pending",
                retainedSourceStatus: .durableInternalStaging(relativePath: poison))
            let message = UserFacingFailure.from(pending)
            r.equal("folder recovery routes preserved", message.actions, [.reconnect, .exportPending, .dismiss])
            r.check("actual unfinished photo remains visible", message.detail.contains("waiting to be saved"))
            r.check("pending path stays out of UI", !message.detail.contains(poison))
            r.check("full pending path remains in diagnostic", AppDiagnostics.description(for: pending, operation: "test").contains("durableInternal(\(poison))"))
            let memory = UserFacingFailure.from(CaptureFailure(kind: .captureFailed(detail: poison), operation: "test.partial",
                retainedSourceStatus: .inMemoryRepresentationUnstaged))
            r.check("ephemeral memory does not promise a pending file", !memory.detail.contains("waiting to be saved"))
            r.check("partial outcome does not claim no saved photos", !memory.detail.localizedCaseInsensitiveContains("nothing saved") && !memory.detail.localizedCaseInsensitiveContains("no photos saved"))
            let reset = UserFacingFailure.from(CaptureFailure(kind: .restorationFailed(detail: poison), operation: "test.reset"))
            r.equal("reset action preserved", reset.actions, [.resetToAuto, .dismiss])
            r.check("reset instruction remains clear", reset.detail.contains("Reset to Auto"))
            let photos = UserFacingFailure.from(CaptureFailure(kind: .permissionDenied(domain: "Photos"), operation: "test.photos"))
            r.equal("Photos permission is not mislabeled Camera", photos.displayTitle, "Photos access needed")
            r.equal("permission action preserved", photos.actions, [.openSettings, .dismiss])
        },
        TCCase(id: "EC48N", title: "Generic native errors retain their full diagnostics without exposing native descriptions") { r in
            for code in [NSFileReadNoPermissionError, NSFileWriteOutOfSpaceError, NSFileReadNoSuchFileError, 48] {
                let error = NSError(domain: NSCocoaErrorDomain, code: code,
                    userInfo: [NSLocalizedDescriptionKey: poison, NSFilePathErrorKey: "/private/library/poison.dng"])
                let copy = UserFacingFailure.message(for: error)
                r.check("native \(code) has safe copy", !copy.contains("POISON_NATIVE") && !copy.contains("/private") && !copy.isEmpty)
                let full = AppDiagnostics.description(for: error, operation: "test.native")
                r.check("native \(code) remains diagnosable", full.contains(poison) && full.contains(String(code)) && full.contains(NSCocoaErrorDomain))
            }
        },
        TCCase(id: "EC48S", title: "Camera and preview presentation hide raw reasons without changing reset signals") { r in
            let camera = CameraSurfaceState.cameraUnavailable(detail: poison)
            r.check("camera surface hides raw reason", !camera.userDescription.contains("POISON_NATIVE"))
            if case .cameraUnavailable(let reason) = camera { r.equal("camera state keeps raw diagnostic", reason, poison) }
            let unsupported = CameraSurfaceState.unsupportedBayer(detail: poison)
            r.check("RAW unavailability remains clear", unsupported.userDescription.contains("RAW"))
            r.check("RAW surface hides native details", !unsupported.userDescription.contains(poison))
            let reset = PreviewLifecycleState.analysisUnsupported(reason: MediaServicesResetSignal.analysisUnavailableReason)
            r.check("reset status is plain", !reset.statusLabel.contains(MediaServicesResetSignal.analysisUnavailableReason))
            if case .analysisUnsupported(let reason) = reset {
                r.equal("exact reset routing signal survives", reason, MediaServicesResetSignal.analysisUnavailableReason)
            }
            let interruption = PreviewLifecycleState.cameraInterrupted(reason: poison)
            r.check("preview interruption hides native reason", !interruption.statusLabel.contains(poison))
        }
    ])
}
