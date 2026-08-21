import Testing
import Foundation
@testable import naqi

/// The three seams behind the job screens that fail silently rather than
/// loudly: a failure that resolves to the wrong sentence, a queue file that
/// stops decoding, and a survivor of a relaunch that nothing can reach.
@Suite("Jobs backend", .serialized)
struct JobsBackendTests {

    // MARK: - Failure taxonomy

    /// A refused photo library is the one publish failure the user can actually
    /// fix. It used to collapse into `publishFailed`, which the screen prints
    /// as "Filtering failed." — a sentence that is both wrong and unactionable.
    @Test("a refused photo library is its own case, from either side of the job")
    func photosDeniedIsItsOwnCase() {
        #expect(JobFailure.of(PublishError.photosDenied) == .photosDenied)
        #expect(JobFailure.of(PreflightFailure.photosDenied) == .photosDenied)
        // The other two publish failures still collapse: neither names anything
        // the user can do about it.
        #expect(JobFailure.of(PublishError.photosFailed("x")) == .publishFailed)
        #expect(JobFailure.of(PublishError.destinationUnwritable("x")) == .publishFailed)
    }

    /// The early exit must stay exactly that. Asking a folder-bound job about
    /// the photo library would put a permission sheet in front of every user
    /// who deliberately chose Files.
    @Test("preflight only asks about Photos when the destination is Photos")
    func photosAccessSkipsTheFolderDestination() async {
        #expect(await Preflight.photosAccess(for: .userFolder) == nil)
    }

    // MARK: - Queue file compatibility

    /// The guarantee `Job.shortfall` is optional for.
    ///
    /// A `naqi-queue.json` written before the field existed has no such key,
    /// and `JobQueue.load` treats an unparseable file as *no jobs at all* — so
    /// a decode that tripped over the new field would silently empty a queue
    /// that may hold hours of checkpointed work.
    @Test("a queue file written before the shortfall field still decodes")
    func oldQueueFileDecodes() throws {
        let old = """
            [{"id":"1D9F0C8E-4A2B-4E15-9C3D-2F6A1B0E7C41",
              "source":"file:///tmp/naqi-old.mp4",
              "title":"old",
              "ops":{"removeMusic":true,"censor":true,"who":"women","censorMode":"regions",
                     "strictness":40,"blurAmount":60,"grayscale":false,"keepStems":"vocals"},
              "destination":"photos",
              "state":{"failed":{"_0":"lowSpace","resumable":false}},
              "enqueuedAt":770000000}]
            """
        let job = try #require(try JSONDecoder().decode([Job].self, from: Data(old.utf8)).first)
        #expect(job.title == "old")
        #expect(job.state == .failed(.lowSpace, resumable: false))
        #expect(job.shortfall == nil)

        // And a row that has one survives the round trip the queue actually
        // performs on every state change.
        var carried = job
        carried.shortfall = Job.Shortfall(requiredBytes: 9, availableBytes: 4)
        let round = try JSONDecoder().decode([Job].self, from: JSONEncoder().encode([carried]))
        #expect(round.first?.shortfall == Job.Shortfall(requiredBytes: 9, availableBytes: 4))
    }

    // MARK: - Survivors of a relaunch

    /// A job killed with the app is reset to `.pending` by `load()` and nothing
    /// drains at launch, so this is the only thing that can find it again.
    @Test("resumable() finds the pending survivor and nothing terminal")
    func resumableFindsPendingOnly() async throws {
        let store = Fixtures.scratch("jobs-resumable.json")
        defer { try? FileManager.default.removeItem(at: store) }
        let pending = Self.row(.pending)
        try JSONEncoder()
            .encode([pending,
                     Self.row(.done(Published(name: "a.mp4", url: nil, assetID: nil))),
                     Self.row(.failed(.interrupted, resumable: true)),
                     Self.row(.cancelled)])
            .write(to: store)

        let queue = JobQueue(storeURL: store)
        #expect(await queue.resumable().map(\.id) == [pending.id])
    }

    /// Discarding is not `remove`: the scratch has to go with the row, or a
    /// user who just said they did not want a half-rendered film keeps paying
    /// gigabytes for it until the 7-day sweep runs.
    @Test("discard drops the row and the work directory with it")
    func discardClearsTheScratch() async throws {
        let store = Fixtures.scratch("jobs-discard.json")
        defer { try? FileManager.default.removeItem(at: store) }
        let job = Self.row(.pending)
        try JSONEncoder().encode([job]).write(to: store)

        let dir = WorkDir.job(Checkpoint.key(source: job.source, ops: job.ops))
        FileManager.default.createFile(atPath: dir.appendingPathComponent("seg-000.mp4").path,
                                       contents: Data([0]))

        let queue = JobQueue(storeURL: store)
        await queue.discard(job.id)
        #expect(await queue.jobs.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: dir.path))
    }

    /// A queue row in a given state, with a unique source so no two share a
    /// `Checkpoint.key`.
    private static func row(_ state: Job.State) -> Job {
        var job = Job(source: URL(fileURLWithPath: "/tmp/naqi-\(UUID().uuidString).mp4"),
                      title: "queued", ops: FilterOps(), destination: .photos)
        job.state = state
        return job
    }
}
