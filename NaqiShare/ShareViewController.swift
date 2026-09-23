import OSLog
import UIKit
import UniformTypeIdentifiers

/// Share-sheet target for video, audio, **and links**.
///
/// **This extension copies bytes (or a URL) and nothing else.** iOS gives a
/// share extension roughly 120 MB and kills it for exceeding that, so it never
/// opens a model, never runs yt-dlp and never reads a video into memory — it
/// streams each file into the App Group inbox, or writes a URL manifest, and
/// leaves every decision to the app (`ShareInbox.drain`).
///
final class ShareViewController: UIViewController {

    /// The two roots the activation rule admits for files, **in the order they
    /// are tried**. Movie first is load-bearing: an audio-only `.mp4` conforms
    /// to both, and asking a movie provider for `public.audio` can hand back a
    /// re-encoded extraction instead of the file the user shared.
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
    private let qualityControl = UISegmentedControl(items: [
        String(localized: "share.quality_best", defaultValue: "Best"),
        String(localized: "share.quality_1080", defaultValue: "1080p"),
        String(localized: "share.quality_720", defaultValue: "720p"),
        String(localized: "share.quality_480", defaultValue: "480p"),
        String(localized: "share.quality_audio", defaultValue: "Audio only"),
    ])
    private let processingControl = UISegmentedControl(items: [
        String(localized: "share.performance_current", defaultValue: "Current"),
        String(localized: "share.performance_fast", defaultValue: "Fast"),
    ])
    private let addButton = UIButton(type: .system)
    private let optionsStack = UIStackView()
    private var accepting = false
    private var sharedURL: String?

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground

