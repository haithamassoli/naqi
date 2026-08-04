import AVFoundation
import CoreMedia
import CoreVideo
import Foundation
import os

/// Pass 2: decode → censor → encode, driven by the EDL.
///
/// The loop is encoder-paced. `pump` only asks for a frame while the writer
/// wants one, so nothing buffers and the effect can never run ahead of
/// VideoToolbox — which is also why the effect must stay cheap enough not to
/// become the pacer itself.
enum RenderPass {

    struct Result: Sendable {
        let frames: Int
        /// Frames that actually went through Core Image. The rest went to the
        /// encoder as the decoder handed them over.
        let censoredFrames: Int
        let wallMs: Double
        var framesPerSecond: Double { wallMs > 0 ? Double(frames) * 1000 / wallMs : 0 }
    }

    /// Renders `source` through the censor and writes one MP4 at `output`.
    ///
    /// - Parameter replacedAudio: **the both-ops seam.** A file the audio pass
    ///   has already finished writing, whose *first audio track* replaces the
    ///   source's. It is copied compressed, so it must already be in a
    ///   mux-compatible codec (AAC in `.m4a`/`.mp4`) — this pass never decodes
    ///   or re-encodes an audio sample. `nil` means censor-only: the source's
    ///   own audio track is copied instead, bit-identically.
    /// - Parameter edl: Consumed through `Edl.fullFrame(at:)` / `regions(at:)`,
    ///   so the whole-frame-beats-regions precedence rule is honoured by the
    ///   EDL itself, not re-derived here.
    static func run(source: MediaSource,
                    edl: Edl,
                    ops: FilterOps,
                    output: URL,
                    replacedAudio: URL? = nil,
                    progress: (@Sendable (Double) -> Void)? = nil,
                    isCancelled: @escaping @Sendable () -> Bool = { false }) async throws -> Result {
        guard let v = source.video else { throw MediaError.noVideoTrack }
        let asset = AVURLAsset(url: source.url, options: [
            AVURLAssetPreferPreciseDurationAndTimingKey: true,
        ])
        // `AVAssetTrack.asset` is **weak** and `TrackReader` reads it back to
        // build its `AVAssetReader`. Nothing below this line touches `asset`
        // again, so an optimised build is free to release it the moment the
        // track loads — and then the reader fails with "track has no asset"
        // in Release only. Same guard as the replacement asset further down.
        defer { withExtendedLifetime(asset) {} }
        guard let videoTrack = try await asset.loadTracks(withMediaType: .video).first else {
            throw MediaError.noVideoTrack
        }

        let writer = try OutputWriter(url: output)
        writer.addEncodedVideo(v, bitrate: EncodeSettings.resolveBitrate(v))

        // `AVAssetTrack.asset` is weak and `TrackReader` reads it back, so the
        // replacement's asset has to outlive the pump — hence the local.
        var replacementAsset: AVURLAsset?
        defer { withExtendedLifetime(replacementAsset) {} }
        var audioTrack: AVAssetTrack?
        if let replacedAudio {
            let replacement = try await MediaSource.probe(replacedAudio)
            let ra = AVURLAsset(url: replacedAudio)
            replacementAsset = ra
            guard let info = replacement.audio,
                  let t = try await ra.loadTracks(withMediaType: .audio).first
            else { throw MediaError.noAudioTrack }
            writer.addPassthroughAudio(info)
            audioTrack = t
        } else if let info = source.audio,
                  let t = try await asset.loadTracks(withMediaType: .audio).first {
            writer.addPassthroughAudio(info)
            audioTrack = t
        }
        try writer.start()

        let effect = CensorEffect(ops: ops, transform: v.transform, tonemapHDR: v.isHDR)
        Log.render.info("""
            render \(Int(v.naturalSize.width))x\(Int(v.naturalSize.height)) \
            rot=\(v.transform.rotationDegrees) hdr=\(v.isHDR) \
            blur=\(ops.blurAmount)(sigma \(effect.plan.sigmaPx, format: .fixed(precision: 1))px \
            /\(effect.plan.downscale)) gray=\(ops.grayscale) \
            audio=\(replacedAudio == nil ? "passthrough" : "replaced", privacy: .public)
            """)

        // AVFoundation objects are not Sendable but each is touched by exactly
        // one of the two child tasks below; the writer itself is thread-safe.
        nonisolated(unsafe) let vt = videoTrack
        nonisolated(unsafe) let at = audioTrack
        nonisolated(unsafe) let out = writer
        nonisolated(unsafe) let audioIn = writer.audioInput

        let stage = Stage("render")
        do {
            async let video = renderVideo(track: vt, writer: out, edl: edl, effect: effect,
                                          duration: source.duration, progress: progress,
                                          isCancelled: isCancelled)
            async let audio: Void = copyAudio(at, into: audioIn, isCancelled: isCancelled)
            let (counts, _) = try await (video, audio)
            try await out.finish()

            let r = Result(frames: counts.frames, censoredFrames: counts.censored,
                           wallMs: stage.elapsedMs)
            stage.stop("\(r.frames) frames (\(r.censoredFrames) censored) "
                + "\(String(format: "%.1f", r.framesPerSecond)) fps")
            return r
        } catch {
            // Cancel removes the partial file; the PRD requires that on every
            // failure path, not just user cancellation.
            out.cancel()
            throw error
        }
    }

