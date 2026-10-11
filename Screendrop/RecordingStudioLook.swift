//
//  RecordingStudioLook.swift
//  Screendrop
//
//  The pieces of Studio's Look page: the Styles strip, whose tiles are
//  drawn from the recording’s own frame, and the one-line background row that
//  opens the full picker, previewing a fill on the video while the pointer
//  rests on it.
//

import AppKit
import AVFoundation
import SwiftUI

extension AnnotationBackgroundStyle {
    var displayTitle: String {
        switch self {
        case .none: "None"
        case .solid(let color): color.title
        case .gradient(let gradient): gradient.title
        case .customWallpaper(let wallpaper): wallpaper.title
        }
    }
}

/// A background drawn small: the fill itself, or a quiet empty well for none.
struct StudioBackgroundSwatch: View {
    let style: AnnotationBackgroundStyle

    var body: some View {
        switch style {
        case .none:
            Rectangle()
                .fill(Color.primary.opacity(0.06))
                .overlay {
                    Image(systemName: "slash.circle")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(.tertiary)
                }
        case .solid(let color):
            Rectangle().fill(color.color)
        case .gradient(let gradient):
            Rectangle().fill(LinearGradient(
                colors: gradient.colors.map(\.color),
                startPoint: gradient.startPoint,
                endPoint: gradient.endPoint
            ))
        case .customWallpaper(let wallpaper):
            AnnotationCustomWallpaperPreview(wallpaper: wallpaper, maxPixelSize: 320)
        }
    }
}

// MARK: - Background

/// The background as one row: its swatch and name. The full picker opens
/// beside the inspector, over the canvas, so hovering a fill shows it on
/// the video right there.
struct StudioBackgroundRow: View {
    @Bindable var model: RecordingStudioModel
    @Bindable var wallpaperStore: AnnotationWallpaperStore
    let onPickWallpaper: () -> Void

    @State private var isPickerPresented = false
    @State private var isHovering = false

    var body: some View {
        Button {
            isPickerPresented = true
        } label: {
            HStack(spacing: 8) {
                StudioBackgroundSwatch(style: model.style.background)
                    .frame(width: 26, height: 18)
                    .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.5)
                    }

                Text(model.style.background.displayTitle)
                    .font(.inspectorValue)
                    .foregroundStyle(.primary.opacity(0.85))
                    .lineLimit(1)
                    .truncationMode(.middle)

                Spacer(minLength: 4)

                Image(systemName: "chevron.right")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(.leading, 7)
            .padding(.trailing, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .inspectorField()
            .overlay {
                if isHovering || isPickerPresented {
                    RoundedRectangle(cornerRadius: InspectorMetrics.fieldRadius, style: .continuous)
                        .fill(InspectorControlPalette.hoverFill)
                }
            }
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .help("Choose a background")
        .accessibilityLabel("Background")
        .accessibilityValue(model.style.background.displayTitle)
        .popover(isPresented: $isPickerPresented, arrowEdge: .leading) {
            StudioBackgroundPicker(
                model: model,
                wallpaperStore: wallpaperStore,
                onPickWallpaper: {
                    isPickerPresented = false
                    onPickWallpaper()
                }
            )
        }
    }
}

/// Every fill in one scrolling popover. Hovering previews on the video;
/// clicking keeps it; closing without a click leaves the background as it
/// was.
private struct StudioBackgroundPicker: View {
    @Bindable var model: RecordingStudioModel
    @Bindable var wallpaperStore: AnnotationWallpaperStore
    let onPickWallpaper: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text("Background")
                    .font(.system(size: 13, weight: .semibold))
                Spacer(minLength: 0)
                if model.style.background != .none {
                    Button("None") {
                        withAnimation(.morphQuickIfAllowed) { model.style.background = .none }
                    }
                    .buttonStyle(.plain)
                    .font(.inspectorValue)
                    .foregroundStyle(.secondary)
                    .onHover { model.previewBackground(.none, isHovering: $0) }
                    .help("Remove the background")
                }
            }
            .padding(.horizontal, 14)
            .frame(height: 44)

            ScrollView(.vertical) {
                InspectorBackgroundFillPicker(
                    style: $model.style.background,
                    rememberedWallpaper: nil,
                    wallpaperStore: wallpaperStore,
                    onEditorAction: {},
                    onPickWallpaper: onPickWallpaper,
                    stacked: true,
                    onPreview: { style, isHovering in
                        model.previewBackground(style, isHovering: isHovering)
                    }
                )
                .padding(.horizontal, 14)
                .padding(.bottom, 14)
            }
            .scrollEdgeEffectSoftIfAvailable()
        }
        .frame(width: 320, height: 520)
        .background(Palette.panel)
        .presentationBackground(Palette.panel)
        .onDisappear { model.previewBackground = nil }
    }
}

// MARK: - Styles

