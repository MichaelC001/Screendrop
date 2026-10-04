//
//  RecordingStudioTimelineDock.swift
//  Screendrop
//
//  The Studio timeline: a glass control row over the lanes. Edit tools sit
//  on the left, transport in the middle, timeline zoom on the right - each a
//  cluster of glass shapes in its own container. Tools that only mean
//  something in context are born out of their neighbour when they start to
//  apply and melt back into it when they stop: Delete grows out of Split
//  once something is selected, Reset appears beside Undo once the cut has
//  edits, and the fit chip grows out of the zoom buttons once the lanes are
//  zoomed.
//

import AppKit
import SwiftUI

struct StudioTimelineDock: View {
    @Bindable var model: RecordingStudioModel

    /// Horizontal scale of the lanes, as a multiplier over "the whole
    /// recording fits the viewport". Zoom 1 is the timeline's original
    /// fixed-width layout; anything above it scrolls.
    @State private var zoom: Double = 1
    @State private var viewportWidth: CGFloat = 1
    @State private var scrollX: CGFloat = 0
    @State private var scrollPosition = ScrollPosition(edge: .leading)
    @State private var isResetClipsConfirmationPresented = false
    @Namespace private var glass

    /// Step per zoom button press / keyboard shortcut.
    private static let zoomStep: Double = 1.6
    /// How close to the viewport edge the playhead may drift before the
    /// lanes scroll to keep it in sight.
    private static let followMargin: CGFloat = 48

    private var scale: StudioTimelineScale {
        StudioTimelineScale(
            viewportWidth: viewportWidth,
            duration: model.duration,
            zoom: zoom
        )
    }

    var body: some View {
        VStack(spacing: StudioTimelineMetrics.rowSpacing) {
            controlRow
            lanes
        }
        .padding(.horizontal, 16)
        .padding(.top, 10)
        .padding(.bottom, 14)
        .background(Color(nsColor: .windowBackgroundColor))
        .overlay(alignment: .top) {
            Rectangle()
                .fill(Color(nsColor: .separatorColor).opacity(0.45))
                .frame(height: 0.5)
        }
    }

    // MARK: Control row

    private var controlRow: some View {
        ZStack {
            HStack(spacing: 0) {
                editCluster
                Spacer(minLength: 0)
                zoomCluster
            }

            transport
        }
        .frame(height: 38)
        .motion(.morph, value: clusterKey)
    }

    /// Changes when a contextual tool appears or leaves, so the clusters
    /// morph once per change rather than on every model update.
    private var clusterKey: [Bool] {
        [canDeleteSelection, model.hasClipEdits, model.canUndo, model.canRedo, zoom > 1.0001]
    }

    private var editCluster: some View {
        GlassEffectContainer(spacing: GlassMetrics.containerSpacing) {
            HStack(spacing: GlassMetrics.gap) {
                GlassIconButton(systemImage: "scissors", help: "Split at Playhead (⌘B)") {
                    withAnimation(.morphIfAllowed) {
                        model.splitClip(at: model.currentTime)
                    }
                }
                .keyboardShortcut("b", modifiers: .command)
                .disabled(!model.isLoaded)
                .glassEffectID("split", in: glass)

                if canDeleteSelection {
                    GlassIconButton(systemImage: "trash", help: "Delete Selection (⌫)") {
                        deleteSelection()
                    }
                    .glassEffectID("delete", in: glass)
                }

                GlassIconButton(systemImage: "arrow.uturn.backward", help: "Undo (⌘Z)") {
                    model.undo()
                }
                .keyboardShortcut("z", modifiers: .command)
                .disabled(!model.canUndo)
                .glassEffectID("undo", in: glass)
                .padding(.leading, 6)

                GlassIconButton(systemImage: "arrow.uturn.forward", help: "Redo (⇧⌘Z)") {
                    model.redo()
                }
                .keyboardShortcut("z", modifiers: [.command, .shift])
                .disabled(!model.canRedo)
                .glassEffectID("redo", in: glass)

                if model.hasClipEdits {
                    GlassIconButton(systemImage: "arrow.counterclockwise", help: "Reset All Clip Edits…") {
                        isResetClipsConfirmationPresented = true
                    }
                    .glassEffectID("reset", in: glass)
                    .confirmationDialog(
                        "Reset all clip edits?",
                        isPresented: $isResetClipsConfirmationPresented
                    ) {
                        Button("Reset Clips", role: .destructive) {
                            withAnimation(.morphIfAllowed) { model.resetClips() }
                        }
                    } message: {
                        Text("Every split, trim, deletion and speed change goes back to the original recording. You can undo this.")
                    }
                }
            }
        }
    }

