//
//  GlassControls.swift
//  Screendrop
//
//  Liquid Glass building blocks for editor chrome. Each control is one glass
//  shape; callers group them in a `GlassEffectContainer` and give each a
//  `glassEffectID` so controls that appear or leave are born out of, and melt
//  back into, their neighbours instead of fading in place.
//
//  The container's spacing must stay below the resting gap between shapes:
//  glass closer than the container spacing merges, so a wider resting gap is
//  what lets a shape settle as its own clean capsule after the morph.
//

import AppKit
import SwiftUI

enum GlassMetrics {
    /// Glass closer than this melts together while shapes move.
    static let containerSpacing: CGFloat = 6
    /// Resting gap between neighbouring glass shapes; wider than
    /// `containerSpacing` so settled shapes stand apart.
    static let gap: CGFloat = 8
    /// Small icon buttons in docks and floating bars.
    static let buttonSize: CGFloat = 30
    /// Primary actions, such as the inspector footer's export capsule.
    static let actionHeight: CGFloat = 34
    /// Glyph size inside a `buttonSize` control.
    static let symbolSize: CGFloat = 12
}

// MARK: - Buttons

/// A round glass icon button. Disabled buttons keep their glass but drop the
/// interactive press response and dim their glyph.
struct GlassIconButton: View {
    let systemImage: String
    let help: String
    var size: CGFloat = GlassMetrics.buttonSize
    var symbolSize: CGFloat = GlassMetrics.symbolSize
    var tint: Color? = nil
    let action: () -> Void

    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: symbolSize, weight: .semibold))
                .foregroundStyle(foreground)
                .contentTransition(.symbolEffect(.replace))
                .frame(width: size, height: size)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .glassEffect(glass, in: .circle)
        .help(help)
        .accessibilityLabel(help)
    }

    private var foreground: Color {
        if tint != nil { return .white.opacity(isEnabled ? 1 : 0.5) }
        return .primary.opacity(isEnabled ? 0.88 : 0.28)
    }

    private var glass: Glass {
        var glass = Glass.regular
        if let tint { glass = glass.tint(tint) }
        return glass.interactive(isEnabled)
    }
}

/// A glass capsule holding an icon and a title.
struct GlassCapsuleButton: View {
    let title: String
    var systemImage: String? = nil
    var height: CGFloat = GlassMetrics.buttonSize
    var tint: Color? = nil
    let action: () -> Void

    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if let systemImage {
                    Image(systemName: systemImage)
                        .font(.system(size: GlassMetrics.symbolSize - 1, weight: .semibold))
                }
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(1)
                    .fixedSize()
            }
            .foregroundStyle(foreground)
            .padding(.horizontal, 13)
            .frame(height: height)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .glassEffect(glass, in: .capsule)
    }

    private var foreground: Color {
        if tint != nil { return .white.opacity(isEnabled ? 1 : 0.5) }
        return .primary.opacity(isEnabled ? 0.88 : 0.28)
    }

    private var glass: Glass {
        var glass = Glass.regular
        if let tint { glass = glass.tint(tint) }
        return glass.interactive(isEnabled)
    }
}

// MARK: - Tabs

/// Tabs that fill their width, which AppKit's segmented control won't do.
/// The selected segment is a glass pill on a quiet track; it jumps to the
/// next segment rather than sliding. Ported from Periscope's navigator.
struct SegmentedTabs<Value: Hashable>: View {
    let options: [(String, Value)]
    @Binding var selection: Value
    /// The height of each segment's button. The bar is this plus the inset
    /// around it.
    var segmentHeight: CGFloat = 24
    private static var inset: CGFloat { 3 }

