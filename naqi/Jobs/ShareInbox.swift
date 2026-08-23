import AVFoundation
import Foundation
import os

/// The share-extension handoff, main-app side.
///
/// A share extension gets roughly 120 MB and is killed for exceeding it, so it
/// cannot open a model, decode a frame or touch a video byte beyond copying the
/// file. It therefore does exactly two things — copy the shared media into the
/// App Group container, then write a manifest beside it — and the app drains
/// the result at launch and on every foreground.
///
/// The writing side is `NaqiShare/ShareViewController.swift`; the file format
/// both agree on is `ShareManifest` in `NaqiShared/`, compiled into both
/// targets so it cannot drift.
enum ShareInbox {

    static var container: URL? { AppGroup.inbox }

    /// Enqueues everything waiting and returns how many were taken. Safe to
    /// call repeatedly; a drained item is deleted from the container.
    @discardableResult
    static func drain(into queue: JobQueue,
                      destination: Destination = .photos,
                      folder: URL? = nil) async -> Int {
        guard let dir = container,
              let entries = try? FileManager.default.contentsOfDirectory(
                at: dir, includingPropertiesForKeys: [.contentModificationDateKey])
        else { return 0 }

        var taken = 0
        // Oldest first: "multiple shares run in order" is the shared-in
        // promise, and the queue itself is strictly serial.
        for manifest in entries.filter({ $0.pathExtension == "json" }).sorted(by: olderFirst) {
            guard let data = try? Data(contentsOf: manifest),
                  let handoff = try? JSONDecoder().decode(ShareManifest.self, from: data),
                  let media = media(for: handoff, in: dir) else {
                // A manifest with no media is an extension that died between
                // the two writes. Nothing to run, so drop it.
                try? FileManager.default.removeItem(at: manifest)
                continue
            }

            // Move it out of the shared container before enqueueing: the
            // container is not the app's to keep a multi-hour job's input in,
            // and a second share of the same file must not race this one.
            let owned = adopt(media, named: handoff.fileName)
            let job = Job.capture(source: owned,
                                  ops: await ops(for: owned, shared: handoff.options),
                                  destination: destination,
                                  folder: folder,
                                  title: (handoff.fileName as NSString).deletingPathExtension)
            await queue.enqueue(job)
            try? FileManager.default.removeItem(at: manifest)
            taken += 1
        }
        if taken > 0 { Log.job.info("share inbox: enqueued \(taken)") }
        return taken
    }

    /// Last-used options, minus what the shared file cannot do — `FilterOps.fit`
    /// is the same coercion `Flow` applies to a pick. The extension deliberately
    /// carries no options UI, so this is the single place share-in settings are
    /// decided, and a censor job queued on an audio file would die at
    /// `Preflight` *after* the share sheet said it was added.
    ///
    /// The video-track question is asked of the file, never of its extension:
    /// an audio-only `.mp4` is a movie container and gets this too.
    private static func ops(for url: URL, shared: ShareOptions?) async -> FilterOps {
        var ops = FilterOps.loadLastUsed()
        if let shared {
            ops.removeMusic = shared.removeMusic
            ops.censor = shared.censor
            ops.who = FilterOps.Who(rawValue: shared.who) ?? ops.who
        }
        // Not `MediaSource.probe`: this runs for every shared item at launch,
        // and precise-duration loading would read far more of the file than
        // "does it have a video track" needs.
        let tracks = try? await AVURLAsset(url: url).loadTracks(withMediaType: .video)
        ops.fit(hasVideo: tracks.map { !$0.isEmpty })
        return ops
    }

    private static func olderFirst(_ a: URL, _ b: URL) -> Bool {
        func stamp(_ u: URL) -> Date {
            (try? u.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
                ?? .distantPast
        }
        return stamp(a) < stamp(b)
    }

    private static func media(for handoff: ShareManifest, in dir: URL) -> URL? {
        let ext = (handoff.fileName as NSString).pathExtension
        let named = ShareManifest.mediaURL(dir, id: handoff.id, ext: ext.isEmpty ? "mp4" : ext)
        if FileManager.default.fileExists(atPath: named.path) { return named }
        // The extension is allowed to keep the original extension case or
        // rewrite the container; find the id's file whatever it is called.
        return (try? FileManager.default.contentsOfDirectory(atPath: dir.path))?
            .first { $0.hasPrefix(handoff.id.uuidString) && !$0.hasSuffix(".json") }
            .map { dir.appendingPathComponent($0) }
    }

    /// Shared container → app-owned scratch. Falls back to the shared copy if
    /// the move fails, so a share never silently disappears.
    private static func adopt(_ media: URL, named name: String) -> URL {
        var dir = WorkDir.root.deletingLastPathComponent()
            .appendingPathComponent("naqi-shared", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        // A shared-in film is gigabytes of someone else's video sitting in our
        // container; it has no business in a cloud backup. Sibling of the work
        // root rather than inside it, so the 7-day sweep cannot take an input
        // out from under a queued job.
        var rv = URLResourceValues()
        rv.isExcludedFromBackup = true
        try? dir.setResourceValues(rv)
        let dest = dir.appendingPathComponent("\(UUID().uuidString)-\(name)")
        do {
            try FileManager.default.moveItem(at: media, to: dest)
            return dest
        } catch {
            Log.job.error("share inbox: could not adopt \(name, privacy: .public)")
            return media
        }
    }
}
