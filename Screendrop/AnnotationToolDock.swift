//
//  AnnotationToolDock.swift
//  Screendrop
//
//  The screenshot editor's tools, floating in one glass capsule over the
//  bottom of the canvas, where the pointer already is. Tools are grouped by
//  what they make - shapes, lines, marks, redactions - with hairlines
//  between groups. The selected tool is inked; it jumps to the next tool
//  rather than sliding, like every other selection in the app.
//

import SwiftUI

struct AnnotationToolDock: View {
    @Bindable var model: AnnotationEditorModel
    let onEditorAction: () -> Void

    static let height: CGFloat = 44
    static let bottomPadding: CGFloat = 14
    /// Height the canvas keeps clear for the dock when fitting the image,
    /// beyond its own fit inset.
    static let canvasReserve: CGFloat = 44

    private static let groups: [[AnnotationTool]] = [
        [.select],
        [.rectangle, .filledRectangle, .ellipse, .highlight],
        [.arrow, .line, .freehand],
        [.text, .numberedCircle],
        [.pixelate, .blur],
    ]

    var body: some View {
        HStack(spacing: 2) {
            ForEach(Array(Self.groups.enumerated()), id: \.offset) { index, group in
                if index > 0 { separator }
                ForEach(group) { tool in
                    AnnotationDockToolButton(
                        tool: tool,
                        isSelected: model.selectedTool == tool
                    ) {
                        onEditorAction()
                        model.selectTool(tool)
                    }
                }
            }

            autoRedactMenu
        }
        .padding(.horizontal, 5)
        .frame(height: Self.height)
        .glassEffect(.regular, in: .capsule)
        .motion(.morphQuick, value: model.selectedTool)
    }

    private var separator: some View {
        Rectangle()
            .fill(Palette.hairline)
            .frame(width: 1, height: 18)
            .padding(.horizontal, 4)
            .accessibilityHidden(true)
    }

    /// Finds text that looks sensitive and covers it in one go. Spins while
    /// it scans; the result lands as a toast above the dock.
    private var autoRedactMenu: some View {
        Menu {
            Button("Pixelate Sensitive Text", systemImage: AnnotationTool.pixelate.systemImage) {
                onEditorAction()
                model.smartRedact(using: .pixelate)
            }
            Button("Blur Sensitive Text", systemImage: AnnotationTool.blur.systemImage) {
                onEditorAction()
                model.smartRedact(using: .blur)
            }
        } label: {
            ZStack {
                if model.isSmartRedacting {
                    ProgressView()
                        .controlSize(.small)
                        .transition(.blurPop)
                } else {
                    Image(systemName: "wand.and.sparkles")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Palette.label)
                        .transition(.blurPop)
                }
            }
            .frame(width: 34, height: 34)
            .contentShape(Circle())
        }
        .menuStyle(.button)
        .menuIndicator(.hidden)
        .buttonStyle(.plain)
        .fixedSize()
        .disabled(model.isSmartRedacting)
        .help("Redact sensitive text automatically")
        .motion(.morphQuick, value: model.isSmartRedacting)
    }
}

private struct AnnotationDockToolButton: View {
    let tool: AnnotationTool
    let isSelected: Bool
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: tool.systemImage)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(isSelected ? Palette.onAccent : Palette.label)
                .frame(width: 34, height: 34)
                .background {
                    Circle()
                        .fill(isSelected ? Palette.accent : isHovering ? Palette.hoverFill : .clear)
                }
                .scaleEffect(isSelected ? 1 : isHovering ? 1.04 : 1)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .onHover { isHovering = $0 }
        .motion(.morphQuick, value: isHovering)
        .help(helpText)
        .accessibilityLabel(tool.title)
        .accessibilityHint(tool.helpText)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private var helpText: String {
        guard let key = tool.shortcutKey else { return tool.helpText }
        return "\(tool.helpText) (\(key))"
    }
}

private extension AnnotationTool {
    /// The single-key shortcut AnnotationKeyboard maps to this tool.
    var shortcutKey: String? {
        switch self {
        case .select: "H"
        case .rectangle: "R"
        case .ellipse: "O"
        case .text: "T"
        case .line: "L"
        case .arrow: "A"
        case .pixelate: "P"
        case .blur: "B"
        case .numberedCircle: "1"
        default: nil
        }
    }
}

/// A short-lived message floating above the dock, e.g. the result of an
/// automatic redaction.
struct AnnotationDockToast: View {
    let text: String
    var systemImage = "sparkles"

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: systemImage)
                .font(.system(size: 11, weight: .semibold))
            Text(text)
                .font(.system(size: 12, weight: .medium))
        }
        .foregroundStyle(Palette.label)
        .padding(.horizontal, 14)
        .frame(height: 30)
        .glassEffect(.regular, in: .capsule)
    }
}
