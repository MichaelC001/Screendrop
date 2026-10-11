//
//  AnnotationActionFooter.swift
//  Screendrop
//
//  The screenshot editor's finishing actions, built like Studio's footer:
//  Share carries its own job and flashes when the link is on the
//  clipboard, Save As sits beside it as a glass circle, and Done is the one
//  inked capsule.
//

import SwiftUI

struct AnnotationActionFooter: View {
    let canShare: Bool
    let isUploading: Bool
    let didCopyLink: Bool
    let isFinishing: Bool
    let isBusy: Bool
    let suggestedTitle: String
    let onUpload: (CloudUploadOptions) -> Void
    let onSaveAs: () -> Void
    let onDone: () -> Void

    @State private var isShareOptionsPresented = false
    @Namespace private var glass

    var body: some View {
        GlassEffectContainer(spacing: GlassMetrics.containerSpacing) {
            HStack(spacing: GlassMetrics.gap) {
                if canShare {
                    GlassActionCapsule(
                        title: isUploading ? "Uploading…" : "Share",
                        systemImage: isUploading ? "arrow.up.circle" : "link",
                        flash: didCopyLink ? "Link Copied" : nil
                    ) {
                        isShareOptionsPresented = true
                    }
                    .disabled(isBusy)
                    .glassEffectID("share", in: glass)
                    .popover(isPresented: $isShareOptionsPresented, arrowEdge: .top) {
                        CloudUploadOptionsPopover(suggestedTitle: suggestedTitle, onConfirm: onUpload)
                    }
                }

                GlassIconButton(
                    systemImage: "square.and.arrow.down.on.square",
                    help: "Save a Copy As…",
                    size: GlassMetrics.actionHeight
                ) {
                    onSaveAs()
                }
                .disabled(isBusy)
                .glassEffectID("saveAs", in: glass)

                GlassActionCapsule(
                    title: isFinishing ? "Saving…" : "Done",
                    systemImage: "checkmark",
                    isProminent: true
                ) {
                    onDone()
                }
                .disabled(isBusy)
                .glassEffectID("done", in: glass)
            }
        }
        .padding(.horizontal, InspectorMetrics.horizontalPadding)
        .padding(.top, 10)
        .padding(.bottom, 16)
        .motion(.morph, value: canShare)
        .motion(.morphQuick, value: didCopyLink)
    }
}
