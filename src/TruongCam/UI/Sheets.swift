import SwiftUI

// UI.md "Onboarding/recovery screens": folder selection/reconnection, folder
// unavailable, and pending-source recovery with Retry save / Export original and
// an explicit warning that pending originals are not reinstall-safe.

struct FolderSheet: View {
    @Environment(AppEnvironment.self) private var app
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    LabeledContent("Location", value: app.libraryLocationLabel)
                    LabeledContent("Status", value: app.libraryStatusLine)
                    LabeledContent(app.library?.hasMorePages == true ? "Loaded originals" : "Originals",
                                   value: "\(app.library?.individualOriginalCount ?? 0)")
                } header: {
                    Text("Selected folder")
                } footer: {
                    Text("Photos save in originals; app records go in metadata. Saved originals stay in your selected folder.")
                }

                Section {
                    Button("Select or reconnect folder") {
                        Task { await app.selectLibraryFolder() }
                    }
                    .frame(minHeight: 44)

                    if app.libraryRootState.libraryID != nil {
                        Button("Stop using this folder", role: .destructive) {
                            Task { await app.releaseLibraryFolder() }
                        }
                        .frame(minHeight: 44)
                    }
                } footer: {
                    Text("Choose On My iPhone, outside TruongCam. Deleting TruongCam deletes its own folder. Cloud folders aren’t supported. Other apps’ folders need those apps to stay installed.")
                }

                if let notice = app.selectionNotice {
                    Section {
                        HStack(alignment: .top, spacing: 8) {
                            Image(systemName: "info.circle").foregroundStyle(.secondary)
                            Text(notice).font(.footnote)
                            Spacer(minLength: 0)
                            Button("Dismiss") { app.clearSelectionNotice() }
                                .font(.footnote.weight(.semibold))
                                .frame(minHeight: 44)
                        }
                    } footer: {
                        Text("Your previous folder is still selected.")
                    }
                }

                Section("Files layout") {
                    Text("Photos are in originals. App records are in metadata.").font(.footnote)
                    Button(app.isOrganizingMetadata ? "Organizing…" : "Organize existing app records") {
                        Task { await app.organizeLibraryMetadata() }
                    }.disabled(!app.libraryRootState.isWritable || app.isOrganizingMetadata)
                    Text("Moves older app records out of the photo folders. Photos stay in place.")
                        .font(.caption).foregroundStyle(.secondary)
                    if let message = app.metadataOrganizationMessage { Text(message).font(.footnote) }
                }

                Section {
                    NavigationLink { PhotoTrashView() } label: {
                        Label("Recently Deleted", systemImage: "trash")
                    }
                } footer: {
                    Text("Recover photos or delete them permanently. Nothing is deleted automatically.")
                }

                if let failure = app.failure {
                    Section {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(failure.title).font(.subheadline.weight(.semibold))
                            Text(failure.detail).font(.footnote).foregroundStyle(.secondary)
                        }
                    }
                }

                Section {
                    Text("After reinstalling, reconnect this folder to rebuild your library.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Library folder")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}

