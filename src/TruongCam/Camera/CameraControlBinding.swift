import Foundation
@preconcurrency import AVFoundation

/// Local alias: `AVCaptureDevice.WhiteBalanceGains` is the device type, and this
/// app's own value model is `AppWhiteBalanceGains` (declared in Core).
typealias AppWhiteBalanceGains = WhiteBalanceGains

// ARCHITECTURE.md "Exposure model", "Focus, white balance and lens selection".
//
// Every native setter in this file validates its arguments first. CONTRACTS.md is
// explicit that an invalid value must be rejected *before* the Objective-C call,
// because `setExposureModeCustom`, `setFocusModeLocked` and
// `setWhiteBalanceModeLocked` raise `NSInvalidArgumentException` /
// `NSRangeException` for out-of-range input instead of returning an error.

/// A validated instruction for one native control application.
struct NativeControlInstruction: Hashable, Sendable {
    let exposure: ExposureChoice
    let biasEV: Double
    let focus: FocusIntent
    let whiteBalance: WhiteBalanceIntent
}

/// The outcome of applying an instruction.
enum ControlApplicationResult: Sendable {
    case applied(AppliedControlSnapshot)
    case rejected([ExposureValidationFailure], focus: FocusValidationFailure?, whiteBalance: WhiteBalanceValidationFailure?)
    case failed(CaptureFailure)
}

/// Binds the semantic control model to the native device.
///
/// Runs only on the serial session queue; the enclosing actor guarantees that.
struct CameraControlBinding: Sendable {
    static func observedTemperatureAndTint(gains: AVCaptureDevice.WhiteBalanceGains,
                                          device: AVCaptureDevice) -> WhiteBalanceTemperatureAndTint? {
        let maximum = device.maxWhiteBalanceGain
        guard maximum.isFinite, maximum >= 1,
              [gains.redGain, gains.greenGain, gains.blueGain].allSatisfy({ $0.isFinite && $0 >= 1 && $0 <= maximum }) else { return nil }
        let value = device.temperatureAndTintValues(for: gains)
        guard value.temperature.isFinite, value.temperature > 0, value.tint.isFinite else { return nil }
        return WhiteBalanceTemperatureAndTint(temperature: Double(value.temperature), tint: Double(value.tint))
    }
    /// Fresh native modes used only for this operation's no-mutation proof.
    /// This is never retained or substituted for a later live observation.
    struct AutoState {
        let exposureMode: AVCaptureDevice.ExposureMode
        let focusMode: AVCaptureDevice.FocusMode
        let whiteBalanceMode: AVCaptureDevice.WhiteBalanceMode
        let biasEV: Float
        let focusPoint: CGPoint?
    }

    static func controlsAlreadyMatchAuto(
        _ instruction: NativeControlInstruction,
        read: () -> AutoState
    ) -> Bool {
        guard instruction.exposure.mode == .auto,
              instruction.focus.mode == .continuousAuto,
              instruction.whiteBalance.mode == .auto else { return false }
        let state = read()
        return state.exposureMode == .continuousAutoExposure
            && state.focusMode == .continuousAutoFocus
            && state.whiteBalanceMode == .continuousAutoWhiteBalance
            && state.biasEV == Float(instruction.biasEV)
            && instruction.focus.pointOfInterest.map {
                state.focusPoint == CGPoint(x: $0.x, y: $0.y)
            } != false
    }

    /// Converts a `Double` to the `Float` a native API requires, or nil when the value
    /// is not finite or not representable as a `Float`.
    ///
    /// REVIEW.md F03: a finite `Double` can still overflow `Float`, and the native
    /// converter must never receive a non-finite component.
    static func representableFloat(_ value: Double) -> Float? {
        guard value.isFinite else { return nil }
        let converted = Float(value)
        guard converted.isFinite else { return nil }
        return converted
    }

