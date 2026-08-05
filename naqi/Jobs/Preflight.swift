import AVFoundation
import Foundation
import os

/// Reasons a job may not start. Each maps to one user-facing string.
enum PreflightFailure: Error, Equatable, Sendable {
    case drmProtected
    case noVideoTrack
    case noAudioTrack
    case unsupportedContainer(String)
    case lowSpace(requiredBytes: Int64, availableBytes: Int64)
    case sourceUnreadable
}

/// Guards run before any decoding starts. Order matters: DRM is checked before
/// codec lookup, because a protected track otherwise fails much later with an
/// opaque crypto error (Android `work/Preflight.kt:91-93`).
enum Preflight {

    /// 2 GiB of headroom on top of the computed requirement.
    static let slackBytes: Int64 = 2 * 1024 * 1024 * 1024

    /// Separated audio is held as int16 stereo 44.1 kHz: 176 400 B per second
    /// of source, ~1.6 GB on a 155-minute film. It scales with **duration**,
    /// not file size, so it cannot be folded into `tempCopies`.
    static let pcmBytesPerSecond: Int64 = 176_400
    /// AAC transcode scratch: 192 kbit/s stereo.
    static let aacBytesPerSecond: Int64 = 24_000

    /// Full-size temporary copies that coexist with the published output.
    /// Measured: the mux temp is a full-size copy of the source, so a 2 h movie
    /// exceeds any fixed "2 GB temp" budget by construction. The preflight
    /// sizes for that rather than asserting it (`docs/tasks.md:50` on Android).
    static func tempCopies(for ops: FilterOps, segmented: Bool) -> Int64 {
        // Segmented never holds three: the segments are deleted the moment the
        // concat lands, so the pairs that coexist are (segments, concat) and
        // then (concat, muxed output).
        if segmented { return 2 }
        if ops.shape == .both { return 2 } // render temp + published output
        return 1                           // one temp + the published copy
    }

    /// The PCM scratch only exists when the separator is **resumable** — being
    /// resumable is what makes it land `audio.pcm` on disk instead of streaming
    /// straight into the encoder. That is why the spec's combined row is a bare
    /// `3x source + 2 GiB`: a combined job is under 30 minutes by construction
    /// (a longer one dispatches to `segmented`) and never writes the scratch.
    ///
    /// Every `removeMusic` shape lands the separated track as a standalone
    /// `audio.m4a` **before** it is muxed in, so the encoded track is a real
    /// file that coexists with the output rather than bytes inside it. That is
    /// what makes music-only resumable (`JobRunner`), and it is a term the
    /// budget has to carry: 192 kbit/s over a 155-minute film is ~223 MB.
    ///
    /// The AAC term used to have a second trigger, for a segmented route that
    /// transcodes the source's own audio up front. No such route exists here —
    /// the Apple one copies the track through `Remux.mux` untouched — so the
    /// flag was charged by a unit test and by nothing else.
    static func extraScratchBytes(for ops: FilterOps, durationSeconds: Int64,
                                  segmented: Bool) -> Int64 {
        let resumableAudio = ops.removeMusic
            && durationSeconds * 1000 >= Checkpoint.longSourceThresholdMs
        let pcm = (resumableAudio || (segmented && ops.removeMusic))
            ? durationSeconds * pcmBytesPerSecond : 0
        let aac = ops.removeMusic ? durationSeconds * aacBytesPerSecond : 0
        return pcm + aac
    }

    static func requiredBytes(sourceBytes: Int64, tempCopies: Int64, extraScratch: Int64) -> Int64 {
        (tempCopies + 1) * sourceBytes + extraScratch + slackBytes
    }

    /// Runs every guard. Returns nil when the job may proceed.
    static func check(source: MediaSource, ops: FilterOps, segmented: Bool = false) async -> PreflightFailure? {
        let asset = AVURLAsset(url: source.url)

        if (try? await asset.load(.hasProtectedContent)) == true { return .drmProtected }
        if ops.censor && source.video == nil { return .noVideoTrack }
        if ops.removeMusic && source.audio == nil { return .noAudioTrack }
        if (try? await asset.load(.isPlayable)) != true {
            return .unsupportedContainer(source.url.pathExtension)
        }

        // The Apple equivalent of Android's `file://`-has-no-size trap: a
        // security-scoped Photos URL may not answer `.fileSize`, and a nil there
        // would silently degrade the whole check to the bare 2 GiB slack.
        guard let sourceBytes = fileSize(source.url) else { return .sourceUnreadable }

        let required = requiredBytes(
            sourceBytes: sourceBytes,
            tempCopies: tempCopies(for: ops, segmented: segmented),
            extraScratch: extraScratchBytes(for: ops,
                                            durationSeconds: Int64(source.duration.seconds),
                                            segmented: segmented))
        let available = availableBytes()
        Log.job.info("preflight need=\(required / 1_048_576)MiB have=\(available / 1_048_576)MiB")
        if available < required { return .lowSpace(requiredBytes: required, availableBytes: available) }
        return nil
    }

    static func fileSize(_ url: URL) -> Int64? {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        guard let v = try? url.resourceValues(forKeys: [.fileSizeKey, .totalFileSizeKey]) else { return nil }
        if let s = v.totalFileSize ?? v.fileSize, s > 0 { return Int64(s) }
        return nil
    }

    /// Space the app may actually use, which on iOS is the "important" volume
    /// capacity, not the raw free-space number.
    static func availableBytes() -> Int64 {
        let dir = WorkDir.root
        if let v = try? dir.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]),
           let c = v.volumeAvailableCapacityForImportantUsage {
            return Int64(c)
        }
        let attrs = try? FileManager.default.attributesOfFileSystem(forPath: dir.path)
        return (attrs?[.systemFreeSize] as? NSNumber)?.int64Value ?? 0
    }
}

/// Scratch lives in a no-backup directory, never next to the source — part of
/// the original-untouched guarantee.
enum WorkDir {
    static let root: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("naqi-work", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        var b = base
        var rv = URLResourceValues()
        rv.isExcludedFromBackup = true
        try? b.setResourceValues(rv)
        return base
    }()

    static func job(_ key: String) -> URL {
        let d = root.appendingPathComponent(key, isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    static func clear(_ key: String) {
        try? FileManager.default.removeItem(at: root.appendingPathComponent(key, isDirectory: true))
    }
}

/// `<sourceNameNoExt>-naqi-<epochMillis>.<ext>`. The epoch suffix is the only
/// collision defence; keeping the source's stem is what stops a downloaded
/// video losing its title one step before the user sees it.
func outputName(for source: URL, ext: String = "mp4") -> String {
    let stem = source.deletingPathExtension().lastPathComponent
    let name = stem.isEmpty ? "video" : stem
    return "\(name)-naqi-\(Int64(Date().timeIntervalSince1970 * 1000)).\(ext)"
}