    private static func renderVideo(track: AVAssetTrack,
                                    writer: OutputWriter,
                                    edl: Edl,
                                    effect: CensorEffect,
                                    duration: CMTime,
                                    progress: (@Sendable (Double) -> Void)?,
                                    isCancelled: @escaping @Sendable () -> Bool)
    async throws -> (frames: Int, censored: Int) {
        guard let input = writer.videoInput, let adaptor = writer.pixelAdaptor else {
            throw MediaError.writerFailed("video input not configured")
        }
        let reader = try TrackReader.decodedVideo(track: track)
        try reader.start()

        nonisolated(unsafe) let r = reader
        nonisolated(unsafe) let sink = adaptor
        let counts = Confined((frames: 0, censored: 0))
        let total = duration.seconds

        try await pump(input, label: "video") {
            if isCancelled() { throw MediaError.cancelled }
            guard let sb = r.next() else {
                try r.throwIfFailed()
                return false
            }
            guard let src = CMSampleBufferGetImageBuffer(sb) else {
                throw MediaError.readerFailed("frame \(counts.v.frames) carries no image buffer")
            }
            let pts = CMSampleBufferGetPresentationTimeStamp(sb)
            // The EDL is in whole milliseconds. Truncate rather than round, so a
            // frame lands in the same interval Android's integer `us / 1000`
            // put it in.
            let ms = pts.value * 1000 / Int64(pts.timescale)
            let full = edl.fullFrame(at: ms)
            let regions = full ? [] : edl.regions(at: ms)

            if effect.needsRender(wholeFrame: full, regions: regions) {
                guard let pool = sink.pixelBufferPool else {
                    throw MediaError.writerFailed("adaptor has no pixel buffer pool")
                }
                var dst: CVPixelBuffer?
                guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &dst) == kCVReturnSuccess,
                      let dst else {
                    throw MediaError.writerFailed("pixel buffer pool exhausted at frame \(counts.v.frames)")
                }
                effect.render(src, to: dst, wholeFrame: full, regions: regions)
                guard sink.append(dst, withPresentationTime: pts) else {
                    throw MediaError.writerFailed("append censored frame \(counts.v.frames)")
                }
                counts.v.censored += 1
            } else {
                // Nothing to censor here: the decoder's own buffer goes straight
                // to the encoder. No Core Image, no pool allocation, no copy.
                guard sink.append(src, withPresentationTime: pts) else {
                    throw MediaError.writerFailed("append frame \(counts.v.frames)")
                }
            }
            counts.v.frames += 1
            if let progress, total > 0, counts.v.frames % 30 == 0 {
                progress(min(1, pts.seconds / total))
            }
            return true
        }
        return counts.v
    }

    private static func copyAudio(_ track: AVAssetTrack?,
                                  into input: AVAssetWriterInput?,
                                  isCancelled: @escaping @Sendable () -> Bool) async throws {
        guard let track, let input else { return }
        try await copyTrackPassthrough(track: track, into: input, label: "audio",
                                       isCancelled: isCancelled)
    }
}
