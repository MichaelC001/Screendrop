//
//  RecordingTypingSounds.swift
//  Screendrop
//
//  Keyboard sounds laid under a recording's typing. The sounds are
//  synthesized here rather than sampled - no third-party audio ships with
//  the app - and rendered into a sound track on the edited timeline, which
//  Studio layers into playback and the exporter mixes into the movie.
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

/// Procedural key sounds. Each hit is built from filtered noise bursts (the
/// click and the plastic "slap") plus a few decaying partials (the keycap
/// and plate ringing), with a small upstroke after it. Every kind gets a
/// handful of seeded variants so fast typing never sounds like a loop.
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
        let kinds: [RecordingTypingKeyKind] = [.key, .space, .returnKey, .delete, .modifier]
        var bank: Bank = [:]
        for (kindIndex, kind) in kinds.enumerated() {
            bank[kind] = (0..<variantsPerKind).map { variant in
                var random = SeededRandom(seed: UInt64(kindIndex * 1_000 + variant + 1) &* 0x9E37_79B9_7F4A_7C15)
                return hit(profile: profile, kind: kind, random: &random)
            }
        }
        return bank
    }

    private static func hit(
        profile: TypingSoundProfile,
        kind: RecordingTypingKeyKind,
        random: inout SeededRandom
    ) -> Hit {
        let mono: [Float]
        switch profile {
        case .mechanical:
            mono = mechanical(kind: kind, random: &random)
        case .apple:
            mono = apple(kind: kind, random: &random)
        }

        // Keys sit slightly left or right of center; the space bar is wide
        // and central.
        let pan = kind == .space ? 0 : random.next(in: -0.28...0.28)
        let angle = (pan + 1) * .pi / 4
        let leftGain = Float(cos(angle))
        let rightGain = Float(sin(angle))
        return Hit(left: mono.map { $0 * leftGain }, right: mono.map { $0 * rightGain })
    }

    // MARK: Mechanical

    private static func mechanical(kind: RecordingTypingKeyKind, random: inout SeededRandom) -> [Float] {
        let pitch = kindPitch(kind, mechanical: true) * random.next(in: 0.94...1.06)
        let length = kind == .space ? 0.3 : 0.22
        var voice = Voice(length: length)

        // Downstroke: a bright, very short click as the stem snaps past the
        // tactile bump...
        voice.noiseBurst(
            at: 0,
            filter: .bandPass(frequency: 3_800 * pitch, q: 1.1),
            decay: 0.0012,
            amplitude: 0.85,
            random: &random
        )
        // ...then the bottom-out: a woody slap and the case ringing.
        let bottomOut = random.next(in: 0.0035...0.006)
        voice.noiseBurst(
            at: bottomOut,
            filter: .lowPass(frequency: 1_500 * pitch, q: 0.8),
            decay: 0.011,
            amplitude: 1.0,
            random: &random
        )
        voice.partial(at: bottomOut, frequency: 235 * pitch, decay: 0.02, amplitude: 0.55)
        voice.partial(at: bottomOut, frequency: 610 * pitch, decay: 0.013, amplitude: 0.32)
        voice.partial(at: bottomOut, frequency: 1_430 * pitch, decay: 0.007, amplitude: 0.18)

        if kind == .space {
            // Stabilizer rattle on the wide bar.
            for offset in [0.011, 0.019] {
                voice.noiseBurst(
                    at: bottomOut + offset + random.next(in: 0...0.003),
                    filter: .bandPass(frequency: 2_200, q: 2),
                    decay: 0.0015,
                    amplitude: 0.22,
                    random: &random
                )
            }
        }

        // Upstroke as the key returns.
        let release = random.next(in: 0.075...0.105) * (kind == .space ? 1.25 : 1)
        voice.noiseBurst(
            at: release,
            filter: .bandPass(frequency: 2_600 * pitch, q: 1.3),
            decay: 0.0022,
            amplitude: 0.34,
            random: &random
        )
        voice.partial(at: release, frequency: 420 * pitch, decay: 0.009, amplitude: 0.16)

        return voice.normalized(peak: kindGain(kind) * Float(random.next(in: 0.88...1.0)))
    }

    // MARK: Apple (scissor switch)

    private static func apple(kind: RecordingTypingKeyKind, random: inout SeededRandom) -> [Float] {
        let pitch = kindPitch(kind, mechanical: false) * random.next(in: 0.95...1.05)
        let length = kind == .space ? 0.16 : 0.12
        var voice = Voice(length: length)

        // A soft, papery tick with almost no travel...
        voice.noiseBurst(
            at: 0,
            filter: .bandPass(frequency: 5_200 * pitch, q: 0.9),
            decay: 0.0009,
            amplitude: 0.7,
            random: &random
        )
        // ...a short plastic body and a thin aluminium ring.
        let body = random.next(in: 0.0012...0.002)
        voice.noiseBurst(
            at: body,
            filter: .lowPass(frequency: 3_000 * pitch, q: 0.7),
            decay: 0.0042,
            amplitude: 0.55,
            random: &random
        )
        voice.partial(at: body, frequency: 1_750 * pitch, decay: 0.005, amplitude: 0.26)
        voice.partial(at: body, frequency: 3_300 * pitch, decay: 0.003, amplitude: 0.12)
        if kind == .space {
            voice.partial(at: body, frequency: 520, decay: 0.011, amplitude: 0.24)
        }

        let release = random.next(in: 0.045...0.065)
        voice.noiseBurst(
            at: release,
            filter: .bandPass(frequency: 4_100 * pitch, q: 1),
            decay: 0.0008,
            amplitude: 0.16,
            random: &random
        )

        return voice.normalized(peak: 0.72 * kindGain(kind) * Float(random.next(in: 0.88...1.0)))
    }

    private static func kindPitch(_ kind: RecordingTypingKeyKind, mechanical: Bool) -> Double {
        switch kind {
        case .key: 1
        case .space: mechanical ? 0.72 : 0.8
        case .returnKey: 0.86
        case .delete: 0.94
        case .modifier: 1.08
        }
    }

    private static func kindGain(_ kind: RecordingTypingKeyKind) -> Float {
        switch kind {
        case .key: 0.8
        case .space: 0.95
        case .returnKey: 0.92
        case .delete: 0.84
        case .modifier: 0.55
        }
    }

    // MARK: Building blocks

    private struct Voice {
        var samples: [Float]

        init(length: TimeInterval) {
            samples = [Float](repeating: 0, count: Int(length * TypingSoundSynthesizer.sampleRate))
        }

        mutating func noiseBurst(
            at start: TimeInterval,
            filter: Biquad.Kind,
            decay: TimeInterval,
            amplitude: Double,
            random: inout SeededRandom
        ) {
            var biquad = Biquad(kind: filter, sampleRate: TypingSoundSynthesizer.sampleRate)
            let startFrame = Int(start * TypingSoundSynthesizer.sampleRate)
            let frames = min(samples.count - startFrame, Int(decay * 8 * TypingSoundSynthesizer.sampleRate))
            guard startFrame >= 0, frames > 0 else { return }
            let attack = 0.0002 * TypingSoundSynthesizer.sampleRate
            for index in 0..<frames {
                let t = Double(index) / TypingSoundSynthesizer.sampleRate
                let envelope = min(1, Double(index) / attack) * exp(-t / decay)
                let filtered = biquad.process(random.next(in: -1...1))
                samples[startFrame + index] += Float(filtered * envelope * amplitude)
            }
        }

        mutating func partial(
            at start: TimeInterval,
            frequency: Double,
            decay: TimeInterval,
            amplitude: Double
        ) {
            let startFrame = Int(start * TypingSoundSynthesizer.sampleRate)
            let frames = min(samples.count - startFrame, Int(decay * 8 * TypingSoundSynthesizer.sampleRate))
            guard startFrame >= 0, frames > 0 else { return }
            let step = 2 * Double.pi * frequency / TypingSoundSynthesizer.sampleRate
            for index in 0..<frames {
                let t = Double(index) / TypingSoundSynthesizer.sampleRate
                samples[startFrame + index] += Float(sin(step * Double(index)) * exp(-t / decay) * amplitude)
            }
        }

        func normalized(peak: Float) -> [Float] {
            let currentPeak = samples.reduce(Float(0)) { max($0, abs($1)) }
            guard currentPeak > 0 else { return samples }
            let scale = peak / currentPeak
            return samples.map { $0 * scale }
        }
    }

    /// RBJ-cookbook biquad, enough to color noise into clicks and slaps.
    private struct Biquad {
        enum Kind {
            case lowPass(frequency: Double, q: Double)
            case bandPass(frequency: Double, q: Double)
        }

        private var b0 = 0.0, b1 = 0.0, b2 = 0.0, a1 = 0.0, a2 = 0.0
        private var x1 = 0.0, x2 = 0.0, y1 = 0.0, y2 = 0.0

        init(kind: Kind, sampleRate: Double) {
            let frequency: Double
            let q: Double
            switch kind {
            case .lowPass(let f, let quality), .bandPass(let f, let quality):
                frequency = min(f, sampleRate * 0.45)
                q = quality
            }
            let omega = 2 * Double.pi * frequency / sampleRate
            let alpha = sin(omega) / (2 * q)
            let cosOmega = cos(omega)
            let a0 = 1 + alpha
            switch kind {
            case .lowPass:
                b0 = (1 - cosOmega) / 2 / a0
                b1 = (1 - cosOmega) / a0
                b2 = (1 - cosOmega) / 2 / a0
            case .bandPass:
                b0 = alpha / a0
                b1 = 0
                b2 = -alpha / a0
            }
            a1 = -2 * cosOmega / a0
            a2 = (1 - alpha) / a0
        }

        mutating func process(_ x: Double) -> Double {
            let y = b0 * x + b1 * x1 + b2 * x2 - a1 * y1 - a2 * y2
            x2 = x1
            x1 = x
            y2 = y1
            y1 = y
            return y
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
