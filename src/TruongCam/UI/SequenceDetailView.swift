import SwiftUI

// UI.md "Proposed sequence grouping": one cover tile opens a source grid with the
// sequence name, time, completed/planned count and complete/interrupted status.
// Every source stays individually accessible and exportable, and the cover is a
// retained source preview rather than a merged result.
//
// REVIEW.md C11: `sequenceCards` was populated but no view ever read it, there was
// no per-source previous/next navigation, and there was no sequence export action.
// This view supplies all three.

struct SequenceDetailView: View {
    /// Routes a recovery action raised on THIS destination.
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
        app.camera?.clearLastFailure()
    }

    @Environment(AppEnvironment.self) private var app
    let sequenceID: SequenceID
    let summary: SequenceSummary

    @State private var selectedIndex: Int?
    /// The source currently open in the viewer, identified by position so the sheet
    /// re-presents when the user taps a different row (R09).
    @State private var presentedSequenceIndex: Int?

    private var cards: [LibrarySourceCard] {
        guard app.library?.selectedSequenceID == sequenceID else { return [] }
        return app.library?.sequenceCards ?? []
    }

    var body: some View {
        List {
            Section {
                LabeledContent("Type", value: summary.kind.displayName)
                LabeledContent("Started", value: summary.startedAtUTC.formatted(date: .abbreviated, time: .standard))
                LabeledContent("Sources", value: "\(summary.committedCount) of \(summary.plannedCount) retained")
                LabeledContent("Status", value: summary.statusLabel)
                if summary.skippedDeadlineCount > 0 {
                    LabeledContent("Skipped deadlines", value: "\(summary.skippedDeadlineCount)")
                }
                if !summary.missingIndices.isEmpty {
                    LabeledContent("Missing", value: summary.missingIndices.map(String.init).joined(separator: ", "))
                }
                if !summary.failedIndices.isEmpty {
                    LabeledContent("Failed", value: summary.failedIndices.map(String.init).joined(separator: ", "))
                }
            } header: {
                Text("Sequence")
            } footer: {
                Text("Photos are saved separately, without merging.")
            }

            Section {
                if cards.isEmpty {
                    Text("No photos found for this sequence.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(Array(cards.enumerated()), id: \.element.captureID) { index, card in
                        // R09: tapping a retained source opens the real viewer with
                        // sequence stepping, so the whole sequence is browsable
                        // image by image instead of being a dead list.
                        Button {
                            presentedSequenceIndex = index
                        } label: {
                            SourceRow(card: card, ordinal: card.sequenceIndex ?? index)
                        }
                        .buttonStyle(.plain)
                        .frame(minHeight: 44)
                    }
                }
            } header: {
                Text("Sources (\(cards.count))")
            }

            Section {
                Toggle("Include sidecar files", isOn: Binding(
                    get: { AppEnvironment.includeExportSidecars },
                    set: { app.setIncludeExportSidecars($0) }))
                Button {
                    app.exportSequenceOriginals(sequenceID)
                } label: {
                    Label("Export originals", systemImage: "square.and.arrow.up")
                }
                .frame(minHeight: 44)
                .disabled(cards.isEmpty)
            } footer: {
                // Partial-source confirmation: the user is told up front when some
                // originals cannot be exported rather than discovering it later.
                let unavailable = cards.filter { !$0.canExportOriginal }
                if unavailable.isEmpty {
                    Text("Exports each original DNG unchanged.")
                } else {
                    Text("\(unavailable.count) of \(cards.count) photos can’t be exported. Reconnect the folder or restore them in Files.")
                        .foregroundStyle(.orange)
                }
            }
        }
        .overlay(alignment: .bottom) {
            // H06: render the failure where the export was INVOKED. A root or library
            // banner is not visible on a pushed destination.
            if let failure = app.exportPresenter?.lastFailure ?? app.camera?.lastFailure {
                FailureBanner(failure: failure) { action in
                    handleExportAction(action)
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
        .navigationTitle(summary.kind.displayName)
        .navigationBarTitleDisplayMode(.inline)
        .modifier(PartialExportConsentAlert(surface: .sequence))
        .fullScreenCover(item: presentedSequenceIndexBinding) { presented in
            NavigationStack {
                if presented.value < cards.count, presented.value >= 0 {
                    SourceDetailView(
                        card: cards[presented.value],
                        orderedSources: cards,
                        onStep: { next in
                            selectedIndex = cards.firstIndex { $0.captureID == next.captureID }
                        })
                }
            }
        }
        // AppEnvironment.openSequence owns the query. A second destination task
        // used to repeat it and could publish an obsolete sequence after Back.

        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                // Previous/next navigates the retained sources in ordinal order.
                HStack(spacing: 0) {
                    Button {
                        step(-1)
                    } label: {
                        Label("Previous source", systemImage: "chevron.left")
                    }
                    .disabled(!canStep(-1))
                    .frame(minWidth: 44, minHeight: 44)

                    Button {
                        step(1)
                    } label: {
                        Label("Next source", systemImage: "chevron.right")
                    }
                    .disabled(!canStep(1))
                    .frame(minWidth: 44, minHeight: 44)
                }
            }
        }
    }

    /// Bridges the optional index to a sheet item.
    private var presentedSequenceIndexBinding: Binding<PresentedSourceIndex?> {
        Binding(
            get: { presentedSequenceIndex.map(PresentedSourceIndex.init) },
            set: { presentedSequenceIndex = $0?.value })
    }

    private func canStep(_ delta: Int) -> Bool {
        let current = selectedIndex ?? (delta > 0 ? -1 : cards.count)
        let next = current + delta
        return next >= 0 && next < cards.count
    }

    private func step(_ delta: Int) {
        let current = selectedIndex ?? (delta > 0 ? -1 : cards.count)
        let next = current + delta
        guard next >= 0, next < cards.count else { return }
        selectedIndex = next
        // Step the REAL viewer sheet. The previous implementation wrote
        // `AppEnvironment.presentedSource`, which had no reader, so the toolbar
        // appeared to do nothing (REVIEW.md F06).
        presentedSequenceIndex = next
    }
}

/// A sheet item wrapping the presented source's position in the sequence.
struct PresentedSourceIndex: Identifiable, Hashable {
    let value: Int
    var id: Int { value }
}

/// One retained source inside a sequence, showing its ordinal and offset when the
/// sidecar recorded one (never a guessed brightness-derived value).
struct SourceRow: View {
    let card: LibrarySourceCard
    let ordinal: Int

    var body: some View {
        HStack(spacing: 8) {
            Text("\(ordinal)")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(minWidth: 20, alignment: .trailing)
            VStack(alignment: .leading, spacing: 2) {
                Text(card.rawDimensions.map { "\($0.width)×\($0.height)" } ?? "RAW original")
                    .font(.subheadline)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            if !card.canExportOriginal {
                Image(systemName: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
                    .accessibilityLabel("Unavailable locally")
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var detail: String {
        var parts: [String] = []
        if let offset = card.sequenceIndex { parts.append("source \(offset + 1)") }
        switch card.availability {
        case .local: parts.append("available")
        case .missing: parts.append("missing")
        case .inaccessible: parts.append("couldn’t be opened")
        case .unknown: parts.append("not checked yet")
        }
        return parts.joined(separator: " · ")
    }
}
