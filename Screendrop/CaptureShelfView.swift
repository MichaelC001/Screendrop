//
//  CaptureShelfView.swift
//  Screendrop
//
//  The shelf's layout inside its edge panel: a column of cards anchored to
//  the bottom of the screen, newest on top so older cards never move when one
//  arrives; a small header above them while the pointer is on the shelf; and,
//  while tucked, a handle in the middle of the edge.
//
//  Everything moves along one axis, through the docked edge: cards arrive
//  and leave that way, tucking slides the column out that way, and the
//  handle slides in from it.
//

import SwiftUI

struct CaptureShelfView: View {
    @State private var shelf = CaptureShelf.shared
    @State private var isShelfHovered = false
    @State private var hoverEndTask: Task<Void, Never>?
    @AppStorage(ScreendropPreferences.previewPositionKey) private var positionRaw = PreviewOverlayPosition.right.rawValue

    private var isLeft: Bool { positionRaw == PreviewOverlayPosition.left.rawValue }
    /// +1 when docked right, -1 when docked left: the direction of "out".
    private var outward: CGFloat { isLeft ? -1 : 1 }
    private var edge: HorizontalAlignment { isLeft ? .leading : .trailing }
    private var cardTransition: AnyTransition {
        .offset(x: CaptureShelfMetrics.panelWidth * outward).combined(with: .opacity)
    }

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: Alignment(horizontal: edge, vertical: .bottom)) {
                column
                    .padding(isLeft ? .leading : .trailing, CaptureShelfMetrics.edgeInset)
                    .padding(.bottom, CaptureShelfMetrics.bottomInset)
                    .offset(x: shelf.isTucked ? CaptureShelfMetrics.panelWidth * outward : 0)

                if shelf.isTucked, !shelf.items.isEmpty {
                    CaptureShelfHandle(count: shelf.items.count, isLeft: isLeft) {
                        shelf.open()
                    }
                    .frame(maxHeight: .infinity)
                    .transition(.offset(x: 60 * outward))
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height, alignment: Alignment(horizontal: edge, vertical: .bottom))
            .onAppear { shelf.capacity = CaptureShelfMetrics.capacity(forHeight: proxy.size.height) }
            .onChange(of: proxy.size.height) { _, height in
                shelf.capacity = CaptureShelfMetrics.capacity(forHeight: height)
            }
        }
        .onChange(of: positionRaw) { _, _ in
            CaptureShelfPresenter.shared.applyPlacement()
        }
    }

    private var column: some View {
        VStack(alignment: edge, spacing: CaptureShelfMetrics.cardSpacing) {
            if showsHeader {
                CaptureShelfHeader(
                    count: shelf.items.count,
                    hasRecordings: shelf.items.contains { $0.kind == .video },
                    isLeft: isLeft,
                    onTuck: { shelf.tuck(.user) },
                    onClearAll: { shelf.dismissAll() }
                )
                .padding(.bottom, CaptureShelfMetrics.headerSpacing - CaptureShelfMetrics.cardSpacing)
                .transition(.rise)
            }

            ForEach(shelf.items) { item in
                CaptureShelfCard(item: item, shelf: shelf)
                    .transition(cardTransition)
            }
        }
        .frame(width: CaptureShelfMetrics.cardSize.width)
        // The gaps between cards are clear, so the pointer briefly leaves the
        // shelf crossing one. Hold the hover a moment so the header doesn't
        // blink.
        .onHover(perform: setShelfHovered)
        .motion(.morphQuick, value: showsHeader)
    }

    private var showsHeader: Bool {
        isShelfHovered && !shelf.isTucked && !shelf.items.isEmpty && shelf.draggingID == nil
    }

    private func setShelfHovered(_ isHovered: Bool) {
        hoverEndTask?.cancel()
        if isHovered {
            isShelfHovered = true
        } else {
            hoverEndTask = Task {
                try? await Task.sleep(for: .milliseconds(220))
                guard !Task.isCancelled else { return }
                isShelfHovered = false
            }
        }
    }
}

/// Shown above the cards while the pointer is on the shelf: the count, a
/// button that tucks the shelf into the edge, and Clear All.
private struct CaptureShelfHeader: View {
    let count: Int
    let hasRecordings: Bool
    let isLeft: Bool
    let onTuck: () -> Void
    let onClearAll: () -> Void

    @Namespace private var glass

    var body: some View {
        GlassEffectContainer(spacing: GlassMetrics.containerSpacing) {
            HStack(spacing: GlassMetrics.gap) {
                if isLeft { tuckButton }

                GlassCapsuleButton(title: "Clear All", height: CaptureShelfMetrics.headerHeight, action: onClearAll)
                    .help("Dismiss \(title.lowercased())")
                    .glassEffectID("clear", in: glass)

                if !isLeft { tuckButton }
            }
        }
        .frame(height: CaptureShelfMetrics.headerHeight)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(title)
    }

    private var tuckButton: some View {
        GlassIconButton(
            systemImage: isLeft ? "chevron.left" : "chevron.right",
            help: "Tuck into the edge",
            size: CaptureShelfMetrics.headerHeight,
            symbolSize: 10,
            action: onTuck
        )
        .glassEffectID("tuck", in: glass)
    }

    private var title: String {
        let noun = hasRecordings ? "Capture" : "Screenshot"
        return count == 1 ? "1 \(noun)" : "\(count) \(noun)s"
    }
}

/// The tucked shelf: a slim glass tab against the middle of the docked edge,
/// showing how many captures wait inside. Clicking it, or swiping away from
/// the edge on it, brings the cards back.
private struct CaptureShelfHandle: View {
    let count: Int
    let isLeft: Bool
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                Image(systemName: isLeft ? "chevron.right" : "chevron.left")
                    .font(.system(size: 9, weight: .bold))
                Text("\(count)")
                    .font(.system(size: 11, weight: .semibold).monospacedDigit())
                    .contentTransition(.numericText())
            }
            .foregroundStyle(Palette.label)
            .frame(width: isHovered ? 30 : 24, height: 64)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: handleShape)
        .padding(isLeft ? .leading : .trailing, 3)
        .onHover { isHovered = $0 }
        .motion(.morphQuick, value: isHovered)
        .motion(.morphQuick, value: count)
        .help(count == 1 ? "Show 1 capture" : "Show \(count) captures")
        .accessibilityLabel("Show captures")
        .accessibilityValue("\(count)")
    }

    private var handleShape: UnevenRoundedRectangle {
        let outer: CGFloat = 8
        let inner: CGFloat = 13
        return UnevenRoundedRectangle(
            topLeadingRadius: isLeft ? outer : inner,
            bottomLeadingRadius: isLeft ? outer : inner,
            bottomTrailingRadius: isLeft ? inner : outer,
            topTrailingRadius: isLeft ? inner : outer,
            style: .continuous
        )
    }
}