    /// Applies the whole exposure/focus/WB selection as one revision.
    static func apply(
        _ instruction: NativeControlInstruction,
        to device: AVCaptureDevice,
        generation: ConfigurationGeneration,
        limits: ExposureLimits,
        focusLimits: FocusLimits,
        whiteBalanceLimits: WhiteBalanceLimits,
        configuredPhotoDimensions: PixelDimensions?,
        completions: SetterCompletionGroup = SetterCompletionGroup()
    ) -> ControlApplicationResult {
        // Pure validation first: nothing below this point may run for an
        // invalid request.
        #if DEBUG
        let validationBegan = ProcessInfo.processInfo.systemUptime
        #endif
        // Auto validation never uses the custom-exposure support answer. Avoid
        // entering that native query on the cold ordinary Auto shutter path.
        let supportsCustom = instruction.exposure.mode != .auto && device.isExposureModeSupported(.custom)
        let exposureFailures = ExposureValidator.validate(
            choice: instruction.exposure,
            limits: limits,
            supportsCustomExposureMode: supportsCustom,
            supportsCombination: { choice in
                Self.supportsCombination(choice, device: device, limits: limits)
            })

        let biasFailure = ExposureValidator.validateBias(instruction.biasEV, limits: limits)

        var focusFailure: FocusValidationFailure?
        switch instruction.focus.mode {
        case .manual:
            if let position = instruction.focus.position {
                focusFailure = FocusValidator.validateManualPosition(position, limits: focusLimits)
            } else {
                focusFailure = .positionNonFinite(.nan)
            }
        case .continuousAuto, .lockedAuto:
            if let point = instruction.focus.pointOfInterest {
                focusFailure = FocusValidator.validatePointOfInterest((point.x, point.y), limits: focusLimits)
            }
        }

        var whiteBalanceFailure: WhiteBalanceValidationFailure?
        switch instruction.whiteBalance.mode {
        case .manual:
            guard let temperatureAndTint = instruction.whiteBalance.temperatureAndTint else {
                whiteBalanceFailure = .temperatureNonFinite(.nan)
                break
            }
            if !temperatureAndTint.temperature.isFinite {
                whiteBalanceFailure = .temperatureNonFinite(temperatureAndTint.temperature)
            } else if temperatureAndTint.temperature <= 0 {
                whiteBalanceFailure = .temperatureNonPositive(temperatureAndTint.temperature)
            } else if !temperatureAndTint.tint.isFinite {
                whiteBalanceFailure = .tintNonFinite(temperatureAndTint.tint)
            } else if case .unavailable = whiteBalanceLimits {
                whiteBalanceFailure = .conversionUnavailable
            }
        case .auto:
            break
        }

        let allExposureFailures = biasFailure.map { exposureFailures + [$0] } ?? exposureFailures
        #if DEBUG
        print("TruongCam timing control-validation=\(Int((ProcessInfo.processInfo.systemUptime - validationBegan) * 1000))ms")
        #endif
        if !allExposureFailures.isEmpty || focusFailure != nil || whiteBalanceFailure != nil {
            return .rejected(allExposureFailures, focus: focusFailure, whiteBalance: whiteBalanceFailure)
        }

        // This path already takes a complete native reading below. If every
        // continuous Auto mode/bias/point is unchanged, that is a live observation
        // of this operation, not merely a setter ACK. Any mutation retains the
        // ordinary post-setter observation requirement.
        #if DEBUG
        let proofBegan = ProcessInfo.processInfo.systemUptime
        #endif
        let unchangedAuto = controlsAlreadyMatchAuto(instruction) {
            AutoState(exposureMode: device.exposureMode,
                      focusMode: device.focusMode,
                      whiteBalanceMode: device.whiteBalanceMode,
                      biasEV: device.exposureTargetBias,
                      focusPoint: instruction.focus.pointOfInterest == nil ? nil : device.focusPointOfInterest)
        }
        #if DEBUG
        print("TruongCam timing control-auto-proof=\(Int((ProcessInfo.processInfo.systemUptime - proofBegan) * 1000))ms matched=\(unchangedAuto)")
        #endif

        // A read of already-matching Auto controls does not require exclusive
        // configuration access. Cold lock acquisition can block behind the ISP.
        // Every path that may change a native setting still takes the lock.
        #if DEBUG
        let lockBegan = ProcessInfo.processInfo.systemUptime
        #endif
        if !unchangedAuto {
            do { try device.lockForConfiguration() }
            catch { return .failed(AVFoundationFailureMapper.failure(error, operation: "lockForConfiguration")) }
        }
        defer { if !unchangedAuto { device.unlockForConfiguration() } }
        #if DEBUG
        print("TruongCam timing control-lock=\(Int((ProcessInfo.processInfo.systemUptime - lockBegan) * 1000))ms required=\(!unchangedAuto)")
        #endif


        var resolvedGains: AppWhiteBalanceGains?
        #if DEBUG
        let nativeApplyBegan = ProcessInfo.processInfo.systemUptime
        #endif
        // Already-running continuous modes prove their own current availability.
        // Do not re-query support and re-read them after proving no setter is
        // needed. Changed/manual/priority controls retain the locked native path.
        if !unchangedAuto {
            // White balance gain resolution is delegated to the device converter so
            // no colour model is invented in app code.
            if instruction.whiteBalance.mode == .manual,
               let temperatureAndTint = instruction.whiteBalance.temperatureAndTint {
                guard device.isLockingWhiteBalanceWithCustomDeviceGainsSupported else {
                    return .rejected([], focus: nil, whiteBalance: .customGainsUnsupported)
                }
                // REVIEW.md F03: validate representability BEFORE the native conversion.
                // A finite Double can still be outside Float's range, and the native
                // converter must never receive a non-finite component.
                guard let temperature = Self.representableFloat(temperatureAndTint.temperature),
                      let tint = Self.representableFloat(temperatureAndTint.tint) else {
                    return .rejected([], focus: nil, whiteBalance: .temperatureTintUnrepresentable)
                }
                let deviceGains = device.deviceWhiteBalanceGains(
                    for: AVCaptureDevice.WhiteBalanceTemperatureAndTintValues(
                        temperature: temperature,
                        tint: tint))
                let resolver = WhiteBalanceGainResolver(maxGain: Double(device.maxWhiteBalanceGain))
                let resolution = resolver.resolve(temperatureAndTint) { _ in
                    AppWhiteBalanceGains(red: Double(deviceGains.redGain),
                                         green: Double(deviceGains.greenGain),
                                         blue: Double(deviceGains.blueGain))
                }
                switch resolution {
                case .exact(let legal), .clamped(_, let legal):
                    resolvedGains = legal
                case .unrepresentable:
                    return .rejected([], focus: nil, whiteBalance: .gainsOutOfRange(
                        AppWhiteBalanceGains(red: Double(deviceGains.redGain),
                                             green: Double(deviceGains.greenGain),
                                             blue: Double(deviceGains.blueGain)),
                        max: Double(device.maxWhiteBalanceGain)))
                case .conversionUnavailable:
                    return .rejected([], focus: nil, whiteBalance: .conversionUnavailable)
                }
            }



            if instruction.exposure.mode == .auto {
                guard device.isExposureModeSupported(.continuousAutoExposure) else {
                    return .rejected([.unsupportedCombination(instruction.exposure.mode)], focus: nil, whiteBalance: nil)
                }
                // Reassigning the same continuous modes at every shutter press is
                // unnecessary. Keep the already-running Auto algorithms in force.
                if device.exposureMode != .continuousAutoExposure {
                    device.exposureMode = .continuousAutoExposure
                }
            } else {
                // Custom exposure is one call with the whole choice. Only this
                // path needs the iOS 27 Auto constants for priority parameters;
                // continuous Auto exposure never consumes them.
                let duration: CMTime
                if let target = instruction.exposure.durationTargetSeconds {
                    guard let built = CMTime.fromValidatedSeconds(target) else {
                        return .rejected([.nonPositiveDuration(target)], focus: nil, whiteBalance: nil)
                    }
                    duration = built
                } else {
                    duration = AVCaptureDevice.autoExposureDuration
                }
                let iso = instruction.exposure.isoTarget.map { Float($0) } ?? AVCaptureDevice.autoISO
                completions.expectOne()
                device.setExposureModeCustom(
                    lensAperture: AVCaptureDevice.currentLensAperture,
                    duration: duration,
                    iso: iso,
                    completionHandler: { time in completions.arrive(atDeviceTime: time) })
            }

            // Bias only takes effect in an automatic or priority configuration.
            if instruction.exposure.mode != .manual,
               device.exposureTargetBias != Float(instruction.biasEV) {
                completions.expectOne()
                device.setExposureTargetBias(Float(instruction.biasEV), completionHandler: { time in completions.arrive(atDeviceTime: time) })
            }

            // H01: the mode assignments below can RAISE an ObjC exception when the mode is
            // unsupported, and that cannot be caught in Swift. Every assignment is guarded
            // by the framework's own support query.
            let supportsFocusMode: (AVCaptureDevice.FocusMode) -> Bool = { device.isFocusModeSupported($0) }
            let supportsWhiteBalanceMode: (AVCaptureDevice.WhiteBalanceMode) -> Bool = {
                device.isWhiteBalanceModeSupported($0)
            }

            // Focus.
            switch instruction.focus.mode {
            case .continuousAuto:
                if let point = instruction.focus.pointOfInterest {
                    let desiredPoint = CGPoint(x: point.x, y: point.y)
                    if device.focusPointOfInterest != desiredPoint { device.focusPointOfInterest = desiredPoint }
                }
                guard supportsFocusMode(.continuousAutoFocus) else {
                    return .rejected([], focus: .manualModeUnsupported, whiteBalance: nil)
                }
                if device.focusMode != .continuousAutoFocus { device.focusMode = .continuousAutoFocus }
            case .lockedAuto:
                if let point = instruction.focus.pointOfInterest {
                    device.focusPointOfInterest = CGPoint(x: point.x, y: point.y)
                }
                guard supportsFocusMode(.autoFocus) else {
                    return .rejected([], focus: .manualModeUnsupported, whiteBalance: nil)
                }
                device.focusMode = .autoFocus
            case .manual:
                if let position = instruction.focus.position {
                    completions.expectOne()
                    device.setFocusModeLocked(lensPosition: Float(position), completionHandler: { time in completions.arrive(atDeviceTime: time) })
                }
            }

            // White balance.
            switch instruction.whiteBalance.mode {
            case .auto:
                guard supportsWhiteBalanceMode(.continuousAutoWhiteBalance) else {
                    return .rejected([], focus: nil, whiteBalance: .customGainsUnsupported)
                }
                if device.whiteBalanceMode != .continuousAutoWhiteBalance {
                    device.whiteBalanceMode = .continuousAutoWhiteBalance
                }
            case .manual:
                guard supportsWhiteBalanceMode(.locked) else {
                    return .rejected([], focus: nil, whiteBalance: .customGainsUnsupported)
                }
                device.whiteBalanceMode = .locked
                if let gains = resolvedGains {
                    completions.expectOne()
                    device.setWhiteBalanceModeLocked(
                        with: AVCaptureDevice.WhiteBalanceGains(
                            redGain: Float(gains.red),
                            greenGain: Float(gains.green),
                            blueGain: Float(gains.blue)),
                        completionHandler: { time in completions.arrive(atDeviceTime: time) })
                }
            }

        }
        #if DEBUG
        print("TruongCam timing control-native-apply=\(Int((ProcessInfo.processInfo.systemUptime - nativeApplyBegan) * 1000))ms")
        let readbackBegan = ProcessInfo.processInfo.systemUptime
        #endif
        // Read the native gains struct once: separate channel getter calls can
        // both repeat native work and combine values from different Auto updates.
        let observedGains = device.deviceWhiteBalanceGains

        var snapshot = AppliedControlSnapshot(
            generation: generation,
            settlement: unchangedAuto ? .moving : .awaitingObservation,
            isExposureAdjusting: device.isAdjustingExposure,
            isFocusAdjusting: device.isAdjustingFocus,
            isWhiteBalanceAdjusting: device.isAdjustingWhiteBalance,
            exposureChoice: instruction.exposure,
            biasEV: instruction.biasEV,
            observedDurationSeconds: device.exposureDuration.seconds,
            observedISO: Double(device.iso),
            observedExposureTargetOffset: Double(device.exposureTargetOffset),
            focusMode: instruction.focus.mode,
            focusPosition: Double(device.lensPosition),
            whiteBalanceMode: instruction.whiteBalance.mode,
            whiteBalanceGains: AppWhiteBalanceGains(
                red: Double(observedGains.redGain),
                green: Double(observedGains.greenGain),
                blue: Double(observedGains.blueGain)),
            lensAperture: Double(device.lensAperture),
            videoZoomFactor: Double(device.videoZoomFactor),
            photoConnectionScale: 1.0,
            photoConnectionCrop: 1.0,
            capturedAtUTC: Date())
        snapshot.isFixedFocusCamera = !device.isLockingFocusWithCustomLensPositionSupported
            && !device.isFocusModeSupported(.autoFocus) && !device.isFocusModeSupported(.continuousAutoFocus)
        #if DEBUG
        print("TruongCam timing control-live-readback=\(Int((ProcessInfo.processInfo.systemUptime - readbackBegan) * 1000))ms")
        #endif
        _ = configuredPhotoDimensions
        // The validated/clamped gains this request actually asked the device for.
        snapshot.resolvedWhiteBalanceTarget = resolvedGains
        return .applied(snapshot)
    }

