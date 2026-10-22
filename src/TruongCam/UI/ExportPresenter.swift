import Foundation
import Observation

#if canImport(UIKit)
import SwiftUI
import UIKit
import Photos
import UniformTypeIdentifiers
import Synchronization
#endif

// LIBRARY.md "Export and deletion" + REVIEW.md C07.
//
// Export must reach the system share sheet with exact bytes, keep its session
// alive until the sheet is dismissed, and report failures. The previous code
// prepared a session inside `try?` and discarded it, so nothing was ever shared
// and every error was hidden.
//
// It also supports exporting a PENDING original directly from internal recovery
// storage. That is exactly when the promised "Export pending original" recovery
// action is needed, and it must not depend on the external root being available.

@MainActor
@Observable
final class ExportPresenter {
    /// ONE frozen export invocation: the surface, the exact sources and the sidecar
    /// choice as they were at the moment the user acted.
    ///
    /// O04: these were previously read from mutable global state INSIDE the scheduled
    /// task, so a later gesture could reroute or re-option an earlier one.
    struct Invocation: Sendable {
        var surface: ExportSurface
        var sources: [CaptureID]
        var includeSidecars: Bool
        var description: String
        /// Present for a PENDING-original invocation, which addresses recovery storage
        /// rather than a committed source (REVIEW.md P04).
        var transactionIDs: [TransactionID] = []
        /// Present for a SEQUENCE invocation (REVIEW.md Q04).
        var sequenceID: SequenceID?
        /// Present for a CONFIRMATION invocation.
        var confirmationAvailable: [CaptureID] = []
        /// The command epoch this invocation was issued under. `unmanagedEpoch` means the
        /// invocation was not issued through a command (REVIEW.md U04).
        var epoch: Int = ExportPresenter.unmanagedEpoch
    }

    /// Monotonic epoch of the most recent export COMMAND. Every entry point — single,
    /// pending, sequence, confirm, cancel — takes one synchronously, and a superseded
    /// command may not present or replace newer state.
    private var commandEpoch = 0

    /// Marks an invocation that is not part of the command epoch.
    nonisolated static let unmanagedEpoch = Int.max

    /// Issues a new command epoch. Call synchronously, before any Task/await.
    func beginCommand() -> Int {
        commandEpoch += 1
        return commandEpoch
    }

    /// Whether `epoch` is still the newest command.
    func isCurrentCommand(_ epoch: Int) -> Bool {
        epoch == Self.unmanagedEpoch || epoch == commandEpoch
    }

    /// Runs a FROZEN pending-original invocation.
    func exportPending(_ invocation: Invocation) async {
        guard isCurrentCommand(invocation.epoch) else { return }
        presentationSurface = invocation.surface
        await exportPending(
            transactionIDs: invocation.transactionIDs,
            description: invocation.description,
            includeSidecars: invocation.includeSidecars,
            epoch: invocation.epoch)
    }

    /// Runs a FROZEN invocation.
    func export(_ invocation: Invocation) async {
        guard isCurrentCommand(invocation.epoch) else { return }
        presentationSurface = invocation.surface
        await export(sources: invocation.sources,
                     includeSidecars: invocation.includeSidecars,
                     description: invocation.description,
                     epoch: invocation.epoch)
    }

    /// The surfaces that can invoke an export. Exactly one owns any presentation.
    enum ExportSurface: String, Hashable, Sendable, CaseIterable {
        case root
        case library
        case sequence
        case viewer
    }

    struct PresentedExport: Identifiable {
        let id = UUID()
        let session: ExportSession
        let sourceDescription: String
    }

    var presented: PresentedExport?

    /// The surface that invoked the export currently being presented. Only this surface
    /// presents it, so competing presenters and duplicate finishes are impossible
    /// (REVIEW.md J07).
    private(set) var presentationSurface: ExportSurface = .root
    /// The surface each PREPARED session belongs to, frozen when it was prepared.
    private var surfaceBySessionID: [UUID: ExportSurface] = [:]

