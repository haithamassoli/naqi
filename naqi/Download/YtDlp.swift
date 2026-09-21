import Foundation
import os

/// Managed yt-dlp: the latest zipapp from GitHub, kept in Application Support
/// and refreshed weekly the same way Android's `Downloader.updateIfDue` does.
///
/// YouTube (and Instagram, TikTok, …) rotate extractors on the order of weeks.
/// A frozen copy inside the binary goes stale; fetching the current release is
/// the whole point of "yt-dlp latest".
actor YtDlp {
    static let shared = YtDlp()

    /// Standalone PyInstaller binary. `/usr/bin/python3` is an xcrun stub that
    /// cannot run inside the App Sandbox, so the zipapp is not enough on Mac.
    private static let latestMacBinary = URL(string: "https://github.com/yt-dlp/yt-dlp/releases/latest/download/yt-dlp_macos")!
    private static let latestAPI = URL(string: "https://api.github.com/repos/yt-dlp/yt-dlp/releases/latest")!
    private static let updateKey = "naqi.ytdlp.lastCheck"
    private static let versionKey = "naqi.ytdlp.version"
    private static let week: TimeInterval = 7 * 24 * 60 * 60

    private var ready = false

    var installDir: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("naqi-ytdlp", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        var dir = base
        var rv = URLResourceValues()
        rv.isExcludedFromBackup = true
        try? dir.setResourceValues(rv)
        return dir
    }

    var binary: URL { installDir.appendingPathComponent("yt-dlp") }

    func version() -> String? {
        UserDefaults.standard.string(forKey: Self.versionKey)
            ?? (try? String(contentsOf: installDir.appendingPathComponent("VERSION"), encoding: .utf8))
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
    }

    func updateIfDue() async {
        let last = UserDefaults.standard.object(forKey: Self.updateKey) as? Date ?? .distantPast
        #if os(macOS)
        let missing = !FileManager.default.fileExists(atPath: binary.path)
        #else
        let missing = version() == nil
        #endif
        guard Date.now.timeIntervalSince(last) > Self.week || missing else { return }
        _ = try? await update()
    }

    @discardableResult
    func update() async throws -> String {
        #if os(macOS)
        let (data, response) = try await URLSession.shared.data(from: Self.latestMacBinary)
        let http = response as? HTTPURLResponse
        guard let http, (200..<300).contains(http.statusCode), data.count > 1_000 else {
            throw DownloadError.network("yt-dlp download HTTP \(http?.statusCode ?? 0)")
        }
        let tmp = binary.appendingPathExtension("tmp")
        try data.write(to: tmp, options: .atomic)
        try? FileManager.default.removeItem(at: binary)
        try FileManager.default.moveItem(at: tmp, to: binary)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: binary.path)
        let ver = (try? await fetchLatestTag()) ?? "latest"
        Log.download.info("yt-dlp updated to \(ver, privacy: .public) (\(data.count) bytes)")
        #else
        // iOS cannot spawn yt-dlp; keep the tag so About can show it.
        let ver = try await fetchLatestTag()
        Log.download.info("yt-dlp latest is \(ver, privacy: .public)")
        #endif
        try? ver.write(to: installDir.appendingPathComponent("VERSION"), atomically: true, encoding: .utf8)
        UserDefaults.standard.set(ver, forKey: Self.versionKey)
        UserDefaults.standard.set(Date.now, forKey: Self.updateKey)
        ready = true
        return ver
    }

    func ensure() async throws {
        if ready, FileManager.default.fileExists(atPath: binary.path) { return }
        await updateIfDue()
        if FileManager.default.fileExists(atPath: binary.path) {
            ready = true
            return
        }
        _ = try await update()
    }

    /// `yt-dlp -J --no-playlist URL` → parsed formats. macOS only: iOS cannot
    /// spawn a process, so `NativeExtract` is the extractor there.
    func extract(_ url: String) async throws -> ExtractedMedia {
        try await ensure()
        do {
            return try await extractOnce(url)
        } catch {
            Log.download.warning("yt-dlp extract failed; updating and retrying once: \(error.localizedDescription, privacy: .public)")
            _ = try? await update()
            return try await extractOnce(url)
        }
    }

    private func extractOnce(_ url: String) async throws -> ExtractedMedia {
        let json = try await run(args: [
            "-J", "--no-playlist", "--no-warnings", "--no-check-certificates",
            "--skip-download", url,
        ])
        return try Self.parseDump(json)
    }

    func run(args: [String]) async throws -> String {
        try await ensure()
        #if os(macOS)
        return try await runProcess(args: args)
        #else
        throw DownloadError.unsupported
        #endif
    }

    #if os(macOS)
    private func runProcess(args: [String]) async throws -> String {
        try await withCheckedThrowingContinuation { cont in
            let proc = Process()
            proc.executableURL = binary
            proc.arguments = args
            proc.currentDirectoryURL = installDir
            var env = ProcessInfo.processInfo.environment
            env["PYTHONUNBUFFERED"] = "1"
            env["HOME"] = installDir.path
            proc.environment = env
            let out = Pipe()
            let err = Pipe()
            proc.standardOutput = out
            proc.standardError = err
            proc.terminationHandler = { p in
                let stdout = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                let stderr = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                if p.terminationStatus == 0 {
                    cont.resume(returning: stdout)
                } else {
                    let text = (stdout + "\n" + stderr)
                    Log.download.error("yt-dlp exit \(p.terminationStatus): \(text.prefix(800), privacy: .public)")
                    cont.resume(throwing: Self.classify(text))
                }
            }
            do { try proc.run() }
            catch { cont.resume(throwing: DownloadError.generic(error.localizedDescription)) }
        }
    }
    #endif

    nonisolated static func classify(_ text: String) -> DownloadError {
        let t = text.lowercased()
        if t.contains("unsupported url") || t.contains("unable to extract")
            || t.contains("no video formats") || t.contains("requested format is not available") {
            return .unsupported
        }
        if t.contains("timed out") || t.contains("connection") || t.contains("network")
            || t.contains("unable to download") || t.contains("http error") {
            return .network(text)
        }
        if t.contains("no space") || t.contains("enospc") { return .noSpace }
        return .generic(text)
    }

    private func fetchLatestTag() async throws -> String {
        var req = URLRequest(url: Self.latestAPI)
        req.setValue("Naqi/1.0 (yt-dlp-update)", forHTTPHeaderField: "User-Agent")
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        let (data, _) = try await URLSession.shared.data(for: req)
        struct Rel: Decodable { var tag_name: String }
        return try JSONDecoder().decode(Rel.self, from: data).tag_name
    }

    nonisolated static func parseDump(_ json: String) throws -> ExtractedMedia {
        guard let data = json.data(using: .utf8),
              let root = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { throw DownloadError.generic("yt-dlp produced no JSON") }
        let title = (root["title"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            .nonEmpty ?? "download"
        let webpage = (root["webpage_url"] as? String) ?? (root["original_url"] as? String) ?? ""
        let raw = (root["formats"] as? [[String: Any]]) ?? []
        var formats: [MediaFormat] = []
        formats.reserveCapacity(raw.count)
        for f in raw {
            guard let urlStr = f["url"] as? String, let url = URL(string: urlStr) else { continue }
            let proto = (f["protocol"] as? String) ?? url.scheme ?? ""
            // Skip HLS/DASH manifests — URLSession is a single-file downloader.
            if proto.contains("m3u8") || proto.contains("dash") || proto.contains("rtmp") { continue }
            let ext = (f["ext"] as? String) ?? url.pathExtension.nonEmpty ?? "mp4"
            let headers = (f["http_headers"] as? [String: String]) ?? [:]
            let height = f["height"] as? Int
            let vcodec = f["vcodec"] as? String
            let acodec = f["acodec"] as? String
            let size = (f["filesize"] as? Int64) ?? (f["filesize_approx"] as? Int64)
            let tbr = (f["tbr"] as? Double) ?? (f["vbr"] as? Double) ?? (f["abr"] as? Double)
            let id = (f["format_id"] as? String) ?? UUID().uuidString
            formats.append(MediaFormat(id: id, url: url, ext: ext, height: height,
                                       vcodec: vcodec, acodec: acodec, filesize: size,
                                       tbr: tbr, httpHeaders: headers))
        }
        if formats.isEmpty { throw DownloadError.unsupported }
        return ExtractedMedia(title: String(title.prefix(80)), webpageURL: webpage, formats: formats)
    }
}

private extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}
