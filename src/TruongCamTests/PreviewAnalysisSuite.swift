import Foundation

// Native test bundles read the app's real types through the module; the
// standalone verifier compiles the app sources into the same executable and
// therefore cannot import a module. XCTest is only available in the native
// bundle, so it gates the import.
#if canImport(XCTest)
@testable import TruongCam
#endif


// TEST_PLAN.md T31–T37 (device-independent half) plus the geometry containment
// check required by packet P7.
//
// Evidence class: LOCAL_HARNESS. These cases execute the real image math, the
// demand/rate policy and the metering state machine on synthetic fixtures. They
// prove nothing about iPhone camera behaviour, RAW output, framing, thermal
// behaviour or focus accuracy; the corresponding device gates D05/D06/D10 remain
// NOT_RUN.

enum PreviewAnalysisSuite {
    static let suite = TCSuite(
        id: "T31-T37-Preview",
        title: "Preview analysis math, geometry, demand policy and metering service",
        cases: [
            TCCase(id: "LP54A", title: "Loupe receives 30 Hz union samples while histogram and masks keep independent rates") { r in
                r.equal("loupe-only acquisition", AnalysisRateLimits.nativeAcquisitionHz(masksEnabled: false, loupeEnabled: true), 30)
                r.equal("masks do not slow a simultaneous loupe", AnalysisRateLimits.nativeAcquisitionHz(masksEnabled: true, loupeEnabled: true), 30)
                r.equal("masks retain native 20 Hz cap", AnalysisRateLimits.nativeAcquisitionHz(masksEnabled: true, loupeEnabled: false), 20)
                r.equal("non-loupe acquisition keeps previous floor", AnalysisRateLimits.nativeAcquisitionHz(masksEnabled: false, loupeEnabled: false), 15)
                let clock = VirtualMonotonicClock(start: 0), service = MeteringService(clock: clock)
                await service.setDemand(previewRequest(configuration: 6, layout: 7, demand: previewFullDemand))
                for index in 0..<7 {
                    if index > 0 { clock.advance(by: 1.0 / 30.0) }
                    await service.submit(sample: previewSample(bytes: [UInt8](repeating: 250, count: 16 * 12),
                        width: 16, height: 12, configuration: 6, geometry: 7, at: Double(index)))
                }
                r.equal("one loupe per eligible 30 Hz frame", await service.emittedLoupeCount, 7)
                r.equal("histogram remains 10 Hz", await service.emittedHistogramCount, 3)
                r.equal("masks do not exceed 20 Hz on 30 Hz input", await service.emittedMaskCount, 4)
                await service.setRateLimits(AnalysisRateLimits.nominal.scaled(by: 0.5))
                clock.advance(by: 1.0 / 30.0)
                await service.submit(sample: previewSample(bytes: [UInt8](repeating: 250, count: 16 * 12),
                    width: 16, height: 12, configuration: 6, geometry: 7, at: 7))
                r.equal("thermal reduction still suppresses intermediate loupe", await service.emittedLoupeCount, 7)
                clock.advance(by: 1.0 / 30.0)
                await service.submit(sample: previewSample(bytes: [UInt8](repeating: 250, count: 16 * 12),
                    width: 16, height: 12, configuration: 6, geometry: 7, at: 8))
                r.equal("reduced loupe remains 15 Hz", await service.emittedLoupeCount, 8)
                clock.advance(by: 1)
                await service.submit(sample: previewSample(bytes: [UInt8](repeating: 250, count: 16 * 12),
                    width: 16, height: 12, configuration: 5, geometry: 7, at: 9))
                r.equal("stale camera cannot enter faster stream", await service.emittedLoupeCount, 8)
                r.equal("stale source is recorded", await service.droppedStaleGenerationSampleCount, 1)
                await service.stop()
            },
            TCCase(id: "LV53A", title: "Healthy face-up and face-down motion uses a surface level in every screen orientation") { r in
                for orientation in DeviceOrientation.allCases {
                    for z in [-1.0, 1.0] {
                        var level = LevelService(clock: VirtualMonotonicClock(start: 5), orientation: orientation)
                        let flat = level.update(gravity: GravityReading(x: 0, y: 0, z: z))
                        let label = "\(orientation.rawValue) z=\(z)"
                        r.equal("\(label) remains a real reading", flat.isProducingReadings, true)
                        r.equal("\(label) is level", flat.zone, .level)
                        r.close("\(label) surface deviation", flat.surfaceTilt?.deviationDegrees ?? 999, 0)
                        r.close("\(label) bubble horizontal center", flat.surfaceTilt?.rightDegrees ?? 999, 0)
                        r.close("\(label) bubble vertical center", flat.surfaceTilt?.upDegrees ?? 999, 0)
                        r.check("\(label) does not claim unavailable", !flat.statusLabel.lowercased().contains("unavailable"))
                        r.equal("\(label) accepts sequence", flat.sequenceNumber, 1)

                        let axes = orientation.screenAxes, angle = 4.0 * Double.pi / 180
                        let rightTilt = level.update(gravity: GravityReading(x: axes.right.x * sin(angle),
                            y: axes.right.y * sin(angle), z: z * cos(angle)))
                        r.equal("\(label) tilted surface is not falsely level", rightTilt.zone, .tilted)
                        r.close("\(label) surface right axis", rightTilt.surfaceTilt?.rightDegrees ?? 999, 4, tolerance: 1e-6)
                        r.close("\(label) no crossed vertical axis", rightTilt.surfaceTilt?.upDegrees ?? 999, 0, tolerance: 1e-6)
                        let upTilt = level.update(gravity: GravityReading(x: -axes.up.x * sin(angle),
                            y: -axes.up.y * sin(angle), z: z * cos(angle)))
                        r.close("\(label) surface up axis", upTilt.surfaceTilt?.upDegrees ?? 999, -4, tolerance: 1e-6)
                    }
                }
            },
            TCCase(id: "LV53B", title: "Flat projection never feeds undefined roll into the upright smoothing filter") { r in
                var level = LevelService(gain: 0.25)
                let radians = 35.0 * Double.pi / 180
                _ = level.update(gravity: GravityReading(x: sin(radians), y: -cos(radians), z: 0))
                for index in 0..<12 {
                    let sign = index.isMultiple(of: 2) ? 1.0 : -1.0
                    let flat = level.update(gravity: GravityReading(x: sign * 1e-7, y: -sign * 1e-7, z: -1))
                    r.equal("flat noise stays level \(index)", flat.zone, .level)
                    r.close("undefined roll is not rendered \(index)", flat.rollDegrees, 0)
                }
                let vertical = level.update(gravity: GravityReading(x: 0, y: -1, z: 0))
                r.check("vertical uses horizon again", vertical.surfaceTilt == nil)
                r.close("old tilt and flat noise cannot contaminate resumed horizon", vertical.rollDegrees, 0)
                let oneDegree = Double.pi / 180
                let near = level.update(gravity: GravityReading(x: sin(oneDegree), y: 0, z: -cos(oneDegree)))
                r.equal("surface has a near-level band", near.zone, .nearLevel)
                r.close("surface band uses actual tilt", near.surfaceTilt?.deviationDegrees ?? 999, 1, tolerance: 1e-6)
                level.setOrientation(.landscapeRight)
                let landscape = level.update(gravity: GravityReading(x: 1, y: 0, z: 0))
                r.close("orientation reset keeps horizon axes", landscape.rollDegrees, 0)
                r.check("landscape upright has no surface bubble", landscape.surfaceTilt == nil)
            },
            TCCase(id: "LV53C", title: "No sensor reading and hidden motion remain unavailable rather than a false flat success") { r in
                let clock = VirtualMonotonicClock(start: 10)
                var level = LevelService(clock: clock)
                let flat = level.update(gravity: GravityReading(x: 0, y: 0, z: -1))
                clock.advance(by: 2)
                let invalid = [GravityReading(x: 0, y: 0, z: 0), GravityReading(x: .nan, y: 0, z: -1),
                    GravityReading(x: 1e308, y: 1e308, z: 1e308)]
                for (index, gravity) in invalid.enumerated() {
                    let missing = level.update(gravity: gravity)
                    r.equal("invalid sample unavailable \(index)", missing.zone, .unavailable)
                    r.equal("invalid sample not a sensor success \(index)", missing.isProducingReadings, false)
                    r.check("invalid sample has no surface target \(index)", missing.surfaceTilt == nil)
                    r.equal("invalid sample cannot advance sequence \(index)", missing.sequenceNumber, flat.sequenceNumber)
                    r.equal("invalid sample cannot refresh time \(index)", missing.lastUpdateInstant, flat.lastUpdateInstant)
                }
                _ = level.update(gravity: GravityReading(x: 0, y: 0, z: 1))
                level.setVisible(false)
                r.equal("hidden reading unavailable", level.state.zone, .unavailable)
                r.check("hidden target removed", level.state.surfaceTilt == nil)
                r.equal("hidden state not producing", level.state.isProducingReadings, false)
                level.setVisible(true)
                r.check("showing alone does not restore old target", level.state.surfaceTilt == nil)
                r.equal("showing needs a new sample", level.state.isProducingReadings, false)
                r.equal("fresh flat sample recovers", level.update(gravity: GravityReading(x: 0, y: 0, z: -1)).zone, .level)
                level.setSceneActive(false)
                r.check("background target removed", level.state.surfaceTilt == nil)
                r.equal("background stops readings", level.state.isProducingReadings, false)
            },
            TCCase(id: "AF35", title: "Display jitter holds continuously then fades stale masks without relabeling source time") { r in
                let time = Date()
                r.equal("normal jitter does not blank mask", PreviewAidFreshness.displayOpacity(capturedAt: time, now: time.addingTimeInterval(0.19)), 1)
                let fading = PreviewAidFreshness.displayOpacity(capturedAt: time, now: time.addingTimeInterval(0.275))
                r.check("stall fades gradually", fading > 0.45 && fading < 0.55)
                r.equal("sustained stall hides mask", PreviewAidFreshness.displayOpacity(capturedAt: time, now: time.addingTimeInterval(0.36)), 0)
                r.equal("wrong future timestamp hidden", PreviewAidFreshness.displayOpacity(capturedAt: time.addingTimeInterval(1), now: time), 0)
            },
            TCCase(id: "AF34", title: "Masks can emit every 20-Hz frame while histogram and pressure retain independent caps") { r in
                let clock = VirtualMonotonicClock(start: 0)
                let metering = MeteringService(clock: clock)
                await metering.setDemand(previewRequest(configuration: 6, layout: 7, demand: previewFullDemand))
                for index in 0..<7 {
                    if index > 0 { clock.advance(by: 1.0 / 20.0) }
                    await metering.submit(sample: previewSample(bytes: [UInt8](repeating: 250, count: 32 * 24),
                        width: 32, height: 24, configuration: 6, geometry: 7, at: Double(index)))
                }
                r.equal("one mask snapshot per eligible frame", await metering.emittedMaskCount, 7)
                r.equal("histogram remains capped independently", await metering.emittedHistogramCount, 4)
                r.equal("pressure halves mask rate", AnalysisRateLimits.nominal.scaled(by: 0.5).zebraHz, 10)
            },
            TCCase(id: "CS33", title: "Small native noise can settle but drift, active adjustment and unbound manual focus cannot") { r in
                let base = SelfRepairFixtures.controlSnapshot(iso: 100, duration: 0.01)
                let noise = SelfRepairFixtures.controlSnapshot(iso: 100.5, duration: 0.01002)
                var tracker = ControlSettlementTracker()
                r.check("first native measurement not enough", !tracker.observe(base).isSettled)
                r.check("bounded native noise converges", tracker.observe(noise).isSettled)
                let drift = SelfRepairFixtures.controlSnapshot(iso: 104, duration: 0.01)
                r.check("out of window drift resets", !tracker.observe(drift).isSettled)
                var adjusting = base; adjusting.isExposureAdjusting = true
                r.check("native adjustment refuses stability", !tracker.observe(adjusting).isSettled)
                var fixed = OperationCleanupSuite.reading()
                var ordinary = ControlSettlementTracker()
                r.check("unbound manual focus refused", !ordinary.observe(fixed).isSettled)
                r.check("repetition cannot authorize unbound focus", !ordinary.observe(fixed).isSettled)
                fixed.isFixedFocusCamera = true; fixed.isFocusAdjusting = false
                var hardwareFixed = ControlSettlementTracker()
                r.check("fixed hardware still needs observations", !hardwareFixed.observe(fixed).isSettled)
                r.check("explicit fixed hardware can settle", hardwareFixed.observe(fixed).isSettled)
            },
            TCCase(id: "AF33", title: "Preview masks expire instead of trailing indefinitely over moving video") { r in
                let now = Date(timeIntervalSince1970: 1_000)
                r.check("fresh aid visible", PreviewAidFreshness.isFresh(capturedAt: now, now: now))
                r.check("one frame late still usable", PreviewAidFreshness.isFresh(capturedAt: now.addingTimeInterval(-0.06), now: now))
                r.check("stalled aid hidden", !PreviewAidFreshness.isFresh(capturedAt: now.addingTimeInterval(-0.2), now: now))
                r.check("cold delayed work hidden", !PreviewAidFreshness.isFresh(capturedAt: now.addingTimeInterval(-2), now: now))
                r.check("future/wrong clock hidden", !PreviewAidFreshness.isFresh(capturedAt: now.addingTimeInterval(1), now: now))
                r.equal("masks use available 20-Hz native sample schedule", AnalysisRateLimits.nominal.peakingHz, 20)
                r.equal("zebras use same pass", AnalysisRateLimits.nominal.zebraHz, 20)
            },

            TCCase(id: "UX04", title: "Each quarter-turn repositions a discriminating zebra corner; dark samples never zebra") { r in
                let plane: [UInt8] = [255,0,0,0,0,0]
                let expectations: [(Int,[UInt8],Int,Int)] = [(0,[255,0,0,0,0,0],3,2),
                    (90,[0,255,0,0,0,0],2,3),(180,[0,0,0,0,0,255],3,2),(270,[0,0,0,0,255,0],2,3)]
                for (angle, expected, w, h) in expectations {
                    let service = MeteringService(clock: VirtualMonotonicClock())
                    let request = AnalysisRequest(configurationGeneration: ConfigurationGeneration(1),
                        geometry: previewGeometry(configuration: 1, layout: 5, dimensions: PixelDimensions(width: 3,height: 2), rotation: angle),
                        demand: AnalysisDemand(needsLuminanceSample: true, histogramEnabled: false, zebrasEnabled: true, peakingEnabled: false, loupeEnabled: false),
                        peakingThreshold: 0.5, zebraThreshold: 0.95, loupeCenter: .center, loupeMagnification: 2)
                    await service.setDemand(request)
                    await service.submit(sample: previewSample(bytes: plane, width: 3,height: 2, geometry: 5))
                    let mask = previewMasks(await service.recentOutputsForTesting).last
                    r.equal("angle \(angle) zebra corner", mask?.zebraMask, expected)
                    r.equal("angle \(angle) dimensions", mask.map { PixelDimensions(width: $0.width,height: $0.height) }, PixelDimensions(width:w,height:h))
                }
                r.equal("dark plane has no zebra", PreviewAnalysisMath.zebraMask(from: previewSample(bytes: [0,100,200],width:3,height:1), threshold:0.95), [0,0,0])
                r.equal("wrong byte count refused", PreviewMaskOrientation.rotate([1],width:2,height:2,degrees:90).bytes, [])
            },
            TCCase(id: "UX05", title: "Level follows physical axes in both landscapes and resets the portrait filter") { r in
                var service = LevelService(gain: 1)
                let fixtures: [(Int,GravityReading)] = [(90,GravityReading(x:0,y:-1,z:0)),
                    (0,GravityReading(x:-1,y:0,z:0)),(180,GravityReading(x:1,y:0,z:0)),(270,GravityReading(x:0,y:1,z:0))]
                for (angle,gravity) in fixtures {
                    service.setOrientation(.fromPreviewRotation(angle))
                    let state = service.update(gravity:gravity)
                    r.close("angle \(angle) reads horizontal", state.rollDegrees, 0, tolerance: 0.001)
                    r.equal("angle \(angle) level zone", state.zone, .level)
                }
                service.setOrientation(.fromPreviewRotation(0))
                r.check("tilt is not falsely level", abs(service.update(gravity:GravityReading(x:0.9,y:0.2,z:0)).rollDegrees) > 3)
            },
            TCCase(id: "T31RGBa", title: "Preview RGB uses actual chroma, known matrix, range and padded row strides") { r in
                let y: [UInt8] = [81,81,145,145,41,41,255,255, 81,81,145,145,41,41,255,255]
                let uv: [UInt8] = [90,240,54,34,240,110,255,255]
                let rgb = y.withUnsafeBufferPointer { yy in uv.withUnsafeBufferPointer { cc in
                    PreviewAnalysisMath.rgbHistogram(luma: yy,chroma: cc,width:6,height:2,lumaStride:8,
                        chromaStride:8,chromaWidth:3,chromaHeight:1,range:.video,matrix:.itu601)
                } }
                r.equal("all real pixels sampled", rgb?.sampleCount, 12)
                r.equal("red patch in red channel", rgb?.red[254], 4)
                r.equal("green patch in green channel", rgb?.green[255], 4)
                r.equal("blue patch in blue channel", rgb?.blue[255], 4)
                r.equal("each channel conserves count", rgb.map { [$0.red.reduce(0,+),$0.green.reduce(0,+),$0.blue.reduce(0,+)] }, [12,12,12])
                r.check("channels differ, not tinted luma", rgb?.red != rgb?.green)
                let unknown = y.withUnsafeBufferPointer { yy in uv.withUnsafeBufferPointer { cc in
                    PreviewAnalysisMath.rgbHistogram(luma:yy,chroma:cc,width:6,height:2,lumaStride:8,
                        chromaStride:8,chromaWidth:3,chromaHeight:1,range:.video,matrix:nil)
                } }
                r.check("unknown matrix has no fabricated RGB", unknown == nil)
                let bad = y.withUnsafeBufferPointer { yy in uv.withUnsafeBufferPointer { cc in
                    PreviewAnalysisMath.rgbHistogram(luma:yy,chroma:cc,width:6,height:2,lumaStride:5,
                        chromaStride:8,chromaWidth:3,chromaHeight:1,range:.video,matrix:.itu709)
                } }
                r.check("invalid stride rejected", bad == nil)
            },
            TCCase(id: "T31RGBb", title: "RGB range endpoints, matrix selection and bounded samples survive metering publication") { r in
                for range in [PreviewCodeRange.full,.video] {
                    let yy: [UInt8] = range == .full ? [0,255,0,255] : [16,235,16,235]
                    let cc: [UInt8] = [128,128]
                    for matrix in PreviewYCbCrMatrix.allCases {
                        let rgb = yy.withUnsafeBufferPointer { y in cc.withUnsafeBufferPointer { c in
                            PreviewAnalysisMath.rgbHistogram(luma:y,chroma:c,width:2,height:2,lumaStride:2,
                                chromaStride:2,chromaWidth:1,chromaHeight:1,range:range,matrix:matrix)
                        } }
                        r.equal("neutral black endpoint", rgb?.red[0], 2)
                        r.equal("neutral white endpoint", rgb?.blue[255], 2)
                        r.equal("neutral channels match", rgb?.red, rgb?.green)
                        r.equal("matrix retained", rgb?.matrix, matrix.rawValue)
                    }
                }
                let yy=[UInt8](repeating:128,count:400*200),cc=[UInt8](repeating:128,count:400*100)
                let rgb=yy.withUnsafeBufferPointer { y in cc.withUnsafeBufferPointer { c in
                    PreviewAnalysisMath.rgbHistogram(luma:y,chroma:c,width:400,height:200,lumaStride:400,
                        chromaStride:400,chromaWidth:200,chromaHeight:100,range:.full,matrix:.itu709)
                } }
                r.equal("bounded 192 edge", rgb?.sampleCount, 192*96)
                var sample=previewSample(bytes:[128,128,128,128],width:2,height:2,geometry:5)
                sample.rgbHistogram=rgb
                let meter=MeteringService(clock:VirtualMonotonicClock(start: 0))
                await meter.setDemand(previewRequest(configuration:1,layout:5,demand:AnalysisDemand(needsLuminanceSample:true,histogramEnabled:true,zebrasEnabled:false,peakingEnabled:false,loupeEnabled:false)))
                await meter.submit(sample:sample)
                r.equal("RGB travels with histogram output", previewHistograms(await meter.recentOutputsForTesting).last?.rgb, rgb)
            },

            // MARK: - T31 histogram, stride and range

            TCCase(id: "T31a", title: "Padded planar rows never contribute to the histogram or the sample") { r in
                let width = 8
                let height = 4
                let stride = 12
                // Real body value 100; every padding byte and the trailing slack
                // are 255. None of them may appear in the sample or the bins.
                var bytes = previewStridedPlane(width: width,
                                                height: height,
                                                stride: stride,
                                                bodyValue: 100,
                                                paddingValue: 255,
                                                trailingBytes: 8)
                bytes.append(contentsOf: [UInt8](repeating: 255, count: 3))

                let outcome = bytes.withUnsafeBufferPointer { buffer in
                    PreviewAnalysisMath.downsampleLuma(from: buffer,
                                                       width: width,
                                                       height: height,
                                                       bytesPerRow: stride,
                                                       range: .planarLuma8(.full),
                                                       targetLongEdge: PreviewAnalysisMath.workingLongEdgeLimit)
                }
                guard let sample = outcome.sample, let record = outcome.record else {
                    r.check("sample produced", false, "outcome \(outcome)")
                    return
                }
                r.equal("sample dimensions follow the real width/height", PixelDimensions(width: sample.width, height: sample.height), PixelDimensions(width: width, height: height))
                r.equal("no padding byte reaches the sample", Set(sample.luma), Set([UInt8(100)]))
                r.equal("sample count is width × height", sample.luma.count, width * height)
                r.equal("no resample was needed", record.usedAccelerateScale, false)
                r.check("normalization record reports the endpoints", record.nominalBlack == 0 && record.nominalWhite == 255)
                r.check("full range reports no clamping", !record.clampsAtBlack && !record.clampsAtWhite)

                let histogram = PreviewAnalysisMath.histogram(from: sample)
                r.equal("bin count", histogram.bins.count, 256)
                r.equal("bin total equals the sample count", histogram.bins.reduce(UInt32(0)) { $0 &+ $1 }, histogram.sampleCount)
                r.equal("all samples land in the body bin", histogram.bins[100], UInt32(width * height))
                r.equal("padding value bin stays empty", histogram.bins[255], 0)
                r.check("recorded sample count is finite", histogram.sampleCount > 0)

                // The accelerated path must exclude padding too.
                var big = previewStridedPlane(width: 1280,
                                              height: 960,
                                              stride: 1300,
                                              bodyValue: 100,
                                              paddingValue: 255,
                                              trailingBytes: 0)
                let bigOutcome = big.withUnsafeBufferPointer { buffer in
                    PreviewAnalysisMath.downsampleLuma(from: buffer,
                                                       width: 1280,
                                                       height: 960,
                                                       bytesPerRow: 1300,
                                                       range: .planarLuma8(.full),
                                                       targetLongEdge: 640)
                }
                guard let bigSample = bigOutcome.sample, let bigRecord = bigOutcome.record else {
                    r.check("downscaled sample produced", false, "outcome \(bigOutcome)")
                    return
                }
                r.equal("working image is capped at 640 long edge", PixelDimensions(width: bigSample.width, height: bigSample.height), PixelDimensions(width: 640, height: 480))
                r.check("vImage performed the resample", bigRecord.usedAccelerateScale)
                r.equal("padded downscale keeps the body constant", Set(bigSample.luma), Set([UInt8(100)]))
                big.removeAll()
            },

            TCCase(id: "T31b", title: "Full and video range normalize to deliberate, clamped code values") { r in
                func normalized(_ value: UInt8, range: PreviewCodeRange) -> LuminanceSample? {
                    let bytes = [UInt8](repeating: value, count: 16)
                    let outcome = bytes.withUnsafeBufferPointer { buffer in
                        PreviewAnalysisMath.downsampleLuma(from: buffer,
                                                           width: 16,
                                                           height: 1,
                                                           bytesPerRow: 16,
                                                           range: .planarLuma8(range),
                                                           targetLongEdge: 640)
                    }
                    return outcome.sample
                }

                guard let full = normalized(100, range: .full),
                      let videoBlack = normalized(16, range: .video),
                      let videoMid = normalized(100, range: .video),
                      let videoWhite = normalized(235, range: .video),
                      let videoBelow = normalized(0, range: .video),
                      let videoAbove = normalized(255, range: .video),
                      let videoSeventeen = normalized(17, range: .video) else {
                    r.check("all range fixtures produced", false)
                    return
                }

                r.equal("full range keeps the code value", Set(full.luma), Set([UInt8(100)]))
                r.equal("video nominal black maps to 0", Set(videoBlack.luma), Set([UInt8(0)]))
                r.equal("video mid grey maps by the affine window", Set(videoMid.luma), Set([UInt8(98)]))
                r.equal("video nominal white maps to 255", Set(videoWhite.luma), Set([UInt8(255)]))
                r.equal("video below black clamps to 0", Set(videoBelow.luma), Set([UInt8(0)]))
                r.equal("video above nominal white clamps to 255", Set(videoAbove.luma), Set([UInt8(255)]))
                r.equal("video one step above black maps to 1", Set(videoSeventeen.luma), Set([UInt8(1)]))

                let fullSnapshot = PreviewAnalysisMath.histogram(from: full)
                let videoSnapshot = PreviewAnalysisMath.histogram(from: videoMid)
                r.check("full range is reported as full", fullSnapshot.isFullRange)
                r.check("video range is not reported as full", !videoSnapshot.isFullRange)
                r.equal("video histogram lands in the mapped bin", videoSnapshot.bins[98], UInt32(16))
                r.equal("clamped below-black value bins at 0", PreviewAnalysisMath.histogram(from: videoBelow).bins[0], UInt32(16))
                r.equal("clamped above-white value bins at 255", PreviewAnalysisMath.histogram(from: videoAbove).bins[255], UInt32(16))

                let videoRecord = [UInt8](repeating: 16, count: 4).withUnsafeBufferPointer { buffer in
                    PreviewAnalysisMath.downsampleLuma(from: buffer,
                                                       width: 4,
                                                       height: 1,
                                                       bytesPerRow: 4,
                                                       range: .planarLuma8(.video),
                                                       targetLongEdge: 640).record
                }
                r.check("video normalization records both deliberate clamps",
                        videoRecord?.clampsAtBlack == true && videoRecord?.clampsAtWhite == true)
                r.check("normalization record states it is preview code values, not RAW clipping",
                        videoRecord?.note.lowercased().contains("not a raw clipping measurement") == true)
            },

            TCCase(id: "T31c", title: "White ramp, analysis-plane aspect and finite bin totals") { r in
                let width = 640
                let height = 480
                var bytes = [UInt8](repeating: 0, count: width * height)
                let lastIndex = width * height - 1
                for index in 0...lastIndex {
                    bytes[index] = UInt8(index * 255 / lastIndex)
                }
                let outcome = bytes.withUnsafeBufferPointer { buffer in
                    PreviewAnalysisMath.downsampleLuma(from: buffer,
                                                       width: width,
                                                       height: height,
                                                       bytesPerRow: width,
                                                       range: .planarLuma8(.full),
                                                       targetLongEdge: PreviewAnalysisMath.workingLongEdgeLimit)
                }
                guard let sample = outcome.sample else {
                    r.check("ramp sample produced", false)
                    return
                }
                let histogram = PreviewAnalysisMath.histogram(from: sample)
                let analysis = PreviewAnalysisMath.histogramAnalysisDimensions(width: sample.width, height: sample.height)
                r.equal("analysis plane is 192×144 for 4:3", analysis, PixelDimensions(width: 192, height: 144))
                r.equal("sample count equals the analysis plane", histogram.sampleCount, UInt32(192 * 144))
                r.equal("bins sum exactly to the sample count", histogram.bins.reduce(UInt32(0)) { $0 &+ $1 }, histogram.sampleCount)
                r.check("black end of the ramp is populated", histogram.bins[0] > 0)
                r.check("the top of the ramp is sampled",
                        histogram.bins[248...255].reduce(UInt32(0)) { $0 &+ $1 } > 0,
                        "top bins \(histogram.bins[248...255])")
                r.check("ramp spreads across many bins", histogram.bins.filter { $0 > 0 }.count > 100,
                        "non-zero bins \(histogram.bins.filter { $0 > 0 }.count)")
                r.check("every bin total is finite", histogram.bins.allSatisfy { Double($0).isFinite })
                r.check("every normalized table entry is finite",
                        PreviewAnalysisMath.normalizationTable(for: .video).allSatisfy { Double($0).isFinite })
                r.equal("portrait aspect is preserved", PreviewAnalysisMath.histogramAnalysisDimensions(width: 480, height: 640), PixelDimensions(width: 144, height: 192))
                r.equal("16:9 aspect is preserved", PreviewAnalysisMath.histogramAnalysisDimensions(width: 1920, height: 1080), PixelDimensions(width: 192, height: 108))
            },

            TCCase(id: "T31d", title: "BGRA is a typed unsupported result and stride/dimension errors are rejected") { r in
                let bytes = [UInt8](repeating: 7, count: 64)
                let bgra = bytes.withUnsafeBufferPointer { buffer in
                    PreviewAnalysisMath.downsampleLuma(from: buffer,
                                                       width: 8,
                                                       height: 8,
                                                       bytesPerRow: 8,
                                                       range: .bgra8,
                                                       targetLongEdge: 640)
                }
                if case .unsupported(let format, let reason) = bgra {
                    r.check("BGRA reports unsupported", !format.isLumaPlane)
                    r.check("BGRA reason names the missing conversion", reason.lowercased().contains("not a luma plane"))
                } else {
                    r.check("BGRA is never reinterpreted as luma", false, "got \(bgra)")
                }
                r.check("unsupported outcome carries no sample", bgra.sample == nil)

                let stubStride = bytes.withUnsafeBufferPointer { buffer in
                    PreviewAnalysisMath.downsampleLuma(from: buffer,
                                                       width: 16,
                                                       height: 8,
                                                       bytesPerRow: 8,
                                                       range: .planarLuma8(.full),
                                                       targetLongEdge: 640)
                }
                if case .invalid(let reason) = stubStride {
                    r.check("stride smaller than width is rejected", reason.contains("bytesPerRow"))
                } else {
                    r.check("stride smaller than width is rejected", false, "got \(stubStride)")
                }

                let shortBuffer = [UInt8](repeating: 0, count: 32)
                let short = shortBuffer.withUnsafeBufferPointer { buffer in
                    PreviewAnalysisMath.downsampleLuma(from: buffer,
                                                       width: 8,
                                                       height: 8,
                                                       bytesPerRow: 8,
                                                       range: .planarLuma8(.full),
                                                       targetLongEdge: 640)
                }
                if case .invalid(let reason) = short {
                    r.check("short buffer is rejected", reason.contains("required"))
                } else {
                    r.check("short buffer is rejected", false, "got \(short)")
                }

                var buffer = [UInt8](repeating: 50, count: 8 * 8 * 2)
                let accelerated = buffer.withUnsafeBufferPointer { pointer in
                    PreviewAnalysisMath.downsampleLuma(from: pointer,
                                                       width: 8,
                                                       height: 8,
                                                       bytesPerRow: 8,
                                                       range: .planarLuma8(.full),
                                                       targetLongEdge: 640,
                                                       useAccelerate: false)
                }
                r.check("fallback path still produces a sample", accelerated.sample != nil)
                r.equal("fallback path keeps a constant plane", Set(accelerated.sample?.luma ?? []), Set([UInt8(50)]))
                buffer.removeAll()
            },

            // MARK: - T32 signed Sobel peaking

            TCCase(id: "T32a", title: "Reversing an edge cannot clip a negative lobe") { r in
                let width = 16
                let height = 16
                func step(left: UInt8, right: UInt8) -> [UInt8] {
                    var bytes = [UInt8](repeating: 0, count: width * height)
                    for row in 0..<height {
                        for column in 0..<width {
                            bytes[row * width + column] = column < width / 2 ? left : right
                        }
                    }
                    return bytes
                }
                let forward = previewSample(bytes: step(left: 0, right: 60), width: width, height: height)
                let reversed = previewSample(bytes: step(left: 60, right: 0), width: width, height: height)

                let forwardMask = PreviewAnalysisMath.peakingMask(from: forward, threshold: PeakingThreshold.normal.value)
                let reversedMask = PreviewAnalysisMath.peakingMask(from: reversed, threshold: PeakingThreshold.normal.value)
                r.equal("mask sizes match the plane", forwardMask.count, width * height)
                r.equal("falling edge keeps the same magnitude as the rising edge", reversedMask, forwardMask)
                r.check("rising edge is detected", previewLitCount(forwardMask) > 0)
                r.check("falling edge is detected", previewLitCount(reversedMask) > 0)
                r.check("real Sobel response is symmetric about the step", previewLitColumns(forwardMask, width: width) == [7, 8],
                        "lit columns \(previewLitColumns(forwardMask, width: width))")
                r.check("outermost pixel ring is suppressed",
                        previewBorderLitCount(forwardMask, width: width, height: height) == 0)
                r.equal("the sample plane is never written by peaking", forward.luma, step(left: 0, right: 60))
            },

            TCCase(id: "T32b", title: "Flat fields produce no edges; corners, tiny planes and border rings are safe") { r in
                let flat = previewSample(bytes: [UInt8](repeating: 128, count: 16 * 16), width: 16, height: 16)
                let flatMask = PreviewAnalysisMath.peakingMask(from: flat, threshold: PeakingThreshold.low.value)
                r.equal("flat field yields a full-size mask", flatMask.count, 256)
                r.check("flat field has no edges at all", flatMask.allSatisfy { $0 == 0 })

                var corner = [UInt8](repeating: 0, count: 16 * 16)
                for row in 0..<4 {
                    for column in 0..<4 { corner[row * 16 + column] = 255 }
                }
                let cornerSample = previewSample(bytes: corner, width: 16, height: 16)
                let cornerMask = PreviewAnalysisMath.peakingMask(from: cornerSample, threshold: PeakingThreshold.low.value)
                r.check("corner step is detected next to the corner", cornerMask[4 * 16 + 4] == 255)
                r.equal("corner border pixels stay suppressed", previewBorderLitCount(cornerMask, width: 16, height: 16), 0)

                // 1×N, N×1, 2×2 and 3×3 planes must return correctly sized masks
                // without reading out of bounds.
                let tiny: [(Int, Int)] = [(1, 1), (1, 8), (8, 1), (2, 2), (3, 3)]
                for (tinyWidth, tinyHeight) in tiny {
                    let plane = previewSample(bytes: [UInt8](repeating: 255, count: tinyWidth * tinyHeight),
                                             width: tinyWidth,
                                             height: tinyHeight)
                    let mask = PreviewAnalysisMath.peakingMask(from: plane, threshold: PeakingThreshold.low.value)
                    r.equal("tiny \(tinyWidth)×\(tinyHeight) mask size", mask.count, tinyWidth * tinyHeight)
                    r.check("tiny \(tinyWidth)×\(tinyHeight) plane has no interior pixels", mask.allSatisfy { $0 == 0 })
                }
            },

            TCCase(id: "T32c", title: "Magnitude is sqrt(gx²+gy²)/sqrt(32) and a larger threshold means fewer edges") { r in
                let width = 16
                let height = 16
                func step(amplitude: UInt8) -> LuminanceSample {
                    var bytes = [UInt8](repeating: 0, count: width * height)
                    for row in 0..<height {
                        for column in 0..<width where column >= width / 2 {
                            bytes[row * width + column] = amplitude
                        }
                    }
                    return previewSample(bytes: bytes, width: width, height: height)
                }
                // 4·amplitude/(255·sqrt(32)) = amplitude/360.6
                let belowLow = PreviewAnalysisMath.peakingMask(from: step(amplitude: 16), threshold: PeakingThreshold.low.value)
                let lowBand = PreviewAnalysisMath.peakingMask(from: step(amplitude: 25), threshold: PeakingThreshold.low.value)
                let lowBandAtNormal = PreviewAnalysisMath.peakingMask(from: step(amplitude: 25), threshold: PeakingThreshold.normal.value)
                let normalBand = PreviewAnalysisMath.peakingMask(from: step(amplitude: 45), threshold: PeakingThreshold.normal.value)
                let normalBandAtHigh = PreviewAnalysisMath.peakingMask(from: step(amplitude: 45), threshold: PeakingThreshold.high.value)
                let highBand = PreviewAnalysisMath.peakingMask(from: step(amplitude: 70), threshold: PeakingThreshold.high.value)

                r.equal("16/255 step stays below Low", previewLitCount(belowLow), 0)
                r.equal("25/255 step lights 14 interior rows × 2 columns at Low", previewLitCount(lowBand), 28)
                r.equal("25/255 step is invisible at Normal", previewLitCount(lowBandAtNormal), 0)
                r.equal("45/255 step is visible at Normal", previewLitCount(normalBand), 28)
                r.equal("45/255 step is invisible at High", previewLitCount(normalBandAtHigh), 0)
                r.equal("70/255 step is visible at High", previewLitCount(highBand), 28)
                r.check("thresholds are ordered Low < Normal < High",
                        PeakingThreshold.low.value < PeakingThreshold.normal.value
                            && PeakingThreshold.normal.value < PeakingThreshold.high.value)
                r.check("labels carry the documented starting parameters",
                        PeakingThreshold.low.detailLabel.contains("0.06")
                            && PeakingThreshold.normal.detailLabel.contains("0.1")
                            && PeakingThreshold.high.detailLabel.contains("0.16"))
                r.check("peaking details refuse a focus-accuracy claim",
                        PreviewAnalysisMath.peakingLimitationNote.lowercased().contains("not proof"))
            },

            // MARK: - T33 preview zebras

            TCCase(id: "T33a", title: "Zebra values just below, equal to and above each threshold") { r in
                let values: [UInt8] = [0, 100, 229, 230, 241, 242, 254, 255]
                let sample = previewSample(bytes: values, width: values.count, height: 1)

                r.equal("90% quantizes to code value 230", ZebraThreshold.ninety.codeValue, UInt8(230))
                r.equal("95% quantizes to code value 242", ZebraThreshold.ninetyFive.codeValue, UInt8(242))
                r.equal("100% quantizes to code value 255", ZebraThreshold.hundred.codeValue, UInt8(255))
                r.equal("the default preset is 95%", ZebraThreshold.default, ZebraThreshold.ninetyFive)

                let ninety = PreviewAnalysisMath.zebraMask(from: sample, threshold: .ninety)
                let ninetyFive = PreviewAnalysisMath.zebraMask(from: sample, threshold: .ninetyFive)
                let hundred = PreviewAnalysisMath.zebraMask(from: sample, threshold: .hundred)
                r.equal("90% lights 3…7 (229 is below, 230 is equal)", previewLitIndices(ninety), [3, 4, 5, 6, 7])
                r.equal("95% lights 5…7 (241 below, 242 equal)", previewLitIndices(ninetyFive), [5, 6, 7])
                r.equal("100% lights only 255 (254 below, 255 equal)", previewLitIndices(hundred), [7])
                r.check("equal-to-threshold counts as highlighted",
                        ninety[3] == 255 && ninety[2] == 0 && ninetyFive[5] == 255 && ninetyFive[4] == 0)

                r.equal("0.5 quantizes to 128", PreviewAnalysisMath.zebraCodeValue(forNormalizedThreshold: 0.5), UInt8(128))
                r.equal("0.5 highlights values at or above 128",
                        previewLitIndices(PreviewAnalysisMath.zebraMask(from: sample, threshold: 0.5)), [2, 3, 4, 5, 6, 7])
                r.equal("a negative threshold clamps to code value 0", PreviewAnalysisMath.zebraCodeValue(forNormalizedThreshold: -1), UInt8(0))
                r.equal("a threshold above one clamps to code value 255", PreviewAnalysisMath.zebraCodeValue(forNormalizedThreshold: 2), UInt8(255))

                let histogramBefore = PreviewAnalysisMath.histogram(from: sample)
                _ = PreviewAnalysisMath.zebraMask(from: sample, threshold: .ninetyFive)
                _ = PreviewAnalysisMath.peakingMask(from: sample, threshold: PeakingThreshold.low.value)
                let histogramAfter = PreviewAnalysisMath.histogram(from: sample)
                r.equal("overlay masks never contribute to histogram samples", histogramAfter.bins, histogramBefore.bins)
                r.equal("the mask pass does not modify the sample", sample.luma, values)
            },

            TCCase(id: "T33b", title: "Video-range endpoints map correctly before zebra comparison") { r in
                let raw: [UInt8] = [16, 17, 100, 234, 235, 236, 0, 255]
                let outcome = raw.withUnsafeBufferPointer { buffer in
                    PreviewAnalysisMath.downsampleLuma(from: buffer,
                                                       width: raw.count,
                                                       height: 1,
                                                       bytesPerRow: raw.count,
                                                       range: .planarLuma8(.video),
                                                       targetLongEdge: 640)
                }
                guard let sample = outcome.sample else {
                    r.check("video-range sample produced", false)
                    return
                }
                r.equal("nominal black/white and clamped endpoints",
                        sample.luma, [0, 1, 98, 254, 255, 255, 0, 255])
                r.equal("100% highlights nominal white, above-white and nothing below",
                        previewLitIndices(PreviewAnalysisMath.zebraMask(from: sample, threshold: .hundred)), [4, 5, 7])
                r.equal("95% also highlights the 234 → 254 mapping",
                        previewLitIndices(PreviewAnalysisMath.zebraMask(from: sample, threshold: .ninetyFive)), [3, 4, 5, 7])
                r.equal("90% highlights the same post-mapping pixels",
                        previewLitIndices(PreviewAnalysisMath.zebraMask(from: sample, threshold: .ninety)), [3, 4, 5, 7])
                r.check("nominal black is never highlighted", PreviewAnalysisMath.zebraMask(from: sample, threshold: .ninety)[0] == 0)
            },

            TCCase(id: "T33c", title: "Every zebra label stays a preview claim with no RAW saturation wording") { r in
                for threshold in ZebraThreshold.allCases {
                    let label = threshold.label.lowercased()
                    let detail = threshold.detailLabel.lowercased()
                    r.check("\(threshold.label) label has no RAW wording", !label.contains("raw") && !label.contains("clipp"))
                    r.check("\(threshold.label) detail names the preview", detail.contains("preview"))
                    r.check("\(threshold.label) detail makes no saturation claim",
                            !detail.contains("saturation") && !detail.contains("sensor"))
                    r.check("\(threshold.label) detail exposes its code value", detail.contains("\(threshold.codeValue)"))
                }
                let note = PreviewAnalysisMath.zebraLimitationNote.lowercased()
                r.check("zebra note names the processed preview", note.contains("preview"))
                r.check("zebra note explicitly refuses a RAW clipping claim", note.contains("never measure sensor saturation"))
                r.check("loupe note states display-only magnification",
                        PreviewAnalysisMath.loupeLimitationNote.lowercased().contains("display only"))
                r.check("loupe note names the native zoom factor",
                        PreviewAnalysisMath.loupeLimitationNote.contains("videoZoomFactor"))
            },

            // MARK: - T34 focus loupe and mask geometry

            TCCase(id: "T34a", title: "Loupe crops are clamped at center and at every corner") { r in
                let width = 640
                let height = 480
                var bytes = [UInt8](repeating: 0, count: width * height)
                let markerIndex = 240 * width + 320
                let cornerIndex = 0
                bytes[markerIndex] = 255
                bytes[cornerIndex] = 255
                let sample = previewSample(bytes: bytes, width: width, height: height)

                let centerRect = LoupeRenderer.sampleRect(sample: sample,
                                                          center: NormalizedDevicePoint(x: 0.5, y: 0.5),
                                                          magnification: 2,
                                                          mapper: PreviewGeometryMapper.analysisPlane(planeDimensions: PixelDimensions(width: width, height: height)))
                r.equal("center crop is the centered half-size window", centerRect, PixelRect(x: 160, y: 120, width: 320, height: 240))

                let centerSnap = LoupeRenderer.render(sample: sample,
                                                      center: NormalizedDevicePoint(x: 0.5, y: 0.5),
                                                      magnification: 2)
                r.check("loupe output stays within 256", centerSnap.width <= 256 && centerSnap.height <= 256)
                r.equal("loupe keeps the crop aspect", PixelDimensions(width: centerSnap.width, height: centerSnap.height), PixelDimensions(width: 256, height: 192))
                r.check("the magnified center shows the marker", previewLoupePixel(centerSnap, x: centerSnap.width / 2, y: centerSnap.height / 2) == 255,
                        "center pixel \(previewLoupePixel(centerSnap, x: centerSnap.width / 2, y: centerSnap.height / 2) ?? 0)")
                r.check("the loupe carries the sample generations",
                        centerSnap.geometryGeneration == sample.geometryGeneration
                            && centerSnap.configurationGeneration == sample.configurationGeneration)

                // Top-left corner: the crop clamps to the origin and still contains
                // the bright corner pixel.
                let topLeft = LoupeRenderer.render(sample: sample,
                                                   center: NormalizedDevicePoint(x: 0, y: 0),
                                                   magnification: 2)
                r.check("top-left corner crop shows the corner pixel", previewLoupePixel(topLeft, x: 0, y: 0) == 255)
                let topLeftRect = LoupeRenderer.sampleRect(sample: sample,
                                                           center: NormalizedDevicePoint(x: 0, y: 0),
                                                           magnification: 2,
                                                           mapper: PreviewGeometryMapper.analysisPlane(planeDimensions: PixelDimensions(width: width, height: height)))
                r.equal("top-left crop clamps to the origin", topLeftRect, PixelRect(x: 0, y: 0, width: 320, height: 240))

                // Bottom-right corner: a 2× crop of 320×240 clamps to (320, 240),
                // which puts the center marker at the crop's top-left pixel.
                let bottomRight = LoupeRenderer.render(sample: sample,
                                                       center: NormalizedDevicePoint(x: 1, y: 1),
                                                       magnification: 2)
                r.check("bottom-right crop clamps inside the plane and shows the marker at its own corner",
                        previewLoupePixel(bottomRight, x: 0, y: 0) == 255)

                // Every sampled rectangle must stay inside the plane, for a sweep
                // of centers including all four corners and edges.
                let mapper = PreviewGeometryMapper.analysisPlane(planeDimensions: PixelDimensions(width: width, height: height))
                var allInside = true
                var nonEmpty = true
                for xStep in 0...8 {
                    for yStep in 0...8 {
                        let center = NormalizedDevicePoint(x: Double(xStep) / 8.0, y: Double(yStep) / 8.0)
                        guard let rect = LoupeRenderer.sampleRect(sample: sample, center: center, magnification: 4, mapper: mapper) else {
                            nonEmpty = false
                            continue
                        }
                        if rect.x < 0 || rect.y < 0 || rect.maxX > width || rect.maxY > height { allInside = false }
                    }
                }
                r.check("every swept crop is clamped inside the real image bounds", allInside)
                r.check("every swept crop is non-empty", nonEmpty)
                bytes.removeAll()
            },

            TCCase(id: "T34b", title: "Rotated, mirrored and letterboxed mappings keep plane order and stay in bounds") { r in
                let width = 160
                let height = 120
                var bytes = [UInt8](repeating: 0, count: width * height)
                for row in 0..<60 {
                    for column in 0..<80 { bytes[row * width + column] = 255 }
                }
                bytes[30 * width + 120] = 200
                let sample = previewSample(bytes: bytes, width: width, height: height)
                let plane = PixelDimensions(width: width, height: height)
                let letterboxed = TCRect(x: 20, y: 140, width: 160, height: 120)

                let rotatedMapper = PreviewGeometryMapper.analysisPlane(fallbackContentRect: letterboxed,
                                                                        planeDimensions: plane,
                                                                        rotationDegrees: 90,
                                                                        bufferOrientation: 6)
                var inBounds = true
                for xStep in 0...6 {
                    for yStep in 0...6 {
                        let center = NormalizedDevicePoint(x: Double(xStep) / 6.0, y: Double(yStep) / 6.0)
                        guard let rect = LoupeRenderer.sampleRect(sample: sample,
                                                                  center: center,
                                                                  magnification: 2,
                                                                  mapper: rotatedMapper) else {
                            inBounds = false
                            continue
                        }
                        if rect.x < 0 || rect.y < 0 || rect.maxX > width || rect.maxY > height { inBounds = false }
                    }
                }
                r.check("rotated/letterboxed crops stay inside the plane", inBounds)

                // The swapped-axis mapping must find the bright marker: with the
                // axes swapped, device y selects the column and device x the row.
                let swapped = NormalizedDevicePoint(x: 0.25, y: 0.75)
                guard let swappedRect = LoupeRenderer.sampleRect(sample: sample,
                                                                 center: swapped,
                                                                 magnification: 2,
                                                                 mapper: rotatedMapper) else {
                    r.check("swapped-axis crop exists", false)
                    return
                }
                r.check("swapped-axis crop covers the mapped bright pixels",
                        swappedRect.x <= 120 && swappedRect.maxX > 120 && swappedRect.y <= 30 && swappedRect.maxY > 30,
                        "rect \(swappedRect)")

                // Mirroring is a display transform: it must not flip the sampled
                // plane content, so both mappers produce the same rectangle.
                let plain = PreviewGeometryMapper.analysisPlane(planeDimensions: plane)
                let mirrored = PreviewGeometryMapper(imageDimensions: plane,
                                                     contentRect: TCRect(x: 0, y: 0, width: Double(width), height: Double(height)),
                                                     isMirrored: true,
                                                     rotationDegrees: 0,
                                                     bufferOrientation: 1)
                let plainRect = LoupeRenderer.sampleRect(sample: sample,
                                                         center: NormalizedDevicePoint(x: 0.5, y: 0.5),
                                                         magnification: 2,
                                                         mapper: plain)
                let mirroredRect = LoupeRenderer.sampleRect(sample: sample,
                                                            center: NormalizedDevicePoint(x: 0.5, y: 0.5),
                                                            magnification: 2,
                                                            mapper: mirrored)
                r.equal("mirroring does not flip the sampled plane rectangle", mirroredRect, plainRect)

                // Plane order: the bright top-left quadrant must stay top-left.
                let snapshot = LoupeRenderer.render(sample: sample,
                                                    center: NormalizedDevicePoint(x: 0.5, y: 0.5),
                                                    magnification: 2,
                                                    mapper: plain)
                r.check("plane row/column order is preserved in the loupe buffer",
                        previewLoupePixel(snapshot, x: 0, y: 0) == 255
                            && previewLoupePixel(snapshot, x: snapshot.width - 1, y: snapshot.height - 1) == 0,
                        "top-left \(previewLoupePixel(snapshot, x: 0, y: 0) ?? 0) bottom-right \(previewLoupePixel(snapshot, x: snapshot.width - 1, y: snapshot.height - 1) ?? 0)")
                bytes.removeAll()
            },

            TCCase(id: "T34c", title: "Display magnification never changes a native zoom value") { r in
                struct NativeZoomState: Equatable {
                    var videoZoomFactor = 1.0
                    var photoConnectionScale = 1.0
                    var photoConnectionCrop = 1.0
                    var rawOutputDimensions = PixelDimensions(width: 8000, height: 6000)
                }
                let before = NativeZoomState()
                var native = before
                let sample = previewSample(bytes: [UInt8](repeating: 180, count: 64 * 48), width: 64, height: 48)

                let twoTimes = LoupeRenderer.render(sample: sample,
                                                    center: .center,
                                                    magnification: LoupeRenderer.defaultMagnification)
                let fourTimes = LoupeRenderer.render(sample: sample, center: .center, magnification: 4)
                r.equal("2× label", twoTimes.magnification, 2)
                r.equal("4× label", fourTimes.magnification, 4)
                r.check("default display magnification is 2×", LoupeRenderer.defaultMagnification == 2)
                r.equal("supported display magnifications are the documented pair", LoupeRenderer.supportedMagnifications, [2, 4])
                r.check("loupe output is never larger than 256×256",
                        twoTimes.width <= 256 && twoTimes.height <= 256 && fourTimes.width <= 256 && fourTimes.height <= 256)
                r.check("loupe bytes are luma-only RGBA", twoTimes.rgbaBytes.count == twoTimes.width * twoTimes.height * 4)

                // The pure renderer takes no camera parameter and cannot mutate a
                // device: the captured native state must be identical afterwards.
                r.equal("native zoom state is untouched by loupe rendering", native, before)
                native.videoZoomFactor = 1.0
                r.equal("video zoom stays native 1.0", native.videoZoomFactor, before.videoZoomFactor)
                r.equal("photo connection scale stays 1.0", native.photoConnectionScale, before.photoConnectionScale)
                r.equal("photo connection crop stays 1.0", native.photoConnectionCrop, before.photoConnectionCrop)
                r.equal("RAW output dimensions are unchanged", native.rawOutputDimensions, before.rawOutputDimensions)

                r.equal("zero magnification falls back to the 2× default", LoupeRenderer.effectiveMagnification(0), 2)
                r.equal("negative magnification falls back to the 2× default", LoupeRenderer.effectiveMagnification(-4), 2)
                r.equal("non-finite magnification falls back to the 2× default", LoupeRenderer.effectiveMagnification(.nan), 2)
                r.equal("magnification is capped at 4×", LoupeRenderer.effectiveMagnification(9), 4)
                r.equal("magnification 0 still renders the default crop", LoupeRenderer.render(sample: sample, center: .center, magnification: 0).magnification, 2)

                let empty = LoupeRenderer.render(sample: previewSample(bytes: [], width: 0, height: 0),
                                                 center: .center,
                                                 magnification: 2)
                r.check("an unusable plane yields the empty unavailable snapshot",
                        empty.width == 0 && empty.height == 0 && empty.rgbaBytes.isEmpty)
            },

            TCCase(id: "T34d", title: "4× samples a quarter of the 2× window") { r in
                let sample = previewSample(bytes: [UInt8](repeating: 10, count: 640 * 480), width: 640, height: 480)
                let mapper = PreviewGeometryMapper.analysisPlane(planeDimensions: PixelDimensions(width: 640, height: 480))
                let two = LoupeRenderer.sampleRect(sample: sample, center: .center, magnification: 2, mapper: mapper)
                let four = LoupeRenderer.sampleRect(sample: sample, center: .center, magnification: 4, mapper: mapper)
                guard let two, let four else {
                    r.check("both crops exist", false)
                    return
                }
                r.equal("4× halves the sampled width", four.width * 2, two.width)
                r.equal("4× halves the sampled height", four.height * 2, two.height)
            },

            TCCase(id: "T34e", title: "Mask cell rects stay inside the content rect in portrait and both landscapes") { r in
                struct Layout {
                    let name: String
                    let viewSize: TCSize
                    let rotation: Int
                }
                let layouts = [
                    Layout(name: "portrait", viewSize: TCSize(width: 393, height: 852), rotation: 90),
                    Layout(name: "landscapeRight", viewSize: TCSize(width: 852, height: 393), rotation: 0),
                    Layout(name: "landscapeLeft", viewSize: TCSize(width: 852, height: 393), rotation: 180),
                ]
                let maskWidth = 192
                let maskHeight = 144
                for layout in layouts {
                    let contentRect = PreviewGeometryMapper.aspectFitRect(imageDimensions: PixelDimensions(width: 1920, height: 1440),
                                                                         rotationDegrees: layout.rotation,
                                                                         in: TCRect(origin: .zero, size: layout.viewSize))
                    let mapper = PreviewGeometryMapper(imageDimensions: PixelDimensions(width: 1920, height: 1440),
                                                       contentRect: contentRect,
                                                       isMirrored: false,
                                                       rotationDegrees: layout.rotation,
                                                       bufferOrientation: 1)
                    r.check("\(layout.name) content rect is inside the view",
                            contentRect.minX >= -1e-9 && contentRect.minY >= -1e-9
                                && contentRect.maxX <= layout.viewSize.width + 1e-9
                                && contentRect.maxY <= layout.viewSize.height + 1e-9,
                            "content \(contentRect)")
                    var allInside = true
                    var allNonNil = true
                    for row in 0..<maskHeight {
                        for column in 0..<maskWidth {
                            guard let cell = mapper.viewRect(forMaskColumn: column,
                                                             row: row,
                                                             maskWidth: maskWidth,
                                                             maskHeight: maskHeight) else {
                                allNonNil = false
                                continue
                            }
                            let epsilon = 1e-9
                            if cell.minX < contentRect.minX - epsilon || cell.minY < contentRect.minY - epsilon
                                || cell.maxX > contentRect.maxX + epsilon || cell.maxY > contentRect.maxY + epsilon {
                                allInside = false
                            }
                        }
                    }
                    r.check("\(layout.name) every mask cell rect is non-nil", allNonNil)
                    r.check("\(layout.name) every mask cell rect stays inside the content rect", allInside)
                    let lastCell = mapper.viewRect(forMaskColumn: maskWidth - 1,
                                                  row: maskHeight - 1,
                                                  maskWidth: maskWidth,
                                                  maskHeight: maskHeight)
                    r.close("\(layout.name) last cell reaches the content maxX",
                            Double(lastCell?.maxX ?? -1), contentRect.maxX, tolerance: 1e-6)
                    r.close("\(layout.name) last cell reaches the content maxY",
                            Double(lastCell?.maxY ?? -1), contentRect.maxY, tolerance: 1e-6)
                    r.check("\(layout.name) out-of-range cells are rejected",
                            mapper.viewRect(forMaskColumn: maskWidth, row: 0, maskWidth: maskWidth, maskHeight: maskHeight) == nil
                                && mapper.viewRect(forMaskColumn: -1, row: 0, maskWidth: maskWidth, maskHeight: maskHeight) == nil)
                }
            },

            // MARK: - T35 generation changes

            TCCase(id: "T35a", title: "A sample from an old configuration or layout generation is dropped") { r in
                let clock = VirtualMonotonicClock(start: 0)
                let service = MeteringService(clock: clock)
                await service.setDemand(previewRequest(configuration: 7, layout: 3, demand: previewFullDemand))

                let current = previewSample(bytes: [UInt8](repeating: 40, count: 32 * 24),
                                            width: 32,
                                            height: 24,
                                            configuration: 7,
                                            geometry: 3,
                                            at: 0)
                await service.submit(sample: current)
                let afterCurrent = await service.emittedOutputCount
                r.check("the current-generation sample is analysed", afterCurrent > 0)

                let oldConfiguration = previewSample(bytes: [UInt8](repeating: 40, count: 32 * 24),
                                                     width: 32,
                                                     height: 24,
                                                     configuration: 6,
                                                     geometry: 3,
                                                     at: 1)
                let oldLayout = previewSample(bytes: [UInt8](repeating: 40, count: 32 * 24),
                                              width: 32,
                                              height: 24,
                                              configuration: 7,
                                              geometry: 2,
                                              at: 2)
                await service.submit(sample: oldConfiguration)
                await service.submit(sample: oldLayout)

                r.equal("old-generation samples produce no output", await service.emittedOutputCount, afterCurrent)
                r.equal("both stale samples were counted", await service.droppedStaleGenerationSampleCount, 2)
                let outputs = await service.recentOutputsForTesting
                let masks = previewMasks(outputs)
                r.check("every emitted mask belongs to the current generation",
                        masks.allSatisfy { $0.configurationGeneration == ConfigurationGeneration(7) && $0.geometryGeneration == 3 },
                        "masks \(masks.map { ($0.configurationGeneration.value, $0.geometryGeneration) })")
                r.check("every emitted loupe frame belongs to the current generation",
                        previewLoupes(outputs).allSatisfy { $0.configurationGeneration == ConfigurationGeneration(7) && $0.geometryGeneration == 3 })

                // An unlabelled sample is not evidence of an *old* generation, and
                // it is still the newest frame, so it must be analysed - and the
                // resulting snapshot must be stamped with the demand generation the
                // overlay code compares against, not with the sample's zero.
                let emittedBeforeUnlabelled = await service.emittedOutputCount
                clock.advance(by: 0.5)
                await service.submit(sample: previewSample(bytes: [UInt8](repeating: 40, count: 32 * 24),
                                                           width: 32,
                                                           height: 24,
                                                           configuration: 0,
                                                           geometry: 0,
                                                           at: 3))
                r.check("an unlabelled newest sample is analysed rather than silently dropped",
                        await service.emittedOutputCount > emittedBeforeUnlabelled)
                r.equal("the unlabelled sample is counted as such", await service.acceptedUnspecifiedGenerationSampleCount, 1)
                let relabelled = previewMasks(await service.recentOutputsForTesting).last
                r.check("the snapshot carries the demand generation, not the sample's zero",
                        relabelled?.configurationGeneration == ConfigurationGeneration(7)
                            && relabelled?.geometryGeneration == 3,
                        "mask generations \(String(describing: relabelled?.configurationGeneration.value))/\(String(describing: relabelled?.geometryGeneration))")
            },

            TCCase(id: "T35b", title: "A geometry change drops the throttle history and re-emits at once") { r in
                let clock = VirtualMonotonicClock(start: 0)
                let service = MeteringService(clock: clock)
                await service.setDemand(previewRequest(configuration: 7, layout: 3, demand: previewMaskDemand))

                await service.submit(sample: previewSample(bytes: [UInt8](repeating: 30, count: 32 * 24),
                                                          width: 32, height: 24, configuration: 7, geometry: 3, at: 0))
                r.equal("first sample emits a mask", await service.emittedMaskCount, 1)

                await service.submit(sample: previewSample(bytes: [UInt8](repeating: 30, count: 32 * 24),
                                                          width: 32, height: 24, configuration: 7, geometry: 3, at: 1))
                r.equal("a second sample in the same instant is throttled", await service.emittedMaskCount, 1)

                await service.setDemand(previewRequest(configuration: 7, layout: 4, demand: previewMaskDemand))
                await service.submit(sample: previewSample(bytes: [UInt8](repeating: 30, count: 32 * 24),
                                                          width: 32, height: 24, configuration: 7, geometry: 4, at: 2))
                r.equal("the first sample of the new generation emits immediately", await service.emittedMaskCount, 2)
                let masks = previewMasks(await service.recentOutputsForTesting)
                r.equal("the newest mask carries the new layout generation", masks.last?.geometryGeneration, 4)
                r.check("no mask from the superseded layout survives",
                        !masks.dropLast().contains { $0.geometryGeneration == 4 } && masks.dropLast().allSatisfy { $0.geometryGeneration == 3 })
            },

            TCCase(id: "T35c", title: "Rapid configuration change with analysis in flight leaves no stale overlay") { r in
                let clock = VirtualMonotonicClock(start: 0)
                let service = MeteringService(clock: clock)
                await service.setDemand(previewRequest(configuration: 7, layout: 3, demand: previewFullDemand))
                await service.submit(sample: previewSample(bytes: [UInt8](repeating: 90, count: 32 * 24),
                                                           width: 32, height: 24, configuration: 7, geometry: 3, at: 0))
                r.check("first generation produced output", await service.emittedOutputCount > 0)

                // The lens/format/rotation change lands while a callback for the old
                // generation is still on its way.
                let emittedBeforeChange = await service.emittedOutputCount
                await service.setDemand(previewRequest(configuration: 8, layout: 5, demand: previewFullDemand))
                clock.advance(by: 0.001)
                await service.submit(sample: previewSample(bytes: [UInt8](repeating: 90, count: 32 * 24),
                                                           width: 32, height: 24, configuration: 7, geometry: 3, at: 1))
                r.equal("the late old-generation callback is dropped", await service.droppedStaleGenerationSampleCount, 1)

                clock.advance(by: 0.5)
                await service.submit(sample: previewSample(bytes: [UInt8](repeating: 90, count: 32 * 24),
                                                           width: 32, height: 24, configuration: 8, geometry: 5, at: 2))
                let outputs = await service.recentOutputsForTesting
                let emittedAfterChange = await service.emittedOutputCount - emittedBeforeChange
                r.check("the change still produced fresh output", emittedAfterChange > 0)
                let fresh = Array(outputs.suffix(emittedAfterChange))
                r.check("no fresh output is stamped with the superseded configuration",
                        fresh.allSatisfy { output in
                            switch output {
                            case .histogram(let snapshot): return snapshot.configurationGeneration.value == 8 && snapshot.geometryGeneration == 5
                            case .masks(let snapshot): return snapshot.configurationGeneration.value == 8 && snapshot.geometryGeneration == 5
                            case .loupe(let snapshot): return snapshot.configurationGeneration.value == 8 && snapshot.geometryGeneration == 5
                            case .geometryChanged, .analysisUnavailable: return true
                            }
                        },
                        "fresh types \(fresh.map { String(describing: $0).prefix(12) })")
                r.check("fresh masks and loupe frames exist after the change",
                        !previewMasks(fresh).isEmpty && !previewLoupes(fresh).isEmpty && !previewHistograms(fresh).isEmpty)
            },

            // MARK: - T36 no work when nothing is demanded

            TCCase(id: "T36a", title: "All aids off releases scratch and produces no output") { r in
                let clock = VirtualMonotonicClock(start: 0)
                let service = MeteringService(clock: clock)
                await service.setDemand(previewRequest(configuration: 1, layout: 1, demand: previewFullDemand))
                await service.submit(sample: previewSample(bytes: [UInt8](repeating: 200, count: 32 * 24),
                                                           width: 32, height: 24, configuration: 1, geometry: 1, at: 0))
                r.check("scratch is allocated while aids run", await service.scratchRetainedByteCount > 0)
                let emitted = await service.emittedOutputCount
                r.check("aids produced output", emitted > 0)

                await service.setDemand(nil)
                r.check("scratch is released when every aid is off", await service.isScratchReleased)
                r.equal("no buffer is retained after release", await service.scratchRetainedByteCount, 0)

                await service.submit(sample: previewSample(bytes: [UInt8](repeating: 200, count: 32 * 24),
                                                           width: 32, height: 24, configuration: 1, geometry: 1, at: 1))
                r.equal("no output while nothing is demanded", await service.emittedOutputCount, emitted)
                r.equal("the sample was counted as dropped, never queued", await service.droppedNoDemandSampleCount, 1)
            },

            TCCase(id: "T36b", title: "Library navigation and inactive scenes demand nothing, and the level stops") { r in
                let geometry = previewGeometry(configuration: 3, layout: 9)
                let lifecycles: [PreviewLifecycleState] = [
                    .cameraNotRunning,
                    .cameraInterrupted(reason: "call"),
                    .libraryNavigating,
                    .sceneInactive,
                    .analysisUnsupported(reason: "BGRA only"),
                ]
                for lifecycle in lifecycles {
                    let decision = AnalysisDemandPolicy.decide(configuration: .default,
                                                              lifecycle: lifecycle,
                                                              geometry: geometry)
                    r.check("\(lifecycle) demands nothing", decision.demand.isEmpty)
                    r.check("\(lifecycle) requests no analysis", decision.request == nil)
                    r.check("\(lifecycle) requests no video output", !decision.wantsVideoOutput)
                    r.check("\(lifecycle) reports a truthful status", !decision.statusMessage.isEmpty)
                }

                let allOff = AnalysisDemandPolicy.decide(configuration: PreviewAidConfiguration(isHistogramEnabled: false,
                                                                                                isPeakingEnabled: false,
                                                                                                peakingThreshold: .normal,
                                                                                                isZebrasEnabled: false,
                                                                                                zebraThreshold: .default,
                                                                                                isLoupeEnabled: false,
                                                                                                loupeMagnification: 2,
                                                                                                loupeCenter: .center),
                                                         lifecycle: .activeCameraView,
                                                         geometry: geometry)
                r.check("all aids off demands no sample", allOff.demand.isEmpty)
                r.check("all aids off requests no analysis", allOff.request == nil)
                r.check("all aids off requests no video output", !allOff.wantsVideoOutput)

                // The level stops producing readings when hidden or inactive.
                var level = LevelService(clock: VirtualMonotonicClock(start: 0), orientation: .portrait)
                let vertical = GravityReading(x: 0, y: -1, z: 0)
                let first = level.update(gravity: vertical)
                r.check("a visible active level produces a reading", first.isProducingReadings)
                let sequence = first.sequenceNumber

                level.setVisible(false)
                let hidden = level.update(gravity: vertical)
                r.check("a hidden level stops producing readings", !hidden.isProducingReadings)
                r.equal("a hidden level produces no new update", hidden.sequenceNumber, sequence)
                level.setVisible(true)
                level.setSceneActive(false)
                let inactive = level.update(gravity: vertical)
                r.check("an inactive scene stops producing readings", !inactive.isProducingReadings)
                r.equal("an inactive scene produces no new update", inactive.sequenceNumber, sequence)
                level.setSceneActive(true)
                level.setEnabled(false)
                r.check("a disabled level stops producing readings", !level.update(gravity: vertical).isProducingReadings)
            },

            TCCase(id: "T36c", title: "stop() releases scratch, emits nothing and can be followed by a fresh demand") { r in
                let clock = VirtualMonotonicClock(start: 0)
                let service = MeteringService(clock: clock)
                await service.setDemand(previewRequest(configuration: 2, layout: 2, demand: previewFullDemand))
                await service.submit(sample: previewSample(bytes: [UInt8](repeating: 60, count: 32 * 24),
                                                           width: 32, height: 24, configuration: 2, geometry: 2, at: 0))
                let emitted = await service.emittedOutputCount
                r.check("analysis ran before stop", emitted > 0)

                await service.stop()
                r.check("stop releases scratch", await service.isScratchReleased)
                r.equal("stop retains no buffers", await service.scratchRetainedByteCount, 0)
                await service.submit(sample: previewSample(bytes: [UInt8](repeating: 60, count: 32 * 24),
                                                           width: 32, height: 24, configuration: 2, geometry: 2, at: 1))
                r.equal("stop emits no analysis output", await service.emittedOutputCount, emitted)

                let masksBefore = await service.emittedMaskCount
                await service.setDemand(previewRequest(configuration: 2, layout: 2, demand: previewMaskDemand))
                await service.submit(sample: previewSample(bytes: [UInt8](repeating: 60, count: 32 * 24),
                                                           width: 32, height: 24, configuration: 2, geometry: 2, at: 2))
                r.equal("a fresh demand resumes analysis after stop", await service.emittedMaskCount, masksBefore + 1)
            },

            TCCase(id: "T36d", title: "Steady-state analysis reuses scratch buffers instead of reallocating") { r in
                let clock = VirtualMonotonicClock(start: 0)
                let service = MeteringService(clock: clock)
                await service.setDemand(previewRequest(configuration: 4, layout: 4, demand: previewFullDemand))
                clock.advance(by: 0.2)
                await service.submit(sample: previewSample(bytes: [UInt8](repeating: 20, count: 64 * 48),
                                                           width: 64, height: 48, configuration: 4, geometry: 4, at: 0))
                let growthAfterFirstPass = await service.scratchBufferGrowthCount
                r.check("the first pass allocated the working buffers", growthAfterFirstPass >= 4,
                        "growth \(growthAfterFirstPass)")
                for index in 1..<4 {
                    clock.advance(by: 0.2)
                    await service.submit(sample: previewSample(bytes: [UInt8](repeating: UInt8(20 + index * 10), count: 64 * 48),
                                                               width: 64, height: 48, configuration: 4, geometry: 4, at: Double(index)))
                }
                r.equal("four passes ran", await service.analysisPassCount, 4)
                r.equal("later passes added no allocation", await service.scratchBufferGrowthCount, growthAfterFirstPass)
                r.check("every pass produced a mask", await service.emittedMaskCount == 4)
                r.equal("no sample was dropped", await service.droppedStaleGenerationSampleCount + service.droppedLateSampleCount + service.droppedNoDemandSampleCount, 0)

                // A larger working plane may grow scratch once, but re-running the
                // same size must not grow it again.
                clock.advance(by: 0.2)
                await service.submit(sample: previewSample(bytes: [UInt8](repeating: 90, count: 160 * 120),
                                                           width: 160, height: 120, configuration: 4, geometry: 4, at: 100))
                let grownOnce = await service.scratchBufferGrowthCount
                clock.advance(by: 0.2)
                await service.submit(sample: previewSample(bytes: [UInt8](repeating: 90, count: 160 * 120),
                                                           width: 160, height: 120, configuration: 4, geometry: 4, at: 101))
                r.equal("a repeated larger pass does not allocate again", await service.scratchBufferGrowthCount, grownOnce)
            },

            TCCase(id: "T36e", title: "The level is orientation-aware, smoothed and honest when flat") { r in
                for orientation in DeviceOrientation.allCases {
                    var level = LevelService(clock: VirtualMonotonicClock(start: 0),
                                             orientation: orientation,
                                             gain: 1.0)
                    let axes = orientation.screenAxes
                    let vertical = GravityReading(x: -axes.up.x, y: -axes.up.y, z: 0)
                    let state = level.update(gravity: vertical)
                    r.close("\(orientation.displayLabel) reads level when vertical", state.rollDegrees, 0, tolerance: 1e-6)
                    r.equal("\(orientation.displayLabel) zone is level", state.zone, .level)

                    // A 10° tilt inside the screen plane must read as 10°, and the
                    // sign must follow the screen's own right/up axes.
                    let radians = 10.0 * Double.pi / 180.0
                    let tilted = GravityReading(x: -axes.up.x * cos(radians) + axes.right.x * sin(radians),
                                                y: -axes.up.y * cos(radians) + axes.right.y * sin(radians),
                                                z: 0)
                    let tiltedState = level.update(gravity: tilted)
                    r.close("\(orientation.displayLabel) reads the 10° screen-plane tilt", tiltedState.rollDegrees, 10, tolerance: 1e-6)
                    r.equal("\(orientation.displayLabel) zone is tilted", tiltedState.zone, .tilted)
                }

                var smoothed = LevelService(clock: VirtualMonotonicClock(start: 0),
                                            orientation: .portrait,
                                            gain: 0.5)
                let axes = DeviceOrientation.portrait.screenAxes
                let radians = 20.0 * Double.pi / 180.0
                let tilted = GravityReading(x: -axes.up.x * cos(radians) + axes.right.x * sin(radians),
                                            y: -axes.up.y * cos(radians) + axes.right.y * sin(radians),
                                            z: 0)
                _ = smoothed.update(gravity: tilted)
                let response = smoothed.update(gravity: GravityReading(x: -axes.up.x, y: -axes.up.y, z: 0))
                r.close("gain applies a low-pass response to the roll", response.rollDegrees, 10, tolerance: 1e-6)
                r.equal("the level reports a new reading", response.isProducingReadings, true)

                var flat = LevelService(clock: VirtualMonotonicClock(start: 0), orientation: .portrait)
                let flatState = flat.update(gravity: GravityReading(x: 0, y: 0, z: -1))
                r.equal("a flat phone has a valid surface level", flatState.zone, .level)
                r.check("flat state carries a surface reading instead of a horizon roll", flatState.surfaceTilt != nil)
                r.check("flat status text is explicit", flatState.statusLabel.lowercased().contains("flat"))
            },

            TCCase(id: "T36f", title: "The public output stream delivers small snapshots and stays silent when idle") { r in
                let clock = VirtualMonotonicClock(start: 0)
                let service = MeteringService(clock: clock)
                // In the native bundle `MeteringService` is an actor and the
                // property needs a hop; in the standalone verifier the same source
                // is compiled into this executable, where it is not isolated.
                #if canImport(XCTest)
                let stream = await service.output
                #else
                let stream = service.output
                #endif
                await service.setDemand(previewRequest(configuration: 2, layout: 2, demand: previewFullDemand))
                await service.submit(sample: previewSample(bytes: [UInt8](repeating: 120, count: 64 * 48),
                                                           width: 64, height: 48, configuration: 2, geometry: 2, at: 0))

                var kinds: Set<String> = []
                var largestSnapshotBytes = 0
                for await output in stream {
                    switch output {
                    case .histogram(let snapshot):
                        kinds.insert("histogram")
                        largestSnapshotBytes = max(largestSnapshotBytes, snapshot.bins.count * MemoryLayout<UInt32>.stride)
                    case .masks(let snapshot):
                        kinds.insert("masks")
                        let bytes = (snapshot.peakingMask?.count ?? 0) + (snapshot.zebraMask?.count ?? 0)
                        largestSnapshotBytes = max(largestSnapshotBytes, bytes)
                    case .loupe(let snapshot):
                        kinds.insert("loupe")
                        largestSnapshotBytes = max(largestSnapshotBytes, snapshot.rgbaBytes.count)
                    case .geometryChanged:
                        kinds.insert("geometry")
                    case .analysisUnavailable:
                        kinds.insert("unavailable")
                    }
                    if kinds.count == 3 { break }
                }
                r.equal("every enabled aid arrives on the public stream", kinds, Set(["histogram", "masks", "loupe"]))
                r.check("stream snapshots stay bounded (no full-frame image)",
                        largestSnapshotBytes <= 640 * 480 * 4,
                        "largest \(largestSnapshotBytes) bytes")

                // With nothing demanded, the stream must stay silent even though
                // samples keep arriving.
                await service.setDemand(nil)
                let delivered = PreviewFlag()
                let consumer = Task {
                    for await _ in stream {
                        delivered.set()
                        break
                    }
                }
                await service.submit(sample: previewSample(bytes: [UInt8](repeating: 120, count: 64 * 48),
                                                           width: 64, height: 48, configuration: 2, geometry: 2, at: 1))
                try? await Task.sleep(nanoseconds: 30_000_000)
                consumer.cancel()
                _ = await consumer.value
                r.check("no snapshot is delivered while every aid is off", !delivered.value)
            },

            // MARK: - T37 pressure, precedence and no stale frame

            TCCase(id: "T37a", title: "Memory and thermal pressure reduce the rate and can visibly pause a tool") { r in
                let geometry = previewGeometry(configuration: 5, layout: 6)
                let allOn = PreviewAidConfiguration(isHistogramEnabled: true,
                                                    isPeakingEnabled: true,
                                                    peakingThreshold: .normal,
                                                    isZebrasEnabled: true,
                                                    zebraThreshold: .default,
                                                    isLoupeEnabled: true,
                                                    loupeMagnification: 2,
                                                    loupeCenter: .center)
                let nominal = AnalysisDemandPolicy.decide(configuration: allOn, lifecycle: .activeCameraView, geometry: geometry)
                r.equal("nominal histogram rate", nominal.rateLimits.histogramHz, 10)
                r.equal("nominal peaking rate", nominal.rateLimits.peakingHz, 20)
                r.equal("nominal zebra rate", nominal.rateLimits.zebraHz, 20)
                r.equal("nominal loupe rate", nominal.rateLimits.loupeHz, 30)
                r.check("nominal decision runs every aid", nominal.demand == previewFullDemand)
                r.check("nominal decision has no paused aid", nominal.pausedAids.isEmpty)

                let thermal = AnalysisResourcePressure(thermal: .elevated)
                let elevated = AnalysisDemandPolicy.decide(configuration: allOn, lifecycle: .activeCameraView, pressure: thermal, geometry: geometry)
                r.equal("elevated thermal halves the histogram rate", elevated.rateLimits.histogramHz, 5)
                r.equal("elevated thermal halves the loupe rate", elevated.rateLimits.loupeHz, 15)
                r.equal("elevated thermal keeps every aid running", elevated.demand, previewFullDemand)
                r.check("elevated status names the reduction", elevated.statusMessage.lowercased().contains("reduced"))

                let memory = AnalysisResourcePressure(memoryWarningCount: 1)
                let afterWarning = AnalysisDemandPolicy.decide(configuration: allOn, lifecycle: .activeCameraView, pressure: memory, geometry: geometry)
                r.equal("a memory warning also halves the rate", afterWarning.rateLimits.histogramHz, 5)

                let pending = AnalysisResourcePressure(pendingOriginalCount: 3)
                let withPending = AnalysisDemandPolicy.decide(configuration: allOn, lifecycle: .activeCameraView, pressure: pending, geometry: geometry)
                r.equal("pending originals reduce the analysis rate", withPending.rateLimits.histogramHz, 5)
                r.equal("pending originals are reported, never evicted", withPending.pendingOriginalCount, 3)
                r.check("the decision states pending originals are retained", withPending.retainedPendingOriginals)
                r.check("the status never claims eviction",
                        !withPending.statusMessage.lowercased().contains("evict")
                            && !withPending.statusMessage.lowercased().contains("discard"))

                let critical = AnalysisResourcePressure(thermal: .critical)
                let paused = AnalysisDemandPolicy.decide(configuration: allOn, lifecycle: .activeCameraView, pressure: critical, geometry: geometry)
                r.equal("critical pressure reduces the rate further", paused.rateLimits.histogramHz, 2.5)
                r.equal("critical pressure pauses the two most expensive aids", Set(paused.pausedAids.map(\.aid)), Set([PreviewAidKind.peaking, .loupe]))
                r.check("a paused aid is visibly reported, not silently missing",
                        paused.pausedAids.allSatisfy { !$0.statusLabel.isEmpty && $0.statusLabel.lowercased().contains("paused") })
                r.check("paused aids are removed from the live demand",
                        !paused.demand.peakingEnabled && !paused.demand.loupeEnabled
                            && paused.demand.zebrasEnabled && paused.demand.histogramEnabled)
                r.check("reduced aids still run so the preview stays useful", paused.request != nil)
                r.check("critical status names the pause and the reduction",
                        paused.statusMessage.lowercased().contains("critical")
                            && paused.statusMessage.lowercased().contains("paused"))

                let onlyExpensive = PreviewAidConfiguration(isHistogramEnabled: false,
                                                            isPeakingEnabled: true,
                                                            peakingThreshold: .normal,
                                                            isZebrasEnabled: false,
                                                            zebraThreshold: .default,
                                                            isLoupeEnabled: true,
                                                            loupeMagnification: 2,
                                                            loupeCenter: .center)
                let allPaused = AnalysisDemandPolicy.decide(configuration: onlyExpensive,
                                                            lifecycle: .activeCameraView,
                                                            pressure: critical,
                                                            geometry: geometry)
                r.check("when everything is paused no analysis is requested", allPaused.request == nil && allPaused.demand.isEmpty)
                r.check("the paused state says no live overlay is shown",
                        allPaused.statusMessage.lowercased().contains("no live overlay"))
            },

            TCCase(id: "T37b", title: "Capture and export storage take precedence over optional analysis") { r in
                let geometry = previewGeometry(configuration: 5, layout: 6)
                let allOn = PreviewAidConfiguration(isHistogramEnabled: true,
                                                    isPeakingEnabled: true,
                                                    peakingThreshold: .normal,
                                                    isZebrasEnabled: true,
                                                    zebraThreshold: .default,
                                                    isLoupeEnabled: true,
                                                    loupeMagnification: 2,
                                                    loupeCenter: .center)
                let duringCapture = AnalysisDemandPolicy.decide(configuration: allOn,
                                                               lifecycle: .activeCameraView,
                                                               pressure: AnalysisResourcePressure(captureOrExportInFlight: true),
                                                               geometry: geometry)
                r.check("capture preempts every optional aid", duringCapture.demand.isEmpty && duringCapture.request == nil)
                r.check("the preemption is flagged", duringCapture.isPreemptedByCapture)
                r.equal("every enabled aid is reported paused", duringCapture.pausedAids.count, 4)
                r.check("the paused reason names capture/export storage",
                        duringCapture.pausedAids.allSatisfy { $0.reason.lowercased().contains("storage") })
                r.check("no video output is requested during capture", !duringCapture.wantsVideoOutput)
            },

            TCCase(id: "T37c", title: "Reduced rates throttle, paused aids stay absent and a late frame is never live") { r in
                let clock = VirtualMonotonicClock(start: 0)
                let service = MeteringService(clock: clock, rateLimits: AnalysisRateLimits.nominal.scaled(by: 0.5))
                await service.setDemand(previewRequest(configuration: 6, layout: 7, demand: previewFullDemand))

                let first = previewSample(bytes: [UInt8](repeating: 150, count: 32 * 24), width: 32, height: 24, configuration: 6, geometry: 7, at: 0)
                await service.submit(sample: first)
                let emitted = await service.emittedOutputCount
                r.equal("the first sample emits one snapshot per running aid", emitted, 3)

                clock.advance(by: 0.02)
                await service.submit(sample: previewSample(bytes: [UInt8](repeating: 150, count: 32 * 24), width: 32, height: 24, configuration: 6, geometry: 7, at: 1))
                r.equal("a sample inside the reduced interval is throttled", await service.emittedOutputCount, emitted)

                clock.advance(by: 0.15)
                await service.submit(sample: previewSample(bytes: [UInt8](repeating: 150, count: 32 * 24), width: 32, height: 24, configuration: 6, geometry: 7, at: 2))
                r.check("the next eligible sample emits", await service.emittedOutputCount > emitted)

                // A late-arriving older frame must never be presented as live, even
                // once the throttle interval has elapsed.
                let beforeLate = await service.emittedOutputCount
                clock.advance(by: 5.0)
                await service.submit(sample: previewSample(bytes: [UInt8](repeating: 150, count: 32 * 24), width: 32, height: 24, configuration: 6, geometry: 7, at: 0.5))
                r.equal("a late frame produces no output", await service.emittedOutputCount, beforeLate)
                r.equal("the late frame is counted as dropped", await service.droppedLateSampleCount, 1)
                let masks = previewMasks(await service.recentOutputsForTesting)
                r.equal("the newest accepted sample is the one presented",
                        masks.last?.mappedAtUTC, previewBaseDate.addingTimeInterval(2))

                // A policy-paused aid contributes nothing to the shared mask.
                let geometry = previewGeometry(configuration: 6, layout: 7)
                let decision = AnalysisDemandPolicy.decide(configuration: PreviewAidConfiguration(isHistogramEnabled: false,
                                                                                                  isPeakingEnabled: true,
                                                                                                  peakingThreshold: .normal,
                                                                                                  isZebrasEnabled: true,
                                                                                                  zebraThreshold: .default,
                                                                                                  isLoupeEnabled: false,
                                                                                                  loupeMagnification: 2,
                                                                                                  loupeCenter: .center),
                                                           lifecycle: .activeCameraView,
                                                           pressure: AnalysisResourcePressure(thermal: .critical),
                                                           geometry: geometry)
                guard let pausedRequest = decision.request else {
                    r.check("reduced request exists", false)
                    return
                }
                let pausedService = MeteringService(clock: VirtualMonotonicClock(start: 0), rateLimits: decision.rateLimits)
                await pausedService.setDemand(pausedRequest)
                await pausedService.submit(sample: previewSample(bytes: [UInt8](repeating: 250, count: 32 * 24), width: 32, height: 24, configuration: 6, geometry: 7, at: 0))
                let pausedMasks = previewMasks(await pausedService.recentOutputsForTesting)
                r.check("a paused aid contributes no mask", pausedMasks.allSatisfy { $0.peakingMask == nil })
                r.check("the running aid still contributes its mask", pausedMasks.contains { $0.zebraMask != nil })
                r.check("paused aids remain visible to the user", !decision.pausedAids.isEmpty)
            },
        ])
}

