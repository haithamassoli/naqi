import AVFoundation
import Foundation
import os

/// Runs ONE job end to end.
///
/// Everything below is orchestration: the analyze, separate and render passes
/// are called, never reimplemented. What lives here is the shape dispatch, the
/// concurrency contract between the two branches, the checkpoint/resume ledger,
/// and the cancellation rules.
enum JobRunner {

    /// Why a run stopped short.
    ///
    /// **A stop is not automatically a cancel.** An expired iOS background
    /// grace, a jetsam kill and a reboot all arrive the same way, and those are
    /// exactly the cases resume exists to survive. Only `.userCancelled`
    /// destroys the work directory.
    enum Stop: String, Codable, Sendable, Equatable {
        case userCancelled, interrupted
    }

    struct Completion: Sendable {
        let output: Published
        let shape: Job.Shape
        /// Stages a checkpoint let this run skip entirely.
        let resumed: Set<Job.Stage>
        let wallMs: Double
    }

    /// How often the cancel poll is bridged into a pass that only observes task
    /// cancellation. One sampled analyze frame is ~100 ms, so this is well
    /// inside the "at most one chunk" latency the PRD allows.
    static let cancelPollMs = 200

    /// - Parameter stop: polled from the pipelines' own queues, so it must be
    ///   cheap and thread-safe. Non-nil means "wind up now".
    static func run(_ job: Job,
                    progress: @escaping @Sendable (JobProgress) -> Void = { _ in },
                    stop: @escaping @Sendable () -> Stop? = { nil }) async throws -> Completion {
        // The head of a run is the only place that always executes, including
        // after a relaunch that went straight into a resumed job, so the
        // age-based sweep hangs off it.
        Checkpoint.sweepStale()

        guard job.ops.isValid else { throw JobFailure.nothingSelected }
        let (url, close) = try job.openSource()
        defer { close() }

        let src = try await MediaSource.probe(url)
        let durationMs = src.duration.isNumeric ? Int64(src.duration.seconds * 1000) : 0

        // Per-segment video resume needs a time-ranged analyze *and* render
        // plus a compressed-segment concat. `FrameSampler` already takes
        // `startMs`/`endMs`; `AnalyzePass`, `RenderPass` and the muxer do not.
        // Until they do, every length runs the already-device-verified
        // unsegmented route and resume is stage-level, not segment-level.
        let shape = Job.shape(ops: job.ops, hasVideoTrack: src.video != nil, segmented: false)

        if let failure = await Preflight.check(source: src, ops: job.ops,
                                               segmented: shape == .segmented) {
            throw JobFailure.of(failure)
        }

        // An `.m4a` in the photo library is invisible to every music player,
        // which is the only app that would want it (§5.1); Photos will not take
        // it at all. Audio-only output needs a Files destination.
        if shape == .audioOnly, job.destination == .photos {
            throw JobFailure.publishFailed
        }

        let key = Checkpoint.key(source: url, ops: job.ops)
        let dir = WorkDir.job(key)
        let ext = shape == .audioOnly ? "m4a" : "mp4"
        let out = dir.appendingPathComponent("out.\(ext)")
        // A leftover from an attempt that died between the writer finishing and
        // the publish is not a checkpoint — nothing marks it complete.
        try? FileManager.default.removeItem(at: out)

        let bar = OSAllocatedUnfairLock(initialState: JobProgress(shape: shape,
                                                                  removeMusic: job.ops.removeMusic))
        @Sendable func post(_ stage: Job.Stage, _ sub: Double) {
            progress(bar.withLock { p in p.post(stage, sub); return p })
        }
        @Sendable func stopping() -> Bool { stop() != nil }

        let resumed = OSAllocatedUnfairLock<Set<Job.Stage>>(initialState: [])
        let started = ContinuousClock.now
        let stage = Stage("job")
        Log.job.info("""
            start \(shape.rawValue, privacy: .public) key=\(key, privacy: .public) \
            dur=\(durationMs)ms music=\(job.ops.removeMusic) censor=\(job.ops.censor)
            """)

        do {
            switch shape {
            case .censorOnly:
                let edl = try await resolveEdl(src, ops: job.ops, dir: dir, resumed: resumed,
                                               post: post, isCancelled: stopping)
                _ = try await RenderPass.run(source: src, edl: edl, ops: job.ops, output: out,
                                             progress: { post(.render, $0) },
                                             isCancelled: stopping)

            case .musicOnly, .audioOnly:
                // The container tail (`finishWriting`) happens inside
                // `removeMusic`, so `mux` closes in one step when it returns.
                _ = try await AudioPipeline.removeMusic(src, to: out, keepStems: job.ops.keepStems,
                                                        includeVideo: shape == .musicOnly,
                                                        progress: { post(.separate, $0) },
                                                        isCancelled: stopping)
                post(.mux, 1)

            case .combined, .segmented:
                let audio = dir.appendingPathComponent(Checkpoint.audioTrackName)
                let edl = try await bothBranches(src, ops: job.ops, dir: dir, audio: audio,
                                                 resumed: resumed, post: post, stop: stop)
                // Render *is* the mux here: the separated track is copied in
                // compressed while the picture is encoded, so there is no
                // second full-size pass the way Android's `mux.mp4` was.
                _ = try await RenderPass.run(source: src, edl: edl, ops: job.ops, output: out,
                                             replacedAudio: audio,
                                             progress: { post(.render, $0) },
                                             isCancelled: stopping)
                post(shape == .segmented ? .concat : .mux, 1)
            }

            if stopping() { throw MediaError.cancelled }
            post(.publish, 0)
            let published = try await Publish.save(out, named: outputName(for: url, ext: ext),
                                                   to: job.destination, folder: job.folder)
            post(.publish, 1)
            // Success takes the whole directory: the checkpoints only exist to
            // survive an interruption, and this run had none.
            WorkDir.clear(key)

            let wall = msSince(started)
            stage.stop("\(shape.rawValue) \(Int(wall))ms resumed=\(resumed.withLock { $0.count })")
            return Completion(output: published, shape: shape,
                              resumed: resumed.withLock { $0 }, wallMs: wall)

        } catch {
            // No partial output file survives any failure path, not just a
            // user cancel.
            try? FileManager.default.removeItem(at: out)
            let reason = stop()
            let resumable = reason != .userCancelled && hasResumableWork(dir: dir)
            if !resumable { WorkDir.clear(key) }
            stage.stop("\(shape.rawValue) stopped")
            if let reason {
                Log.job.notice("""
                    job \(shape.rawValue, privacy: .public) \(reason.rawValue, privacy: .public) \
                    resumable=\(resumable)
                    """)
                throw JobStopped(reason: reason, resumable: resumable)
            }
            // The cause is logged in full here and nowhere else; what reaches
            // the screen is a case, never this text.
            Log.job.error("""
                job \(shape.rawValue, privacy: .public) failed: \
                \(String(describing: error), privacy: .public) resumable=\(resumable)
                """)
            throw JobFailure.of(error)
        }
    }

