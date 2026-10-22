import SwiftUI
import UIKit

// UI.md "Shared library and detail screen".
//
// Date-grouped thumbnail grid; a day's count and the footer count include
// individual committed originals even when a sequence is covered by one tile.
// Local missing/inaccessible originals are marked and offer reconnect, never a
// cloud download. Explicit deletion moves verified photos to recoverable Trash.

/// Requests the next index page when the user reaches the end of the loaded list.
///
/// REVIEW.md R09: this used to sit BEFORE the grid and fire from a bare
/// `onAppear`, so it triggered on entry and never re-armed — page 2 and beyond were
/// unreachable. `identity` is the number of pages already loaded, which changes on
/// every successful load and therefore re-runs `onAppear` for each new cursor.
struct NextPageSentinel: View {
    let identity: Int
    let loadNextPage: () -> Void

    var body: some View {
        HStack {
            ProgressView()
            Text("Loading more sources…")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, minHeight: 44)
        .id(identity)
        .onAppear(perform: loadNextPage)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Loading more sources")
    }
}

struct LibraryScreen: View {
    @Environment(AppEnvironment.self) private var app
    @State private var selection: LibrarySourceCard?
    @State private var isInspectorPresented = false
    @State private var isSelecting = false
    @State private var selectedIDs: Set<CaptureID> = []
    @State private var selectionSources: [LibrarySourceCard] = []
    @State private var selectionLoading = false
    @State private var selectionFrames: [CaptureID: CGRect] = [:]
    @State private var selectionRevision = 0
    @State private var selectionSequenceCache = SelectionSequenceExpansionCache()
    @State private var batchDelete: BatchDeleteRequest?
    @State private var batchMessage: String?
    private struct BatchDeleteRequest: Identifiable {
        let id = UUID()
        let cards: [LibrarySourceCard]
        let generation: RootGeneration
    }
    init(selecting: Bool = false) { _isSelecting = State(initialValue: selecting) }
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    /// Presents the recovery sheet on THIS surface.
    /// Presents the explicit destination reconfirmation (REVIEW.md H05).
    private var reconfirmationBinding: Binding<Bool> {
        Binding(
            get: { app.isAwaitingDestinationReconfirmation },
            set: { _ in })
    }

    private var libraryRecoveryBinding: Binding<Bool> {
        Binding(
            get: { app.camera?.isRecoverySheetPresented ?? false },
            set: { app.camera?.isRecoverySheetPresented = $0 })
    }

    /// Routes the recovery actions a library-surface failure can offer.
    private func handleExportAction(_ action: UserFacingFailure.Action) {
        switch action {
        case .retrySave, .exportPending:
            app.camera?.isRecoverySheetPresented = true
        case .reconnect:
            app.camera?.isFolderSheetPresented = true
        case .resetToAuto, .openSettings, .dismiss:
            break
        }
        app.exportPresenter?.clearLastFailure()
    }

