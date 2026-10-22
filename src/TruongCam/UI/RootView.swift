import SwiftUI
import AVKit

/// Root navigation. Camera and library are the only two top-level screens in v1.
struct RootView: View {
    @Environment(AppEnvironment.self) private var app
    /// L03: scene ownership lives on the ALWAYS-PRESENT root type. `CameraScreen` is
    /// removed when the library tab is selected, so a handler there cannot observe scene
    /// changes while the library or a modal covers the camera.
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        Group {
            switch app.tab {
            case .camera:
                CameraScreen()
            case .library:
                LibraryScreen()
            }
        }
        .overlay {
            if app.isPreparingExperience {
                LaunchPreparationView().transition(.opacity)
            }
        }
        .onChange(of: app.canFinishLaunchPreparation, initial: true) { _, ready in
            if ready { app.finishLaunchPreparationIfReady() }
        }
        .tint(.accentColor)
        .background(Color.black.ignoresSafeArea())
        // R04: one clearly labeled export setting, visible from root/library/sequence
        // flows. DNG-only by default; the choice is frozen per invocation by the
        // synchronous gesture freeze, so toggling it cannot alter an in-flight export.
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Toggle(isOn: Binding(
                        get: { AppEnvironment.includeExportSidecars },
                        set: { app.setIncludeExportSidecars($0) })) {
                        Text("Include sidecar files")
                        Text("Photo originals only when off (default)")
                    }
                } label: {
                    Label("Export options", systemImage: "square.and.arrow.up.badge.clock")
                }
                .accessibilityIdentifier("exportOptions")
            }
        }
        .modifier(ExportSheetPresentation(presenter: app.exportPresenter, surface: .nonViewer))
        .preferredColorScheme(.dark)
        .tint(.white)
        .task(id: app.camera?.graphIdentity) {
            // L03: replay the CURRENT phase for a late-injected graph. A graph created
            // while the app was already backgrounded must learn that immediately.
            guard let camera = app.camera else { return }
            switch scenePhase {
            case .active:
                await camera.handleSceneBecameActive()
            case .inactive, .background:
                await camera.handleSceneBecameInactive()
            @unknown default:
                await camera.handleSceneBecameInactive()
            }
        }
        // Scene changes are forwarded to the camera owner from HERE, so they are observed
        // no matter which tab is showing (REVIEW.md L03). Identical phases are idempotent
        // because the model's scene handlers only invalidate on a real change.
        .onChange(of: scenePhase) { _, phase in
            guard let camera = app.camera else { return }
            Task {
                switch phase {
                case .active:
                    await camera.handleSceneBecameActive()
                case .inactive, .background:
                    await camera.handleSceneBecameInactive()
                @unknown default:
                    await camera.handleSceneBecameInactive()
                }
            }
        }
    }
}