    /// Routes the next presentation to `surface`.
    func routePresentation(to surface: ExportSurface) {
        presentationSurface = surface
    }

    /// Whether `surface` owns the current presentation.
    ///
    /// N04: ownership is decided by the surface the PRESENTED session was prepared for,
    /// falling back to the current route when nothing is presented.
    func ownsPresentation(_ surface: ExportSurface) -> Bool {
        if let presented, let frozen = surfaceBySessionID[presented.session.sessionID] {
            return frozen == surface
        }
        return presentationSurface == surface
    }
    private var preparationCount = 0
    var isPreparingExport: Bool { preparationCount > 0 }
    private(set) var lastFailure: UserFacingFailure?
    private(set) var lastNotice: String?

    /// Dismisses the current notice. Exports never clear a notice implicitly, so
    /// the user decides when they have read it.
    func clearLastNotice() { lastNotice = nil }

    /// Reports a failure raised outside the presenter's own export methods (for
    /// example a failed recovery retry) so one place owns what the user sees
    /// (REVIEW.md R08).
    func reportFailure(_ failure: UserFacingFailure) {
        lastFailure = failure
        lastNotice = nil
    }

    /// Reports an informational outcome on the same surface as failures.
    func reportNotice(_ text: String) {
        lastNotice = text
        lastFailure = nil
    }

    /// Dismisses the current failure. Kept explicit so a view can clear it after
    /// routing the user's chosen action.
    func clearLastFailure() {
        lastFailure = nil
    }
    private let store: (any ExportPreparing)?

    /// Sessions prepared but not yet dismissed. Cleanup waits until none remain so
    /// finishing one share cannot delete another's files (REVIEW.md C07).
    private var activeSessionIDs: Set<UUID> = []
    /// Native readers own these copies through the sheet's actual dismissal,
    /// including activity completion and temporary covering presentations.
    private var presentedSessionIDs: Set<UUID> = []

    init(store: (any ExportPreparing)?) {
        self.store = store
    }

    // MARK: Committed originals

    func export(sources: [CaptureID], includeSidecars: Bool, description: String,
                epoch: Int = unmanagedEpoch) async {
        preparationCount += 1
        #if DEBUG
        let prepareBegan = ProcessInfo.processInfo.systemUptime
        #endif
        defer {
            preparationCount -= 1
            #if DEBUG
            print("TruongCam timing export-prepare=\(Int((ProcessInfo.processInfo.systemUptime - prepareBegan) * 1000))ms count=\(sources.count)")
            #endif
        }

        // N04: the invoking surface is frozen BEFORE any suspension, so a route change
        // while this export prepares cannot reroute it.
        let invocationSurface = presentationSurface
        guard let store else {
            AppDiagnostics.record("No ExportPreparing storage is attached", operation: "export.unavailable")
            lastFailure = UserFacingFailure(
                title: "Export unavailable",
                detail: "Reconnect your library folder, then try again.",
                actions: [.dismiss])
            return
        }
        guard !sources.isEmpty else {
            lastFailure = UserFacingFailure(
                title: "Nothing to export",
                detail: "Choose a photo to export.",
                actions: [.dismiss])
            return
        }
        do {
            let session = try await store.prepareOriginalExport(
                sourceIDs: sources, includeSidecars: includeSidecars)
            // The frozen invocation surface travels with this session's presentation.
            // U04: re-checked at the PUBLICATION boundary, after the preparation await, so a
            // command superseded while preparing cannot present or replace newer state.
            guard isCurrentCommand(epoch) else {
                await store.discardExport(sessionID: session.sessionID)
                return
            }
            surfaceBySessionID[session.sessionID] = invocationSurface
            present(session, description: description)
        } catch let failure as CaptureFailure {
            guard isCurrentCommand(epoch) else { return }
            lastFailure = UserFacingFailure.from(failure)
        } catch {
            guard isCurrentCommand(epoch) else { return }
            lastFailure = UserFacingFailure(title: "Export failed", detail: UserFacingFailure.message(for: error), actions: [.dismiss])
        }
    }

