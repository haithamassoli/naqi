import CryptoKit
import Foundation
import os

/// One slice of a long source, rendered and checkpointed independently.
struct RenderSegment: Codable, Sendable, Equatable {
    var index: Int
    var startMs: Int64
    var endMs: Int64
    var durationMs: Int64 { endMs - startMs }
}

/// Per-segment resume.
///
/// **The checkpoint unit is one COMPLETED segment.** Mid-segment state — gate
/// firings so far, the live face-track map — is deliberately never persisted,
/// so an interruption costs the segment in flight and nothing more.
///
/// **Every file is written to `<name>.tmp` and renamed.** A file existing under
/// its final name *means* it is complete: no manifest to keep in sync, and no
/// way for a checkpoint to reference a half-written segment.
enum Checkpoint {

    /// One fixed length for every device. The per-export fixed cost is small
    /// next to what a lost segment costs: analyze runs near 0.45x realtime, so
    /// one lost 5-minute segment is ~2.3 min of work.
    static let segmentMs: Int64 = 5 * 60 * 1000
    /// Below this, the whole timeline runs in one pass — the unsegmented route
    /// stays byte-for-byte unchanged for ordinary clips.
    static let longSourceThresholdMs: Int64 = 30 * 60 * 1000
    /// Work directories untouched for this long are swept. Age-based on
    /// purpose: "delete every temp at startup" is the obvious reading and the
    /// one change that could silently destroy hours of work.
    static let staleInterval: TimeInterval = 7 * 24 * 60 * 60

    /// Empty means "run the whole timeline in one pass".
    ///
    /// - Parameter cutAt: snaps a proposed cut to a real sync sample. Returning
    ///   the input unchanged disables snapping.
    static func plan(durationMs: Int64,
                     forcedSegmentMs: Int64 = 0,
                     cutAt: (Int64) -> Int64 = { $0 }) -> [RenderSegment] {
        let seg = forcedSegmentMs > 0 ? forcedSegmentMs : segmentMs
        guard durationMs > 0 else { return [] }
        if forcedSegmentMs <= 0 && durationMs < longSourceThresholdMs { return [] }
        guard durationMs > seg else { return [] }

        let count = (durationMs + seg - 1) / seg
        var cuts: [Int64] = [0]
        for i in 1..<count { cuts.append(min(max(cutAt(Int64(i) * seg), 0), durationMs)) }
        cuts.append(durationMs)
        // `distinct` is load-bearing: it collapses two cuts that a sparse-keyframe
        // source snapped onto the same sample, so such a source gets fewer,
        // longer segments rather than an empty one — which would make the
        // clipper throw on an inverted range.
        cuts = Array(Set(cuts)).sorted()

        return zip(cuts, cuts.dropFirst()).enumerated().map {
            RenderSegment(index: $0.offset, startMs: $0.element.0, endMs: $0.element.1)
        }
    }

    /// Stable identity for a job's work directory. A real digest, not a hash
    /// value: a collision here would resume the wrong job's segments into a
    /// user's video. Parts are length-delimited so ("a","bc") and ("ab","c")
    /// cannot hash alike.
    static func key(_ parts: [String]) -> String {
        var d = SHA256()
        for p in parts { d.update(data: Data("\(p.count):\(p)|".utf8)) }
        return d.finalize().prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    static func key(source: URL, ops: FilterOps) -> String {
        key([
            source.absoluteString,
            String(ops.removeMusic),
            ops.who.rawValue,
            String(ops.censor),
            ops.censorMode.rawValue,
            String(ops.strictness),
            String(ops.blurAmount),
            String(ops.grayscale),
            ops.keepStems.rawValue,
        ])
    }

    // MARK: Files

    static func analysisURL(_ dir: URL, segment: Int) -> URL {
        dir.appendingPathComponent(String(format: "an-%03d.json", segment))
    }
    static func segmentURL(_ dir: URL, segment: Int) -> URL {
        dir.appendingPathComponent(String(format: "seg-%03d.mp4", segment))
    }
    static var audioTrackName: String { "audio.m4a" }
    static var audioProgressName: String { "audio.json" }
    static var renderTempName: String { "render.mp4" }

    /// Write-then-rename. `rename` will not overwrite on every filesystem, so a
    /// rewrite removes the target first.
    static func writeAtomically(_ data: Data, to url: URL) throws {
        let tmp = url.appendingPathExtension("tmp")
        try? FileManager.default.removeItem(at: tmp)
        try data.write(to: tmp, options: .atomic)
        try? FileManager.default.removeItem(at: url)
        try FileManager.default.moveItem(at: tmp, to: url)
    }

    /// A segment checkpoint stores **bare tracks only** — the whole-frame
    /// intervals are always rebuilt globally, because hysteresis and the
    /// whole-frame floor span segment boundaries.
    struct SegmentAnalysis: Codable, Sendable {
        var firingsMs: [Int64]
        var tracks: [FaceTrackEdl]
    }

    static func writeAnalysis(_ a: SegmentAnalysis, dir: URL, segment: Int) throws {
        try writeAtomically(try JSONEncoder().encode(a), to: analysisURL(dir, segment: segment))
    }

    static func readAnalysis(dir: URL, segment: Int) -> SegmentAnalysis? {
        guard let d = try? Data(contentsOf: analysisURL(dir, segment: segment)) else { return nil }
        return try? JSONDecoder().decode(SegmentAnalysis.self, from: d)
    }

    /// Segments already on disk, so resume can skip them.
    static func completedSegments(dir: URL, of plan: [RenderSegment]) -> Set<Int> {
        Set(plan.map(\.index).filter { FileManager.default.fileExists(atPath: segmentURL(dir, segment: $0).path) })
    }

    /// Runs at the head of every job. Descends only into the work root, and
    /// only into entries untouched for 7 days. A directory's own mtime does not
    /// track writes to files inside it on every filesystem, so a job is aged by
    /// its newest *file*.
    static func sweepStale(now: Date = Date()) {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(at: WorkDir.root,
                                                        includingPropertiesForKeys: [.isDirectoryKey])
        else { return }
        for dir in entries {
            guard (try? dir.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true else { continue }
            var newest = Date.distantPast
            let walker = fm.enumerator(at: dir, includingPropertiesForKeys: [.contentModificationDateKey])
            while let f = walker?.nextObject() as? URL {
                if let m = try? f.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate {
                    newest = max(newest, m)
                }
            }
            if now.timeIntervalSince(newest) > staleInterval {
                Log.job.notice("sweeping stale work dir \(dir.lastPathComponent, privacy: .public)")
                try? fm.removeItem(at: dir)
            }
        }
    }
}
