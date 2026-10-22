import Foundation

// Native test bundles read the app's real types through the module; the
// standalone verifier compiles the app sources into the same executable and
// therefore cannot import a module. XCTest is only available in the native
// bundle, so it gates the import.
#if canImport(XCTest)
@testable import TruongCam
#endif


// CONTRACTS.md bounded-buffer rules: latest-only UI streams, lossless bounded
// event channels that surface overflow instead of growing without limit, and
// admission gates that cannot double-resume.

enum BoundedChannelSuite {
    static let suite = TCSuite(
        id: "T04b-T09",
        title: "Bounded channels, coalescing and admission gates",
        cases: [
            TCCase(id: "T04c", title: "Coalescing applier keeps the newest desired value") { r in
                let applier = CoalescingApplier<Double>()
                for index in 0..<100 {
                    await applier.submit(Double(index), revision: UInt64(index))
                }
                let applied = LockedBox<[Double]>([])
                await applier.drain { value in
                    applied.mutate { $0.append(value) }
                    // Yield so any queued submits can land.
                    await Task.yield()
                }
                let count = await applier.applyCount
                let seen = applied.value
                r.check("latest value applied", seen.last == 99.0, "applied \(seen)")
                r.check("not one device operation per slider update", count < 100,
                        "applied \(count) times")
                r.check("at least one operation", count >= 1)
            },

            TCCase(id: "T04d", title: "A stale revision cannot overwrite a newer desired value") { r in
                let applier = CoalescingApplier<Int>()
                await applier.submit(5, revision: 10)
                await applier.submit(3, revision: 4) // older revision, must be ignored
                let applied = LockedBox<[Int]>([])
                await applier.drain { value in
                    applied.mutate { $0.append(value) }
                    await Task.yield()
                }
                let seen = applied.value
                r.check("newest revision won", seen.last == 5, "applied \(seen)")
            },

            TCCase(id: "T09a", title: "AsyncGate admits one holder and never double-resumes") { r in
                let gate = AsyncGate()
                r.check("starts free", await !gate.held)
                let acquired = await gate.tryAcquire()
                r.check("first tryAcquire succeeds", acquired)
                let second = await gate.tryAcquire()
                r.check("second tryAcquire fails while held", !second)

                // A waiter must resume exactly once when the holder releases.
                let waiterFinished = LockedFlag()
                let task = Task {
                    await gate.acquire()
                    waiterFinished.set()
                }
                // Give the waiter a chance to park.
                for _ in 0..<20 where await gate.held == false { await Task.yield() }
                await gate.release()
                _ = await task.value
                r.check("waiter resumed exactly once", waiterFinished.value)
                await gate.release()
                let afterRelease = await gate.tryAcquire()
                r.check("gate is acquirable again", afterRelease)
            },

            TCCase(id: "T04e", title: "Latest-value broadcaster keeps only the newest sample") { r in
                let broadcaster = LatestValueBroadcaster<Int>()
                for index in 0..<1000 { broadcaster.send(index) }
                r.equal("only newest retained", broadcaster.current, 999)

                // Bounded latest-only delivery: consuming the current value must
                // not require a later producer event to complete, and producer
                // pressure must never grow memory.
                let received = LockedBox<[Int]>([])
                let stream = broadcaster.subscribe()
                for await value in stream {
                    received.mutate { $0.append(value) }
                    break
                }
                r.equal("subscriber receives the retained newest value", received.value, [999])

                for index in 1000..<5000 { broadcaster.send(index) }
                r.equal("producer pressure keeps only the newest value", broadcaster.current, 4999)

                let received2 = LockedBox<[Int]>([])
                let stream2 = broadcaster.subscribe()
                for await value in stream2 {
                    received2.mutate { $0.append(value) }
                    break
                }
                r.equal("second subscriber also sees only the newest", received2.value, [4999])
                broadcaster.finish()
            },

            TCCase(id: "T09b", title: "Lossless event channel buffers between producer and consumer") { r in
                let channel = BoundedEventChannel<Int>(capacity: 8, overflow: .dropOldest)
                let stream = channel.subscribe()
                let consumer = Task { () -> [Int] in
                    var out: [Int] = []
                    for await value in stream {
                        out.append(value)
                        if out.count == 5 { break }
                    }
                    return out
                }
                for index in 0..<5 { channel.send(index) }
                let received = await consumer.value
                r.equal("all five delivered in order", received, [0, 1, 2, 3, 4])
                r.equal("nothing dropped", channel.droppedElementCount, 0)
                channel.finish()
            },

            TCCase(id: "T09c", title: "Overflow is counted, never silently unbounded") { r in
                // With no subscriber the channel buffers up to capacity, then
                // drops the oldest and reports it.
                let channel = BoundedEventChannel<Int>(capacity: 4, overflow: .dropOldest)
                for index in 0..<10 { channel.send(index) }
                r.equal("overflow counted", channel.droppedElementCount, 6)
                let stream = channel.subscribe()
                let consumer = Task { () -> [Int] in
                    var out: [Int] = []
                    for await value in stream {
                        out.append(value)
                        if out.count == 4 { break }
                    }
                    return out
                }
                let received = await consumer.value
                r.equal("newest four retained", received, [6, 7, 8, 9])
                channel.finish()
            },

            TCCase(id: "T09d", title: "Virtual clock deadlines are deterministic and monotonic") { r in
                let clock = VirtualMonotonicClock(start: 100)
                r.close("start", clock.now(), 100)
                clock.advance(by: 2.5)
                r.close("advanced", clock.now(), 102.5)
                clock.advance(to: 50)
                r.close("advance(to:) never moves backwards", clock.now(), 102.5)
                clock.advance(to: 200)
                r.close("advance(to:) forward", clock.now(), 200)

                let resumed = LockedFlag()
                let task = Task {
                    try await clock.sleep(until: 210)
                    resumed.set()
                }
                // Not due yet.
                for _ in 0..<5 { await Task.yield() }
                r.check("waiter still parked before deadline", !resumed.value)
                clock.advance(to: 211)
                _ = try? await task.value
                r.check("waiter resumed at deadline", resumed.value)
            },
        ])
}

/// Minimal lock-protected box for observing values written from another task.
final class LockedBox<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: Value

    init(_ initial: Value) { storage = initial }

    var value: Value {
        lock.lock(); defer { lock.unlock() }
        return storage
    }

    func mutate(_ body: (inout Value) -> Void) {
        lock.lock(); body(&storage); lock.unlock()
    }
}

/// Minimal lock-protected flag used to observe cross-task completion.
final class LockedFlag: @unchecked Sendable {
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