/// The selected **Precision** camera appearance: the full sensor frame dominates
/// the screen, with compact readouts and an on-demand adjustment panel overlay.
struct CameraScreen: View {
    @Environment(AppEnvironment.self) private var app
    @Environment(\.openURL) private var openURL
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        GeometryReader { proxy in
            let isLandscape = proxy.size.width > proxy.size.height
            ZStack {
                Color.black.ignoresSafeArea()

                let layout = CameraScreenLayout(size: proxy.size,
                    bottomSafeArea: proxy.safeAreaInsets.bottom, accessibility: dynamicTypeSize.isAccessibilitySize)
                Viewfinder()
                    .frame(width: layout.preview.width, height: layout.preview.height)
                    .position(x: layout.preview.midX, y: layout.preview.midY)

                if isLandscape {
                    landscapeLayout(in: proxy.size, safeArea: proxy.safeAreaInsets)
                        .opacity(app.camera?.isHardwareControlFullscreen == true ? 0.15 : 1)
                        .allowsHitTesting(app.camera?.isHardwareControlFullscreen != true)
                } else {
                    portraitLayout(in: proxy.size, safeArea: proxy.safeAreaInsets)
                        .opacity(app.camera?.isHardwareControlFullscreen == true ? 0.15 : 1)
                        .allowsHitTesting(app.camera?.isHardwareControlFullscreen != true)
                }

                if let camera = app.camera, camera.surface != .ready, camera.surface != .preparing, !camera.isSwitchingLens {
                    VStack(spacing: 12) {
                        Text(camera.surface.userDescription).multilineTextAlignment(.center)
                        Button("Retry camera") { Task { await camera.startIfNeeded() } }
                            .buttonStyle(.bordered)
                            .frame(minHeight: 44)
                    }
                    .padding()
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
                    .padding(24)
                }

                if let camera = app.camera, camera.isTimerRunning {
                    // Cancel must be reachable while counting down, at large type.
                    TimerCancelBanner {
                        camera.cancelTimer()
                    }
                    .padding()
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                }

                if let camera = app.camera, let failure = camera.lastFailure {
                    FailureBanner(failure: failure) { action in
                        handle(action, camera: camera)
                    }
                    .padding()
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                } else if let notice = app.camera?.lastNotice ?? app.exportPresenter?.lastNotice {
                    // REVIEW.md S11: notices were set but never shown, so a partial
                    // export and a refused action both looked like nothing happened.
                    NoticeBanner(text: notice) {
                        app.camera?.clearLastNotice()
                        app.exportPresenter?.clearLastNotice()
                    }
                    .padding()
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                }
            }
        }
        .task(id: thumbnailPreparationIdentity) {
            guard thumbnailPreparationIdentity.enabled else { return }
            do { try await Task.sleep(for: .milliseconds(750)) } catch { return }
            guard !Task.isCancelled else { return }
            await app.library?.prepareFirstThumbnails()
        }
        .onCameraCaptureEvent(isEnabled: hardwareInteractionEnabled,
            primaryAction: { handleHardwareShutter($0, source: .primary) },
            secondaryAction: { handleHardwareShutter($0, source: .secondary) })
        .onChange(of: hardwareInteractionEnabled) { _, enabled in
            if !enabled {
                app.camera?.handleHardwareShutter(.cancelled, source: .primary)
                app.camera?.handleHardwareShutter(.cancelled, source: .secondary)
            }
        }
        .onChange(of: hardwareControlConfiguration, initial: true) { _, configuration in
            app.camera?.updateHardwareControls(configuration)
        }
        .task {
            // Start when possible, and let the graphState observer below handle a
            // late attachment. Both paths are idempotent (REVIEW.md S03).
            guard let camera = app.camera else { return }
            await camera.startIfNeeded()
            camera.startReadbackObservation()
            camera.startLevelFeed()
            camera.startSessionConditionObservation()
        }
        .onDisappear {
            app.camera?.handleHardwareShutter(.cancelled)
            app.camera?.stopContinuousCapture()
            app.camera?.updateHardwareControls(HardwareControlConfiguration(enabled: false, selections: []))
            // Stopping analysis/motion when the camera is covered keeps sensor and
            // video work off while the library is open (REVIEW.md C09).
            // The camera SCREEN is no longer visible, which is distinct from the app
            // being backgrounded. Stops the sensor and cancels unsubmitted work
            // (REVIEW.md F02).
            Task {
                guard app.tab != .camera else { return }
                app.camera?.stopReadbackObservation()
                app.camera?.stopLevelFeed()
                app.camera?.stopSessionConditionObservation()
                await app.camera?.handleCameraScreenCovered()
            }
        }
        .onChange(of: app.graphState) { _, state in
            // The camera view starts the camera when the graph is genuinely ready,
            // not at whatever moment its own task happened to run (REVIEW.md S03).
            guard state.isReady, let camera = app.camera else { return }
            // REVIEW.md F02: the late graph-ready path previously started only the
            // camera, unlike the normal task, so readback/motion/conditions stayed
            // unobserved after a late injection.
            Task {
                await camera.startIfNeeded()
                camera.startReadbackObservation()
                camera.startLevelFeed()
                camera.startSessionConditionObservation()
            }
        }
        .sheet(item: cameraSheetBinding, onDismiss: { app.camera?.launchQueuedSequence() }) { sheet in
            switch sheet {
            case .tools: if let camera = app.camera { ToolsSheet(camera: camera) }
            case .folder: FolderSheet()
            case .recovery: PendingRecoverySheet()
            }
        }
        // H02: re-install on EVERY appearance of a camera graph, and also when the
        // camera object itself changes identity, so a late-injected graph cannot leave
        // Settings routing unset.
        // H06: present the prepared export. Attached at the root so an export invoked
        // from a non-modal surface has a presentation point; modal surfaces attach
        // their own so a viewer is never hidden behind this one.
        .task(id: app.camera?.graphIdentity) {
            guard let camera = app.camera else { return }
            camera.openSettingsPage = {
                guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
                openURL(url)
            }
            await camera.handleCameraScreenRevealed()
        }
        .onAppear {
            // Install the Settings route once the view exists. A denied camera
            // grant is recoverable only through Settings (REVIEW.md S03).
            app.camera?.openSettingsPage = {
                guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
                openURL(url)
            }
            // G02: the camera screen is visible again, so screen eligibility is
            // restored by the ACTUAL UI path rather than only by a test helper.
            Task { await app.camera?.handleCameraScreenRevealed() }
        }
    }

    private var hardwareShutterEnabled: Bool {
        !app.isPreparingExperience && app.tab == .camera && app.camera?.isHardwareShutterEnabled == true
            && app.exportPresenter?.presented == nil && app.exportPresenter?.hasActiveExport != true && app.pendingPartialExport == nil
    }

    private struct ThumbnailPreparationIdentity: Hashable {
        let enabled: Bool
        let root: String
        let cards: [LibrarySourceCard]
    }
    private var thumbnailPreparationIdentity: ThumbnailPreparationIdentity {
        ThumbnailPreparationIdentity(enabled: !app.isPreparingExperience && app.tab == .camera && !app.photoMutationInProgress
            && app.camera?.isHardwareShutterEnabled == true && app.camera?.isCaptureBusy == false && app.camera?.isContinuousCaptureActive == false
            && app.camera?.isPreviewTransitionVisible == false,
            root: String(describing: app.libraryRootState) + (app.libraryThumbnailSource.grantedRootURL?.absoluteString ?? "none"),
            cards: app.library?.firstThumbnailSources ?? [])
    }

    private func handleHardwareShutter(_ event: AVCaptureEvent, source: HardwareShutterSource) {
        guard let camera = app.camera else { return }
        switch event.phase {
        case .began: if hardwareShutterEnabled { camera.handleHardwareShutter(.began, source: source) }
        case .ended: camera.handleHardwareShutter(.ended, source: source)
        case .cancelled: camera.handleHardwareShutter(.cancelled, source: source)
        @unknown default: camera.handleHardwareShutter(.cancelled, source: source)
        }
    }

    private var hardwareInteractionEnabled: Bool {
        !app.isPreparingExperience && app.tab == .camera && app.camera?.isHardwareInteractionEligible == true
            && app.exportPresenter?.presented == nil && app.exportPresenter?.hasActiveExport != true && app.pendingPartialExport == nil
    }

    private var hardwareControlConfiguration: HardwareControlConfiguration {
        app.camera?.hardwareConfiguration(enabled: !app.isPreparingExperience && app.tab == .camera
            && app.exportPresenter?.presented == nil && app.exportPresenter?.hasActiveExport != true && app.pendingPartialExport == nil)
            ?? HardwareControlConfiguration(enabled: false, selections: [])
    }

    private func handle(_ action: UserFacingFailure.Action, camera: CameraViewModel) {
        switch action {
        case .retrySave, .exportPending:
            camera.showPendingRecovery()
        case .reconnect:
            camera.isFolderSheetPresented = true
        case .resetToAuto:
            camera.resetControlsToAuto()
        case .openSettings:
            // The visible Open Settings action previously did nothing
            // (REVIEW.md S03), so a denied user had no recovery route at all.
            camera.openSystemSettings()
        case .dismiss:
            break
        }
        camera.clearLastFailure()
    }

    private var toolsSheetBinding: Binding<Bool> {
        Binding(get: { app.camera?.isToolsSheetPresented ?? false },
                set: { app.camera?.isToolsSheetPresented = $0 })
    }

    private var folderSheetBinding: Binding<Bool> {
        Binding(get: { app.camera?.isFolderSheetPresented ?? false },
                set: { app.camera?.isFolderSheetPresented = $0 })
    }

    /// The prepared export awaiting presentation (REVIEW.md H06).

    private var cameraSheetBinding: Binding<CameraViewModel.CameraSheet?> {
        Binding(get: { app.camera?.presentedCameraSheet },
                set: { app.camera?.presentedCameraSheet = $0 })
    }

    // MARK: Portrait

    @ViewBuilder
    private func portraitLayout(in size: CGSize, safeArea: EdgeInsets) -> some View {
        let layout = CameraScreenLayout(size: size, bottomSafeArea: safeArea.bottom,
            accessibility: dynamicTypeSize.isAccessibilitySize)
        ZStack(alignment: .top) {
            Color.clear.allowsHitTesting(false)
                .frame(width: layout.preview.width, height: layout.preview.height)
                .overlay(alignment: .top) {
                    CameraTopRow().frame(height: CameraPreviewChromeLayout.headerHeight)
                        .padding(.horizontal, CameraPreviewChromeLayout.headerInset)
                        .padding(.top, CameraPreviewChromeLayout.headerInset)
                }
                .overlay(alignment: .bottom) { PhysicalLensSelector().padding(.bottom, 10) }
                .position(x: layout.preview.midX, y: layout.preview.midY)
            VStack(spacing: 0) {
                CameraReadoutRow().frame(height: CameraScreenLayout.readoutHeight)
                adjustmentWell(height: layout.naturalAdjustmentHeight, viewport: layout.adjustmentViewportHeight)
                Color.clear.frame(height: CameraScreenLayout.adjustmentShutterSpacing).allowsHitTesting(false)
                CameraShutterRail(compactFeedback: true)
                    .frame(height: layout.shutterRailHeight).padding(.horizontal, 20)
            }
            .background(.black)
            .frame(width: layout.controls.width, height: layout.controls.height)
            .position(x: layout.controls.midX, y: layout.controls.midY)
        }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    @ViewBuilder private func adjustmentWell(height: CGFloat, viewport: CGFloat? = nil) -> some View {
        if let camera = app.camera {
            CameraAdjustmentWell(camera: camera, controlsViewportHeight: viewport, controlsContentHeight: height)
                .padding(.horizontal, 8).frame(height: viewport ?? height)
        } else { Color.clear.frame(height: viewport ?? height) }
    }

    // MARK: Landscape

    /// Expanded landscape: the whole 4:3 frame uses the maximum available height
    /// with no vertical padding, and the interactive rail stays on the screen's
    /// right edge inside the real safe area.
    @ViewBuilder
    private func landscapeLayout(in size: CGSize, safeArea: EdgeInsets) -> some View {
        let layout = CameraScreenLayout(size: size, bottomSafeArea: safeArea.bottom,
            accessibility: dynamicTypeSize.isAccessibilitySize)
        ZStack {
            Color.clear.allowsHitTesting(false)
                .frame(width: layout.preview.width, height: layout.preview.height)
                .overlay(alignment: .topLeading) {
                    CameraTopRow(isCompact: true)
                        .padding(.horizontal, CameraPreviewChromeLayout.headerInset)
                        .padding(.top, CameraPreviewChromeLayout.headerInset)
                }
                .overlay(alignment: .bottom) { PhysicalLensSelector().padding(.bottom, 10) }
                .position(x: layout.preview.midX, y: layout.preview.midY)
            VStack(spacing: 0) {
                ScrollView {
                    VStack(spacing: 0) {
                        CameraReadoutGrid()
                        adjustmentWell(height: layout.naturalAdjustmentHeight)
                    }
                }
                .scrollBounceBehavior(.basedOnSize)
                .frame(height: layout.parameterHeight)
                Color.clear.frame(height: CameraScreenLayout.adjustmentShutterSpacing).allowsHitTesting(false)
                CameraShutterRail(isLandscape: true, compactFeedback: true)
                    .frame(height: layout.shutterRailHeight)
            }
            .frame(width: layout.controls.width, height: layout.controls.height)
            .background(.black)
            .position(x: layout.controls.midX, y: layout.controls.midY)
        }

    }
}

