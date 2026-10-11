//
//  GlassCropBar.swift
//  Screendrop
//
//  Crop mode's controls, floating over the bottom of an editor's canvas:
//  aspect, reset, cancel, and the one inked action that applies the crop.
//  The screenshot editor and Studio crop through the same bar.
//

import SwiftUI

struct GlassCropBar: View {
    let aspect: CropAspectRatio
    let onAspectChange: (CropAspectRatio) -> Void
    let onReset: () -> Void
    let onCancel: () -> Void
    let onApply: () -> Void
    var resetHelp = "Reset the selection to the whole image"

    @Namespace private var glass

    var body: some View {
        GlassEffectContainer(spacing: GlassMetrics.containerSpacing) {
            HStack(spacing: GlassMetrics.gap) {
                GlassMenuButton(
                    title: aspect.title,
                    systemImage: "aspectratio",
                    help: "Crop aspect ratio"
                ) {
                    Picker("Aspect Ratio", selection: Binding(get: { aspect }, set: onAspectChange)) {
                        ForEach(CropAspectRatio.allCases) { aspect in
                            Text(aspect.title).tag(aspect)
                        }
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()
                }
                .glassEffectID("aspect", in: glass)

                GlassCapsuleButton(title: "Reset", systemImage: "arrow.counterclockwise", action: onReset)
                    .help(resetHelp)
                    .glassEffectID("reset", in: glass)

                GlassIconButton(systemImage: "xmark", help: "Cancel Crop (Esc)", action: onCancel)
                    .keyboardShortcut(.cancelAction)
                    .glassEffectID("cancel", in: glass)

                GlassCapsuleButton(title: "Crop", systemImage: "checkmark", isProminent: true, action: onApply)
                    .keyboardShortcut(.defaultAction)
                    .help("Apply the crop (Return)")
                    .glassEffectID("apply", in: glass)
            }
        }
    }
}
