//
//  RecordingOverlayEffects.swift
//  Screendrop
//
//  Post-record input feedback drawn by Studio: the click pulse and the
//  keystroke caption. Both are reconstructed from the input.json sidecar on
//  the source timeline, so they can be toggled and styled in the editor and
//  render pixel-identically in the live preview and the offline exporter.
//

import CoreGraphics
import Foundation

// MARK: - Click feedback

nonisolated struct PointerPressEffectGeometry: Sendable {
    var impactRadius: CGFloat
    var impactOpacity: Double
    var rippleRadius: CGFloat
    var rippleOpacity: Double
    var rippleLineWidth: CGFloat
}

/// Shared preview/export math for a crisp impact followed by a quieter ripple.
/// The effect stays anchored to the recorded press coordinate rather than the
/// cursor spring, so the marked target is exact even during a fast movement.
nonisolated enum PointerPressEffectStyle {
    /// macOS system blue.
    static let color: (red: Double, green: Double, blue: Double) = (0, 122.0 / 255.0, 1)
    static let duration: TimeInterval = 0.4
    private static let impactDuration: TimeInterval = 0.12
    private static let rippleDelay: TimeInterval = 0.06

    /// `referenceHeight` is the unzoomed content height. Camera transforms move
    /// the effect but never inflate its on-screen size.
    static func geometry(
        progress: Double,
        referenceHeight: CGFloat,
        cursorScale: CGFloat
    ) -> PointerPressEffectGeometry {
        let age = min(max(progress, 0), 1) * duration
        let base = referenceHeight * CGFloat(21.0 / 1_080.0) * cursorScale
        let impactProgress = min(max(age / impactDuration, 0), 1)
        let impactEase = easeOutCubic(impactProgress)
        let rippleProgress = min(max(
            (age - rippleDelay) / (duration - rippleDelay),
            0
        ), 1)
        let rippleEase = easeOutCubic(rippleProgress)
        return PointerPressEffectGeometry(
            impactRadius: base * CGFloat(0.38 + 0.34 * impactEase),
            impactOpacity: age <= impactDuration ? 0.38 * (1 - impactEase) : 0,
            rippleRadius: base * CGFloat(0.62 + 0.93 * rippleEase),
            rippleOpacity: age >= rippleDelay ? 0.44 * (1 - rippleEase) : 0,
            rippleLineWidth: max(1, base * CGFloat(0.14 - 0.07 * rippleEase))
        )
    }

    private static func easeOutCubic(_ progress: Double) -> Double {
        let clamped = min(max(progress, 0), 1)
        return 1 - pow(1 - clamped, 3)
    }
}

// MARK: - Keystroke caption placement

enum RecordingKeystrokePlacement: String, Codable, CaseIterable, Identifiable, Sendable {
    case topLeft
    case topCenter
    case topRight
    case bottomLeft
    case bottomCenter
    case bottomRight

    var id: String { rawValue }

    var isTop: Bool {
        switch self {
        case .topLeft, .topCenter, .topRight: true
        case .bottomLeft, .bottomCenter, .bottomRight: false
        }
    }

    var title: String {
        switch self {
        case .topLeft, .bottomLeft: "Left"
        case .topCenter, .bottomCenter: "Center"
        case .topRight, .bottomRight: "Right"
        }
    }
}

// MARK: - Keystroke caption timeline

/// What the caption shows at a single point in time.
nonisolated struct KeystrokeCaptionFrame: Sendable, Equatable {
    var modifiers: [String]
    var key: String
    var opacity: Double
    var scale: Double
}

