//
//  RecordingCompositionBuilder.swift
//  Screendrop
//
//  Shared gap-closing composition used by Studio playback and export.
//

import AVFoundation

nonisolated enum RecordingCompositionBuilder {
    static func makeAsset(
        from sourceAsset: AVAsset,
        timeline: RecordingClipTimeline,
        sourceDuration: TimeInterval
    ) throws -> AVAsset {
        let normalized = timeline.normalized(to: sourceDuration)
        if normalized.isUnedited(sourceDuration: sourceDuration) {
            return sourceAsset
        }

        let composition = AVMutableComposition()
        var insertionTime = CMTime.zero
        for clip in normalized.segments {
            let range = CMTimeRange(
                start: CMTime(seconds: clip.sourceStart, preferredTimescale: 600),
                duration: CMTime(seconds: clip.duration, preferredTimescale: 600)
            )
            try composition.insertTimeRange(range, of: sourceAsset, at: insertionTime)

            // Retiming here scales every track inserted above together
            // (video and audio alike), so a sped-up clip never drifts out
            // of sync the way independently retiming each track would.
            if abs(clip.speed - 1) > 0.000_001 {
                let insertedRange = CMTimeRange(start: insertionTime, duration: range.duration)
                let scaledDuration = CMTime(seconds: clip.editorDuration, preferredTimescale: 600)
                composition.scaleTimeRange(insertedRange, toDuration: scaledDuration)
                insertionTime = insertionTime + scaledDuration
            } else {
                insertionTime = insertionTime + range.duration
            }
        }
        return composition
    }

    /// Playback asset whose soundtrack comes from an imported file instead
    /// of the recording's own audio. The video track arrives already
    /// resolved so Studio can rebuild the player item synchronously, the
    /// way it does on every trim.
    static func makeAsset(
        videoTrack: AVAssetTrack,
        timeline: RecordingClipTimeline,
        sourceDuration: TimeInterval,
        replacementAudio: RecordingReplacementAudio
    ) throws -> AVAsset {
        let normalized = timeline.normalized(to: sourceDuration)
        let composition = AVMutableComposition()
        guard let video = composition.addMutableTrack(
            withMediaType: .video,
            preferredTrackID: kCMPersistentTrackID_Invalid
        ) else {
            throw RecordingStudioExporter.ExportError.noVideoTrack
        }

        var insertionTime = CMTime.zero
        for clip in normalized.segments {
            let range = CMTimeRange(
                start: CMTime(seconds: clip.sourceStart, preferredTimescale: 600),
                duration: CMTime(seconds: clip.duration, preferredTimescale: 600)
            )
            try video.insertTimeRange(range, of: videoTrack, at: insertionTime)

            if abs(clip.speed - 1) > 0.000_001 {
                let insertedRange = CMTimeRange(start: insertionTime, duration: range.duration)
                let scaledDuration = CMTime(seconds: clip.editorDuration, preferredTimescale: 600)
                video.scaleTimeRange(insertedRange, toDuration: scaledDuration)
                insertionTime = insertionTime + scaledDuration
            } else {
                insertionTime = insertionTime + range.duration
            }
        }

        // The import is already the finished cut's soundtrack, so it lies
        // flat from zero rather than being re-cut through the clip list -
        // and is clipped to whatever the timeline still holds.
        let audioLength = min(replacementAudio.duration, insertionTime.seconds)
        if audioLength > 0,
           let audio = composition.addMutableTrack(
               withMediaType: .audio,
               preferredTrackID: kCMPersistentTrackID_Invalid
           ) {
            try audio.insertTimeRange(
                CMTimeRange(
                    start: .zero,
                    duration: CMTime(seconds: audioLength, preferredTimescale: 600)
                ),
                of: replacementAudio.track,
                at: .zero
            )
        }
        return composition
    }

    /// Lays the rendered typing-sound track from zero over `asset`, which is
    /// already on the edited timeline. Returns the new asset and the added
    /// track's ID so gain for the recording's own audio can leave it alone.
    static func addingTypingTrack(
        _ typingTrack: AVAssetTrack,
        duration typingDuration: TimeInterval,
        to asset: AVAsset,
        editorDuration: TimeInterval
    ) throws -> (asset: AVAsset, typingTrackID: CMPersistentTrackID) {
        let composition: AVMutableComposition
        if let existing = asset as? AVMutableComposition {
            composition = existing
        } else {
            composition = AVMutableComposition()
            try composition.insertTimeRange(
                CMTimeRange(start: .zero, duration: CMTime(seconds: editorDuration, preferredTimescale: 600)),
                of: asset,
                at: .zero
            )
        }

        guard let audio = composition.addMutableTrack(
            withMediaType: .audio,
            preferredTrackID: kCMPersistentTrackID_Invalid
        ) else {
            return (composition, kCMPersistentTrackID_Invalid)
        }
        let length = min(typingDuration, editorDuration)
        if length > 0 {
            try audio.insertTimeRange(
                CMTimeRange(start: .zero, duration: CMTime(seconds: length, preferredTimescale: 48_000)),
                of: typingTrack,
                at: .zero
            )
        }
        return (composition, audio.trackID)
    }
}