    /// Prepares an export without presenting it, reporting what is actually missing.
    ///
    /// REVIEW.md G06: `export` prepared and shared in one step, so a source discovered
    /// missing during preparation was silently dropped from the shared subset. A caller
    /// that must confirm real absences first uses this, then `present(_:description:)`
    /// only after the user accepts.
    enum PreparationOutcome: Sendable {
        case ready(ExportSession)
        /// Nothing could be prepared at all.
        case nothingAvailable(missing: [String])
        case failed(UserFacingFailure)
    }

    /// Prepares a FROZEN invocation's sources, so a later option or route change cannot
    /// affect what this invocation discovers or shares (REVIEW.md Q04).
    func prepare(_ invocation: Invocation) async -> PreparationOutcome {
        presentationSurface = invocation.surface
        return await prepare(
            sources: invocation.sources, includeSidecars: invocation.includeSidecars)
    }

    func prepare(sources: [CaptureID],
                 includeSidecars: Bool) async -> PreparationOutcome {
        preparationCount += 1
        #if DEBUG
        let prepareBegan = ProcessInfo.processInfo.systemUptime
        #endif
        defer {
            preparationCount -= 1
            #if DEBUG
            print("TruongCam timing export-prepare=\(Int((ProcessInfo.processInfo.systemUptime - prepareBegan) * 1000))ms count=\(sources.count)")
            #endif
        }

        // N04: frozen BEFORE any suspension, so a route change during preparation cannot
        // reroute this invocation.
        let invocationSurface = presentationSurface
        guard let store else {
            AppDiagnostics.record("No ExportPreparing storage is attached", operation: "export.prepare.unavailable")
            return .failed(UserFacingFailure(
                title: "Export unavailable",
                detail: "Reconnect your library folder, then try again.",
                actions: [.dismiss]))
        }
        guard !sources.isEmpty else {
            return .failed(UserFacingFailure(
                title: "Nothing to export",
                detail: "Choose a photo to export.",
                actions: [.dismiss]))
        }
        do {
            let session = try await store.prepareOriginalExport(
                sourceIDs: sources, includeSidecars: includeSidecars)
            if session.fileURLs.isEmpty {
                return .nothingAvailable(missing: session.missingItems)
            }
            // Registered as live BEFORE it is returned, so cancel/replacement can clean
            // exactly this directory and the global cleanup cannot run underneath it.
            activeSessionIDs.insert(session.sessionID)
            // N04: the surface frozen at INVOCATION time travels with this session.
            surfaceBySessionID[session.sessionID] = invocationSurface
            return .ready(session)
        } catch let failure as CaptureFailure {
            return .failed(UserFacingFailure.from(failure))
        } catch {
            return .failed(UserFacingFailure(
                title: "Export failed", detail: UserFacingFailure.message(for: error), actions: [.dismiss]))
        }
    }

    /// Releases a prepared session that will not be shared, cleaning ONLY it.
    ///
    /// REVIEW.md J07: cancelling or replacing one prepared export must not remove another
    /// live export's copies, and it must not clear a newer presentation.
    func discardPrepared(_ session: ExportSession) async {
        await finished(sessionID: session.sessionID)
    }

    /// Presents an ALREADY PREPARED session. Used after an explicit confirmation.
    func presentPrepared(_ session: ExportSession, description: String) {
        // Q04: the frozen invocation surface travels through consent to presentation.
        if surfaceBySessionID[session.sessionID] == nil {
            surfaceBySessionID[session.sessionID] = presentationSurface
        }
        present(session, description: description)
    }

    /// Freezes the surface for a session prepared by an ALREADY frozen invocation.
    func adoptFrozenSurface(_ surface: ExportSurface, for session: ExportSession) {
        surfaceBySessionID[session.sessionID] = surface
    }

