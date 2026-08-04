import Testing
import AVFoundation
import Foundation
import os
@testable import naqi

/// M5 exit criteria. The three things that can silently ruin the job layer all
/// fail quietly rather than crashing: a progress bar that walks backwards, a
/// job key that moves and orphans hours of rendered work, and a cancel that
/// leaves a half-written file in the user's library. Each is pinned here
/// against the spec's own numbers rather than against the code that produced
/// them.
@Suite("Jobs", .serialized)
struct JobTests {

    // MARK: - Progress weighting

    static let shapes: [(Job.Shape, Bool)] = [
        (.censorOnly, false), (.musicOnly, true), (.combined, true),
        (.segmented, true), (.segmented, false), (.audioOnly, true),
    ]

    @Test("progress is monotonic, starts at 0 and ends at exactly 1.0",
          arguments: shapes.indices)
    func progressPerShape(i: Int) {
        let (shape, music) = Self.shapes[i]
        var p = JobProgress(shape: shape, removeMusic: music)
        #expect(p.fraction == 0, "\(shape) starts at 0")

        var last = 0.0
        for stage in Job.stages(shape, removeMusic: music) {
            for step in stride(from: 0.0, through: 1.0, by: 0.05) {
                p.post(stage, step)
                #expect(p.fraction >= last, "\(shape)/\(stage)@\(step) went backwards")
                #expect(p.fraction <= 1.0, "\(shape)/\(stage)@\(step) overshot")
                last = p.fraction
            }
        }
        // Exactly, not approximately: a bar that stops at 0.99 reads as a hang
        // on the one screen the user is watching.
        #expect(p.fraction == 1.0, "\(shape) music=\(music) ended at \(p.fraction)")
    }

    /// The arithmetic the spec calls out: the video branch tops out where the
    /// audio share ends, so the tail band starts exactly on their sum.
    @Test("the two shares meet the tail band exactly")
    func shareArithmetic() {
        var combined = JobProgress(shape: .combined, removeMusic: true)
        combined.post(.analyze, 1)
        combined.post(.separate, 1)
        combined.post(.render, 1)
        #expect(combined.pct == 93)

        var segmented = JobProgress(shape: .segmented, removeMusic: true)
        segmented.post(.analyze, 1)
        segmented.post(.separate, 1)
        segmented.post(.render, 1)
        #expect(segmented.pct == 90)

        var censorSegments = JobProgress(shape: .segmented, removeMusic: false)
        censorSegments.post(.analyze, 1)
        censorSegments.post(.render, 1)
        #expect(censorSegments.pct == 90)
    }

    /// A branch that reports out of order — the audio share arriving after the
    /// tail band has started, a resumed stage posting 1 then a live one posting
    /// 0 — must not move the bar down.
    @Test("a late or backwards post cannot lower the bar")
    func progressNeverRegresses() {
        var p = JobProgress(shape: .combined, removeMusic: true)
        p.post(.analyze, 1)
        p.post(.separate, 1)
        p.post(.render, 1)
        p.post(.mux, 1)
        let peak = p.fraction
        p.post(.analyze, 0)
        p.post(.separate, 0)
        p.post(.render, 0.2)
        #expect(p.fraction == peak)
    }

    @Test("shape dispatch order")
    func shapeDispatch() {
        var music = FilterOps(); music.removeMusic = true; music.censor = false
        var censor = FilterOps(); censor.removeMusic = false; censor.censor = true
        var both = FilterOps(); both.removeMusic = true; both.censor = true

        // Detected, not flagged: the source is the only trustworthy statement
        // about which tracks it has.
        #expect(Job.shape(ops: music, hasVideoTrack: false, segmented: false) == .audioOnly)
        #expect(Job.shape(ops: both, hasVideoTrack: false, segmented: false) == .audioOnly)
        #expect(Job.shape(ops: censor, hasVideoTrack: true, segmented: true) == .segmented)
        #expect(Job.shape(ops: both, hasVideoTrack: true, segmented: true) == .segmented)
        #expect(Job.shape(ops: both, hasVideoTrack: true, segmented: false) == .combined)
        #expect(Job.shape(ops: music, hasVideoTrack: true, segmented: false) == .musicOnly)
        #expect(Job.shape(ops: censor, hasVideoTrack: true, segmented: false) == .censorOnly)
    }