/// Countdown banner with an explicit, always-reachable Cancel action.
struct TimerCancelBanner: View {
    @Environment(AppEnvironment.self) private var app
    let onCancel: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "timer")
            Text(app.camera?.timerBadgeText ?? "Timer")
                .font(.headline)
            Spacer(minLength: 0)
            Button("Cancel", action: onCancel)
                .buttonStyle(.borderedProminent)
                .frame(minHeight: 44)
                .accessibilityLabel("Cancel timer")
                .accessibilityHint("Stops the countdown before any photo is taken.")
        }
        .padding(10)
        .background(.ultraThinMaterial, in: Capsule())
        .accessibilityElement(children: .contain)
    }
}

/// A dismissible informational notice. Distinct from a failure: nothing failed,
/// but something the user asked for did not happen exactly as expected (for
/// example a partial export). REVIEW.md S11.
struct NoticeBanner: View {
    let text: String
    let onDismiss: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "info.circle")
            Text(text).font(.footnote)
            Spacer(minLength: 0)
            Button("Dismiss", action: onDismiss)
                .font(.footnote.weight(.semibold))
                .frame(minHeight: 44)
        }
        .padding(10)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
        .accessibilityElement(children: .combine)
    }
}

/// Failure banner with the recovery actions the contract requires.
struct FailureBanner: View {
    let failure: UserFacingFailure
    let onAction: (UserFacingFailure.Action) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(failure.displayTitle)
                .font(.headline)
            Text(failure.detail)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            FlowRow(spacing: 8) {
                ForEach(failure.actionLabels, id: \.0) { action, label in
                    Button(label) { onAction(action) }
                        .buttonStyle(.bordered)
                        .frame(minHeight: 44)
                }
            }
        }
        .padding(12)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(failure.displayTitle). \(failure.detail)")
    }
}