struct PendingRecoverySheet: View {
    @Environment(AppEnvironment.self) private var app
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text("Unsaved originals are stored in the app and will be lost if you delete it. Retry saving or export them first.")
                        .font(.footnote)
                }

                if let failure = app.exportPresenter?.lastFailure {
                    Section {
                        Text(failure.title).font(.headline)
                        Text(failure.detail).font(.footnote)
                    }
                } else if let notice = app.exportPresenter?.lastNotice {
                    Section { Text(notice).font(.footnote) }
                }

                if app.pendingOriginals.isEmpty {
                    ContentUnavailableView(
                        "No pending originals",
                        systemImage: "checkmark.circle",
                        description: Text("There are no photos waiting for recovery."))
                } else {
                    Section("Pending originals (\(app.pendingOriginals.count))") {
                        ForEach(app.pendingOriginals) { pending in
                            VStack(alignment: .leading, spacing: 4) {
                                Text((pending.intendedRelativeOriginalPath as NSString).lastPathComponent)
                                    .font(.footnote)
                                Text("\(ByteCountFormatter.string(fromByteCount: pending.byteCount, countStyle: .file)) · Save needs attention")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                if pending.lastError != nil {
                                    Text("The last save couldn’t finish. Retry or export this photo.")
                                        .font(.caption2).foregroundStyle(.orange)
                                }
                                HStack {
                                    Button("Retry save") {
                                        Task { await app.retryPendingOriginal(pending.transactionID) }
                                    }
                                    .buttonStyle(.bordered)
                                    .frame(minHeight: 44)

                                    Button("Export original") {
                                        // Free the modal presenter before its prepared export arrives.
                                        app.camera?.presentedCameraSheet = nil
                                        dismiss()
                                        app.exportPendingOriginal(pending.transactionID)
                                    }
                                    .buttonStyle(.bordered)
                                    .frame(minHeight: 44)
                                }
                            }
                            .task(id: pending) {
                                if let error = pending.lastError {
                                    AppDiagnostics.record(error, operation: "pendingRecovery.\(pending.captureID)")
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("Pending originals")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}

/// Batch cancellation stays in the existing toolbar. Operation state never
/// inserts a new footer or shifts the photo-management controls.
struct PhotoOperationSelectionButton: View {
    @Environment(AppEnvironment.self) private var app
    let selecting: Bool
    let unavailable: Bool
    let toggleSelection: () -> Void
    private var batch: PhotoMutationProgress? {
        guard app.photoMutationInProgress, let progress = app.visiblePhotoMutationProgress,
              progress.total > 1 else { return nil }
        return progress
    }
    var body: some View {
        Button(batch == nil ? (selecting ? "Done" : "Select") : "Stop") {
            if let batch { app.stopPhotoMutation(batch.id) }
            else if !app.photoMutationInProgress { toggleSelection() }
        }
        .frame(minHeight: 44)
        .disabled(batch.map { $0.stopRequested || $0.isRefreshing }
            ?? (unavailable || app.photoMutationInProgress))
        .accessibilityLabel(batch == nil ? (selecting ? "Done selecting" : "Select photos") : "Stop photo operation")
        .accessibilityValue(batch.map { "\($0.completed) of \($0.total) completed" } ?? "")
        .accessibilityIdentifier("photoSelection")
    }
}

/// Persistent photo grid; permanent deletion always uses a frozen confirmation.
struct PhotoTrashView: View {
    @Environment(AppEnvironment.self) private var app
    @Environment(\.dynamicTypeSize) private var typeSize
    @State private var records: [PhotoTrashRecord] = []
    @State private var errorText: String?
    @State private var loading = false
    @State private var selecting = false
    @State private var selected: Set<CaptureID> = []
    @State private var frames: [CaptureID: CGRect] = [:]
    @State private var focused: PhotoTrashRecord?
    @State private var confirmation: TrashRequest?
    @State private var reloadID = UUID()
    @State private var verifiedRemovalBatch = VerifiedPhotoRemovalBatch()
    @State private var verifiedRemovalRoot: String?
    @State private var removalPublication: Task<Void, Never>?
    @State private var removalPublicationID = UUID()
    private struct ReloadIdentity: Hashable {
        let root: String
        let mutationRevision: UInt64
    }
    private var reloadIdentity: ReloadIdentity {
        ReloadIdentity(root: rootKey, mutationRevision: app.photoMutationRevision)
    }
    private struct TrashRequest: Identifiable {
        let id = UUID()
        let records: [PhotoTrashRecord]
        let generation: RootGeneration
        let root: URL?
        let permanent: Bool
    }
    init(selecting: Bool = false) { _selecting = State(initialValue: selecting) }
    private var rootKey: String { String(describing: app.libraryRootState) + (app.libraryStore?.grantedRootURL?.absoluteString ?? "none") }
    private func selectionID(_ record: PhotoTrashRecord) -> CaptureID { CaptureID(record.id) }
    private var targets: [PhotoTrashRecord] {
        if let focused { return [focused] }
        return selecting ? records.filter { selected.contains(selectionID($0)) } : records
    }
    var body: some View {
        Group {
            if let focused {
                TrashImagePreview(record: focused, previous: { step(-1) }, next: { step(1) }, close: { self.focused = nil })
            } else {
                ScrollView {
                    LazyVStack(spacing: 12) {
                        if loading { ProgressView("Loading photos…").padding() }
                        if records.isEmpty && !loading { ContentUnavailableView("No Recently Deleted Photos", systemImage: "trash") }
                        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 3), count: typeSize.isAccessibilitySize ? 2 : 3), spacing: 3) {
                            ForEach(records) { record in
                                LibraryCell(card: LibraryCard(id: record.id.uuidString, kind: .single(record.previewCard),
                                    capturedAtUTC: record.deletedAtUTC, representedOriginalCount: 1)) {
                                    guard !app.photoMutationInProgress, confirmation == nil else { return }
                                    if selecting {
                                        if !selected.insert(selectionID(record)).inserted { selected.remove(selectionID(record)) }
                                    } else { focused = record }
                                }
                                .overlay { if selecting && selected.contains(selectionID(record)) { Color.gray.opacity(0.32).allowsHitTesting(false) } }
                                .overlay(alignment: .topTrailing) {
                                    if selecting {
                                        Image(systemName: selected.contains(selectionID(record)) ? "checkmark.circle.fill" : "circle")
                                            .font(.title2).foregroundStyle(selected.contains(selectionID(record)) ? .blue : .white)
                                            .padding(8).allowsHitTesting(false)
                                    }
                                }
                                .overlay(alignment: .bottomLeading) {
                                    if record.purgeStartedAtUTC != nil { Text("Retry deletion").font(.caption2).padding(4).background(.ultraThinMaterial) }
                                }
                                .accessibilityLabel("Deleted photo, \(record.deletedAtUTC.formatted(date: .abbreviated, time: .omitted))")
                                .accessibilityValue(selected.contains(selectionID(record)) ? "Selected" : "Not selected")
                                .background { GeometryReader { proxy in Color.clear.preference(key: GalleryCellFrames.self, value: [selectionID(record): proxy.frame(in: .named("trash-selection"))]) } }
                            }
                        }.padding(.horizontal, 3)
                            .coordinateSpace(name: "trash-selection")
                            .onPreferenceChange(GalleryCellFrames.self) { frames = $0 }
                            .background { GallerySelectionGesture(frames: frames, orderedIDs: records.map(selectionID), selectedIDs: $selected,
                                context: rootKey, isEnabled: selecting && !loading && !app.photoMutationInProgress && confirmation == nil) }
                        Text("Photos stay here until you recover or permanently delete them.")
                            .font(.footnote).foregroundStyle(.secondary).padding()
                    }
                }
            }
        }
        .navigationTitle(focused == nil ? "Recently Deleted" : "")
        .navigationBarTitleDisplayMode(.inline)
        .safeAreaInset(edge: .bottom) { actions }
        .overlay(alignment: .top) { if let errorText { Text(errorText).font(.footnote).padding().background(.regularMaterial).onTapGesture { self.errorText = nil } } }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                if focused != nil { Button { focused = nil } label: { ViewerGlassIcon(symbol: "xmark") }.accessibilityLabel("Back to Recently Deleted") }
                else { PhotoOperationSelectionButton(selecting: selecting, unavailable: records.isEmpty) { selected = []; selecting.toggle() } }
            }
        }
        // Root changes clear selection below. Completion revisions refresh the
        // current focus in place, including a screen returned to during a batch.
        .task(id: reloadIdentity) { await reload() }
        .refreshable { if !app.photoMutationInProgress { await reload() } }
        .onChange(of: app.visiblePhotoMutationProgress, initial: true) { _, progress in
            if let progress, progress.kind != .moveToTrash { queueVerifiedRemovals(progress) }
            else if progress == nil { publishVerifiedRemovals() }
        }
        .onChange(of: rootKey) { _, _ in
            selected = []; focused = nil; records = []; confirmation = nil
            cancelVerifiedRemovals()
        }
        .onDisappear { confirmation = nil; cancelVerifiedRemovals() }
    }
    private var actions: some View {
        HStack {
            Button(focused != nil ? "Recover" : selecting ? "Recover Selected" : "Recover All") { request(permanent: false) }
                .disabled(targets.isEmpty || loading || confirmation != nil || targets.contains { $0.purgeStartedAtUTC != nil } || app.photoMutationInProgress || !app.libraryRootState.isWritable)
                .background { confirmationAnchor(permanent: false) }
            Spacer()
            if selecting { Text("\(selected.count)").monospacedDigit() }
            Spacer()
            Button(focused != nil ? "Delete" : selecting ? "Delete Selected" : "Delete All", role: .destructive) { request(permanent: true) }
                .disabled(targets.isEmpty || loading || confirmation != nil || app.photoMutationInProgress || !app.libraryRootState.isWritable)
                .background { confirmationAnchor(permanent: true) }
        }.frame(minHeight: 44).padding(.horizontal, 20).padding(.vertical, 10).background(.bar)
    }
    private func confirmationAnchor(permanent: Bool) -> some View {
        GalleryTrashConfirmation(requestID: confirmation?.permanent == permanent ? confirmation?.id : nil,
            count: confirmation?.records.count ?? 0, onConfirm: confirm,
            onDismiss: { id in if confirmation?.id == id { confirmation = nil } },
            kind: permanent ? .permanentlyDelete : .recover)
    }
    private func request(permanent: Bool) {
        guard !app.photoMutationInProgress, !targets.isEmpty,
              case .writable(_, let generation) = app.libraryRootState else { return }
        confirmation = TrashRequest(records: targets, generation: generation, root: app.libraryStore?.grantedRootURL, permanent: permanent)
    }
    private func confirm(_ id: UUID) {
        guard let request = confirmation, request.id == id, request.root == app.libraryStore?.grantedRootURL else { confirmation = nil; return }
        confirmation = nil
        let originalRoot = rootKey
        Task {
            let result = await app.performTrashAction(request.records, permanently: request.permanent, generation: request.generation)
            guard rootKey == originalRoot else { return }
            selected.subtract(result.completed.map(CaptureID.init))
            errorText = result.failure
            // The app's retained completion revision owns one reload. The one
            // progress observer batches verified tile/focus changes, including
            // when this surface was reopened during an ongoing operation.
        }
    }
    private func queueVerifiedRemovals(_ progress: PhotoMutationProgress) {
        if verifiedRemovalRoot != rootKey { cancelVerifiedRemovals(); verifiedRemovalRoot = rootKey }
        if let current = verifiedRemovalBatch.operationID, current != progress.id { publishVerifiedRemovals() }
        guard verifiedRemovalBatch.record(operationID: progress.id, completedIDs: progress.completedIDs),
              removalPublication == nil else { return }
        let root = rootKey, publication = UUID(); removalPublicationID = publication
        removalPublication = Task {
            // File outcomes remain exact in the visible progress counter. Only
            // grid invalidation is coalesced, rather than rebuilding it per file.
            do { try await Task.sleep(for: .milliseconds(64)) } catch { return }
            guard !Task.isCancelled, root == rootKey, removalPublicationID == publication else { return }
            publishVerifiedRemovals()
        }
    }
    private func publishVerifiedRemovals() {
        removalPublication?.cancel(); removalPublication = nil; removalPublicationID = UUID()
        guard verifiedRemovalRoot == rootKey else { verifiedRemovalBatch.reset(); return }
        removeVerifiedRecords(verifiedRemovalBatch.drain())
    }
    private func cancelVerifiedRemovals() {
        removalPublication?.cancel(); removalPublication = nil; removalPublicationID = UUID()
        verifiedRemovalBatch.reset(); verifiedRemovalRoot = nil
    }
    private func removeVerifiedRecords(_ ids: Set<UUID>) {
        guard !ids.isEmpty else { return }
        if let focus = focused, ids.contains(focus.id), let i = records.firstIndex(where: { $0.id == focus.id }) {
            focused = records.dropFirst(i + 1).first(where: { !ids.contains($0.id) })
                ?? records.prefix(i).last(where: { !ids.contains($0.id) })
        }
        records.removeAll { ids.contains($0.id) }
        selected.subtract(ids.map(CaptureID.init))
    }
    private func step(_ delta: Int) {
        guard let focused, let i = records.firstIndex(where: { $0.id == focused.id }), records.indices.contains(i + delta), !app.photoMutationInProgress else { return }
        self.focused = records[i + delta]
    }
    private func reload() async {
        let key = rootKey, request = UUID(); reloadID = request
        guard app.libraryRootState.isWritable else { records = []; errorText = "Reconnect your library folder to manage Recently Deleted."; return }
        loading = true
        defer { if reloadID == request { loading = false } }
        do {
            let loaded = try await app.libraryStore?.trashedOriginals() ?? []
            guard !Task.isCancelled, key == rootKey, reloadID == request else { return }
            records = loaded; selected = selected.intersection(Set(loaded.map(selectionID)))
            if let focused { self.focused = loaded.first(where: { $0.id == focused.id }) }
            // A read begun during a batch may return a snapshot from just before
            // its newest verified outcomes. Do not reinsert those completed tiles.
            if let progress = app.visiblePhotoMutationProgress, progress.kind != .moveToTrash {
                queueVerifiedRemovals(progress)
                removeVerifiedRecords(progress.completedIDs)
            }
        } catch {
            AppDiagnostics.record(error, operation: "recentlyDeleted.load")
            if key == rootKey && reloadID == request { errorText = "Couldn’t load Recently Deleted. Reconnect your library folder and try again." }
        }
    }
}