    // MARK: - Segment plan

    @Test("the 30-minute gate decides whether a source is segmented at all")
    func planThreshold() {
        #expect(Checkpoint.plan(durationMs: 29 * 60 * 1000).isEmpty)
        #expect(Checkpoint.plan(durationMs: 30 * 60 * 1000 - 1).isEmpty)

        let duration: Int64 = 31 * 60 * 1000
        let long = Checkpoint.plan(durationMs: duration)
        // 31 min / 5 min = 6.2, so 7 segments with a 60 s tail.
        #expect(long.count == 7)
        #expect(long.first?.startMs == 0)
        #expect(long.last?.endMs == duration)
        #expect(long.last?.durationMs == 60_000)

        // A forced length overrides the gate — the debug hook that makes a
        // short clip exercise the segmented route.
        #expect(!Checkpoint.plan(durationMs: 60_000, forcedSegmentMs: 10_000).isEmpty)
        #expect(Checkpoint.plan(durationMs: 0).isEmpty)
        #expect(Checkpoint.plan(durationMs: -1).isEmpty)
    }

    /// A sparse-keyframe source snaps several proposed cuts onto the same
    /// sample. Collapsing them gives fewer, longer segments; not collapsing
    /// them gives a zero-length or inverted clip, which makes the clipper throw.
    @Test("duplicate cuts collapse without producing a zero-length or inverted segment")
    func planCollapsesDuplicateCuts() {
        let duration: Int64 = 31 * 60 * 1000
        let cases: [(String, (Int64) -> Int64)] = [
            // Sync samples 15 minutes apart: three proposed cuts land on each.
            ("coarse-keyframes", { ($0 / 900_000) * 900_000 }),
            // "No sync sample at or after ms" — collapses this and every later cut.
            ("no-sync-sample", { _ in duration }),
            // A source that cannot be seeked by time at all.
            ("unseekable", { _ in 0 }),
            ("identity", { $0 }),
        ]

        for (name, cutAt) in cases {
            let plan = Checkpoint.plan(durationMs: duration, cutAt: cutAt)
            #expect(!plan.isEmpty, "\(name) produced no plan")
            #expect(plan.first?.startMs == 0, "\(name) does not start at 0")
            #expect(plan.last?.endMs == duration, "\(name) does not end at the duration")
            for (i, seg) in plan.enumerated() {
                #expect(seg.index == i, "\(name) index \(seg.index) != \(i)")
                #expect(seg.endMs > seg.startMs,
                        "\(name) segment \(i) is \(seg.startMs)…\(seg.endMs)")
                if i > 0 { #expect(seg.startMs == plan[i - 1].endMs, "\(name) has a gap at \(i)") }
            }
        }
    }

    @Test("resume skips the segments already on disk")
    func completedSegmentsAreSkipped() throws {
        let dir = Fixtures.scratch("jobs-segments")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let plan = Checkpoint.plan(durationMs: 31 * 60 * 1000)
        #expect(Checkpoint.completedSegments(dir: dir, of: plan).isEmpty)
        #expect(!Checkpoint.hasRenderedSegments(dir: dir))

        for i in [0, 1, 4] {
            try Data("x".utf8).write(to: Checkpoint.segmentURL(dir, segment: i))
        }
        #expect(Checkpoint.completedSegments(dir: dir, of: plan) == [0, 1, 4])
        #expect(Checkpoint.hasRenderedSegments(dir: dir))
        #expect(JobRunner.hasResumableWork(dir: dir))
    }

    // MARK: - Job key

