import AVFoundation
import CoreMedia
import Foundation
import os

/// Container surgery: joining tracks and joining files, never touching a sample.
///
/// Both operations are an `AVMutableComposition` plus a passthrough export.
/// Hand-rolling an `AVAssetWriter` loop would work and is what `RenderPass`
/// does, but there it earns its keep — it needs per-frame PTS and a cancel
/// point. Here there is nothing to see per frame: the composition already
/// expresses "these samples, in this order", and `AVAssetExportPresetPassthrough`
/// is the documented way to say "do not re-encode". The loop version would be
/// forty lines that can get the PTS offset wrong.
enum Remux {

    /// A passthrough export that loses a whole segment writes a short file and
    /// reports success. Compare against what the composition said it was and
    /// fail loudly instead. One second absorbs edit-list rounding at the joins;
    /// the failure this catches is measured in minutes.
    private static let durationSlackSeconds = 1.0

    /// Video track of `video` + audio track of `audio`, compressed passthrough.
    ///
    /// This is what makes a music-removal job resumable: the render (or the
    /// untouched source) and the separated `.m4a` are two checkpoints on disk,
    /// and this joins them in a pass that costs no encode. `spec-render.md` §4.2
    /// measured what re-encoding audio here would cost on a non-AAC source —
    /// 12.9 s per 193 s track, ~10 min on a film, all of it thrown away.
    static func mux(video: URL, audio: URL, to output: URL) async throws {
        let vAsset = AVURLAsset(url: video)
        let aAsset = AVURLAsset(url: audio)
        // `AVAssetTrack.asset` is weak and the composition reads it back while
        // inserting; nothing else below mentions these, so a release build is
        // free to drop them without the locals.
        defer { withExtendedLifetime((vAsset, aAsset)) {} }

        guard let srcV = try await vAsset.loadTracks(withMediaType: .video).first else {
            throw MediaError.noVideoTrack
        }
        guard let srcA = try await aAsset.loadTracks(withMediaType: .audio).first else {
            throw MediaError.noAudioTrack
        }

        let composition = AVMutableComposition()
        guard let dstV = composition.addMutableTrack(withMediaType: .video,
                                                     preferredTrackID: kCMPersistentTrackID_Invalid),
              let dstA = composition.addMutableTrack(withMediaType: .audio,
                                                     preferredTrackID: kCMPersistentTrackID_Invalid)
        else { throw MediaError.writerFailed("composition would not take a track") }

        let (vRange, vTransform, aRange) = try await (srcV.load(.timeRange),
                                                      srcV.load(.preferredTransform),
                                                      srcA.load(.timeRange))
        try dstV.insertTimeRange(vRange, of: srcV, at: .zero)
        try dstA.insertTimeRange(aRange, of: srcA, at: .zero)
        // Rotation lives in the track matrix, not in the pixels. Dropping it
        // here is the failure that plays a portrait film sideways while every
        // frame in it is correct.
        dstV.preferredTransform = vTransform

        Log.media.info("""
            mux \(vRange.duration.seconds, format: .fixed(precision: 2))s video \
            + \(aRange.duration.seconds, format: .fixed(precision: 2))s audio \
            -> \(output.lastPathComponent, privacy: .public)
            """)
        try await export(composition, to: output)
    }

    /// Same-codec segments concatenated in order, compressed passthrough.
    ///
    /// The single-format-per-track rule is why `EncodeSettings.resolveBitrate`
    /// is resolved once per job and hoisted out of the segment loop, and why
    /// there is no per-segment transmux fast path: a container can hold one
    /// sample description per track, so a segment that skipped the encoder and
    /// one that did not cannot be joined (`spec-render.md` §4.1).
    static func concat(_ segments: [URL], to output: URL) async throws {
        guard !segments.isEmpty else { throw MediaError.readerFailed("concat of nothing") }

        let composition = AVMutableComposition()
        guard let dstV = composition.addMutableTrack(withMediaType: .video,
                                                     preferredTrackID: kCMPersistentTrackID_Invalid)
        else { throw MediaError.writerFailed("composition would not take a track") }
        // ponytail: one audio track, inserted only where a segment has one. The
        // shipped segmented route renders picture only (`RenderPass.run(range:)`)
        // so this never fires; a segment set that mixed silent and voiced parts
        // would concatenate its audio end-to-end with no gap for the silent
        // stretches, which is wrong. Upgrade path when that shape exists:
        // `insertEmptyTimeRange` for every segment with no audio track.
        var dstA: AVMutableCompositionTrack?

        var cursor = CMTime.zero
        for url in segments {
            let asset = AVURLAsset(url: url)
            defer { withExtendedLifetime(asset) {} }
            guard let v = try await asset.loadTracks(withMediaType: .video).first else {
                throw MediaError.noVideoTrack
            }
            let vRange = try await v.load(.timeRange)
            try dstV.insertTimeRange(vRange, of: v, at: cursor)
            if cursor == .zero { dstV.preferredTransform = try await v.load(.preferredTransform) }

            if let a = try await asset.loadTracks(withMediaType: .audio).first {
                if dstA == nil {
                    dstA = composition.addMutableTrack(withMediaType: .audio,
                                                       preferredTrackID: kCMPersistentTrackID_Invalid)
                }
                guard let dstA else {
                    throw MediaError.writerFailed("composition would not take an audio track")
                }
                try dstA.insertTimeRange(try await a.load(.timeRange), of: a, at: cursor)
            }
            // Advance by the *video* range, which is the segment's spine. Taking
            // the composition's own end instead would let a track that ran long
            // push the next segment's picture out of sync with its own.
            cursor = CMTimeAdd(cursor, vRange.duration)
        }

        Log.media.info("""
            concat \(segments.count) segments \
            = \(cursor.seconds, format: .fixed(precision: 2))s \
            -> \(output.lastPathComponent, privacy: .public)
            """)
        try await export(composition, to: output)
    }

    // MARK: - Export

    private static func export(_ composition: AVMutableComposition, to output: URL) async throws {
        try? FileManager.default.removeItem(at: output)
        guard let session = AVAssetExportSession(asset: composition,
                                                 presetName: AVAssetExportPresetPassthrough) else {
            throw MediaError.writerFailed("no passthrough export session")
        }
        try await session.export(to: output, as: .mp4)

        // The expensive silent failure is a short output — one segment written,
        // the rest dropped — because the export reports success either way.
        let expected = composition.duration.seconds
        let got = try await AVURLAsset(url: output).load(.duration).seconds
        guard got >= expected - durationSlackSeconds else {
            try? FileManager.default.removeItem(at: output)
            throw MediaError.writerFailed(
                "passthrough wrote \(String(format: "%.2f", got))s of \(String(format: "%.2f", expected))s")
        }
    }
}