    /// Anything short of a user cancel keeps the work directory when it holds
    /// something the next attempt can reuse. Android keyed this off the shape
    /// and the 30-minute threshold (§2.10) because below that nothing was ever
    /// checkpointed; the unsegmented Apple route checkpoints the finished EDL
    /// and the separated audio track at any length, so the test is "is there
    /// anything there", not "is it long".
    static func hasResumableWork(dir: URL) -> Bool {
        let fm = FileManager.default
        if fm.fileExists(atPath: dir.appendingPathComponent(Checkpoint.analysisName).path) { return true }
        if fm.fileExists(atPath: dir.appendingPathComponent(Checkpoint.audioTrackName).path) { return true }
        return Checkpoint.hasRenderedSegments(dir: dir)
    }

    // MARK: - Branches

    /// analyze ‖ separate, then hand the EDL to the render that muxes them.
    ///
    /// Failure semantics come from the structure: whichever branch throws first
    /// wins, the shared abort flag releases the other one (its pump loop polls
    /// a flag, not task cancellation), and the group rethrows the original
    /// cause so the failure taxonomy sees the real error.
    private static func bothBranches(_ src: MediaSource, ops: FilterOps, dir: URL, audio: URL,
                                     resumed: OSAllocatedUnfairLock<Set<Job.Stage>>,
                                     post: @escaping @Sendable (Job.Stage, Double) -> Void,
                                     stop: @escaping @Sendable () -> Stop?) async throws -> Edl {
        let fm = FileManager.default
        let haveAudio = fm.fileExists(atPath: audio.path)
        let cached = Checkpoint.readEdl(dir: dir)
        if haveAudio { resumed.withLock { _ = $0.insert(.separate) }; post(.separate, 1) }
        if cached != nil { resumed.withLock { _ = $0.insert(.analyze) }; post(.analyze, 1) }
        if haveAudio, let cached { return cached }

        let edl = OSAllocatedUnfairLock<Edl?>(initialState: cached)
        let failed = OSAllocatedUnfairLock(initialState: false)
        @Sendable func aborted() -> Bool { stop() != nil || failed.withLock { $0 } }

        try await withThrowingTaskGroup(of: Void.self) { group in
            if !haveAudio {
                // QoS is the Apple-only dial Android could not reach, and the
                // highest impact-per-line item in `spec-performance.md` §1.4:
                // htdemucs is the wall on this shape with the video branch
                // sitting on hundreds of seconds of slack, so the audio branch
                // takes `.userInitiated` …
                group.addTask(priority: .userInitiated) {
                    try await separate(src, ops: ops, to: audio, includeVideo: false,
                                       progress: { post(.separate, $0) }, isCancelled: aborted)
                }
            }
            if cached == nil {
                // … and the video branch takes `.utility`, which biases it onto
                // the E-cores so it *cannot* steal a P-core from ORT. Android
                // measured 47 % of an expected saving eaten by exactly this
                // contention, with no way to arbitrate it. The video branch
                // getting slower is free.
                group.addTask(priority: .utility) {
                    post(.analyze, 0)
                    let r = try await analyze(src, ops: ops, isCancelled: aborted)
                    edl.withLock { $0 = r }
                    post(.analyze, 1)
                }
            }
            // The pump loops do not observe task cancellation, so the abort
            // flag has to be raised before waiting on the sibling or a failure
            // on one side hangs the group.
            var first: (any Error)?
            while !group.isEmpty {
                do { try await group.next() }
                catch {
                    if first == nil { first = error }
                    failed.withLock { $0 = true }
                }
            }
            if let first { throw first }
        }

        guard let result = edl.withLock({ $0 }) else { throw MediaError.cancelled }
        try Checkpoint.writeEdl(result, dir: dir)
        return result
    }