    @Test("the job key is stable for identical inputs and moves when any option does")
    func jobKeyIdentity() {
        let url = URL(fileURLWithPath: "/tmp/a movie.mp4")
        let base = FilterOps()
        let key = Checkpoint.key(source: url, ops: base)
        #expect(key.count == 16)
        #expect(key == Checkpoint.key(source: url, ops: base))
        #expect(key == Checkpoint.key(source: URL(fileURLWithPath: "/tmp/a movie.mp4"), ops: base))
        #expect(key != Checkpoint.key(source: URL(fileURLWithPath: "/tmp/b movie.mp4"), ops: base))

        var variants: [FilterOps] = []
        var v = base; v.removeMusic = !base.removeMusic; variants.append(v)
        v = base; v.censor = !base.censor; variants.append(v)
        v = base; v.who = .men; variants.append(v)
        v = base; v.censorMode = .wholeFrame; variants.append(v)
        v = base; v.strictness += 1; variants.append(v)
        v = base; v.blurAmount += 1; variants.append(v)
        v = base; v.grayscale = !base.grayscale; variants.append(v)
        v = base; v.keepStems = .vocalsAndOther; variants.append(v)

        var seen: Set<String> = [key]
        for variant in variants {
            let k = Checkpoint.key(source: url, ops: variant)
            #expect(seen.insert(k).inserted, "\(variant) collided with an earlier key")
        }
    }

    /// Length-delimited, so ("a","bc") and ("ab","c") cannot hash alike. A
    /// collision here resumes the wrong job's segments into a user's video.
    @Test("key parts are length-delimited")
    func jobKeyDelimiting() {
        #expect(Checkpoint.key(["a", "bc"]) != Checkpoint.key(["ab", "c"]))
        #expect(Checkpoint.key(["", "abc"]) != Checkpoint.key(["abc", ""]))
    }

    // MARK: - Preflight free space