    /// Current time, the three playback buttons, and the cut's length. The
    /// play button is the one large shape; its glyph swaps with a symbol
    /// replace so the glass itself never jumps.
    private var transport: some View {
        HStack(spacing: 12) {
            Text(studioPreciseTimecode(model.displayTime))
                .font(.system(size: 12, weight: .semibold).monospacedDigit())
                .foregroundStyle(.primary.opacity(0.9))
                .frame(width: 58, alignment: .trailing)

            GlassEffectContainer(spacing: GlassMetrics.containerSpacing) {
                HStack(spacing: GlassMetrics.gap) {
                    GlassIconButton(systemImage: "backward.end.fill", help: "Back to Start") {
                        model.pause()
                        model.seek(to: 0)
                    }

                    GlassIconButton(
                        systemImage: model.isPlaying ? "pause.fill" : "play.fill",
                        help: model.isPlaying ? "Pause (Space)" : "Play (Space)",
                        size: 38,
                        symbolSize: 15
                    ) {
                        model.togglePlayback()
                    }
                    .keyboardShortcut(.space, modifiers: [])
                    .motion(.morphQuick, value: model.isPlaying)

                    GlassIconButton(systemImage: "forward.end.fill", help: "Skip to End") {
                        model.pause()
                        model.seek(to: model.duration)
                    }
                }
            }
            .disabled(!model.isLoaded)

            Text(studioPreciseTimecode(model.duration))
                .font(.system(size: 12, weight: .medium).monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 58, alignment: .leading)
        }
    }

    private var zoomCluster: some View {
        GlassEffectContainer(spacing: GlassMetrics.containerSpacing) {
            HStack(spacing: GlassMetrics.gap) {
                if zoom > 1.0001 {
                    GlassCapsuleButton(
                        title: String(format: "%.1f×", zoom),
                        systemImage: "arrow.left.and.right"
                    ) {
                        withAnimation(.morphIfAllowed) { fitTimeline() }
                    }
                    .keyboardShortcut("0", modifiers: .command)
                    .help("Fit Timeline (⌘0)")
                    .glassEffectID("fit", in: glass)
                }

                GlassIconButton(systemImage: "minus.magnifyingglass", help: "Zoom Out (⌘-)") {
                    applyZoom(factor: 1 / Self.zoomStep, anchorTime: buttonZoomAnchor)
                }
                .keyboardShortcut("-", modifiers: .command)
                .disabled(zoom <= 1.0001)
                .glassEffectID("zoomOut", in: glass)

                GlassIconButton(systemImage: "plus.magnifyingglass", help: "Zoom In (⌘=)") {
                    applyZoom(factor: Self.zoomStep, anchorTime: buttonZoomAnchor)
                }
                .keyboardShortcut("=", modifiers: .command)
                .disabled(zoom >= scale.maxZoom - 0.0001)
                .glassEffectID("zoomIn", in: glass)
            }
        }
    }

    // MARK: Lanes

    private var lanes: some View {
        GeometryReader { proxy in
            // The proxy width leads the stored one by a frame, so lay the
            // lanes out from it and keep the state copy for the controls.
            let scale = StudioTimelineScale(
                viewportWidth: max(proxy.size.width, 1),
                duration: model.duration,
                zoom: zoom
            )

            VStack(spacing: StudioTimelineMetrics.rowSpacing) {
                Color.clear
                    .frame(height: StudioTimelineMetrics.playheadLaneHeight)

                StudioTimelineRuler(
                    duration: model.duration,
                    pointsPerSecond: scale.pointsPerSecond,
                    scrollX: scrollX
                )
                .frame(height: StudioTimelineMetrics.rulerHeight)

                scrollingLanes(scale: scale)
            }
            .overlay {
                StudioTimelinePlayhead(
                    time: model.currentTime,
                    scale: scale,
                    scrollX: scrollX
                ) { time in
                    model.pause()
                    model.seek(to: time)
                }
            }
            .onChange(of: proxy.size.width, initial: true) { _, width in
                viewportWidth = max(width, 1)
                clampZoom()
            }
        }
        .frame(height: StudioTimelineMetrics.lanesHeight)
        .onChange(of: model.duration) { _, _ in clampZoom() }
        .onChange(of: model.currentTime) { _, time in followPlayhead(to: time) }
    }