/// Saved looks as thumbnails of this recording wearing them. Clicking one
/// applies it; the last tile saves the current look.
struct RecordingStudioStyleStrip: View {
    @Bindable var model: RecordingStudioModel
    @Bindable var presetStore: RecordingStudioStylePresetStore

    @State private var poster: CGImage?
    @State private var isNameEditorPresented = false
    @State private var draftName = ""
    @State private var presetPendingDeletion: RecordingStudioStylePreset?
    @FocusState private var isNameFieldFocused: Bool

    private static let tileWidth: CGFloat = 78
    private static let tileAspect: CGFloat = 1.5

    var body: some View {
        VStack(alignment: .leading, spacing: InspectorMetrics.groupLabelSpacing) {
            HStack(spacing: 6) {
                Text("Styles")
                    .font(.inspectorSectionHeader)
                    .foregroundStyle(Palette.label.opacity(0.95))
                Spacer(minLength: 0)
            }
            .frame(minHeight: 24)
            .padding(.horizontal, InspectorMetrics.horizontalPadding)

            ScrollView(.horizontal) {
                HStack(alignment: .top, spacing: 6) {
                    ForEach(presetStore.presets) { preset in
                        tile(for: preset)
                    }
                    addTile
                }
                .padding(.horizontal, InspectorMetrics.horizontalPadding - 2.5)
            }
            .scrollIndicators(.never)
        }
        .padding(.top, InspectorMetrics.sectionVerticalPadding / 2 + 3)
        .padding(.bottom, 4)
        .task(id: model.screenURL) {
            poster = await Self.poster(for: model.screenURL)
        }
        .alert(
            "Delete Style?",
            isPresented: Binding(
                get: { presetPendingDeletion != nil },
                set: { if !$0 { presetPendingDeletion = nil } }
            ),
            presenting: presetPendingDeletion
        ) { preset in
            Button("Delete", role: .destructive) {
                presetStore.deletePreset(id: preset.id)
                if model.appliedStylePresetID == preset.id {
                    model.appliedStylePresetID = nil
                }
                presetPendingDeletion = nil
            }
            Button("Cancel", role: .cancel) {
                presetPendingDeletion = nil
            }
        } message: { preset in
            Text("“\(preset.name)” will be removed from your styles. This recording won’t change.")
        }
    }

    private func tile(for preset: RecordingStudioStylePreset) -> some View {
        let isApplied = model.appliedStylePresetID == preset.id && preset.matches(model.style)
        let isDefault = presetStore.activePreset?.id == preset.id
        let isMissing = preset.hasMissingWallpaper
        return VStack(spacing: 4) {
            InspectorTile(title: preset.name, aspectRatio: Self.tileAspect, isSelected: isApplied) {
                guard !isMissing else {
                    presetPendingDeletion = preset
                    return
                }
                withAnimation(.morphIfAllowed) { model.applyStylePreset(preset) }
            } content: {
                StudioStylePreview(
                    style: preset.value,
                    poster: poster,
                    contentAspect: model.sourceVideoAspect,
                    showsCamera: model.hasCameraVideo
                )
                .overlay {
                    if isMissing {
                        Color.black.opacity(0.45)
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.white)
                    }
                }
            }

            HStack(spacing: 3) {
                if isDefault {
                    Circle()
                        .fill(Palette.label)
                        .frame(width: 4, height: 4)
                        .help("Used for new recordings")
                }
                Text(preset.name)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .font(.system(size: 10, weight: isApplied ? .semibold : .regular))
            .foregroundStyle(isApplied ? Palette.label : Palette.secondaryLabel)
            .padding(.horizontal, 2)
        }
        .frame(width: Self.tileWidth)
        .help(isMissing ? "\(preset.name)’s wallpaper can’t be found" : preset.name)
        .contextMenu {
            if !isMissing {
                Button(isDefault ? "Stop Using for New Recordings" : "Use for New Recordings") {
                    presetStore.setActivePreset(id: isDefault ? nil : preset.id)
                }
                Divider()
            }
            Button("Delete…", role: .destructive) {
                presetPendingDeletion = preset
            }
        }
    }

    private var addTile: some View {
        VStack(spacing: 4) {
            Button {
                draftName = ""
                isNameEditorPresented = true
            } label: {
                RoundedRectangle(cornerRadius: InspectorMetrics.tileRadius, style: .continuous)
                    .strokeBorder(style: StrokeStyle(lineWidth: 1.2, dash: [4, 3]))
                    .foregroundStyle(.quaternary)
                    .aspectRatio(Self.tileAspect, contentMode: .fit)
                    .overlay {
                        Image(systemName: "plus")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.tertiary)
                    }
                    .padding(2.5)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Save this look as a style")
            .accessibilityLabel("Save Style")
            .popover(isPresented: $isNameEditorPresented, arrowEdge: .bottom) {
                nameEditor
            }

            Text(presetStore.presets.isEmpty ? "Save Look" : "Save")
                .font(.system(size: 10))
                .foregroundStyle(Palette.tertiaryLabel)
        }
        .frame(width: Self.tileWidth)
    }

