//
//  RecordingStudioInspector.swift
//  Screendrop
//
//  The Studio inspector shows one thing at a time. With nothing chosen it
//  is the Look: saved styles, the canvas shape, the frame around the video,
//  the list of features and the sound - short enough to fit one screen.
//  A feature's row opens its own page, and clicking a zoom on the timeline
//  opens that zoom's page; a back link returns to the Look. Pages swap in
//  place with no transition. Export and Share stay pinned below every page.
//

import AppKit
import SwiftUI
import UniformTypeIdentifiers

private extension ZoomAnchorMode {
    var inspectorTitle: String {
        switch self {
        case .pointerAnchor: "Pointer"
        case .smartAnchor: "Smart"
        case .pinnedAnchor: "Fixed"
        }
    }
}

private enum StudioTranscriptTab: Hashable {
    case captions
    case edit
}

/// A feature's own page, opened from its row on the Look.
private enum StudioInspectorPage: Hashable {
    case camera
    case zoom
    case cursor
    case captions
    case keystrokes
    case speedBadge
    case clip

    var title: String {
        switch self {
        case .camera: "Camera"
        case .zoom: "Zoom"
        case .cursor: "Cursor"
        case .captions: "Captions"
        case .keystrokes: "Keystrokes"
        case .speedBadge: "Speed Badge"
        case .clip: "Clip"
        }
    }

    var systemImage: String {
        switch self {
        case .camera: "person.crop.square"
        case .zoom: "plus.magnifyingglass"
        case .cursor: "cursorarrow"
        case .captions: "captions.bubble"
        case .keystrokes: "command"
        case .speedBadge: "forward"
        case .clip: "film"
        }
    }
}

/// What the inspector is showing, so the scroll position starts over when
/// it changes.
private enum StudioInspectorContent: Hashable {
    case look
    case page(StudioInspectorPage)
    case zoom(UUID)
}

