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

    let monitor = JobMonitor()

    var canContinue: Bool { source != nil && ops.isValid }
    var estimateMs: Int64 { Eta.estimateMs(durationMs: durationMs, ops: ops) }

    func setSource(_ new: PickedSource) {
        if let old = source, old.securityScoped { old.url.stopAccessingSecurityScopedResource() }
        source = new
        durationMs = 0
        Task { [url = new.url] in
            let ms = await Self.probeDurationMs(url)
            if source?.url == url { durationMs = ms }
        }
    }

    func adoptFileImport(_ url: URL) {
        let scoped = url.startAccessingSecurityScopedResource()
        setSource(PickedSource(url: url, name: url.lastPathComponent, securityScoped: scoped))
    }

    func start() async {
        guard let source, ops.isValid else { return }
        ops.saveAsLastUsed()
        path = [.progress]
        await monitor.start(source: source, ops: ops)
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
    /// Screenshot harness only — sets both fields without the probe, whose
    /// async answer would otherwise land after the seed and reset the duration.
    func seed(source: PickedSource, durationMs: Int64) {
        self.source = source
        self.durationMs = durationMs
    }
    #endif

    private static func probeDurationMs(_ url: URL) async -> Int64 {
        guard let src = try? await MediaSource.probe(url), src.duration.isNumeric else { return 0 }
        return Int64(src.duration.seconds * 1000)
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