    /// Bound to the environment so a cover tap pushes the sequence drilldown.
    private var sequenceBinding: Binding<SequenceID?> {
        Binding(
            get: { app.openSequenceID },
            set: { app.openSequenceID = $0 })
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 4, pinnedViews: [.sectionHeaders]) {
                    FolderStatusRow()
                    if !app.pendingOriginals.isEmpty {
                        Button { app.camera?.showPendingRecovery() } label: {
                            Label("\(app.pendingOriginals.count) pending originals — Retry or export", systemImage: "tray.full")
                                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                        }.padding(.horizontal, 12)
                    }

                    if let library = app.library {
                        if isSelecting {
                            selectionGrid
                        } else {
                        ForEach(library.dayGroups, id: \.dayKey) { group in
                            Section {
                                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 3), count: dynamicTypeSize.isAccessibilitySize ? 2 : 3), spacing: 4) {
                                    ForEach(group.cards) { card in
                                        LibraryCell(card: card) {
                                            switch card.kind {
                                            case .single(let source):
                                                selection = source
                                            case .sequenceCover(let summary, _):
                                                // A sequence tile opens its source list; the
                                                // cover is a retained preview, not the
                                                // only thing reachable (REVIEW.md C11).
                                                app.openSequence(summary.sequenceID)
                                            }
                                        }
                                    }
                                }
                                .padding(.horizontal, 3)
                            } header: {
                                DayHeader(group: group)
                            }
                        }
                        }

                    } else {
                        ContentUnavailableView(
                            "No library yet",
                            systemImage: "folder.badge.questionmark",
                            description: Text("Choose a local folder on this iPhone. Reconnect it after reinstalling."))
                            .padding(.top, 40)
                    }

                    // R09: the tail trigger. It is the LAST row, so it only appears
                    // once the user reaches the end of the loaded pages; and its
                    // identity changes with the cursor so SwiftUI re-runs onAppear for
                    // every subsequent page instead of firing once on entry.
                    if let library = app.library {
                        if library.hasMorePages {
                            NextPageSentinel(
                                // A stable identity per page is what makes this a
                                // repeatable trigger rather than a one-shot.
                                identity: library.loadedPageCount,
                                loadNextPage: { app.libraryLoadNextPage() })
                        } else if library.pageLoadFailure != nil {
                            Button {
                                app.libraryLoadNextPage()
                            } label: {
                                Label("Retry loading more sources", systemImage: "arrow.clockwise")
                            }
                            .frame(minHeight: 44)
                        }
                        if let failure = library.pageLoadFailure {
                            Text(failure)
                                .font(.footnote)
                                .foregroundStyle(.orange)
                        }
                        if app.libraryScanWasTruncated {
                            Text("Showing the first \(library.loadedSourceCount) records. Refresh for more.")
                                .font(.footnote)
                                .foregroundStyle(.orange)
                        }
                    }
                }
            }
            // R08: export/recovery errors and notices are rendered where the action
            // was invoked. The camera screen already renders camera failures; these
            // belong to the library surface.
            .overlay(alignment: .bottom) {
                if let failure = app.exportPresenter?.lastFailure {
                    FailureBanner(failure: failure) { action in
                        handleExportAction(action)
                    }
                    .padding()
                } else if let notice = app.exportPresenter?.lastNotice {
                    NoticeBanner(text: notice) {
                        app.exportPresenter?.clearLastNotice()
                    }
                    .padding()
                }
            }
            // G06: the library surface must present its own recovery sheet. It
            // previously only set the flag, so Retry / Export pending did nothing
            // here; a root-level overlay is also hidden behind a presented sheet.
            .sheet(isPresented: libraryRecoveryBinding) { PendingRecoverySheet() }
            // H05: the folder's locality could not be verified. The user is offered an
            // EXPLICIT reconfirmation for that folder; there is deliberately no global
            // "accept unknown folders" switch.
            .alert("Confirm this folder is local storage", isPresented: reconfirmationBinding) {
                Button("Use this folder") { app.reconfirmPendingDestination() }
                Button("Cancel", role: .cancel) { }
            } message: {
                Text("This folder's location could not be verified as local storage on this iPhone. "
                    + "Confirm only if it is a folder you created or chose in the Files app on this iPhone.")
            }
            .navigationTitle("Photo library")
            .safeAreaInset(edge: .bottom) {
                if isSelecting { selectionActions }
            }
            .task(id: selectionLoadKey) { await loadSelectionSources() }
            .onChange(of: selectionRootKey) { _, _ in
                // A confirmation cannot silently acquire authority over a new root.
                selectedIDs = []; selectionSources = []; batchDelete = nil
                selectionSequenceCache.reset()
            }
            .onDisappear { batchDelete = nil }
            .alert("Photo operation", isPresented: Binding(get: { batchMessage != nil }, set: { if !$0 { batchMessage = nil } })) {
                Button("OK") { batchMessage = nil }
            } message: { Text(batchMessage ?? "") }
            .modifier(PartialExportConsentAlert(surface: .library))
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Camera") { app.tab = .camera }
                        .frame(minHeight: 44)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    PhotoOperationSelectionButton(selecting: isSelecting, unavailable: app.library == nil) {
                        selectedIDs = []; isSelecting.toggle()
                    }
                }
                ToolbarSpacer(.fixed, placement: .topBarTrailing)
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        app.camera?.isFolderSheetPresented = true
                    } label: {
                        Label("Folder", systemImage: "folder")
                    }
                    .frame(minHeight: 44)
                }
            }
            .refreshable {
            // Explicit/foreground refresh (REVIEW.md S10).
            app.libraryRefreshFromFiles()
        }
        .navigationDestination(item: sequenceBinding) { sequenceID in
                if let summary = app.library?.summary(for: sequenceID) {
                    SequenceDetailView(sequenceID: sequenceID, summary: summary)
                } else {
                    ContentUnavailableView(
                        "Sequence unavailable",
                        systemImage: "questionmark.folder",
                        description: Text("This sequence's record could not be read from the folder."))
                }
            }
            .fullScreenCover(item: $selection) { source in
                NavigationStack {
                    SourceDetailView(
                        card: source,
                        orderedSources: app.library?.orderedSources ?? [],
                        onStep: nil)
                }
            }
            .sheet(isPresented: folderSheetBinding) { FolderSheet() }
        }
    }

    private struct SelectionLoadIdentity: Hashable {
        let isSelecting: Bool
        let revision: UInt64
        let root: String
        let modelID: ObjectIdentifier?
    }
    private var selectionLoadKey: SelectionLoadIdentity {
        SelectionLoadIdentity(isSelecting: isSelecting,
            revision: isSelecting ? (app.library?.contentRevision ?? 0) : 0, root: selectionRootKey,
            modelID: app.library.map { ObjectIdentifier($0) })
    }
    private var selectionRootKey: String {
        String(describing: app.libraryRootState) + (app.libraryThumbnailSource.grantedRootURL?.absoluteString ?? "none")
    }

    private var selectedSources: [LibrarySourceCard] { selectionSources.filter { selectedIDs.contains($0.captureID) } }

    @ViewBuilder private var selectionGrid: some View {
        Text(selectionLoading ? "Loading individual originals…" : "Select individual originals")
            .font(.footnote).foregroundStyle(.secondary).padding(.horizontal, 12).padding(.vertical, 8)
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 3), count: dynamicTypeSize.isAccessibilitySize ? 2 : 3), spacing: 4) {
            ForEach(selectionSources) { source in
                LibraryCell(card: LibraryCard(id: source.id, kind: .single(source), capturedAtUTC: source.capturedAtUTC, representedOriginalCount: 1)) {
                    guard !selectionLoading, !app.photoMutationInProgress, batchDelete == nil else { return }
                    if !selectedIDs.insert(source.captureID).inserted { selectedIDs.remove(source.captureID) }
                }
                .disabled(selectionLoading || app.photoMutationInProgress || batchDelete != nil)
                .overlay { if selectedIDs.contains(source.captureID) { Color.gray.opacity(0.32).allowsHitTesting(false) } }
                .overlay(alignment: .topTrailing) {
                    Image(systemName: selectedIDs.contains(source.captureID) ? "checkmark.circle.fill" : "circle")
                        .font(.title2).foregroundStyle(selectedIDs.contains(source.captureID) ? .blue : .white)
                        .padding(8).allowsHitTesting(false)
                }
                .accessibilityValue(selectedIDs.contains(source.captureID) ? "Selected" : "Not selected")
                .accessibilityAddTraits(selectedIDs.contains(source.captureID) ? [.isSelected] : [])
                .background {
                    GeometryReader { geometry in
                        Color.clear.preference(key: GalleryCellFrames.self,
                            value: [source.captureID: geometry.frame(in: .named("gallery-selection"))])
                    }
                }
            }
        }
        .coordinateSpace(name: "gallery-selection")
        .onPreferenceChange(GalleryCellFrames.self) { if selectionFrames != $0 { selectionFrames = $0 } }
        .background {
            GallerySelectionGesture(frames: selectionFrames, orderedIDs: selectionSources.map(\.captureID),
                selectedIDs: $selectedIDs, context: selectionRootKey + "|\(selectionRevision)",
                isEnabled: isSelecting && !selectionLoading && !app.photoMutationInProgress && batchDelete == nil)
        }
        .padding(.horizontal, 3)
    }

    private var selectionActions: some View {
        let chosen = selectedSources
        return HStack(spacing: 16) {
            Button("Select loaded") { selectedIDs = Set(selectionSources.map(\.captureID)) }
                .disabled(selectionLoading || app.photoMutationInProgress)
            Spacer(minLength: 4)
            Text("\(selectedIDs.count)").monospacedDigit().accessibilityLabel("\(selectedIDs.count) selected")
            Button { app.exportSelectedOriginals(chosen) } label: { ViewerGlassIcon(symbol: "square.and.arrow.up") }
                .accessibilityLabel("Export selected originals")
                .disabled(chosen.isEmpty || app.photoMutationInProgress)
            Button {
                guard case .writable(_, let generation) = app.libraryRootState else { return }
                batchDelete = BatchDeleteRequest(cards: chosen, generation: generation)
            } label: { ViewerGlassIcon(symbol: "trash") }
                .accessibilityLabel("Delete selected photos")
                .disabled(chosen.isEmpty || !app.libraryRootState.isWritable || app.photoMutationInProgress
                    || chosen.contains { !$0.isTruongCamCapture || !$0.canExportOriginal })
                .background {
                    GalleryTrashConfirmation(requestID: batchDelete?.id, count: batchDelete?.cards.count ?? 0,
                        onConfirm: confirmBatchDelete, onDismiss: { id in if batchDelete?.id == id { batchDelete = nil } })
                }
        }.buttonStyle(.plain).padding(.horizontal, 16).padding(.vertical, 10).background(.bar)
    }

    private func confirmBatchDelete(_ requestID: UUID) {
        guard let request = batchDelete, request.id == requestID else { return }
        let root = selectionRootKey
        batchDelete = nil
        // The storage action rechecks root generation, confirmation and each
        // original's identity; the popover itself cannot grant new authority.
        Task {
            let result = await app.trashOriginals(request.cards, generation: request.generation) { verifiedID in
                guard root == selectionRootKey else { return }
                selectionSources.removeAll { $0.captureID == verifiedID }
                selectedIDs.remove(verifiedID)
            }
            guard root == selectionRootKey else { return }
            selectedIDs.subtract(result.completed)
            if let failure = result.failure {
                AppDiagnostics.record(failure, operation: "library.deleteSelected")
                batchMessage = "\(result.completed.count) photos moved to Recently Deleted. The remaining photos weren’t moved. You can try again."
            } else { selectedIDs = []; isSelecting = false }
        }
    }

    @MainActor private func loadSelectionSources() async {
        guard !Task.isCancelled, isSelecting, let library = app.library else { return }
        let root = selectionRootKey
        let libraryID = app.libraryRootState.libraryID
        let context = SelectionSequenceExpansionCache.Context(root: root + "|" + String(describing: ObjectIdentifier(library)),
            reloadRevision: library.reloadRevision)
        selectionSequenceCache.prepare(context)
        selectionLoading = true
        selectionRevision &+= 1
        defer { if !Task.isCancelled { selectionLoading = false } }
        let groups = library.dayGroups
        var sources: [LibrarySourceCard] = []
        for tile in groups.flatMap(\.cards) {
            switch tile.kind {
            case .single(let source):
                guard source.libraryID == libraryID else { return }
                sources.append(source)
            case .sequenceCover(let summary, _):
                do {
                    let members: [LibrarySourceCard]
                    if let cached = selectionSequenceCache.sources(for: tile) {
                        members = cached
                    } else {
                        guard let index = app.libraryIndex else { throw CocoaError(.fileReadUnknown) }
                        members = try await index.sources(inSequence: summary.sequenceID)
                        guard !Task.isCancelled, isSelecting, root == selectionRootKey,
                              selectionSequenceCache.context == context,
                              members.allSatisfy({ $0.libraryID == libraryID && $0.sequenceID == summary.sequenceID }) else { return }
                        guard selectionSequenceCache.insert(members, for: tile, libraryID: libraryID, context: context) else { return }
                    }
                    sources += members
                } catch {
                    guard !Task.isCancelled, root == selectionRootKey else { return }
                    AppDiagnostics.record(error, operation: "library.selectSequencePhotos")
                    batchMessage = "Couldn’t load these photos. Try opening the group again."
                    return
                }
            }
            guard !Task.isCancelled, isSelecting, root == selectionRootKey else { return }
        }
        var seen: Set<CaptureID> = []
        selectionSources = sources.filter { seen.insert($0.captureID).inserted }
        selectedIDs.formIntersection(seen)
    }

    private var folderSheetBinding: Binding<Bool> {
        Binding(get: { app.camera?.isFolderSheetPresented ?? false },
                set: { app.camera?.isFolderSheetPresented = $0 })
    }
}

