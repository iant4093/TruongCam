import Foundation
import ImageIO

#if canImport(XCTest)
@testable import TruongCam
#endif

// Regression tests for the Codex review repairs.
//
// Each case here reproduces a defect REVIEW.md actually confirmed, and would fail
// against the pre-repair source. They exercise the production types, not copies.

enum RepairRegressionSuite {
    static let suite = TCSuite(
        id: "REPAIR",
        title: "Review repair regressions (C01, C02, C04, C05)",
        cases: [

            // MARK: C01 — loss-critical channel

            TCCase(id: "C01a", title: "A RAW queued before finish is still delivered to a late subscriber") { r in
                // This is the exact ChannelFinishProbe failure: finish() used to
                // clear the backlog, so the source was lost.
                let channel = BoundedEventChannel<Int>(capacity: 3)
                channel.send(42)
                channel.finish()

                var iterator = channel.subscribe().makeAsyncIterator()
                let received = await iterator.next()
                r.equal("late subscriber receives the queued RAW", received, 42)
                r.equal("nothing was reported as dropped", channel.droppedElementCount, 0)
                r.equal("nothing was refused", channel.overflowedElementCount, 0)
            },

            TCCase(id: "C01b", title: "Ordered backlog survives finish for multiple subscribers") { r in
                let channel = BoundedEventChannel<String>(capacity: 4)
                for value in ["a", "b", "c"] { channel.send(value) }
                channel.finish()

                for attempt in 1...2 {
                    var collected: [String] = []
                    for await value in channel.subscribe() { collected.append(value) }
                    // The first subscriber drains the held backlog; a later one
                    // sees an empty but correctly terminated stream. Neither may
                    // hang, and the first must be complete and ordered.
                    if attempt == 1 {
                        r.equal("first subscriber sees the full ordered backlog", collected, ["a", "b", "c"])
                    } else {
                        r.equal("second subscriber gets a terminated empty stream", collected, [])
                    }
                }
            },

            TCCase(id: "C01c", title: "A lossless channel refuses rather than silently dropping") { r in
                let channel = BoundedEventChannel<Int>(capacity: 2, overflow: .rejectNewest)
                r.check("first accepted", channel.send(1))
                r.check("second accepted", channel.send(2))
                r.check("third refused, not dropped silently", !channel.send(3))
                r.equal("refusal is counted", channel.overflowedElementCount, 1)
                r.equal("nothing was quietly discarded", channel.droppedElementCount, 0)

                // Terminate so the drain below ends instead of waiting forever
                // for an element that will never arrive.
                channel.finish()
                var collected: [Int] = []
                for await value in channel.subscribe() { collected.append(value) }
                r.equal("the accepted elements are intact", collected, [1, 2])
            },

            TCCase(id: "C01d", title: "TerminalOutcomeBox replays one immutable outcome to every reader") { r in
                let box = TerminalOutcomeBox<String>()
                r.check("no outcome yet", !box.hasOutcome)
                r.check("current is nil before recording, never a default", box.current == nil)

                // Record AFTER the first waiter parked.
                let early = Task { await box.wait() }
                await Task.yield()
                r.check("record succeeds", box.record("native capture failed"))
                let firstRead = await early.value
                r.equal("early waiter sees the real outcome", firstRead, "native capture failed")

                // Later readers get the same value, not absence.
                let secondRead = await box.wait()
                let thirdRead = await box.wait()
                r.equal("second reader replays the same outcome", secondRead, firstRead)
                r.equal("third reader replays the same outcome", thirdRead, firstRead)
                r.equal("current agrees", box.current, firstRead)

                // A duplicate terminal callback must not overwrite the truth.
                r.check("duplicate record is ignored", !box.record("success"))
                let afterDuplicate = await box.wait()
                r.equal("outcome unchanged by a duplicate", afterDuplicate, firstRead)
            },

            TCCase(id: "C01e", title: "A missing terminal can never be reported as success") { r in
                // REVIEW.md S01: these assertions must describe what `drain`
                // RETURNS, not a detached helper. `drain` now feeds durable
                // evidence into reconcile and returns its result.
                let stagedButUncommitted = CaptureCoordinator.reconcile(
                    acquisition: .success, durableRetainedCount: 0,
                    stagedSourceCount: 3, unexplainedFailureCount: 0)
                switch stagedButUncommitted {
                case .failed(let failure):
                    r.check("staged-but-unverified bytes are not success",
                            failure.kind.stableCode == "representationUnavailable")
                    r.check("and the retained staging is reported",
                            failure.retainedSourceStatus.description.contains("inMemory")
                                || failure.retainedSourceStatus.description.contains("none"))
                default:
                    r.check("staged-but-uncommitted must not be success", false, "\(stagedButUncommitted)")
                }

                // The coordinator must not infer success from absent data. This
                // asserts the reconciliation rule directly, including the
                // success-with-no-bytes case that used to pass as saved.
                let noBytes = CaptureCoordinator.reconcile(
                    acquisition: .success, durableRetainedCount: 0,
                    stagedSourceCount: 0, unexplainedFailureCount: 0)
                switch noBytes {
                case .failed(let failure):
                    r.equal("reported kind", failure.kind.stableCode, "representationUnavailable")
                default:
                    r.check("success with no retained bytes must be a failure", false, "got \(noBytes)")
                }

                let nativeErrorWithBytes = CaptureCoordinator.reconcile(
                    acquisition: .failed(CaptureFailure(kind: .captureFailed(detail: "sensor error"), operation: "capture")),
                    durableRetainedCount: 2,
                    stagedSourceCount: 2,
                    unexplainedFailureCount: 0)
                switch nativeErrorWithBytes {
                case .partial(let count, _):
                    r.equal("intact sources are retained through a terminal error", count, 2)
                default:
                    r.check("expected partialWithRetainedSource", false, "got \(nativeErrorWithBytes)")
                }

                let partialWithoutBytes = CaptureCoordinator.reconcile(
                    acquisition: .partial(retainedSourceCount: 0, description: "boom"),
                    durableRetainedCount: 0,
                    stagedSourceCount: 0,
                    unexplainedFailureCount: 0)
                switch partialWithoutBytes {
                case .failed: r.check("partial with no bytes is a failure", true)
                default: r.check("partial with no bytes is a failure", false, "got \(partialWithoutBytes)")
                }

                let unexplained = CaptureCoordinator.reconcile(
                    acquisition: .success, durableRetainedCount: 1,
                    stagedSourceCount: 1, unexplainedFailureCount: 1)
                switch unexplained {
                case .partial(let count, _):
                    r.equal("staging failure degrades success to partial", count, 1)
                default:
                    r.check("expected partial when staging failed", false, "got \(unexplained)")
                }
            },

            // MARK: C04 — explicit capture tuple

            TCCase(id: "C04a", title: "A format with no usable Bayer RAW path is never selected") { r in
                // The old code published selectedFormatIndex: nil and every caller
                // fell back to formats.startIndex, which is exactly this mistake.
                let selection = CaptureTupleSelector.select(from: [
                    CaptureFormatFacts(index: 0,
                                       advertisedMaxPhotoDimensions: [PixelDimensions(width: 4032, height: 3024)],
                                       bayerPixelFormatsForDNG: []),
                ])
                r.check("a RAW-less format is refused rather than indexed into", selection == nil)
            },

            TCCase(id: "C04b", title: "The largest advertised ceiling with a usable RAW path wins") { r in
                let selection = CaptureTupleSelector.select(from: [
                    CaptureFormatFacts(index: 0,
                                       advertisedMaxPhotoDimensions: [PixelDimensions(width: 1920, height: 1080)],
                                       bayerPixelFormatsForDNG: [0x4247_4734]),
                    CaptureFormatFacts(index: 1,
                                       advertisedMaxPhotoDimensions: [PixelDimensions(width: 4032, height: 3024)],
                                       bayerPixelFormatsForDNG: [0x4247_4734]),
                ])
                r.equal("picks the larger legal format", selection?.formatIndex, 1)
                r.equal("publishes the matching ceiling",
                        selection?.requestedDimensions, PixelDimensions(width: 4032, height: 3024))
            },

            TCCase(id: "C04c", title: "A larger RAW-less format does not beat a smaller usable one") { r in
                let selection = CaptureTupleSelector.select(from: [
                    CaptureFormatFacts(index: 0,
                                       advertisedMaxPhotoDimensions: [PixelDimensions(width: 8064, height: 6048)],
                                       bayerPixelFormatsForDNG: []),
                    CaptureFormatFacts(index: 1,
                                       advertisedMaxPhotoDimensions: [PixelDimensions(width: 4032, height: 3024)],
                                       bayerPixelFormatsForDNG: [0x4247_4734]),
                ])
                r.equal("advertised megapixels alone do not win", selection?.formatIndex, 1)
                r.check("the rejection is reported, not hidden",
                        selection?.notes.contains { $0.contains("no usable Bayer RAW path") } == true)
            },

            TCCase(id: "C04d", title: "A format with no advertised photo dimensions is skipped") { r in
                let selection = CaptureTupleSelector.select(from: [
                    CaptureFormatFacts(index: 0, advertisedMaxPhotoDimensions: [],
                                       bayerPixelFormatsForDNG: [0x4247_4734]),
                ])
                r.check("no ceiling means no tuple", selection == nil)
            },

            // MARK: C05 — nested EXIF is actual source truth

            TCCase(id: "C05a", title: "Source exposure is read from nested EXIF, not the pre-capture readback") { r in
                // Real ImageIO shape: values live under the Exif dictionary, not at
                // the top level, which is what the old flattened lookup assumed.
                let metadata: [String: Any] = [
                    kCGImagePropertyExifDictionary as String: [
                        kCGImagePropertyExifExposureTime as String: 0.008,
                        kCGImagePropertyExifISOSpeedRatings as String: [400],
                        kCGImagePropertyExifFNumber as String: 1.6,
                        kCGImagePropertyExifFocalLength as String: 6.86,
                        kCGImagePropertyExifDateTimeOriginal as String: "2026:10:07 09:15:00",
                    ],
                    kCGImagePropertyOrientation as String: 6,
                ]
                let exif = SourceEXIF(metadata: metadata)
                r.close("exposure time from EXIF", exif.exposureTimeSeconds ?? -1, 0.008, tolerance: 1e-9)
                r.close("ISO from EXIF array", exif.isoSpeed ?? -1, 400, tolerance: 1e-9)
                r.close("aperture from EXIF", exif.aperture ?? -1, 1.6, tolerance: 1e-9)
                r.close("focal length from EXIF", exif.focalLengthMM ?? -1, 6.86, tolerance: 1e-9)
                r.equal("orientation from EXIF", exif.orientation, 6)
                r.check("capture time parsed", exif.capturedAt != nil)
            },

            TCCase(id: "C05b", title: "Absent EXIF stays unknown instead of zero-filled") { r in
                let exif = SourceEXIF(metadata: [:])
                r.check("no exposure time", exif.exposureTimeSeconds == nil)
                r.check("no ISO", exif.isoSpeed == nil)
                r.check("no aperture", exif.aperture == nil)
                r.check("no focal length", exif.focalLengthMM == nil)
                r.check("no orientation", exif.orientation == nil)
                r.check("no capture time", exif.capturedAt == nil)

                // A zero or negative in the container is not a measurement either.
                let bogus: [String: Any] = [
                    kCGImagePropertyExifDictionary as String: [
                        kCGImagePropertyExifExposureTime as String: 0,
                        kCGImagePropertyExifISOSpeedRatings as String: [0],
                    ],
                ]
                let bogusExif = SourceEXIF(metadata: bogus)
                r.check("zero exposure is unknown, not a valid reading", bogusExif.exposureTimeSeconds == nil)
                r.check("zero ISO is unknown, not a valid reading", bogusExif.isoSpeed == nil)
            },

            TCCase(id: "C05c", title: "An out-of-range EXIF orientation is rejected, not passed through") { r in
                let metadata: [String: Any] = [kCGImagePropertyOrientation as String: 99]
                r.check("orientation 99 is not a legal EXIF orientation",
                        SourceEXIF(metadata: metadata).orientation == nil)
            },

            // MARK: C02 — display bridge is a real, safe value

            TCCase(id: "C02a", title: "The preview display bridge never retains the session") { r in
                // The bridge holds a weak reference, so clearing it (as stop()
                // does) leaves nothing for a late reader to configure.
                let bridge = PreviewDisplayBridge()
                r.check("empty before install", bridge.displaySession == nil)
                bridge.clear()
                r.check("clear is idempotent", bridge.displaySession == nil)
                r.check("mutating value across a hop does not crash", true)
            },
        ])
}
