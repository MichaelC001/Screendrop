//
//  RecordingTypingSounds.swift
//  Screendrop
//
//  Keyboard sounds laid under a recording's typing. Each keypress is voiced
//  from a recorded mechanical keystroke embedded as code
//  (TypingSoundSamples) and rendered into a sound track on the edited
//  timeline, which Studio layers into playback and the exporter mixes into
//  the movie.
//
//  Capture stores only *when* a key went down and a coarse class (letter,
//  space, return, delete, modifier). Which key was pressed is never
//  recorded, so typed text can't be reconstructed from the sidecar.
//

import AVFoundation
import Foundation

// MARK: - Captured events

/// The coarse class of a keypress, enough to pick a believable sound.
nonisolated enum RecordingTypingKeyKind: String, Codable, Sendable {
    case key
    case space
    case returnKey = "return"
    case delete
    case modifier

    /// Classifies a key-down by virtual key code without keeping the key.
    static func kind(forKeyCode keyCode: UInt16) -> RecordingTypingKeyKind {
        switch keyCode {
        case 49: .space
        case 36, 76: .returnKey
        case 51, 117: .delete
        default: .key
        }
    }
}

/// One keypress on the screen movie timeline (or, once mapped, the edited
/// timeline).
nonisolated struct RecordingTypingEvent: Codable, Sendable, Equatable {
    var time: TimeInterval
    var kind: RecordingTypingKeyKind
}

// MARK: - Settings

nonisolated enum TypingSoundProfile: String, Codable, CaseIterable, Identifiable, Sendable {
    /// A tactile mechanical switch: a crisp downstroke, a woody bottom-out
    /// and a lighter upstroke.
    case mechanical
    /// A low-travel MacBook keyboard: soft, padded thumps with no click.
    case apple

    var id: Self { self }

    var title: String {
        switch self {
        case .mechanical: "Mechanical"
        case .apple: "Apple"
        }
    }

    var systemImage: String {
        switch self {
        case .mechanical: "keyboard"
        case .apple: "keyboard.chevron.compact.down"
        }
    }
}

nonisolated struct TypingSoundSettings: Codable, Equatable, Sendable {
    var isEnabled = false
    var profile: TypingSoundProfile = .mechanical
    /// Linear gain applied to the synthesized track, 0...1.
    var volume: Double = 0.6

    static let volumeRange: ClosedRange<Double> = 0...1

    var clampedVolume: Double {
        volume.isFinite ? min(max(volume, Self.volumeRange.lowerBound), Self.volumeRange.upperBound) : 0.6
    }
}

/// The last choices made in Studio, used for projects that haven't picked
/// their own - so typing sounds follow the user from one recording to the next.
nonisolated enum TypingSoundDefaults {
    private static let key = "recordingStudio.typingSounds.v1"

    static var settings: TypingSoundSettings {
        get {
            guard let data = UserDefaults.standard.data(forKey: key),
                  let decoded = try? JSONDecoder().decode(TypingSoundSettings.self, from: data) else {
                return TypingSoundSettings()
            }
            return decoded
        }
        set {
            guard let data = try? JSONEncoder().encode(newValue) else { return }
            UserDefaults.standard.set(data, forKey: key)
        }
    }
}

// MARK: - Synthesis