    /// Hand-computed from spec §4.1:
    /// `(tempCopies + 1) * source + extraScratch + 2 GiB`.
    @Test("free-space maths per shape")
    func preflightBudget() {
        let gib: Int64 = 1_073_741_824
        let slack: Int64 = 2 * gib
        #expect(Preflight.slackBytes == slack)

        var censor = FilterOps(); censor.removeMusic = false; censor.censor = true
        var music = FilterOps(); music.removeMusic = true; music.censor = false
        var both = FilterOps(); both.removeMusic = true; both.censor = true

        func required(_ ops: FilterOps, seconds: Int64, segmented: Bool,
                      transcodes: Bool = false) -> Int64 {
            Preflight.requiredBytes(
                sourceBytes: gib,
                tempCopies: Preflight.tempCopies(for: ops, segmented: segmented),
                extraScratch: Preflight.extraScratchBytes(for: ops, durationSeconds: seconds,
                                                          segmented: segmented,
                                                          transcodesAudio: transcodes))
        }

        // censor-only: one temp + the published copy, no scratch.
        #expect(required(censor, seconds: 600, segmented: false) == 2 * gib + slack)
        // music-only under 30 min: the separator is not resumable, so no PCM.
        #expect(required(music, seconds: 600, segmented: false) == 2 * gib + slack)
        // music-only at 30 min: resumable, so 1800 s x 176 400 B/s of int16 PCM.
        #expect(required(music, seconds: 1800, segmented: false)
                == 2 * gib + 1800 * 176_400 + slack)
        // combined: render temp AND published output coexist; under 30 min by
        // construction, so no scratch.
        #expect(required(both, seconds: 600, segmented: false) == 3 * gib + slack)
        // segmented censor-only: every rendered segment plus the concat output.
        #expect(required(censor, seconds: 3600, segmented: true) == 3 * gib + slack)
        // …plus the one-off AAC transcode at 192 kbit/s when the source audio
        // cannot be copied into the concat.
        #expect(required(censor, seconds: 3600, segmented: true, transcodes: true)
                == 3 * gib + 3600 * 24_000 + slack)
        // segmented with music: the PCM scratch scales with duration, not size.
        #expect(required(both, seconds: 3600, segmented: true)
                == 3 * gib + 3600 * 176_400 + slack)

        // ~1.6 GB on a 155-minute film is the number that made the scratch a
        // separate term instead of another "temp copy".
        #expect(Preflight.extraScratchBytes(for: music, durationSeconds: 155 * 60,
                                            segmented: false) == 1_640_520_000)
    }

    // MARK: - Failure taxonomy

    @Test("mid-pipeline failures resolve to a case, never to a message")
    func failureTaxonomy() {
        func failure(_ message: String) -> JobFailure {
            JobFailure.of(NSError(domain: "test", code: 1,
                                  userInfo: [NSLocalizedDescriptionKey: message]))
        }
        #expect(failure("write failed: ENOSPC") == .outOfSpace)
        #expect(failure("No space left on device") == .outOfSpace)
        #expect(failure("crypto error 0x1") == .drmProtected)
        // The decoder's own wording when the device has no codec for a mime.
        // It names neither "codec" nor "decoder".
        #expect(failure("Failed to initialize audio/ac3, error 0x80001001") == .unsupportedCodec)
        #expect(failure("no decoder for hvc1") == .unsupportedCodec)
        // Specific cases shadow one another in order: space beats codec.
        #expect(failure("encoder failed: no space left on device") == .outOfSpace)
        // An unrecognised cause is never the throwable's own message.
        #expect(failure("separator emitted 3 of 4 frames") == .generic)

        #expect(JobFailure.of(CocoaError(.fileNoSuchFile)) == .sourceUnreadable)
        #expect(JobFailure.of(PreflightFailure.lowSpace(requiredBytes: 1, availableBytes: 0)) == .lowSpace)
        #expect(JobFailure.of(PreflightFailure.drmProtected) == .drmProtected)
        #expect(JobFailure.of(PublishError.photosDenied) == .publishFailed)
    }

    @Test("the up-front ETA is a floor, and a no-op job estimates nothing")
    func etaFloor() {
        var censor = FilterOps(); censor.removeMusic = false; censor.censor = true
        var music = FilterOps(); music.removeMusic = true; music.censor = false
        var both = FilterOps(); both.removeMusic = true; both.censor = true
        var none = FilterOps(); none.removeMusic = false; none.censor = false

        #expect(Eta.estimateMs(durationMs: 100_000, ops: censor) == 28_000)
        #expect(Eta.estimateMs(durationMs: 100_000, ops: music) == 68_000)
        #expect(Eta.estimateMs(durationMs: 100_000, ops: both) == 100_000)
        #expect(Eta.estimateMs(durationMs: 100_000, ops: none) == 0)
        #expect(Eta.estimateMs(durationMs: 0, ops: both) == 0)

        // 0 means "too early to say"; the surface hides the line entirely.
        #expect(Eta.liveMs(elapsedMs: 10_000, pct: 2) == 0)
        #expect(Eta.liveMs(elapsedMs: 10_000, pct: 25) == 30_000)
        #expect(Eta.confirmThresholdMs == 1_800_000)
    }

    // MARK: - End to end

    /// Kill a job mid-way, re-run it, and prove the expensive pass did not run
    /// twice. Simulated as a system stop rather than a user cancel: those are
    /// the cases resume exists to survive, and only a user cancel destroys the
    /// work directory.
    @Test("an interrupted run keeps its analysis and the next run skips it")
    func resumeSkipsFinishedWork() async throws {
        let url = try requireQAVideo()
        var ops = FilterOps()
        ops.removeMusic = false
        ops.censor = true
        // `everyone` skips the gender vote outright, which keeps the test to
        // the resume behaviour rather than to genderage's runtime.
        ops.who = .everyone

        let folder = Fixtures.scratch("jobs-resume-out")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let job = Job.capture(source: url, ops: ops, destination: .userFolder, folder: folder)
        let key = Checkpoint.key(source: url, ops: ops)
        WorkDir.clear(key)
        let dir = WorkDir.root.appendingPathComponent(key, isDirectory: true)

        // First attempt: stop the moment the analysis checkpoint lands.
        let interrupt = OSAllocatedUnfairLock(initialState: false)
        var thrown: (any Error)?
        do {
            _ = try await JobRunner.run(
                job,
                progress: { p in if p.stage == .analyze, p.fraction >= 0.5 { interrupt.withLock { $0 = true } } },
                stop: { interrupt.withLock { $0 } ? .interrupted : nil })
        } catch { thrown = error }

        let stopped = try #require(thrown as? JobStopped, "the run should have been interrupted")
        #expect(stopped.reason == .interrupted)
        #expect(stopped.resumable)
        #expect(FileManager.default.fileExists(
            atPath: dir.appendingPathComponent(Checkpoint.analysisName).path),
            "the analysis checkpoint should have survived the stop")
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path).isEmpty,
                "an interrupted run must not publish anything")

        // Second attempt: same (source, options) ⇒ same key ⇒ finds the checkpoint.
        let done = try await JobRunner.run(job)
        #expect(done.resumed.contains(.analyze), "analyze ran a second time")
        #expect(done.shape == .censorOnly)

        // A `.userFolder` publish is the one that leaves a file behind, so the
        // URL is non-nil here; a Photos publish would legitimately have none.
        let out = try await MediaSource.probe(try #require(done.output.url))
        #expect(out.video != nil, "the output has no video track")
        #expect(done.output.name == out.url.lastPathComponent)
        let source = try await MediaSource.probe(url)
        #expect(abs(out.duration.seconds - source.duration.seconds) < 0.5)
        #expect(!FileManager.default.fileExists(atPath: dir.path),
                "a completed job leaves no work directory")
        try? FileManager.default.removeItem(at: folder)
    }

    /// The flagship shape, and the only one with two concurrent branches: the
    /// audio wall at `.userInitiated` and the analyze branch demoted to
    /// `.utility` so it cannot take a P-core off ORT. Interrupting once both
    /// branches have landed proves the expensive half survives — a resumed
    /// both-ops job must not separate the audio a second time.
    @Test("both-ops resumes without re-separating the audio")
    func combinedResumesTheAudioBranch() async throws {
        let url = try requireQAVideo()
        var ops = FilterOps()
        ops.removeMusic = true
        ops.censor = true
        ops.who = .everyone

        let folder = Fixtures.scratch("jobs-combined-out")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let job = Job.capture(source: url, ops: ops, destination: .userFolder, folder: folder)
        let key = Checkpoint.key(source: url, ops: ops)
        WorkDir.clear(key)
        let dir = WorkDir.root.appendingPathComponent(key, isDirectory: true)

        // Render only starts once analyze and separate have both finished, so
        // its first progress post is the signal that both checkpoints exist.
        let interrupt = OSAllocatedUnfairLock(initialState: false)
        var thrown: (any Error)?
        do {
            _ = try await JobRunner.run(
                job,
                progress: { p in if p.stage == .render { interrupt.withLock { $0 = true } } },
                stop: { interrupt.withLock { $0 } ? .interrupted : nil })
        } catch { thrown = error }

        #expect(thrown is JobStopped)
        #expect(FileManager.default.fileExists(
            atPath: dir.appendingPathComponent(Checkpoint.audioTrackName).path),
            "the separated track should have survived the stop")

        let done = try await JobRunner.run(job)
        #expect(done.shape == .combined)
        #expect(done.resumed == [.analyze, .separate])

        let out = try await MediaSource.probe(try #require(done.output.url))
        #expect(out.video != nil)
        #expect(out.audio != nil, "the separated track was not muxed in")
        let source = try await MediaSource.probe(url)
        #expect(abs(out.duration.seconds - source.duration.seconds) < 0.5)
        try? FileManager.default.removeItem(at: folder)
    }

    @Test("a user cancel leaves no output file and no temp directory")
    func cancelLeavesNothing() async throws {
        let url = try requireQAVideo()
        var ops = FilterOps()
        ops.removeMusic = false
        ops.censor = true
        ops.who = .everyone

        let folder = Fixtures.scratch("jobs-cancel-out")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let job = Job.capture(source: url, ops: ops, destination: .userFolder, folder: folder)
        let key = Checkpoint.key(source: url, ops: ops)
        WorkDir.clear(key)

        var thrown: (any Error)?
        do { _ = try await JobRunner.run(job, stop: { .userCancelled }) } catch { thrown = error }

        let stopped = try #require(thrown as? JobStopped)
        #expect(stopped.reason == .userCancelled)
        #expect(!stopped.resumable)
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path).isEmpty)
        #expect(!FileManager.default.fileExists(
            atPath: WorkDir.root.appendingPathComponent(key, isDirectory: true).path),
            "a user cancel takes the whole work directory")
        try? FileManager.default.removeItem(at: folder)
    }

    // MARK: - Queue

    @Test("the queue runs in order, records each outcome, and survives a relaunch")
    func queueOrderAndPersistence() async throws {
        let store = Fixtures.scratch("jobs-queue.json")
        let queue = JobQueue(storeURL: store)
        var ops = FilterOps()
        ops.censor = true

        // Sources that cannot be opened: the point here is the queue's
        // bookkeeping, and a queued run must never take the rest of the queue
        // down with it.
        var enqueued: [Job.ID] = []
        for i in 0..<3 {
            let missing = URL(fileURLWithPath: "/tmp/naqi-missing-\(i)-\(UUID().uuidString).mp4")
            enqueued.append(await queue.enqueue(
                Job.capture(source: missing, ops: ops, destination: .userFolder)))
        }

        try await settle { await queue.jobs.allSatisfy(\.state.isTerminal) }
        var jobs = await queue.jobs
        #expect(jobs.map(\.id) == enqueued, "the queue reordered itself")
        for job in jobs {
            #expect(job.state == .failed(.sourceUnreadable, resumable: false))
        }

        // Retry is not a special code path: the same (source, options) is
        // re-run, and it lands on the same job key.
        await queue.retry(enqueued[0])
        try await settle { await queue.jobs.allSatisfy(\.state.isTerminal) }
        jobs = await queue.jobs
        #expect(jobs.count == 3, "retry duplicated a row")

        // Relaunch.
        let reloaded = JobQueue(storeURL: store)
        #expect(await reloaded.jobs.map(\.id) == enqueued)

        await queue.clearFinished()
        #expect(await queue.jobs.isEmpty)
    }

    /// Drives the share-in seam from the *extension's* side: write exactly what
    /// `ShareViewController.copy` writes — media first, manifest second — then
    /// drain. This is the only test that can fail if the App Group entitlement
    /// regresses, because everything else on this path degrades to a silent
    /// no-op rather than an error.
    @Test("share inbox drains what the extension writes")
    func shareInboxDrains() async throws {
        // The App Group is scoped to iOS: the share extension is iOS-only, and
        // requiring the entitlement on macOS would force a provisioning profile
        // for a container nothing on that platform reads.
        guard let dir = ShareInbox.container else {
            #if os(iOS)
            Issue.record("no App Group container — the entitlement or the group id regressed")
            #endif
            return
        }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let id = UUID()
        let media = ShareManifest.mediaURL(dir, id: id, ext: "mp4")
        try Data("not really a movie".utf8).write(to: media)
        let manifest = ShareManifest(id: id, fileName: "clip.mp4", receivedAt: Date())
        try JSONEncoder().encode(manifest)
            .write(to: ShareManifest.manifestURL(dir, id: id), options: .atomic)

        let queue = JobQueue(storeURL: Fixtures.scratch("jobs-inbox.json"))
        #expect(await ShareInbox.drain(into: queue) == 1)
        let jobs = await queue.jobs
        #expect(jobs.count == 1)
        #expect(jobs.first?.title == "clip")
        // Both container entries are consumed: a manifest left behind would be
        // re-enqueued on the next foreground, and the app foregrounds a lot.
        #expect(!FileManager.default.fileExists(
            atPath: ShareManifest.manifestURL(dir, id: id).path))
        #expect(!FileManager.default.fileExists(atPath: media.path))

        // The "movie" is 18 bytes of text, so the job fails at preflight; stop
        // it rather than leaving it to race the next test's scratch dir.
        for job in jobs { await queue.cancel(job.id) }
        try? FileManager.default.removeItem(at: jobs[0].source)
    }

    /// A manifest whose media never arrived is an extension that died between
    /// its two writes. It must be dropped, not retried forever.
    @Test("share inbox drops a manifest with no media")
    func shareInboxDropsOrphanManifest() async throws {
        guard let dir = ShareInbox.container else { return }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let id = UUID()
        let orphan = ShareManifest.manifestURL(dir, id: id)
        try JSONEncoder().encode(ShareManifest(id: id, fileName: "gone.mp4", receivedAt: Date()))
            .write(to: orphan, options: .atomic)

        let queue = JobQueue(storeURL: Fixtures.scratch("jobs-orphan.json"))
        #expect(await ShareInbox.drain(into: queue) == 0)
        #expect(await queue.jobs.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: orphan.path))
    }

    /// Polls rather than sleeping a fixed time: the queue's own hops through
    /// the main actor make any single sleep either flaky or slow.
    private func settle(_ condition: @Sendable () async -> Bool,
                        timeout: Duration = .seconds(10)) async throws {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        Issue.record("timed out waiting for the queue to settle")
    }
}
