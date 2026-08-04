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
    private var progress: JobProgress?
    private var running: Task<Void, Never>?
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
        jobs.removeAll(where: \.state.isTerminal)
        commit()
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
        } catch let stopped as JobStopped {
            update(job.id) {
                $0.state = stopped.reason == .userCancelled
                    ? .cancelled
                    : .failed(.generic, resumable: stopped.resumable)
            }
        } catch {
            update(job.id) { $0.state = .failed(JobFailure.of(error), resumable: false) }
        }

        runningID = nil
        progress = nil
        running = nil
        notify()
        drain()
    }

    private func report(_ id: Job.ID, _ p: JobProgress) {
        guard id == runningID else { return }
        progress = p
        notify()
        Task { await LiveActivity.update(p) }
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