/// Builds key sounds from one recorded mechanical keystroke
/// (`TypingSoundSamples`): the press at the keypress and the release a
/// moment later. Each key class and variant gets its own pitch, level,
/// release timing and stereo position so fast typing never sounds looped.
/// The Apple profile reshapes the same recording into a MacBook-style soft
/// thump: the click filtered away, a gentler onset and a faint release.
nonisolated enum TypingSoundSynthesizer {
    static let sampleRate: Double = 48_000
    static let variantsPerKind = 6

    /// One rendered keypress in stereo.
    struct Hit: Sendable {
        let left: [Float]
        let right: [Float]
        var frameCount: Int { left.count }
    }

    typealias Bank = [RecordingTypingKeyKind: [Hit]]

    static func bank(for profile: TypingSoundProfile) -> Bank {
        // The recording is quiet; bring the press up to a healthy peak and
        // scale the release by the same amount so their balance holds.
        let peak = TypingSoundSamples.keyDown.reduce(Int32(1)) { max($0, abs(Int32($1))) }
        let scale = 0.75 / Float(peak)
        let down = TypingSoundSamples.keyDown.map { Float($0) * scale }
        let up = TypingSoundSamples.keyUp.map { Float($0) * scale }
        let kinds: [RecordingTypingKeyKind] = [.key, .space, .returnKey, .delete, .modifier]
        var bank: Bank = [:]
        for (kindIndex, kind) in kinds.enumerated() {
            bank[kind] = (0..<variantsPerKind).map { variant in
                var random = SeededRandom(seed: UInt64(kindIndex * 1_000 + variant + 1) &* 0x9E37_79B9_7F4A_7C15)
                return hit(profile: profile, kind: kind, down: down, up: up, random: &random)
            }
        }
        return bank
    }

    private struct Voicing {
        var pitch: Double
        var downGain: Float
        var upGain: Float
        var releaseDelay: TimeInterval
        /// Removes the bright click above this frequency; nil keeps the full
        /// sound.
        var lowPass: Double?
        /// Fades the onset in over this long so the key lands without a snap.
        var attack: TimeInterval = 0
        /// Cuts each sample off after this long, with a short fade.
        var maximumLength: TimeInterval?
    }

    private static func hit(
        profile: TypingSoundProfile,
        kind: RecordingTypingKeyKind,
        down: [Float],
        up: [Float],
        random: inout SeededRandom
    ) -> Hit {
        let voicing = voicing(profile: profile, kind: kind, random: &random)

        let pressed = shaped(down, voicing: voicing)
        let released = shaped(up, voicing: voicing)
        let releaseStart = Int(voicing.releaseDelay * sampleRate)
        var mono = [Float](repeating: 0, count: max(pressed.count, releaseStart + released.count))
        for index in pressed.indices {
            mono[index] += pressed[index] * voicing.downGain
        }
        for index in released.indices {
            mono[releaseStart + index] += released[index] * voicing.upGain
        }

        // Keys sit slightly left or right of center; the space bar is wide
        // and central.
        let pan = kind == .space ? 0 : random.next(in: -0.25...0.25)
        let angle = (pan + 1) * .pi / 4
        let leftGain = Float(cos(angle) * 2.squareRoot())
        let rightGain = Float(sin(angle) * 2.squareRoot())
        return Hit(left: mono.map { $0 * leftGain }, right: mono.map { $0 * rightGain })
    }

    private static func voicing(
        profile: TypingSoundProfile,
        kind: RecordingTypingKeyKind,
        random: inout SeededRandom
    ) -> Voicing {
        // Bigger keys ring lower; modifiers are pressed lightly.
        let kindPitch: Double
        let kindGain: Float
        switch kind {
        case .key: kindPitch = 1; kindGain = 1
        case .space: kindPitch = 0.84; kindGain = 1.1
        case .returnKey: kindPitch = 0.9; kindGain = 1.05
        case .delete: kindPitch = 0.95; kindGain = 1
        case .modifier: kindPitch = 1.04; kindGain = 0.7
        }
        let level = kindGain * Float(random.next(in: 0.85...1.0))

        switch profile {
        case .mechanical:
            return Voicing(
                pitch: kindPitch * random.next(in: 0.95...1.05),
                downGain: level,
                upGain: level * Float(random.next(in: 0.75...0.95)),
                releaseDelay: random.next(in: 0.07...0.11) * (kind == .space ? 1.2 : 1),
                lowPass: nil,
                maximumLength: nil
            )
        case .apple:
            // Scissor switches barely travel and have no click leaf: a
            // dull, padded thump, then an almost silent return.
            return Voicing(
                pitch: kindPitch * random.next(in: 0.84...0.92),
                // Filtering the click away removes most of the energy; make
                // it back up so the thump sits just under Mechanical.
                downGain: level * 2.6,
                upGain: level * 0.4,
                releaseDelay: random.next(in: 0.05...0.07),
                lowPass: kind == .space ? 900 : 1_200,
                attack: 0.0025,
                maximumLength: 0.035
            )
        }
    }

    /// Resamples to the output rate at the voicing's pitch (linear
    /// interpolation is plenty for clicks this short), then applies the
    /// optional high-pass and length cap.
    private static func shaped(_ source: [Float], voicing: Voicing) -> [Float] {
        let step = TypingSoundSamples.sampleRate / sampleRate * voicing.pitch
        var length = Int(Double(source.count - 1) / step)
        if let maximumLength = voicing.maximumLength {
            length = min(length, Int(maximumLength * sampleRate))
        }
        guard length > 0 else { return [] }

        var output = [Float](repeating: 0, count: length)
        for index in 0..<length {
            let position = Double(index) * step
            let lower = Int(position)
            let fraction = Float(position - Double(lower))
            let next = min(lower + 1, source.count - 1)
            output[index] = source[lower] + (source[next] - source[lower]) * fraction
        }

        if let cutoff = voicing.lowPass {
            // Two passes for a steeper slope, so no click leaks through.
            for _ in 0..<2 {
                var filter = OnePoleLowPass(cutoff: cutoff, sampleRate: sampleRate)
                for index in output.indices {
                    output[index] = filter.process(output[index])
                }
            }
        }
        if voicing.attack > 0 {
            let rampFrames = min(length, Int(voicing.attack * sampleRate))
            for index in 0..<rampFrames {
                let progress = Float(index) / Float(rampFrames)
                output[index] *= progress * progress
            }
        }
        if voicing.maximumLength != nil {
            let fade = min(length, Int(0.004 * sampleRate))
            for offset in 0..<fade {
                output[length - fade + offset] *= Float(fade - offset) / Float(fade)
            }
        }
        return output
    }

    private struct OnePoleLowPass {
        private let coefficient: Float
        private var previousOutput: Float = 0

        init(cutoff: Double, sampleRate: Double) {
            let dt = 1 / sampleRate
            let rc = 1 / (2 * Double.pi * cutoff)
            coefficient = Float(dt / (rc + dt))
        }

        mutating func process(_ input: Float) -> Float {
            previousOutput += coefficient * (input - previousOutput)
            return previousOutput
        }
    }
}

