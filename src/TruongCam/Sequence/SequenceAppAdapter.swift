import Foundation

// The composition root for sequences.
//
// These adapters connect the sequence coordinator's injected ports to the real
// camera and storage services. Everything the coordinator does with native
// capture goes through these ports, so the coordinator never touches a device or
// the file system itself.

/// Executes one ordinary RAW capture for a sequence source, through the same
/// serialized capture pipeline the shutter uses.
struct CaptureSequenceExecutor: SingleCaptureExecuting {
    let capture: CaptureCoordinator

    func execute(_ intent: CaptureIntent) async -> SingleCaptureExecutionResult {
        let result = await capture.capture(intent: intent)
        return Self.executionResult(for: result, intent: intent)
    }

    /// One boundary mapping for ordinary and sequence source truth. Errors and
    /// transaction IDs alone never establish retained byte ownership.
    static func executionResult(for result: CaptureRequestResult, intent: CaptureIntent) -> SingleCaptureExecutionResult {
        let receipt = result.committedReceipts.first {
            $0.captureID == intent.captureID && $0.libraryID == intent.libraryID
                && $0.rootGeneration == intent.rootGeneration && $0.isOriginalAvailable
        }
        let pending = Set(result.pendingTransactionIDs)
        let handle = result.pendingHandles.first {
            $0.isValid && $0.captureID == intent.captureID && $0.metadata.captureID == intent.captureID
                && $0.libraryID == intent.libraryID && $0.metadata.libraryID == intent.libraryID
                && $0.originRootGeneration == intent.rootGeneration && pending.contains($0.transactionID)
        }
        var failure = result.failures.first
        if failure == nil {
            switch result.acquisition {
            case .failed(let nativeFailure): failure = nativeFailure
            case .partial(_, let detail):
                failure = CaptureFailure(kind: .captureFailed(detail: detail), operation: "sequence.capture.acquisition")
            case .success: break
            }
        }
        if let diagnostic = failure {
            // A terminal or historical failure cannot prove current retention.
            // Only the accepted pending handle below may restore an internal
            // path claim; verified external ownership lives in the receipt.
            failure = CaptureFailure(kind: diagnostic.kind, operation: diagnostic.operation,
                retainedSourceStatus: .none, nsErrorDomain: diagnostic.nsErrorDomain,
                nsErrorCode: diagnostic.nsErrorCode, underlyingDescription: diagnostic.underlyingDescription)
        }
        let state: SourcePersistenceState
        if let receipt {
            state = .committed(receipt)
        } else if let handle {
            let pendingFailure = CaptureFailure(
                kind: failure?.kind ?? .providerIOFailed(detail: "The original is durably staged and needs a save retry."),
                operation: failure?.operation ?? "sequence.capture.persist",
                retainedSourceStatus: .durableInternalStaging(relativePath: handle.pendingRelativePath),
                nsErrorDomain: failure?.nsErrorDomain, nsErrorCode: failure?.nsErrorCode,
                underlyingDescription: failure?.underlyingDescription)
            failure = pendingFailure
            state = .pendingRetry(failure: pendingFailure, retained: .durableInternalStaging(relativePath: handle.pendingRelativePath))
        } else {
            let missing = failure ?? CaptureFailure(kind: .captureFailed(detail: "No verified original or durable staging handle was retained."), operation: "sequence.capture.persist")
            failure = missing
            state = .failed(failure: missing)
        }
        return SingleCaptureExecutionResult(
            captureID: intent.captureID,
            terminalStatus: Self.terminalStatus(for: result.acquisition),
            persistence: state,
            stagedHandle: handle,
            receipt: receipt,
            failure: failure)
    }

    private static func terminalStatus(for outcome: NativeRequestOutcome) -> AcquisitionTerminalStatus {
        switch outcome {
        case .success:
            return .success
        case .partial(_, let description):
            return .partialWithRetainedSource(errorDescription: description)
        case .failed(let failure):
            return .failed(errorDescription: failure.kind.userDescription)
        }
    }
}

/// Persists a representation that the native layer already delivered for a known
/// intent. Used by the native bracket path, where the bytes arrive through
/// callbacks rather than through `beginCapture` per source.
struct LibrarySequencePersister: DeliveredSourcePersisting {
    let capture: CaptureCoordinator

    func persist(_ representation: DeliveredRAWRepresentation,
                 intent: CaptureIntent) async -> SingleCaptureExecutionResult {
        await capture.persistDelivered(representation: representation, intent: intent)
    }
}

/// Reports the active format's limits and priority support to the coordinator.
struct CameraSequenceCapabilityProvider: SequenceCapabilityProviding {
    let camera: any CameraViewModelCapabilitySource

    func capabilityContext() async -> SequenceCapabilityContext {
        let snapshot = await camera.capabilitySnapshotForSequences()
        guard let kind = snapshot.selectedCameraKind,
              let physical = snapshot.camera(kind),
              !physical.formats.isEmpty else {
            return .undiscovered
        }
        let index = physical.selectedFormatIndex ?? physical.formats.startIndex
        guard physical.formats.indices.contains(index) else { return .undiscovered }
        let format = physical.formats[index]
        return SequenceCapabilityContext(
            exposureLimits: format.exposureLimits,
            focusLimits: format.focusLimits,
            supportsCustomExposureMode: format.supportsCustomExposureMode.value ?? false,
            supportedExposureModes: format.supportedPriorityCombinations)
    }
}

/// The camera facts a sequence needs. Implemented by `CameraViewModel`.
@preconcurrency
protocol CameraViewModelCapabilitySource: Sendable {
    func capabilitySnapshotForSequences() async -> CameraCapabilitySnapshot
}