    // MARK: Saving

    private var duplicateNamePreset: RecordingStudioStylePreset? {
        presetStore.preset(named: draftName)
    }

    private var canSaveName: Bool {
        !RecordingStudioStylePresetStore.normalizedName(draftName).isEmpty
            && duplicateNamePreset == nil
            && !model.style.hasMissingCustomWallpaper
    }

    private var nameEditor: some View {
        InspectorPopover(
            title: "New Style",
            message: "Saves the background, frame, cursor size and camera. New recordings start with it.",
            confirmTitle: "Save",
            isConfirmDisabled: !canSaveName,
            width: 292,
            onCancel: { isNameEditorPresented = false },
            onConfirm: savePreset
        ) {
            VStack(alignment: .leading, spacing: 6) {
                TextField("Style name", text: $draftName)
                    .inspectorTextField()
                    .focused($isNameFieldFocused)
                    .onSubmit(savePreset)
                    .onChange(of: draftName) { _, newValue in
                        let limitedName = String(
                            newValue.prefix(RecordingStudioStylePresetStore.maximumNameLength)
                        )
                        if limitedName != newValue {
                            draftName = limitedName
                        }
                    }

                if model.style.hasMissingCustomWallpaper {
                    Label(
                        "The selected wallpaper can’t be found. Choose it again before saving.",
                        systemImage: "exclamationmark.triangle.fill"
                    )
                    .font(.inspectorLabel)
                    .foregroundStyle(Palette.record)
                } else if duplicateNamePreset != nil {
                    Label(
                        "A style with this name already exists.",
                        systemImage: "exclamationmark.circle.fill"
                    )
                    .font(.inspectorLabel)
                    .foregroundStyle(Palette.record)
                }
            }
        }
        .onAppear {
            Task { @MainActor in
                isNameFieldFocused = true
            }
        }
    }

    private func savePreset() {
        guard canSaveName,
              let preset = presetStore.savePreset(named: draftName, style: model.style) else {
            return
        }
        model.appliedStylePresetID = preset.id
        presetStore.setActivePreset(id: preset.id)
        isNameEditorPresented = false
    }

    /// One small frame from early in the recording, for the thumbnails.
    nonisolated private static func poster(for url: URL) async -> CGImage? {
        let asset = AVURLAsset(url: url)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 360, height: 360)
        let duration = (try? await asset.load(.duration))?.seconds ?? 0
        let seconds = duration.isFinite ? min(1, duration / 2) : 0
        return try? await generator.image(at: CMTime(seconds: seconds, preferredTimescale: 600)).image
    }
}

/// A style drawn the way the canvas lays it out: the background, the
/// recording inset by the style's padding with its corners and shadow, and
/// the camera bubble where it sits.
struct StudioStylePreview: View {
    let style: RecordingStudioStyle
    let poster: CGImage?
    let contentAspect: CGFloat
    var showsCamera = false

    var body: some View {
        GeometryReader { proxy in
            let size = proxy.size
            let short = min(size.width, size.height)
            let inset = style.background == .none ? 0 : style.padding * short
            let available = CGSize(
                width: max(1, size.width - inset * 2),
                height: max(1, size.height - inset * 2)
            )
            let aspect = max(0.1, contentAspect)
            let card = available.width / available.height > aspect
                ? CGSize(width: available.height * aspect, height: available.height)
                : CGSize(width: available.width, height: available.width / aspect)

            ZStack {
                StudioBackgroundSwatch(style: style.background)

                Group {
                    if let poster {
                        Image(decorative: poster, scale: 1)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                    } else {
                        Color(white: 0.16)
                    }
                }
                .frame(width: card.width, height: card.height)
                .clipShape(RoundedRectangle(cornerRadius: style.cornerRadius * short, style: .continuous))
                .shadow(
                    color: .black.opacity(style.background == .none ? 0 : 0.5 * style.shadow),
                    radius: short * 0.05 * style.shadow,
                    y: short * 0.02 * style.shadow
                )

                if showsCamera, style.camera.isVisible {
                    let diameter = style.camera.size * short
                    RoundedRectangle(cornerRadius: diameter * style.camera.roundness, style: .continuous)
                        .fill(Color(white: 0.78))
                        .overlay {
                            Image(systemName: "person.fill")
                                .font(.system(size: diameter * 0.45))
                                .foregroundStyle(Color(white: 0.55))
                        }
                        .frame(width: diameter, height: diameter)
                        .clipShape(RoundedRectangle(cornerRadius: diameter * style.camera.roundness, style: .continuous))
                        .position(x: style.camera.center.x * size.width, y: style.camera.center.y * size.height)
                }
            }
            .frame(width: size.width, height: size.height)
        }
    }
}