/// SplitMix64: tiny, deterministic, good enough for audio jitter.
nonisolated struct SeededRandom {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    mutating func nextUInt64() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    mutating func next(in range: ClosedRange<Double>) -> Double {
        let unit = Double(nextUInt64() >> 11) / Double(1 << 53)
        return range.lowerBound + unit * (range.upperBound - range.lowerBound)
    }
}

// MARK: - Track rendering

nonisolated enum TypingSoundTrackRenderer {
    enum RenderError: Error {
        case couldNotCreateBuffer
    }

    /// Maps source-timeline keypresses onto the edited timeline, dropping
    /// the ones whose footage was cut. Clips at normal speed keep every
    /// keypress where it happened. A sped-up clip would squeeze the real
    /// presses into an inhuman rattle, so wherever its typing is denser
    /// than a person can type, that stretch gets a natural typing rhythm
    /// instead - still starting and stopping with the typing on screen.
    static func editorEvents(
        from events: [RecordingTypingEvent],
        clipTimeline: RecordingClipTimeline
    ) -> [RecordingTypingEvent] {
        let sorted = events.sorted { $0.time < $1.time }
        var result: [RecordingTypingEvent] = []
        var editorStart: TimeInterval = 0
        for (clipIndex, clip) in clipTimeline.segments.enumerated() {
            let isLast = clipIndex == clipTimeline.segments.count - 1
            let speed = max(clip.speed, RecordingClipSegment.minimumSpeed)
            let mapped = sorted
                .filter { event in
                    event.time >= clip.sourceStart - 0.000_001
                        && (isLast ? event.time <= clip.sourceEnd + 0.000_001 : event.time < clip.sourceEnd)
                }
                .map { event in
                    RecordingTypingEvent(
                        time: editorStart + min(max(event.time - clip.sourceStart, 0), clip.duration) / speed,
                        kind: event.kind
                    )
                }

            if speed > 1.001 {
                var random = SeededRandom(seed: UInt64(clipIndex + 1) &* 0xA24B_AED4_963E_E407)
                result += naturalTyping(replacing: mapped, random: &random)
            } else {
                result += mapped
            }
            editorStart += clip.editorDuration
        }
        return result.sorted { $0.time < $1.time }
    }

    /// Fastest believable sustained typing, in keypresses per second.
    private static let naturalKeysPerSecond: Double = 8
    /// Compressed keypresses closer than this belong to the same burst of
    /// typing; a longer gap is a pause that stays silent.
    private static let burstGap: TimeInterval = 0.35

    /// Splits compressed keypresses into bursts and re-voices each burst
    /// that is too dense to be human as words at a natural pace, spanning
    /// the same stretch of the timeline.
    private static func naturalTyping(
        replacing events: [RecordingTypingEvent],
        random: inout SeededRandom
    ) -> [RecordingTypingEvent] {
        var bursts: [[RecordingTypingEvent]] = []
        for event in events {
            if let last = bursts.last?.last, event.time - last.time <= burstGap {
                bursts[bursts.count - 1].append(event)
            } else {
                bursts.append([event])
            }
        }

        var result: [RecordingTypingEvent] = []
        for burst in bursts {
            guard let first = burst.first, let last = burst.last else { continue }
            let span = last.time - first.time
            // Already a human pace (a few presses, or a gentle speed-up).
            if Double(burst.count) <= max(1, span * naturalKeysPerSecond) + 1 {
                result += burst
                continue
            }

            var time = first.time
            var simulated: [RecordingTypingEvent] = []
            while time <= last.time {
                let letters = Int(random.next(in: 2...7.99))
                for _ in 0..<letters where time <= last.time {
                    simulated.append(RecordingTypingEvent(time: time, kind: .key))
                    time += random.next(in: 0.085...0.16)
                }
                guard time <= last.time else { break }
                simulated.append(RecordingTypingEvent(time: time, kind: .space))
                time += random.next(in: 0.13...0.24)
            }
            // A burst that ended by pressing Return still ends on Return.
            if last.kind == .returnKey {
                if let final = simulated.last, last.time - final.time < 0.08 {
                    simulated.removeLast()
                }
                simulated.append(last)
            }
            result += simulated
        }
        return result
    }

    /// Writes a stereo Apple Lossless track exactly `duration` long with a
    /// synthesized keypress at every event. Lossless keeps timing exact (no
    /// encoder priming) while long silent stretches still compress to
    /// almost nothing.
    @concurrent
    static func render(
        events: [RecordingTypingEvent],
        duration: TimeInterval,
        settings: TypingSoundSettings,
        to url: URL
    ) async throws {
        let sampleRate = TypingSoundSynthesizer.sampleRate
        let bank = TypingSoundSynthesizer.bank(for: settings.profile)
        let gain = Float(settings.clampedVolume)
        let totalFrames = max(1, Int((duration * sampleRate).rounded()))

        try? FileManager.default.removeItem(at: url)
        let file = try AVAudioFile(
            forWriting: url,
            settings: [
                AVFormatIDKey: kAudioFormatAppleLossless,
                AVSampleRateKey: sampleRate,
                AVNumberOfChannelsKey: 2,
                AVEncoderBitDepthHintKey: 16
            ],
            commonFormat: .pcmFormatFloat32,
            interleaved: false
        )
        let blockFrames = Int(sampleRate)
        guard let buffer = AVAudioPCMBuffer(
            pcmFormat: file.processingFormat,
            frameCapacity: AVAudioFrameCount(blockFrames)
        ), let channels = buffer.floatChannelData else {
            throw RenderError.couldNotCreateBuffer
        }

        // Pair each event with its hit up front, never repeating the same
        // variant twice in a row for a kind.
        var lastVariant: [RecordingTypingKeyKind: Int] = [:]
        var random = SeededRandom(seed: 0x5EED_0F_7E_C1_1C)
        let scheduled: [(start: Int, hit: TypingSoundSynthesizer.Hit)] = events.compactMap { event in
            guard let variants = bank[event.kind] ?? bank[.key], !variants.isEmpty else { return nil }
            var variant = Int(random.nextUInt64() % UInt64(variants.count))
            if variants.count > 1, variant == lastVariant[event.kind] {
                variant = (variant + 1) % variants.count
            }
            lastVariant[event.kind] = variant
            return (Int((event.time * sampleRate).rounded()), variants[variant])
        }

        var firstActive = 0
        var blockStart = 0
        while blockStart < totalFrames {
            try Task.checkCancellation()
            let frames = min(blockFrames, totalFrames - blockStart)
            let blockEnd = blockStart + frames
            let left = channels[0]
            let right = channels[1]
            left.update(repeating: 0, count: frames)
            right.update(repeating: 0, count: frames)

            while firstActive < scheduled.count,
                  scheduled[firstActive].start + scheduled[firstActive].hit.frameCount <= blockStart {
                firstActive += 1
            }
            var index = firstActive
            while index < scheduled.count, scheduled[index].start < blockEnd {
                let (start, hit) = scheduled[index]
                let from = max(start, blockStart)
                let to = min(start + hit.frameCount, blockEnd)
                if from < to {
                    for frame in from..<to {
                        left[frame - blockStart] += hit.left[frame - start] * gain
                        right[frame - blockStart] += hit.right[frame - start] * gain
                    }
                }
                index += 1
            }

            // Overlapping fast keystrokes can stack; keep them in range.
            for frame in 0..<frames {
                left[frame] = min(1, max(-1, left[frame]))
                right[frame] = min(1, max(-1, right[frame]))
            }
            buffer.frameLength = AVAudioFrameCount(frames)
            try file.write(from: buffer)
            blockStart = blockEnd
        }
    }

    /// A short burst of typing for auditioning a profile in the inspector.
    static let auditionEvents: [RecordingTypingEvent] = {
        let pattern: [(TimeInterval, RecordingTypingKeyKind)] = [
            (0.05, .key), (0.17, .key), (0.26, .key), (0.41, .key), (0.52, .space),
            (0.68, .key), (0.77, .key), (0.9, .key), (0.99, .key), (1.12, .delete),
            (1.3, .key), (1.42, .returnKey)
        ]
        return pattern.map { RecordingTypingEvent(time: $0.0, kind: $0.1) }
    }()

    static let auditionDuration: TimeInterval = 1.8

    static func temporaryURL(named name: String) -> URL {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("Screendrop", isDirectory: true)
            .appendingPathComponent("TypingSounds", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("\(name).caf")
    }
}
