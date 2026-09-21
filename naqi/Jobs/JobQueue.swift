import Foundation
import os

/// A strictly serial queue: one job at a time, in enqueue order.
///
/// Two jobs at once would both want the P-cores ORT needs and the ~1.3 GB
/// htdemucs is resident for, and the second would only make the first slower —
/// there is nothing to overlap that `JobRunner`'s two branches are not already
/// overlapping inside a single job.
///
/// The queue file is the authority on a job's outcome, not the runner's return
/// value: a queued run that fails must not take the rest of the queue with it,
/// which is the whole reason Android kept a `queue.json` alongside WorkManager.
actor JobQueue {
    static let shared = JobQueue()

    struct Snapshot: Sendable {
        var jobs: [Job]
        var running: Job.ID?
        /// Never persisted. On relaunch the process is gone and the checkpoint,
        /// not a stored percent, decides how much of the job survived.
        var progress: JobProgress?
    }

    private let storeURL: URL
    private(set) var jobs: [Job] = []
    private var runningID: Job.ID?
    /// When the running job actually started working. Not its `enqueuedAt`:
    /// time spent waiting behind another job is not time this one has spent,
    /// and the live ETA divides by it.
    private var runningSince: Date?
    private var progress: JobProgress?
    private var running: Task<Void, Never>?
    /// A BGProcessing grant owns one checkpointed job, never the whole queue.
    private var stopAfterCurrent = false
    private var observers: [UUID: AsyncStream<Snapshot>.Continuation] = [:]

    /// Polled by the running job from AVFoundation's own queues, so it lives in
    /// a lock rather than in actor state.
    private let stopFlag = OSAllocatedUnfairLock<JobRunner.Stop?>(initialState: nil)

    static var defaultStore: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base.appendingPathComponent("naqi-queue.json")
    }

    init(storeURL: URL = JobQueue.defaultStore) {
        self.storeURL = storeURL
        jobs = Self.load(storeURL)
    }

    // MARK: Mutations

    /// Adding the same (source, options) twice is a no-op while the first copy
    /// is still live.
    ///
    /// Android learned this as KEEP-not-REPLACE: replacing meant one stray tap
    /// on Start cancelled a job that could be four hours in, and the UI's
    /// disabled button is the half that can be raced.
    @discardableResult
    func enqueue(_ job: Job) -> Job.ID {
        let key = Checkpoint.key(source: job.source, ops: job.ops)
        if let existing = jobs.first(where: {
            !$0.state.isTerminal && Checkpoint.key(source: $0.source, ops: $0.ops) == key
        }) {
            Log.job.notice("enqueue ignored, already queued")
            // Still drain. `load()` resets a `.running` row to `.pending` on
            // relaunch and nothing runs at init, so the row this call matched
            // may be a survivor that no longer has a task behind it. Returning
            // early left it pending forever and the progress screen sat on
            // "Starting… 0 %". `drain()` is a no-op when a job is already live.
            drain()
            return existing.id
        }
        jobs.append(job)
        commit()
        drain()
        return job.id
    }

    /// Cancelling the running job stops it within one chunk; cancelling a
    /// queued one just marks it. Android had to re-append every survivor here
    /// because WorkManager cascades a cancellation down the chain — a serial
    /// actor has no chain, so there is nothing to repair.
    func cancel(_ id: Job.ID) {
        if id == runningID {
            stopFlag.withLock { $0 = .userCancelled }
            running?.cancel()
            return
        }
        update(id) { $0.state = .cancelled }
    }

    /// Not a special code path: the same (source, options) lands on the same
    /// job key, finds whatever the last attempt checkpointed, and resumes.
    func retry(_ id: Job.ID) {
        update(id) { $0.state = .pending }
        drain()
    }

    func remove(_ id: Job.ID) {
        if id == runningID { cancel(id) }
        jobs.removeAll { $0.id == id }
        commit()
    }

    func clearFinished() {
        for job in jobs {
            if case .done(let published) = job.state, let url = published.url {
                OutputLibrary.remove(url)
            }
        }
        jobs.removeAll {
            switch $0.state {
            case .done, .cancelled: true
            case .failed(_, let resumable): !resumable
            case .pending, .running: false
            }
        }
        commit()
    }

    // MARK: Survivors

    /// Jobs a relaunch left behind. `load()` resets a `.running` row to
    /// `.pending` and nothing drains at init, so without this they sit in
    /// `naqi-queue.json` forever and the bookmark and checkpoint machinery
    /// built to survive a relaunch has no trigger.
    ///
    /// Read-only on purpose: a job that resumes itself while the user is
    /// looking at the picker — burning an hour of battery they did not ask
    /// for — is worse than one that waits to be asked.
    ///
    /// ponytail: "pending" and not "left over", so a row merely queued behind a
    /// live job is in here too. At launch, which is the only time anything asks,
    /// nothing is live and the two sets are the same.
    func resumable() -> [Job] {
        jobs.filter { if case .pending = $0.state { true } else { false } }
    }

    /// Puts one back in flight. The same path `retry` takes, because it is the
    /// same thing: the row is already `.pending` and `drain()` is what starts
    /// it.
    func resume(_ id: Job.ID) { retry(id) }

    /// Starts the first checkpointed survivor when iOS grants a processing
    /// window. A fresh process loads an interrupted `.running` row as pending;
    /// a process that survived suspension has already recorded `.failed` with
    /// `resumable = true`, so both routes meet here.
    func startResumableHead() -> Job.ID? {
        guard runningID == nil else { return nil }
        guard let job = jobs.first(where: {
            switch $0.state {
            case .pending: true
            case .failed(_, let resumable): resumable
            default: false
            }
        }) else { return nil }
        if job.state.isTerminal { update(job.id) { $0.state = .pending } }
        stopAfterCurrent = true
        drain()
        return runningID
    }

    nonisolated func signalBackgroundExpiration() {
        stopFlag.withLock { $0 = .interrupted }
    }

    func hasResumableJob() -> Bool {
        jobs.contains {
            switch $0.state {
            case .pending: true
            case .failed(_, let resumable): resumable
            default: false
            }
        }
    }

    /// A foreground launch owns the serial queue again. If the processing
    /// grant is still running, its current job continues and may drain the next
    /// row when it finishes. If it already ended, drain now.
    func continueInForeground() {
        stopAfterCurrent = false
        drain()
    }

    /// Drops the row *and* the scratch it was holding. `remove` alone leaves a
    /// work directory behind for the 7-day sweep, which on a half-rendered film
    /// is gigabytes the user just said they did not want.
    ///
    /// ponytail: keyed off `job.source`, the same way `enqueue` dedupes. A
    /// bookmark that re-resolves to a different URL than the one stored took a
    /// different key in `JobRunner`, and that directory is left to the sweep.
    func discard(_ id: Job.ID) {
        if let job = jobs.first(where: { $0.id == id }) {
            WorkDir.clear(Checkpoint.key(source: job.source, ops: job.ops))
            if case .done(let published) = job.state, let url = published.url {
                OutputLibrary.remove(url)
            }
        }
        remove(id)
    }

    // MARK: Observation

    func observe() -> AsyncStream<Snapshot> {
        let (stream, continuation) = AsyncStream<Snapshot>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let id = UUID()
        observers[id] = continuation
        continuation.onTermination = { [weak self] _ in
            Task { await self?.stopObserving(id) }
        }
        continuation.yield(snapshot())
        return stream
    }

    private func stopObserving(_ id: UUID) { observers[id] = nil }

    private func snapshot() -> Snapshot {
        Snapshot(jobs: jobs, running: runningID, progress: progress)
    }

    private func notify() {
        let s = snapshot()
        for c in observers.values { c.yield(s) }
    }

    // MARK: Draining

    private func drain() {
        guard running == nil,
              let next = jobs.first(where: { if case .pending = $0.state { true } else { false } })
        else { return }
        runningID = next.id
        runningSince = .now
        progress = nil
        stopFlag.withLock { $0 = nil }
        update(next.id) { $0.state = .running }
        running = Task { await self.execute(next) }
    }

    private func execute(_ job: Job) async {
        await Lifecycle.shared.jobStarted(title: job.title) { [weak self] in
            Task { await self?.flush() }
        }
        await LiveActivity.start(title: job.title)
        await Notify.requestAuthorization()
        let flag = stopFlag
        defer {
            Task {
                await Lifecycle.shared.jobFinished()
                await LiveActivity.end()
            }
        }

        do {
            let done = try await JobRunner.run(
                job,
                progress: { [weak self] p in Task { await self?.report(job.id, p) } },
                stop: { flag.withLock { $0 } ?? (Lifecycle.shared.isInterrupted ? .interrupted : nil) })
            update(job.id) { $0.state = .done(done.output) }
            Log.job.info("""
                done \(done.shape.rawValue, privacy: .public) in \(Int(done.wallMs))ms \
                resumed=\(done.resumed.map(\.rawValue).sorted().joined(separator: ","), privacy: .public)
                """)
            await Notify.done(name: done.output.name)
        } catch let stopped as JobStopped {
            // An interruption is not a failure of the work — the OS took the
            // app away and the checkpoint survived. Saying so is what lets the
            // screen stop printing "Filtering failed." above a Resume button.
            update(job.id) {
                $0.state = stopped.reason == .userCancelled
                    ? .cancelled
                    : .failed(.interrupted, resumable: stopped.resumable)
            }
            // A deliberate cancel needs no announcement; an interruption is by
            // definition something that happened while the user was elsewhere.
            if stopped.reason != .userCancelled { await Notify.failed() }
        } catch {
            let failure = JobFailure.of(error)
            // The byte counts cannot ride on the failure case — see
            // `Job.shortfall` — so they are picked up from the preflight that
            // just computed them, and only for the failure they belong to.
            let shortfall = failure == .lowSpace ? Preflight.lastShortfall.withLock({ $0 }) : nil
            update(job.id) {
                $0.shortfall = shortfall
                $0.state = .failed(failure, resumable: false)
            }
            await Notify.failed()
        }

        runningID = nil
        runningSince = nil
        progress = nil
        running = nil
        notify()
        if stopAfterCurrent {
            stopAfterCurrent = false
        } else {
            drain()
        }
    }

    private func report(_ id: Job.ID, _ p: JobProgress) {
        guard id == runningID else { return }
        progress = p
        notify()
        // The same straight-line extrapolation the Progress screen shows, off
        // the same clock — the lock screen is where a 90-minute job actually
        // lives, and `Eta.liveMs` returning 0 early on is what hides the line
        // rather than printing a number that will be wrong.
        let eta = Eta.liveMs(elapsedMs: Date.now.timeIntervalSince(runningSince ?? .now) * 1000,
                             pct: p.pct)
        Task { await LiveActivity.update(p, etaSeconds: Int(eta / 1000)) }
    }

    private func update(_ id: Job.ID, _ transform: (inout Job) -> Void) {
        guard let i = jobs.firstIndex(where: { $0.id == id }) else { return }
        transform(&jobs[i])
        commit()
    }

    // MARK: Persistence

    /// Re-persists on demand. The queue already commits on every state change,
    /// so this only matters when the app is about to lose the foreground with a
    /// job mid-flight.
    func flush() { commit() }

    /// Whole-file rewrite on every change, committed temp+rename. The file is
    /// small (a handful of rows) and the alternative — a partially updated
    /// queue — is the one state the screen cannot recover from.
    private func commit() {
        if let data = try? JSONEncoder().encode(jobs) {
            try? Checkpoint.writeAtomically(data, to: storeURL)
        }
        notify()
    }

    /// A truncated or unparseable file starts the queue empty rather than
    /// bricking the screen. A job left `.running` is reset: the process died,
    /// the job did not, and the checkpoint decides how much it re-does.
    private static func load(_ url: URL) -> [Job] {
        guard let data = try? Data(contentsOf: url),
              var loaded = try? JSONDecoder().decode([Job].self, from: data)
        else { return [] }
        for i in loaded.indices where loaded[i].state == .running {
            loaded[i].state = .pending
        }
        return loaded
    }
}
