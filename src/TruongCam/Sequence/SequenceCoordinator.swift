import Foundation

// CONTRACTS.md "Sequence rules and policy defaults", "Readiness and admission",
// "Common failure" and ARCHITECTURE.md "Advanced sequences".
//
// The coordinator owns plan freezing, serial source admission, deadline
// scheduling, bracket identity mapping, cancellation/interruption, source
// retention and settings restoration. It never touches a device: every camera,
// storage and clock effect arrives through an injected port.

actor SequenceCoordinator {

    /// Everything the coordinator needs, injected. All ports are testable with
    /// deterministic fakes and a `VirtualMonotonicClock`.
    struct Environment: Sendable {
        let clock: MonotonicClock
        let wallClock: WallClock
        let storage: SequenceDocumentStoring
        let pipeline: SequenceSourcePipeline
        let settings: SequenceSettingsControlling
        let baselineSettler: SequenceBaselineSettling
        let bracketSubmitter: BracketSubmitting
        let focusDriver: FocusBracketDriver
        let capability: SequenceCapabilityProviding
        let admission: SequenceAdmissionPolicy
        /// Longest a single wait may run before re-checking the stop flag. Bounds
        /// cancel latency without depending on task cancellation.
        var cancellationCheckIntervalSeconds: Double = 0.5

        init(clock: MonotonicClock,
             wallClock: WallClock,
             storage: SequenceDocumentStoring,
             pipeline: SequenceSourcePipeline,
             settings: SequenceSettingsControlling,
             baselineSettler: SequenceBaselineSettling,
             bracketSubmitter: BracketSubmitting,
             focusDriver: FocusBracketDriver,
             capability: SequenceCapabilityProviding,
             admission: SequenceAdmissionPolicy = .provisional,
             cancellationCheckIntervalSeconds: Double = 0.5) {
            self.clock = clock
            self.wallClock = wallClock
            self.storage = storage
            self.pipeline = pipeline
            self.settings = settings
            self.baselineSettler = baselineSettler
            self.bracketSubmitter = bracketSubmitter
            self.focusDriver = focusDriver
            self.capability = capability
            self.admission = admission
            self.cancellationCheckIntervalSeconds = cancellationCheckIntervalSeconds
        }
    }

    private enum RunState: Sendable {
        case idle
        case validating
        case active
        case terminal(SequenceStatus, CaptureFailure?, SequenceInterruptionReason?)
        case restorationFailed(CaptureFailure)
        case resettingToAuto

        var isActive: Bool {
            switch self {
            case .validating, .active, .resettingToAuto: return true
            case .idle, .terminal, .restorationFailed: return false
            }
        }

        var isRunningWork: Bool {
            switch self {
            case .active: return true
            default: return false
            }
        }
    }

    private let environment: Environment

    private var runState: RunState = .idle
    private var activePlan: SequencePlan?
    private var progress: SequenceProgress?
    private var stopReason: SequenceStopReason?
    private var cancellation = SequenceCancellationSignal()

    private var committedReceipts: [Int: CommitReceipt] = [:]
    private var retainedHandles: [Int: StagedSourceHandle] = [:]
    private var failedOrdinals: Set<Int> = []
    private var unattributedCallbacks = 0
    private var seenBracketIdentities: Set<NativeBracketIdentity> = []
    private var bracketTerminalOutcome: NativeRequestOutcome?
    private var documentWriteFailed = false
    private var priorSettings: SequenceSettingsSnapshot?
    private var appliedBaseline: SequenceBaselineSnapshot?
    private var settingsTouched = false
    private var focusReadbacks: [FocusSettleRecord] = []
    private var intervalScheduleSnapshot: IntervalScheduleSnapshot?
    private var runStartedAtUTC: Date?
    private var unresolvedRestorationFailure: CaptureFailure?

    init(environment: Environment) {
        self.environment = environment
    }

    // MARK: - Observation

    func snapshot() -> SequenceCoordinatorSnapshot {
        let publicState = makePublicState()
        return SequenceCoordinatorSnapshot(
            state: publicState,
            progress: progress,
            isShutterBlocked: publicState.isShutterBlocked,
            offersResetToAuto: publicState.offersResetToAuto,
            restoration: publicState.restoration)
    }

    private func makePublicState() -> SequenceCoordinatorState {
        guard let progress else {
            if case .resettingToAuto = runState { return .resettingToAuto }
            return .idle
        }
        switch runState {
        case .idle:
            return .idle
        case .validating:
            return .validating(sequenceID: progress.sequenceID)
        case .active:
            return .running(progress)
        case .terminal(let status, let failure, let reason):
            switch status {
            case .complete: return .complete(progress)
            case .cancelled: return .cancelled(progress)
            case .interrupted:
                return .interrupted(progress, reason: reason ?? .unknown)
            case .failed:
                return .failed(progress, failure: failure ?? Self.genericFailure)
            case .running:
                return .running(progress)
            }
        case .restorationFailed(let failure):
            return .restorationFailed(progress, failure: failure)
        case .resettingToAuto:
            return .resettingToAuto
        }
    }

    private static var genericFailure: CaptureFailure {
        CaptureFailure(kind: .captureFailed(detail: "The sequence did not complete."),
                       operation: "sequence.run")
    }

    // MARK: - Validation

    func validate(_ plan: SequencePlan) async -> [SequencePlanValidationError] {
        let capability = await environment.capability.capabilityContext()
        let baseline = await environment.settings.currentExposureBaseline()
        let context = SequenceValidationContext(capability: capability,
                                                admission: environment.admission,
                                                bracketBaseline: baseline)
        return plan.validate(context: context)
    }

    // MARK: - Start

    func start(_ plan: SequencePlan) async -> SequenceRunResult {
        // A restoration failure blocks new captures until the state is
        // reconciled. It is never silently reported as restored.
        if let unresolvedRestorationFailure {
            return rejected(plan, failure: CaptureFailure(
                kind: .restorationFailed(detail: unresolvedRestorationFailure.kind.userDescription),
                operation: "sequence.start"))
        }
        if runState.isActive {
            return rejected(plan, failure: CaptureFailure(
                kind: .invalidSettings(detail: "Another sequence is already running."),
                operation: "sequence.start"))
        }

        beginRun(plan)
        runState = .validating

        let capability = await environment.capability.capabilityContext()
        let currentBaseline = await environment.settings.currentExposureBaseline()
        let context = SequenceValidationContext(capability: capability,
                                                admission: environment.admission,
                                                bracketBaseline: currentBaseline)

        // No settled reading at the instant Start is tapped is a reason to
        // settle, not to reject a legal bracket before the settler can run.
        // All other preflight errors still fail before any device/settings effect;
        // the full duration/headroom validation below uses the proven baseline.
        let errors = plan.validate(context: context).filter { error in
            if plan.exposureBracketPlan != nil, currentBaseline == nil,
               case .bracketBaselineMissing = error { return false }
            return true
        }
        if !errors.isEmpty {
            let failure = CaptureFailure(
                kind: .invalidSettings(detail: errors.map(\.description).joined(separator: " ")),
                operation: "sequence.validate")
            return await conclude(plan: plan,
                                  stop: .failed(failure),
                                  restoration: .notApplicable,
                                  validationErrors: errors)
        }

        priorSettings = await environment.settings.snapshotCurrentSettings()

        let baselineResult = await resolveBaseline(plan: plan,
                                                   capability: capability,
                                                   prior: priorSettings,
                                                   current: currentBaseline)
        let baseline: SequenceBaselineSnapshot?
        switch baselineResult {
        case .failure(let failure):
            let restoration = await restorePriorSettings()
            return await conclude(plan: plan,
                                  stop: stopReason ?? .failed(failure),
                                  restoration: restoration,
                                  validationErrors: [])
        case .success(let resolved):
            baseline = resolved
        }
        appliedBaseline = baseline

        // Re-validate every duration target against the baseline that was
        // actually settled. This is the last gate before any submission, so an
        // illegal exposure is never attempted.
        if let bracketPlan = plan.exposureBracketPlan, let settled = baseline?.exposureBaseline {
            let settledContext = SequenceValidationContext(capability: capability,
                                                           admission: environment.admission,
                                                           bracketBaseline: settled)
            let recheck = bracketPlan.validate(baseline: settled, context: settledContext)
            if !recheck.isEmpty {
                let failure = CaptureFailure(
                    kind: .invalidSettings(detail: recheck.map(\.description).joined(separator: " ")),
                    operation: "sequence.exposureBracket.validate")
                return await conclude(plan: plan,
                                      stop: .failed(failure),
                                      restoration: await restorePriorSettings(),
                                      validationErrors: recheck)
            }
        }

        if let stopReason {
            return await conclude(plan: plan, stop: stopReason, restoration: await restorePriorSettings(), validationErrors: [])
        }
        runState = .active
        cancellation.reset()

        if let baseline, let prior = priorSettings {
            let frozen = SequenceSettingsSnapshot(
                configurationGeneration: prior.configurationGeneration,
                revision: prior.revision &+ 1,
                exposure: baseline.exposure,
                biasEV: baseline.biasEV,
                focus: baseline.focus,
                whiteBalance: baseline.whiteBalance,
                maxDimensions: baseline.maxDimensions)
            settingsTouched = true
            if case .failure(let failure) = await environment.settings.apply(frozen) {
                let restoration = await restorePriorSettings()
                return await conclude(plan: plan,
                                      stop: .failed(failure),
                                      restoration: restoration,
                                      validationErrors: [])
            }
        }

        let stop = await execute(plan: plan, baseline: baseline)
        let restoration = await restorePriorSettings()
        return await conclude(plan: plan,
                              stop: stop,
                              restoration: restoration,
                              validationErrors: [])
    }

    // MARK: - Cancellation and interruption

    func cancel(sequenceID: SequenceID) {
        // A cancel for an already terminal run must not change its outcome.
        guard runState.isActive,
              let activePlan,
              activePlan.sequenceID == sequenceID else { return }
        requestStop(.userCancelled)
    }

    func interrupt(reason: SequenceInterruptionReason) {
        guard runState.isActive else { return }
        requestStop(.interrupted(reason))
    }

    /// Recovery from a failed settings restoration: return exposure/focus/WB to
    /// Auto and unblock the shutter.
    func resetToAuto() async -> Result<Void, CaptureFailure> {
        guard !runState.isRunningWork else {
            return .failure(CaptureFailure(
                kind: .invalidSettings(detail: "A sequence is still running."),
                operation: "sequence.resetToAuto"))
        }
        runState = .resettingToAuto
        let result = await environment.settings.resetToAuto()
        switch result {
        case .success:
            unresolvedRestorationFailure = nil
            runState = .idle
            progress = nil
            activePlan = nil
            return .success(())
        case .failure(let failure):
            let recorded = unresolvedRestorationFailure ?? failure
            unresolvedRestorationFailure = recorded
            runState = .restorationFailed(recorded)
            return .failure(failure)
        }
    }

    // MARK: - Recovery

    func reconcileAfterRestart(sequenceID: SequenceID) async -> Result<SequenceReconciliation, CaptureFailure> {
        let document: SequenceDocument
        do {
            document = try await environment.storage.readSequenceDocument(sequenceID)
        } catch {
            return .failure(CaptureFailure(
                kind: .metadataInvalid(detail: "The sequence document could not be read."),
                operation: "sequence.reconcile",
                underlying: error))
        }

        guard document.sequenceID == sequenceID.rawValue,
              document.libraryID == environment.storage.rootState.libraryID?.rawValue,
              SequenceDocumentSemanticValidator().validate(document).isEmpty else {
            return .failure(CaptureFailure(kind: .metadataInvalid(detail: "The sequence document has invalid identity or bounded source data."), operation: "sequence.reconcile"))
        }
        var updated = document
        var didPersist = false
        var note: String?

        if document.status == .running {
            let completed = Set(document.completedSources.map(\.index))
            let failed = Set(document.failedIndices)
            updated.status = .interrupted
            updated.endedAtUTC = environment.wallClock.now()
            updated.missingIndices = (0..<max(document.plannedCount, 0))
                .filter { !completed.contains($0) && !failed.contains($0) }
            // A fresh process starts from Auto, so there is no stale frozen state
            // to restore; the run was not resumed and never will be.
            updated.restorationStatus = .notApplicable
            updated.errorSummary = "The app stopped while this sequence was running. "
                + "It is reported as interrupted and is never resumed automatically."
            note = "A stale running sequence is reported as interrupted and is never auto-resumed."

            if environment.storage.rootState.isWritable {
                do {
                    try await environment.storage.writeSequenceDocument(updated)
                    didPersist = true
                } catch {
                    didPersist = false
                    note = (note ?? "") + " The interrupted status could not be written."
                }
            } else {
                note = (note ?? "") + " The library root is not writable, so the interrupted "
                    + "status is held in memory only."
            }
        }

        let summary = SequenceSummary(
            sequenceID: sequenceID,
            kind: updated.kind,
            plannedCount: updated.plannedCount,
            committedCount: updated.completedSources.count,
            missingIndices: updated.missingIndices,
            failedIndices: updated.failedIndices,
            skippedDeadlineCount: updated.skippedDeadlineCount,
            status: updated.status,
            startedAtUTC: document.startedAtUTC)

        return .success(SequenceReconciliation(
            sequenceID: sequenceID,
            previousStatus: document.status,
            document: updated,
            didPersist: didPersist,
            summary: summary,
            note: note))
    }

    // MARK: - Phase observation

    nonisolated func observe(phase: SequenceRunPhase) async {
        await applyObservedPhase(phase)
    }

    private func applyObservedPhase(_ phase: SequenceRunPhase) {
        guard runState.isRunningWork else { return }
        setPhase(phase)
    }

    // MARK: - Run bookkeeping

    private func beginRun(_ plan: SequencePlan) {
        activePlan = plan
        stopReason = nil
        committedReceipts = [:]
        retainedHandles = [:]
        failedOrdinals = []
        unattributedCallbacks = 0
        seenBracketIdentities = []
        bracketTerminalOutcome = nil
        documentWriteFailed = false
        priorSettings = nil
        appliedBaseline = nil
        settingsTouched = false
        focusReadbacks = []
        intervalScheduleSnapshot = nil
        runStartedAtUTC = environment.wallClock.now()
        cancellation = SequenceCancellationSignal()
        progress = SequenceProgress(
            sequenceID: plan.sequenceID,
            kind: plan.kind,
            plannedCount: plan.plannedSourceCount,
            committedCount: 0,
            retainedCount: 0,
            failedOrdinals: [],
            missingOrdinals: Self.boundedOrdinals(plan.plannedSourceCount),
            skippedDeadlineCount: 0,
            deadlineOrdinalsUsed: [],
            unattributedCallbackCount: 0,
            phase: .validating,
            status: .running,
            restoration: .pending,
            errorSummary: nil,
            documentWriteFailed: false,
            bracketPath: plan.exposureBracketPlan?.path,
            baseline: nil)
    }

    private func isStopRequested() -> Bool {
        stopReason != nil
    }

    private func requestStop(_ reason: SequenceStopReason) {
        // The first failure/cancel/interruption wins and stops future
        // submissions.
        guard stopReason == nil else { return }
        stopReason = reason
        cancellation.request()
    }

    private func setPhase(_ phase: SequenceRunPhase) {
        guard var current = progress else { return }
        current.phase = phase
        progress = current
    }

    private func refreshProgress() {
        guard var current = progress else { return }
        current.committedCount = committedReceipts.count
        current.retainedCount = committedReceipts.count + retainedHandles.count
        current.failedOrdinals = failedOrdinals.sorted()
        current.missingOrdinals = computedMissingOrdinals()
        current.unattributedCallbackCount = unattributedCallbacks
        current.documentWriteFailed = documentWriteFailed
        current.baseline = appliedBaseline
        current.skippedDeadlineCount = intervalScheduleSnapshot?.skippedDeadlineCount ?? current.skippedDeadlineCount
        current.deadlineOrdinalsUsed = intervalScheduleSnapshot?.usedDeadlineOrdinals ?? current.deadlineOrdinalsUsed
        progress = current
    }

    private func computedMissingOrdinals() -> [Int] {
        guard let plan = activePlan else { return [] }
        let resolved = Set(committedReceipts.keys).union(retainedHandles.keys)
        return Self.boundedOrdinals(plan.plannedSourceCount)
            .filter { !resolved.contains($0) && !failedOrdinals.contains($0) }
    }

    /// Validation owns rejection of malformed plans. Even the pre-validation
    /// progress projection must not allocate from an untrusted source count.
    private static func boundedOrdinals(_ count: Int) -> [Int] {
        guard (1...MetadataBounds.maxSequenceSources).contains(count) else { return [] }
        return Array(0..<count)
    }

    private func record(_ outcome: SequenceSourceOutcome, ordinal: Int) {
        if let receipt = outcome.receipt {
            committedReceipts[ordinal] = receipt
            retainedHandles.removeValue(forKey: ordinal)
        } else if let handle = outcome.stagedHandle {
            retainedHandles[ordinal] = handle
        } else {
            failedOrdinals.insert(ordinal)
        }
        refreshProgress()
    }

    // MARK: - Execution

    private func execute(plan: SequencePlan,
                         baseline: SequenceBaselineSnapshot?) async -> SequenceStopReason? {
        switch plan.specification {
        case .timer(let timer):
            await executeTimer(plan: plan, timer: timer)
        case .interval(let interval):
            await executeInterval(plan: plan, interval: interval, baseline: baseline)
        case .exposureBracket(let bracket):
            await executeExposureBracket(plan: plan, bracket: bracket, baseline: baseline)
        case .focusBracket(let focus):
            await executeFocusBracket(plan: plan, focus: focus, baseline: baseline)
        }
        return stopReason
    }

    // MARK: Timer

    private func executeTimer(plan: SequencePlan, timer: TimerPlan) async {
        let origin = environment.clock.now()
        let deadline = CountdownDeadline(originMonotonic: origin, delaySeconds: timer.delaySeconds)
        setPhase(.countdown(deadlineMonotonic: deadline.deadlineMonotonic))

        // Cancel, backgrounding, lens switch or permission loss before submission
        // means zero frames.
        guard await waitUntil(deadline.deadlineMonotonic) else { return }
        guard !isStopRequested() else { return }

        // A timer run uses the settings the user sees at expiry: nothing was
        // frozen, so nothing has to be restored.
        let live = await environment.settings.snapshotCurrentSettings()
        setPhase(.capturing(ordinal: 0))
        let intent = makeIntent(
            plan: plan,
            ordinal: nil,
            mode: .timer,
            dimensions: dimensionFallback(live),
            exposure: live?.exposure ?? .auto,
            biasEV: live?.biasEV ?? 0,
            focus: live?.focus ?? Self.defaultFocus,
            whiteBalance: live?.whiteBalance ?? Self.defaultWhiteBalance,
            requestedOffsetEV: nil,
            focusBracketTarget: nil,
            deadlineOrdinal: nil)

        let outcome = await environment.pipeline.run(intent)
        record(outcome, ordinal: 0)
        await persistDocument(status: .running)
        if let failure = outcome.failure {
            requestStop(.failed(failure))
        }
    }

    // MARK: Interval

    private func executeInterval(plan: SequencePlan,
                                 interval: IntervalPlan,
                                 baseline: SequenceBaselineSnapshot?) async {
        // The schedule origin is Start / countdown completion, after any baseline
        // settling has finished.
        var schedule = IntervalSchedule(originMonotonic: environment.clock.now(),
                                        intervalSeconds: interval.intervalSeconds,
                                        plannedCount: interval.count)
        intervalScheduleSnapshot = IntervalScheduleSnapshot(schedule)
        refreshProgress()

        while !schedule.isFinished {
            if isStopRequested() { break }

            // No backlog burst: each source waits for its own eligible deadline,
            // and after a delayed commit the cursor has already advanced past
            // every deadline that elapsed while the pipeline was busy.
            let deadline = schedule.nextEligibleDeadlineTime
            let deadlineOrdinal = schedule.currentDeadlineOrdinal
            setPhase(.waitingForDeadline(deadlineMonotonic: deadline,
                                         deadlineOrdinal: deadlineOrdinal))
            guard await waitUntil(deadline) else { break }
            guard !isStopRequested() else { break }

            let ordinal = schedule.committedSourceCount
            setPhase(.capturing(ordinal: ordinal))
            let intent = makeIntent(
                plan: plan,
                ordinal: SourceOrdinal(ordinal),
                mode: .intervalSource,
                dimensions: dimensionFallback(nil),
                exposure: baseline?.exposure ?? .auto,
                biasEV: baseline?.biasEV ?? 0,
                focus: baseline?.focus ?? Self.defaultFocus,
                whiteBalance: baseline?.whiteBalance ?? Self.defaultWhiteBalance,
                requestedOffsetEV: nil,
                focusBracketTarget: nil,
                deadlineOrdinal: DeadlineOrdinal(deadlineOrdinal))

            let outcome = await environment.pipeline.run(intent)
            let committedAt = environment.clock.now()
            record(outcome, ordinal: ordinal)

            // The ordinal counts committed originals; the cursor counts deadlines.
            schedule.recordCommitted(now: committedAt)
            intervalScheduleSnapshot = IntervalScheduleSnapshot(schedule)
            refreshProgress()
            await persistDocument(status: .running)

            if let failure = outcome.failure {
                requestStop(.failed(failure))
            }
        }
    }

    // MARK: Exposure bracket

    private func executeExposureBracket(plan: SequencePlan,
                                        bracket: ExposureBracketPlan,
                                        baseline: SequenceBaselineSnapshot?) async {
        guard let settled = baseline?.exposureBaseline else {
            requestStop(.failed(CaptureFailure(
                kind: .invalidSettings(detail: "An exposure bracket needs a settled manual baseline."),
                operation: "sequence.exposureBracket")))
            return
        }

        let intents = makeBracketIntents(plan: plan, bracket: bracket, baseline: settled)

        if bracket.path == .serial {
            // Clearly labeled slower alternative: one supported single capture
            // per source, set and settled serially. It is never substituted
            // midway through a failed native run.
            for (index, intent) in intents.enumerated() {
                if isStopRequested() { break }
                setPhase(.capturing(ordinal: index))
                let outcome = await environment.pipeline.run(intent)
                record(outcome, ordinal: index)
                await persistDocument(status: .running)
                if let failure = outcome.failure {
                    requestStop(.failed(failure))
                    break
                }
            }
            return
        }

        let request = BracketSubmissionRequest(
            sequenceID: plan.sequenceID,
            libraryID: plan.libraryID,
            configurationGeneration: plan.configurationGeneration,
            rootGeneration: plan.rootGeneration,
            plan: bracket,
            baseline: settled,
            intents: intents)

        switch await environment.bracketSubmitter.submit(request) {
        case .failure(let failure):
            requestStop(.failed(failure))
        case .success(let submission):
            await drainNativeBracket(submission, plan: plan, intents: intents)
        }
    }

    private func makeBracketIntents(plan: SequencePlan,
                                    bracket: ExposureBracketPlan,
                                    baseline: ExposureBaseline) -> [CaptureIntent] {
        bracket.offsetsEV.enumerated().map { index, offset in
            let duration = bracket.targetDurationSeconds(offsetEV: offset,
                                                         baselineSeconds: baseline.durationSeconds)
            return makeIntent(
                plan: plan,
                ordinal: SourceOrdinal(index),
                mode: .exposureBracketSource,
                dimensions: dimensionFallback(nil),
                exposure: .manual(durationSeconds: duration, iso: baseline.iso),
                biasEV: baseline.biasEV,
                focus: appliedBaseline?.focus ?? Self.defaultFocus,
                whiteBalance: appliedBaseline?.whiteBalance ?? Self.defaultWhiteBalance,
                requestedOffsetEV: offset,
                focusBracketTarget: nil,
                deadlineOrdinal: nil)
        }
    }

    /// Drains a submitted native bracket to storage.
    ///
    /// Cancelling a sequence never assumes the native burst stopped: it stops
    /// future requests and saves everything already delivered. Callbacks are
    /// attributed by `NativeBracketIdentity` and never by arrival order.
    private func drainNativeBracket(_ submission: BracketSubmission,
                                    plan: SequencePlan,
                                    intents: [CaptureIntent]) async {
        setPhase(.drainingSubmittedWork)
        let coordinator = self
        await withTaskGroup(of: Void.self) { group in
            group.addTask {
                for await callback in submission.callbacks {
                    await coordinator.handleBracketCallback(callback, intents: intents)
                }
            }
            group.addTask {
                for await outcome in submission.terminal {
                    await coordinator.noteBracketTerminal(outcome)
                }
            }
        }

        if bracketTerminalOutcome == nil {
            requestStop(.failed(CaptureFailure(
                kind: .operationStalled(detail: "The native bracket did not report a terminal result."),
                operation: "sequence.exposureBracket.terminal")))
            return
        }
        if unattributedCallbacks > 0 {
            requestStop(.failed(CaptureFailure(
                kind: .captureFailed(detail: "\(unattributedCallbacks) bracket callback(s) carried an "
                    + "identity that did not match any submitted step."),
                operation: "sequence.exposureBracket.identity")))
        }
    }

    private func noteBracketTerminal(_ outcome: NativeRequestOutcome) {
        if bracketTerminalOutcome == nil {
            bracketTerminalOutcome = outcome
        }
        if case .failed(let failure) = outcome {
            requestStop(.failed(failure))
        }
    }

    private func handleBracketCallback(_ callback: BracketSourceCallback,
                                       intents: [CaptureIntent]) async {
        guard let index = bracketIntentIndex(for: callback.identity, intents: intents) else {
            // Never label a source by arrival order: an identity we cannot map is
            // recorded as an unresolved error, not assigned to the next ordinal.
            unattributedCallbacks += 1
            refreshProgress()
            return
        }
        // Duplicate and late callbacks are handled exactly once.
        guard !seenBracketIdentities.contains(callback.identity) else { return }
        seenBracketIdentities.insert(callback.identity)

        guard let representation = callback.representation else {
            if let status = callback.terminalStatus, !status.isRetained {
                failedOrdinals.insert(index)
                refreshProgress()
            }
            return
        }

        setPhase(.capturing(ordinal: index))
        let outcome = await environment.pipeline.persist(representation, intent: intents[index])
        record(outcome, ordinal: index)
        await persistDocument(status: .running)
        if let failure = outcome.failure {
            requestStop(.failed(failure))
        }
    }

    /// Maps a native callback to the intent that requested it, using the native
    /// identity only.
    private func bracketIntentIndex(for identity: NativeBracketIdentity,
                                    intents: [CaptureIntent]) -> Int? {
        let index = identity.submittedIndex
        guard intents.indices.contains(index) else { return nil }
        let intent = intents[index]
        switch identity.kind {
        case .manualExposure:
            guard let requestedDuration = identity.requestedDurationSeconds,
                  let requestedISO = identity.requestedISO,
                  let expectedDuration = intent.exposure.durationTargetSeconds,
                  let expectedISO = intent.exposure.isoTarget else { return nil }
            let tolerance = max(1e-9, expectedDuration * 1e-6)
            guard abs(requestedDuration - expectedDuration) <= tolerance,
                  abs(requestedISO - expectedISO) <= 1e-6 else { return nil }
            return index
        case .autoExposure, .focus, .single:
            return nil
        }
    }

    // MARK: Focus bracket

    private func executeFocusBracket(plan: SequencePlan,
                                     focus: FocusBracketPlan,
                                     baseline: SequenceBaselineSnapshot?) async {
        let positions = focus.positions
        let longestDuration = baseline?.durationSeconds ?? 0

        for (index, position) in positions.enumerated() {
            if isStopRequested() { break }
            let intent = makeIntent(
                plan: plan,
                ordinal: SourceOrdinal(index),
                mode: .focusBracketSource,
                dimensions: dimensionFallback(nil),
                exposure: baseline?.exposure ?? .auto,
                biasEV: baseline?.biasEV ?? 0,
                focus: FocusIntent(mode: .manual, position: position, pointOfInterest: nil),
                whiteBalance: baseline?.whiteBalance ?? Self.defaultWhiteBalance,
                requestedOffsetEV: nil,
                focusBracketTarget: position,
                deadlineOrdinal: nil)

            let request = FocusFrameRequest(ordinal: SourceOrdinal(index),
                                            requestedPosition: position,
                                            longestPlannedDurationSeconds: longestDuration,
                                            intent: intent)
            let frame = await environment.focusDriver.runFrame(request,
                                                               cancellation: cancellation,
                                                               observer: self)
            focusReadbacks.append(FocusSettleRecord(ordinal: index,
                                                    requestedPosition: frame.requestedPosition,
                                                    settledPosition: frame.settledPosition,
                                                    provenance: frame.provenance))
            if let source = frame.source {
                record(source, ordinal: index)
            } else {
                failedOrdinals.insert(index)
                refreshProgress()
            }
            await persistDocument(status: .running)

            if let failure = frame.failure {
                // A settle timeout stops future frames before an illegal capture
                // and keeps every already-acquired source.
                requestStop(.failed(failure))
                break
            }
        }
    }

    // MARK: - Intent construction

    private static let defaultFocus = FocusIntent(mode: .continuousAuto,
                                                  position: nil,
                                                  pointOfInterest: nil)
    private static let defaultWhiteBalance = WhiteBalanceIntent(mode: .auto,
                                                                temperatureAndTint: nil)

    private func dimensionFallback(_ live: SequenceSettingsSnapshot?) -> PixelDimensions {
        if let applied = appliedBaseline, applied.maxDimensions.isValid {
            return applied.maxDimensions
        }
        if let live, live.maxDimensions.isValid { return live.maxDimensions }
        if let prior = priorSettings, prior.maxDimensions.isValid { return prior.maxDimensions }
        return PixelDimensions(width: 0, height: 0)
    }

    private func makeIntent(plan: SequencePlan,
                            ordinal: SourceOrdinal?,
                            mode: CaptureMode,
                            dimensions: PixelDimensions,
                            exposure: ExposureChoice,
                            biasEV: Double,
                            focus: FocusIntent,
                            whiteBalance: WhiteBalanceIntent,
                            requestedOffsetEV: Double?,
                            focusBracketTarget: Double?,
                            deadlineOrdinal: DeadlineOrdinal?) -> CaptureIntent {
        let now = environment.wallClock.now()
        // A timer run is one source with no sequence document, so it carries no
        // sequence membership.
        let sequenceID: SequenceID? = plan.kind.documentKind == nil ? nil : plan.sequenceID
        return CaptureIntent(
            captureID: CaptureID(),
            libraryID: plan.libraryID,
            sequenceID: sequenceID,
            sequenceOrdinal: ordinal,
            requestedDimensions: dimensions,
            exposure: exposure,
            biasEV: biasEV,
            focus: focus,
            whiteBalance: whiteBalance,
            configurationGeneration: plan.configurationGeneration,
            rootGeneration: plan.rootGeneration,
            physicalCameraKind: plan.physicalCameraKind,
            createdAtUTC: now,
            capturedAtProvenance: .requestTimestamp,
            timezoneOffsetSeconds: environment.wallClock.timeZone.secondsFromGMT(for: now),
            mode: mode,
            deadlineOrdinal: deadlineOrdinal,
            focusBracketTarget: focusBracketTarget,
            requestedOffsetEV: requestedOffsetEV,
            equivalentFocalLengthMM: plan.nominalEquivalentFocalLengthMM,
            // Carried on the intent so the source sidecar is self-contained:
            // SourceSequenceLink.plannedCount comes from the plan itself.
            sequencePlannedCount: plan.plannedSourceCount)
    }

    // MARK: - Baseline settlement

    private func resolveBaseline(plan: SequencePlan,
                                 capability: SequenceCapabilityContext,
                                 prior: SequenceSettingsSnapshot?,
                                 current: ExposureBaseline?) async -> Result<SequenceBaselineSnapshot?,
                                                                                     CaptureFailure> {
        let fallbackExposure = prior?.exposure ?? .auto
        var fallbackFocus = prior?.focus ?? Self.defaultFocus
        let fallbackWhiteBalance = prior?.whiteBalance ?? Self.defaultWhiteBalance
        let dimensions = prior?.maxDimensions ?? PixelDimensions(width: 0, height: 0)
        let bias = prior?.biasEV ?? 0

        switch plan.specification {
        case .timer:
            return .success(nil)

        case .interval:
            // An interval with automatic parameters keeps the chosen Auto mode
            // and snapshots each source's own readings. Nothing numeric is
            // frozen, so there is no baseline to settle.
            return .success(SequenceBaselineSnapshot(
                exposure: fallbackExposure,
                biasEV: bias,
                focus: fallbackFocus,
                whiteBalance: fallbackWhiteBalance,
                maxDimensions: dimensions,
                provenance: .requested,
                stableSampleCount: 0,
                longestPlannedDurationSeconds: 0))

        case .exposureBracket, .focusBracket:
            if let prior, capability.focusLimits.supportsCustomLensPosition, prior.focus.mode != .manual {
                #if DEBUG
                let focusPreparationBegan = environment.clock.now()
                defer { print("TruongCam timing sequence-focus-preparation=\(Int((environment.clock.now() - focusPreparationBegan) * 1000))ms kind=\(plan.kind)") }
                #endif
                let previouslyTouched = settingsTouched
                settingsTouched = true // Native application may partially succeed before failing.
                switch await environment.settings.prepareFocusLockForBaseline(prior) {
                case .failure(let failure): return .failure(failure)
                case .success(let changed):
                    settingsTouched = previouslyTouched || changed
                    if changed, let observed = await environment.settings.snapshotCurrentSettings() {
                        guard observed.configurationGeneration == prior.configurationGeneration,
                              observed.focus.mode == .manual, observed.focus.position != nil else {
                            return .failure(CaptureFailure(kind: .operationStalled(detail: "The bracket focus lock did not produce a current numeric target."), operation: "sequence.prepareBaselineFocus"))
                        }
                        fallbackFocus = observed.focus
                    }
                }
                if isStopRequested() { return .failure(CaptureFailure(kind: .cancelled(detail: "Bracket cancelled while locking focus."), operation: "sequence.prepareBaseline")) }
            }
            let includeFocus = plan.kind == .exposureBracket && prior?.focus.mode != .manual
                && capability.focusLimits.supportsCustomLensPosition
            var requirements: BaselineSettlementRequirements = []
            if fallbackExposure.isDurationAutomatic || fallbackExposure.isISOAutomatic {
                requirements.insert(.exposure)
            }
            if includeFocus {
                requirements.insert(.focus)
            }
            if fallbackWhiteBalance.mode == .auto {
                requirements.insert(.whiteBalance)
            }

            let explicit: ExposureBaseline?
            if case .manual(let duration, let iso) = fallbackExposure {
                explicit = ExposureBaseline(durationSeconds: duration, iso: iso,
                                            biasEV: bias, provenance: .requested)
            } else {
                explicit = nil
            }

            let longest = plan.longestPlannedDurationSeconds(baseline: explicit ?? current)
            let request = BaselineSettlementRequest(
                sequenceID: plan.sequenceID,
                intent: .freezeNumeric,
                requirements: requirements,
                longestPlannedDurationSeconds: longest,
                fallbackExposure: fallbackExposure,
                fallbackFocus: fallbackFocus,
                fallbackWhiteBalance: fallbackWhiteBalance,
                maxDimensions: dimensions,
                explicitBaseline: explicit)

            setPhase(.settlingBaseline)
            switch await environment.baselineSettler.settle(request, cancellation: cancellation) {
            case .success(let snapshot):
                return .success(snapshot)
            case .failure(let failure):
                return .failure(failure.captureFailure)
            }
        }
    }

    // MARK: - Restoration

    private func restorePriorSettings() async -> RestorationStatus {
        guard settingsTouched, let priorSettings else { return .notApplicable }
        setPhase(.restoringSettings)
        switch await environment.settings.restore(priorSettings) {
        case .success:
            return .restored
        case .failure(let failure):
            // Never silently report a failed restoration as restored.
            unresolvedRestorationFailure = failure
            return .failed
        }
    }

    // MARK: - Conclusion

    private func conclude(plan: SequencePlan,
                          stop: SequenceStopReason?,
                          restoration: RestorationStatus,
                          validationErrors: [SequencePlanValidationError]) async -> SequenceRunResult {
        let status = terminalStatus(stop: stop)
        finishProgress(status: status, stop: stop, restoration: restoration)
        await persistDocument(status: status)

        var restorationResult = restoration
        if restoration == .failed {
            let failure = unresolvedRestorationFailure ?? CaptureFailure(
                kind: .restorationFailed(detail: "Camera settings could not be restored."),
                operation: "sequence.restore")
            unresolvedRestorationFailure = failure
            restorationResult = .failed
            runState = .restorationFailed(failure)
        } else {
            runState = .terminal(status, stop?.failure, stop?.interruptionReason)
        }

        let receipts = committedReceipts.keys.sorted().compactMap { committedReceipts[$0] }
        let handles = retainedHandles.keys.sorted().compactMap { retainedHandles[$0] }
        let finalProgress = progress ?? SequenceProgress(
            sequenceID: plan.sequenceID,
            kind: plan.kind,
            plannedCount: plan.plannedSourceCount,
            committedCount: 0,
            retainedCount: 0,
            failedOrdinals: [],
            missingOrdinals: [],
            skippedDeadlineCount: 0,
            deadlineOrdinalsUsed: [],
            unattributedCallbackCount: 0,
            phase: .finished,
            status: status,
            restoration: restorationResult,
            errorSummary: stop?.summary,
            documentWriteFailed: documentWriteFailed,
            bracketPath: plan.exposureBracketPlan?.path,
            baseline: appliedBaseline)

        return SequenceRunResult(
            sequenceID: plan.sequenceID,
            kind: plan.kind,
            status: status,
            progress: finalProgress,
            committedReceipts: receipts,
            retainedHandles: handles,
            focusReadbacks: focusReadbacks,
            restoration: restorationResult,
            failure: stop?.failure,
            validationErrors: validationErrors,
            documentWriteFailed: documentWriteFailed)
    }

    private func terminalStatus(stop: SequenceStopReason?) -> SequenceStatus {
        if let stop { return stop.status }
        guard let current = progress,
              current.committedCount == current.plannedCount,
              failedOrdinals.isEmpty,
              unattributedCallbacks == 0,
              retainedHandles.isEmpty else {
            return .failed
        }
        return .complete
    }

    private func finishProgress(status: SequenceStatus,
                                stop: SequenceStopReason?,
                                restoration: RestorationStatus) {
        guard var current = progress else { return }
        current.status = status
        current.restoration = restoration
        current.phase = .finished
        current.committedCount = committedReceipts.count
        current.retainedCount = committedReceipts.count + retainedHandles.count
        current.failedOrdinals = failedOrdinals.sorted()
        current.missingOrdinals = computedMissingOrdinals()
        current.unattributedCallbackCount = unattributedCallbacks
        current.documentWriteFailed = documentWriteFailed
        current.baseline = appliedBaseline
        current.skippedDeadlineCount = intervalScheduleSnapshot?.skippedDeadlineCount ?? current.skippedDeadlineCount
        current.deadlineOrdinalsUsed = intervalScheduleSnapshot?.usedDeadlineOrdinals ?? current.deadlineOrdinalsUsed
        current.errorSummary = stop?.summary
        progress = current
    }

    // MARK: - Document persistence

    private func persistDocument(status: SequenceStatus) async {
        guard let plan = activePlan, let startedAt = runStartedAtUTC else { return }
        guard (1...MetadataBounds.maxSequenceSources).contains(plan.plannedSourceCount) else { return }
        guard var document = SequenceDocumentBuilder.makeDocument(plan: plan,
                                                                  baseline: appliedBaseline,
                                                                  startedAtUTC: startedAt)
        else { return }

        document.status = status
        document.skippedDeadlineCount = intervalScheduleSnapshot?.skippedDeadlineCount ?? 0
        document.completedSources = committedReceipts.keys.sorted().compactMap { ordinal in
            guard let receipt = committedReceipts[ordinal] else { return nil }
            return SequenceCompletedSource(index: ordinal, captureID: receipt.captureID.rawValue)
        }
        document.failedIndices = failedOrdinals.sorted()
        document.missingIndices = computedMissingOrdinals()
        document.restorationStatus = progress?.restoration ?? .pending
        document.errorSummary = progress?.errorSummary
        document.endedAtUTC = status == .running ? nil : environment.wallClock.now()

        do {
            try await environment.storage.writeSequenceDocument(document)
        } catch {
            // A document failure can never delete or hide an already committed
            // original, and it is recorded so the group rebuilds as incomplete.
            documentWriteFailed = true
            refreshProgress()
        }
    }

    // MARK: - Waiting

    /// Sleeps in bounded slices so cancel/interrupt is observed promptly.
    /// Returns false when the wait stopped before the deadline.
    private func waitUntil(_ deadline: Double) async -> Bool {
        while true {
            if isStopRequested() { return false }
            if Task.isCancelled {
                requestStop(.interrupted(.processDeath))
                return false
            }
            let now = environment.clock.now()
            if now >= deadline { return true }
            let slice = min(deadline,
                            now + max(0.05, environment.cancellationCheckIntervalSeconds))
            try? await environment.clock.sleep(until: slice)
        }
    }

    // MARK: - Rejection

    private func rejected(_ plan: SequencePlan, failure: CaptureFailure) -> SequenceRunResult {
        let rejectedProgress = SequenceProgress(
            sequenceID: plan.sequenceID,
            kind: plan.kind,
            plannedCount: plan.plannedSourceCount,
            committedCount: 0,
            retainedCount: 0,
            failedOrdinals: [],
            missingOrdinals: Self.boundedOrdinals(plan.plannedSourceCount),
            skippedDeadlineCount: 0,
            deadlineOrdinalsUsed: [],
            unattributedCallbackCount: 0,
            phase: .finished,
            status: .failed,
            restoration: unresolvedRestorationFailure == nil ? .notApplicable : .failed,
            errorSummary: failure.description,
            documentWriteFailed: false,
            bracketPath: plan.exposureBracketPlan?.path,
            baseline: nil)

        return SequenceRunResult(
            sequenceID: plan.sequenceID,
            kind: plan.kind,
            status: .failed,
            progress: rejectedProgress,
            committedReceipts: [],
            retainedHandles: [],
            focusReadbacks: [],
            restoration: rejectedProgress.restoration,
            failure: failure,
            validationErrors: [],
            documentWriteFailed: false)
    }
}

// The coordinator is the phase observer for the injected focus driver, so a
// long settle wait still publishes a visible, cancellable settling state.
extension SequenceCoordinator: SequencePhaseObserving {}