    /// Asks the format whether this exact priority combination is legal, using
    /// the Auto constants for the automatic parameter.
    static func supportsCombination(
        _ choice: ExposureChoice,
        device: AVCaptureDevice,
        limits: ExposureLimits
    ) -> Bool {
        let format = device.activeFormat
        switch choice.mode {
        case .auto:
            return true
        case .shutterPriority:
            guard let duration = choice.durationTargetSeconds,
                  duration.isFinite, duration > 0,
                  duration >= limits.minDurationSeconds,
                  duration <= limits.maxDurationSeconds else { return false }
            return format.supportsExposureModeCustom(
                lensAperture: AVCaptureDevice.currentLensAperture,
                duration: CMTime.fromValidatedSeconds(duration) ?? AVCaptureDevice.autoExposureDuration,
                iso: AVCaptureDevice.autoISO)
        case .isoPriority:
            guard let iso = choice.isoTarget,
                  iso.isFinite, iso > 0,
                  iso >= limits.minISO, iso <= limits.maxISO else { return false }
            return format.supportsExposureModeCustom(
                lensAperture: AVCaptureDevice.currentLensAperture,
                duration: AVCaptureDevice.autoExposureDuration,
                iso: Float(iso))
        case .manual:
            guard let duration = choice.durationTargetSeconds,
                  let iso = choice.isoTarget,
                  duration.isFinite, duration > 0, iso.isFinite, iso > 0,
                  duration >= limits.minDurationSeconds, duration <= limits.maxDurationSeconds,
                  iso >= limits.minISO, iso <= limits.maxISO else { return false }
            return format.supportsExposureModeCustom(
                lensAperture: AVCaptureDevice.currentLensAperture,
                duration: CMTime.fromValidatedSeconds(duration) ?? AVCaptureDevice.autoExposureDuration,
                iso: Float(iso))
        }
    }