    var body: some View {
        HStack(spacing: 0) {
            ForEach(options, id: \.1) { title, value in
                let selected = selection == value
                Button {
                    selection = value
                } label: {
                    Text(title)
                        .font(.system(size: 11.5, weight: selected ? .semibold : .medium))
                        .foregroundStyle(selected ? Color.primary : Color.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .contentShape(Capsule())
                        .glassEffect(selected ? .regular.interactive() : .identity, in: Capsule())
                }
                .buttonStyle(.plain)
                .focusEffectDisabled()
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
        .padding(Self.inset)
        .frame(height: segmentHeight + Self.inset * 2)
        .background(Capsule().fill(Color.primary.opacity(0.06)))
    }
}

// MARK: - Action capsule

/// A primary action that carries its own job. Idle it reads as a button;
/// running, the capsule fills as its own progress bar and offers Cancel on
/// hover; when the job lands it flashes a check in green before settling
/// back. Collapsed, it folds to an icon-only circle so a sibling action can
/// take the room.
struct GlassActionCapsule: View {
    let title: String
    let systemImage: String
    /// Nil while idle; the job's 0...1 progress while it runs.
    var progress: Double? = nil
    /// Names the running stage ahead of the percentage, e.g. "Uploading".
    var stage: String? = nil
    /// A transient success message, shown with a check on green glass.
    var flash: String? = nil
    var isProminent = false
    var isCollapsed = false
    var height: CGFloat = GlassMetrics.actionHeight
    let action: () -> Void

    @State private var isHovering = false
    @Environment(\.isEnabled) private var isEnabled

    private var isRunning: Bool { progress != nil }

    var body: some View {
        Button(action: action) {
            GeometryReader { proxy in
                let filled = proxy.size.width * min(max(progress ?? 0, 0), 1)
                ZStack(alignment: .leading) {
                    if isRunning {
                        Rectangle()
                            .fill(Color.accentColor)
                            .frame(width: filled)
                            .frame(maxHeight: .infinity)
                            .transition(.opacity)
                    }

                    label.foregroundStyle(baseInk)

                    if isRunning {
                        // The same label in reverse ink, revealed only over
                        // the filled part of the capsule.
                        label
                            .foregroundStyle(.white)
                            .mask(alignment: .leading) {
                                Rectangle().frame(width: filled)
                            }
                    }
                }
                .frame(width: proxy.size.width, height: proxy.size.height, alignment: .leading)
                .clipShape(Capsule())
                .motion(.smooth(duration: 0.35), value: progress)
            }
            .frame(height: height)
            .frame(minWidth: height, maxWidth: isCollapsed ? height : .infinity)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .glassEffect(glass, in: .capsule)
        .onHover { isHovering = $0 }
        .help(helpText)
        .accessibilityLabel(helpText)
        .accessibilityValue(
            progress.map { Text($0, format: .percent.precision(.fractionLength(0))) } ?? Text("")
        )
    }

    @ViewBuilder
    private var label: some View {
        ZStack {
            if isCollapsed {
                Image(systemName: systemImage)
                    .font(.system(size: 13, weight: .semibold))
                    .transition(.blurPop)
            } else if let flash, !isRunning {
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 13, weight: .semibold))
                    Text(flash)
                        .font(.system(size: 13, weight: .semibold))
                }
                .transition(AnyTransition(.blurReplace))
            } else if isRunning {
                Text(runningTitle)
                    .font(.system(size: 13, weight: .semibold).monospacedDigit())
                    .contentTransition(.numericText())
                    .motion(.morphQuick, value: runningTitle)
                    .transition(AnyTransition(.blurReplace))
            } else {
                HStack(spacing: 6) {
                    Image(systemName: systemImage)
                        .font(.system(size: 12, weight: .semibold))
                    Text(title)
                        .font(.system(size: 13, weight: .semibold))
                }
                .transition(AnyTransition(.blurReplace))
            }
        }
        .lineLimit(1)
        .frame(maxWidth: .infinity)
    }

    private var runningTitle: String {
        if isHovering { return "Cancel" }
        let percent = (progress ?? 0).formatted(.percent.precision(.fractionLength(0)))
        guard let stage else { return percent }
        return "\(stage) \(percent)"
    }

    private var baseInk: Color {
        if !isEnabled { return .primary.opacity(isProminent ? 0.45 : 0.3) }
        if !isRunning, flash != nil || isProminent { return .white }
        return .primary.opacity(0.9)
    }

    private var glass: Glass {
        var glass = Glass.regular
        if !isRunning, isEnabled {
            if flash != nil {
                glass = glass.tint(.green)
            } else if isProminent {
                glass = glass.tint(.accentColor)
            }
        }
        return glass.interactive(isEnabled)
    }

    private var helpText: String {
        if isRunning { return "Cancel \(title)" }
        return title
    }
}
