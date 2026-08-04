import OSLog
import UIKit
import UniformTypeIdentifiers

/// Share-sheet target for videos.
///
/// **This extension copies bytes and nothing else.** iOS gives a share
/// extension roughly 120 MB and kills it for exceeding that, so it never opens
/// a model, never decodes a frame and never reads a video into memory — it
/// streams each item into the App Group inbox with `FileManager.copyItem` and
/// leaves every decision to the app, which drains the inbox at launch and on
/// every activation (`ShareInbox.drain`).
///
/// There is deliberately no options UI. Share-in inherits the app's last-used
/// settings, which is what the PRD's flow promises; an extension that asked
/// again would be a second place for those defaults to live.
final class ShareViewController: UIViewController {

    private let label = UILabel()
    private let spinner = UIActivityIndicatorView(style: .large)

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground

        label.text = String(localized: "share.adding", defaultValue: "Adding to Naqi…")
        label.textAlignment = .center
        label.font = .preferredFont(forTextStyle: .headline)
        label.adjustsFontForContentSizeCategory = true
        label.numberOfLines = 0

        let stack = UIStackView(arrangedSubviews: [spinner, label])
        stack.axis = .vertical
        stack.spacing = 16
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor, constant: 32),
        ])
        spinner.startAnimating()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        Task { await accept() }
    }

    private func accept() async {
        let providers = (extensionContext?.inputItems as? [NSExtensionItem] ?? [])
            .flatMap { $0.attachments ?? [] }
            .filter { $0.hasItemConformingToTypeIdentifier(UTType.movie.identifier) }

        var taken = 0
        if let dir = AppGroup.inbox {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            for provider in providers where await copy(provider, into: dir) { taken += 1 }
        }

        spinner.stopAnimating()
        // The extension is the only place the user learns this failed. An
        // entitlement mismatch or a full disk here would otherwise look exactly
        // like success and the video would simply never appear in the app.
        label.text = taken > 0
            ? String(localized: "share.queued", defaultValue: "Added to Naqi")
            : String(localized: "share.failed", defaultValue: "Couldn’t add this video")

        try? await Task.sleep(for: .milliseconds(taken > 0 ? 600 : 1600))
        extensionContext?.completeRequest(returningItems: nil)
    }

    /// Stream one item into the inbox. Returns whether the app will see it.
    private func copy(_ provider: NSItemProvider, into dir: URL) async -> Bool {
        let id = UUID()
        do {
            // `loadFileRepresentation` hands back a URL that is valid only for
            // the duration of the call, hence the copy inside the continuation
            // rather than after it.
            let name = try await withCheckedThrowingContinuation { (k: CheckedContinuation<String, Error>) in
                provider.loadFileRepresentation(forTypeIdentifier: UTType.movie.identifier) { url, error in
                    guard let url else {
                        k.resume(throwing: error ?? CocoaError(.fileNoSuchFile)); return
                    }
                    let ext = url.pathExtension.isEmpty ? "mp4" : url.pathExtension
                    do {
                        try FileManager.default.copyItem(
                            at: url, to: ShareManifest.mediaURL(dir, id: id, ext: ext))
                        k.resume(returning: url.lastPathComponent)
                    } catch {
                        k.resume(throwing: error)
                    }
                }
            }
            // Manifest last, always: it is the completion marker, and a reader
            // that finds it must be able to trust the bytes are all there.
            let data = try JSONEncoder().encode(
                ShareManifest(id: id, fileName: name, receivedAt: Date()))
            try data.write(to: ShareManifest.manifestURL(dir, id: id), options: .atomic)
            return true
        } catch {
            // Drop the half-copied movie: with no manifest the app would ignore
            // it anyway, and it would sit in the shared container forever.
            try? FileManager.default.removeItem(
                at: ShareManifest.mediaURL(dir, id: id, ext: "mp4"))
            Logger(subsystem: "com.haithamassoli.naqi", category: "share")
                .error("share copy failed: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }
}