    /// Execute only while the native queue still owns the issuing sensor/control operation.
    static func applyFocusPointIfCurrent(isCurrent: () -> Bool,
        apply: () -> Result<Void, CaptureFailure>) -> Result<Void, CaptureFailure> {
        guard isCurrent() else {
            return .failure(CaptureFailure(kind: .operationStalled(detail: "A newer camera operation owns focus."), operation: "setFocusPoint.owner"))
        }
        return apply()
    }

    /// Focuses at a normalized device point. Returns a typed failure rather than
    /// raising when the point or the mode is unsupported.
    static func setFocusPoint(
        _ point: NormalizedDevicePoint,
        isTapToFocus: Bool,
        on device: AVCaptureDevice,
        focusLimits: FocusLimits
    ) -> Result<Void, CaptureFailure> {
        if let failure = FocusValidator.validatePointOfInterest((point.x, point.y), limits: focusLimits) {
            return .failure(CaptureFailure(
                kind: .unsupportedCapability(detail: failure.userDescription),
                operation: "setFocusPoint"))
        }
        if !device.isFocusPointOfInterestSupported {
            return .failure(CaptureFailure(
                kind: .unsupportedCapability(detail: FocusValidationFailure.pointOfInterestUnsupported.userDescription),
                operation: "setFocusPoint"))
        }
        // POI support does not imply support for single-shot autofocus. Check
        // the mode before changing even the point; an unsupported setter raises.
        if isTapToFocus, device.focusMode != .locked, !device.isFocusModeSupported(.autoFocus) {
            return .failure(CaptureFailure(kind: .unsupportedCapability(detail: "Single-shot autofocus is unavailable on this camera."), operation: "setFocusPoint.mode"))
        }
        do {
            try device.lockForConfiguration()
        } catch {
            return .failure(AVFoundationMapper.failure(error, operation: "setFocusPoint.lock"))
        }
        defer { device.unlockForConfiguration() }
        device.focusPointOfInterest = CGPoint(x: point.x, y: point.y)
        if isTapToFocus, device.focusMode != .locked {
            // A tap must never unlock a deliberate manual focus.
            device.focusMode = .autoFocus
        }
        return .success(())
    }