    // MARK: Pending originals

    /// Exports a pending original from durable internal recovery storage.
    ///
    /// Integrity is verified against the recorded digest before the copy is
    /// offered, and the copy is labelled as recovered so it is never presented as
    /// a historical integrity guarantee the app cannot make.
    func exportPending(
        transactionIDs: [TransactionID],
        description: String,
        includeSidecars: Bool = false,
        epoch: Int = unmanagedEpoch
    ) async {
        // O04: frozen BEFORE any suspension, so a route change while the pending export
        // prepares cannot reroute it.
        let invocationSurface = presentationSurface
        guard let store else {
            AppDiagnostics.record("No ExportPreparing storage is attached", operation: "export.unavailable")
            lastFailure = UserFacingFailure(
                title: "Export unavailable",
                detail: "Reconnect your library folder, then try again.",
                actions: [.dismiss])
            return
        }
        guard !transactionIDs.isEmpty else {
            lastFailure = UserFacingFailure(
                title: "Nothing to export",
                detail: "Choose a pending photo to export.",
                actions: [.dismiss])
            return
        }
        do {
            let session = try await store.preparePendingOriginalExport(
                transactionIDs: transactionIDs, includeSidecars: includeSidecars)
            // V04: re-checked AFTER the preparation await. A superseded command disposes its
            // own obsolete copies and publishes nothing.
            guard isCurrentCommand(epoch) else {
                await store.discardExport(sessionID: session.sessionID)
                return
            }
            // O04: the frozen invocation surface travels with this session.
            surfaceBySessionID[session.sessionID] = invocationSurface
            if !session.missingItems.isEmpty {
                AppDiagnostics.record(session.missingItems.joined(separator: "\n"), operation: "exportPending.missing")
            }
            lastNotice = session.missingItems.isEmpty
                ? nil
                : "Some pending photos couldn’t be exported. Try saving or exporting them again."
            present(session, description: description)
        } catch let failure as CaptureFailure {
            guard isCurrentCommand(epoch) else { return }
            lastFailure = UserFacingFailure.from(failure)
        } catch {
            guard isCurrentCommand(epoch) else { return }
            lastFailure = UserFacingFailure(title: "Export failed", detail: UserFacingFailure.message(for: error), actions: [.dismiss])
        }
    }

    // MARK: Session lifetime

    private func present(_ session: ExportSession, description: String) {
        activeSessionIDs.insert(session.sessionID)
        presented = PresentedExport(session: session, sourceDescription: description)
        if !session.missingItems.isEmpty {
            AppDiagnostics.record(session.missingItems.joined(separator: "\n"), operation: "export.missing")
            lastNotice = "\(session.missingItems.count) photo\(session.missingItems.count == 1 ? " wasn’t" : "s weren’t") included in this export."
        }
    }

    func presentationWillPresent(sessionID: UUID) {
        guard activeSessionIDs.contains(sessionID) else { return }
        presentedSessionIDs.insert(sessionID)
    }

    /// Activity completion requests dismissal; it does not retire native readers.
    func requestDismissal(sessionID: UUID) {
        if presented?.session.sessionID == sessionID { presented = nil }
    }

    /// Only the owning native controller's terminal dismissal releases its lifetime.
    func presentationDidDismiss(sessionID: UUID) async {
        presentedSessionIDs.remove(sessionID)
        await finished(sessionID: sessionID)
    }

    /// Unpresented sessions can finish immediately. A mounted presentation keeps
    /// its verified copies until UIKit has completed the dismissal.
    func finished(sessionID: UUID?) async {
        guard let sessionID = sessionID ?? presented?.session.sessionID else { return }
        requestDismissal(sessionID: sessionID)
        guard !presentedSessionIDs.contains(sessionID),
              activeSessionIDs.remove(sessionID) != nil else { return }
        surfaceBySessionID.removeValue(forKey: sessionID)
        await store?.discardExport(sessionID: sessionID)
    }