    /// The two lanes that carry real edit targets live in a horizontal scroll
    /// view sized to the zoomed timeline. The ruler, playhead and lane chrome
    /// stay viewport-sized and redraw against `scrollX` instead - a rounded
    /// rectangle or Canvas tens of thousands of points wide would be a single
    /// oversized layer, while an AppKit view only ever draws its visible rect.
    private func scrollingLanes(scale: StudioTimelineScale) -> some View {
        ZStack(alignment: .topLeading) {
            VStack(spacing: StudioTimelineMetrics.rowSpacing) {
                Color.clear
                    .frame(height: StudioTimelineMetrics.clipLaneHeight)
                StudioZoomLaneBackground(
                    showsHint: model.zoomEnabled && model.zoomTimelineBlocks.isEmpty
                )
                    .frame(height: StudioTimelineMetrics.zoomLaneHeight)
                Color.clear
                    .frame(height: StudioTimelineMetrics.scrollerGutter)
            }

            ScrollView(.horizontal) {
                VStack(spacing: StudioTimelineMetrics.rowSpacing) {
                    clipLane
                        .frame(
                            width: scale.contentWidth,
                            height: StudioTimelineMetrics.clipLaneHeight
                        )

                    StudioZoomLane(
                        model: model,
                        scale: scale,
                        visibleRange: scale.visibleRange(scrollX: scrollX)
                    )
                    .frame(
                        width: scale.contentWidth,
                        height: StudioTimelineMetrics.zoomLaneHeight
                    )

                    Color.clear
                        .frame(height: StudioTimelineMetrics.scrollerGutter)
                }
            }
            .scrollPosition($scrollPosition)
            .scrollIndicators(scale.isScrollable ? .visible : .never)
            .scrollBounceBehavior(.basedOnSize)
            .onScrollGeometryChange(for: CGFloat.self) { geometry in
                geometry.contentOffset.x
            } action: { _, offset in
                if abs(offset - scrollX) > 0.01 {
                    scrollX = offset
                }
            }
        }
        .frame(height: StudioTimelineMetrics.scrollingLanesHeight)
    }

    private var clipLane: some View {
        RecordingClipTimelineView(
            selectedClipID: $model.selectedClipID,
            playheadTime: $model.currentTime,
            timeline: model.clipTimeline,
            sourceDuration: model.sourceDuration,
            thumbnails: model.timelineThumbnails,
            onSelect: { model.selectClip(id: $0) },
            onSeek: { time in
                model.pause()
                model.seek(to: time)
            },
            onHover: { time in
                model.timelineHoverTime = time
                model.hoverPreviewTime = time
            },
            onSplit: { model.splitClip(at: $0) },
            onDelete: { deleteSelection() },
            onTrim: { model.trimClip($0) },
            onZoom: { factor, anchorTime in
                applyZoom(factor: factor, anchorTime: anchorTime)
            },
            onStep: { seconds in
                model.pause()
                model.seek(to: model.currentTime + seconds)
            }
        )
    }

    // MARK: Zoom & scroll

    /// Rescales around `anchorTime`, keeping that moment under the same
    /// screen position so pinching or ⌘-scrolling doesn't shove the edit
    /// you were aiming at out of the viewport.
    private func applyZoom(factor: Double, anchorTime: TimeInterval?) {
        let current = scale
        guard current.duration > 0, factor.isFinite, factor > 0 else { return }
        let anchor = anchorTime ?? current.time(forX: scrollX + viewportWidth / 2)
        let anchorViewportX = current.x(for: anchor) - scrollX
        let next = min(max(zoom * factor, 1), current.maxZoom)
        guard abs(next - zoom) > 0.0001 else { return }

        // A pinch arrives as dozens of small steps; let the storyboard scale
        // with the lane and resample once the gesture settles.
        model.timelineThumbnails.deferSampling()
        zoom = next
        var zoomed = current
        zoomed.zoom = next
        scroll(to: zoomed.x(for: anchor) - anchorViewportX, in: zoomed)
    }

    private func fitTimeline() {
        guard zoom > 1 else { return }
        zoom = 1
        scrollX = 0
        scrollPosition.scrollTo(edge: .leading)
    }

    /// Keeps the zoom inside range after the viewport or the edited duration
    /// changes - a cut or a wider window can leave the old scale past the cap.
    private func clampZoom() {
        let clamped = min(max(zoom, 1), scale.maxZoom)
        if abs(clamped - zoom) > 0.0001 {
            zoom = clamped
        }
    }

    private func followPlayhead(to time: TimeInterval) {
        let current = scale
        guard current.isScrollable else { return }
        let x = current.x(for: time)
        guard x < scrollX + Self.followMargin
            || x > scrollX + viewportWidth - Self.followMargin else { return }
        // While playing, land the playhead a third in so there is room to
        // watch what is coming; a seek just centers it.
        let inset = model.isPlaying ? viewportWidth / 3 : viewportWidth / 2
        scroll(to: x - inset, in: current)
    }

    private func scroll(to x: CGFloat, in scale: StudioTimelineScale) {
        let clamped = min(max(x, 0), max(0, scale.contentWidth - scale.viewportWidth))
        scrollX = clamped
        scrollPosition.scrollTo(x: clamped)
    }

    /// Zoom buttons keep the playhead pinned when it is on screen, so the
    /// scale grows around the edit point rather than the viewport middle.
    private var buttonZoomAnchor: TimeInterval {
        let x = scale.x(for: model.currentTime)
        if x >= scrollX, x <= scrollX + viewportWidth {
            return model.currentTime
        }
        return scale.time(forX: scrollX + viewportWidth / 2)
    }