/// Deterministic caption playback built once from the recorded keystrokes.
/// Consecutive chords replace the caption content in place; a chord with
/// nothing after it fades out on its own.
nonisolated struct KeystrokeCaptionTimeline: Sendable {
    private static let popInDuration: TimeInterval = 0.16
    private static let holdDuration: TimeInterval = 1.1
    private static let popOutDuration: TimeInterval = 0.3

    private let events: [RecordingKeystrokeEvent]

    static let empty = KeystrokeCaptionTimeline(events: [])

    init(events: [RecordingKeystrokeEvent]) {
        self.events = events
            .filter { $0.time.isFinite && !$0.key.isEmpty }
            .sorted { $0.time < $1.time }
    }

    var isEmpty: Bool {
        events.isEmpty
    }

    func frame(at time: TimeInterval) -> KeystrokeCaptionFrame? {
        guard !events.isEmpty, time.isFinite else { return nil }

        // Last event that has already started.
        var low = 0
        var high = events.count
        while low < high {
            let middle = (low + high) / 2
            if events[middle].time <= time {
                low = middle + 1
            } else {
                high = middle
            }
        }
        let index = low - 1
        guard index >= 0 else { return nil }

        let event = events[index]
        let naturalEnd = event.time + Self.popInDuration + Self.holdDuration + Self.popOutDuration
        let nextStart = index + 1 < events.count ? events[index + 1].time : nil
        let end = min(naturalEnd, nextStart ?? .greatestFiniteMagnitude)
        guard time < end else { return nil }

        // Pop-in is skipped when the previous chord was still on screen -
        // the caption just swaps its content in place.
        let previousEnd: TimeInterval? = index > 0
            ? events[index - 1].time + Self.popInDuration + Self.holdDuration + Self.popOutDuration
            : nil
        let continuesPreviousCaption = previousEnd.map { $0 > event.time } ?? false

        var opacity = 1.0
        var scale = 1.0

        if !continuesPreviousCaption, time - event.time < Self.popInDuration {
            let progress = min(max((time - event.time) / Self.popInDuration, 0), 1)
            let eased = 1 - pow(1 - progress, 3)
            opacity = eased
            scale = 0.92 + 0.08 * eased
        }

        // Fade out only applies at the natural end; a chord cut short by the
        // next one hands over at full opacity.
        if naturalEnd <= (nextStart ?? .greatestFiniteMagnitude), time > naturalEnd - Self.popOutDuration {
            let progress = min(max((naturalEnd - time) / Self.popOutDuration, 0), 1)
            let eased = 1 - pow(1 - progress, 3)
            opacity = min(opacity, eased)
            scale = min(scale, 0.97 + 0.03 * eased)
        }

        guard opacity > 0.005 else { return nil }
        return KeystrokeCaptionFrame(
            modifiers: event.modifiers,
            key: event.key,
            opacity: opacity,
            scale: scale
        )
    }
}

// MARK: - Keystroke caption metrics

/// Geometry shared verbatim by the SwiftUI preview and the CoreGraphics
/// exporter. Everything derives from the recording card's height so the
/// caption is stable under zoom and identical at any render resolution.
nonisolated struct KeystrokeCaptionMetrics: Sendable {
    let fontSize: CGFloat
    let paddingHorizontal: CGFloat
    let paddingVertical: CGFloat
    let cornerRadius: CGFloat
    let margin: CGFloat

    static let backgroundAlpha: Double = 0.62
    static let modifierAlpha: Double = 0.7

    /// The caption text drawn for a frame: modifiers, a space, then the key.
    static func text(for frame: KeystrokeCaptionFrame) -> (modifiers: String, key: String) {
        let modifiers = frame.modifiers.joined(separator: " ")
        return (modifiers.isEmpty ? "" : modifiers + " ", frame.key)
    }

    init(cardHeight: CGFloat) {
        fontSize = max(11, cardHeight * 0.033)
        paddingHorizontal = fontSize * 0.72
        paddingVertical = fontSize * 0.46
        // One rounded container; radius stays proportional to the pill so it
        // reads as a soft capsule-ish rectangle at any resolution.
        cornerRadius = fontSize * 0.55
        margin = cardHeight * 0.045
    }

    /// Top-left origin of the caption pill inside `cardRect` (both in the
    /// same top-left-origin coordinate space).
    func pillOrigin(
        pillSize: CGSize,
        cardRect: CGRect,
        placement: RecordingKeystrokePlacement
    ) -> CGPoint {
        let x: CGFloat
        switch placement {
        case .topLeft, .bottomLeft:
            x = cardRect.minX + margin
        case .topCenter, .bottomCenter:
            x = cardRect.midX - pillSize.width / 2
        case .topRight, .bottomRight:
            x = cardRect.maxX - margin - pillSize.width
        }
        let y = placement.isTop
            ? cardRect.minY + margin
            : cardRect.maxY - margin - pillSize.height
        return CGPoint(x: x, y: y)
    }
}

// MARK: - Speed badge

/// What the speed badge shows at a single point in time.
nonisolated struct SpeedBadgeFrame: Sendable, Equatable {
    let speed: Double
    /// Entrance and exit, 0...1: drives opacity and a small scale-in.
    let presence: Double
    /// Editor time, which paces the chevrons' sweep so the preview and the
    /// export animate identically.
    let time: TimeInterval

    var opacity: Double { presence }
    var scale: Double { 0.85 + 0.15 * presence }

    var title: String { RecordingClipSegment.speedTitle(speed) }

    /// Brightness of chevron `index` (0 = leftmost): a highlight sweeps
    /// left to right through the three, then rests, then sweeps again.
    func chevronAlpha(_ index: Int) -> Double {
        let phase = time / SpeedBadgeMetrics.sweepPeriod
        var local = (phase - Double(index) * 0.2).truncatingRemainder(dividingBy: 1)
        if local < 0 { local += 1 }
        let window = 0.45
        let bump = local < window ? sin(.pi * local / window) : 0
        return 0.32 + 0.68 * bump
    }
}