/// Minimal wrapping row so action buttons never clip at large Dynamic Type.
struct FlowRow: Layout {
    var spacing: CGFloat = 8

    /// Measurement and placement share the same packing plan, including the
    /// widest earlier row. A short last row cannot shrink the layout underneath
    /// actions already measured on a wider row.
    static func packing(sizes: [CGSize], width: CGFloat, spacing: CGFloat) -> (size: CGSize, origins: [CGPoint]) {
        let available = max(0, width)
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0, widest: CGFloat = 0
        var origins: [CGPoint] = []
        for size in sizes {
            let gap = x > 0 ? spacing : 0
            if x > 0, x + gap + size.width > available {
                widest = max(widest, x)
                y += rowHeight + spacing
                x = 0; rowHeight = 0
            }
            if x > 0 { x += spacing }
            origins.append(CGPoint(x: x, y: y))
            x += size.width
            rowHeight = max(rowHeight, size.height)
        }
        widest = max(widest, x)
        return (CGSize(width: min(available, widest), height: y + rowHeight), origins)
    }

    private func sizes(for subviews: Subviews, width: CGFloat) -> [CGSize] {
        let proposal = width.isFinite ? ProposedViewSize(width: max(0, width), height: nil) : .unspecified
        return subviews.map { $0.sizeThatFits(proposal) }
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        return Self.packing(sizes: sizes(for: subviews, width: width), width: width, spacing: spacing).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let sizes = sizes(for: subviews, width: bounds.width)
        let plan = Self.packing(sizes: sizes, width: bounds.width, spacing: spacing)
        for (index, subview) in subviews.enumerated() {
            let origin = plan.origins[index]
            subview.place(at: CGPoint(x: bounds.minX + origin.x, y: bounds.minY + origin.y),
                          anchor: .topLeading, proposal: ProposedViewSize(sizes[index]))
        }
    }
}

/// The actual graph/display preparation runs behind this surface. It never
/// takes hidden photos or requests Photos access and has no invented percentage.
struct LaunchPreparationView: View {
    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            VStack(spacing: 24) {
                Image(systemName: "camera").font(.system(size: 42, weight: .light))
                Text("TruongCam").font(.system(.largeTitle, design: .serif))
                ProgressView().tint(.white).padding(.top, 8)
                Text("Getting ready").font(.subheadline).foregroundStyle(.secondary)
            }
            .padding(32)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("TruongCam. Getting ready.")
        .accessibilityIdentifier("launchPreparation")
    }
}