    private var canDeleteSelection: Bool {
        model.selectedCueID != nil || model.canDeleteSelectedClip
    }

    private func deleteSelection() {
        withAnimation(.morphIfAllowed) {
            if let cueID = model.selectedCueID {
                model.removeZoomCue(id: cueID)
            } else if model.selectedClipID != nil {
                model.deleteSelectedClip()
            }
        }
    }
}

private enum StudioTimelineMetrics {
    static let rowSpacing: CGFloat = 8
    static let playheadLaneHeight: CGFloat = 14
    static let rulerHeight: CGFloat = 16
    static let clipLaneHeight: CGFloat = 52
    static let zoomLaneHeight: CGFloat = 32
    /// Room under the lanes for the horizontal scroller, so it never sits on
    /// top of a zoom block.
    static let scrollerGutter: CGFloat = 8

    static let scrollingLanesHeight = clipLaneHeight + zoomLaneHeight
        + scrollerGutter + rowSpacing * 2
    static let lanesHeight = playheadLaneHeight + rulerHeight
        + scrollingLanesHeight + rowSpacing * 2
}

/// Shared horizontal scale for every lane in the Studio timeline. `zoom` is a
/// multiplier over "the whole recording fits the viewport", so zoom 1 keeps
/// the original fixed-width timeline and higher values widen the lanes into a
/// scrolling surface where cuts, trim handles and zoom blocks stay grabbable
/// on long recordings.
private struct StudioTimelineScale: Equatable {
    /// Finest scale worth offering; past this a single frame is wider than a
    /// thumbnail tile.
    static let maximumPointsPerSecond: CGFloat = 240
    /// Ceiling on lane width, which is what actually bounds the scale on long
    /// recordings. A 30-minute take still reaches ~55 points per second here.
    static let maximumContentWidth: CGFloat = 100_000

    var viewportWidth: CGFloat
    var duration: TimeInterval
    var zoom: Double

    var contentWidth: CGFloat {
        max(viewportWidth, viewportWidth * CGFloat(zoom))
    }

    var pointsPerSecond: CGFloat {
        duration > 0 ? contentWidth / CGFloat(duration) : 0
    }

    var secondsPerPoint: Double {
        pointsPerSecond > 0 ? 1 / Double(pointsPerSecond) : 0
    }

    var isScrollable: Bool {
        contentWidth > viewportWidth + 0.5
    }

    var maxZoom: Double {
        guard duration > 0, viewportWidth > 1 else { return 1 }
        let widest = min(
            Self.maximumContentWidth,
            Self.maximumPointsPerSecond * CGFloat(duration)
        )
        return max(1, Double(widest / viewportWidth))
    }

    func x(for time: TimeInterval) -> CGFloat {
        guard duration > 0 else { return 0 }
        return CGFloat(min(max(time, 0), duration)) * pointsPerSecond
    }

    func time(forX x: CGFloat) -> TimeInterval {
        guard pointsPerSecond > 0 else { return 0 }
        return min(max(Double(x / pointsPerSecond), 0), duration)
    }

    /// Editor time span currently on screen, padded a little so lane content
    /// culled against it never pops in at the edges.
    func visibleRange(scrollX: CGFloat) -> ClosedRange<TimeInterval> {
        let margin: CGFloat = 120
        let lower = time(forX: scrollX - margin)
        let upper = time(forX: scrollX + viewportWidth + margin)
        return lower...max(lower, upper)
    }
}

/// Full-height playhead with a grabbable crown pin in the lane above the
/// ruler. The crown is the only hit target - everywhere else the overlay
/// passes clicks through to the tracks underneath.
private struct StudioTimelinePlayhead: View {
    let time: TimeInterval
    let scale: StudioTimelineScale
    let scrollX: CGFloat
    let onScrub: (TimeInterval) -> Void

    private enum Metrics {
        static let crownWidth: CGFloat = 11
        static let crownHeight: CGFloat = 13
        static let hitWidth: CGFloat = 26
        static let hitHeight: CGFloat = 22
        static let lineWidth: CGFloat = 1.5
    }

    private static let coordinateSpace = "studio.playheadLane"

