import Foundation
import Synchronization
#if canImport(XCTest)
@testable import TruongCam
#endif

private actor CleanupHold {
    private var continuation: CheckedContinuation<Void, Never>?
    private var observers: [CheckedContinuation<Void, Never>] = []
    func wait() async {
        await withCheckedContinuation { c in
            continuation = c
            for observer in observers { observer.resume() }
            observers = []
        }
    }
    func entered() async {
        if continuation != nil { return }
        await withCheckedContinuation { observers.append($0) }
    }
    func release() { continuation?.resume(); continuation = nil }
}

struct OperationCleanupSuite {
    static func reading() -> AppliedControlSnapshot {
        AppliedControlSnapshot(generation: .zero, exposureChoice: .auto, biasEV: 0,
            observedDurationSeconds: 0.01, observedISO: 100, observedExposureTargetOffset: 0,
            focusMode: .manual, focusPosition: 0.7, whiteBalanceMode: .auto,
            whiteBalanceGains: nil, lensAperture: nil, videoZoomFactor: 1,
            photoConnectionScale: 1, photoConnectionCrop: 1, capturedAtUTC: Date())
    }
    static func accepted(_ owner: ControlApplicationOwner) async -> ControlApplicationOwner.Application {
        let application = await owner.begin(revision: 1, generation: .zero)
        let target = ControlSettlementPolicy.Target(focusPosition: 0.7)
        _ = await owner.accept(application, target: target)
        await owner.beginSettlement(target: target)
        _ = await owner.settle(reading(), for: application)
        _ = await owner.settle(reading(), for: application)
        return application
    }
    static let suite = TCSuite(id: "OperationCleanup", title: "Live operation authority at the owner mutation", cases: [
        TCCase(id: "OC01", title: "Current cleanup clears its own window and history") { r in
            let owner = ControlApplicationOwner()
            let application = await accepted(owner)
            r.equal("positive precondition: the accepted window is settled",
                    await owner.settle(reading(), for: application), .settled)
            let cleared = await owner.endSettlement(ifOwnedBy: application, authorityIsCurrent: { true })
            r.check("current legitimate cleanup executes", cleared)
            r.notEqual("a subsequent reading cannot inherit settled history",
                       await owner.settle(reading(), for: application), .settled)
        },
        TCCase(id: "OC02", title: "Lifecycle supersession while queued preserves the accepted window") { r in
            let owner = ControlApplicationOwner(), life = LifecycleOwnership(), hold = CleanupHold()
            let application = await accepted(owner), token = life.begin()
            let authority: @Sendable () -> Bool = { life.isCurrent(token) }
            r.check("currency was true before the hop", authority())
            let task = Task {
                await hold.wait()
                return await owner.endSettlement(ifOwnedBy: application, authorityIsCurrent: authority)
            }
            await hold.entered(); _ = life.begin(); await hold.release()
            r.check("obsolete cleanup refuses at the actual owner turn", !(await task.value))
            r.equal("accepted window history is preserved",
                    await owner.settle(reading(), for: application), .settled)
        },
        TCCase(id: "OC03", title: "Reset supersession without a new lifecycle refuses owner finish") { r in
            let owner = ControlApplicationOwner(), hold = CleanupHold()
            let application = await accepted(owner)
            let observed = await owner.ownershipSnapshot
            let pass = LatestValueBroadcaster<UInt64>()
            pass.send(1)
            let authority: @Sendable () -> Bool = { pass.current == 1 }
            r.check("reset authority was true before the hop", authority())
            let task = Task {
                await hold.wait()
                return await owner.finish(ifUnchangedSince: observed, authorityIsCurrent: authority)
            }
            await hold.entered(); pass.send(2); await hold.release()
            r.check("old Stop cannot finish the newer reset's owner", !(await task.value))
            r.equal("the accepted application survives", await owner.currentApplication, application)
            r.equal("the accepted settled history survives",
                    await owner.settle(reading(), for: application), .settled)
        },
        TCCase(id: "OC04", title: "Restoration requires the current correlated settled measurement") { r in
            var observation = reading()
            observation.settlement = .settled
            observation.requestRevision = 3
            let settings = SequenceSettingsSnapshot(configurationGeneration: .zero, revision: 2,
                exposure: .auto, biasEV: 0,
                focus: FocusIntent(mode: .manual, position: 0.7, pointOfInterest: nil),
                whiteBalance: WhiteBalanceIntent(mode: .auto, temperatureAndTint: nil),
                maxDimensions: PixelDimensions(width: 4032, height: 3024))
            func verified(_ value: AppliedControlSnapshot, generation: ConfigurationGeneration = .zero, revision: UInt64 = 3) -> Bool {
                SequenceControlVerification.matches(value, settings: settings, generation: generation,
                                                    revision: revision, whiteBalanceTarget: nil)
            }
            r.check("a matching current settled observation restores", verified(observation))
            r.check("an old generation cannot restore the new graph", !verified(observation, generation: ConfigurationGeneration(1)))
            r.check("another control revision cannot restore this request", !verified(observation, revision: 4))
            observation.settlement = .awaitingObservation
            r.check("a setter acknowledgement is not restoration", !verified(observation))
            observation.settlement = .settled
            // The immutable reading's position is reconstructed with a different target.
            let wrongTarget = SequenceSettingsSnapshot(configurationGeneration: .zero, revision: 2,
                exposure: .auto, biasEV: 0,
                focus: FocusIntent(mode: .manual, position: 0.1, pointOfInterest: nil),
                whiteBalance: WhiteBalanceIntent(mode: .auto, temperatureAndTint: nil),
                maxDimensions: settings.maxDimensions)
            r.check("settled at the wrong focus is not restoration", !SequenceControlVerification.matches(
                observation, settings: wrongTarget, generation: .zero, revision: 3, whiteBalanceTarget: nil))
        },
        TCCase(id: "OC05", title: "Submitted native identity owns its source and terminal callbacks") { r in
            let captureID = CaptureID()
            let intent = ChainCameraSpy.defaultIntent(captureID: captureID)
            let request = PerCaptureRequest(captureID: captureID, intent: intent,
                rawPixelFormatType: 0x1234, rawFileType: "synthetic", maximumRepresentations: 1)
            r.check("native settings bind before any callback", request.bindNativeSettingsID(9001))
            r.check("another native settings identity cannot rebind", !request.bindNativeSettingsID(9002))
            let ticket = CameraCaptureTicket(captureID: captureID, uniqueSettingsID: 0, request: request)
            r.equal("the shipping ticket exposes the submitted native identity", ticket.uniqueSettingsID, 9001)
            func representation(_ id: CaptureID, settings: Int64) -> DeliveredRAWRepresentation {
                DeliveredRAWRepresentation(bytes: Data([1,2,3]), captureID: id,
                    resolvedSettingsUniqueID: settings, nativeBracketIdentity: nil,
                    rawPixelFormatType: 0x1234, rawFileType: "synthetic",
                    rawPhotoDimensions: nil, rawPixelBufferDimensions: nil,
                    timestampSeconds: 0, metadata: [:])
            }
            r.check("another native request's RAW is refused", !request.recordRepresentation(representation(captureID, settings: 9002)))
            r.check("another capture identity is refused", !request.recordRepresentation(representation(CaptureID(), settings: 9001)))
            r.equal("foreign callbacks publish no source", request.recordedRepresentationCount, 0)
            r.check("its own late RAW remains accepted under original identity", request.recordRepresentation(representation(captureID, settings: 9001)))
            r.check("another native terminal cannot retire this request", request.recordNativeTerminal(settingsID: 9002, mappedFailure: nil) == nil)
            r.check("this terminal remains unresolved after a foreign callback", request.terminal.current == nil)
            r.check("its own native terminal resolves honestly", request.recordNativeTerminal(settingsID: 9001, mappedFailure: nil) != nil)
            r.equal("exactly its own source remains recorded", request.recordedRepresentationCount, 1)
        }
    ])
}
