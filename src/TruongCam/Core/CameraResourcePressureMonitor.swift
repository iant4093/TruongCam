import Foundation
@preconcurrency import Dispatch

/// Actual process/resource events affect optional preview work only. A source
/// revision rejects delivery that crosses the MainActor hop out of order.
struct CameraResourcePressureSnapshot: Hashable, Sendable {
    var thermal: ResourcePressureLevel = .nominal
    var memory: ResourcePressureLevel = .nominal
    var isLowPowerMode = false
    var revision: UInt64 = 0
    func analysisPressure(pendingOriginalCount: Int) -> AnalysisResourcePressure {
        AnalysisResourcePressure(thermal: thermal, memoryWarningCount: memory == .nominal ? 0 : 1,
            isLowPowerMode: isLowPowerMode, pendingOriginalCount: pendingOriginalCount)
    }
}

protocol CameraResourcePressureMonitoring: AnyObject, Sendable {
    func start(onChange: @escaping @Sendable (CameraResourcePressureSnapshot) -> Void)
    func stop()
}

/// Foundation notifications and GCD memory-pressure events are public in the
/// installed iOS 27 SDK. Memory recovery comes only from an actual `.normal`
/// event, never an elapsed-time guess or destructive cache traversal.
///
/// `@unchecked Sendable`: callback/revision/tokens/source are protected by lock;
/// resource refreshes are serialized on queue. Framework callbacks enqueue only
/// small state reads; no native camera, bitmap, original or per-frame work runs.
final class SystemCameraResourcePressureMonitor: CameraResourcePressureMonitoring, @unchecked Sendable {
    private final class MemoryObservation: @unchecked Sendable {
        let source: any DispatchSourceMemoryPressure
        init(_ source: any DispatchSourceMemoryPressure) { self.source = source }
    }
    private let lock = NSLock()
    private let queue = DispatchQueue(label: "TruongCam.resource-events", qos: .utility)
    private let center: NotificationCenter
    private let process: ProcessInfo
    private var handler: (@Sendable (CameraResourcePressureSnapshot) -> Void)?
    private var epoch: UInt64 = 0
    private var revision: UInt64 = 0
    private var memory: ResourcePressureLevel = .nominal
    private var last: CameraResourcePressureSnapshot?
    private var tokens: [NSObjectProtocol] = []
    private var observation: MemoryObservation?

    init(center: NotificationCenter = .default, process: ProcessInfo = .processInfo) {
        self.center = center; self.process = process
    }
    func start(onChange: @escaping @Sendable (CameraResourcePressureSnapshot) -> Void) {
        stop()
        // The SDK explicitly requires accessing thermalState before registering.
        _ = process.thermalState
        lock.lock(); epoch &+= 1; let owner = epoch; handler = onChange; last = nil; lock.unlock()
        let names = [ProcessInfo.thermalStateDidChangeNotification, .NSProcessInfoPowerStateDidChange]
        let added = names.map { name in
            center.addObserver(forName: name, object: process, queue: nil) { [weak self] _ in
                self?.enqueueRefresh(owner: owner)
            }
        }
        let source = DispatchSource.makeMemoryPressureSource(eventMask: [.normal, .warning, .critical], queue: queue)
        let memoryObservation = MemoryObservation(source)
        source.setEventHandler { [weak self, weak memoryObservation] in
            guard let memoryObservation else { return }
            let flags = memoryObservation.source.data
            let level: ResourcePressureLevel?
            if flags.contains(.critical) { level = .critical }
            else if flags.contains(.warning) { level = .elevated }
            else if flags.contains(.normal) { level = .nominal }
            else { level = nil }
            self?.refresh(owner: owner, memoryEvent: level)
        }
        // Balance activation even if stop superseded this registration.
        source.resume()
        lock.lock()
        let retained = epoch == owner && handler != nil
        if retained { tokens = added; observation = memoryObservation }
        lock.unlock()
        if !retained { added.forEach(center.removeObserver); source.cancel(); return }
        enqueueRefresh(owner: owner)
    }
    private func enqueueRefresh(owner: UInt64) {
        queue.async { [weak self] in self?.refresh(owner: owner) }
    }
    private func refresh(owner: UInt64, memoryEvent: ResourcePressureLevel? = nil) {
        let thermal: ResourcePressureLevel
        switch process.thermalState {
        case .nominal: thermal = .nominal
        case .fair, .serious: thermal = .elevated
        case .critical: thermal = .critical
        @unknown default: thermal = .elevated
        }
        let lowPower = process.isLowPowerModeEnabled
        lock.lock()
        guard owner == epoch, let callback = handler else { lock.unlock(); return }
        if let memoryEvent { memory = memoryEvent }
        if let last, last.thermal == thermal, last.memory == memory, last.isLowPowerMode == lowPower {
            lock.unlock(); return
        }
        revision &+= 1
        let snapshot = CameraResourcePressureSnapshot(thermal: thermal, memory: memory,
            isLowPowerMode: lowPower, revision: revision)
        last = snapshot
        lock.unlock()
        callback(snapshot)
    }
    func stop() {
        lock.lock()
        epoch &+= 1; handler = nil; last = nil
        let removed = tokens, memoryObservation = observation
        tokens = []; observation = nil
        lock.unlock()
        removed.forEach(center.removeObserver)
        memoryObservation?.source.cancel()
    }
    deinit { stop() }
}