    var body: some View {
        GeometryReader { proxy in
            let width = max(proxy.size.width, 1)
            // Viewport space: the playhead overlay never scrolls, it just
            // tracks the scrolled lanes underneath it.
            let x = scale.x(for: time) - scrollX
            let isVisible = x >= -Metrics.lineWidth && x <= width + Metrics.lineWidth

            ZStack(alignment: .topLeading) {
                Rectangle()
                    .fill(Color.accentColor)
                    .frame(
                        width: Metrics.lineWidth,
                        height: max(0, proxy.size.height - Metrics.crownHeight + 2)
                    )
                    .offset(x: x - Metrics.lineWidth / 2, y: Metrics.crownHeight - 2)
                    .allowsHitTesting(false)
                    .opacity(isVisible ? 1 : 0)

                Color.clear
                    .frame(width: Metrics.hitWidth, height: Metrics.hitHeight)
                    .contentShape(Rectangle())
                    .overlay(alignment: .top) {
                        PlayheadCrownShape()
                            .fill(Color.accentColor)
                            .frame(width: Metrics.crownWidth, height: Metrics.crownHeight)
                            .shadow(color: .black.opacity(0.22), radius: 1, y: 0.5)
                    }
                    .offset(x: x - Metrics.hitWidth / 2, y: 0)
                    .opacity(isVisible ? 1 : 0)
                    .allowsHitTesting(isVisible)
                    .gesture(
                        DragGesture(
                            minimumDistance: 0,
                            coordinateSpace: .named(Self.coordinateSpace)
                        )
                        .onChanged { value in
                            onScrub(scale.time(forX: value.location.x + scrollX))
                        }
                    )
            }
        }
        .coordinateSpace(name: Self.coordinateSpace)
    }
}

/// Rounded flag with a pointed tail, the classic editor playhead pin.
private struct PlayheadCrownShape: Shape {
    func path(in rect: CGRect) -> Path {
        let cornerRadius: CGFloat = 3
        let tailHeight: CGFloat = 4
        let bodyBottom = rect.maxY - tailHeight

        var path = Path()
        path.move(to: CGPoint(x: rect.minX + cornerRadius, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX - cornerRadius, y: rect.minY))
        path.addQuadCurve(
            to: CGPoint(x: rect.maxX, y: rect.minY + cornerRadius),
            control: CGPoint(x: rect.maxX, y: rect.minY)
        )
        path.addLine(to: CGPoint(x: rect.maxX, y: bodyBottom - cornerRadius))
        path.addQuadCurve(
            to: CGPoint(x: rect.maxX - cornerRadius, y: bodyBottom),
            control: CGPoint(x: rect.maxX, y: bodyBottom)
        )
        path.addLine(to: CGPoint(x: rect.midX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX + cornerRadius, y: bodyBottom))
        path.addQuadCurve(
            to: CGPoint(x: rect.minX, y: bodyBottom - cornerRadius),
            control: CGPoint(x: rect.minX, y: bodyBottom)
        )
        path.addLine(to: CGPoint(x: rect.minX, y: rect.minY + cornerRadius))
        path.addQuadCurve(
            to: CGPoint(x: rect.minX + cornerRadius, y: rect.minY),
            control: CGPoint(x: rect.minX, y: rect.minY)
        )
        path.closeSubpath()
        return path
    }
}

/// Absolute-time ruler above the clip lane. The ruler itself never scrolls: it
/// draws only the time span currently on screen, so a deeply zoomed timeline
/// costs the same to render as a fitted one.
private struct StudioTimelineRuler: View {
    let duration: Double
    let pointsPerSecond: CGFloat
    let scrollX: CGFloat

    var body: some View {
        Canvas { context, size in
            guard duration > 0.2, pointsPerSecond > 0, size.width > 60 else { return }

            let step = Self.labelStep(forPointsPerSecond: pointsPerSecond)
            let startTime = max(0, Double(scrollX / pointsPerSecond))
            let endTime = min(duration, Double((scrollX + size.width) / pointsPerSecond))
            let endpointLabel = Self.label(for: duration, step: step)
            var lastLabelMaxX = -CGFloat.greatestFiniteMagnitude

            func x(for time: Double) -> CGFloat {
                CGFloat(time) * pointsPerSecond - scrollX
            }

            /// `anchorX` is the tick position; `trailing` right-aligns the
            /// label onto it instead of centering, which is how the endpoint
            /// label stays inside the viewport.
            func drawLabel(_ text: String, at anchorX: CGFloat, trailing: Bool = false) {
                let label = context.resolve(
                    Text(text)
                        .font(.system(size: 9, weight: .medium).monospacedDigit())
                        .foregroundStyle(Color.secondary)
                )
                let labelSize = label.measure(in: size)
                let labelX = trailing ? anchorX - labelSize.width : anchorX - labelSize.width / 2
                let clampedX = min(max(labelX, 0), max(0, size.width - labelSize.width))
                guard clampedX >= lastLabelMaxX + 8 else { return }
                context.draw(label, in: CGRect(
                    x: clampedX,
                    y: size.height - 5 - labelSize.height,
                    width: labelSize.width,
                    height: labelSize.height
                ))
                lastLabelMaxX = clampedX + labelSize.width
            }

            var index = max(0, Int(floor(startTime / step)))
            let lastIndex = Int(ceil(endTime / step))
            while index <= lastIndex {
                let time = Double(index) * step
                index += 1
                guard time <= duration else { break }
                let tickX = x(for: time)

                context.fill(
                    Path(CGRect(x: tickX - 0.5, y: size.height - 4, width: 1, height: 4)),
                    with: .color(.primary.opacity(0.30))
                )

                let minorTime = time + step / 2
                if minorTime < duration {
                    context.fill(
                        Path(CGRect(
                            x: x(for: minorTime) - 0.5,
                            y: size.height - 2.5,
                            width: 1,
                            height: 2.5
                        )),
                        with: .color(.primary.opacity(0.16))
                    )
                }

                // A final whole-second tick can format identically to a
                // fractional endpoint (for example 4.2 -> 00:04). Let the
                // actual endpoint own that label.
                let timeLabel = Self.label(for: time, step: step)
                if time == 0 || timeLabel != endpointLabel {
                    drawLabel(timeLabel, at: tickX)
                }
            }

            // The end of the recording always gets a tick, right-aligned when
            // it lands at the trailing edge of the viewport.
            let endpointX = x(for: duration)
            if endpointX >= -1, endpointX <= size.width + 1 {
                context.fill(
                    Path(CGRect(
                        x: min(endpointX, size.width - 0.5) - 0.5,
                        y: size.height - 4,
                        width: 1,
                        height: 4
                    )),
                    with: .color(.primary.opacity(0.30))
                )
                drawLabel(endpointLabel, at: endpointX, trailing: true)
            }
        }
    }

