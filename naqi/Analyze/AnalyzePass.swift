import AVFoundation
import CoreMedia
import Foundation
import os

/// What one analyze pass produced, plus the counters the perf wall is read from.
struct AnalyzeResult: Sendable {
    let edl: Edl
    let decodedFrames: Int
    let sampledFrames: Int
    let gateFrames: Int
    let firings: Int
    let wallMs: Double

    var msPerSampledFrame: Double { sampledFrames > 0 ? wallMs / Double(sampledFrames) : 0 }
    var decodedFramesPerSecond: Double { wallMs > 0 ? Double(decodedFrames) * 1000 / wallMs : 0 }
}

/// Pass 1: one sequential decode feeding two consumers — the NSFW whole-frame
/// gate and the face tracker — emitting one `Edl`. Pass 2 consumes only the
/// `Edl`; nothing else crosses the boundary.
///
/// **This pass is deliberately NOT segmented, and must not become so.**
/// `RenderPass` takes a source-time window because a rendered segment is a
/// standalone file that concatenates; an analyzed segment is not the same kind
/// of thing. A 5-minute cut lands in the middle of face tracks, and the two
/// halves of a split track take their gender votes from different samples —
/// they can reach *opposite* verdicts, so the same face is censored either side
/// of the seam and bare in between. The hysteresis (§3) and the whole-frame
/// floor (§7) also span seams, which is why Android's own per-segment file
/// stored bare tracks and rebuilt intervals globally. Analyze is also
/// the cheaper of the two passes — 10 fps sampling against the render's every
/// frame — so what a resume loses here is worth less than the correctness it
/// would cost. Stage-level resume (`Checkpoint.writeEdl`, one finished EDL) is
/// the right trade and the one this port ships.
enum AnalyzePass {

    /// - Parameter progress: 0...1 of **this pass only**; the caller maps it
    ///   into its own band. Reported from the real decode position, the same
    ///   way `RenderPass` does it.
    /// - Parameter isCancelled: polled once per sampled frame — the same
    ///   granularity `RenderPass` polls at — and answered with
    ///   `CancellationError`, which is what `FrameSampler` already throws, so
    ///   every caller unwinds through one path.
    static func run(_ source: MediaSource, ops: FilterOps,
                    progress: (@Sendable (Double) -> Void)? = nil,
                    isCancelled: @escaping @Sendable () -> Bool = { false }) async throws -> AnalyzeResult {
        guard let video = source.video else { throw MediaError.noVideoTrack }
        let asset = AVURLAsset(url: source.url)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            throw MediaError.noVideoTrack
        }
        // `AVAssetTrack.asset` is a **weak** reference and nothing below touches
        // `asset` again, so ARC is free to release it right here — a release
        // build will. `TrackReader` then throws "track has no asset" and the
        // whole pass fails on a line that reads as if it could not.
        defer { withExtendedLifetime(asset) {} }
        // Unknown duration is `max`, never a small positive number — see
        // `NsfwGate.intervals`.
        let durationMs = source.duration.isNumeric
            ? source.duration.convertScale(1000, method: .default).value
            : .max

        // A build without genderage degrades every track to "no vote", which
        // means censor — safe, and the only signal is this log line (§11.6).
        let voter = ops.who.skipsGenderVote
            ? nil
            : (try? ModelRegistry.model(Models.GenderAge.file)).map(GenderVote.init)
        if voter == nil, !ops.who.skipsGenderVote {
            Log.analyze.notice("genderage unavailable: every track abstains, i.e. censors")
        }

        let tracker = FaceTracker(who: ops.who)
        let detector = await FaceDetector.resolve()
        let batch: GateBatch?
        if ops.censorNsfw {
            // Android's own sweep peaked at 2 intra-op threads (20.1 / 47.8 /
            // 42.3 / 19.5 inferences per second at 1 / 2 / 4 / 8, §8.3).
            let gate = try ModelRegistry.model(Models.Nsfw.file, threads: 2)
            // Batch 1: §10.16 forbids batching the gate, and the Apple
            // measurement agreed (see `GateBatch`).
            batch = GateBatch(model: gate, strictness: ops.strictness, size: 1)
        } else {
            batch = nil
        }
        let sampler = try FrameSampler(track: track, transform: video.transform,
                                       gateEnabled: ops.censorNsfw)

        // `RenderPass` throttles to every 30th frame, which at a 30 fps source is
        // one report per second of picture. This pass decodes at `sampleFPS`, so
        // the same one-report-per-source-second cadence is every `sampleFPS`-th
        // *sampled* frame. Copying the literal 30 instead would tick a third as
        // often here and read as a stalled bar on the longer of the two stages.
        let reportEvery = max(1, Int(AnalyzeConstants.sampleFPS.rounded()))
        // `durationMs` is `.max` when the container will not say, and dividing
        // by it would peg the bar at 0 for the whole film — report nothing then
        // and let the terminal 1.0 close the band.
        let knownDurationMs = (durationMs > 0 && durationMs != .max) ? Double(durationMs) : 0
        var seen = 0
        var detectFailures = DetectFailures()

