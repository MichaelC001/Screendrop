//
//  TeleprompterComposerPresenter.swift
//  Screendrop
//
//  The small script window opened from the pre-record bar's teleprompter
//  button: paste or type the script, switch the prompter on, and pick how
//  many lines the notch shows at once. Values persist in preferences so a
//  script survives between recordings.
//

import AppKit
import SwiftUI

@MainActor
final class TeleprompterComposerPresenter {
    static let shared = TeleprompterComposerPresenter()

    private var panel: NSPanel?

    private init() {}

    func toggle() {
        if let panel, panel.isVisible {
            hide()
        } else {
            show()
        }
    }

    func show() {
        let panel = panel ?? makePanel()
        PreviewWindowCaptureExclusion.shared.register(window: panel)
        position(panel)
        panel.makeKeyAndOrderFront(nil)
    }

    func hide() {
        panel?.orderOut(nil)
    }

    private func makePanel() -> NSPanel {
        let panel = TeleprompterComposerPanel(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )

        panel.backgroundColor = .clear
        panel.isOpaque = false
        // The glass casts its own shadow; the panel leaves `slack` around it
        // so that shadow isn't clipped.
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.isFloatingPanel = true
        panel.isReleasedWhenClosed = false
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isMovableByWindowBackground = true
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true

        let hostingView = TeleprompterComposerHostingView(rootView: TeleprompterComposerView())
        hostingView.wantsLayer = true
        hostingView.layer?.backgroundColor = NSColor.clear.cgColor
        hostingView.layer?.isOpaque = false
        panel.contentView = hostingView
        panel.setContentSize(hostingView.fittingSize)

        self.panel = panel
        return panel
    }

    /// Sits just above the pre-record bar when it's on screen; otherwise
    /// falls back to the bar's usual bottom-center spot.
    private func position(_ panel: NSPanel) {
        let size = panel.frame.size
        let slack = TeleprompterComposerView.slack
        if let barFrame = RecordingPickerPresenter.shared.barFrame {
            panel.setFrameOrigin(CGPoint(
                x: barFrame.midX - size.width / 2,
                y: barFrame.maxY + 10 - slack
            ))
            return
        }

        let displayID = ActiveDisplayResolver.activeDisplayID(preferPointer: false)
        let screen = ActiveDisplayResolver.screen(for: displayID) ?? NSScreen.main
        let visibleFrame = screen?.visibleFrame ?? CGRect(x: 0, y: 0, width: 800, height: 600)
        panel.setFrameOrigin(CGPoint(
            x: visibleFrame.midX - size.width / 2,
            y: visibleFrame.minY + 126 - slack
        ))
    }
}

private final class TeleprompterComposerPanel: NSPanel {
    override var canBecomeKey: Bool {
        true
    }

    override var canBecomeMain: Bool {
        false
    }

    override func cancelOperation(_ sender: Any?) {
        TeleprompterComposerPresenter.shared.hide()
    }
}

private final class TeleprompterComposerHostingView<Content: View>: NSHostingView<Content> {
    override var isOpaque: Bool {
        false
    }
}

// MARK: - View

/// The script panel, drawn as part of the recording bar: the same glass,
/// radius and edge, with the script sitting straight on the glass.
private struct TeleprompterComposerView: View {
    /// Clear room around the glass for its shadow.
    static let slack: CGFloat = 24

    @AppStorage(ScreendropPreferences.recordingTeleprompterEnabledKey) private var isEnabled = false
    @AppStorage(ScreendropPreferences.recordingTeleprompterScriptKey) private var script = ""
    @AppStorage(ScreendropPreferences.recordingTeleprompterLineCountKey) private var lineCount = 3

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: BarMetrics.cornerRadius, style: .continuous)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.horizontal, 14)
                .padding(.vertical, 12)

            Rectangle().fill(Palette.hairline).frame(height: 0.5)

            editor

            Rectangle().fill(Palette.hairline).frame(height: 0.5)

            footer
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
        }
        .frame(width: 380)
        .glassEffect(.regular, in: shape)
        .overlay { shape.strokeBorder(BarMetrics.edge, lineWidth: 0.5) }
        .padding(Self.slack)
        .onChange(of: isEnabled) { _, enabled in
            if enabled {
                TeleprompterController.shared.preflightAssets()
            }
        }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Teleprompter")
                    .font(.dsHeadline)
                    .foregroundStyle(Palette.label)
                Text(isEnabled ? "Shown under the notch while you record" : "Turn on to show it under the notch")
                    .font(.dsCaption)
                    .foregroundStyle(Palette.secondaryLabel)
                    .contentTransition(.interpolate)
            }

            Spacer(minLength: 8)

            InspectorToggle("Show while recording", isOn: $isEnabled)
                .help(isEnabled
                    ? "Teleprompter will appear in the notch while recording"
                    : "Turn on to show the script in the notch while recording")
        }
        .motion(.morphQuick, value: isEnabled)
    }

    private var editor: some View {
        ZStack(alignment: .topLeading) {
            TextEditor(text: $script)
                .font(.system(size: 13))
                .lineSpacing(3)
                .foregroundStyle(Palette.label)
                .scrollContentBackground(.hidden)
                .padding(.horizontal, 9)
                .padding(.vertical, 8)

            if script.isEmpty {
                Text("Type or paste your script…")
                    .font(.system(size: 13))
                    .foregroundStyle(Palette.tertiaryLabel)
                    .padding(.top, 8)
                    .padding(.leading, 14)
                    .allowsHitTesting(false)
            }
        }
        .frame(height: 168)
    }

    private var footer: some View {
        HStack(spacing: 10) {
            Text(readingSummary)
                .font(.dsCaption)
                .monospacedDigit()
                .foregroundStyle(Palette.secondaryLabel)
                .contentTransition(.numericText())

            Spacer(minLength: 8)

            Text("Lines")
                .font(.dsCaption)
                .foregroundStyle(Palette.secondaryLabel)

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