    /// Smallest "nice" interval whose labels stay comfortably apart at the
    /// current scale. Sub-second steps unlock once a zoomed lane spreads a
    /// single second across most of the viewport.
    private static func labelStep(forPointsPerSecond pointsPerSecond: CGFloat) -> Double {
        let candidates: [Double] = [
            0.1, 0.2, 0.5, 1, 2, 5, 10, 15, 30, 60, 120, 300, 600, 1800
        ]
        for candidate in candidates where CGFloat(candidate) * pointsPerSecond >= 64 {
            return candidate
        }
        return candidates.last ?? 60
    }

    private static func label(for time: Double, step: Double) -> String {
        step < 1 ? studioPreciseTimecode(time) : studioTimecode(time)
    }
}

func studioTimecode(_ seconds: Double) -> String {
    let safe = max(0, seconds.isFinite ? seconds : 0)
    let total = Int(safe.rounded(.down))
    let hours = total / 3600
    let minutes = (total % 3600) / 60
    let remainingSeconds = total % 60
    return hours > 0
        ? String(format: "%d:%02d:%02d", hours, minutes, remainingSeconds)
        : String(format: "%02d:%02d", minutes, remainingSeconds)
}

func studioPreciseTimecode(_ seconds: Double) -> String {
    let safe = max(0, seconds.isFinite ? seconds : 0)
    let totalMinutes = Int(safe) / 60
    let remaining = safe.truncatingRemainder(dividingBy: 60)
    return String(format: "%02d:%04.1f", totalMinutes, remaining)
}

/// Frame around the zoom lane. It stays pinned to the viewport while the cue
/// blocks scroll inside it, so the lane reads as a fixed track no matter how
/// far the timeline is zoomed.
private struct StudioZoomLaneBackground: View {
    /// An empty lane explains itself instead of reading as dead space.
    var showsHint = false

    var body: some View {
        RoundedRectangle(
            cornerRadius: StudioZoomLaneMetrics.laneCornerRadius,
            style: .continuous
        )
            .fill(Color.primary.opacity(0.055))
            .overlay {
                if showsHint {
                    Label("Drag here to add a zoom", systemImage: "plus.magnifyingglass")
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(.tertiary)
                }
            }
            .allowsHitTesting(false)
    }
}

private struct StudioZoomLane: View {
    @Bindable var model: RecordingStudioModel
    let scale: StudioTimelineScale
    let visibleRange: ClosedRange<TimeInterval>

    /// Below this many dragged points, a gesture on blank lane space is
    /// still treated as a click-to-seek rather than a zoom-creating drag.
    private static let dragCreateThreshold: CGFloat = 4

    /// Held as a time rather than a position so a zoom change mid-drag can't
    /// reinterpret where the drag began.
    @State private var dragStartTime: TimeInterval?
    @State private var pendingZoomRange: ClosedRange<TimeInterval>?