/// Partial export consent belongs to the surface that requested the verified
/// copies. Every callback retains that exact confirmation rather than acting on
/// whichever command happens to be current when an old alert dismisses.
struct PartialExportConsentAlert: ViewModifier {
    @Environment(AppEnvironment.self) private var app
    let surface: ExportPresenter.ExportSurface

    private var offered: AppEnvironment.PartialExportConfirmation? {
        guard let pending = app.pendingPartialExport, pending.surface == surface else { return nil }
        return pending
    }
    private func rootMatches(_ pending: AppEnvironment.PartialExportConfirmation) -> Bool {
        guard let root = pending.root, let store = app.libraryStore else { return false }
        return root.state == store.rootState && root.url == store.grantedRootURL
    }
    private var visible: AppEnvironment.PartialExportConfirmation? {
        offered.flatMap { rootMatches($0) ? $0 : nil }
    }

    func body(content: Content) -> some View {
        content
            .alert("Some photos are unavailable", isPresented: Binding(
                get: { visible != nil },
                // The explicit buttons own completion. A delayed presentation
                // dismissal cannot cancel a newer confirmation's command.
                set: { _ in }), presenting: visible) { pending in
                Button("Export available originals") {
                    app.confirmPendingPartialExport(expectedID: pending.id)
                }
                Button("Cancel", role: .cancel) {
                    app.cancelPendingPartialExport(expectedID: pending.id)
                }
            } message: { pending in
                Text(PartialExportConsentCopy.message(absences: pending.absentDescriptions,
                    sources: (app.library?.orderedSources ?? []) + (app.library?.sequenceCards ?? [])))
            }
            .task(id: visible?.id) {
                if let pending = visible {
                    AppDiagnostics.record(pending.absentDescriptions.joined(separator: "\n"), operation: "export.partialConsent")
                }
            }
            .onChange(of: app.libraryRootState) { _, _ in cancelRevokedConsent() }
            .onChange(of: app.libraryStore?.grantedRootURL) { _, _ in cancelRevokedConsent() }
    }

    private func cancelRevokedConsent() {
        guard let pending = offered, !rootMatches(pending) else { return }
        app.cancelPendingPartialExport(expectedID: pending.id)
    }
}

/// Preserve useful photo names and planned ordinals in consent without showing
/// storage errors, paths or opaque capture identities. The frozen raw absences
/// stay unchanged for ownership/membership checks and detailed diagnostics.
enum PartialExportConsentCopy {
    static func message(absences: [String], sources: [LibrarySourceCard]) -> String {
        let labels = absences.enumerated().map { index, absence -> String in
            if let source = sources.first(where: { absence.contains($0.captureID.description) }) {
                return (source.relativeOriginalPath as NSString).lastPathComponent
            }
            if absence.hasPrefix("planned source ") {
                let ordinal = absence.dropFirst("planned source ".count).prefix { $0.isNumber }
                if !ordinal.isEmpty { return "Photo \(ordinal) wasn’t captured" }
            }
            let prefix = absence.components(separatedBy: " (").first ?? absence
            let filename = (prefix as NSString).lastPathComponent
            if LibraryStore.isSupportedOriginalPath(filename),
               !filename.contains("\n"), !filename.contains("\r"), !filename.contains(":") {
                return filename
            }
            return "Unavailable photo \(index + 1)"
        }
        return "These \(absences.count) photos won’t be included in the export:\n" + labels.joined(separator: "\n")
    }
}

/// Chosen folder path and availability, opening the same folder sheet.
struct FolderStatusRow: View {
    @Environment(AppEnvironment.self) private var app

