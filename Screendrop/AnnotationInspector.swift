//
//  AnnotationInspector.swift
//  Screendrop
//

import AppKit
import SwiftUI

// MARK: - Inspector

enum AnnotationEditorFocusedField: Hashable {
    case watermarkText
}

/// Sections that fold with a chevron rather than a feature switch.
private enum AnnotationInspectorAdvancedSection: String, Hashable, CaseIterable {
    case camera
}

private enum AnnotationInspectorSectionState {
    static let expandedSectionsKey = "annotationInspector.expandedAdvancedSections"

    static func loadExpandedSections() -> Set<AnnotationInspectorAdvancedSection> {
        let rawValues = UserDefaults.standard.stringArray(forKey: expandedSectionsKey) ?? []
        return Set(rawValues.compactMap(AnnotationInspectorAdvancedSection.init(rawValue:)))
    }

    static func saveExpandedSections(_ sections: Set<AnnotationInspectorAdvancedSection>) {
        UserDefaults.standard.set(sections.map(\.rawValue), forKey: expandedSectionsKey)
    }
}

struct AnnotationEditorInspector: View {
    @Bindable var model: AnnotationEditorModel
    @Bindable var wallpaperStore: AnnotationWallpaperStore
    @Bindable var backgroundPresetStore: AnnotationBackgroundPresetStore
    let focusedField: FocusState<AnnotationEditorFocusedField?>.Binding
    let onEditorAction: () -> Void
    let onPickWallpaper: () -> Void
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var accessibilityReduceMotion
    @State private var expandedAdvancedSections: Set<AnnotationInspectorAdvancedSection> = AnnotationInspectorSectionState.loadExpandedSections()

