import Foundation

/// Errors surfaced to the user, with the recovery actions the contract requires.
struct UserFacingFailure: Hashable, Sendable, Identifiable {
    enum Action: String, Hashable, Sendable, CaseIterable {
        case retrySave
        case reconnect
        case exportPending
        case resetToAuto
        case openSettings
        case dismiss
    }

    let id: UUID
    let title: String
    let detail: String
    let actions: [Action]
    /// The originating failure's stable code, when there was one. Callers use it
    /// to react to a specific cause (for example re-evaluating camera permission)
    /// instead of parsing display text.
    let origin: String?

    /// Keep stable diagnostics/routing separate from the everyday camera copy.
    var displayTitle: String {
        switch origin {
        case "permissionDenied": return title
        case "noCamera", "cameraInterrupted": return "Camera unavailable"
        case "unsupportedCapability": return "Camera feature unavailable"
        case "invalidSettings": return "Check camera settings"
        case "captureFailed", "representationUnavailable": return "Photo needs attention"
        case "localStorageFull": return "Storage is full"
        case "folderUnavailable", "providerIOFailed": return title
        case "integrityMismatch", "conflict": return "Photo needs attention"
        case "metadataInvalid", "unsupportedSchema": return title
        case "operationStalled": return "Taking longer than expected"
        case "restorationFailed": return "Reset camera settings"
        case "cancelled": return "Cancelled"
        case "notImplemented": return "Feature unavailable"
        default: return title
        }
    }

    init(title: String, detail: String, actions: [Action],
         origin: String? = nil, id: UUID = UUID()) {
        self.id = id
        self.title = title
        self.detail = detail
        self.actions = actions
        self.origin = origin
    }

    var actionLabels: [(Action, String)] {
        actions.map { action in
            switch action {
            case .retrySave: return (action, "Retry save")
            case .reconnect: return (action, "Reconnect folder")
            case .exportPending: return (action, "Export pending")
            case .resetToAuto: return (action, "Reset to Auto")
            case .openSettings: return (action, "Open Settings")
            case .dismiss: return (action, "Dismiss")
            }
        }
    }

    static func from(_ failure: CaptureFailure) -> UserFacingFailure {
        AppDiagnostics.record(failure, operation: "presentFailure")
        let actions: [Action]
        switch failure.kind {
        case .permissionDenied:
            actions = [.openSettings, .dismiss]
        case .folderUnavailable, .providerIOFailed:
            actions = [.reconnect, .exportPending, .dismiss]
        case .localStorageFull:
            actions = [.retrySave, .exportPending, .dismiss]
        case .restorationFailed:
            actions = [.resetToAuto, .dismiss]
        case .conflict, .integrityMismatch, .metadataInvalid, .unsupportedSchema:
            actions = [.exportPending, .dismiss]
        default:
            actions = [.dismiss]
        }
        return UserFacingFailure(
            title: title(for: failure.kind),
            detail: friendlyMessage(for: failure),
            actions: actions,
            origin: failure.kind.stableCode)
    }

    /// Copy is deliberately independent of associated diagnostic strings. Those
    /// strings may contain native errors, paths, identifiers or implementation
    /// details; none are needed to explain the next useful action.
    private static func title(for kind: FailureKind) -> String {
        switch kind {
        case .permissionDenied(let domain):
            return domain.localizedCaseInsensitiveContains("photo") ? "Photos access needed" : "Camera access needed"
        case .noCamera, .cameraInterrupted: return "Camera unavailable"
        case .unsupportedCapability: return "Feature unavailable"
        case .invalidSettings: return "Check camera settings"
        case .captureFailed, .representationUnavailable, .integrityMismatch, .conflict: return "Photo needs attention"
        case .localStorageFull: return "Storage is full"
        case .folderUnavailable: return "Reconnect your folder"
        case .providerIOFailed: return "Couldn’t access the photo"
        case .metadataInvalid: return "Photo information unavailable"
        case .unsupportedSchema: return "Update TruongCam"
        case .operationStalled: return "Taking longer than expected"
        case .restorationFailed: return "Reset camera settings"
        case .cancelled: return "Cancelled"
        case .notImplemented: return "Feature unavailable"
        }
    }

    /// A typed failure has already been logged by `from`; callers with a raw
    /// Error use the overload below, which records it before returning safe copy.
    private static func friendlyMessage(for failure: CaptureFailure) -> String {
        let text: String
        switch failure.kind {
        case .permissionDenied(let domain):
            text = domain.localizedCaseInsensitiveContains("photo")
                ? "Allow Photos access in Settings to save photos."
                : "Allow camera access in Settings to take photos."
        case .noCamera: text = "The camera isn’t available right now. Please try again."
        case .unsupportedCapability: text = "This camera doesn’t support this feature. Try another lens."
        case .invalidSettings: text = "These settings aren’t available. Choose Auto or adjust them and try again."
        case .cameraInterrupted: text = "The camera was interrupted. Please try again when it’s available."
        case .captureFailed: text = "There was a problem taking this photo. Check the library before trying again."
        case .representationUnavailable: text = "There was a problem with this photo. Check the library before trying again."
        case .localStorageFull: text = "Free up some space on your iPhone, then try again."
        case .folderUnavailable: text = "Reconnect your library folder to save photos."
        case .providerIOFailed: text = "The photo couldn’t be read or saved. Please try again."
        case .integrityMismatch: text = "This photo couldn’t be verified. Keep the original and try again."
        case .conflict: text = "An existing file can’t be replaced. Refresh the library or choose another folder."
        case .metadataInvalid: text = "This photo’s information couldn’t be read. Refresh the library and try again."
        case .unsupportedSchema: text = "This library needs a newer version of TruongCam."
        case .operationStalled: text = "This is taking longer than expected. Please wait, then try again."
        case .restorationFailed: text = "Camera settings couldn’t be restored. Reset to Auto to continue."
        case .cancelled: text = "The operation was cancelled."
        case .notImplemented: text = "This feature isn’t available yet."
        }
        switch failure.retainedSourceStatus {
        case .durableInternalStaging:
            return text + " An unfinished photo is waiting to be saved."
        case .externalStaging:
            return text + " A photo hasn’t finished saving."
        case .none, .inMemoryRepresentationUnstaged:
            return text
        }
    }

    static func message(for error: Error) -> String {
        AppDiagnostics.record(error, operation: "presentError")
        if let failure = error as? CaptureFailure { return friendlyMessage(for: failure) }
        let native = error as NSError
        if native.domain == NSCocoaErrorDomain {
            switch native.code {
            case NSFileNoSuchFileError, NSFileReadNoSuchFileError:
                return "The file couldn’t be found. Refresh the library and try again."
            case NSFileReadNoPermissionError, NSFileWriteNoPermissionError:
                return "The folder can’t be opened. Reconnect it and try again."
            case NSFileWriteOutOfSpaceError:
                return "Free up some space on your iPhone, then try again."
            default: break
            }
        }
        return "Something went wrong. Please try again."
    }
}