    var body: some View {
        Button {
            app.camera?.isFolderSheetPresented = true
        } label: {
            HStack(spacing: 8) {
                Image(systemName: statusIcon)
                VStack(alignment: .leading, spacing: 2) {
                    Text(app.libraryLocationLabel)
                        .font(.subheadline)
                        .lineLimit(1)
                    Text(app.libraryStatusLine)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "chevron.right").foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .frame(minHeight: 44)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Selected folder")
        .accessibilityValue("\(app.libraryLocationLabel). \(app.libraryStatusLine)")
    }

    private var statusIcon: String {
        switch app.libraryRootState {
        case .writable: return "folder.fill"
        case .readOnly: return "lock"
        case .unavailable: return "folder.badge.questionmark"
        case .unselected: return "folder"
        case .resolving, .reconciling: return "arrow.triangle.2.circlepath"
        }
    }
}

struct DayHeader: View {
    let group: LibraryDayGroup

    var body: some View {
        HStack {
            Text(group.displayTitle)
                .font(.headline)
            Spacer()
            Text("\(group.originalCount)")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .accessibilityLabel("\(group.originalCount) originals")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.bar)
    }
}

struct LibraryCell: View {
    @Environment(AppEnvironment.self) private var app
    @State private var thumbnail = ThumbnailModel()
    let card: LibraryCard
    let onOpen: () -> Void

    /// The card whose preview represents this tile. A sequence cover is a
    /// retained source preview, never a merged rendering.
    private var previewSource: LibrarySourceCard? {
        switch card.kind {
        case .single(let source): return source
        case .sequenceCover(_, let cover): return cover
        }
    }

    var body: some View {
        Button(action: onOpen) {
            ZStack(alignment: .bottomLeading) {
                Rectangle()
                    .fill(Color.secondary.opacity(0.18))
                    .aspectRatio(1, contentMode: .fit)
                    .overlay {
                        if case .loaded(let image) = thumbnail.state {
                            Image(decorative: image, scale: 1)
                                .resizable()
                                .aspectRatio(contentMode: .fill)
                                .clipped()
                        } else if thumbnail.state == .loading {
                            ProgressView().tint(.secondary)
                        } else {
                            Image(systemName: badgeSymbol)
                                .font(.title2)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .clipped()

                HStack(spacing: 4) {
                    if case .sequenceCover(let summary, _) = card.kind {
                        Label("\(summary.committedCount)/\(summary.plannedCount)",
                              systemImage: "square.stack.3d.up")
                            .labelStyle(.titleAndIcon)
                            .font(.caption2)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 2)
                            .background(.black.opacity(0.6), in: Capsule())
                            .foregroundStyle(.white)
                    }
                    if case .single(let source) = card.kind, source.availability != .local {
                        Text("Unavailable")
                            .font(.caption2)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 2)
                            .background(.orange.opacity(0.85), in: Capsule())
                            .foregroundStyle(.black)
                    }
                }
                .padding(4)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityValue(accessibilityValue)
        .task(id: previewSource.map {
            ThumbnailModel.Request(card: $0, sourceRevision: app.libraryThumbnailRevision,
                                   rootState: app.libraryRootState, targetLongEdge: 256, rootURL: app.libraryStore?.grantedRootURL)
        }) {
            guard let source = previewSource else { return }
            await thumbnail.loadAndWait(card: source, source: app.libraryThumbnailSource,
                sourceRevision: app.libraryThumbnailRevision, rootState: app.libraryRootState)
        }
        .onDisappear { thumbnail.cancel() }
    }

    private var badgeSymbol: String {
        switch card.kind {
        case .single(let source):
            return source.availability == .local ? "photo" : "photo.badge.exclamationmark"
        case .sequenceCover:
            return "square.stack.3d.up"
        }
    }

    private var accessibilityLabel: String {
        switch card.kind {
        case .single(let source):
            return source.rawDimensions.map { "Photo, \($0.width) by \($0.height)" } ?? "Photo"
        case .sequenceCover(let summary, _):
            return "\(summary.kind.displayName) group, \(summary.committedCount) of \(summary.plannedCount) sources, \(summary.statusLabel)"
        }
    }

    private var accessibilityValue: String {
        switch card.kind {
        case .single(let source):
            switch source.availability {
            case .local: return "Available on this iPhone"
            case .missing: return "Original missing"
            case .inaccessible: return "Photo couldn’t be opened"
            case .unknown: return "Availability unknown"
            }
        case .sequenceCover:
            return "Contains \(card.representedOriginalCount) individual originals"
        }
    }
}

/// Detail with a display-decoded image, Export original, an on-demand metadata
/// inspector and sequence source navigation.
struct SourceDetailView: View {
    @Environment(AppEnvironment.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var card: LibrarySourceCard
    @State private var isInspectorPresented = false
    @State private var isViewerFolderPresented = false
    @State private var viewer = ThumbnailModel()
    @State private var photoDetails = PhotoDetailModel()
    private struct DeleteRequest {
        let id = UUID()
        let card: LibrarySourceCard
        let generation: RootGeneration
        let root: ViewerPagingContext
    }
    @State private var deleteRequest: DeleteRequest?
    private var confirmingDelete: Bool { deleteRequest != nil }
    @State private var mutationError: String?
    @State private var deletedIDs: Set<CaptureID> = []
    @State private var isDeleting = false
    @State private var noSourcesRemaining = false
    @State private var viewerLifetime = UUID()
    @State private var stepTask: Task<Void, Never>?
    @State private var stepEpoch: UUID?
    @State private var stepTarget: CaptureID?
    @State private var adjacentPages: [CaptureID: ThumbnailModel] = [:]
    @State private var prefetchCards: [LibrarySourceCard] = []
    @State private var pagingContext: ViewerPagingContext?
    @State private var pagingProgress: CGFloat = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var sourceOrder: ViewerSourceOrder


    /// The gallery's ordered sources, so the viewer can step through them.
    /// REVIEW.md S12: sequence sources could navigate but the flat gallery could
    /// not, so a single opened original was a dead end.
    private let onStep: ((LibrarySourceCard) -> Void)?

    init(card: LibrarySourceCard,
         orderedSources: [LibrarySourceCard] = [],
         onStep: ((LibrarySourceCard) -> Void)? = nil,
         viewerModel: ThumbnailModel? = nil) {
        _card = State(initialValue: card)
        _viewer = State(initialValue: viewerModel ?? ThumbnailModel())
        _sourceOrder = State(initialValue: ViewerSourceOrder(orderedSources))
        self.onStep = onStep
    }

    @State private var chromeVisible = true
    @State private var dismissProgress: CGFloat = 0

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            // A bounded page viewport keeps outgoing/incoming canvases beside
            // each other. Chrome and the modal presentation stay in place.
            GeometryReader { viewport in
                ZStack {
                    if noSourcesRemaining {
                        EmptyPhotoViewer(isDismissalEnabled: !isDeleting && !app.photoMutationInProgress && !confirmingDelete,
                                         onDismiss: { dismiss() })
                    } else if card.availability == .local, viewer.loadedCaptureID == card.captureID,
                       case .loaded(let image) = viewer.state {
                        InteractiveOriginalPager(image: image, captureID: card.captureID,
                            position: sourceOrder.position(of: card.captureID) ?? 0,
                            previousCaptureID: adjacentCard(-1)?.captureID, nextCaptureID: adjacentCard(1)?.captureID,
                            previousPage: adjacentPage(-1), nextPage: adjacentPage(1),
                            hasPrevious: adjacentCard(-1) != nil, hasNext: adjacentCard(1) != nil,
                            navigationEnabled: pagingAllowed,
                            context: currentPagingContext, reduceMotion: reduceMotion,
                            toggleChrome: { chromeVisible.toggle() },
                            previous: { if canStep(-1) { step(-1) } },
                            next: { if canStep(1) { step(1) } },
                            selectPage: { interactiveStep(from: $0, to: $1) },
                            pagingProgress: { progress in
                                // UIKit tracks every finger sample. SwiftUI only
                                // hides/restores the settings capsule at the
                                // gesture boundary, avoiding a gallery-sized
                                // body rebuild on every animation frame.
                                let hidden: CGFloat = progress > 0 ? 1 : 0
                                if pagingProgress != hidden { pagingProgress = hidden }
                            },
                            dismissalEnabled: !isDeleting && !app.photoMutationInProgress && !confirmingDelete,
                            dismissalProgress: { dismissProgress = $0 }, dismissViewer: { dismiss() })
                            .overlay {
                                if chromeVisible {
                                    PhotoSettingsBelowImage(image: image,
                                        details: photoDetails.captureID == card.captureID ? photoDetails.details : nil)
                                        .opacity(1 - pagingProgress)
                                        .allowsHitTesting(false)
                                }
                            }
                            .zIndex(1)
                            .accessibilityLabel("Photo preview")
                            .accessibilityHint("Pinch or double-tap to zoom. At fit size, swipe left/right for photos or down for the library.")
                            .accessibilityAction(named: "Back to library") { dismiss() }
                    } else if card.availability == .local, viewerNeedsLoading {
                        ProgressView().tint(.white)
                    } else {
                        VStack(spacing: 16) {
                            Image(systemName: "photo.badge.exclamationmark").font(.largeTitle)
                            Text(viewerUnavailableMessage).multilineTextAlignment(.center)
                            Button("Reconnect folder") { isViewerFolderPresented = true }
                                .frame(minHeight: 44)
                        }.padding(24)
                    }
                }
                .frame(width: viewport.size.width, height: viewport.size.height)
                .clipped()
            }
            .ignoresSafeArea()
            if chromeVisible && !noSourcesRemaining {
                VStack {
                    HStack {
                        Button { dismiss() } label: {
                            ViewerGlassIcon(symbol: "chevron.left")
                        }.accessibilityLabel("Back to library")
                        Spacer()
                        Text(currentIndex.map { "\($0 + 1) / \(sourceOrder.visibleCount(excluding: deletedIDs))" } ?? "Original")
                            .font(.caption).foregroundStyle(.white.opacity(0.75))
                        Spacer()
                        Button { isInspectorPresented = true } label: {
                            ViewerGlassIcon(symbol: "info")
                        }.accessibilityLabel("Photo information")
                    }.background(LinearGradient(colors: [.black.opacity(0.7), .clear], startPoint: .top, endPoint: .bottom))
                    Spacer()
                    HStack {
                        Button { step(-1) } label: {
                            ViewerGlassIcon(symbol: "chevron.left")
                        }.disabled(!canStep(-1)).accessibilityLabel("Previous original")
                        Spacer()
                        Button {
                            cancelStep()
                            guard case .writable(_, let generation) = app.libraryRootState else { return }
                            deleteRequest = DeleteRequest(card: card, generation: generation, root: currentPagingContext)
                        } label: {
                            ViewerGlassIcon(symbol: "trash")
                        }.accessibilityLabel("Delete photo")
                            .disabled(!card.canExportOriginal || !card.isTruongCamCapture || app.photoMutationInProgress || isDeleting || confirmingDelete)
                            .background {
                                GalleryTrashConfirmation(requestID: deleteRequest?.id, count: deleteRequest == nil ? 0 : 1,
                                    onConfirm: confirmDelete,
                                    onDismiss: { id in if deleteRequest?.id == id { deleteRequest = nil } })
                            }
                        Button { step(1) } label: {
                            ViewerGlassIcon(symbol: "chevron.right")
                        }.disabled(!canStep(1)).accessibilityLabel("Next original")
                    }.font(.subheadline)
                        .overlay {
                            Button { app.exportCommittedOriginal(card.captureID, surface: .viewer) } label: {
                                ViewerGlassIcon(symbol: "square.and.arrow.up")
                            }.disabled(!card.canExportOriginal || app.photoMutationInProgress || isDeleting || app.exportPresenter?.isPreparingExport == true)
                                .accessibilityLabel("Export original")
                                .accessibilityIdentifier("viewerExport")
                        }
                        .background(LinearGradient(colors: [.clear, .black.opacity(0.7)], startPoint: .top, endPoint: .bottom))
                }.padding(.horizontal, 8)
                    .buttonStyle(.plain)
                    .opacity(1 - dismissProgress)
                    .allowsHitTesting(dismissProgress == 0)
            }
        }
        .foregroundStyle(.white).tint(.white)
        .onDisappear { viewerLifetime = UUID(); cancelStep(); deleteRequest = nil }
        .toolbar(.hidden, for: .navigationBar)
        .alert("Photo operation failed", isPresented: Binding(get: { mutationError != nil }, set: { if !$0 { mutationError = nil } })) {
            Button("OK") { mutationError = nil }
        } message: { Text((mutationError ?? "") + " Check Folder → Recently Deleted for interrupted moves; permanent deletion is available in Recently Deleted.") }
        .sheet(isPresented: $isInspectorPresented) {
            NavigationStack {
                ScrollView {
                    MetadataInspector(card: card,
                        details: photoDetails.captureID == card.captureID ? photoDetails.details : nil,
                        metadataError: photoDetails.error).padding()
                    if let sequenceID = card.sequenceID {
                        Button("All sources in this sequence") {
                            isInspectorPresented = false
                            dismiss()
                            app.openSequence(sequenceID)
                        }.frame(minHeight: 44)
                    }
                }
                .navigationTitle("Photo information").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { isInspectorPresented = false }
                } }
            }.presentationDetents([.medium, .large])
        }
        .task(id: ThumbnailModel.Request(card: card, sourceRevision: app.libraryThumbnailRevision,
            rootState: app.libraryRootState, targetLongEdge: 2048, rootURL: app.libraryStore?.grantedRootURL)) {
            // A late provider or changed folder must re-arm an already-open viewer.
            // Keep both reads owned by this presentation's structured task so
            // dismissal cancels queued display work without delaying metadata.
            let target = card, source = app.libraryThumbnailSource
            let revision = app.libraryThumbnailRevision, root = app.libraryRootState
            let display = viewer, metadata = photoDetails, store = app.libraryStore
            let context = currentPagingContext
            if pagingContext != context { cancelStep(); pagingContext = context }
            async let image: Void = display.loadViewerAndWait(card: target, source: source,
                sourceRevision: revision, rootState: root)
            await metadata.load(card: target, store: store)
            await image
            guard !Task.isCancelled, card == target, currentPagingContext == context else { return }
            prepareAdjacentPages()
        }
        .overlay(alignment: .bottom) {
            // G06: a root-level banner is hidden behind this modal, so the modal owns
            // its own visible failure/notice surface and recovery route.
            if let failure = app.exportPresenter?.lastFailure ?? app.camera?.lastFailure {
                FailureBanner(failure: failure) { action in
                    handleAction(action)
                }
                .padding()
            } else if let notice = app.exportPresenter?.lastNotice ?? app.camera?.lastNotice {
                NoticeBanner(text: notice) {
                    app.exportPresenter?.clearLastNotice()
                    app.camera?.clearLastNotice()
                }
                .padding()
            }
        }
        .sheet(isPresented: $isViewerFolderPresented) { FolderSheet() }
        .sheet(isPresented: sourceRecoveryBinding) { PendingRecoverySheet() }
        .modifier(ExportSheetPresentation(presenter: app.exportPresenter, surface: .viewer))
        .onChange(of: currentPagingContext) { _, context in
            if deleteRequest?.root != context { deleteRequest = nil }
        }
    }

    private func confirmDelete(_ id: UUID) {
        guard let request = deleteRequest, request.id == id,
              request.card == card, request.root == currentPagingContext,
              !app.photoMutationInProgress, !isDeleting else {
            if deleteRequest?.id == id { deleteRequest = nil }
            return
        }
        deleteRequest = nil
        Task { await deleteAndAdvance(request.card, generation: request.generation) }
    }

    private func deleteAndAdvance(_ deleted: LibrarySourceCard, generation: RootGeneration) async {
        guard !isDeleting else { return }
        let context = currentPagingContext
        let lifetime = viewerLifetime
        cancelStep()
        isDeleting = true
        defer { isDeleting = false; deleteRequest = nil }
        let next = sourceOrder.successor(deleting: deleted.captureID, excluding: deletedIDs)
        do {
            try await app.trashOriginal(deleted, generation: generation)
            guard viewerLifetime == lifetime, currentPagingContext == context else { return }
            let incoming = ThumbnailModel()
            if let next { await incoming.loadViewerAndWait(card: next, source: app.libraryThumbnailSource,
                sourceRevision: app.libraryThumbnailRevision, rootState: app.libraryRootState) }
            guard viewerLifetime == lifetime, currentPagingContext == context else { return }
            // Keep this viewer presentation and the current bitmap alive while
            // decoding the successor; replace them together after verified Trash.
            deletedIDs.insert(deleted.captureID)
            if let next {
                viewer = incoming
                card = next
                onStep?(next)
            } else { noSourcesRemaining = true }
            UINotificationFeedbackGenerator().notificationOccurred(.success)
        } catch {
            AppDiagnostics.record(error, operation: "viewer.delete")
            guard viewerLifetime == lifetime, currentPagingContext == context else { return }
            mutationError = "This photo couldn’t be moved to Recently Deleted. Try again."
        }
    }

    private var viewerNeedsLoading: Bool {
        if viewer.loadedCaptureID != card.captureID { return true }
        switch viewer.state {
        case .idle, .loading: return true
        case .loaded, .unavailable: return false
        }
    }

    private var viewerUnavailableMessage: String {
        if case .unavailable(let reason) = viewer.state { return reason }
        return unavailableMessage
    }

    /// Recovery presented from the modal that invoked the action.
    private var sourceRecoveryBinding: Binding<Bool> {
        Binding(
            get: { app.camera?.isRecoverySheetPresented ?? false },
            set: { app.camera?.isRecoverySheetPresented = $0 })
    }

    /// Routes a recovery action from the modal to the surface that owns it.
    private func handleAction(_ action: UserFacingFailure.Action) {
        switch action {
        case .retrySave, .exportPending:
            app.camera?.isRecoverySheetPresented = true
        case .reconnect:
            isViewerFolderPresented = true
        case .resetToAuto, .openSettings, .dismiss:
            break
        }
        app.exportPresenter?.clearLastFailure()
        app.camera?.clearLastFailure()
    }

    private var currentIndex: Int? {
        sourceOrder.visiblePosition(of: card.captureID, excluding: deletedIDs)
    }

    private var pagingAllowed: Bool {
        !isDeleting && !app.photoMutationInProgress && !confirmingDelete
            && !isInspectorPresented && !isViewerFolderPresented
            && app.exportPresenter?.isPreparingExport != true
            && app.exportPresenter?.ownsPresentation(.viewer) != true
    }

    private var currentPagingContext: ViewerPagingContext {
        ViewerPagingContext(revision: app.libraryThumbnailRevision, rootState: app.libraryRootState,
                            rootURL: app.libraryStore?.grantedRootURL)
    }

    private func adjacentCard(_ delta: Int) -> LibrarySourceCard? {
        sourceOrder.neighbor(of: card.captureID, direction: delta, excluding: deletedIDs)
    }

    private func adjacentPage(_ delta: Int) -> ViewerAdjacentPage? {
        guard pagingContext == currentPagingContext, let target = adjacentCard(delta),
              let model = adjacentPages[target.captureID], model.loadedCaptureID == target.captureID,
              case .loaded(let image) = model.state else { return nil }
        return ViewerAdjacentPage(captureID: target.captureID, image: image)
    }

    /// Current and adjacent canvases are display-only, at the existing 2,048-pixel
    /// bound. One worker owns foreground navigation and sequential prefetch; a
    /// rapid input replaces its latest target rather than enqueueing RAW reads.
    private func prepareAdjacentPages() {
        guard !noSourcesRemaining, pagingContext == currentPagingContext else { return }
        let neighbors = [adjacentCard(1), adjacentCard(-1)].compactMap { $0 }
        let retained = Set(neighbors.map(\.captureID))
        adjacentPages = adjacentPages.filter { retained.contains($0.key) }
        prefetchCards = neighbors.filter { adjacentPages[$0.captureID] == nil && $0.availability == .local }
        startPageWorker()
    }

    private func canStep(_ delta: Int) -> Bool {
        pagingAllowed && sourceOrder.neighbor(of: requestedCaptureID, direction: delta, excluding: deletedIDs) != nil
    }

    private func step(_ delta: Int) {
        guard pagingAllowed, let target = sourceOrder.neighbor(of: requestedCaptureID, direction: delta, excluding: deletedIDs) else { return }
        stepTarget = target.captureID
        startPageWorker()
    }

    /// A drag always names the displayed neighbor. Toolbar requests may already
    /// be queued, so their latest requestedCaptureID must never reinterpret a drag.
    private func interactiveStep(from displayedID: CaptureID, to targetID: CaptureID) -> Bool {
        guard pagingAllowed, card.captureID == displayedID, pagingContext == currentPagingContext,
              [adjacentCard(-1)?.captureID, adjacentCard(1)?.captureID].contains(targetID) else { return false }
        stepTarget = targetID
        startPageWorker()
        return true
    }

    private func startPageWorker() {
        guard stepTask == nil else { return }
        let epoch = UUID(), context = currentPagingContext
        stepEpoch = epoch
        stepTask = Task {
            defer {
                if stepEpoch == epoch { stepTask = nil; stepTarget = nil }
            }
            while !Task.isCancelled, stepEpoch == epoch, currentPagingContext == context,
                  !isDeleting, !app.photoMutationInProgress {
                let foreground = stepTarget.flatMap { sourceOrder.source($0, excluding: deletedIDs) }
                let target: LibrarySourceCard
                if let foreground { target = foreground }
                else if !prefetchCards.isEmpty { target = prefetchCards.removeFirst() }
                else { return }
                if target.captureID == card.captureID { stepTarget = nil; continue }
                // Retain at most the displayed model plus two adjacent/target
                // models, including a foreground target beyond a coalesced page.
                if adjacentPages[target.captureID] == nil, adjacentPages.count >= 2,
                   let discarded = adjacentPages.keys.first {
                    adjacentPages.removeValue(forKey: discarded)?.cancel()
                }
                let incoming = adjacentPages[target.captureID] ?? ThumbnailModel()
                await incoming.loadViewerAndWait(card: target, source: app.libraryThumbnailSource,
                    sourceRevision: context.revision, rootState: context.rootState)
                guard !Task.isCancelled, stepEpoch == epoch, currentPagingContext == context,
                      sourceOrder.source(target.captureID, excluding: deletedIDs) == target, !isDeleting, !app.photoMutationInProgress else { return }
                if stepTarget == target.captureID {
                    guard pagingAllowed else { stepTarget = nil; continue }
                    // Identity and pixels publish together. UIKit owns the page
                    // travel, so this does not recreate the modal or double-slide.
                    let previousCard = card, previousViewer = viewer
                    viewer = incoming; card = target; stepTarget = nil; pagingProgress = 0
                    adjacentPages[previousCard.captureID] = previousViewer
                    onStep?(target)
                    prepareAdjacentPages()
                } else if [adjacentCard(-1)?.captureID, adjacentCard(1)?.captureID].contains(target.captureID) {
                    adjacentPages[target.captureID] = incoming
                }
            }
        }
    }

    private var requestedCaptureID: CaptureID {
        stepTarget.flatMap { sourceOrder.source($0, excluding: deletedIDs)?.captureID } ?? card.captureID
    }

    private func cancelStep() {
        stepTask?.cancel()
        stepTask = nil; stepEpoch = nil; stepTarget = nil
        for model in adjacentPages.values { model.cancel() }
        adjacentPages.removeAll(); prefetchCards.removeAll()
        pagingProgress = 0
    }

    private var unavailableMessage: String {
        switch card.availability {
        case .local: return ""
        case .missing:
            return "The original is not in the selected folder. It may have been moved or deleted in Files."
        case .inaccessible:
            return "This photo couldn’t be opened. Reconnect your library folder and try again."
        case .unknown:
            return "The original's availability has not been checked yet."
        }
    }
}

/// On-demand metadata inspector. Unknown fields are labelled Unknown and are
/// never rendered as measured zeros.
struct MetadataInspector: View {
    let card: LibrarySourceCard
    var details: PhotoMetadataDetails? = nil
    var metadataError: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let details, !details.settings.isEmpty {
                HStack(spacing: 12) {
                    ForEach([details.shutter, details.iso, details.aperture].compactMap { $0 }, id: \.self) { value in
                        Text(value).font(.title2.weight(.semibold)).lineLimit(1).minimumScaleFactor(0.75)
                            .frame(maxWidth: .infinity)
                    }
                }.padding(.vertical, 16)
            }
            row("Captured", card.capturedAtUTC.formatted(date: .abbreviated, time: .standard))
            row("Dimensions", card.rawDimensions.map { "\($0.width) × \($0.height)" } ?? "Unknown")
            row("File size", card.byteCount.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) } ?? "Unknown")
            if metadataError != nil {
                Text("Photo details couldn’t be loaded.").font(.footnote).foregroundStyle(.secondary).padding(.vertical)
            }
            row("Format", originalFormatLabel)
            if let details {
                ForEach(details.infoFields) { field in row(field.label, field.value).padding(.vertical, 6) }
            }
            row("File", URL(fileURLWithPath: card.relativeOriginalPath).lastPathComponent)

        }
        .padding(12)
        .background(Color.secondary.opacity(0.1), in: RoundedRectangle(cornerRadius: 10))
        .accessibilityElement(children: .contain)
    }

    var originalFormatLabel: String {
        switch (card.relativeOriginalPath as NSString).pathExtension.lowercased() {
        case "dng": return "DNG"
        case "heic": return "HEIF"
        case "jpg", "jpeg": return "JPEG"
        case "": return "Unknown"
        case let suffix: return suffix.uppercased()
        }
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label).font(.subheadline).foregroundStyle(.secondary)
            Spacer(minLength: 8)
            Text(value).font(.subheadline).multilineTextAlignment(.trailing)
        }
    }


}