    private static func resolveEdl(_ src: MediaSource, ops: FilterOps, dir: URL,
                                   resumed: OSAllocatedUnfairLock<Set<Job.Stage>>,
                                   post: @escaping @Sendable (Job.Stage, Double) -> Void,
                                   isCancelled: @escaping @Sendable () -> Bool) async throws -> Edl {
        if let cached = Checkpoint.readEdl(dir: dir) {
            resumed.withLock { _ = $0.insert(.analyze) }
            post(.analyze, 1)
            return cached
        }
        post(.analyze, 0)
        let edl = try await analyze(src, ops: ops, isCancelled: isCancelled)
        try Checkpoint.writeEdl(edl, dir: dir)
        post(.analyze, 1)
        return edl
    }

    /// `AnalyzePass` observes task cancellation but takes no polled flag, so
    /// the poll is bridged: a sibling task watches the flag and throws, which
    /// cancels the analyze child at its next `Task.checkCancellation()`.
    private static func analyze(_ src: MediaSource, ops: FilterOps,
                                isCancelled: @escaping @Sendable () -> Bool) async throws -> Edl {
        if isCancelled() { throw MediaError.cancelled }
        return try await withThrowingTaskGroup(of: Edl?.self) { group in
            group.addTask { try await AnalyzePass.run(src, ops: ops).edl }
            group.addTask {
                while !Task.isCancelled {
                    if isCancelled() { throw MediaError.cancelled }
                    try await Task.sleep(for: .milliseconds(cancelPollMs))
                }
                return nil
            }
            while let next = try await group.next() {
                if let edl = next {
                    group.cancelAll()
                    return edl
                }
            }
            throw MediaError.cancelled
        }
    }

    /// Written to `<name>.part` and renamed: a file existing under its final
    /// name *means* it is complete, which is the whole atomicity story the
    /// checkpoint layer rests on — no manifest, and no way to reference a
    /// half-written track.
    private static func separate(_ src: MediaSource, ops: FilterOps, to url: URL,
                                 includeVideo: Bool,
                                 progress: @escaping @Sendable (Double) -> Void,
                                 isCancelled: @escaping @Sendable () -> Bool) async throws {
        let part = url.appendingPathExtension("part")
        try? FileManager.default.removeItem(at: part)
        _ = try await AudioPipeline.removeMusic(src, to: part, keepStems: ops.keepStems,
                                                includeVideo: includeVideo,
                                                progress: progress, isCancelled: isCancelled)
        try? FileManager.default.removeItem(at: url)
        try FileManager.default.moveItem(at: part, to: url)
    }
}