    var body: some View {
        ZStack(alignment: .topLeading) {
            // Contentless hit surface: the lane can be tens of thousands of
            // points wide, and the visible frame is drawn by the chrome behind
            // the scroll view.
            Color.clear
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            guard scale.pointsPerSecond > 0 else { return }
                            let time = scale.time(forX: value.location.x)

                            if dragStartTime == nil {
                                model.pause()
                                dragStartTime = time
                            }
                            guard let startTime = dragStartTime else { return }

                            if pendingZoomRange == nil,
                               abs(value.location.x - scale.x(for: startTime))
                                   < Self.dragCreateThreshold {
                                // Still within click tolerance: scrub the
                                // playhead, same as a plain click always has.
                                model.seek(to: time)
                                return
                            }

                            pendingZoomRange = pendingRange(from: startTime, to: time)
                        }
                        .onEnded { _ in
                            // A range clamped to nothing means the drag ran
                            // entirely into a neighboring block; there is no
                            // gap here to put a zoom in.
                            if let range = pendingZoomRange,
                               range.upperBound - range.lowerBound > 0.001 {
                                model.addZoomCue(
                                    fromEditorTime: range.lowerBound,
                                    toEditorTime: range.upperBound
                                )
                            }
                            dragStartTime = nil
                            pendingZoomRange = nil
                        }
                )

            if let pendingZoomRange {
                let lowX = scale.x(for: pendingZoomRange.lowerBound)
                let highX = scale.x(for: pendingZoomRange.upperBound)
                RoundedRectangle(
                    cornerRadius: StudioZoomLaneMetrics.blockCornerRadius,
                    style: .continuous
                )
                    .fill(Color.accentColor.opacity(0.35))
                    .frame(width: max(2, highX - lowX), height: StudioZoomLaneMetrics.blockHeight)
                    .offset(x: lowX, y: StudioZoomLaneMetrics.blockInset)
                    .allowsHitTesting(false)
            }

            // Click ticks and cue blocks are culled to the visible span: an
            // hour-long take can hold thousands of clicks, and only a screenful
            // of them can ever be seen.
            ForEach(Array(visiblePressTimes.enumerated()), id: \.offset) { _, pressTime in
                Rectangle()
                    .fill(Color.accentColor.opacity(0.38))
                    .frame(width: 1, height: 10)
                    .offset(x: scale.x(for: pressTime), y: 11)
                    .allowsHitTesting(false)
            }

            ForEach(visibleBlocks) { block in
                StudioZoomCueBlock(model: model, block: block, scale: scale)
            }
        }
        .contextMenu {
            Button("Add Zoom at Playhead") {
                model.addZoomCue(at: model.currentTime)
            }
        }
    }

    /// The range a drag-created zoom would cover, stopped at the blocks on
    /// either side of where the drag began so the preview matches the cue the
    /// model will actually allow.
    private func pendingRange(
        from startTime: TimeInterval,
        to currentTime: TimeInterval
    ) -> ClosedRange<TimeInterval> {
        let blocks = model.zoomTimelineBlocks
        let lowerLimit = blocks
            .filter { $0.editorEnd <= startTime }
            .map(\.editorEnd)
            .max() ?? 0
        let upperLimit = blocks
            .filter { $0.editorStart >= startTime }
            .map(\.editorStart)
            .min() ?? model.duration
        let low = max(min(startTime, currentTime), lowerLimit)
        let high = min(max(startTime, currentTime), upperLimit)
        return low...max(low, high)
    }

    private var visiblePressTimes: [TimeInterval] {
        model.visibleRecordedPressTimes.filter { visibleRange.contains($0) }
    }

    private var visibleBlocks: [RecordingZoomTimelineBlock] {
        model.zoomTimelineBlocks.filter {
            $0.editorEnd >= visibleRange.lowerBound && $0.editorStart <= visibleRange.upperBound
        }
    }
}

private enum StudioZoomLaneMetrics {
    static let laneInset: CGFloat = 4
    static let blockCornerRadius: CGFloat = 6
    static let laneCornerRadius = blockCornerRadius + laneInset
    static let selectionRingPadding: CGFloat = 1
    static let selectionRingCornerRadius = blockCornerRadius + selectionRingPadding
    static let blockHeight: CGFloat = 24
    static let blockInset: CGFloat = 4
    static let minimumLabelledBlockWidth: CGFloat = 48
}

private struct StudioZoomCueBlock: View {
    @Bindable var model: RecordingStudioModel
    let block: RecordingZoomTimelineBlock
    let scale: StudioTimelineScale

    /// Frozen at drag start. The live block re-derives on every model update,
    /// so measuring the drag against it would compound the translation each
    /// event and send the block flying.
    private struct DragBase {
        let cue: ZoomCue
        let editorStart: TimeInterval
        let editorEnd: TimeInterval
    }

    @State private var dragBase: DragBase?

    private var isSelected: Bool {
        model.selectedCueID == block.cue.id
    }