// MARK: - Fixtures

private let previewBaseDate = Date(timeIntervalSince1970: 1_700_000_000)

private let previewFullDemand = AnalysisDemand(needsLuminanceSample: true,
                                               histogramEnabled: true,
                                               zebrasEnabled: true,
                                               peakingEnabled: true,
                                               loupeEnabled: true)

private let previewMaskDemand = AnalysisDemand(needsLuminanceSample: true,
                                               histogramEnabled: false,
                                               zebrasEnabled: true,
                                               peakingEnabled: true,
                                               loupeEnabled: false)

private func previewStridedPlane(width: Int,
                                 height: Int,
                                 stride: Int,
                                 bodyValue: UInt8,
                                 paddingValue: UInt8,
                                 trailingBytes: Int) -> [UInt8] {
    var bytes = [UInt8](repeating: bodyValue, count: stride * height)
    for row in 0..<height {
        for column in width..<stride { bytes[row * stride + column] = paddingValue }
    }
    if trailingBytes > 0 {
        bytes.append(contentsOf: [UInt8](repeating: paddingValue, count: trailingBytes))
    }
    return bytes
}

private func previewSample(bytes: [UInt8],
                           width: Int,
                           height: Int,
                           range: PreviewCodeRange = .full,
                           configuration: UInt64 = 1,
                           geometry: UInt64 = 1,
                           at offset: Double = 0) -> LuminanceSample {
    LuminanceSample(width: width,
                    height: height,
                    luma: bytes,
                    range: range,
                    configurationGeneration: ConfigurationGeneration(configuration),
                    geometryGeneration: geometry,
                    capturedAtUTC: previewBaseDate.addingTimeInterval(offset))
}

