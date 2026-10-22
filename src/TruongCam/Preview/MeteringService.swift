import Foundation

// PREVIEW_TOOLS.md "Shared analysis pipeline" + CONTRACTS.md "Semantic
// interfaces" MeteringService row.
//
// Demand is the UNION of the enabled aids. One submitted sample serves every
// enabled aid; there is no per-tool sample queue. There is in fact no sample
// queue at all: `submit` processes under the actor's serialization, so at most
// one sample is ever processed at a time and nothing can be buffered for replay.
// A sample is dropped rather than queued when
//   * no aid is demanded,
//   * it carries a *different non-zero* configuration/geometry generation than
//     the current demand (the stale-overlay rule, TEST_PLAN.md T35), or
//   * it is older than the last sample that was presented (a late frame can
//     never be shown as the live one, TEST_PLAN.md T37).
//
// A generation of 0 means "the caller did not label this sample". That is not
// evidence of an old generation and the sample is still the newest frame, so it
// is analysed and counted in `acceptedUnspecifiedGenerationSampleCount`; the
// late-sample rule still prevents any older frame from being presented. Emitted
// snapshots are stamped with the demand's own generation, which is the value the
// overlay code compares against.
//
// Outputs are small value snapshots only (`HistogramSnapshot`, `MaskSnapshot`,
// `LoupeSnapshot`, `analysisUnavailable`); the native preview never becomes a
// full-frame image stream. Time-throttling happens before any expensive work.

