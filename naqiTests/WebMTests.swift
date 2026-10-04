import AVFoundation
import CryptoKit
import Foundation
import os
import Testing
@testable import naqi

@Suite("WebM import", .serialized)
struct WebMTests {
    // Fixtures contain 1.2 s of FFmpeg testsrc2 at 10 fps and a 440 Hz tone.
    private final class BundleToken {}

    private func fixture(_ name: String) throws -> URL {
        try #require(Bundle(for: BundleToken.self).url(forResource: name, withExtension: "webm"))
    }

    private func directory() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("webm-\(UUID())")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test("Converted WebM decodes both tracks and preserves the original",
          arguments: ["vp9-opus", "vp8-vorbis", "opus-audio", "no-duration"])
    func conversion(_ name: String) async throws {
        let source = try fixture(name)
        let before = SHA256.hash(data: try Data(contentsOf: source))
        let info = try await WebM.metadata(source)
        let dir = try directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let output = try await WebM.prepare(source, in: dir)
        let media = try await MediaSource.probe(output)
        #expect(output != source && output.pathExtension == "mp4")
        #expect((media.video != nil) == (name != "opus-audio"))
        #expect(media.hasAudio && media.duration.seconds > 1 && media.duration.seconds < 1.5)
        #expect(info.hasVideo == (media.video != nil))
        try await verifyDecoding(output, video: media.video != nil)
        #expect(SHA256.hash(data: try Data(contentsOf: source)) == before)

        // A completed conversion is reused on resume, rather than re-encoded.
        let stamp = try FileManager.default.attributesOfItem(atPath: output.path)[.modificationDate] as? Date
        #expect(try await WebM.prepare(source, in: dir) == output)
        #expect(try FileManager.default.attributesOfItem(atPath: output.path)[.modificationDate] as? Date == stamp)
        #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent("webm-converting.mp4").path))
    }

    @Test("Cancelled and invalid imports leave no converted file")
    func failures() async throws {
        let dir = try directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let source = try fixture("vp9-opus")
        let cancelled = OSAllocatedUnfairLock(initialState: false)
        await #expect(throws: CancellationError.self) {
            try await WebM.prepare(source, in: dir,
                                   onProgress: { _ in cancelled.withLock { $0 = true } },
                                   isCancelled: { cancelled.withLock { $0 } })
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path).isEmpty)
        let invalid = dir.appendingPathComponent("invalid.WEBM")
        try Data("not a WebM".utf8).write(to: invalid)
        await #expect(throws: PreflightFailure.sourceUnreadable) {
            try await WebM.prepare(invalid, in: dir)
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path) == [invalid.lastPathComponent])
        #expect(try await WebM.prepare(dir.appendingPathComponent("unchanged.mp4"), in: dir)
                == dir.appendingPathComponent("unchanged.mp4"))
    }

    @Test("Job converts, renders and publishes WebM with the original filename")
    func job() async throws {
        let folder = try directory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let original = try fixture("vp9-opus")
        let source = folder.appendingPathComponent("holiday.WEBM")
        try FileManager.default.copyItem(at: original, to: source)
        let before = SHA256.hash(data: try Data(contentsOf: source))
        var ops = FilterOps()
        ops.removeMusic = false
        ops.censor = true
        let job = Job.capture(source: source, ops: ops, destination: .userFolder, folder: folder)
        let opened = try job.openSource()
        let key = Checkpoint.key(source: opened.url, ops: ops)
        opened.close()
        defer { WorkDir.clear(key) }
        // Supply verified analysis so this exercises real conversion/render/export without ML models.
        try Checkpoint.writeEdl(Edl(censorIntervalsMs: [0...2_000]), dir: WorkDir.job(key))
        #expect(Checkpoint.readEdl(dir: WorkDir.job(key)) != nil)
        let stages = OSAllocatedUnfairLock<Set<Job.Stage>>(initialState: [])
        let result = try await JobRunner.run(job, progress: { p in
            if let stage = p.stage { stages.withLock { _ = $0.insert(stage) } }
        })
        let output = try #require(result.output.url)
        #expect(output.lastPathComponent.hasPrefix("holiday"))
        #expect(output.pathExtension == "mp4")
        let observed = stages.withLock { $0 }
        #expect(observed.contains(.convert))
        #expect(observed.contains(.publish))
        try await verifyDecoding(output, video: true)
        #expect(SHA256.hash(data: try Data(contentsOf: source)) == before)
        #expect(!FileManager.default.fileExists(atPath: WorkDir.root.appendingPathComponent(key).path))
    }

    private func verifyDecoding(_ url: URL, video: Bool) async throws {
        let asset = AVURLAsset(url: url)
        if video {
            let track = try #require(try await asset.loadTracks(withMediaType: .video).first)
            let reader = try TrackReader.decodedVideo(track: track)
            try reader.start()
            var frames = 0
            while reader.next() != nil { frames += 1 }
            try reader.throwIfFailed()
            #expect(frames == 12)
        }
        let audio = try #require(try await asset.loadTracks(withMediaType: .audio).first)
        let reader = try AudioDecoder(track: audio)
        try reader.start()
        var frames = 0
        while let samples = try reader.next() { frames += samples.frames }
        #expect(frames > 44_100)
    }
}