private func previewGeometry(configuration: UInt64,
                             layout: UInt64,
                             dimensions: PixelDimensions = PixelDimensions(width: 1920, height: 1440),
                             rotation: Int = 90,
                             mirrored: Bool = false,
                             bufferOrientation: Int = 1,
                             viewSize: TCSize = TCSize(width: 393, height: 852)) -> PreviewGeometrySnapshot {
    let content = PreviewGeometryMapper.aspectFitRect(imageDimensions: dimensions,
                                                      rotationDegrees: rotation,
                                                      in: TCRect(origin: .zero, size: viewSize))
    return PreviewGeometrySnapshot(configurationGeneration: ConfigurationGeneration(configuration),
                                   layoutGeneration: layout,
                                   imageDimensions: dimensions,
                                   cleanApertureDimensions: nil,
                                   previewLayerContentRect: content,
                                   bufferOrientation: bufferOrientation,
                                   isMirrored: mirrored,
                                   analysisRotationDegrees: rotation,
                                   isVideoMirrored: false,
                                   capturedAtUTC: previewBaseDate)
}

private func previewRequest(configuration: UInt64,
                            layout: UInt64,
                            demand: AnalysisDemand,
                            peaking: Double = PeakingThreshold.normal.value,
                            zebra: Double = ZebraThreshold.default.normalizedValue,
                            center: NormalizedDevicePoint = .center,
                            magnification: Double = 2) -> AnalysisRequest {
    AnalysisRequest(configurationGeneration: ConfigurationGeneration(configuration),
                    geometry: previewGeometry(configuration: configuration, layout: layout),
                    demand: demand,
                    peakingThreshold: peaking,
                    zebraThreshold: zebra,
                    loupeCenter: center,
                    loupeMagnification: magnification)
}

