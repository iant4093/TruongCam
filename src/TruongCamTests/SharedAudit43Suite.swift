import Foundation
import Synchronization
#if canImport(XCTest)
@testable import TruongCam
#endif

/// Source-level concurrency and formatting regressions, with no native camera,
/// provider or performance claims. Every held worker has a bounded release.
enum SharedAudit43Suite {
    // Dispatch's blocking wait is unavailable in an async context on iOS. Run
    // only the bounded semaphore observation on a synchronous dispatch worker.
    private static func wait(_ semaphore: DispatchSemaphore, seconds: Double) async -> Bool {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: semaphore.wait(timeout: .now() + seconds) == .success)
            }
        }
    }
    static let suite = TCSuite(id: "SharedAudit43", title: "Shared queue ownership, publication ordering and bounded formatting", cases: [
        TCCase(id: "SH43Q", title: "Different I/O owners retain their own serial queue while same-owner nesting is reentrant") { r in
            let a = BlockingIOOwner(label: "TruongCam.test.audit43.owner-a")
            let b = BlockingIOOwner(label: "TruongCam.test.audit43.owner-b")
            let began = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
            let nestedFinished = DispatchSemaphore(value: 0)
            let held = Task.detached {
                try? await b.submit {
                    began.signal()
                    return release.wait(timeout: .now() + 2) == .success
                }
            }
            r.check("second owner work is held", await wait(began, seconds: 2))
            DispatchQueue.global().async {
                a.perform { b.perform { nestedFinished.signal() } }
            }
            r.check("different owner cannot bypass held queue", await wait(nestedFinished, seconds: 0.03) == false)
            release.signal()
            r.check("different owner proceeds after its queue releases", await wait(nestedFinished, seconds: 2))
            r.check("held owner released normally", await held.value == true)
            let calls = Mutex(0)
            a.perform { a.perform { calls.withLock { $0 += 1 } } }
            r.equal("same-owner nesting completes once", calls.withLock { $0 }, 1)
        },
        TCCase(id: "SH43B", title: "Concurrent latest-value sends and replay share one publication order") { r in
            #if DEBUG || TC_PORTABLE_VERIFIER
            let began = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
            let firstDone = DispatchSemaphore(value: 0), secondDone = DispatchSemaphore(value: 0)
            let secondAttempted = DispatchSemaphore(value: 0), replayAttempted = DispatchSemaphore(value: 0)
            let replayDone = DispatchSemaphore(value: 0)
            let replay = Mutex<AsyncStream<Int>?>(nil)
            let broadcaster = LatestValueBroadcaster<Int>(beforeDelivery: { value in
                if value == 1 { began.signal(); _ = release.wait(timeout: .now() + 2) }
            })
            let stream = broadcaster.subscribe(replayLatest: false)
            DispatchQueue.global().async { broadcaster.send(1); firstDone.signal() }
            r.check("first publication held before delivery", await wait(began, seconds: 2))
            DispatchQueue.global().async { secondAttempted.signal(); broadcaster.send(2); secondDone.signal() }
            DispatchQueue.global().async {
                replayAttempted.signal()
                let subscribed = broadcaster.subscribe()
                replay.withLock { $0 = subscribed }
                replayDone.signal()
            }
            r.check("second send reaches boundary", await wait(secondAttempted, seconds: 2))
            r.check("replay reaches boundary", await wait(replayAttempted, seconds: 2))
            r.check("new send cannot overtake held delivery", await wait(secondDone, seconds: 0.03) == false)
            r.check("replay cannot overtake held delivery", await wait(replayDone, seconds: 0.03) == false)
            r.equal("latest remains first admitted value", broadcaster.current, 1)
            release.signal()
            r.check("first publication completes", await wait(firstDone, seconds: 2))
            r.check("second publication completes", await wait(secondDone, seconds: 2))
            r.check("replay subscription completes", await wait(replayDone, seconds: 2))
            broadcaster.finish()
            var iterator = stream.makeAsyncIterator()
            r.equal("subscriber ends with same latest as registry", await iterator.next(), broadcaster.current)
            r.equal("publication final value", broadcaster.current, 2)
            if let replayStream = replay.withLock({ $0 }) {
                var iterator = replayStream.makeAsyncIterator()
                r.equal("replay cannot overwrite newer publication", await iterator.next(), 2)
            } else { r.check("replay stream exists", false) }
            #else
            r.check("delivery hold seam is only compiled into test/debug code", true)
            #endif
        },
        TCCase(id: "SH43F", title: "Finish drains admitted publication and cancellation cannot deadlock registry cleanup") { r in
            #if DEBUG || TC_PORTABLE_VERIFIER
            let began = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
            let finishAttempted = DispatchSemaphore(value: 0), finishDone = DispatchSemaphore(value: 0)
            let broadcaster = LatestValueBroadcaster<Int>(beforeDelivery: { _ in
                began.signal(); _ = release.wait(timeout: .now() + 2)
            })
            let stream = broadcaster.subscribe(replayLatest: false)
            DispatchQueue.global().async { broadcaster.send(7) }
            r.check("publication admitted", await wait(began, seconds: 2))
            DispatchQueue.global().async { finishAttempted.signal(); broadcaster.finish(); finishDone.signal() }
            r.check("finish attempts during publication", await wait(finishAttempted, seconds: 2))
            r.check("finish cannot discard admitted publication", await wait(finishDone, seconds: 0.03) == false)
            release.signal()
            r.check("finish completes after publication", await wait(finishDone, seconds: 2))
            var iterator = stream.makeAsyncIterator()
            r.equal("admitted value survives finish", await iterator.next(), 7)
            r.equal("finished stream terminates", await iterator.next(), nil)
            let late = broadcaster.subscribe()
            var lateIterator = late.makeAsyncIterator()
            r.equal("late subscriber gets final replay", await lateIterator.next(), 7)
            r.equal("late subscriber terminates", await lateIterator.next(), nil)
            broadcaster.send(8)
            r.equal("post-finish send rejected", broadcaster.current, 7)
            #endif
            let cancelledBroadcaster = LatestValueBroadcaster<Int>()
            let cancelledStream = cancelledBroadcaster.subscribe(replayLatest: false)
            let task = Task { for await _ in cancelledStream {} }
            task.cancel()
            await task.value
            cancelledBroadcaster.send(1)
            cancelledBroadcaster.finish()
            r.equal("termination cleanup leaves publication usable", cancelledBroadcaster.current, 1)
        },
        TCCase(id: "SH43E", title: "External exposure numbers cannot trap presentation while ordinary values keep their labels") { r in
            for value in [Double.nan, .infinity, -.infinity, 0, -1, Double.greatestFiniteMagnitude, Double.leastNonzeroMagnitude] {
                r.equal("safe duration \(value)", ExposureFormatting.duration(value), "—")
            }
            for value in [Double.nan, .infinity, -.infinity, 0, -1, Double.greatestFiniteMagnitude, Double(Int.max)] {
                r.equal("safe ISO \(value)", ExposureFormatting.iso(value), "—")
            }
            r.equal("integer duration unchanged", ExposureFormatting.duration(2), "2s")
            r.equal("fractional duration unchanged", ExposureFormatting.duration(1.3), "1.3s")
            r.equal("reciprocal unchanged", ExposureFormatting.duration(1.0 / 125), "1/125s")
            r.equal("rounded ISO unchanged", ExposureFormatting.iso(799.8), "800")
            r.equal("low ISO unchanged", ExposureFormatting.iso(64), "64")
        }
    ])
}
