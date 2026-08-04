#if DEBUG
import Foundation

/// Screenshot harness. `-naqiScreen picked|options|progress|done` puts the flow
/// on one screen with plausible state so every step can be captured — including
/// in Arabic — without a running job and without a tap.
///
/// DEBUG only, and deliberately not a preview trait: the screens have to be
/// audited in the real app, in the real locale, at the real device size. It
/// fabricates a job row that no user action produced, so nothing outside a
/// debug build may be able to reach it.
extension Flow {

    func seedFromLaunchArguments() {
        guard let i = CommandLine.arguments.firstIndex(of: "-naqiScreen"),
              i + 1 < CommandLine.arguments.count
        else { return }
        let screen = CommandLine.arguments[i + 1]
        guard screen != "pick" else { return }

        // A real clip staged into Documents by the capture script takes
        // precedence, so `-naqiScreen run` drives a genuine job through the
        // same screens the other modes only pose.
        let staged = URL.documentsDirectory.appendingPathComponent("screenshot-source.mp4")
        let url = FileManager.default.fileExists(atPath: staged.path)
            ? staged
            : FileManager.default.temporaryDirectory.appendingPathComponent("holiday-in-tabuk.mp4")
        if url != staged { FileManager.default.createFile(atPath: url.path, contents: Data()) }
        // 43 min: past the 30-minute confirm threshold, so the ETA line and the
        // long-job dialog are both live.
        seed(source: PickedSource(url: url, name: url.lastPathComponent, securityScoped: true),
             durationMs: 43 * 60 * 1000)
        ops.removeMusic = true
        ops.censor = true

        switch screen {
        case "options":
            path = [.options]
        case "progress":
            path = [.progress]
            var bar = JobProgress(shape: .combined, removeMusic: true)
            bar.post(.analyze, 0.72)
            bar.post(.separate, 0.35)
            monitor.seed(state: .running, progress: bar)
        case "done":
            path = [.done]
            // `url:` non-nil poses the folder destination, which is the only
            // one that can show Open and Share — the Photos publish the app
            // actually uses leaves nothing openable behind.
            monitor.seed(state: .done(Published(name: "holiday-in-tabuk-naqi-1754320000000.mp4",
                                                url: url, assetID: nil)),
                         progress: nil)
        case "about":
            path = [.about]
        case "run":
            // Censor-only: the same four screens, real work behind them, and
            // no 88 MB htdemucs graph to load on a simulator.
            ops.removeMusic = false
            ops.censor = true
            Task { await start() }
        default:
            break
        }
    }
}
#endif