    var body: some View {
        guard scale.pointsPerSecond > 0 else { return AnyView(EmptyView()) }

        let cue = block.cue
        let blockDuration = block.editorEnd - block.editorStart
        // Short cues keep a grabbable minimum width even when the timeline is
        // fitted; zooming in is what makes them accurate to work with.
        let width = min(
            scale.contentWidth,
            max(24, CGFloat(blockDuration) * scale.pointsPerSecond)
        )
        let x = min(
            max(scale.x(for: block.editorStart), 0),
            max(0, scale.contentWidth - width)
        )

        return AnyView(
            HStack(spacing: 0) {
                resizeHandle(edge: .leading)
                Spacer(minLength: 0)
                // Too narrow for the label: show the block bare rather
                // than a truncated "…".
                if width >= StudioZoomLaneMetrics.minimumLabelledBlockWidth {
                    Text(String(format: "%.1f×", cue.zoom))
                        .font(.system(size: 10, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                        .fixedSize()
                }
                Spacer(minLength: 0)
                resizeHandle(edge: .trailing)
            }
            .frame(width: width, height: StudioZoomLaneMetrics.blockHeight)
            .background(
                RoundedRectangle(
                    cornerRadius: StudioZoomLaneMetrics.blockCornerRadius,
                    style: .continuous
                )
                    .fill(Color.accentColor.opacity(isSelected ? 0.95 : 0.72))
            )
            .overlay {
                if isSelected {
                    RoundedRectangle(
                        cornerRadius: StudioZoomLaneMetrics.selectionRingCornerRadius,
                        style: .continuous
                    )
                        .stroke(Color.white.opacity(0.8), lineWidth: 1.5)
                        .padding(-StudioZoomLaneMetrics.selectionRingPadding)
                }
            }
            .offset(x: x, y: StudioZoomLaneMetrics.blockInset)
            .gesture(
                // Global coordinates: the block moves under the pointer while
                // dragging, so a local-space translation would chase its own
                // updates and jitter.
                DragGesture(coordinateSpace: .global)
                    .onChanged { value in
                        if dragBase == nil {
                            dragBase = DragBase(
                                cue: cue,
                                editorStart: block.editorStart,
                                editorEnd: block.editorEnd
                            )
                            model.beginZoomCueEdit()
                            model.selectZoomCue(id: cue.id)
                        }
                        guard let dragBase else { return }
                        let delta = Double(value.translation.width) * scale.secondsPerPoint
                        var moved = dragBase.cue
                        let length = dragBase.cue.duration
                        let baseBlockDuration = dragBase.editorEnd - dragBase.editorStart
                        let editorStart = min(
                            max(0, dragBase.editorStart + delta),
                            max(0, model.duration - baseBlockDuration)
                        )
                        moved.start = min(
                            max(0, model.sourceTime(atEditorTime: editorStart)),
                            max(0, model.sourceDuration - length)
                        )
                        moved.end = min(model.sourceDuration, moved.start + length)
                        model.moveZoomCue(moved)
                    }
                    .onEnded { _ in
                        dragBase = nil
                        model.endZoomCueEdit(actionName: "Move Zoom")
                    }
            )
            .onTapGesture {
                model.selectZoomCue(id: cue.id)
            }
            .contextMenu {
                Button("Remove Zoom", role: .destructive) {
                    model.removeZoomCue(id: cue.id)
                }
            }
        )
    }

    private func resizeHandle(edge: HorizontalEdge) -> some View {
        Rectangle()
            .fill(Color.white.opacity(0.001))
            .frame(width: 10, height: StudioZoomLaneMetrics.blockHeight)
            .overlay(alignment: .center) {
                Capsule()
                    .fill(Color.white.opacity(isSelected ? 0.9 : 0.45))
                    .frame(width: 2.5, height: 12)
            }
            .contentShape(Rectangle())
            .gesture(
                // Global coordinates - the handle itself moves while resizing,
                // so local-space translations feed back into the drag and jitter.
                DragGesture(coordinateSpace: .global)
                    .onChanged { value in
                        if dragBase == nil {
                            dragBase = DragBase(
                                cue: block.cue,
                                editorStart: block.editorStart,
                                editorEnd: block.editorEnd
                            )
                            model.beginZoomCueEdit()
                            model.selectZoomCue(id: block.cue.id)
                        }
                        guard let dragBase else { return }
                        let delta = Double(value.translation.width) * scale.secondsPerPoint
                        var resized = dragBase.cue
                        switch edge {
                        case .leading:
                            let editorTime = dragBase.editorStart + delta
                            let sourceTime = model.sourceTime(atEditorTime: editorTime)
                            resized.start = min(
                                max(0, sourceTime),
                                dragBase.cue.end - ZoomCue.minimumDuration
                            )
                        case .trailing:
                            let editorTime = dragBase.editorEnd + delta
                            let sourceTime = model.sourceTime(atEditorTime: editorTime)
                            resized.end = max(
                                dragBase.cue.start + ZoomCue.minimumDuration,
                                min(model.sourceDuration, sourceTime)
                            )
                        }
                        model.updateZoomCue(resized)
                    }
                    .onEnded { _ in
                        dragBase = nil
                        model.endZoomCueEdit(actionName: "Resize Zoom")
                    }
            )
    }
}
