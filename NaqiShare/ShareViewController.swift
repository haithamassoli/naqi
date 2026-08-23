import OSLog
import UIKit
import UniformTypeIdentifiers

/// Share-sheet target for video and audio.
///
/// **This extension copies bytes and nothing else.** iOS gives a share
/// extension roughly 120 MB and kills it for exceeding that, so it never opens
/// a model, never decodes a frame and never reads a video into memory — it
/// streams each item into the App Group inbox with `FileManager.copyItem` and
/// leaves every decision to the app, which drains the inbox at launch and on
/// every activation (`ShareInbox.drain`).
///
final class ShareViewController: UIViewController {

    /// The two roots the activation rule admits, **in the order they are tried**.
    /// Movie first is load-bearing: an audio-only `.mp4` conforms to both, and
    /// asking a movie provider for `public.audio` can hand back a re-encoded
    /// extraction instead of the file the user shared.
    private static let accepted: [UTType] = [.movie, .audio]

    private let label = UILabel()
    private let spinner = UIActivityIndicatorView(style: .large)
    private let musicSwitch = UISwitch()
    private let censorSwitch = UISwitch()
    private let whoControl = UISegmentedControl(items: [
        String(localized: "share.women", defaultValue: "Women"),
        String(localized: "share.men", defaultValue: "Men"),
        String(localized: "share.everyone", defaultValue: "Everyone"),
    ])
    private let addButton = UIButton(type: .system)
    private let optionsStack = UIStackView()
    private var accepting = false

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground

        let options = ShareOptions.loadLastUsed()
        musicSwitch.isOn = options.removeMusic
        censorSwitch.isOn = options.censor
        musicSwitch.addTarget(self, action: #selector(optionsChanged), for: .valueChanged)
        censorSwitch.addTarget(self, action: #selector(optionsChanged), for: .valueChanged)
        whoControl.selectedSegmentIndex = ["women", "men", "everyone"].firstIndex(of: options.who) ?? 0

        label.text = String(localized: "share.options", defaultValue: "Add to Naqi")
        label.textAlignment = .center
        label.font = .preferredFont(forTextStyle: .headline)
        label.adjustsFontForContentSizeCategory = true
        label.numberOfLines = 0

        optionsStack.axis = .vertical
        optionsStack.spacing = 12
        optionsStack.addArrangedSubview(row(String(localized: "share.remove_music",
                                                    defaultValue: "Remove music"), musicSwitch))
        optionsStack.addArrangedSubview(row(String(localized: "share.censor_faces",
                                                    defaultValue: "Cover faces"), censorSwitch))
        optionsStack.addArrangedSubview(whoControl)

        var config = UIButton.Configuration.filled()
        config.title = String(localized: "share.add", defaultValue: "Add")
        config.cornerStyle = .large
        addButton.configuration = config
        addButton.addTarget(self, action: #selector(addTapped), for: .touchUpInside)
        addButton.isEnabled = musicSwitch.isOn || censorSwitch.isOn

        let stack = UIStackView(arrangedSubviews: [label, optionsStack, addButton, spinner])
        stack.axis = .vertical
        stack.spacing = 16
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            stack.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -24),
        ])
    }

    private func row(_ title: String, _ control: UIView) -> UIView {
        let text = UILabel()
        text.text = title
        text.font = .preferredFont(forTextStyle: .body)
        text.adjustsFontForContentSizeCategory = true
        text.isAccessibilityElement = false
        control.accessibilityLabel = title
        let row = UIStackView(arrangedSubviews: [text, control])
        row.axis = .horizontal
        row.alignment = .center
        row.spacing = 12
        return row
    }

    @objc private func addTapped() {
        guard !accepting else { return }
        accepting = true
        optionsStack.isHidden = true
        addButton.isHidden = true
        label.text = String(localized: "share.adding", defaultValue: "Adding to Naqi…")
        spinner.startAnimating()
        let who = ["women", "men", "everyone"][max(0, whoControl.selectedSegmentIndex)]
        let options = ShareOptions(removeMusic: musicSwitch.isOn, censor: censorSwitch.isOn, who: who)
        options.saveAsLastUsed()
        Task { await accept(options: options) }
    }

    @objc private func optionsChanged() {
        addButton.isEnabled = musicSwitch.isOn || censorSwitch.isOn
    }

    private func accept(options: ShareOptions) async {
        // Unfiltered: `copy` has to pick *which* accepted type to load anyway,
        // and returns false for an attachment that is neither.
        let providers = (extensionContext?.inputItems as? [NSExtensionItem] ?? [])
            .flatMap { $0.attachments ?? [] }

        var taken = 0
        if let dir = AppGroup.inbox {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            for provider in providers where await copy(provider, into: dir, options: options) { taken += 1 }
        }

        spinner.stopAnimating()
        // The extension is the only place the user learns this failed. An
        // entitlement mismatch or a full disk here would otherwise look exactly
        // like success and the file would simply never appear in the app.
        label.text = taken > 0
            ? String(localized: "share.queued", defaultValue: "Added to Naqi")
            : String(localized: "share.failed", defaultValue: "Couldn’t add this file")

        try? await Task.sleep(for: .milliseconds(taken > 0 ? 600 : 1600))
        extensionContext?.completeRequest(returningItems: nil)
    }

    /// Stream one item into the inbox. Returns whether the app will see it.
    private func copy(_ provider: NSItemProvider, into dir: URL, options: ShareOptions) async -> Bool {
        guard let type = Self.accepted.first(where: {
            provider.hasItemConformingToTypeIdentifier($0.identifier)
        }) else { return false }
        let id = UUID()
        do {
            // `loadFileRepresentation` hands back a URL that is valid only for
            // the duration of the call, hence the copy inside the continuation
            // rather than after it.
            let name = try await withCheckedThrowingContinuation { (k: CheckedContinuation<String, Error>) in
                provider.loadFileRepresentation(forTypeIdentifier: type.identifier) { url, error in
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
                ShareManifest(id: id, fileName: name, receivedAt: Date(), options: options))
            try data.write(to: ShareManifest.manifestURL(dir, id: id), options: .atomic)
            return true
        } catch {
            // Drop the half-copied media: with no manifest the app would ignore
            // it anyway, and it would sit in the shared container forever. By
            // id prefix rather than by a guessed extension — the copy above
            // keeps the source's own, so the old `ext: "mp4"` here missed every
            // `.mov`, and would now miss every `.mp3` too.
            for f in (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
            where f.hasPrefix(id.uuidString) {
                try? FileManager.default.removeItem(at: dir.appendingPathComponent(f))
            }
            Logger(subsystem: "com.haithamassoli.naqi", category: "share")
                .error("share copy failed: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }
}