        // `Stage` carries the signpost; the wall is measured here as well
        // because `AnalyzeResult` reports it to the caller, not just to the log.
        let started = ContinuousClock.now
        let stage = Stage("analyze")
        let stats = try await sampler.run { frame in
            // Polled per sampled frame, exactly where `RenderPass` polls, and
            // answered with the error `FrameSampler` already throws so a polled
            // cancel and a task cancel are indistinguishable to the caller.
            if isCancelled() { throw CancellationError() }
            try Task.checkCancellation()
            if let progress, knownDurationMs > 0, seen % reportEvery == 0 {
                progress(min(1, max(0, Double(frame.ptsMs) / knownDurationMs)))
            }
            seen += 1
            // Detection and the gate overlap; the await stays inside this call
            // so the frame's pool slot survives both (§1.5, §2.5).
            async let detected = detector.detect(frame)
            if let g = frame.gate { try batch?.add(ptsMs: frame.ptsMs, tensor: g) }
            // A detector failure is per-frame and survivable; see
            // `DetectFailures` for why it is survivable only up to a point.
            let boxes: [CGRect]
            do {
                boxes = try await detected
                detectFailures.succeeded()
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                // Rethrown unchanged, so the job's recorded cause stays the
                // real Vision error rather than a counter tripping.
                if detectFailures.failed() { throw error }
                Log.analyze.warning("""
                    detect failed at \(frame.ptsMs) ms, skipping frame \
                    (\(detectFailures.total) so far): \(String(describing: error), privacy: .public)
                    """)
                boxes = []
            }
            tracker.onFaces(boxes, uprightSize: frame.transform.uprightSize, ptsMs: frame.ptsMs) { rect in
                voter?.vote(in: frame, rect: rect) ?? 0
            }
        }
        // Before `batch.flush`, because an unusable detector must not look like
        // a completed pass that merely found no faces.
        if detectFailures.exceededRate(sampled: stats.emitted) {
            throw AnalyzeError.detectorUnusable(failed: detectFailures.total, of: stats.emitted)
        }
        try batch?.flush()
        // The last sampled frame sits up to one sample interval short of the
        // duration, and on a stage that feeds a progress band "97 %" is a stage
        // that never finished. Closing at exactly 1.0 is the caller's signal
        // that the band is complete, so it is stated rather than approached.
        progress?(1)
        let wallMs = msSince(started)
        let faceTracks = tracker.finish()

        // In region mode this is the plain concatenation — only the whole-frame
        // path merges (§6.3 rule 2).
        let firings = batch?.firings ?? []
        var intervals = NsfwGate.intervals(firings, durationMs: durationMs)
            + overflowSpans(faceTracks)
        if ops.censorMode == .wholeFrame {
            intervals = promoteToWholeFrame(intervals, tracks: faceTracks)
        }

