//
//  RecordingBarTeleprompter.swift
//  Screendrop
//
//  The teleprompter as part of the recording bar. Its button unfolds the bar
//  upward into a script editor, so the bar becomes one island holding the
//  source, the inputs and the script; pressing it again, starting a
//  recording or Esc folds it back.
//

import AppKit
import SwiftUI

struct RecordingBarTeleprompter: View {
    /// The section's height, which the bar's panel reserves above the bar.
    static let height: CGFloat = 252

    @AppStorage(ScreendropPreferences.recordingTeleprompterEnabledKey) private var isEnabled = false
    @AppStorage(ScreendropPreferences.recordingTeleprompterScriptKey) private var script = ""
    @AppStorage(ScreendropPreferences.recordingTeleprompterLineCountKey) private var lineCount = 3

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.horizontal, 14)
                .padding(.top, 12)
                .padding(.bottom, 10)

            hairline

            editor

            hairline

            footer
                .padding(.horizontal, 14)
                .padding(.vertical, 9)

            hairline
        }
        .frame(height: Self.height)
        .onChange(of: isEnabled) { _, enabled in
            if enabled {
                TeleprompterController.shared.preflightAssets()
            }
        }
    }

    private var hairline: some View {
        Rectangle().fill(BarMetrics.edge).frame(height: 0.5)
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Teleprompter")
                    .font(.dsHeadline)
                    .foregroundStyle(BarMetrics.activeTint)
                Text(isEnabled ? "Shown under the notch while you record" : "Turn on to show it under the notch")
                    .font(.dsCaption)
                    .foregroundStyle(BarMetrics.inactiveTint)
                    .contentTransition(.interpolate)
            }

            Spacer(minLength: 8)

            InspectorToggle("Show while recording", isOn: $isEnabled)
        }
        .motion(.morphQuick, value: isEnabled)
    }

    private var editor: some View {
        ZStack(alignment: .topLeading) {
            TextEditor(text: $script)
                .font(.system(size: 13))
                .lineSpacing(3)
                .foregroundStyle(BarMetrics.activeTint)
                .scrollContentBackground(.hidden)
                .padding(.horizontal, 9)
                .padding(.vertical, 8)

            if script.isEmpty {
                Text("Type or paste your script…")
                    .font(.system(size: 13))
                    .foregroundStyle(BarMetrics.inactiveTint)
                    .padding(.top, 8)
                    .padding(.leading, 14)
                    .allowsHitTesting(false)
            }
        }
        .frame(maxHeight: .infinity)
        // The bar's panel turns off cursor rects (its controls manage the
        // pointer themselves), so the text cursor is set by hand here.
        .overlay { TextCursorRegion() }
    }

    private var footer: some View {
        HStack(spacing: 10) {
            Text(readingSummary)
                .font(.dsCaption)
                .monospacedDigit()
                .foregroundStyle(BarMetrics.inactiveTint)
                .contentTransition(.numericText())

            Spacer(minLength: 8)

            Text("Lines")
                .font(.dsCaption)
                .foregroundStyle(BarMetrics.inactiveTint)

            InspectorSegmented(
                options: Array(ScreendropPreferences.teleprompterLineCountRange),
                isSelected: { $0 == lineCount },
                onTap: { lineCount = $0 },
                label: { count in
                    Text("\(count)")
                        .font(.inspectorSegment)
                        .monospacedDigit()
                },
                height: 26
            )
            .frame(width: 128)
            .help("How many lines the notch shows at once")
        }
    }

    /// Word count and a rough speaking time, at about 150 words a minute.
    private var readingSummary: String {
        let words = script.split { $0.isWhitespace || $0.isNewline }.count
        guard words > 0 else { return "No script yet" }
        let seconds = Int((Double(words) / 150 * 60).rounded())
        let time: String
        if seconds < 60 {
            time = "\(max(seconds, 1)) s"
        } else if seconds % 60 == 0 {
            time = "\(seconds / 60) min"
        } else {
            time = "\(seconds / 60) min \(seconds % 60) s"
        }
        return "\(words) word\(words == 1 ? "" : "s") · about \(time)"
    }
}

/// Shows the text cursor over the script. A tracking area rather than
/// SwiftUI's hover, which can report the hover ending while the bar
/// unfolds under a pointer that was never over the editor, resetting the
/// cursor to an arrow on every frame of the animation.
private struct TextCursorRegion: NSViewRepresentable {
    func makeNSView(context: Context) -> TextCursorView { TextCursorView() }
    func updateNSView(_ nsView: TextCursorView, context: Context) {}
}

private final class TextCursorView: NSView {
    private var isInside = false

    /// Purely an observer; clicks belong to the text editor beneath.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect],
            owner: self
        ))
    }

    override func mouseEntered(with event: NSEvent) {
        isInside = true
        setCursor(.iBeam)
    }

    override func mouseMoved(with event: NSEvent) {
        guard isInside else { return }
        setCursor(.iBeam)
    }

    override func mouseExited(with event: NSEvent) {
        guard isInside else { return }
        isInside = false
        setCursor(.arrow)
    }

    /// A turn late, so AppKit's own resets during the event don't win.
    private func setCursor(_ cursor: NSCursor) {
        DispatchQueue.main.async { cursor.set() }
    }
}