    var body: some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 0) {
                InspectorSection("Tools") {
                    AnnotationInspectorToolGrid(selectedTool: model.selectedTool) { tool in
                        onEditorAction()
                        model.selectTool(tool)
                    }

                    smartRedactionRow
                }

                // Always present so selecting or deselecting annotations never
                // shifts the sections below.
                InspectorSection("Style") {
                    styleControls
                }

                InspectorGroupBreak()

                InspectorSection(
                    "Background",
                    accessory: {
                        if model.backgroundSettings.style != .none {
                            InspectorClearButton(help: "Remove background") {
                                onEditorAction()
                                withAnimation(.morphQuick) {
                                    model.backgroundSettings.style = .none
                                }
                            }
                            .transition(.blurPop)
                        }
                    }
                ) {
                    AnnotationBackgroundInspector(
                        settings: Binding(
                            get: { model.backgroundSettings },
                            set: { model.backgroundSettings = $0 }
                        ),
                        wallpaperStore: wallpaperStore,
                        onEditorAction: onEditorAction,
                        onPickWallpaper: onPickWallpaper
                    )
                }

                InspectorSection(
                    "Border",
                    summary: AnnotationInspectorSummary.border(model.backgroundSettings.border),
                    isOn: featureBinding(\.border.isEnabled),
                    toggleTitle: "Enable border",
                    accessory: {
                        if model.backgroundSettings.border != AnnotationScreenshotBorderSettings(),
                           model.backgroundSettings.border.isEnabled {
                            sectionResetButton("Reset border") {
                                var border = AnnotationScreenshotBorderSettings()
                                border.isEnabled = true
                                model.backgroundSettings.border = border
                            }
                        }
                    }
                ) {
                    AnnotationScreenshotBorderInspector(
                        settings: Binding(
                            get: { model.backgroundSettings.border },
                            set: { model.backgroundSettings.border = $0 }
                        ),
                        onEditorAction: onEditorAction
                    )
                }

                InspectorGroupBreak()

                InspectorSection(
                    "Camera",
                    summary: AnnotationInspectorSummary.camera(model.backgroundSettings.camera),
                    isExpanded: expansionBinding(for: .camera),
                    accessory: {
                        if !model.backgroundSettings.camera.isDefault {
                            InspectorResetButton(help: "Reset camera") {
                                onEditorAction()
                                withAnimation(.morph) {
                                    model.backgroundSettings.camera = AnnotationCameraSettings()
                                }
                            }
                            .transition(.blurPop)
                        }
                    }
                ) {
                    AnnotationCameraInspector(
                        settings: Binding(
                            get: { model.backgroundSettings.camera },
                            set: { model.backgroundSettings.camera = $0 }
                        ),
                        onEditorAction: onEditorAction
                    )
                }

                InspectorSection(
                    "Progressive Blur",
                    summary: AnnotationInspectorSummary.progressiveBlur(model.backgroundSettings.progressiveBlur),
                    isOn: featureBinding(\.progressiveBlur.isEnabled),
                    toggleTitle: "Enable progressive blur",
                    accessory: {
                        if model.backgroundSettings.progressiveBlur != AnnotationProgressiveBlurSettings(),
                           model.backgroundSettings.progressiveBlur.isEnabled {
                            sectionResetButton("Reset progressive blur") {
                                var blur = AnnotationProgressiveBlurSettings()
                                blur.isEnabled = true
                                model.backgroundSettings.progressiveBlur = blur
                            }
                        }
                    }
                ) {
                    AnnotationProgressiveBlurInspector(
                        settings: Binding(
                            get: { model.backgroundSettings.progressiveBlur },
                            set: { model.backgroundSettings.progressiveBlur = $0 }
                        ),
                        onEditorAction: onEditorAction
                    )
                }

                InspectorGroupBreak()

                InspectorSection(
                    "Watermark",
                    summary: AnnotationInspectorSummary.watermark(model.backgroundSettings.watermark),
                    isOn: featureBinding(\.watermark.isEnabled),
                    toggleTitle: "Enable watermark",
                    accessory: {
                        if model.backgroundSettings.watermark != AnnotationWatermarkSettings(),
                           model.backgroundSettings.watermark.isEnabled {
                            sectionResetButton("Reset watermark") {
                                var watermark = AnnotationWatermarkSettings()
                                watermark.isEnabled = true
                                model.backgroundSettings.watermark = watermark
                            }
                        }
                    }
                ) {
                    AnnotationWatermarkInspector(
                        settings: Binding(
                            get: { model.backgroundSettings.watermark },
                            set: { model.backgroundSettings.watermark = $0 }
                        ),
                        focusedField: focusedField,
                        onFocusCleared: onEditorAction
                    )
                }
            }
            .frame(maxWidth: .infinity, alignment: .topLeading)
            // Reserve clearance so the final inspector controls are never
            // hidden behind the floating preview peek pill.
            .padding(.bottom, PreviewPeekTab.pillHeight * 1.1)
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            VStack(spacing: 0) {
                AnnotationBackgroundPresetBar(
                    model: model,
                    presetStore: backgroundPresetStore,
                    onEditorAction: onEditorAction
                )

                Rectangle()
                    .fill(Color(nsColor: .separatorColor).opacity(0.45))
                    .frame(height: 0.5)
            }
            .background(sidebarBackground)
        }
        .scrollContentBackground(.hidden)
        .scrollEdgeEffectSoftIfAvailable()
        .background(sidebarBackground)
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
    }

    private var sidebarBackground: Color {
        colorScheme == .dark ? Color(nsColor: .windowBackgroundColor) : .white
    }

    private func expansionBinding(
        for section: AnnotationInspectorAdvancedSection
    ) -> Binding<Bool> {
        Binding(
            get: { expandedAdvancedSections.contains(section) },
            set: { isExpanded in
                if isExpanded {
                    expandedAdvancedSections.insert(section)
                } else {
                    expandedAdvancedSections.remove(section)
                }
                AnnotationInspectorSectionState.saveExpandedSections(expandedAdvancedSections)
            }
        )
    }

    /// A feature switch in a section header. The section folds with it.
    private func featureBinding(
        _ keyPath: WritableKeyPath<AnnotationBackgroundSettings, Bool>
    ) -> Binding<Bool> {
        Binding(
            get: { model.backgroundSettings[keyPath: keyPath] },
            set: { value in
                onEditorAction()
                model.backgroundSettings[keyPath: keyPath] = value
            }
        )
    }

    /// Restores a switched-on feature's defaults without switching it off.
    private func sectionResetButton(_ help: String, reset: @escaping () -> Void) -> some View {
        InspectorResetButton(help: help) {
            onEditorAction()
            withAnimation(.morph) { reset() }
        }
        .transition(.blurPop)
    }

    // MARK: Tools & style

    private var smartRedactionRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            InspectorRow("Redact") {
                HStack(spacing: 6) {
                    InspectorActionButton(
                        "Pixelate",
                        systemImage: "app.background.dotted",
                        isBusy: model.isSmartRedacting
                    ) {
                        onEditorAction()
                        model.smartRedact(using: .pixelate)
                    }
                    .help("Find sensitive content and pixelate it")

                    InspectorActionButton(
                        "Blur",
                        systemImage: "drop.fill",
                        isBusy: model.isSmartRedacting
                    ) {
                        onEditorAction()
                        model.smartRedact(using: .blur)
                    }
                    .help("Find sensitive content and blur it")
                }
            }

            if model.isSmartRedacting {
                HStack(spacing: 6) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Scanning screenshot…")
                        .font(.inspectorLabel)
                        .foregroundStyle(.secondary)
                }
            } else if let message = model.smartRedactionMessage {
                Text(message)
                    .font(.inspectorLabel)
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var styleControls: some View {
        if !model.hasInspectorStyleControls {
            Text("Choose a drawing tool or select an annotation to change its style.")
                .font(.inspectorLabel)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        } else {
            if model.selectionCount > 1 {
                Text("\(model.selectionCount) annotations selected")
                    .font(.inspectorLabel)
                    .foregroundStyle(.secondary)
            }

            if model.isTextStyleAvailable {
                AnnotationTextStyleControls(model: model)
            } else {
                if model.isColorStyleAvailable {
                    InspectorRow("Color") {
                        AnnotationSwatchStrip(selectedSwatch: model.selectedSwatch) { swatch in
                            onEditorAction()
                            model.setSwatch(swatch)
                        }
                    }
                }

                if model.isStrokeStyleAvailable {
                    InspectorRow("Stroke") {
                        AnnotationStrokePicker(strokeWidth: model.strokeWidth) { strokeWidth in
                            onEditorAction()
                            model.setStrokeWidth(strokeWidth)
                        }
                    }
                }

                if model.isRedactionStyleAvailable {
                    InspectorSlider(
                        "Strength",
                        value: Binding(
                            get: { model.redactionDensity },
                            set: {
                                onEditorAction()
                                model.setRedactionDensity($0)
                            }
                        ),
                        range: 0.15...1,
                        format: .percent()
                    )
                }
            }
        }
    }
}