/// The empty viewer retains a full-screen downward-swipe route. Its natural
/// content height keeps Back near the center, away from the home indicator.
struct EmptyPhotoViewer: UIViewControllerRepresentable {
    var isDismissalEnabled: Bool
    var onDismiss: () -> Void
    func makeUIViewController(context: Context) -> EmptyPhotoViewerController {
        EmptyPhotoViewerController(isDismissalEnabled: isDismissalEnabled, onDismiss: onDismiss)
    }
    func updateUIViewController(_ controller: EmptyPhotoViewerController, context: Context) {
        controller.isDismissalEnabled = isDismissalEnabled
        controller.onDismiss = onDismiss
        controller.refreshContent()
    }
}

struct EmptyPhotoViewerContent: View {
    let isEnabled: Bool
    let onBack: () -> Void
    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "photo").font(.system(size: 40)).foregroundStyle(.secondary)
            Text("No photos remaining").font(.title3.weight(.semibold))
            Button(action: onBack) {
                Label("Back to library", systemImage: "chevron.left")
                    .font(.body.weight(.medium)).padding(.horizontal, 20).frame(minHeight: 48)
                    .glassEffect(.regular.interactive(), in: Capsule())
            }.buttonStyle(.plain).disabled(!isEnabled).accessibilityIdentifier("emptyViewerBack")
        }.foregroundStyle(.white).frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(.black).preferredColorScheme(.dark)
    }
}