    /// Reports that nothing could be exported because every source is missing.
    func reportMissingAll(missing: [String]) async {
        if !missing.isEmpty {
            AppDiagnostics.record(missing.joined(separator: "\n"), operation: "export.noneAvailable")
        }
        lastFailure = UserFacingFailure(
            title: "Photos unavailable",
            detail: missing.isEmpty
                ? "Choose a photo to export."
                : "These photos couldn’t be opened. Reconnect your library folder, or restore the photos in Files, then try again.",
            actions: [.reconnect, .dismiss])
    }

    func clearFailure() {
        lastFailure = nil
    }

    func clearNotice() {
        lastNotice = nil
    }

    var hasActiveExport: Bool { !activeSessionIDs.isEmpty }
}

#if canImport(UIKit)
/// UIKit owns one frozen activity controller through actual dismissal. Requests
/// wait behind an existing alert/sheet rather than creating a failed SwiftUI
/// sheet invocation that can never deliver onDismiss.
struct ExportSheetPresentation: ViewModifier {
    enum Surface { case nonViewer, viewer }
    let presenter: ExportPresenter?
    let surface: Surface
    func body(content: Content) -> some View {
        let export = presenter?.ownsPresentation(.viewer) == (surface == .viewer) ? presenter?.presented : nil
        return content.background {
            ExportPresentationAnchor(presenter: presenter, export: export)
                .allowsHitTesting(false).accessibilityHidden(true)
        }
    }
}

private struct ExportPresentationAnchor: UIViewRepresentable {
    let presenter: ExportPresenter?
    let export: ExportPresenter.PresentedExport?
    func makeUIView(context: Context) -> NativeExportPresentationAnchor { NativeExportPresentationAnchor() }
    func updateUIView(_ view: NativeExportPresentationAnchor, context: Context) {
        view.update(presenter: presenter, export: export)
    }
    static func dismantleUIView(_ view: NativeExportPresentationAnchor, coordinator: ()) { view.close() }
}

private final class ExportActivityController: UIActivityViewController {
    var changedVisibility: (() -> Void)?
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated); changedVisibility?()
    }
    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated); changedVisibility?()
    }
}

final class NativeExportPresentationAnchor: UIView, UIAdaptivePresentationControllerDelegate {
    private struct Intent {
        let owner: ExportPresenter
        let export: ExportPresenter.PresentedExport
    }
    private final class Active {
        let intent: Intent
        let controller: ExportActivityController
        var didMount = false
        var presentationCompleted = false
        var completedAt: TimeInterval?
        init(intent: Intent, controller: ExportActivityController) {
            self.intent = intent; self.controller = controller
        }
    }
    private var desired: Intent?
    private var active: Active?
    private var observation: Task<Void, Never>?

    override init(frame: CGRect) {
        super.init(frame: frame); isUserInteractionEnabled = false; accessibilityElementsHidden = true
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window != nil { reconcileSoon() }
    }
    func update(presenter: ExportPresenter?, export: ExportPresenter.PresentedExport?) {
        if let presenter, let export {
            desired = Intent(owner: presenter, export: export)
        } else { desired = nil }
        reconcileSoon()
    }
    func close() {
        let pending = desired
        desired = nil
        if let pending, active?.intent.export.id != pending.export.id {
            pending.owner.requestDismissal(sessionID: pending.export.session.sessionID)
            Task { await pending.owner.finished(sessionID: pending.export.session.sessionID) }
        }
        reconcileSoon()
    }
    func presentationControllerDidDismiss(_ presentationController: UIPresentationController) { reconcileSoon() }