actor MeteringService {
    /// Bounded diagnostic ring. Tests and status UI read it; production consumers
    /// read `output`. It is not a producer queue and holds at most a handful of
    /// snapshots. Image payloads are discarded as their demand ends or tightens;
    /// scalar diagnostic counters remain independent of that disposable history.
    private static let maxRecentOutputs = 8

    /// Latest-only output stream. Subscribers see the newest snapshots and never
    /// block the analysis path.
    let output: AsyncStream<AnalysisOutput>

    // MARK: Diagnostics
    private(set) var processedSampleCount = 0
    private(set) var droppedNoDemandSampleCount = 0
    private(set) var droppedStaleGenerationSampleCount = 0
    private(set) var droppedLateSampleCount = 0
    /// Samples that arrived without a generation label (generation 0) and were
    /// still the newest frame. The pipeline always labels its samples; this
    /// counter makes an unlabelled caller visible instead of silently dead.
    private(set) var acceptedUnspecifiedGenerationSampleCount = 0
    private(set) var emittedOutputCount = 0
    private(set) var emittedHistogramCount = 0
    private(set) var emittedMaskCount = 0
    private(set) var emittedLoupeCount = 0
    private(set) var emittedUnavailableCount = 0
    private(set) var scratchReleaseCount = 0
    private(set) var lastStatusMessage: String?

    private let clock: MonotonicClock
    private var rateLimits: AnalysisRateLimits
    private var request: AnalysisRequest?
    private var lastEmitInstant: [PreviewAidKind: Double] = [:]
    private var lastProcessedCapturedAt: Date?
    private let scratch = ReusedScratch()
    private var recentOutputs: [AnalysisOutput] = []
    private let continuation: AsyncStream<AnalysisOutput>.Continuation

    init(clock: MonotonicClock, rateLimits: AnalysisRateLimits = .nominal) {
        let (stream, continuation) = AsyncStream<AnalysisOutput>.makeStream(bufferingPolicy: .bufferingNewest(8))
        self.output = stream
        self.continuation = continuation
        self.clock = clock
        self.rateLimits = rateLimits
    }

    deinit {
        continuation.finish()
    }

    // MARK: Demand

    /// Sets the union demand for the current geometry/configuration generation.
    /// Passing nil (or an empty demand) stops all analysis work and releases
    /// scratch: all consumers are off, so no video output should be requested.
    func setDemand(_ newRequest: AnalysisRequest?) async {
        let previous = request
        request = newRequest

        guard let newRequest, !newRequest.demand.isEmpty else {
            recentOutputs.removeAll()
            releaseScratch(reason: "all preview aids are off")
            lastProcessedCapturedAt = nil
            return
        }

        discardRecentImages(loupe: !newRequest.demand.loupeEnabled,
            masks: previous.map {
                ($0.demand.peakingEnabled && !newRequest.demand.peakingEnabled)
                    || ($0.demand.zebrasEnabled && !newRequest.demand.zebrasEnabled)
            } ?? !(newRequest.demand.peakingEnabled || newRequest.demand.zebrasEnabled))

        let generationChanged = previous?.configurationGeneration != newRequest.configurationGeneration
            || previous?.geometry?.layoutGeneration != newRequest.geometry?.layoutGeneration
        if generationChanged {
            // A rotation/lens/format change invalidates both the throttle history
            // and any sample produced for the old geometry, and the first sample
            // of the new generation should emit at once.
            lastEmitInstant.removeAll()
            lastProcessedCapturedAt = nil
        } else if let previous {
            // A newly enabled aid must not inherit the previous aid's throttle.
            if newRequest.demand.histogramEnabled && !previous.demand.histogramEnabled { lastEmitInstant[.histogram] = nil }
            if newRequest.demand.peakingEnabled && !previous.demand.peakingEnabled { lastEmitInstant[.peaking] = nil }
            if newRequest.demand.zebrasEnabled && !previous.demand.zebrasEnabled { lastEmitInstant[.zebras] = nil }
            if newRequest.demand.loupeEnabled && !previous.demand.loupeEnabled { lastEmitInstant[.loupe] = nil }
        }
    }

    /// Applies the policy's update rates (nominal, or reduced under pressure).
    func setRateLimits(_ limits: AnalysisRateLimits) async {
        discardRecentImages(loupe: limits.loupeHz < rateLimits.loupeHz,
            masks: limits.peakingHz < rateLimits.peakingHz || limits.zebraHz < rateLimits.zebraHz)
        rateLimits = limits
    }

    /// Stops analysis: no demand, no output, scratch released. The output stream
    /// stays open so a later `setDemand` can resume without recreating it.
    func stop() async {
        request = nil
        lastEmitInstant.removeAll()
        lastProcessedCapturedAt = nil
        recentOutputs.removeAll()
        releaseScratch(reason: "analysis stopped")
    }

    /// Reports a tool that cannot run for the current preview tuple (for example
    /// an unsupported pixel format). Emits a truthful unavailable snapshot rather
    /// than substituting an old frame.
    func reportAnalysisUnavailable(reason: String) {
        guard let request, !request.demand.isEmpty else { return }
        emit(.analysisUnavailable(reason: reason))
    }

    // MARK: Samples

    /// Submits one downsampled luminance sample for every enabled aid.
    func submit(sample: LuminanceSample) async {
        guard let currentRequest = request, !currentRequest.demand.isEmpty else {
            droppedNoDemandSampleCount += 1
            return
        }
        let configurationMatches = sample.configurationGeneration == currentRequest.configurationGeneration
        guard let requestGeometry = currentRequest.geometry else { return }
        let geometryMatches = sample.geometryGeneration == requestGeometry.layoutGeneration
        // A generation of 0 means the caller did not label the sample. That is not
        // evidence of an old generation, and the sample is still the newest frame,
        // so it must not be discarded silently (the late-sample rule below still
        // prevents an older *frame* from being presented as live). Anything with a
        // different non-zero generation is a stale overlay and is dropped.
        let configurationSpecified = sample.configurationGeneration != .zero
        let geometrySpecified = sample.geometryGeneration != 0
        guard (configurationMatches || !configurationSpecified),
              (geometryMatches || !geometrySpecified) else {
            droppedStaleGenerationSampleCount += 1
            return
        }
        if !configurationSpecified || !geometrySpecified {
            acceptedUnspecifiedGenerationSampleCount += 1
        }
        if let last = lastProcessedCapturedAt, sample.capturedAtUTC <= last {
            // A late sample can never be presented as the live frame.
            droppedLateSampleCount += 1
            return
        }
        process(sample, request: currentRequest)
        lastProcessedCapturedAt = sample.capturedAtUTC
        processedSampleCount += 1
    }

    // MARK: Queries

    var recentOutputsForTesting: [AnalysisOutput] { recentOutputs }
    /// Logical image bytes held by the diagnostic ring, not an allocator/heap
    /// measurement. Already-emitted subscriber/UI values have their own owners.
    var recentImagePayloadByteCount: Int {
        recentOutputs.reduce(0) { total, output in
            switch output {
            case .loupe(let snapshot): total + snapshot.rgbaBytes.count
            case .masks(let snapshot): total + (snapshot.peakingMask?.count ?? 0) + (snapshot.zebraMask?.count ?? 0)
            case .histogram, .analysisUnavailable, .geometryChanged: total
            }
        }
    }
    var currentDemand: AnalysisDemand { request?.demand ?? .none }
    var currentRateLimits: AnalysisRateLimits { rateLimits }
    var scratchRetainedByteCount: Int { scratch.retainedByteCount }
    var isScratchReleased: Bool { scratch.isReleased }
    var scratchBufferGrowthCount: Int { scratch.bufferGrowthCount }
    var analysisPassCount: Int { scratch.passCount }

    // MARK: Processing

    private func process(_ sample: LuminanceSample, request: AnalysisRequest) {
        // Overlays are placed against the request's geometry. `setDemand` refuses a
        // request without geometry, so this is a defensive check rather than a
        // normal path (REVIEW.md S07).
        guard let requestGeometry = request.geometry else { return }
        scratch.markPass()
        let now = clock.now()
        let demand = request.demand

        // Loupe first: it is the aid most likely to be paused under pressure, and
        // it is rendered from the same single sample.
        if demand.loupeEnabled, shouldEmit(.loupe, at: now) {
            lastEmitInstant[.loupe] = now
            let rendered: LoupeSnapshot
            if sample.requiresColorLoupe {
                guard let color = sample.colorLoupe, color.matches(request),
                      color.snapshot.mappedAtUTC == sample.capturedAtUTC else {
                    emit(.analysisUnavailable(reason: "Loupe unavailable for the current preview; no old or monochrome frame is shown."))
                    // Histogram/masks can still describe this current sample.
                    processRemainingAids(sample, request: request, geometry: requestGeometry, now: now)
                    return
                }
                rendered = color.snapshot
            } else {
                // Portable/legacy luminance fixtures have no native color
                // contract. Production native samples always require color.
                rendered = LoupeRenderer.render(sample: sample, center: request.loupeCenter,
                    magnification: request.loupeMagnification, geometry: requestGeometry)
            }
            if rendered.width > 0, rendered.height > 0, !rendered.rgbaBytes.isEmpty {
                emit(.loupe(LoupeSnapshot(width: rendered.width,
                                          height: rendered.height,
                                          rgbaBytes: rendered.rgbaBytes,
                                          geometryGeneration: requestGeometry.layoutGeneration,
                                          configurationGeneration: request.configurationGeneration,
                                          magnification: rendered.magnification,
                                          mappedAtUTC: rendered.mappedAtUTC,
                                          sampledCenter: rendered.sampledCenter)))
            } else {
                emit(.analysisUnavailable(reason: "Loupe unavailable for this geometry; no live loupe frame is shown."))
            }
        }

        processRemainingAids(sample, request: request, geometry: requestGeometry, now: now)
    }

    private func processRemainingAids(_ sample: LuminanceSample, request: AnalysisRequest,
                                      geometry requestGeometry: PreviewGeometrySnapshot, now: Double) {
        let demand = request.demand

        if demand.histogramEnabled, shouldEmit(.histogram, at: now) {
            lastEmitInstant[.histogram] = now
            emit(.histogram(PreviewAnalysisMath.histogram(from: sample,
                                                          configurationGeneration: request.configurationGeneration,
                                                          geometryGeneration: requestGeometry.layoutGeneration)))
        }

        if demand.peakingEnabled || demand.zebrasEnabled, shouldEmitMasks(at: now, demand: demand) {
            lastEmitInstant[.peaking] = now
            lastEmitInstant[.zebras] = now

            var peakingMask: [UInt8]?
            var zebraMask: [UInt8]?
            var unavailable: [String] = []
            if demand.peakingEnabled {
                let mask = PreviewAnalysisMath.peakingMask(from: sample,
                                                           threshold: request.peakingThreshold,
                                                           scratch: scratch)
                if mask.isEmpty {
                    unavailable.append("Focus peaking unavailable for this sample")
                } else {
                    peakingMask = mask
                }
            }
            if demand.zebrasEnabled {
                let mask = PreviewAnalysisMath.zebraMask(from: sample, threshold: request.zebraThreshold)
                if mask.isEmpty {
                    unavailable.append("Preview zebras unavailable for this sample")
                } else {
                    zebraMask = mask
                }
            }

            if peakingMask == nil && zebraMask == nil {
                for reason in unavailable { emit(.analysisUnavailable(reason: reason + "; no live overlay is shown.")) }
            } else {
                let orientedPeaking = peakingMask.map { PreviewMaskOrientation.rotate($0, width: sample.width, height: sample.height, degrees: requestGeometry.analysisRotationDegrees, mirrored: requestGeometry.isMirrored) }
                let orientedZebras = zebraMask.map { PreviewMaskOrientation.rotate($0, width: sample.width, height: sample.height, degrees: requestGeometry.analysisRotationDegrees, mirrored: requestGeometry.isMirrored) }
                let orientedSize = orientedPeaking ?? orientedZebras
                emit(.masks(MaskSnapshot(width: orientedSize?.width ?? sample.width,
                                         height: orientedSize?.height ?? sample.height,
                                         geometryGeneration: requestGeometry.layoutGeneration,
                                         configurationGeneration: request.configurationGeneration,
                                         peakingMask: orientedPeaking?.bytes,
                                         zebraMask: orientedZebras?.bytes,
                                         peakingThreshold: request.peakingThreshold,
                                         zebraThreshold: request.zebraThreshold,
                                         mappedAtUTC: sample.capturedAtUTC)))
                for reason in unavailable { emit(.analysisUnavailable(reason: reason + "; no live overlay is shown.")) }
            }
        }
    }

    /// Throttles one aid. Rates are evaluated before any expensive work.
    private func shouldEmit(_ aid: PreviewAidKind, at instant: Double) -> Bool {
        let interval = rateLimits.interval(for: aid)
        guard interval.isFinite else { return false }
        guard let last = lastEmitInstant[aid] else { return true }
        return instant - last >= interval - 0.001
    }

    /// Peaking and zebras share one mask pass, so the shared snapshot uses the
    /// slowest enabled rate of the two.
    private func shouldEmitMasks(at instant: Double, demand: AnalysisDemand) -> Bool {
        var interval = 0.0
        if demand.peakingEnabled { interval = max(interval, rateLimits.interval(for: .peaking)) }
        if demand.zebrasEnabled { interval = max(interval, rateLimits.interval(for: .zebras)) }
        guard interval.isFinite else { return false }
        var lastMaskEmit: Double?
        if demand.peakingEnabled, let stamp = lastEmitInstant[.peaking] { lastMaskEmit = max(lastMaskEmit ?? stamp, stamp) }
        if demand.zebrasEnabled, let stamp = lastEmitInstant[.zebras] { lastMaskEmit = max(lastMaskEmit ?? stamp, stamp) }
        guard let last = lastMaskEmit else { return true }
        return instant - last >= interval - 0.001
    }

    private func emit(_ output: AnalysisOutput) {
        continuation.yield(output)
        recentOutputs.append(output)
        if recentOutputs.count > MeteringService.maxRecentOutputs {
            recentOutputs.removeFirst(recentOutputs.count - MeteringService.maxRecentOutputs)
        }
        emittedOutputCount += 1
        switch output {
        case .histogram: emittedHistogramCount += 1
        case .masks: emittedMaskCount += 1
        case .loupe: emittedLoupeCount += 1
        case .analysisUnavailable: emittedUnavailableCount += 1
        case .geometryChanged: break
        }
    }

    /// A combined mask snapshot owns both planes, so stopping either mask aid
    /// drops that old diagnostic image rather than retaining its disabled plane.
    /// This changes no output stream, current frame, captured original or count.
    private func discardRecentImages(loupe: Bool, masks: Bool) {
        guard loupe || masks else { return }
        recentOutputs.removeAll { output in
            switch output {
            case .loupe: loupe
            case .masks: masks
            case .histogram, .analysisUnavailable, .geometryChanged: false
            }
        }
    }

    private func releaseScratch(reason: String) {
        let wasAllocated = !scratch.isReleased
        scratch.release()
        if wasAllocated { scratchReleaseCount += 1 }
        lastStatusMessage = "Analysis buffers released (\(reason)); no output is emitted."
    }
}
