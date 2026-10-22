import Foundation
import Synchronization
#if canImport(XCTest)
@testable import TruongCam
#endif

enum PreviewNativeAccessSuite {
    static let suite = TCSuite(id: "PreviewNativeAccess", title: "Native preview handoff", cases: [
        TCCase(id: "PA01", title: "Overlapping native owners cannot resume preview early") { r in
            let gate = PreviewNativeAccessGate()
            r.check("initially available", !gate.snapshot.isPaused)
            let old = await gate.pause()
            let current = await gate.pause()
            r.equal("both operations hold access", gate.snapshot.pauseCount, 2)
            gate.noteNativeMutation()
            let revision = gate.snapshot.revision
            old.release()
            old.release()
            r.equal("obsolete double completion cannot reopen current work", gate.snapshot.pauseCount, 1)
            r.check("preview remains paused", gate.snapshot.isPaused)
            current.release()
            r.check("last owner resumes access", !gate.snapshot.isPaused)
            r.equal("pause/resume alone never changes connection identity", gate.snapshot.revision, revision)
        },
        TCCase(id: "PA02", title: "Concurrent terminal paths release one native lease exactly once") { r in
            let gate = PreviewNativeAccessGate()
            let lease = await gate.pause()
            await withTaskGroup(of: Void.self) { group in
                for _ in 0..<100 { group.addTask { lease.release() } }
            }
            r.equal("one balanced release across racing callbacks", gate.snapshot.pauseCount, 0)
            r.check("access is available", !gate.snapshot.isPaused)
            r.equal("no-op work preserves revision", gate.snapshot.revision, 0)
        },
        TCCase(id: "PA03", title: "Abandoned scope releases without affecting another session") { r in
            let first = PreviewNativeAccessGate(), replacement = PreviewNativeAccessGate()
            var lease: PreviewNativeAccessGate.Lease? = await first.pause()
            r.check("owned lease exists", lease != nil)
            let other = await replacement.pause()
            lease = nil
            r.equal("deinit drains abandoned scope", first.snapshot.pauseCount, 0)
            r.equal("replacement session retains its own fence", replacement.snapshot.pauseCount, 1)
            first.noteNativeMutation()
            r.equal("mutation revision is session-local", replacement.snapshot.revision, 0)
            other.release()
        },
        TCCase(id: "PA04", title: "Native pause drains existing buffer readers and refuses later samples") { r in
            let gate = PreviewNativeAccessGate()
            guard let read = gate.beginFrameRead() else {
                r.check("initial read admits", false); return
            }
            let enteredNative = Mutex(false)
            let native = Task { @MainActor in
                let lease = await gate.pauseAndDrainFrames()
                enteredNative.withLock { $0 = true }
                return lease
            }
            for _ in 0..<200 where gate.snapshot.waitingDrainCount == 0 {
                try? await Task.sleep(for: .milliseconds(1))
            }
            r.equal("one buffer reader remains borrowed", gate.snapshot.frameReadCount, 1)
            r.equal("native work suspends for that reader", gate.snapshot.waitingDrainCount, 1)
            r.check("native work has not entered", !enteredNative.withLock { $0 })
            r.check("later callbacks cannot borrow another buffer", gate.beginFrameRead() == nil)
            read.release()
            read.release()
            let lease = await native.value
            r.check("native proceeds only after borrow release", enteredNative.withLock { $0 })
            r.equal("all borrowed buffers drained", gate.snapshot.frameReadCount, 0)
            r.equal("all drain waiters resumed", gate.snapshot.waitingDrainCount, 0)
            r.check("new reads remain refused through native work", gate.beginFrameRead() == nil)
            lease.release()
            let next = gate.beginFrameRead()
            r.check("next camera callback resumes after graph release", next != nil)
            next?.release()
            r.equal("next callback balances its borrow", gate.snapshot.frameReadCount, 0)
        },
        TCCase(id: "PA05", title: "Concurrent graph waiters drain together without releasing one another") { r in
            let gate = PreviewNativeAccessGate()
            var read: PreviewNativeAccessGate.FrameReadLease? = gate.beginFrameRead()
            r.check("held callback exists", read != nil)
            let first = Task { @MainActor in await gate.pauseAndDrainFrames() }
            let second = Task { @MainActor in await gate.pauseAndDrainFrames() }
            for _ in 0..<200 where gate.snapshot.waitingDrainCount < 2 {
                try? await Task.sleep(for: .milliseconds(1))
            }
            r.equal("both owners await one callback", gate.snapshot.waitingDrainCount, 2)
            r.equal("both pauses are recorded before waiting", gate.snapshot.pauseCount, 2)
            read = nil
            let old = await first.value, current = await second.value
            old.release()
            r.equal("old graph completion retains replacement pause", gate.snapshot.pauseCount, 1)
            r.check("current graph still fences callbacks", gate.beginFrameRead() == nil)
            current.release()
            r.equal("both native scopes balance", gate.snapshot.pauseCount, 0)
            r.equal("abandoned callback releases its borrow", gate.snapshot.frameReadCount, 0)
        }
    ])
}
