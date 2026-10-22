import Foundation

/// Shared native mutation plan for preparation and start's defensive fallback.
/// Calling a pipeline setter with its existing value can still reconfigure the
/// ISP. Only actual differences are applied, inside the caller's owned native
/// configuration; this plan never establishes capture capability/readiness.
enum CapturePipelinePreparation {
    enum PreviewMirroringChange: Equatable, Sendable {
        case enableAutomatic, disableAutomatic, setMirrored(Bool)
    }
    /// Let the native preview follow input changes. Explicit mirror setters can
    /// synchronously reconfigure the display and are unnecessary in this mode.
    static func automaticPreviewMirroringChanges(supported: Bool, automatic: Bool) -> [PreviewMirroringChange] {
        supported && !automatic ? [.enableAutomatic] : []
    }
    static func previewMirroringChanges(supported: Bool, automatic: Bool, mirrored: Bool,
                                        desired: Bool) -> [PreviewMirroringChange] {
        guard supported else { return [] }
        return (automatic ? [.disableAutomatic] : []) + (mirrored != desired ? [.setMirrored(desired)] : [])
    }
    /// Preview-backed setters can synchronously invalidate a UIKit layout via
    /// KVO. Keep the mutation executor on MainActor; output connection policy
    /// remains separate on the native queue.
    @MainActor @discardableResult
    static func applyPreviewMirroring(_ changes: [PreviewMirroringChange], isCurrent: () -> Bool,
                                      set: (PreviewMirroringChange) -> Void) -> Bool {
        for change in changes {
            guard isCurrent() else { return false }
            set(change)
        }
        return isCurrent()
    }
    struct OutputState: Equatable, Sendable {
        var photoDeferred = false
        var videoDeferred = false
        var speedPrioritization = true
        var responsiveSupported = false
        var responsiveEnabled = false
        var zeroLagSupported = false
        var zeroLagEnabled = false
        var deferredDeliverySupported = false
        var deferredDeliveryEnabled = false
        var discardsLateFrames = true
    }
    enum OutputChange: Equatable, Sendable {
        case disablePhotoDeferred, disableVideoDeferred, prioritizeSpeed
        case disableResponsive, disableZeroLag, disableDeferredDelivery, discardLateFrames
    }
    static func outputChanges(_ state: OutputState) -> [OutputChange] {
        var result: [OutputChange] = []
        if state.photoDeferred { result.append(.disablePhotoDeferred) }
        if state.videoDeferred { result.append(.disableVideoDeferred) }
        if !state.speedPrioritization { result.append(.prioritizeSpeed) }
        // Responsive capture depends on ZSL; disable it while still supported.
        if state.responsiveSupported && state.responsiveEnabled { result.append(.disableResponsive) }
        if state.zeroLagSupported && state.zeroLagEnabled { result.append(.disableZeroLag) }
        if state.deferredDeliverySupported && state.deferredDeliveryEnabled { result.append(.disableDeferredDelivery) }
        if !state.discardsLateFrames { result.append(.discardLateFrames) }
        return result
    }
    @discardableResult
    static func applyOutputChanges(_ changes: [OutputChange], isCurrent: () -> Bool,
                                   set: (OutputChange) -> Void) -> Bool {
        for change in changes {
            guard isCurrent() else { return false }
            set(change)
        }
        return isCurrent()
    }

    struct AnalysisConnectionState: Equatable, Sendable {
        var mirrorsSupported = false
        var automaticMirroring = false
        var mirrored = false
        var zeroRotationSupported = false
        var rotationDegrees: Double = 0
    }
    enum AnalysisConnectionChange: Equatable, Sendable {
        case disableAutomaticMirroring, disableMirroring, zeroRotation
    }
    static func analysisConnectionChanges(_ state: AnalysisConnectionState) -> [AnalysisConnectionChange] {
        var result: [AnalysisConnectionChange] = []
        if state.mirrorsSupported {
            if state.automaticMirroring { result.append(.disableAutomaticMirroring) }
            if state.mirrored { result.append(.disableMirroring) }
        }
        if state.zeroRotationSupported && state.rotationDegrees != 0 { result.append(.zeroRotation) }
        return result
    }
    @discardableResult
    static func applyAnalysisConnectionChanges(_ changes: [AnalysisConnectionChange], isCurrent: () -> Bool,
                                              set: (AnalysisConnectionChange) -> Void) -> Bool {
        for change in changes {
            guard isCurrent() else { return false }
            set(change)
        }
        return isCurrent()
    }
}
