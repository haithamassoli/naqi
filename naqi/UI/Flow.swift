import CoreTransferable
import Foundation
import Photos
import SwiftUI
import UniformTypeIdentifiers
import os

/// The picked video and the one handle that can delete it later.
struct PickedSource: Sendable, Equatable, Identifiable {
    let url: URL
    let name: String
    /// `PHAsset` local identifier when the video came from the photo library.
    /// Without it "Delete original" has nothing to delete — a Photos pick hands
    /// back a copy in our own container, and deleting that would be a lie.
    var assetID: String?
    /// A Files pick hands back a security-scoped URL. Access opens when the
    /// pick lands and closes only when it is replaced: the job holds this URL
    /// for hours, so nothing may `stopAccessing` in a `defer`.
    var securityScoped = false

    var id: URL { url }
}

/// The Photos transfer. There is no zero-copy path out of PhotosUI —
/// `loadTransferable` writes the asset into a temp file and the copy is the
/// price of not asking for full-library authorization just to read one video.
struct MovieFile: Transferable {
    let url: URL

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(importedContentType: .movie) { received in
            // `received.file` is deleted the moment the closure returns, so the
            // copy is mandatory rather than an optimisation we could skip.
            let dest = FileManager.default.temporaryDirectory
                .appendingPathComponent(received.file.lastPathComponent)
            try? FileManager.default.removeItem(at: dest)
            try FileManager.default.copyItem(at: received.file, to: dest)
            return MovieFile(url: dest)
        }
    }
}

/// True for a file the pick screen will take from a drag.
///
/// `.dropDestination(for: URL.self)` has no `allowedContentTypes` — it hands
/// over whatever file URL was dropped, including a folder or a PDF — so the
/// filter `fileImporter` gets for free has to be applied by hand, against the
/// same list. Rejecting here rather than queueing matters: a dropped PDF would
/// otherwise become a job that dies at preflight as "the file could not be
/// read", which blames the pipeline for a mis-drop.
///
/// Type comes from the file when the file is there, and from the extension when
/// it is not. `public.movie` and `public.audio` are the two roots the importer
/// lists — `.video`, `.mpeg4Movie`, `.mp3`, `.wav` and the rest all conform to
/// one of them. A bare audio file is accepted because `removeMusic` is a real
/// job shape for it (`Job.shape`, `audioOnly`); censoring is not, which is what
/// `Flow.isAudioOnly` turns off.
func isDroppableSource(_ url: URL) -> Bool {
    let type = (try? url.resourceValues(forKeys: [.contentTypeKey]).contentType)
        ?? UTType(filenameExtension: url.pathExtension)
    guard let type else { return false }
    return type.conforms(to: .movie) || type.conforms(to: .audio)
}

/// Four steps in a straight line. There is no route DSL because there is no
/// graph: Options is a detour off Pick, and Progress ends the flow.
///
/// State lives here rather than in each screen because a filter job runs for
/// minutes — dropping the user back on Pick with no route to the running job is
/// exactly the failure the Android version had to fix (spec contract 7.1.1).
@MainActor @Observable final class Flow {

    enum Step: Hashable, Sendable { case options, progress, done, about, diagnostics }

    var path: [Step] = []
    var ops: FilterOps = .loadLastUsed()
    private(set) var source: PickedSource?
    /// 0 means "no estimate" — still probing, or the probe threw. A failure is
    /// deliberately silent: an unreadable source is Preflight's story to tell,
    /// and a broken probe must never stand between the user and Start.
    private(set) var durationMs: Int64 = 0
    /// Photos or a folder, and the folder itself. Resolved once per launch —
    /// `loadLastUsed` opens a security scope it never closes.
    private(set) var export = ExportTarget.loadLastUsed()
    /// `nil` until the probe answers, and it never becomes `nil` again for a
    /// source that probed. Only `false` locks the destination.
    private(set) var sourceHasVideo: Bool?

    let monitor: JobMonitor

    /// - Parameter monitor: the app always watches the shared queue; a test
    ///   hands in one pointed at a scratch store so asserting what `start`
    ///   enqueues does not write into the user's `naqi-queue.json`.
    init(monitor: JobMonitor = JobMonitor()) { self.monitor = monitor }

    var canContinue: Bool { source != nil && ops.isValid }
    var estimateMs: Int64 { Eta.estimateMs(durationMs: durationMs, ops: ops) }

    /// The picked file has no picture, so there is nothing to censor and
    /// removing music is the only thing that can be done to it. Two consequences
    /// hang off this: the censor row is not offered, and Photos is not reachable
    /// — `PHAssetCreationRequest` refuses a bare audio resource and the runner
    /// turns that into `publishFailed`, a failure with no sentence the user can
    /// act on. The folder is therefore **forced** rather than defaulted: a
    /// default can be overridden back into a job that is certain to fail.
    ///
    /// `nil` — still probing, or the probe threw — is not audio-only.
    var isAudioOnly: Bool { sourceHasVideo == false }

    var destination: Destination { isAudioOnly ? .userFolder : export.destination }