    private func reconcileSoon() {
        guard observation == nil else { return }
        observation = Task { @MainActor [self] in
            defer { observation = nil }
            while !Task.isCancelled {
                if let current = active {
                    let controller = current.controller
                    if controller.viewIfLoaded?.window != nil { current.didMount = true }
                    let obsolete = desired?.export.id != current.intent.export.id
                    if controller.presentingViewController == nil, controller.viewIfLoaded?.window == nil,
                       !controller.isBeingPresented, current.didMount || current.presentationCompleted {
                        active = nil
                        controller.changedVisibility = nil; controller.completionWithItemsHandler = nil
                        controller.presentationController?.delegate = nil
                        await current.intent.owner.presentationDidDismiss(sessionID: current.intent.export.session.sessionID)
                        continue
                    }
                    if !current.didMount, !obsolete, current.completedAt == nil {
                        try? await Task.sleep(for: .milliseconds(16)); continue
                    }
                    guard obsolete || current.completedAt != nil else { return }
                    // A real activity action owns its automatic native dismissal.
                    // Recover only if it unexpectedly remains after that transition.
                    if controller.isBeingPresented || controller.isBeingDismissed
                        || current.completedAt.map({ ProcessInfo.processInfo.systemUptime - $0 < 2 }) == true {
                        try? await Task.sleep(for: .milliseconds(16)); continue
                    }
                    controller.dismiss(animated: window != nil)
                    try? await Task.sleep(for: .milliseconds(16))
                } else {
                    guard let intent = desired, window != nil else { return }
                    // Cancelled/superseded unmounted intents never create readers.
                    guard intent.owner.presented?.id == intent.export.id else { desired = nil; continue }
                    var responder: UIResponder? = self
                    while let current = responder, !(current is UIViewController) { responder = current.next }
                    guard var host = responder as? UIViewController else { return }
                    while let parent = host.parent { host = parent }
                    guard host.presentedViewController == nil, !host.isBeingPresented, !host.isBeingDismissed,
                          host.viewIfLoaded?.window != nil, host.transitionCoordinator == nil else {
                        try? await Task.sleep(for: .milliseconds(50)); continue
                    }
                    intent.owner.presentationWillPresent(sessionID: intent.export.session.sessionID)
                    #if DEBUG
                    let began = ProcessInfo.processInfo.systemUptime
                    #endif
                    let controller = ExportActivityController(activityItems: intent.export.session.fileURLs,
                        applicationActivities: [SaveDNGToPhotosActivity()])
                    #if DEBUG
                    print("TruongCam timing share-controller=\(Int((ProcessInfo.processInfo.systemUptime - began) * 1000))ms count=\(intent.export.session.fileURLs.count)")
                    #endif
                    let current = Active(intent: intent, controller: controller)
                    active = current
                    // These finite native callbacks retain the exact presentation
                    // owner even if its SwiftUI surface is removed while closing.
                    controller.changedVisibility = { [self] in reconcileSoon() }
                    controller.completionWithItemsHandler = { [self, weak controller] _, _, _, _ in
                        guard let controller, active?.controller === controller else { return }
                        current.completedAt = ProcessInfo.processInfo.systemUptime
                        intent.owner.requestDismissal(sessionID: intent.export.session.sessionID)
                        if desired?.export.id == intent.export.id { desired = nil }
                        reconcileSoon()
                    }
                    if let popover = controller.popoverPresentationController {
                        popover.sourceView = self
                        popover.sourceRect = CGRect(x: bounds.midX, y: max(0, bounds.maxY - 44), width: 1, height: 1)
                    }
                    host.present(controller, animated: true) { [self] in
                        current.presentationCompleted = true
                        reconcileSoon()
                    }
                    controller.presentationController?.delegate = self
                    try? await Task.sleep(for: .milliseconds(16))
                }
            }
        }
    }
}


#endif

#if canImport(UIKit)
protocol DNGPhotoLibraryWriting: Sendable {
    func requestAddAuthorization() async -> Bool
    func addOriginals(_ files: [URL]) async throws
}