/// Where sped-up clips sit on the edited timeline. Neighbouring clips at the
/// same speed merge into one span, so a split doesn't make the badge blink.
nonisolated struct SpeedBadgeTimeline: Sendable, Equatable {
    struct Span: Sendable, Equatable {
        var start: TimeInterval
        var end: TimeInterval
        let speed: Double
    }

    static let empty = SpeedBadgeTimeline(spans: [])

    /// Ramp in at the start of a span, and out before its end.
    private static let fadeIn: TimeInterval = 0.22
    private static let fadeOut: TimeInterval = 0.18

    let spans: [Span]

    var isEmpty: Bool { spans.isEmpty }

    private init(spans: [Span]) {
        self.spans = spans
    }

    init(clipTimeline: RecordingClipTimeline) {
        var spans: [Span] = []
        var cursor: TimeInterval = 0
        for segment in clipTimeline.segments {
            let length = segment.editorDuration
            defer { cursor += length }
            guard segment.speed > 1.001, length > 0 else { continue }
            if var last = spans.last,
               abs(last.speed - segment.speed) < 0.001,
               abs(last.end - cursor) < 0.0001 {
                last.end = cursor + length
                spans[spans.count - 1] = last
            } else {
                spans.append(Span(start: cursor, end: cursor + length, speed: segment.speed))
            }
        }
        self.spans = spans
    }

    func frame(at time: TimeInterval) -> SpeedBadgeFrame? {
        guard let span = spans.first(where: { time >= $0.start && time < $0.end }) else {
            return nil
        }
        let entering = (time - span.start) / Self.fadeIn
        let leaving = (span.end - time) / Self.fadeOut
        let linear = min(max(min(entering, leaving), 0), 1)
        // Smoothstep, so the entrance eases rather than snapping on.
        let presence = linear * linear * (3 - 2 * linear)
        return SpeedBadgeFrame(speed: span.speed, presence: presence, time: time)
    }
}

/// Geometry shared verbatim by the SwiftUI preview and the CoreGraphics
/// exporter: a caption-style pill reading "2×" followed by three chevrons.
/// Everything derives from the card's height, like the keystroke caption.
nonisolated struct SpeedBadgeMetrics: Sendable {
    static let backgroundAlpha = KeystrokeCaptionMetrics.backgroundAlpha
    static let sweepPeriod: TimeInterval = 0.9

    let fontSize: CGFloat
    let paddingHorizontal: CGFloat
    let paddingVertical: CGFloat
    let cornerRadius: CGFloat
    let margin: CGFloat
    /// Gap between the "2×" and the first chevron.
    let textGap: CGFloat
    let chevronWidth: CGFloat
    let chevronHeight: CGFloat
    /// Advance from one chevron to the next.
    let chevronAdvance: CGFloat
    let chevronLineWidth: CGFloat

    static let chevronCount = 3

    init(cardHeight: CGFloat) {
        let caption = KeystrokeCaptionMetrics(cardHeight: cardHeight)
        fontSize = caption.fontSize
        paddingHorizontal = caption.paddingHorizontal
        paddingVertical = caption.paddingVertical
        cornerRadius = caption.cornerRadius
        margin = caption.margin
        textGap = fontSize * 0.42
        chevronHeight = fontSize * 0.62
        chevronWidth = chevronHeight * 0.5
        chevronAdvance = chevronWidth + fontSize * 0.14
        chevronLineWidth = max(1, fontSize * 0.13)
    }

    /// Width of the three chevrons, outer edge to outer edge.
    var chevronsWidth: CGFloat {
        chevronAdvance * CGFloat(Self.chevronCount - 1) + chevronWidth
    }

    func badgeWidth(textWidth: CGFloat) -> CGFloat {
        paddingHorizontal * 2 + textWidth + textGap + chevronsWidth
    }

    /// One open chevron pointing right, its left edge at `minX`, centered
    /// on `midY`. The same path serves both coordinate systems because it
    /// is symmetric top to bottom.
    func chevronPath(minX: CGFloat, midY: CGFloat) -> CGPath {
        let path = CGMutablePath()
        path.move(to: CGPoint(x: minX, y: midY - chevronHeight / 2))
        path.addLine(to: CGPoint(x: minX + chevronWidth, y: midY))
        path.addLine(to: CGPoint(x: minX, y: midY + chevronHeight / 2))
        return path
    }

    /// Top-left origin of the badge inside `cardRect`, pinned to the card's
    /// edge the same way the keystroke caption is.
    func badgeOrigin(
        badgeSize: CGSize,
        cardRect: CGRect,
        placement: RecordingKeystrokePlacement
    ) -> CGPoint {
        KeystrokeCaptionMetrics(cardHeight: cardRect.height).pillOrigin(
            pillSize: badgeSize,
            cardRect: cardRect,
            placement: placement
        )
    }
}