private struct TrashImagePreview: View {
    @Environment(AppEnvironment.self) private var app
    let record: PhotoTrashRecord
    let previous: () -> Void
    let next: () -> Void
    let close: () -> Void
    @State private var image: CGImage?
    @State private var imageID: UUID?
    @State private var message: String?
    var body: some View {
        ZStack {
            Color.black
            if let image, imageID == record.id {
                ZoomableOriginalView(image: image, toggleChrome: {}, previous: previous, next: next,
                    dismissalEnabled: !app.photoMutationInProgress, dismissViewer: close)
            } else if let message { ContentUnavailableView(message, systemImage: "photo") }
            else { ProgressView().tint(.white) }
        }.task(id: record) {
            image = nil; message = nil
            let root = app.libraryRootState, source = app.libraryThumbnailSource
            let outcome = await source.loadViewer(card: record.previewCard, boundLongEdge: 2048)
            do {
                let result = try await DisplayImagePreparation.shared.prepare(outcome)
                guard !Task.isCancelled, app.libraryRootState == root, app.libraryThumbnailSource.grantedRootURL == source.grantedRootURL else { return }
                switch result { case .image(let bitmap): image = bitmap; imageID = record.id
                case .unavailable(let reason):
                    AppDiagnostics.record(reason, operation: "recentlyDeleted.preview")
                    message = "This photo couldn’t be opened. Try reconnecting your library folder."
                }
            } catch {
                AppDiagnostics.record(error, operation: "recentlyDeleted.preview")
                if !Task.isCancelled { message = "This photo couldn’t be opened. Try again." }
            }
        }
    }
}