    /// Start, as opposed to Pick's Continue. A folder destination with no
    /// folder throws `destinationUnwritable("no folder chosen")` at the last
    /// stage of the job — hours in, on a film. Disabling the button before the
    /// fact is the only version of that the user can do anything about.
    ///
    /// Deliberately not folded into `canContinue`: Pick's Continue is the only
    /// route to the screen that picks the folder, so gating it on the folder
    /// would strand an audio-only source with no way forward.
    var canStart: Bool { canContinue && (destination == .photos || export.folder != nil) }

    func setSource(_ new: PickedSource) {
        if let old = source, old.securityScoped { old.url.stopAccessingSecurityScopedResource() }
        source = new
        durationMs = 0
        sourceHasVideo = nil
        Task { [url = new.url] in
            let probed = await Self.probe(url)
            guard source?.url == url else { return }
            adoptProbe(ms: probed.ms, hasVideo: probed.hasVideo)
        }
    }

    /// What the probe's answer changes. Split out so the screenshot harness
    /// poses the same state the probe would rather than a subset of it.
    private func adoptProbe(ms: Int64, hasVideo: Bool?) {
        durationMs = ms
        sourceHasVideo = hasVideo
        // Options carried over from the last run can only produce a job an
        // audio file is certain to fail: censor has no picture to work on.
        // Removing music is the one operation it *can* have done, so it is the
        // one that is on. That row stays editable — turning it off simply
        // leaves nothing to do, and Continue greys out the way it does for a
        // video with both operations off.
        if hasVideo == false {
            ops.censor = false
            ops.removeMusic = true
        }
    }

    func adoptFileImport(_ url: URL) {
        let scoped = url.startAccessingSecurityScopedResource()
        setSource(PickedSource(url: url, name: url.lastPathComponent, securityScoped: scoped))
    }

    func setDestination(_ new: Destination) {
        export.destination = new
        export.saveAsLastUsed()
    }

    /// Opens the folder's security scope and keeps it open. The job publishes
    /// into it minutes or hours from now, so nothing may `stopAccessing` in a
    /// `defer` — the same rule the picked source lives under.
    func setFolder(_ url: URL) {
        if let old = export.folder, old != url { old.stopAccessingSecurityScopedResource() }
        _ = url.startAccessingSecurityScopedResource()
        export.folder = url
        export.destination = .userFolder
        export.saveAsLastUsed()
    }

    func start() async {
        guard let source, canStart else { return }
        ops.saveAsLastUsed()
        path = [.progress]
        await monitor.start(source: source, ops: ops,
                            destination: destination, folder: export.folder)
    }

    /// Enqueues whatever the share extension left in the App Group container,
    /// with the destination this launch resolved. Returns how many it took, so
    /// a test can assert the choice travelled rather than that the call exists.
    ///
    /// - Parameter queue: the app always drains into the shared one; a test
    ///   points it at a scratch store so it does not enqueue into the user's
    ///   real `naqi-queue.json`.
    @discardableResult
    func drainSharedIn(into queue: JobQueue = .shared) async -> Int {
        // `export`, not `destination`: `isAudioOnly` describes the *picked*
        // source, and a shared-in file is a different one.
        await ShareInbox.drain(into: queue,
                               destination: export.destination, folder: export.folder)
    }

    func cancelJob() async {
        await monitor.cancel()
        path = []
    }

    func finishAndPickAnother() async {
        await monitor.finish()
        path = []
    }

    #if DEBUG
    /// Screenshot harness only — sets the fields without the probe, whose async
    /// answer would otherwise land after the seed and reset the duration.
    func seed(source: PickedSource, durationMs: Int64, hasVideo: Bool = true) {
        self.source = source
        adoptProbe(ms: durationMs, hasVideo: hasVideo)
    }
    #endif

    /// `hasVideo` is `nil` when the probe threw — "unknown", not "no video".
    /// Locking the destination on a source we could not read would trade
    /// Preflight's honest error for a silently different one.
    private static func probe(_ url: URL) async -> (ms: Int64, hasVideo: Bool?) {
        guard let src = try? await MediaSource.probe(url) else { return (0, nil) }
        return (src.duration.isNumeric ? Int64(src.duration.seconds * 1000) : 0, src.video != nil)
    }

    // MARK: - Delete original

    /// Best-effort and it **always reports failure**. Silently keeping a file
    /// the user asked to delete is worse than saying we could not (spec §5.4).
    /// Two-step and opt-in: the caller has already shown the confirm dialog.
    func deleteOriginal() async -> Bool {
        guard let source else { return false }
        if let assetID = source.assetID {
            let assets = PHAsset.fetchAssets(withLocalIdentifiers: [assetID], options: nil)
            guard assets.count > 0 else { return false }
            do {
                // The system puts up its own confirmation on top of ours. That
                // is one prompt too many by design: this is unrecoverable.
                try await PHPhotoLibrary.shared().performChanges {
                    PHAssetChangeRequest.deleteAssets(assets)
                }
                return true
            } catch {
                Log.job.error("delete original failed: \(error.localizedDescription, privacy: .public)")
                return false
            }
        }
        do {
            try FileManager.default.removeItem(at: source.url)
            return true
        } catch {
            Log.job.error("delete original failed: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }
}