/// Reads and freezes the camera's current control state for a sequence, applies
/// the frozen baseline, and restores the user's settings afterwards.
///
/// A restoration failure is reported as a failure so the coordinator can surface
/// it and block the shutter; it is never reported as restored.
struct CameraSequenceSettingsControl: SequenceSettingsControlling {
    let camera: any CameraSequenceSettingsSurface

    func snapshotCurrentSettings() async -> SequenceSettingsSnapshot? {
        await camera.sequenceSettingsSnapshot()
    }

    func currentExposureBaseline() async -> ExposureBaseline? {
        await camera.sequenceExposureBaseline()
    }

    func prepareFocusLockForBaseline(_ prior: SequenceSettingsSnapshot) async -> Result<Bool, CaptureFailure> {
        guard prior.focus.mode != .manual else { return .success(false) }
        guard let reading = await camera.currentAppliedSnapshot(), reading.generation == prior.configurationGeneration,
              reading.requestRevision == prior.revision, let position = reading.focusPosition,
              Date().timeIntervalSince(reading.capturedAtUTC) >= -0.01,
              Date().timeIntervalSince(reading.capturedAtUTC) <= 0.5,
              let locked = SequenceBaselineFocusPreparation.lockedSettings(prior, observedPosition: position) else {
            return .failure(CaptureFailure(kind: .operationStalled(detail: "A fresh current lens position is required before the bracket can lock focus."), operation: "sequence.prepareBaselineFocus"))
        }
        switch await camera.applySequenceSettings(locked) {
        case .success: return .success(true)
        case .failure(let failure): return .failure(failure)
        }
    }

    func apply(_ settings: SequenceSettingsSnapshot) async -> Result<Void, CaptureFailure> {
        await camera.applySequenceSettings(settings)
    }

    func restore(_ settings: SequenceSettingsSnapshot) async -> Result<Void, CaptureFailure> {
        await camera.restoreSequenceSettings(settings)
    }

    func resetToAuto() async -> Result<Void, CaptureFailure> {
        await camera.resetSequenceSettingsToAuto()
    }
}

@preconcurrency
protocol CameraSequenceSettingsSurface: Sendable {
    func sequenceSettingsSnapshot() async -> SequenceSettingsSnapshot?
    func sequenceExposureBaseline() async -> ExposureBaseline?
    func applySequenceSettings(_ settings: SequenceSettingsSnapshot) async -> Result<Void, CaptureFailure>
    func restoreSequenceSettings(_ settings: SequenceSettingsSnapshot) async -> Result<Void, CaptureFailure>
    func resetSequenceSettingsToAuto() async -> Result<Void, CaptureFailure>
    func currentAppliedSnapshot() async -> AppliedControlSnapshot?
}

/// Native exposure brackets are used only when the device has actually reported
/// a measured bracket count that covers the plan. Until Gate A records one, the
/// clearly labelled slower serial source bracket is used instead.
enum BracketPathResolver {
    static func path(for plan: ExposureBracketPlan,
                     capability: CameraCapabilitySnapshot,
                     admission: SequenceAdmissionPolicy) -> ExposureBracketPath {
        guard let kind = capability.selectedCameraKind,
              let physical = capability.camera(kind) else { return .serial }
        switch physical.nativeBracketCountDiscovery {
        case .available(let count) where count >= plan.count:
            // The discovered count is real device data, not an assumption.
            switch admission.testedNativeBracketCounts {
            case .available(let counts) where counts.contains(plan.count):
                return .native
            case .available, .unavailable, .unknown:
                return .serial
            }
        case .available, .unavailable, .unknown:
            return .serial
        }
    }
}


/// Samples the camera's live control readback for baseline settlement.
///
/// The coordinator requires five consecutive stable readbacks; this only reports
/// what the device actually produced. Nothing here invents a value, and a
/// missing field stays `nil` so the settler treats it as unsupported rather than
/// stable.
struct CameraBaselineSampler: BaselineSampling {
    let camera: any CameraSequenceSettingsSurface
    let clock: any MonotonicClock

    func readback() async -> BaselineReadback? {
        guard let snapshot = await camera.currentAppliedSnapshot() else { return nil }
        // REVIEW.md G03: provenance follows the reading's OWN settlement. Calling a
        // moving cached snapshot `settledDeviceReadback` claimed convergence the
        // device never reported. The adjusting flags travel with the reading too, so
        // "not supplied" stays distinct from "not adjusting".
        return BaselineReadback(
            monotonicSeconds: clock.now(),
            measurementIdentity: BaselineReadback.MeasurementIdentity(
                generationValue: snapshot.generation.value,
                requestRevision: snapshot.requestRevision,
                sourceTimestamp: snapshot.capturedAtUTC),
            isExposureAdjusting: snapshot.isExposureAdjusting,
            isFocusAdjusting: snapshot.isFocusAdjusting,
            isWhiteBalanceAdjusting: snapshot.isWhiteBalanceAdjusting,
            durationSeconds: snapshot.observedDurationSeconds,
            iso: snapshot.observedISO,
            focusPosition: snapshot.focusPosition,
            whiteBalanceGains: snapshot.whiteBalanceGains,
            provenance: BaselineReadback.provenance(for: snapshot.settlement))
    }
}

/// Native brackets are refused until a device test records a legal count and
/// proves callback correspondence, so this reports an explicit unsupported
/// failure. The coordinator then uses the clearly labelled serial source
/// bracket, which preserves exact sources.
struct UnavailableNativeBracketSubmitter: BracketSubmitting {
    func submit(_ request: BracketSubmissionRequest) async -> Result<BracketSubmission, CaptureFailure> {
        .failure(CaptureFailure(
            kind: .unsupportedCapability(
                detail: "No native Bayer bracket path has been measured on this device, so the serial source bracket is used instead."),
            operation: "submitNativeBracket"))
    }
}
