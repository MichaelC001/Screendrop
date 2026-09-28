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
    /// A low-travel scissor-switch keyboard like Apple's: short, soft ticks.
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
/// The Apple profile reshapes the same recording into a shorter, brighter,
/// softer low-travel tick.
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
        /// Removes body below this frequency; nil keeps the full sound.
        var highPass: Double?
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
                highPass: nil,
                maximumLength: nil
            )
        case .apple:
            return Voicing(
                pitch: kindPitch * random.next(in: 1.28...1.38),
                downGain: level * 0.62,
                upGain: level * 0.22,
                releaseDelay: random.next(in: 0.045...0.065),
                highPass: 900,
                maximumLength: 0.022
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

        if let cutoff = voicing.highPass {
            var filter = OnePoleHighPass(cutoff: cutoff, sampleRate: sampleRate)
            for index in output.indices {
                output[index] = filter.process(output[index])
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

    private struct OnePoleHighPass {
        private let coefficient: Float
        private var previousInput: Float = 0
        private var previousOutput: Float = 0

        init(cutoff: Double, sampleRate: Double) {
            let rc = 1 / (2 * Double.pi * cutoff)
            coefficient = Float(rc / (rc + 1 / sampleRate))
        }

        mutating func process(_ input: Float) -> Float {
            let output = coefficient * (previousOutput + input - previousInput)
            previousInput = input
            previousOutput = output
            return output
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
    /// the ones whose footage was cut.
    static func editorEvents(
        from events: [RecordingTypingEvent],
        clipTimeline: RecordingClipTimeline
    ) -> [RecordingTypingEvent] {
        events.compactMap { event in
            clipTimeline.editorTime(forSourceTime: event.time).map {
                RecordingTypingEvent(time: $0, kind: event.kind)
            }
        }
        .sorted { $0.time < $1.time }
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
