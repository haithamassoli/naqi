import Foundation

/// Extractor that does not spawn yt-dlp. Used on iOS (no `Process`) and as the
/// fallback when the zipapp is not yet installed. Covers:
///
/// - a URL that is already a media file
/// - YouTube / youtu.be via InnerTube (ANDROID client, which usually returns
///   unciphered progressive/DASH URLs)
/// - any page that advertises a file in `og:video`, JSON-LD, or `<video src>`
enum NativeExtract {

    private static let userAgent = "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1"

    static func extract(_ url: String) async throws -> ExtractedMedia {
        guard let page = URL(string: url), page.scheme == "http" || page.scheme == "https"
        else { throw DownloadError.unsupported }
        if let id = youtubeID(url) {
            return try await youtube(id: id, webpage: url)
        }
        return try await pageExtract(page)
    }

    // MARK: Direct / HTML

    private static func pageExtract(_ page: URL) async throws -> ExtractedMedia {
        let ext = page.pathExtension.lowercased()
        if let direct = directMedia(page, ext: ext, mime: nil, size: nil) { return direct }

        var req = URLRequest(url: page)
        req.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        req.setValue("text/html,application/xhtml+xml,application/json,video/*,audio/*;q=0.9,*/*;q=0.8",
                     forHTTPHeaderField: "Accept")
        let (data, response) = try await URLSession.shared.data(for: req)
        let mime = (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Type") ?? ""
        let length = (response as? HTTPURLResponse)
            .flatMap { $0.value(forHTTPHeaderField: "Content-Length") }
            .flatMap { Int64($0) }
        if let direct = directMedia(page, ext: ext, mime: mime, size: length) { return direct }
        let html = String(data: data, encoding: .utf8)
            ?? String(data: data, encoding: .isoLatin1)
            ?? ""
        let title = meta(html, property: "og:title")
            ?? tag(html, "title")
            ?? page.host
            ?? "download"
        var found: [MediaFormat] = []
        func add(_ raw: String, id: String, height: Int?) {
            let cleaned = raw.replacingOccurrences(of: "\\u0026", with: "&")
                .replacingOccurrences(of: "\\/", with: "/")
                .replacingOccurrences(of: "&amp;", with: "&")
            guard let u = URL(string: cleaned), u.scheme == "http" || u.scheme == "https" else { return }
            let ext = u.pathExtension.nonEmpty ?? "mp4"
            let audio = ["m4a", "mp3", "aac"].contains(ext)
            found.append(MediaFormat(id: id, url: u, ext: ext, height: audio ? nil : (height ?? 720),
                                     vcodec: audio ? "none" : "avc1",
                                     acodec: "mp4a.40.2", filesize: nil, tbr: nil, httpHeaders: [:]))
        }
        if let v = meta(html, property: "og:video") ?? meta(html, property: "og:video:url")
            ?? meta(html, property: "og:video:secure_url") {
            add(v, id: "og", height: Int(meta(html, property: "og:video:height") ?? ""))
        }
        if let v = meta(html, name: "twitter:player:stream") { add(v, id: "twitter", height: nil) }
        for m in jsonLDVideos(html) { add(m, id: "ld", height: nil) }
        for m in quotedURLs(html) where looksLikeMedia(m) { add(m, id: "quoted", height: nil) }
        if found.isEmpty { throw DownloadError.unsupported }
        return ExtractedMedia(title: String(title.prefix(80)), webpageURL: page.absoluteString, formats: found)
    }

    private static let mediaExts: Set<String> = ["mp4", "m4a", "mp3", "mov", "webm", "aac", "wav"]

    private static func directMedia(_ page: URL, ext: String, mime: String?, size: Int64?) -> ExtractedMedia? {
        let audioMime = mime?.hasPrefix("audio/") == true
        let videoMime = mime?.hasPrefix("video/") == true
        guard videoMime || audioMime || mediaExts.contains(ext) else { return nil }
        let audio = audioMime || ["m4a", "mp3", "aac", "wav"].contains(ext)
        return ExtractedMedia(
            title: page.deletingPathExtension().lastPathComponent,
            webpageURL: page.absoluteString,
            formats: [MediaFormat(id: "direct", url: page,
                                  ext: ext.nonEmpty ?? (audio ? "m4a" : "mp4"),
                                  height: audio ? nil : 720,
                                  vcodec: audio ? "none" : "avc1",
                                  acodec: "mp4a.40.2", filesize: size,
                                  tbr: nil, httpHeaders: [:])])
    }

    // MARK: YouTube InnerTube

    private static func youtube(id: String, webpage: String) async throws -> ExtractedMedia {
        let clients: [(name: String, version: String, ua: String)] = [
            ("ANDROID", "19.28.35", "com.google.android.youtube/19.28.35 (Linux; U; Android 14) gzip"),
            ("IOS", "19.29.1", "com.google.ios.youtube/19.29.1 (iPhone16,2; U; CPU iOS 18_0 like Mac OS X;)"),
        ]
        var last: Error = DownloadError.unsupported
        for c in clients {
            do { return try await innertube(id: id, webpage: webpage, client: c) }
            catch { last = error }
        }
        throw last
    }

    private static func innertube(id: String, webpage: String,
                                  client: (name: String, version: String, ua: String)) async throws -> ExtractedMedia {
        let endpoint = URL(string: "https://www.youtube.com/youtubei/v1/player?prettyPrint=false")!
        var req = URLRequest(url: endpoint)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(client.ua, forHTTPHeaderField: "User-Agent")
        req.setValue("https://www.youtube.com", forHTTPHeaderField: "Origin")
        let body: [String: Any] = [
            "videoId": id,
            "context": [
                "client": [
                    "clientName": client.name,
                    "clientVersion": client.version,
                    "hl": "en",
                    "gl": "US",
                    "androidSdkVersion": 34,
                ],
            ],
            "contentCheckOk": true,
            "racyCheckOk": true,
        ]
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, _) = try await URLSession.shared.data(for: req)
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw DownloadError.unsupported
        }
        let play = (root["playabilityStatus"] as? [String: Any])?["status"] as? String
        if play == "LOGIN_REQUIRED" || play == "UNPLAYABLE" || play == "ERROR" {
            throw DownloadError.unsupported
        }
        let title = ((root["videoDetails"] as? [String: Any])?["title"] as? String)
            ?? "youtube-\(id)"
        let streaming = root["streamingData"] as? [String: Any] ?? [:]
        var raw = (streaming["formats"] as? [[String: Any]]) ?? []
        raw += (streaming["adaptiveFormats"] as? [[String: Any]]) ?? []
        var formats: [MediaFormat] = []
        for f in raw {
            guard let urlStr = f["url"] as? String, let url = URL(string: urlStr) else { continue }
            let mime = (f["mimeType"] as? String) ?? ""
            let ext = mime.contains("mp4") ? (mime.contains("audio") ? "m4a" : "mp4")
                : mime.contains("webm") ? "webm" : "mp4"
            formats.append(MediaFormat(
                id: String(f["itag"] as? Int ?? formats.count),
                url: url,
                ext: ext,
                height: f["height"] as? Int,
                vcodec: mime.contains("audio/") ? "none" : (f["quality"] as? String ?? "avc1"),
                acodec: mime.contains("video/") && !mime.contains("audio") ? "none" : "mp4a.40.2",
                filesize: (f["contentLength"] as? String).flatMap { Int64($0) },
                tbr: f["bitrate"] as? Double,
                httpHeaders: ["User-Agent": client.ua, "Referer": "https://www.youtube.com"]))
        }
        if formats.isEmpty { throw DownloadError.unsupported }
        return ExtractedMedia(title: String(title.prefix(80)), webpageURL: webpage, formats: formats)
    }

    static func youtubeID(_ url: String) -> String? {
        let patterns = [
            #"(?:youtube\.com/watch\?(?:[^#]*&)?v=|youtube\.com/embed/|youtube\.com/shorts/|youtu\.be/)([A-Za-z0-9_-]{11})"#,
        ]
        for p in patterns {
            if let re = try? NSRegularExpression(pattern: p),
               let m = re.firstMatch(in: url, range: NSRange(url.startIndex..., in: url)),
               m.numberOfRanges > 1, let r = Range(m.range(at: 1), in: url) {
                return String(url[r])
            }
        }
        return nil
    }

    // MARK: HTML crumbs

    private static func meta(_ html: String, property: String? = nil, name: String? = nil) -> String? {
        let key = property.map { "property=\"\($0)\"" } ?? name.map { "name=\"\($0)\"" } ?? ""
        guard let re = try? NSRegularExpression(
            pattern: "<meta[^>]+" + NSRegularExpression.escapedPattern(for: key)
                + "[^>]+content=\"([^\"]+)\"|<meta[^>]+content=\"([^\"]+)\"[^>]+"
                + NSRegularExpression.escapedPattern(for: key),
            options: .caseInsensitive),
              let m = re.firstMatch(in: html, range: NSRange(html.startIndex..., in: html))
        else { return nil }
        for i in 1..<m.numberOfRanges {
            if let r = Range(m.range(at: i), in: html), !r.isEmpty { return String(html[r]) }
        }
        return nil
    }

    private static func tag(_ html: String, _ name: String) -> String? {
        guard let re = try? NSRegularExpression(pattern: "<\(name)[^>]*>([^<]+)", options: .caseInsensitive),
              let m = re.firstMatch(in: html, range: NSRange(html.startIndex..., in: html)),
              let r = Range(m.range(at: 1), in: html) else { return nil }
        return String(html[r])
    }

    private static func jsonLDVideos(_ html: String) -> [String] {
        guard let re = try? NSRegularExpression(
            pattern: "<script[^>]+type=\"application/ld\\+json\"[^>]*>(.*?)</script>",
            options: [.caseInsensitive, .dotMatchesLineSeparators]) else { return [] }
        let ns = NSRange(html.startIndex..., in: html)
        var urls: [String] = []
        re.enumerateMatches(in: html, range: ns) { m, _, _ in
            guard let m, let r = Range(m.range(at: 1), in: html),
                  let obj = try? JSONSerialization.jsonObject(with: Data(html[r].utf8)) else { return }
            func walk(_ any: Any) {
                if let d = any as? [String: Any] {
                    if let s = d["contentUrl"] as? String { urls.append(s) }
                    d.values.forEach(walk)
                } else if let a = any as? [Any] { a.forEach(walk) }
            }
            walk(obj)
        }
        return urls
    }

    private static func quotedURLs(_ html: String) -> [String] {
        guard let re = try? NSRegularExpression(
            pattern: #"https?://[^"'\\\s>]+\.(?:mp4|m4a|mp3|mov|webm)(?:\?[^"'\\\s>]*)?"#,
            options: .caseInsensitive) else { return [] }
        let ns = NSRange(html.startIndex..., in: html)
        var out: [String] = []
        re.enumerateMatches(in: html, range: ns) { m, _, _ in
            if let m, let r = Range(m.range, in: html) { out.append(String(html[r])) }
        }
        return out
    }

    private static func looksLikeMedia(_ s: String) -> Bool {
        let l = s.lowercased()
        return l.contains(".mp4") || l.contains(".m4a") || l.contains(".mp3") || l.contains(".webm") || l.contains(".mov")
    }
}

private extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}
