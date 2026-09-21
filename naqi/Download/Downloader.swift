import CryptoKit
import Foundation
import os

/// Fetch one URL into quarantine and return the finished file.
///
/// **Quarantine, not the gallery.** Downloads land in
/// `Application Support/naqi-downloads/<urlKey>/` and are published only after
/// filtering — the PRD's core promise is that no unfiltered file is ever
/// visible to Photos. Excluded from backup the same way `WorkDir` is.
///
/// Extraction prefers the latest yt-dlp zipapp (macOS). iOS, and a macOS
/// install that cannot spawn Python, fall back to `NativeExtract`.
enum Downloader {

    private static let rootName = "naqi-downloads"
    private static let inFlight: Set<String> = ["part", "ytdl", "temp"]
    private static let staleMs: TimeInterval = 7 * 24 * 60 * 60

    static var root: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(rootName, isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        var dir = base
        var rv = URLResourceValues()
        rv.isExcludedFromBackup = true
        try? dir.setResourceValues(rv)
        return dir
    }

    static func quarantineDir(for url: String) -> URL {
        let d = root.appendingPathComponent(key(of: url), isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    static func isQuarantined(_ url: URL) -> Bool {
        url.isFileURL && url.path.hasPrefix(root.path + "/")
    }

    static func discard(_ url: URL) {
        guard isQuarantined(url) else { return }
        try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
        Log.download.info("quarantine cleared for \(url.lastPathComponent, privacy: .public)")
    }

    static func sweep() {
        let cutoff = Date.now.addingTimeInterval(-staleMs)
        for d in (try? FileManager.default.contentsOfDirectory(
            at: root, includingPropertiesForKeys: [.contentModificationDateKey])) ?? [] {
            let newest = ((try? FileManager.default.contentsOfDirectory(
                at: d, includingPropertiesForKeys: [.contentModificationDateKey])) ?? [d])
                .compactMap { try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate }
                .max() ?? cutoff
            guard newest < cutoff else { continue }
            try? FileManager.default.removeItem(at: d)
            Log.download.info("swept stale download \(d.lastPathComponent, privacy: .public)")
        }
    }

    /// Fetch `url` at `quality` into its quarantine directory.
    ///
    /// - Parameter onProgress: percent 0…100. Called on the cooperative thread.
    static func download(
        url: String,
        quality: DownloadQuality,
        onProgress: @escaping @Sendable (Int) -> Void = { _ in },
        isCancelled: @escaping @Sendable () -> Bool = { false },
    ) async throws -> URL {
        sweep()
        #if os(macOS)
        var info = try await extract(url)
        // Extraction already refreshes yt-dlp when it fails. This covers the
        // other stale-yt-dlp symptom: format URLs that then refuse to download.
        // One update, one re-extract, one more fetch.
        return try await YtDlp.retryingAfterUpdate {
            try await fetchAll(info, url: url, quality: quality, onProgress: onProgress, isCancelled: isCancelled)
        } update: {
            if await YtDlp.shared.launchBlocked { throw DownloadError.unsupported }
            _ = try await update()
            info = try await extract(url)
        }
        #else
        return try await fetchAll(extract(url), url: url, quality: quality, onProgress: onProgress, isCancelled: isCancelled)
        #endif
    }

    private static func fetchAll(
        _ info: ExtractedMedia,
        url: String,
        quality: DownloadQuality,
        onProgress: @escaping @Sendable (Int) -> Void,
        isCancelled: @escaping @Sendable () -> Bool,
    ) async throws -> URL {
        let chosen = quality.select(info.formats)
        guard !chosen.isEmpty else { throw DownloadError.unsupported }
        let dir = quarantineDir(for: url)
        let safeTitle = sanitize(info.title)

        if isCancelled() { throw DownloadError.cancelled }

        if chosen.count == 1 {
            let dest = dir.appendingPathComponent("\(safeTitle).\(chosen[0].ext)")
            try await fetch(chosen[0], to: dest, share: 0...1, onProgress: onProgress, isCancelled: isCancelled)
            onProgress(100)
            return dest
        }

        let video = chosen.first(where: \.hasVideo) ?? chosen[0]
        let audio = chosen.first(where: { $0.hasAudio && $0.id != video.id }) ?? chosen[1]
        let vURL = dir.appendingPathComponent("\(safeTitle).f\(video.id).\(video.ext)")
        let aURL = dir.appendingPathComponent("\(safeTitle).f\(audio.id).\(audio.ext)")
        try await fetch(video, to: vURL, share: 0...0.7, onProgress: onProgress, isCancelled: isCancelled)
        try await fetch(audio, to: aURL, share: 0.7...0.9, onProgress: onProgress, isCancelled: isCancelled)
        let merged = dir.appendingPathComponent("\(safeTitle).mp4")
        do {
            try await MediaMux.merge(video: vURL, audio: aURL, into: merged)
            try? FileManager.default.removeItem(at: vURL)
            try? FileManager.default.removeItem(at: aURL)
            onProgress(100)
            return merged
        } catch {
            Log.download.warning("mux failed, keeping video: \(error.localizedDescription, privacy: .public)")
            onProgress(100)
            return vURL
        }
    }

    static func extract(_ url: String) async throws -> ExtractedMedia {
        #if os(macOS)
        do { return try await YtDlp.shared.extract(url) }
        catch {
            Log.download.warning("yt-dlp extract failed, trying native: \(error.localizedDescription, privacy: .public)")
        }
        #endif
        return try await NativeExtract.extract(url)
    }

    static func version() async -> String? { await YtDlp.shared.version() }

    static func update() async throws -> String { try await YtDlp.shared.update() }

    static func updateIfDue() async { await YtDlp.shared.updateIfDue() }

    // MARK: Transfer

    private static func fetch(_ format: MediaFormat, to dest: URL,
                              share: ClosedRange<Double>,
                              onProgress: @escaping @Sendable (Int) -> Void,
                              isCancelled: @escaping @Sendable () -> Bool) async throws {
        if format.url.isFileURL {
            try? FileManager.default.removeItem(at: dest)
            try FileManager.default.copyItem(at: format.url, to: dest)
            onProgress(Int((share.upperBound * 100).rounded()))
            return
        }
        var req = URLRequest(url: format.url)
        req.setValue("Mozilla/5.0", forHTTPHeaderField: "User-Agent")
        for (k, v) in format.httpHeaders { req.setValue(v, forHTTPHeaderField: k) }

        let temp: URL
        let response: URLResponse
        do {
            (temp, response) = try await URLSession.shared.download(for: req)
        } catch is CancellationError {
            throw DownloadError.cancelled
        } catch let error as URLError where error.code == .cancelled {
            throw DownloadError.cancelled
        }
        if isCancelled() { throw DownloadError.cancelled }
        let http = response as? HTTPURLResponse
        if let code = http?.statusCode, !(200..<300).contains(code) {
            throw DownloadError.network("HTTP \(code)")
        }
        try? FileManager.default.removeItem(at: dest)
        try FileManager.default.moveItem(at: temp, to: dest)
        let written = (try? FileManager.default.attributesOfItem(atPath: dest.path)[.size] as? NSNumber)?.int64Value ?? 0
        onProgress(Int((share.upperBound * 100).rounded()))
        Log.download.info("fetched \(dest.lastPathComponent, privacy: .public) (\(written) bytes)")
    }

    /// Per-URL directory name, same idea as Android `JobStore.keyOf`. Stable
    /// across launches so a retry finds its own `.part` file.
    static func key(of url: String) -> String {
        SHA256.hash(data: Data(url.utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    static func sanitize(_ title: String) -> String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let banned = CharacterSet(charactersIn: "/\\:?%*|\"<>")
        let cleaned = trimmed.unicodeScalars.map { banned.contains($0) ? "_" : Character($0) }
        let s = String(cleaned)
        return s.isEmpty ? "download" : String(s.prefix(80))
    }
}