struct StudioInspector: View {
    @Bindable var model: RecordingStudioModel
    @State private var wallpaperStore = AnnotationWallpaperStore.shared
    @State private var stylePresetStore = RecordingStudioStylePresetStore.shared
    @State private var transcriptTab: StudioTranscriptTab = .captions
    @State private var isAudioExportOptionsPresented = false
    @State private var page: StudioInspectorPage?
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 0) {
                switch content {
                case .look:
                    lookPage
                case .page(let page):
                    featurePage(page)
                case .zoom:
                    if let cue = model.selectedCue {
                        selectedZoomPage(for: cue)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .padding(.bottom, 12)
        }
        // Each page opens at its top.
        .id(content)
        .scrollContentBackground(.hidden)
        .scrollEdgeEffectSoftIfAvailable()
        .safeAreaInset(edge: .bottom, spacing: 0) {
            // Backed like the panel, so the list never shows through the
            // buttons as it scrolls.
            StudioActionFooter(model: model)
                .background(sidebarBackground)
        }
        .background(sidebarBackground)
        .onChange(of: availablePages) { _, available in
            // A page whose feature went away (its only sped-up clip was
            // reset, say) folds back to the Look.
            if let page, !available.contains(page) {
                self.page = nil
            }
        }
        .inspectorColumnWidth(
            min: InspectorMetrics.columnMinWidth,
            ideal: InspectorMetrics.columnIdealWidth,
            max: InspectorMetrics.columnMaxWidth
        )
        .frame(
            minWidth: InspectorMetrics.columnMinWidth,
            maxWidth: .infinity,
            maxHeight: .infinity,
            alignment: .topLeading
        )
        .task {
            await wallpaperStore.reload()
        }
    }

    /// A selected zoom wins: clicking one is always a request to edit it.
    /// Clips are not here on purpose - the clip lane selects whatever clip
    /// it is scrubbed over, so following it would flip the panel on every
    /// scrub. The selected clip opens from its row instead.
    private var content: StudioInspectorContent {
        if let cue = model.selectedCue { return .zoom(cue.id) }
        if let page, availablePages.contains(page) { return .page(page) }
        return .look
    }

    private var availablePages: Set<StudioInspectorPage> {
        var pages: Set<StudioInspectorPage> = [.zoom]
        if model.hasCameraVideo { pages.insert(.camera) }
        if model.pointerIsSynthesized { pages.insert(.cursor) }
        if model.canTranscribe || model.hasSubtitles { pages.insert(.captions) }
        if model.hasKeystrokes { pages.insert(.keystrokes) }
        if model.hasSpedUpClips { pages.insert(.speedBadge) }
        if model.selectedClip != nil { pages.insert(.clip) }
        return pages
    }

    private func open(_ page: StudioInspectorPage) {
        self.page = page
    }

    // MARK: Look

    @ViewBuilder
    private var lookPage: some View {
        RecordingStudioStyleStrip(model: model, presetStore: stylePresetStore)

        InspectorSection("Canvas") {
            canvasControls
        }

        InspectorSection(
            "Frame",
            accessory: {
                if !usesDefaultLayout {
                    InspectorResetButton(help: "Reset padding, corners and shadow") {
                        withAnimation(.morphIfAllowed) {
                            model.style.padding = 0.06
                            model.style.cornerRadius = 0.02
                            model.style.shadow = 0.45
                        }
                    }
                    .transition(.blurPop)
                }
            }
        ) {
            VStack(alignment: .leading, spacing: InspectorMetrics.rowSpacing) {
                StudioBackgroundRow(
                    model: model,
                    wallpaperStore: wallpaperStore,
                    onPickWallpaper: pickWallpaper
                )
                frameControls
            }
        }

        InspectorSection("Video") {
            featureList
        }

        audioSection
    }

    /// Everything drawn over or done to the video, one row each.
    private var featureList: some View {
        StudioFeatureList {
            if model.hasCameraVideo {
                StudioFeatureRow(
                    title: "Camera",
                    systemImage: StudioInspectorPage.camera.systemImage,
                    summary: cameraSummary,
                    isOn: $model.style.camera.isVisible
                ) { open(.camera) }
            }

            StudioFeatureRow(
                title: "Zoom",
                systemImage: StudioInspectorPage.zoom.systemImage,
                summary: zoomSummary,
                isOn: $model.zoomEnabled
            ) { open(.zoom) }

            if model.pointerIsSynthesized {
                StudioFeatureRow(
                    title: "Cursor",
                    systemImage: StudioInspectorPage.cursor.systemImage,
                    summary: String(format: "%.1f×", model.style.cursorScale),
                    isOn: Binding(
                        get: { !model.style.hidesCursor },
                        set: { model.style.hidesCursor = !$0 }
                    )
                ) { open(.cursor) }
            }

            if model.canTranscribe || model.hasSubtitles {
                StudioFeatureRow(
                    title: "Captions",
                    systemImage: StudioInspectorPage.captions.systemImage,
                    summary: captionsSummary,
                    isOn: captionsToggle
                ) { open(.captions) }
            }

            if model.hasKeystrokes {
                StudioFeatureRow(
                    title: "Keystrokes",
                    systemImage: StudioInspectorPage.keystrokes.systemImage,
                    summary: model.keystrokePlacement.title,
                    isOn: $model.showsKeystrokes
                ) { open(.keystrokes) }
            }

            if model.hasSpedUpClips {
                StudioFeatureRow(
                    title: "Speed Badge",
                    systemImage: StudioInspectorPage.speedBadge.systemImage,
                    summary: model.speedBadgePlacement.title,
                    isOn: $model.showsSpeedBadge
                ) { open(.speedBadge) }
            }

            if let clip = model.selectedClip {
                StudioFeatureRow(
                    title: "Clip",
                    systemImage: StudioInspectorPage.clip.systemImage,
                    summary: clipSummary(for: clip)
                ) { open(.clip) }
            }
        }
    }

    private var cameraSummary: String {
        let center = model.style.camera.center
        let vertical = center.y < 0.34 ? "Top" : center.y > 0.66 ? "Bottom" : "Middle"
        let horizontal = center.x < 0.34 ? "left" : center.x > 0.66 ? "right" : "center"
        return vertical == "Middle" && horizontal == "center" ? "Center" : "\(vertical) \(horizontal)"
    }

    private var zoomSummary: String {
        switch model.zoomCues.count {
        case 0: "None yet"
        case 1: "1 zoom"
        case let count: "\(count) zooms"
        }
    }

    private var captionsSummary: String? {
        switch model.transcriptionState {
        case .transcribing: return "Transcribing…"
        case .failed: return "Failed"
        case .idle:
            return model.hasSubtitles
                ? "\(model.subtitleCues.count) line\(model.subtitleCues.count == 1 ? "" : "s")"
                : "Transcribe"
        }
    }

    /// Captions have a switch only once there is something to show.
    private var captionsToggle: Binding<Bool>? {
        guard model.hasSubtitles, case .idle = model.transcriptionState else { return nil }
        return $model.showsSubtitles
    }

    private func clipSummary(for clip: RecordingClipSegment) -> String {
        let segments = model.clipTimeline.segments
        let speed = RecordingClipSegment.speedTitle(clip.speed)
        guard segments.count > 1,
              let index = segments.firstIndex(where: { $0.id == clip.id }) else {
            return speed
        }
        return "\(index + 1) of \(segments.count) · \(speed)"
    }

    // MARK: Pages

    /// The top of every page: a way back, the page's title, and its switch.
    private func pageHeader<Accessory: View>(
        _ title: String,
        systemImage: String,
        backTitle: String = "Look",
        isOn: Binding<Bool>? = nil,
        toggleTitle: String = "",
        onBack: @escaping () -> Void,
        @ViewBuilder accessory: () -> Accessory = { EmptyView() }
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 4) {
                Button(action: onBack) {
                    HStack(spacing: 3) {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 10, weight: .semibold))
                        Text(backTitle)
                            .font(.inspectorValue)
                    }
                    .foregroundStyle(Palette.secondaryLabel)
                    .frame(height: 24)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Back to \(backTitle)")
                // Escape belongs to the crop bar while cropping.
                .keyboardShortcut(model.isCroppingVideo ? nil : .cancelAction)

                Spacer(minLength: 0)

                accessory()
            }

            HStack(spacing: 8) {
                Image(systemName: systemImage)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Palette.label)
                Text(title)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Palette.label)
                Spacer(minLength: 0)
                if let isOn {
                    InspectorToggle(
                        toggleTitle.isEmpty ? title : toggleTitle,
                        isOn: Binding(
                            get: { isOn.wrappedValue },
                            set: { value in
                                withAnimation(.morphIfAllowed) { isOn.wrappedValue = value }
                            }
                        ),
                        size: .regular
                    )
                }
            }
        }
        .padding(.horizontal, InspectorMetrics.horizontalPadding)
        .padding(.top, 10)
        .padding(.bottom, 4)
    }

    /// A page's controls. A feature that is switched off keeps its controls
    /// on show, dimmed, so the page still says what turning it on would do.
    private func pageBody<Content: View>(
        isActive: Bool = true,
        @ViewBuilder content: () -> Content
    ) -> some View {
        content()
            .padding(.horizontal, InspectorMetrics.horizontalPadding)
            .padding(.top, InspectorMetrics.headerSpacing)
            .frame(maxWidth: .infinity, alignment: .leading)
            .disabled(!isActive)
            .opacity(isActive ? 1 : 0.45)
    }

    private func backToLook() {
        page = nil
    }

    @ViewBuilder
    private func featurePage(_ page: StudioInspectorPage) -> some View {
        switch page {
        case .camera:
            pageHeader(
                page.title,
                systemImage: page.systemImage,
                isOn: $model.style.camera.isVisible,
                toggleTitle: "Show camera",
                onBack: backToLook
            )
            pageBody(isActive: model.style.camera.isVisible) {
                cameraControls
            }

        case .zoom:
            pageHeader(
                page.title,
                systemImage: page.systemImage,
                isOn: $model.zoomEnabled,
                toggleTitle: "Enable zooms",
                onBack: backToLook
            )
            pageBody(isActive: model.zoomEnabled) {
                zoomControls
            }

        case .cursor:
            let isShown = Binding(
                get: { !model.style.hidesCursor },
                set: { model.style.hidesCursor = !$0 }
            )
            pageHeader(
                page.title,
                systemImage: page.systemImage,
                isOn: isShown,
                toggleTitle: "Show mouse pointer",
                onBack: backToLook
            ) {
                if model.style.cursorScale != RecordingStudioStyle.defaultCursorScale {
                    InspectorResetButton(help: "Reset cursor size") {
                        withAnimation(.morphIfAllowed) {
                            model.style.cursorScale = RecordingStudioStyle.defaultCursorScale
                        }
                    }
                }
            }
            pageBody(isActive: !model.style.hidesCursor) {
                cursorControls
            }

        case .captions:
            pageHeader(
                page.title,
                systemImage: page.systemImage,
                isOn: captionsToggle,
                toggleTitle: "Show subtitles",
                onBack: backToLook
            ) {
                if model.transcriptionState.isTranscribing {
                    ProgressView()
                        .controlSize(.mini)
                        .frame(width: 24, height: 24)
                }
            }
            pageBody(isActive: captionsToggle?.wrappedValue ?? true) {
                transcriptionControls
            }

        case .keystrokes:
            pageHeader(
                page.title,
                systemImage: page.systemImage,
                isOn: $model.showsKeystrokes,
                toggleTitle: "Show keystrokes",
                onBack: backToLook
            )
            pageBody(isActive: model.showsKeystrokes) {
                keystrokeControls
            }

        case .speedBadge:
            pageHeader(
                page.title,
                systemImage: page.systemImage,
                isOn: $model.showsSpeedBadge,
                toggleTitle: "Show speed badge",
                onBack: backToLook
            )
            pageBody(isActive: model.showsSpeedBadge) {
                speedBadgeControls
            }

        case .clip:
            if let clip = model.selectedClip {
                selectedClipPage(for: clip)
            }
        }
    }

    private var audioSection: some View {
        InspectorSection(
            "Audio",
            accessory: {
                if model.replacementAudio != nil {
                    Group {
                        if model.hasRecordedAudio {
                            InspectorResetButton(help: "Use the recorded audio again") {
                                withAnimation(.morphIfAllowed) { model.removeReplacementAudio() }
                            }
                        } else {
                            InspectorClearButton(help: "Remove this audio") {
                                withAnimation(.morphIfAllowed) { model.removeReplacementAudio() }
                            }
                        }
                    }
                    .transition(.blurPop)
                }
            }
        ) {
            audioControls
        }
    }

    // MARK: Style

    private var canvasControls: some View {
        VStack(alignment: .leading, spacing: InspectorMetrics.rowSpacing) {
            InspectorSegmented(
                options: ExportAspectPreset.allCases,
                isSelected: { $0 == model.exportAspect },
                onTap: { aspect in
                    withAnimation(.morphIfAllowed) { model.exportAspect = aspect }
                },
                label: { preset in
                    Text(preset.title)
                        .font(.inspectorSegment)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                        .help(preset.help)
                }
            )

            if model.exportAspect != .original {
                InspectorSegmented(
                    options: ExportAspectContentMode.allCases,
                    isSelected: { $0 == model.exportAspectMode },
                    onTap: { mode in
                        withAnimation(.morphIfAllowed) { model.exportAspectMode = mode }
                    },
                    label: { mode in
                        Text(mode.title)
                            .font(.inspectorSegment)
                            .help(mode.help)
                    }
                )
                .transition(AnyTransition(.blurReplace).combined(with: .move(edge: .top)))
            }
        }
    }

    private func pickWallpaper() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.title = "Choose Video Background Wallpaper"
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            wallpaperStore.addRecentWallpaper(url)
            model.style.background = .customWallpaper(AnnotationCustomWallpaper(url: url))
        }
    }

    private var frameControls: some View {
        VStack(alignment: .leading, spacing: InspectorMetrics.rowSpacing) {
            InspectorFieldPair {
                InspectorSlider(
                    "Padding",
                    value: $model.style.padding,
                    range: 0...0.18,
                    format: .percent()
                )
            } trailing: {
                InspectorSlider(
                    "Corners",
                    value: $model.style.cornerRadius,
                    range: 0...0.08,
                    format: .percent()
                )
            }

            InspectorSlider(
                "Shadow",
                value: $model.style.shadow,
                range: 0...1,
                format: .percent()
            )
        }
    }

    private var cameraControls: some View {
        InspectorFieldPair {
            InspectorSlider(
                "Size",
                value: $model.style.camera.size,
                range: 0.12...0.45,
                format: .percent()
            )
        } trailing: {
            InspectorSlider(
                "Rounding",
                value: $model.style.camera.roundness,
                range: 0.05...0.5,
                format: .percent()
            )
        }
        .help("Drag the camera directly on the canvas to place it")
    }

    // MARK: Motion

    private var zoomControls: some View {
        let pressCount = model.recordedPressTimes.count
        return VStack(alignment: .leading, spacing: InspectorMetrics.rowSpacing) {
            HStack(spacing: InspectorMetrics.rowSpacing) {
                InspectorActionButton("Auto Zoom", systemImage: "pointer.arrow.rays") {
                    withAnimation(.morphIfAllowed) { model.resynthesizeZoomCues() }
                }
                .disabled(pressCount == 0)
                .help(
                    pressCount == 0
                        ? "No clicks were recorded"
                        : "Turn the \(pressCount == 1 ? "recorded click" : "\(pressCount) recorded clicks") into smooth camera moves"
                )

                InspectorActionButton("Add Zoom", systemImage: "plus.magnifyingglass") {
                    withAnimation(.morphIfAllowed) { model.addZoomCue(at: model.currentTime) }
                }
                .help("Add a zoom at the playhead, or drag across the zoom lane")
            }

            if model.zoomCues.isEmpty {
                InspectorHint(
                    pressCount > 0
                        ? "Auto Zoom turns your recorded clicks into camera moves."
                        : "Drag across the zoom lane on the timeline to add a zoom."
                )
                .transition(AnyTransition(.blurReplace))
            } else {
                InspectorHint(
                    model.zoomCues.count == 1
                        ? "1 zoom on the timeline. Click it to fine-tune."
                        : "\(model.zoomCues.count) zooms on the timeline. Click one to fine-tune."
                )
                .contentTransition(.numericText())
                .transition(AnyTransition(.blurReplace))
            }
        }
    }

    private var cursorControls: some View {
        VStack(alignment: .leading, spacing: InspectorMetrics.rowSpacing) {
            InspectorSlider(
                "Size",
                value: $model.style.cursorScale,
                range: 1...4,
                format: .magnification(fractionDigits: 1)
            )

            if model.canShowPressEffects {
                InspectorToggleRow("Click highlights", isOn: $model.showsClickEffects)
            }
        }
    }

    // MARK: Selection

    /// A zoom clicked on the timeline. Its switch turns just this zoom on or
    /// off; going back lets go of the selection and returns to wherever the
    /// panel was, the Zoom page included.
    @ViewBuilder
    private func selectedZoomPage(for selected: ZoomCue) -> some View {
        pageHeader(
            "Zoom",
            systemImage: selected.anchorMode == .pinnedAnchor ? "scope" : "plus.magnifyingglass",
            backTitle: page?.title ?? "Look",
            isOn: Binding(
                get: { selected.isEnabled },
                set: { isEnabled in
                    var updated = selected
                    updated.isEnabled = isEnabled
                    model.updateZoomCue(updated)
                }
            ),
            toggleTitle: "Use this zoom",
            onBack: {
                model.selectedCueID = nil
            }
        ) {
            InspectorIconButton(systemName: "trash", help: "Remove Zoom") {
                withAnimation(.morphIfAllowed) { model.removeZoomCue(id: selected.id) }
            }
        }

        if !model.zoomEnabled {
            pageBody {
                HStack(spacing: InspectorMetrics.rowSpacing) {
                    InspectorHint("Zooms are off for this recording.")
                    Spacer(minLength: 0)
                    Button("Turn On") {
                        withAnimation(.morphIfAllowed) { model.zoomEnabled = true }
                    }
                    .buttonStyle(.plain)
                    .font(.inspectorValue)
                    .foregroundStyle(Palette.label)
                }
            }
        } else {
            pageBody(isActive: selected.isEnabled) {
                selectedZoomControls(for: selected)
            }
        }
    }

    private func selectedZoomControls(for selected: ZoomCue) -> some View {
        VStack(alignment: .leading, spacing: InspectorMetrics.groupSpacing) {
            VStack(alignment: .leading, spacing: InspectorMetrics.groupLabelSpacing) {
                InspectorGroupLabel("Camera focus")

                InspectorSegmented(
                    options: ZoomAnchorMode.allCases,
                    isSelected: { $0 == selected.anchorMode },
                    onTap: { anchorMode in
                        var updated = selected
                        updated.anchorMode = anchorMode
                        if anchorMode == .pinnedAnchor,
                           let pointer = model.pointerLocation(at: model.currentTime) {
                            updated.pinnedPoint = pointer
                        }
                        withAnimation(.morphIfAllowed) { model.updateZoomCue(updated) }
                    },
                    label: { Text($0.inspectorTitle).font(.inspectorSegment) }
                )
            }

            if selected.anchorMode == .pinnedAnchor {
                VStack(alignment: .leading, spacing: InspectorMetrics.rowSpacing) {
                    zoomAmountSlider(for: selected)

                    VStack(alignment: .leading, spacing: InspectorMetrics.groupLabelSpacing) {
                        HStack(spacing: 8) {
                            InspectorGroupLabel("Target position")
                            Spacer(minLength: 0)
                            Text(zoomTargetPositionText(selected.pinnedPoint))
                                .font(.inspectorNumeric)
                                .foregroundStyle(.tertiary)
                        }

                        RecordingZoomFocusPad(
                            position: Binding(
                                get: { selected.pinnedPoint },
                                set: { target in
                                    var updated = selected
                                    updated.pinnedPoint = target
                                    model.updateZoomCue(updated)
                                }
                            ),
                            magnification: selected.zoom
                        )
                    }

                    InspectorActionButton("Target Pointer", systemImage: "scope") {
                        guard let pointer = model.pointerLocation(at: model.currentTime) else { return }
                        var updated = selected
                        updated.pinnedPoint = pointer
                        withAnimation(.morphIfAllowed) { model.updateZoomCue(updated) }
                    }
                    .help("Aim the zoom at the pointer's position under the playhead")
                }
                .transition(AnyTransition(.blurReplace))
            } else {
                InspectorFieldPair {
                    zoomAmountSlider(for: selected)
                } trailing: {
                    InspectorSlider(
                        "Edge",
                        value: Binding(
                            get: { CGFloat(selected.boundsBias) },
                            set: { boundsBias in
                                var updated = selected
                                updated.boundsBias = Double(boundsBias)
                                model.updateZoomCue(updated)
                            }
                        ),
                        range: 0...1,
                        format: .percent()
                    )
                    .help("How much of the frame's edge stays in view while zoomed")
                }
                .transition(AnyTransition(.blurReplace))
            }
        }
    }

    private func zoomAmountSlider(for selected: ZoomCue) -> some View {
        InspectorSlider(
            "Zoom",
            value: Binding(
                get: { CGFloat(selected.zoom) },
                set: { newValue in
                    var updated = selected
                    updated.zoom = Double(newValue)
                    model.updateZoomCue(updated)
                }
            ),
            range: 1.1...3,
            format: .magnification(fractionDigits: 1)
        )
    }

    private func zoomTargetPositionText(_ position: CGPoint) -> String {
        let x = Int((position.x * 100).rounded())
        let y = Int((position.y * 100).rounded())
        return "\(x), \(y)"
    }

    /// The clip under the playhead: its speed, and deleting it.
    @ViewBuilder
    private func selectedClipPage(for clip: RecordingClipSegment) -> some View {
        pageHeader(
            "Clip",
            systemImage: StudioInspectorPage.clip.systemImage,
            onBack: backToLook
        ) {
            if model.canDeleteSelectedClip {
                InspectorIconButton(systemName: "trash", help: "Delete Clip") {
                    withAnimation(.morphIfAllowed) { model.deleteSelectedClip() }
                }
            }
        }

        pageBody {
            VStack(alignment: .leading, spacing: InspectorMetrics.groupLabelSpacing) {
                InspectorGroupLabel("Speed")

                InspectorSegmented(
                    options: RecordingClipSegment.speedPresets,
                    isSelected: { abs($0 - clip.speed) < 0.001 },
                    onTap: { model.setClipSpeed($0, forClipID: clip.id) },
                    label: { speed in
                        Text(RecordingClipSegment.speedTitle(speed))
                            .font(.inspectorSegment)
                    }
                )
                .help("Audio speeds up with the clip")

                if clip.speed > 1.001 {
                    InspectorToggleRow(
                        "Show speed badge",
                        isOn: Binding(
                            get: { model.showsSpeedBadge },
                            set: { value in
                                withAnimation(.morphIfAllowed) { model.showsSpeedBadge = value }
                            }
                        )
                    )
                    .padding(.top, InspectorMetrics.rowSpacing - InspectorMetrics.groupLabelSpacing)
                    .help("Applies to every sped-up clip; place it on the Speed Badge page")
                }
            }
        }
    }

    // MARK: Text

    private var keystrokeControls: some View {
        VStack(alignment: .leading, spacing: InspectorMetrics.rowSpacing) {
            InspectorRow("Top") {
                keystrokePlacementRow([.topLeft, .topCenter, .topRight])
            }
            InspectorRow("Bottom") {
                keystrokePlacementRow([.bottomLeft, .bottomCenter, .bottomRight])
            }
        }
        .help("Shortcuts you pressed while recording appear as a caption")
    }

    private var speedBadgeControls: some View {
        VStack(alignment: .leading, spacing: InspectorMetrics.rowSpacing) {
            InspectorRow("Top") {
                placementRow([.topLeft, .topCenter, .topRight], selection: $model.speedBadgePlacement)
            }
            InspectorRow("Bottom") {
                placementRow([.bottomLeft, .bottomCenter, .bottomRight], selection: $model.speedBadgePlacement)
            }
        }
        .help("Sped-up clips carry a “2× ›››” badge while they play")
    }

    private func placementRow(
        _ options: [RecordingKeystrokePlacement],
        selection: Binding<RecordingKeystrokePlacement>
    ) -> some View {
        InspectorSegmented(
            options: options,
            isSelected: { $0 == selection.wrappedValue },
            onTap: { selection.wrappedValue = $0 },
            label: { Text($0.title).font(.inspectorSegment) }
        )
    }

    private func keystrokePlacementRow(
        _ options: [RecordingKeystrokePlacement]
    ) -> some View {
        InspectorSegmented(
            options: options,
            isSelected: { $0 == model.keystrokePlacement },
            onTap: { model.keystrokePlacement = $0 },
            label: { Text($0.title).font(.inspectorSegment) }
        )
    }

    @ViewBuilder
    private var transcriptionControls: some View {
        VStack(alignment: .leading, spacing: InspectorMetrics.rowSpacing) {
            switch model.transcriptionState {
            case .transcribing:
                InspectorHint("Transcribing narration on this Mac…")
                    .transition(AnyTransition(.blurReplace))
            case .failed(let message):
                InspectorHint(message, tint: .orange)

                InspectorActionButton("Try Again", systemImage: "waveform") {
                    model.transcribe()
                }
            case .idle:
                if model.hasSubtitles {
                    subtitleEditor
                    transcriptionActions
                } else {
                    InspectorActionButton("Transcribe Narration", systemImage: "waveform") {
                        withAnimation(.morphIfAllowed) { model.transcribe() }
                    }
                    .help("Turn your microphone narration into subtitles, transcribed on this Mac")
                }
            }
        }
    }

    private var transcriptionActions: some View {
        HStack(spacing: InspectorMetrics.rowSpacing) {
            if model.canTranscribe {
                InspectorActionButton("Transcribe Again", systemImage: "arrow.clockwise") {
                    withAnimation(.morphIfAllowed) { model.transcribe() }
                }
            }

            InspectorActionButton("Remove", systemImage: "trash", role: .destructive) {
                withAnimation(.morphIfAllowed) { model.removeTranscription() }
            }
            .help("Remove the subtitles")
        }
    }

    private var subtitleEditor: some View {
        VStack(alignment: .leading, spacing: InspectorMetrics.rowSpacing) {
            SegmentedTabs(
                options: [("Captions", .captions), ("Edit Video", .edit)],
                selection: Binding(
                    get: { transcriptTab },
                    set: { tab in
                        withAnimation(.morphQuickIfAllowed) { transcriptTab = tab }
                    }
                )
            )

            ZStack(alignment: .top) {
                switch transcriptTab {
                case .captions:
                    captionControls
                        .transition(AnyTransition(.blurReplace))
                case .edit:
                    transcriptEditControls
                        .transition(AnyTransition(.blurReplace))
                }
            }
        }
    }

    private var captionControls: some View {
        let verticalRange = SubtitleBarStyle.verticalRange
        let fontScaleRange = SubtitleBarStyle.fontScaleRange
        return VStack(alignment: .leading, spacing: InspectorMetrics.rowSpacing) {
            InspectorFieldPair {
                InspectorSlider(
                    "Position",
                    value: Binding(
                        get: { CGFloat(model.subtitleStyle.verticalPosition) },
                        set: { model.subtitleStyle.verticalPosition = Double($0) }
                    ),
                    range: CGFloat(verticalRange.lowerBound)...CGFloat(verticalRange.upperBound),
                    format: .percent()
                )
            } trailing: {
                InspectorSlider(
                    "Size",
                    value: Binding(
                        get: { CGFloat(model.subtitleStyle.fontScale) },
                        set: { model.subtitleStyle.fontScale = Double($0) }
                    ),
                    range: CGFloat(fontScaleRange.lowerBound)...CGFloat(fontScaleRange.upperBound),
                    format: .magnification(fractionDigits: 1)
                )
            }

            if model.hasTranscriptWords {
                InspectorToggleRow(
                    "Highlight spoken word",
                    isOn: $model.subtitleStyle.highlightsSpokenWord
                )
            }

            subtitleList
                .help("Click a timestamp to jump there. Edit any line to fix the transcription.")
        }
    }

    @ViewBuilder
    private var transcriptEditControls: some View {
        VStack(alignment: .leading, spacing: InspectorMetrics.rowSpacing) {
            if model.hasTranscriptWords {
                StudioTranscriptEditPanel(model: model)

                if model.removableFillerWordCount > 0 || model.trimmableSilenceCount > 0 {
                    HStack(spacing: InspectorMetrics.rowSpacing) {
                        if model.removableFillerWordCount > 0 {
                            InspectorActionButton(
                                "Fillers (\(model.removableFillerWordCount))",
                                systemImage: "scissors"
                            ) {
                                withAnimation(.morphIfAllowed) { model.removeFillerWords() }
                            }
                            .help("Cut every filler word, like “um” and “uh”")
                            .transition(.blurPop)
                        }

                        if model.trimmableSilenceCount > 0 {
                            InspectorActionButton(
                                "Silences (\(model.trimmableSilenceCount))",
                                systemImage: "waveform.badge.minus"
                            ) {
                                withAnimation(.morphIfAllowed) { model.trimNarrationSilences() }
                            }
                            .help("Trim long pauses in the narration")
                            .transition(.blurPop)
                        }
                    }
                }

                InspectorHint("Click a word to jump there. Shift-click to select a passage, then cut it.")
            } else {
                InspectorHint("This transcription predates editing by text. Transcribe again to cut the video from its transcript.")
            }
        }
    }

    private var subtitleList: some View {
        let shape = RoundedRectangle(cornerRadius: InspectorMetrics.listRadius, style: .continuous)
        return ScrollViewReader { proxy in
            ScrollView(.vertical) {
                VStack(spacing: 0) {
                    let cues = model.subtitleCues
                    ForEach(Array(cues.enumerated()), id: \.element.id) { index, cue in
                        StudioSubtitleRow(
                            model: model,
                            cue: cue,
                            isActive: model.activeSubtitleCue?.id == cue.id
                        )
                        .id(cue.id)

                        if index < cues.count - 1 {
                            Divider()
                                .padding(.leading, 10)
                                .opacity(0.6)
                        }
                    }
                }
            }
            .frame(maxHeight: 300)
            .background(shape.fill(InspectorControlPalette.trackFill(for: colorScheme)))
            .clipShape(shape)
            .onChange(of: model.activeSubtitleCue?.id) { _, activeID in
                // Follow playback through the list, but never yank the list
                // around while the user is scrubbing or editing.
                guard let activeID, model.isPlaying else { return }
                withAnimation(.easeOut(duration: 0.2)) {
                    proxy.scrollTo(activeID, anchor: .center)
                }
            }
        }
    }

    // MARK: Audio

    /// The round trip around tools that clean up speech but offer no API:
    /// write the cut's soundtrack out, run it through the tool, bring the
    /// result back in as the project's audio. Two buttons and a file chip -
    /// the explaining is left to tooltips.
    private var audioControls: some View {
        VStack(alignment: .leading, spacing: InspectorMetrics.rowSpacing) {
            // A silent recording has nothing to send out, but it can still
            // be given a soundtrack - so only the export half is withheld.
            if model.hasAudio {
                InspectorSlider("Volume", value: $model.audioVolume, range: 0...2, format: .percent())
            }

            HStack(spacing: InspectorMetrics.rowSpacing) {
                if model.hasAudio {
                    audioExportButton
                }

                InspectorActionButton(
                    model.hasRecordedAudio ? "Replace" : "Add",
                    systemImage: "waveform.badge.plus"
                ) {
                    pickReplacementAudio()
                }
                .help(
                    model.hasRecordedAudio
                        ? "Swap in an audio file, aligned to the start of the edited timeline"
                        : "Lay an audio file over this silent recording"
                )
            }

            if let replacement = model.replacementAudio {
                replacementChip(for: replacement)
                    .transition(.blurPop)
            }

            if let message = model.replacementAudioError {
                InspectorHint(message, tint: .orange)
                    .transition(AnyTransition(.blurReplace))
            }
        }
        .motion(.morph, value: model.replacementAudio?.displayName)
    }

    /// One button carrying the whole export state, so progress and results
    /// never cost the section an extra row. The format is asked for at export
    /// time, the same way video export asks for its options.
    @ViewBuilder
    private var audioExportButton: some View {
        Group {
            switch model.audioExportState {
            case .idle:
                InspectorActionButton("Export…", systemImage: "arrow.down.circle") {
                    isAudioExportOptionsPresented = true
                }
                .help("Export just the soundtrack of the current cut")
                .popover(isPresented: $isAudioExportOptionsPresented, arrowEdge: .bottom) {
                    StudioAudioExportOptions(format: $model.audioExportFormat) {
                        isAudioExportOptionsPresented = false
                        model.exportAudio()
                    }
                }
            case .exporting(let progress):
                audioExportChrome(help: "Cancel") {
                    model.cancelAudioExport()
                } label: {
                    StudioProgressRing(progress: progress, size: 12)
                    Text("\(Int((progress * 100).rounded()))%")
                        .font(.inspectorValue.monospacedDigit())
                        .contentTransition(.numericText())
                }
            case .finished(let url):
                audioExportChrome(help: "Reveal \(url.lastPathComponent) in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                } label: {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.green)
                    Text("Reveal")
                        .font(.inspectorValue)
                }
            case .failed(let message):
                audioExportChrome(help: message) {
                    model.exportAudio()
                } label: {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.orange)
                    Text("Retry")
                        .font(.inspectorValue)
                }
            }
        }
        .transition(AnyTransition(.blurReplace))
        .motion(.morphQuick, value: model.audioExportState.phase)
    }

    /// Matches `InspectorActionButton`'s chrome for the export button's
    /// non-idle states, which carry richer content than a symbol and a title.
    private func audioExportChrome<Label: View>(
        help: String,
        action: @escaping () -> Void,
        @ViewBuilder label: () -> Label
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                label()
            }
            .lineLimit(1)
            .frame(maxWidth: .infinity)
            .inspectorField()
        }
        .buttonStyle(.plain)
        .help(help)
    }

    private func replacementChip(for replacement: RecordingReplacementAudio) -> some View {
        HStack(spacing: 7) {
            Image(systemName: "waveform")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Palette.highlight)

            Text(replacement.displayName)
                .font(.inspectorValue)
                .lineLimit(1)
                .truncationMode(.middle)

            Spacer(minLength: 4)

            if let drift = model.replacementAudioDrift {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.orange)
                    .help(
                        drift > 0
                            ? "Runs \(Self.spanText(drift)) longer than the cut - the tail is dropped"
                            : "Runs \(Self.spanText(-drift)) shorter than the cut - the end plays silent"
                    )
            }

            Text(Self.clockText(replacement.duration))
                .font(.inspectorLabel.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .inspectorField()
        .help(replacement.displayName)
    }

    private func pickReplacementAudio() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = RecordingAudioFormat.importContentTypes
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.title = "Choose Replacement Audio"
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            model.replaceAudio(with: url)
        }
    }

    private static func clockText(_ seconds: TimeInterval) -> String {
        let total = Int(max(0, seconds).rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    /// Short spans read better in seconds than as 0:00 timecode.
    private static func spanText(_ seconds: TimeInterval) -> String {
        let value = max(0, seconds)
        return value < 60 ? String(format: "%.1fs", value) : clockText(value)
    }

    // MARK: Helpers

    private var usesDefaultLayout: Bool {
        abs(model.style.padding - 0.06) < 0.0001
            && abs(model.style.cornerRadius - 0.02) < 0.0001
            && abs(model.style.shadow - 0.45) < 0.0001
    }

    private var sidebarBackground: Color {
        InspectorControlPalette.panelBackground(for: colorScheme)
    }
}

private extension RecordingStudioExportState {
    /// The state's kind without its payload, so progress ticks don't count
    /// as a change of state.
    var phase: Int {
        switch self {
        case .idle: 0
        case .exporting: 1
        case .finished: 2
        case .failed: 3
        }
    }
}


// MARK: - Transcript

/// One editable subtitle line: a timestamp plus the cue text as a free-form
/// field. Hovering a row skims the preview to that cue, clicking or editing
/// commits the playhead there (paused), and the row under the playhead is
/// highlighted so the list follows the video.
private struct StudioSubtitleRow: View {
    @Bindable var model: RecordingStudioModel
    let cue: RecordingSubtitleCue
    let isActive: Bool

    @FocusState private var isEditing: Bool

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Button {
                model.seekToSubtitle(cue)
            } label: {
                Text(timestamp ?? "–:––")
                    .font(.system(size: 10.5, weight: .medium).monospacedDigit())
                    .foregroundStyle(isActive ? Palette.highlight : .secondary)
            }
            .buttonStyle(.plain)
            .disabled(editorTime == nil)
            .help(editorTime == nil ? "This subtitle's audio was cut out" : "Jump to this subtitle")

            TextField(
                "Subtitle",
                text: Binding(
                    get: { cue.text },
                    set: { model.updateSubtitleText(id: cue.id, text: $0) }
                ),
                axis: .vertical
            )
            .textFieldStyle(.plain)
            .font(.inspectorValue)
            .focused($isEditing)
            .onChange(of: isEditing) { _, editing in
                // Starting to edit parks the paused preview on this cue so
                // the correction is visible in context while typing.
                if editing {
                    model.seekToSubtitle(cue)
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(isActive ? Palette.highlight.opacity(0.14) : .clear)
        .contentShape(Rectangle())
        .opacity(editorTime == nil ? 0.5 : 1)
        .onTapGesture {
            model.seekToSubtitle(cue)
        }
        .onHover { hovering in
            // Hover skims the paused preview like the timeline strip does;
            // leaving hands the frame back to the real playhead.
            guard !model.isPlaying, let editorTime else { return }
            if hovering {
                model.hoverPreviewTime = editorTime
            } else if model.hoverPreviewTime == editorTime {
                model.hoverPreviewTime = nil
            }
        }
    }

    /// Where this cue lands on the edited timeline; nil when its audio was
    /// cut out entirely.
    private var editorTime: TimeInterval? {
        model.editorTime(forSourceTime: cue.start)
            ?? model.editorTime(forSourceTime: (cue.start + cue.end) / 2)
    }

    private var timestamp: String? {
        guard let editorTime else { return nil }
        let total = max(0, Int(editorTime.rounded()))
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

/// Descript-style transcript editing: the narration as flowing words.
/// Clicking a word jumps the playhead there, shift-clicking selects a
/// passage, and cutting the selection removes that stretch of the video.
/// Words whose footage is already cut render struck-through; filler words
/// carry a dotted underline so the bulk action's targets are visible.
private struct StudioTranscriptEditPanel: View {
    @Bindable var model: RecordingStudioModel

    @State private var selection: ClosedRange<Int>?
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(alignment: .leading, spacing: InspectorMetrics.rowSpacing) {
            ScrollViewReader { proxy in
                ScrollView(.vertical) {
                    transcriptFlow
                        .padding(8)
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                }
                .frame(maxHeight: 260)
                .background(
                    RoundedRectangle(cornerRadius: InspectorMetrics.listRadius, style: .continuous)
                        .fill(InspectorControlPalette.trackFill(for: colorScheme))
                )
                .clipShape(RoundedRectangle(cornerRadius: InspectorMetrics.listRadius, style: .continuous))
                .onChange(of: model.activeTranscriptWordIndex) { _, activeIndex in
                    // Follow playback through the transcript, but never yank
                    // it around while the user is selecting a passage.
                    guard let activeIndex, model.isPlaying, selection == nil else { return }
                    withAnimation(.easeOut(duration: 0.2)) {
                        proxy.scrollTo(activeIndex, anchor: .center)
                    }
                }
            }

            if let selection {
                cutSelectionRow(selection)
            }
        }
        .onDeleteCommand(perform: cutSelection)
        .onExitCommand { selection = nil }
    }

    private var transcriptFlow: some View {
        let activeIndex = model.activeTranscriptWordIndex
        return TranscriptFlowLayout() {
            ForEach(model.transcriptWords.indices, id: \.self) { index in
                StudioTranscriptWordView(
                    text: model.transcriptWords[index].displayText,
                    isSelected: selection?.contains(index) ?? false,
                    isActive: index == activeIndex,
                    isCut: !model.transcriptWordSurvives(index),
                    isFiller: model.isFillerWord(index)
                ) {
                    handleTap(on: index)
                }
                .id(index)
            }
        }
    }

    private func cutSelectionRow(_ selection: ClosedRange<Int>) -> some View {
        HStack(spacing: 6) {
            InspectorActionButton(
                selection.count == 1 ? "Cut Word" : "Cut \(selection.count) Words",
                systemImage: "scissors",
                role: .destructive,
                action: cutSelection
            )

            InspectorClearButton(help: "Clear selection") {
                self.selection = nil
            }
        }
    }

    private func handleTap(on index: Int) {
        let shiftHeld = NSApp.currentEvent?.modifierFlags.contains(.shift) ?? false
        if shiftHeld, let selection {
            self.selection = min(selection.lowerBound, index)...max(selection.upperBound, index)
        } else {
            selection = index...index
            model.seekToTranscriptWord(at: index)
        }
    }

    private func cutSelection() {
        guard let selection else { return }
        model.cutTranscriptWords(in: selection)
        self.selection = nil
    }
}

/// One word in the transcript editor, drawn so the flow reads as a plain
/// paragraph: the chip's side padding doubles as the inter-word space
/// (layout spacing is zero), which also makes a multi-word selection's
/// highlight contiguous like real text selection. The font weight never
/// changes with state - a width change would reflow the whole paragraph
/// on every playback tick. Kept to plain stored values so ticks only
/// re-render the words whose state actually changed.
private struct StudioTranscriptWordView: View {
    let text: String
    let isSelected: Bool
    let isActive: Bool
    let isCut: Bool
    let isFiller: Bool
    let action: () -> Void

    var body: some View {
        Text(text)
            .font(.system(size: 11.5))
            .foregroundStyle(foreground)
            .strikethrough(isCut, color: .secondary.opacity(0.6))
            .padding(.horizontal, 1.5)
            .padding(.vertical, 1)
            .background(
                RoundedRectangle(cornerRadius: 2, style: .continuous)
                    .fill(background)
            )
            .contentShape(Rectangle())
            .onTapGesture(perform: action)
    }

    private var foreground: Color {
        isCut ? Color.secondary.opacity(0.45) : Color.primary
    }

    private var background: Color {
        if isSelected {
            Palette.highlight.opacity(isCut ? 0.12 : 0.24)
        } else if isActive, !isCut {
            Palette.highlight.opacity(0.2)
        } else if isFiller, !isCut {
            Color.orange.opacity(0.16)
        } else {
            Color.clear
        }
    }
}

/// Minimal left-aligned wrapping layout for the transcript's word chips.
/// Horizontal spacing lives inside the chips (see StudioTranscriptWordView),
/// so the layout only separates lines.
private struct TranscriptFlowLayout: Layout {
    var spacingX: CGFloat = 0
    var spacingY: CGFloat = 3

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 240
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width {
                x = 0
                y += rowHeight + spacingY
                rowHeight = 0
            }
            x += size.width + spacingX
            rowHeight = max(rowHeight, size.height)
        }
        return CGSize(width: width, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX
        var y = bounds.minY
        var rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX {
                x = bounds.minX
                y += rowHeight + spacingY
                rowHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacingX
            rowHeight = max(rowHeight, size.height)
        }
    }
}

// MARK: - Audio export options

/// Asks for the soundtrack format at export time.
private struct StudioAudioExportOptions: View {
    @Binding var format: RecordingAudioFormat
    let onExport: () -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        InspectorPopover(
            title: "Export Audio",
            confirmTitle: "Export",
            width: 260,
            onCancel: { dismiss() },
            onConfirm: onExport
        ) {
            VStack(alignment: .leading, spacing: InspectorMetrics.rowSpacing) {
                InspectorSegmented(
                    options: RecordingAudioFormat.allCases,
                    isSelected: { $0 == format },
                    onTap: { format = $0 },
                    label: { Text($0.title).font(.inspectorSegment) }
                )

                InspectorHint(
                    format == .m4a
                        ? "Compact AAC audio, accepted by most enhancement tools."
                        : "Uncompressed, for tools that accept nothing else."
                )
            }
        }
    }
}