        stage.stop("""
            \(stats.decoded) decoded, \(stats.emitted) sampled, \(stats.gated) gated, \
            \(firings.count) firings, \(faceTracks.count) tracks, \(intervals.count) intervals\
            \(detectFailures.total > 0 ? ", \(detectFailures.total) detect failures" : "")
            """)
        return AnalyzeResult(edl: Edl(censorIntervalsMs: intervals, faceTracks: faceTracks),
                             decodedFrames: stats.decoded,
                             sampledFrames: stats.emitted,
                             gateFrames: stats.gated,
                             firings: firings.count,
                             wallMs: wallMs)
    }

    // MARK: - EDL assembly (pure, unit-tested without a decoder)

    /// Bridges gaps up to `bridgeMs`. A single range passes through unsorted and
    /// unfiltered, exactly as Android (§7.1).
    static func mergeRanges(_ ranges: [ClosedRange<Int64>],
                            bridgeMs: Int64 = AnalyzeConstants.bridgeMs) -> [ClosedRange<Int64>] {
        guard ranges.count > 1 else { return ranges }
        let sorted = ranges.sorted { $0.lowerBound < $1.lowerBound }
        var out: [ClosedRange<Int64>] = []
        var start = sorted[0].lowerBound, end = sorted[0].upperBound
        for r in sorted.dropFirst() {
            if r.lowerBound <= end + bridgeMs {
                if r.upperBound > end { end = r.upperBound }
            } else {
                out.append(start...end)
                start = r.lowerBound
                end = r.upperBound
            }
        }
        out.append(start...end)
        return out
    }

    /// Whole-frame mode: every gate interval, every overflow span and every
    /// censored face span become one merged timeline.
    ///
    /// The min-duration floor runs **after** the merge, so two blips 300 ms
    /// apart bridge into one surviving span while an isolated 100 ms span dies.
    /// That isolated span is the whole reason the floor exists: a one-sample
    /// false positive — on Android, a cardboard box on a floor — blinks the
    /// entire picture out for 2–3 frames and reads as a decode glitch. Dropping
    /// it costs no coverage, because `regionsAt` then falls back to that track's
    /// own blurred rect (§7.2, §10.10).
    static func promoteToWholeFrame(_ intervals: [ClosedRange<Int64>],
                                    tracks: [FaceTrackEdl]) -> [ClosedRange<Int64>] {
        mergeRanges(intervals + tracks.map { $0.startMs...max($0.startMs, $0.endMs) })
            .filter { $0.upperBound - $0.lowerBound >= AnalyzeConstants.minFullFrameMs }
    }

    /// Spans where more than `Edl.maxRegionsPerFrame` tracks are live at once
    /// are promoted to whole-frame. The renderer composites at most that many
    /// rects and silently drops the **smallest** beyond it — it fails open, on
    /// exactly the frames with the most people (§6.4b).
    ///
    /// This counts track *lifetimes*, so it slightly over-counts against
    /// `Edl.regions(at:)`; over-censoring is the safe direction here.
    static func overflowSpans(_ tracks: [FaceTrackEdl]) -> [ClosedRange<Int64>] {
        guard tracks.count > Edl.maxRegionsPerFrame else { return [] }
        var events: [(t: Int64, delta: Int)] = []
        events.reserveCapacity(tracks.count * 2)
        for tr in tracks {
            events.append((tr.startMs, 1))
            events.append((tr.endMs + 1, -1))     // end is inclusive
        }
        events.sort { $0.t < $1.t }

        var out: [ClosedRange<Int64>] = []
        var active = 0
        var from: Int64 = -1
        var i = 0
        while i < events.count {
            let t = events[i].t
            // Apply every delta at one instant before reading `active`, or a
            // simultaneous end-and-start invents a 1 ms gap.
            while i < events.count, events[i].t == t {
                active += events[i].delta
                i += 1
            }
            if active > Edl.maxRegionsPerFrame {
                if from < 0 { from = t }
            } else if from >= 0 {
                out.append(from...(t - 1))
                from = -1
            }
        }
        return out
    }
}

/// Accumulates gate tensors and submits them in one Run.
///
/// The graph's batch dim is dynamic and batched inference is bit-identical to
/// single-frame (`ModelContractTests.nsfwBatch`). It is **not** the win it looks
/// like: on the iPhone 17 Pro simulator over the QA clip's 64 gate tensors,
/// per-frame cost was flat to 6 % worse at every batch size (threads=2:
/// 11.87 / 12.60 / 12.63 / 12.32 ms per frame at batch 1 / 2 / 4 / 8), which
/// reproduces Android's own finding (§10.16) rather than escaping it.
///
/// So `size` ships at **1**, which is what §10.16 requires and what measured
/// fastest here. It also keeps §2.5's per-frame order intact — detect starts,
/// the gate runs on *that* frame, then the faces are awaited — where a batch of
/// 8 skipped the gate on seven frames out of eight and paid 8x on the ninth,
/// with 4.8 MB of tensors parked in the meantime. The mechanism stays because
/// it is three lines and `Models.Nsfw.maxBatch` needs re-measuring on hardware,
/// where the memory hierarchy is not the host's.
private final class GateBatch {
    private let model: OrtModel
    private let strictness: Int
    private let size: Int
    private var pts: [Int64] = []
    private var data: [Float] = []
    private(set) var firings: [Int64] = []

    init(model: OrtModel, strictness: Int, size: Int = 1) {
        self.model = model
        self.strictness = strictness
        self.size = min(max(size, 1), Models.Nsfw.maxBatch)
        data.reserveCapacity(self.size * 3 * Models.Nsfw.side * Models.Nsfw.side)
    }

    func add(ptsMs: Int64, tensor: [Float]) throws {
        pts.append(ptsMs)
        data.append(contentsOf: tensor)
        if pts.count >= size { try flush() }
    }

    func flush() throws {
        guard !pts.isEmpty else { return }
        let n = pts.count, side = Models.Nsfw.side
        let out = try model.run([Models.Nsfw.input: .float(data, shape: [n, 3, side, side])])
        guard let y = out[Models.Nsfw.output] else { throw OrtError.outputMissing(Models.Nsfw.output) }
        let probs = try y.floats()
        let classes = Models.Nsfw.Class.allCases.count
        for i in 0..<n where NsfwGate.fires(Array(probs[i * classes..<(i + 1) * classes]), strictness: strictness) {
            firings.append(pts[i])
        }
        pts.removeAll(keepingCapacity: true)
        data.removeAll(keepingCapacity: true)
    }
}