struct SystemDNGPhotoLibrary: DNGPhotoLibraryWriting {
    func requestAddAuthorization() async -> Bool {
        var status = PHPhotoLibrary.authorizationStatus(for: .addOnly)
        if status == .notDetermined { status = await PHPhotoLibrary.requestAuthorization(for: .addOnly) }
        return status == .authorized || status == .limited
    }
    func addOriginals(_ files: [URL]) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            PHPhotoLibrary.shared().performChanges {
                for url in files {
                    let options = PHAssetResourceCreationOptions()
                    options.originalFilename = url.lastPathComponent
                    options.contentType = UTType(filenameExtension: url.pathExtension)
                    options.shouldMoveFile = false
                    PHAssetCreationRequest.forAsset().addResource(with: .photo, fileURL: url, options: options)
                }
            } completionHandler: { success, error in
                if success { continuation.resume() }
                else { continuation.resume(throwing: error ?? CocoaError(.fileWriteUnknown)) }
            }
        }
    }
}

/// Owns separate verified scratch copies through PhotoKit completion. Dismissing
/// or superseding a share session therefore cannot remove an import's input.
/// No Photos read permission, asset fetch, DNG rewrite or original move occurs.
actor DNGPhotosExporter {
    enum Failure: LocalizedError {
        case noDNG, permission, changedCopy
        var errorDescription: String? {
            switch self {
            case .noDNG: "No photo originals were included in this export."
            case .permission: "Photos access was not allowed. Enable Add Photos for TruongCam in Settings, then try again. Your originals are still in Files."
            case .changedCopy: "An export copy changed while preparing. Nothing was added to Photos. Try exporting again."
            }
        }
    }
    let library: any DNGPhotoLibraryWriting
    private let hashFile: @Sendable (URL) throws -> HashAndByteCount
    init(library: any DNGPhotoLibraryWriting = SystemDNGPhotoLibrary(),
         hashFile: @escaping @Sendable (URL) throws -> HashAndByteCount = {
             try SystemFileSystemAdapter().hashFile(at: $0, chunkBytes: FileAdapterDefaults.hashChunkBytes)
         }) {
        self.library = library
        self.hashFile = hashFile
    }
    func save(_ exportedFiles: [URL]) async throws -> Int {
        let sources = exportedFiles.filter { $0.isFileURL && LibraryStore.isSupportedOriginalPath($0.lastPathComponent) }
        guard !sources.isEmpty else { throw Failure.noDNG }
        #if DEBUG
        let authorizationBegan = ProcessInfo.processInfo.systemUptime
        #endif
        guard await library.requestAddAuthorization() else { throw Failure.permission }
        #if DEBUG
        print("TruongCam timing photos-authorization=\(Int((ProcessInfo.processInfo.systemUptime - authorizationBegan) * 1000))ms")
        let copyBegan = ProcessInfo.processInfo.systemUptime
        #endif
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("TruongCamPhotos-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        var copies: [URL] = []
        for (index, source) in sources.enumerated() {
            try Task.checkCancellation()
            let directory = scratch.appendingPathComponent(String(index), isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let copy = directory.appendingPathComponent(source.lastPathComponent)
            // Hash the admitted source before copying, then verify the complete
            // import-owned copy. The existing storage helper streams bounded
            // chunks; neither a large RAW nor a mapping fallback fills one Data.
            let originalHash = try hashFile(source)
            try Task.checkCancellation()
            try FileManager.default.copyItem(at: source, to: copy)
            let copyHash = try hashFile(copy)
            guard originalHash == copyHash else { throw Failure.changedCopy }
            copies.append(copy)
        }
        try Task.checkCancellation()
        #if DEBUG
        print("TruongCam timing photos-verified-copies=\(Int((ProcessInfo.processInfo.systemUptime - copyBegan) * 1000))ms count=\(copies.count)")
        let importBegan = ProcessInfo.processInfo.systemUptime
        #endif
        try await library.addOriginals(copies)
        #if DEBUG
        print("TruongCam timing photos-import=\(Int((ProcessInfo.processInfo.systemUptime - importBegan) * 1000))ms count=\(copies.count)")
        #endif
        return copies.count
    }
}

/// UIActivity has nonisolated legacy hooks. URL state is lock protected, the
/// exporter is an actor, and all UIKit controller/finish work asserts MainActor.
final class SaveDNGToPhotosActivity: UIActivity, @unchecked Sendable {
    private let files = Mutex<[URL]>([])
    private let exporter: DNGPhotosExporter
    init(exporter: DNGPhotosExporter = DNGPhotosExporter()) { self.exporter = exporter; super.init() }
    override class var activityCategory: UIActivity.Category { .action }
    override var activityType: UIActivity.ActivityType? { UIActivity.ActivityType("com.iantruong.TruongCam.saveDNGToPhotos") }
    override var activityTitle: String? { "Save to Photos" }
    override var activityImage: UIImage? { UIImage(systemName: "photo.badge.plus") }
    override func canPerform(withActivityItems items: [Any]) -> Bool {
        items.compactMap { $0 as? URL }.contains { $0.isFileURL && LibraryStore.isSupportedOriginalPath($0.lastPathComponent) }
    }
    override func prepare(withActivityItems items: [Any]) {
        let urls = items.compactMap { $0 as? URL }.filter { $0.isFileURL && LibraryStore.isSupportedOriginalPath($0.lastPathComponent) }
        files.withLock { $0 = urls }
    }
    override var activityViewController: UIViewController? {
        let urls = files.withLock { $0 }
        return MainActor.assumeIsolated {
            DNGPhotosSaveController(files: urls, exporter: exporter) { [weak self] success in self?.activityDidFinish(success) }
        }
    }
}

@MainActor final class DNGPhotosSaveController: UIViewController {
    private let files: [URL]
    private let exporter: DNGPhotosExporter
    private let finish: @MainActor (Bool) -> Void
    private let label = UILabel()
    private let spinner = UIActivityIndicatorView(style: .large)
    private let done = UIButton(type: .system)
    private var started = false
    private var succeeded = false
    init(files: [URL], exporter: DNGPhotosExporter, finish: @escaping @MainActor (Bool) -> Void) {
        self.files = files; self.exporter = exporter; self.finish = finish
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { return nil }
    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        label.numberOfLines = 0; label.textAlignment = .center
        label.text = "Adding originals to Photos…"; label.font = .preferredFont(forTextStyle: .headline)
        done.setTitle("Done", for: .normal); done.isHidden = true
        done.addTarget(self, action: #selector(close), for: .touchUpInside)
        done.heightAnchor.constraint(greaterThanOrEqualToConstant: 44).isActive = true
        let stack = UIStackView(arrangedSubviews: [spinner, label, done])
        stack.axis = .vertical; stack.spacing = 24; stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([stack.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            stack.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 28),
            stack.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -28)])
    }
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        guard !started else { return }; started = true
        isModalInPresentation = true; spinner.startAnimating()
        Task {
            do {
                let count = try await exporter.save(files)
                succeeded = true
                label.text = "Saved \(count) photo\(count == 1 ? "" : "s") to Photos.\nYour Files originals stay in place."
            } catch { label.text = Self.failureMessage(for: error) }
            spinner.stopAnimating(); done.isHidden = false; isModalInPresentation = false
        }
    }
    static func failureMessage(for error: Error) -> String {
        AppDiagnostics.record(error, operation: "saveToPhotos")
        switch error as? DNGPhotosExporter.Failure {
        case .some(.permission):
            return "Allow TruongCam to add photos in Settings, then try again. Your originals are still in Files."
        case .some(.noDNG):
            return "No photos were selected. Choose a photo and try again."
        case .some(.changedCopy):
            return "Couldn’t prepare these photos. Export them again and retry. Your originals are still in Files."
        case nil:
            return "Couldn’t save to Photos. Try again. Your originals are still in Files."
        }
    }
    @objc private func close() { finish(succeeded) }
}
#endif