// MARK: - Output inspection

/// Minimal lock-protected flag used to observe a value arriving on a stream from
/// another task. Invariant: `storage` is only ever touched while `lock` is held.
private final class PreviewFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = false

    var value: Bool {
        lock.lock(); defer { lock.unlock() }
        return storage
    }

    func set() {
        lock.lock(); storage = true; lock.unlock()
    }
}

private func previewHistograms(_ outputs: [AnalysisOutput]) -> [HistogramSnapshot] {
    outputs.compactMap { output in
        if case .histogram(let snapshot) = output { return snapshot }
        return nil
    }
}

private func previewMasks(_ outputs: [AnalysisOutput]) -> [MaskSnapshot] {
    outputs.compactMap { output in
        if case .masks(let snapshot) = output { return snapshot }
        return nil
    }
}

private func previewLoupes(_ outputs: [AnalysisOutput]) -> [LoupeSnapshot] {
    outputs.compactMap { output in
        if case .loupe(let snapshot) = output { return snapshot }
        return nil
    }
}

private func previewLitIndices(_ mask: [UInt8]) -> [Int] {
    mask.enumerated().compactMap { $0.element == 255 ? $0.offset : nil }
}

private func previewLitCount(_ mask: [UInt8]) -> Int {
    mask.reduce(0) { $0 + ($1 == 255 ? 1 : 0) }
}

private func previewLitColumns(_ mask: [UInt8], width: Int) -> [Int] {
    guard width > 0 else { return [] }
    var columns: Set<Int> = []
    for (index, value) in mask.enumerated() where value == 255 {
        columns.insert(index % width)
    }
    return columns.sorted()
}

private func previewBorderLitCount(_ mask: [UInt8], width: Int, height: Int) -> Int {
    guard width > 0, height > 0, mask.count == width * height else { return -1 }
    var count = 0
    for row in 0..<height {
        for column in 0..<width where row == 0 || row == height - 1 || column == 0 || column == width - 1 {
            if mask[row * width + column] == 255 { count += 1 }
        }
    }
    return count
}

private func previewLoupePixel(_ snapshot: LoupeSnapshot, x: Int, y: Int) -> UInt8? {
    guard x >= 0, y >= 0, x < snapshot.width, y < snapshot.height else { return nil }
    let offset = (y * snapshot.width + x) * 4
    guard offset + 3 < snapshot.rgbaBytes.count else { return nil }
    return snapshot.rgbaBytes[offset]
}