    /// Keeps the RAW capture preconditions at their legal values: native zoom 1
    /// and connection scale/crop 1. Called before every capture request.
    static func enforceRAWNativeZoom(on device: AVCaptureDevice) -> CaptureFailure? {
        if device.videoZoomFactor != 1.0 {
            do {
                try device.lockForConfiguration()
                defer { device.unlockForConfiguration() }
                device.videoZoomFactor = 1.0
            } catch {
                return AVFoundationFailureMapper.failure(error, operation: "reset videoZoomFactor")
            }
        }
        return nil
    }
}

/// Small shim so the focus-point path can reuse the shared error mapping.
private enum AVFoundationMapper {
    static func failure(_ error: Error, operation: String) -> CaptureFailure {
        AVFoundationFailureMapper.failure(error, operation: operation)
    }
}

/// The production adapter and tests share attachment reconciliation, including
/// delegate loss, system-detached controls and transient canAdd refusal.
protocol HardwareControlSessionPort {
    var supportsControls: Bool { get }
    var maxControlsCount: Int { get }
    var controls: [AVCaptureControl] { get }
    func hasDelegate(_ delegate: HardwareSessionControls) -> Bool
    func setDelegate(_ delegate: HardwareSessionControls, queue: DispatchQueue)
    func canAdd(_ picker: AVCaptureIndexPicker) -> Bool
    func add(_ picker: AVCaptureIndexPicker)
    func remove(_ picker: AVCaptureIndexPicker)
}
private struct NativeHardwareControlSessionPort: HardwareControlSessionPort {
    let session: AVCaptureSession
    var supportsControls: Bool { session.supportsControls }
    var maxControlsCount: Int { session.maxControlsCount }
    var controls: [AVCaptureControl] { session.controls }
    func hasDelegate(_ delegate: HardwareSessionControls) -> Bool { session.controlsDelegate === delegate }
    func setDelegate(_ delegate: HardwareSessionControls, queue: DispatchQueue) { session.setControlsDelegate(delegate, queue: queue) }
    func canAdd(_ picker: AVCaptureIndexPicker) -> Bool { session.canAddControl(picker) }
    func add(_ picker: AVCaptureIndexPicker) { session.addControl(picker) }
    func remove(_ picker: AVCaptureIndexPicker) { session.removeControl(picker) }
}