        let options = ShareOptions.loadLastUsed()
        musicSwitch.isOn = options.removeMusic
        censorSwitch.isOn = options.censor
        musicSwitch.addTarget(self, action: #selector(optionsChanged), for: .valueChanged)
        censorSwitch.addTarget(self, action: #selector(optionsChanged), for: .valueChanged)
        whoControl.selectedSegmentIndex = ["women", "men", "everyone"].firstIndex(of: options.who) ?? 0
        // Visual order matches the Android RTL screenshot (Audio…Best) and
        // flips with the system layout direction via UISegmentedControl.
        qualityControl.selectedSegmentIndex = qualityIndex(DownloadQuality.loadLastUsed())
        qualityControl.addTarget(self, action: #selector(qualityChanged), for: .valueChanged)
        qualityControl.isHidden = true
        processingControl.selectedSegmentIndex = options.processingMode == "fast" ? 1 : 0

        label.text = String(localized: "share.options", defaultValue: "Add to Naqi")
        label.textAlignment = .center
        label.font = .preferredFont(forTextStyle: .headline)
        label.adjustsFontForContentSizeCategory = true
        label.numberOfLines = 0

        optionsStack.axis = .vertical
        optionsStack.spacing = 12
        optionsStack.addArrangedSubview(qualityControl)
        optionsStack.addArrangedSubview(row(String(localized: "share.performance",
                                                   defaultValue: "Processing"), processingControl))
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
        Task { await detectLink() }
    }

    /// Show the quality picker only when the share is a page URL, not a file.
    /// A Files share often attaches both the movie and a `file://` URL; treating
    /// that as a link would skip the copy and the inbox would drop it.
    private func detectLink() async {
        let providers = (extensionContext?.inputItems as? [NSExtensionItem] ?? [])
            .flatMap { $0.attachments ?? [] }
        if providers.contains(where: isMedia) { return }
        if let url = await firstURL(in: providers) {
            sharedURL = url
            await MainActor.run {
                qualityControl.isHidden = false
                addButton.configuration?.title = String(localized: "share.download",
                                                        defaultValue: "Download")
                qualityChanged()
            }
        }
    }

    private func isMedia(_ provider: NSItemProvider) -> Bool {
        Self.accepted.contains { provider.hasItemConformingToTypeIdentifier($0.identifier) }
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
        var removeMusic = musicSwitch.isOn
        var censor = censorSwitch.isOn
        let quality = selectedQuality()
        if quality == .audio { censor = false; if !removeMusic { removeMusic = true } }
        let options = ShareOptions(removeMusic: removeMusic, censor: censor, who: who,
                                   processingMode: processingControl.selectedSegmentIndex == 1 ? "fast" : "current")
        options.saveAsLastUsed()
        quality.saveAsLastUsed()
        Task { await accept(options: options, quality: quality) }
    }

    @objc private func optionsChanged() {
        let link = sharedURL != nil
        addButton.isEnabled = link || musicSwitch.isOn || censorSwitch.isOn
    }

    @objc private func qualityChanged() {
        let audio = selectedQuality() == .audio
        censorSwitch.isEnabled = !audio
        whoControl.isEnabled = !audio
        optionsChanged()
    }

    private func selectedQuality() -> DownloadQuality {
        // Same order as `DownloadQuality.allCases` / Android `Quality.entries`.
        // RTL flips the control, which is how the screenshot reads Audio-first.
        switch qualityControl.selectedSegmentIndex {
        case 0: .best
        case 1: .p1080
        case 2: .p720
        case 3: .p480
        default: .audio
        }
    }

    private func qualityIndex(_ q: DownloadQuality) -> Int {
        switch q {
        case .best: 0
        case .p1080: 1
        case .p720: 2
        case .p480: 3
        case .audio: 4
        }
    }

    private func accept(options: ShareOptions, quality: DownloadQuality) async {
        // Unfiltered: `copy` has to pick *which* accepted type to load anyway,
        // and returns false for an attachment that is neither.
        let providers = (extensionContext?.inputItems as? [NSExtensionItem] ?? [])
            .flatMap { $0.attachments ?? [] }

        var taken = 0
        if let dir = AppGroup.inbox {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            for provider in providers {
                if await copy(provider, into: dir, options: options) { taken += 1 }
            }
            if taken == 0 {
                let page: String?
                if let sharedURL {
                    page = sharedURL
                } else {
                    page = await firstURL(in: providers)
                }
                if let page, VideoURL.first(in: page) != nil {
                    if await writeLink(page, into: dir, options: options, quality: quality) {
                        taken += 1
                    }
                }
            }
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

    /// First http(s) URL among the attachments: a `public.url` item, or the
    /// first URL inside shared plain text.
    private func firstURL(in providers: [NSItemProvider]) async -> String? {
        for provider in providers {
            if provider.hasItemConformingToTypeIdentifier(UTType.url.identifier) {
                if let url = await loadURL(provider) { return url }
            }
        }
        for provider in providers {
            if provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier) {
                if let text = await loadText(provider), let url = VideoURL.first(in: text) {
                    return url
                }
            }
        }
        return nil
    }

    private func writeLink(_ url: String, into dir: URL, options: ShareOptions,
                           quality: DownloadQuality) async -> Bool {
        let id = UUID()
        let host = URL(string: url)?.host ?? "download"
        do {
            let data = try JSONEncoder().encode(
                ShareManifest(id: id, fileName: host, receivedAt: Date(),
                              options: options, url: url, quality: quality.rawValue))
            try data.write(to: ShareManifest.manifestURL(dir, id: id), options: .atomic)
            return true
        } catch {
            Logger(subsystem: "com.haithamassoli.naqi", category: "share")
                .error("share link failed: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    private func loadURL(_ provider: NSItemProvider) async -> String? {
        await withCheckedContinuation { cont in
            provider.loadItem(forTypeIdentifier: UTType.url.identifier, options: nil) { item, _ in
                if let url = item as? URL {
                    cont.resume(returning: VideoURL.first(in: url.absoluteString)); return
                }
                if let data = item as? Data, let url = URL(dataRepresentation: data, relativeTo: nil) {
                    cont.resume(returning: VideoURL.first(in: url.absoluteString)); return
                }
                if let str = item as? String {
                    cont.resume(returning: VideoURL.first(in: str)); return
                }
                cont.resume(returning: nil)
            }
        }
    }

    private func loadText(_ provider: NSItemProvider) async -> String? {
        await withCheckedContinuation { cont in
            provider.loadItem(forTypeIdentifier: UTType.plainText.identifier, options: nil) { item, _ in
                // Some apps hand plain text over as UTF-8 data, not a String.
                if let data = item as? Data {
                    cont.resume(returning: String(data: data, encoding: .utf8)); return
                }
                cont.resume(returning: item as? String)
            }
        }
    }
}