// MARK: - Section summaries

/// One-line readouts for collapsed section headers. `nil` means the section
/// has nothing active worth announcing.
private enum AnnotationInspectorSummary {
    static func border(_ settings: AnnotationScreenshotBorderSettings) -> String? {
        guard settings.isEnabled else { return nil }
        let thickness = InspectorValueFormat.percent(fractionDigits: 1).displayString(for: settings.thickness)
        return "\(settings.color.title) · \(thickness)"
    }

    static func camera(_ settings: AnnotationCameraSettings) -> String? {
        guard !settings.isDefault else { return nil }
        var parts: [String] = []
        let angles = [
            settings.tiltXDegrees, settings.tiltYDegrees, settings.rollDegrees,
            settings.rotationXDegrees, settings.rotationYDegrees
        ]
        if angles.contains(where: { abs($0) > 0.0001 }) {
            parts.append("Angled")
        }
        if abs(settings.zoom - 1) > 0.0001 {
            parts.append(InspectorValueFormat.magnification(fractionDigits: 2).displayString(for: settings.zoom))
        }
        if abs(settings.panX) > 0.0001 || abs(settings.panY) > 0.0001 {
            parts.append("Panned")
        }
        if parts.isEmpty {
            parts.append("FOV \(InspectorValueFormat.degrees().displayString(for: settings.fieldOfViewDegrees))")
        }
        return parts.joined(separator: " · ")
    }

    static func progressiveBlur(_ settings: AnnotationProgressiveBlurSettings) -> String? {
        guard settings.isEnabled else { return nil }
        return "\(settings.mode.title) · \(Int(settings.strength.rounded()))"
    }

    static func watermark(_ settings: AnnotationWatermarkSettings) -> String? {
        let text = settings.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard settings.isEnabled, !text.isEmpty else { return nil }
        return "“\(text)”"
    }
}

// MARK: - Tools

private struct AnnotationInspectorToolGrid: View {
    let selectedTool: AnnotationTool
    let onSelect: (AnnotationTool) -> Void

    private let columns: [GridItem] = Array(
        repeating: GridItem(.flexible(), spacing: 4), count: 6
    )
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        // Nested radius: the tray wraps tiles inset by `controlInset`.
        let shape = RoundedRectangle(
            cornerRadius: InspectorMetrics.tileRadius + InspectorMetrics.controlInset,
            style: .continuous
        )

        LazyVGrid(columns: columns, spacing: 4) {
            ForEach(AnnotationTool.allCases) { tool in
                AnnotationToolCell(
                    tool: tool,
                    isSelected: selectedTool == tool,
                    action: { onSelect(tool) }
                )
            }
        }
        .frame(maxWidth: 280)
        .frame(maxWidth: .infinity)
        .padding(InspectorMetrics.controlInset)
        .background(shape.fill(InspectorControlPalette.trackFill(for: colorScheme)))
        .clipShape(shape)
    }
}

private struct AnnotationToolCell: View {
    let tool: AnnotationTool
    let isSelected: Bool
    let action: () -> Void

    @State private var isHovering = false
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Button(action: action) {
            ZStack {
                Color.clear

                Image(systemName: tool.systemImage)
                    .font(.system(size: 13, weight: .medium))
            }
            .aspectRatio(1, contentMode: .fit)
            .contentShape(RoundedRectangle(cornerRadius: InspectorMetrics.tileRadius, style: .continuous))
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .foregroundStyle(isSelected ? InspectorControlPalette.selectedForeground : Color.secondary)
        .background {
            RoundedRectangle(cornerRadius: InspectorMetrics.tileRadius, style: .continuous)
                .fill(background)
                .shadow(
                    color: isSelected ? InspectorControlPalette.selectedChipShadow(for: colorScheme) : .clear,
                    radius: 1,
                    y: 0.5
                )
        }
        .help(tool.helpText)
        .onHover { isHovering = $0 }
        .accessibilityLabel(tool.title)
        .accessibilityHint(tool.helpText)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private var background: Color {
        if isSelected {
            return InspectorControlPalette.selectedChipFill(for: colorScheme)
        }
        return isHovering ? InspectorControlPalette.hoverFill : .clear
    }
}
