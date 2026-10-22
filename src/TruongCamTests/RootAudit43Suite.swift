import Foundation
import CoreMedia
#if canImport(XCTest)
@testable import TruongCam
#endif

enum RootAudit43Suite {
    static let suite = TCSuite(id: "RootAudit43", title: "Async completion and connected sequence recovery", cases: [
        TCCase(id: "RA43T", title: "Immediate expiry cannot lose its waiter or revoke late native completion") { r in
            for _ in 0..<30 {
                let group = SetterCompletionGroup(); group.expectOne()
                r.check("immediate deadline returns false", !(await group.awaitAll(timeoutSeconds: 0)))
                r.check("deadline is not native completion", group.timedOut && !group.isComplete && group.arrived == 0)
                group.arrive(atDeviceTime: CMTime(value: 1, timescale: 60))
                r.check("late callback reconciles", group.isComplete && group.arrived == 1)
                r.check("completed immediate observer wins", await group.awaitAll(timeoutSeconds: 0))
                r.check("completed observer has no stale timeout", !group.timedOut)
            }
            for timeout in [Double.nan, .infinity, -.infinity] {
                let group = SetterCompletionGroup(); group.expectOne()
                r.check("invalid deadline bounded", !(await group.awaitAll(timeoutSeconds: timeout)))
                group.arrive()
            }
        },
        TCCase(id: "RA43W", title: "One timed observer cannot discard another observer or misclassify its arrival") { r in
            let group = SetterCompletionGroup(); group.expectOne(); group.expectOne()
            let late = Task { await group.awaitAll(timeoutSeconds: 5) }
            let unbounded = Task { await group.awaitAll() }
            #if DEBUG || TC_PORTABLE_VERIFIER
            for _ in 0..<1000 {
                if group.installedWaiterCount == 2 { break }
                try? await Task.sleep(for: .milliseconds(1))
            }
            r.equal("both observers installed before expiry", group.installedWaiterCount, 2)
            #endif
            r.check("short observer expires", !(await group.awaitAll(timeoutSeconds: 0)))
            #if DEBUG || TC_PORTABLE_VERIFIER
            r.equal("short deadline preserves other observers", group.installedWaiterCount, 2)
            #endif
            group.arrive(); r.check("one callback remains", !group.isComplete)
            group.arrive()
            r.check("long observer completes", await late.value)
            await unbounded.value
            r.equal("actual callbacks counted", group.arrived, 2)
            r.check("device complete", group.isComplete)
            #if DEBUG || TC_PORTABLE_VERIFIER
            r.equal("every observer reconciled", group.installedWaiterCount, 0)
            #endif
        },
        TCCase(id: "RA43B", title: "Malformed sequence plans reject before allocating progress or acquiring sources") { r in
            for count in [Int.min, -1, 0, 1000, Int.max] {
                let h = SeqHarness()
                let plan = SequencePlan(libraryID: SeqTestSupport.libraryID, configurationGeneration: SeqTestSupport.configurationGeneration,
                    kind: .interval, specification: .interval(IntervalPlan(count: count)), createdAtUTC: SeqTestSupport.nowUTC)
                let result = await h.coordinator.start(plan)
                r.equal("invalid count rejected", result.status, .failed)
                r.equal("no source acquisition", await h.executor.submittedCount, 0)
                r.equal("invalid progress bounded", result.progress.missingOrdinals, [])
                let sequence = SequenceID()
                let document = SequenceDocument(sequenceID: sequence, libraryID: SeqTestSupport.libraryID, kind: .interval,
                    plannedCount: count, sourcePlan: [], intervalSeconds: 5, baseline: nil, startedAtUTC: SeqTestSupport.nowUTC)
                h.store.seed(document)
                if case .failure(let failure) = await h.coordinator.reconcileAfterRestart(sequenceID: sequence) {
                    r.equal("malformed restart rejected", failure.kind.stableCode, "metadataInvalid")
                } else { r.check("malformed restart rejected", false) }
                r.equal("malformed restart never rewritten", h.store.writeCount, 0)
                let malformedLink = SourceSequenceLink(id: sequence, kind: .interval, index: SourceOrdinal(0), plannedCount: count)
                let malformedMetadata = StorageFixture.metadata(captureID: CaptureID(), libraryID: SeqTestSupport.libraryID, sequence: malformedLink)
                r.check("invalid recovered membership bounded", SequenceGroupRebuilder.rebuild(sequenceID: sequence, metadata: [malformedMetadata]) == nil)
                let focus = FocusBracketPlan(count: count)
                r.equal("invalid focus allocation bounded", focus.positions, [])
                r.check("invalid focus label bounded", focus.label(forIndex: Int.max).hasPrefix("Position"))
            }
            let foreignHarness = SeqHarness(), foreignID = SequenceID()
            let foreign = SequenceDocument(sequenceID: foreignID, libraryID: LibraryID(), kind: .interval, plannedCount: 2,
                sourcePlan: [], intervalSeconds: 5, baseline: nil, startedAtUTC: SeqTestSupport.nowUTC)
            foreignHarness.store.seed(foreign)
            if case .failure(let failure) = await foreignHarness.coordinator.reconcileAfterRestart(sequenceID: foreignID) {
                r.equal("foreign library rejected", failure.kind.stableCode, "metadataInvalid")
            } else { r.check("foreign library rejected", false) }
            r.equal("foreign library never rewritten", foreignHarness.store.writeCount, 0)
            let suggestion = ExposureBracketPlan.maximalLegalSuggestion(baselineSeconds: 0.01, stepEV: .leastNonzeroMagnitude,
                limits: ExposureLimits(minDurationSeconds: 0.0001, maxDurationSeconds: 1, minISO: 20, maxISO: 1600, minBiasEV: -3, maxBiasEV: 3))
            r.equal("tiny-step integer conversion bounded", suggestion?.sourceCount, 5)
        },
        TCCase(id: "RA43D", title: "Decoded dimensions cannot overflow mask allocation guards") { r in
            let invalid = PixelDimensions(width: Int.max, height: Int.max)
            r.check("overflow dimensions invalid", !invalid.isValid)
            r.equal("invalid area has no allocation size", invalid.pixelCount, 0)
            r.check("native dimensions remain valid", PixelDimensions(width: 8064, height: 6048).isValid)
        },
        TCCase(id: "RA43P", title: "Only an exact durable pending handle transfers through sequence recovery to verified index publication") { r in
            guard let h = await StorageHarness.make(name: "ra43-pending") else { r.check("fixture", false); return }
            let base = StorageFixture.temporaryDirectory("ra43-index")
            defer { StorageFixture.removeDirectory(base) }
            do {
                let capture = CaptureID()
                let intent = CaptureIntent(captureID: capture, libraryID: h.libraryID, requestedDimensions: PixelDimensions(width: 4032, height: 3024),
                    exposure: .auto, biasEV: 0, focus: FocusIntent(mode: .continuousAuto, position: nil, pointOfInterest: nil),
                    whiteBalance: WhiteBalanceIntent(mode: .auto, temperatureAndTint: nil), configurationGeneration: .zero,
                    rootGeneration: h.generation, physicalCameraKind: .wide, createdAtUTC: StorageFixture.fixedDate, timezoneOffsetSeconds: 0, mode: .single)
                let bytes = StorageFixture.rawBytes()
                let handle = try await h.store.stageSource(bytes: bytes, metadata: StorageFixture.metadata(captureID: capture, libraryID: h.libraryID))
                // Synthetic native-result boundary; actual store/staging/retry/SQLite/model below.
                let pending = CaptureRequestResult(captureID: capture, acquisition: .success, committedReceipts: [],
                    pendingTransactionIDs: [handle.transactionID], failures: [], pendingHandles: [handle])
                let mapped = CaptureSequenceExecutor.executionResult(for: pending, intent: intent)
                r.equal("exact durable handle transferred", mapped.stagedHandle, handle)
                r.check("pending persistence truthful", mapped.persistence.isDurablyStaged)
                r.equal("actual retained path", mapped.failure?.retainedSourceStatus, .durableInternalStaging(relativePath: handle.pendingRelativePath))
                let providerFailure = CaptureFailure(kind: .providerIOFailed(detail: "Held provider failure"), operation: "provider.commit", retainedSourceStatus: .durableInternalStaging(relativePath: handle.pendingRelativePath), nsErrorDomain: "fixture.provider", nsErrorCode: 7, underlyingDescription: "fixture")
                let failedCommit = CaptureRequestResult(captureID: capture, acquisition: .success, committedReceipts: [],
                    pendingTransactionIDs: [handle.transactionID], failures: [providerFailure], pendingHandles: [handle])
                let mappedFailure = CaptureSequenceExecutor.executionResult(for: failedCommit, intent: intent)
                r.equal("existing error gets proven retained ownership", mappedFailure.failure?.retainedSourceStatus, .durableInternalStaging(relativePath: handle.pendingRelativePath))
                r.equal("diagnostic domain retained", mappedFailure.failure?.nsErrorDomain, "fixture.provider")
                r.equal("diagnostic operation retained", mappedFailure.failure?.operation, "provider.commit")
                var stray = pending; stray.pendingHandles = []
                let rejected = CaptureSequenceExecutor.executionResult(for: stray, intent: intent)
                r.check("transaction ID alone is not retention", !rejected.persistence.isDurablyStaged && rejected.stagedHandle == nil)
                let receipt = try await h.store.retry(transactionID: handle.transactionID)
                r.equal("verified retry source identity", receipt.captureID, capture)
                r.equal("unchanged final bytes", h.memory.fileBytes(at: h.finalURL(for: capture)), bytes)
                let index = SQLiteIndex(databaseURL: base.appendingPathComponent("index.sqlite"))
                let session = await LibrarySessionCoordinator(store: h.store, index: index)
                await session.rebuildIndex()
                let model = await LibraryViewModel(index: index, store: h.store)
                await model.loadFirstPage()
                r.equal("verified source published in model", await model.individualOriginalCount, 1)
                await index.closeDatabase()
            } catch { r.check("connected pending recovery", false, String(describing: error)) }
        },
        TCCase(id: "RA43S", title: "Reconnect publishes real reconciled sequence status through SQLite and the library model") { r in
            guard let h = await StorageHarness.make(name: "ra43-sequence-index") else { r.check("fixture", false); return }
            let base = StorageFixture.temporaryDirectory("ra43-sequence-db")
            defer { StorageFixture.removeDirectory(base) }
            do {
                let sequence = SequenceID(), captures = [CaptureID(), CaptureID()]
                for (ordinal, capture) in captures.enumerated() {
                    let link = SourceSequenceLink(id: sequence, kind: .interval, index: SourceOrdinal(ordinal), plannedCount: 2)
                    let handle = try await h.store.stageSource(bytes: StorageFixture.rawBytes(), metadata: StorageFixture.metadata(captureID: capture, libraryID: h.libraryID, sequence: link))
                    _ = try await h.store.commit(handle: handle)
                }
                var doc = SequenceDocument(sequenceID: sequence, libraryID: h.libraryID, kind: .interval, plannedCount: 2,
                    sourcePlan: [], intervalSeconds: 1, baseline: nil, startedAtUTC: StorageFixture.fixedDate)
                doc.completedSources = captures.enumerated().map { SequenceCompletedSource(index: $0.offset, captureID: $0.element.rawValue) }
                doc.status = .complete; doc.endedAtUTC = StorageFixture.fixedDate; doc.restorationStatus = .restored
                try await h.store.writeSequenceDocument(doc)
                let index = SQLiteIndex(databaseURL: base.appendingPathComponent("index.sqlite"))
                let session = await LibrarySessionCoordinator(store: h.store, index: index)
                await session.rebuildIndex()
                let model = await LibraryViewModel(index: index, store: h.store)
                await model.loadFirstPage()
                let groups = await model.dayGroups
                let cards = groups.flatMap(\.cards)
                r.equal("one collapsed sequence cover", cards.count, 1)
                if let card = cards.first, case .sequenceCover(let summary, _) = card.kind {
                    r.equal("actual complete doc reaches index", summary.status, .complete)
                    r.check("complete count retained", summary.isComplete)
                } else { r.check("sequence cover published", false) }
                await index.closeDatabase()
            } catch { r.check("sequence index wiring", false, String(describing: error)) }
        }
    ])
}