/// All native picker/delegate state belongs to the serial session queue (and its
/// targeted control-action queues). Only Sendable selections cross to the model.
final class HardwareSessionControls: NSObject, AVCaptureSessionControlsDelegate, @unchecked Sendable {
    private var configuration = HardwareControlConfiguration(enabled: false, selections: [])
    private var pickers: [AVCaptureIndexPicker] = []
    private var domains: [HardwareControlDomain] = []
    private var requestedDomains: [HardwareControlDomain] = []
    private var interactionID = UUID()
    private var emit: @Sendable (HardwareControlEvent) -> Void = { _ in }
    private var fullscreen: @Sendable (Bool) -> Void = { _ in }
    private var active = false

    @discardableResult
    func update(session: AVCaptureSession, configuration: HardwareControlConfiguration, interactionID: UUID = UUID(),
                queue: DispatchQueue, emit: @escaping @Sendable (HardwareControlEvent) -> Void,
                fullscreen: @escaping @Sendable (Bool) -> Void) -> Bool {
        update(port: NativeHardwareControlSessionPort(session: session), configuration: configuration,
            interactionID: interactionID, queue: queue, emit: emit, fullscreen: fullscreen)
    }

    @discardableResult
    func update(port: any HardwareControlSessionPort, configuration: HardwareControlConfiguration, interactionID: UUID,
                queue: DispatchQueue, emit: @escaping @Sendable (HardwareControlEvent) -> Void,
                fullscreen: @escaping @Sendable (Bool) -> Void) -> Bool {
        self.emit = emit; self.fullscreen = fullscreen
        let previous = self.configuration
        let changedInteraction = self.interactionID != interactionID
        self.interactionID = interactionID
        self.configuration = configuration
        guard port.supportsControls else { return true }
        let selections = Array(configuration.selections.filter {
            !$0.domain.options.isEmpty && $0.domain.options.count <= 512 && $0.domain.value(at: $0.index) != nil
        }.prefix(max(0, port.maxControlsCount)))
        let wanted = selections.map(\.domain)
        let missing = pickers.count != wanted.count || pickers.contains { picker in !port.controls.contains { $0 === picker } }
        let restoringInput = !previous.enabled && configuration.enabled
        let rebuild = wanted != requestedDomains || missing || !port.hasDelegate(self) || restoringInput
        if rebuild {
            requestedDomains = wanted
            for picker in pickers where port.controls.contains(where: { $0 === picker }) { port.remove(picker) }
            pickers = []; domains = []
            port.setDelegate(self, queue: queue)
            for selection in selections {
                let domain = selection.domain
                let picker = AVCaptureIndexPicker(domain.title, symbolName: domain.symbol,
                    localizedIndexTitles: domain.options.map(\.title))
                picker.setActionQueue(queue) { [weak self] index in
                    self?.receiveSelection(HardwareControlSelection(domain: domain, index: index), interactionID: interactionID)
                }
                picker.selectedIndex = selection.index
                picker.isEnabled = configuration.enabled || configuration.preservesPresentation
                guard port.canAdd(picker) else { continue }
                port.add(picker)
                pickers.append(picker); domains.append(domain)
            }
            #if DEBUG
            print("TruongCam hardware-controls reconcile desired=\(wanted.count) attached=\(pickers.count) input=\(configuration.enabled) preserved=\(configuration.preservesPresentation)")
            #endif
        }
        for (picker, domain) in zip(pickers, domains) {
            guard let selection = selections.first(where: { $0.domain == domain }) else { continue }
            if changedInteraction && !rebuild {
                picker.setActionQueue(queue) { [weak self] index in
                    self?.receiveSelection(HardwareControlSelection(domain: domain, index: index), interactionID: interactionID)
                }
            }
            picker.isEnabled = configuration.enabled || configuration.preservesPresentation
            let wasAutomatic = previous.selections.first(where: { $0.domain == domain })?.isAutomatic
            if HardwarePickerSynchronization.shouldUpdateIndex(active: active, ownerChanged: changedInteraction,
                automaticChanged: wasAutomatic != selection.isAutomatic), picker.selectedIndex != selection.index {
                picker.selectedIndex = selection.index
            }
        }
        if !configuration.enabled && !configuration.preservesPresentation { active = false; fullscreen(false) }
        return pickers.count == wanted.count
    }

    /// Shared by real native actions and discriminating binding tests.
    func receiveSelection(_ selection: HardwareControlSelection, interactionID: UUID) {
        guard self.interactionID == interactionID, configuration.enabled, domains.contains(selection.domain),
              selection.domain.value(at: selection.index) != nil else { return }
        emit(HardwareControlEvent(interactionID: interactionID, selection: selection))
    }
    func sessionControlsDidBecomeActive(_ session: AVCaptureSession) { active = configuration.enabled || configuration.preservesPresentation }
    func sessionControlsWillEnterFullscreenAppearance(_ session: AVCaptureSession) {
        if configuration.enabled || configuration.preservesPresentation { fullscreen(true) }
    }
    func sessionControlsWillExitFullscreenAppearance(_ session: AVCaptureSession) { fullscreen(false) }
    func sessionControlsDidBecomeInactive(_ session: AVCaptureSession) {
        active = false
        for (picker, domain) in zip(pickers, domains) {
            if let selection = configuration.selections.first(where: { $0.domain == domain }), picker.selectedIndex != selection.index {
                picker.selectedIndex = selection.index
            }
        }
        fullscreen(false)
    }
}