@MainActor final class EmptyPhotoViewerController: UIViewController {
    var isDismissalEnabled: Bool
    var onDismiss: () -> Void
    private var hosting: UIHostingController<EmptyPhotoViewerContent>?
    init(isDismissalEnabled: Bool, onDismiss: @escaping () -> Void) {
        self.isDismissalEnabled = isDismissalEnabled; self.onDismiss = onDismiss
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { nil }
    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        let child = UIHostingController(rootView: content)
        hosting = child; addChild(child)
        child.view.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(child.view)
        NSLayoutConstraint.activate([child.view.topAnchor.constraint(equalTo: view.topAnchor),
            child.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            child.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            child.view.trailingAnchor.constraint(equalTo: view.trailingAnchor)])
        child.didMove(toParent: self)
        let down = UISwipeGestureRecognizer(target: self, action: #selector(dismissDownward))
        down.direction = .down; down.numberOfTouchesRequired = 1
        view.addGestureRecognizer(down)
    }
    private var content: EmptyPhotoViewerContent {
        EmptyPhotoViewerContent(isEnabled: isDismissalEnabled, onBack: { [weak self] in self?.dismissDownward() })
    }
    func refreshContent() { hosting?.rootView = content }
    @objc func dismissDownward() {
        // Recheck at release, as a root/photo mutation may have begun meanwhile.
        guard isDismissalEnabled else { return }
        onDismiss()
    }
}

/// Native Liquid Glass, with a stable 44-point target for every viewer action.
struct ViewerGlassIcon: View {
    let symbol: String
    var body: some View {
        Image(systemName: symbol).font(.system(size: 17, weight: .medium))
            .frame(width: 44, height: 44)
            .glassEffect(.regular.interactive(), in: Circle())
    }
}

/// Uses the natural black letterbox below the fitted image. On a frame that
/// fills the screen, the compact strip stays above the bottom action row.
struct PhotoSettingsBelowImage: View {
    let image: CGImage
    let details: PhotoMetadataDetails?
    var body: some View {
        GeometryReader { viewport in
            let fitHeight = min(viewport.size.height, viewport.size.width * CGFloat(image.height) / CGFloat(image.width))
            let imageBottom = (viewport.size.height + fitHeight) / 2
            let settings = details?.settings ?? []
            Text(settings.isEmpty ? "Camera settings unavailable" : settings.joined(separator: "   ·   "))
                .font(.system(.caption, design: .rounded).weight(.medium))
                .foregroundStyle(.white.opacity(0.85)).lineLimit(2).minimumScaleFactor(0.8)
                .padding(.horizontal, 12).padding(.vertical, 8)
                .background(.black.opacity(0.5), in: Capsule())
                .frame(maxWidth: viewport.size.width - 24)
                .position(x: viewport.size.width / 2, y: min(imageBottom + 25, viewport.size.height - 106))
                .accessibilityIdentifier("photoCaptureSettings")
        }
    }
}

/// Display-only UIKit canvas. Its dimensions are those of the oriented decoded
/// bitmap, never the unrotated RAW sensor dimensions. Original bytes stay owned
/// by the existing scoped library read/export services.
struct ZoomableOriginalView: UIViewRepresentable {
    let image: CGImage
    let toggleChrome: () -> Void
    let previous: () -> Void
    let next: () -> Void
    var discretePaging = true
    var dismissalEnabled = true
    var dismissalProgress: (CGFloat) -> Void = { _ in }
    var dismissViewer: () -> Void = {}

    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeUIView(context: Context) -> OriginalScrollView {
        makeScroll(coordinator: context.coordinator)
    }
    func makeScroll(coordinator: Coordinator) -> OriginalScrollView {
        let scroll = OriginalScrollView()
        scroll.delegate = coordinator
        scroll.backgroundColor = .black
        scroll.showsVerticalScrollIndicator = false
        scroll.showsHorizontalScrollIndicator = false
        scroll.contentInsetAdjustmentBehavior = .never
        let tap = UITapGestureRecognizer(target: coordinator, action: #selector(Coordinator.tap))
        let double = UITapGestureRecognizer(target: coordinator, action: #selector(Coordinator.doubleTap(_:)))
        double.numberOfTapsRequired = 2
        tap.require(toFail: double)
        scroll.addGestureRecognizer(tap)
        scroll.addGestureRecognizer(double)
        // Only a one-finger downward drag at fit size owns dismissal. Zoomed
        // panning/pinching and horizontal source navigation keep their own gestures.
        let down = UIPanGestureRecognizer(target: coordinator, action: #selector(Coordinator.dismissPan(_:)))
        down.maximumNumberOfTouches = 1
        down.delegate = coordinator
        scroll.addGestureRecognizer(down)
        scroll.panGestureRecognizer.require(toFail: down)
        tap.require(toFail: down)
        double.require(toFail: down)
        for direction in discretePaging ? [UISwipeGestureRecognizer.Direction.left, .right] : [] {
            let swipe = UISwipeGestureRecognizer(target: coordinator, action: #selector(Coordinator.swipe(_:)))
            swipe.direction = direction
            swipe.delegate = coordinator
            swipe.require(toFail: down)
            scroll.addGestureRecognizer(swipe)
            scroll.panGestureRecognizer.require(toFail: swipe)
        }
        scroll.setImage(UIImage(cgImage: image))
        return scroll
    }
    func updateUIView(_ view: OriginalScrollView, context: Context) {
        context.coordinator.parent = self
        // A refreshed source can keep its capture identity. SwiftUI may coalesce
        // its loading/loaded publications into one update, so view creation alone
        // cannot own the bitmap. Preserve zoom and gestures for equal-size pixels.
        if view.imageView.image?.cgImage !== image {
            view.setImage(UIImage(cgImage: image))
        }
    }
    final class Coordinator: NSObject, UIScrollViewDelegate, UIGestureRecognizerDelegate {
        var parent: ZoomableOriginalView
        init(_ parent: ZoomableOriginalView) { self.parent = parent }
        func viewForZooming(in scrollView: UIScrollView) -> UIView? {
            (scrollView as? OriginalScrollView)?.imageView
        }
        func scrollViewDidZoom(_ scrollView: UIScrollView) {
            (scrollView as? OriginalScrollView)?.centerImage()
        }
        func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            guard let scroll = gestureRecognizer.view as? OriginalScrollView else { return true }
            if let pan = gestureRecognizer as? UIPanGestureRecognizer {
                let velocity = pan.velocity(in: scroll.superview)
                return parent.dismissalEnabled && scroll.isAtFitSize
                    && velocity.y > abs(velocity.x) * 1.2
            }
            if gestureRecognizer is UISwipeGestureRecognizer { return scroll.isAtFitSize }
            return true
        }
        @objc func dismissPan(_ sender: UIPanGestureRecognizer) {
            guard let scroll = sender.view as? OriginalScrollView else { return }
            // Use the untransformed parent coordinate space; measuring on the
            // moving canvas feeds its own transform back into the next sample.
            updateDismissal(state: sender.state, translation: sender.translation(in: scroll.superview),
                            velocity: sender.velocity(in: scroll.superview), scroll: scroll)
        }
        func updateDismissal(state: UIGestureRecognizer.State, translation: CGPoint,
                             velocity: CGPoint, scroll: OriginalScrollView) {
            let distance = max(0, translation.y)
            switch state {
            case .began, .changed:
                guard parent.dismissalEnabled && scroll.isAtFitSize else {
                    resetDismissal(scroll)
                    return
                }
                let progress = min(1, distance / max(1, scroll.bounds.height * 0.5))
                let scale = 1 - progress * 0.15
                scroll.transform = CGAffineTransform(translationX: translation.x * 0.2, y: distance)
                    .scaledBy(x: scale, y: scale)
                parent.dismissalProgress(progress)
            case .ended:
                let threshold = min(140, max(80, scroll.bounds.height * 0.16))
                let farEnough = distance > threshold
                let flick = distance > 32 && velocity.y > 900 && velocity.y > abs(velocity.x)
                guard parent.dismissalEnabled && scroll.isAtFitSize,
                      translation.y > abs(translation.x), farEnough || flick else {
                    resetDismissal(scroll)
                    return
                }
                parent.dismissViewer()
            case .cancelled, .failed:
                resetDismissal(scroll)
            default: break
            }
        }
        private func resetDismissal(_ scroll: OriginalScrollView) {
            UIView.animate(withDuration: 0.25, delay: 0, usingSpringWithDamping: 0.9,
                           initialSpringVelocity: 0, options: [.beginFromCurrentState, .allowUserInteraction]) {
                scroll.transform = .identity
            }
            parent.dismissalProgress(0)
        }
        @objc func tap() { parent.toggleChrome() }
        @objc func swipe(_ sender: UISwipeGestureRecognizer) {
            if sender.direction == .left { parent.next() } else { parent.previous() }
        }
        @objc func doubleTap(_ sender: UITapGestureRecognizer) {
            guard let scroll = sender.view as? OriginalScrollView else { return }
            if scroll.zoomScale > scroll.minimumZoomScale * 1.01 {
                scroll.setZoomScale(scroll.minimumZoomScale, animated: true)
            } else {
                let scale = min(scroll.maximumZoomScale, scroll.minimumZoomScale * 2.5)
                let point = sender.location(in: scroll.imageView)
                let size = CGSize(width: scroll.bounds.width / scale, height: scroll.bounds.height / scale)
                scroll.zoom(to: CGRect(x: point.x - size.width / 2, y: point.y - size.height / 2,
                                      width: size.width, height: size.height), animated: true)
            }
        }
    }
}

final class OriginalScrollView: UIScrollView {
    let imageView = UIImageView()
    var isAtFitSize: Bool { zoomScale <= minimumZoomScale * 1.01 }
    private var fittedBounds = CGSize.zero
    func refitNextImage() { fittedBounds = .zero }
    func setImage(_ image: UIImage) {
        let needsRefit = imageView.image?.size != image.size
        imageView.image = image
        imageView.isAccessibilityElement = true
        imageView.accessibilityLabel = "Photo preview"
        if imageView.superview == nil { addSubview(imageView) }
        if needsRefit { fittedBounds = .zero }
        setNeedsLayout()
    }
    override func layoutSubviews() {
        super.layoutSubviews()
        guard let image = imageView.image, bounds.width > 0, bounds.height > 0,
              fittedBounds != bounds.size else { return }
        fittedBounds = bounds.size
        // Rotation refits the current image; it never crops the sensor image to
        // match another source's dimensions or retains a previous source's zoom.
        minimumZoomScale = 0.0001
        maximumZoomScale = 8
        zoomScale = 1
        imageView.frame = CGRect(origin: .zero, size: image.size)
        contentSize = image.size
        let fit = min(bounds.width / image.size.width, bounds.height / image.size.height)
        minimumZoomScale = fit
        maximumZoomScale = fit * 4
        setZoomScale(fit, animated: false)
        centerImage()
        setContentOffset(CGPoint(x: -contentInset.left, y: -contentInset.top), animated: false)
    }
    func centerImage() {
        let horizontal = max(0, (bounds.width - contentSize.width) / 2)
        let vertical = max(0, (bounds.height - contentSize.height) / 2)
        contentInset = UIEdgeInsets(top: vertical, left: horizontal, bottom: vertical, right: horizontal)
    }
}
