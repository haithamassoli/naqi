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
/// Extraction prefers the latest standalone yt-dlp executable on macOS. iOS,
/// and a sandboxed Mac that cannot launch it, fall back to `NativeExtract`.
enum Downloader {

    private static let rootName = "naqi-downloads"
    private static let inFlight: Set<String> = ["part", "ytdl", "temp"]
    private static let staleMs: TimeInterval = 7 * 24 * 60 * 60
    private static let recordName = "download.json"

    private struct Record: Codable {
        var quality: String
        var formatIDs: [String]
        var fileName: String
        var bytes: Int64
        var sha256: String
    }

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

    static func discard(remoteURL: String) {
        try? FileManager.default.removeItem(at: root.appendingPathComponent(key(of: remoteURL), isDirectory: true))
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
        let started = ContinuousClock.now
        sweep()
        if let cached = reusable(url: url, quality: quality) {
            onProgress(100)
            Log.download.info("reusing completed download \(cached.lastPathComponent, privacy: .public)")
            return cached
        }
        #if os(macOS)
        var info = try await extract(url)
        // Extraction already refreshes yt-dlp when it fails. This covers the
        // other stale-yt-dlp symptom: format URLs that then refuse to download.
        // One update, one re-extract, one more fetch.
        let output = try await YtDlp.retryingAfterUpdate {
            try await fetchAll(info, url: url, quality: quality, onProgress: onProgress, isCancelled: isCancelled)
        } update: {
            if await YtDlp.shared.launchBlocked { throw DownloadError.unsupported }
            _ = try await update()
            info = try await extract(url)
        }
        Log.download.info("download overall \(Int(msSince(started)))ms")
        return output
        #else
        let output = try await fetchAll(extract(url), url: url, quality: quality,
                                        onProgress: onProgress, isCancelled: isCancelled)
        Log.download.info("download overall \(Int(msSince(started)))ms")
        return output
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
            let meter = DownloadProgress(ids: chosen.map(\.id), ceiling: 100, onProgress: onProgress)
            try await fetch(chosen[0], to: dest, meter: meter, isCancelled: isCancelled)
            try writeRecord(output: dest, quality: quality, formats: chosen, dir: dir,
                            isCancelled: isCancelled)
            onProgress(100)
            return dest
        }

        let video = chosen.first(where: \.hasVideo) ?? chosen[0]
        let audio = chosen.first(where: { $0.hasAudio && $0.id != video.id }) ?? chosen[1]
        let vURL = dir.appendingPathComponent("\(safeTitle).f\(video.id).\(video.ext)")
        let aURL = dir.appendingPathComponent("\(safeTitle).f\(audio.id).\(audio.ext)")
        let meter = DownloadProgress(ids: chosen.map(\.id), ceiling: 90, onProgress: onProgress)
        async let fetchedVideo: Void = fetch(video, to: vURL, meter: meter, isCancelled: isCancelled)
        async let fetchedAudio: Void = fetch(audio, to: aURL, meter: meter, isCancelled: isCancelled)
        _ = try await (fetchedVideo, fetchedAudio)
        let merged = dir.appendingPathComponent("\(safeTitle).mp4")
        do {
            try await MediaMux.merge(video: vURL, audio: aURL, into: merged)
            try? FileManager.default.removeItem(at: vURL)
            try? FileManager.default.removeItem(at: aURL)
            try writeRecord(output: merged, quality: quality, formats: chosen, dir: dir,
                            isCancelled: isCancelled)
            onProgress(100)
            return merged
        } catch {
            try? FileManager.default.removeItem(at: merged)
            Log.download.error("mux failed: \(error.localizedDescription, privacy: .public)")
            throw DownloadError.generic("mux: \(error.localizedDescription)")
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

    /// Digest of the validated private artifact used to bind processing
    /// checkpoints to downloaded bytes rather than only to the page URL.
    static func sourceIdentity(for file: URL) -> String? {
        guard let record = readRecord(file.deletingLastPathComponent()),
              record.fileName == file.lastPathComponent else { return nil }
        return record.sha256
    }

    // MARK: Transfer

    private static func fetch(_ format: MediaFormat, to dest: URL,
                              meter: DownloadProgress,
                              isCancelled: @escaping @Sendable () -> Bool) async throws {
        if let expected = format.filesize,
           (try? dest.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) == expected {
            meter.complete(format.id, bytes: expected)
            return
        }
        if format.url.isFileURL {
            try? FileManager.default.removeItem(at: dest)
            try FileManager.default.copyItem(at: format.url, to: dest)
            let bytes = (try? dest.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0
            meter.complete(format.id, bytes: bytes)
            return
        }
        var req = URLRequest(url: format.url)
        req.setValue("Mozilla/5.0", forHTTPHeaderField: "User-Agent")
        for (k, v) in format.httpHeaders { req.setValue(v, forHTTPHeaderField: k) }

        let resumeURL = dest.appendingPathExtension("resume")
        do {
            let report: @Sendable (Int64, Int64) -> Void = { received, expected in
                meter.update(format.id, received: received,
                             expected: expected > 0 ? expected : format.filesize)
            }
            let hadResume = FileManager.default.fileExists(atPath: resumeURL.path)
            do {
                try await DownloadTransfer(destination: dest, resumeURL: resumeURL,
                                           isCancelled: isCancelled, progress: report).run(req)
            } catch {
                guard hadResume, isCancelled() == false, Task.isCancelled == false else { throw error }
                try? FileManager.default.removeItem(at: resumeURL)
                try await DownloadTransfer(destination: dest, resumeURL: resumeURL,
                                           isCancelled: isCancelled, progress: report).run(req)
            }
        } catch is CancellationError {
            throw DownloadError.cancelled
        } catch let error as URLError where error.code == .cancelled {
            throw DownloadError.cancelled
        }
        if isCancelled() { throw DownloadError.cancelled }
        let written = (try? FileManager.default.attributesOfItem(atPath: dest.path)[.size] as? NSNumber)?.int64Value ?? 0
        meter.complete(format.id, bytes: written)
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

    private static func reusable(url: String, quality: DownloadQuality) -> URL? {
        let dir = quarantineDir(for: url)
        guard let record = readRecord(dir) else { return nil }
        guard record.quality == quality.rawValue else {
            try? FileManager.default.removeItem(at: dir)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            return nil
        }
        let file = dir.appendingPathComponent(record.fileName)
        let bytes = (try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init)
        guard bytes == record.bytes, record.bytes > 0 else { return nil }
        return file
    }

    private static func readRecord(_ dir: URL) -> Record? {
        let url = dir.appendingPathComponent(recordName)
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(Record.self, from: data)
    }

    private static func writeRecord(output: URL, quality: DownloadQuality,
                                    formats: [MediaFormat], dir: URL,
                                    isCancelled: @escaping @Sendable () -> Bool) throws {
        let bytes = (try output.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0
        guard bytes > 0 else { throw DownloadError.noFile }
        let record = Record(quality: quality.rawValue, formatIDs: formats.map(\.id),
                            fileName: output.lastPathComponent, bytes: bytes,
                            sha256: try digest(output, isCancelled: isCancelled))
        try JSONEncoder().encode(record).write(to: dir.appendingPathComponent(recordName), options: .atomic)
    }

    private static func digest(_ url: URL,
                               isCancelled: @escaping @Sendable () -> Bool) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hash = SHA256()
        while let data = try handle.read(upToCount: 1024 * 1024), data.isEmpty == false {
            if isCancelled() || Task.isCancelled { throw DownloadError.cancelled }
            hash.update(data: data)
        }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

/// Aggregates two independent byte streams. Unknown lengths intentionally do
/// not manufacture a percentage; the stage advances when all streams finish.
private final class DownloadProgress: @unchecked Sendable {
    private struct Entry { var received: Int64 = 0; var expected: Int64?; var complete = false }
    private struct State {
        var entries: [String: Entry]
        var lastValue = -1
        var lastPost = ContinuousClock.now
    }
    private let ceiling: Int
    private let post: @Sendable (Int) -> Void
    private let state: OSAllocatedUnfairLock<State>

    init(ids: [String], ceiling: Int, onProgress: @escaping @Sendable (Int) -> Void) {
        self.ceiling = ceiling
        self.post = onProgress
        self.state = OSAllocatedUnfairLock(initialState: State(
            entries: Dictionary(uniqueKeysWithValues: ids.map { ($0, Entry()) })))
    }

    func update(_ id: String, received: Int64, expected: Int64?) {
        let value = state.withLock { state -> Int? in
            var entry = state.entries[id] ?? Entry()
            entry.received = max(entry.received, received)
            if let expected, expected > 0 { entry.expected = expected }
            state.entries[id] = entry
            guard state.entries.values.allSatisfy({ $0.expected != nil }) else { return nil }
            let total = state.entries.values.compactMap(\.expected).reduce(0, +)
            guard total > 0 else { return nil }
            let bytes = state.entries.values.reduce(Int64(0)) { $0 + min($1.received, $1.expected ?? $1.received) }
            let next = min(ceiling, Int((Double(bytes) / Double(total) * Double(ceiling)).rounded(.down)))
            let due = state.lastPost.duration(to: .now) >= .milliseconds(250)
            guard next > state.lastValue, due else { return nil }
            state.lastValue = next
            state.lastPost = .now
            return next
        }
        if let value { post(value) }
    }

    func complete(_ id: String, bytes: Int64) {
        let value = state.withLock { state -> Int? in
            var entry = state.entries[id] ?? Entry()
            entry.received = max(entry.received, bytes)
            entry.expected = entry.expected ?? bytes
            entry.complete = true
            state.entries[id] = entry
            guard state.entries.values.allSatisfy(\.complete), state.lastValue < ceiling else { return nil }
            state.lastValue = ceiling
            return ceiling
        }
        if let value { post(value) }
    }
}

private final class DownloadTransfer: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let destination: URL
    private let resumeURL: URL
    private let isCancelled: @Sendable () -> Bool
    private let progress: @Sendable (Int64, Int64) -> Void
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, any Error>?
    private var task: URLSessionDownloadTask?
    private var session: URLSession?
    private var moveError: (any Error)?
    private var cancellationRequested = false

    init(destination: URL, resumeURL: URL,
         isCancelled: @escaping @Sendable () -> Bool,
         progress: @escaping @Sendable (Int64, Int64) -> Void) {
        self.destination = destination
        self.resumeURL = resumeURL
        self.isCancelled = isCancelled
        self.progress = progress
    }

    func run(_ request: URLRequest) async throws {
        let monitor = Task { @concurrent in
            while Task.isCancelled == false {
                if self.isCancelled() {
                    self.cancelProducingResumeData()
                    return
                }
                do { try await Task.sleep(for: .milliseconds(200)) }
                catch { return }
            }
        }
        defer { monitor.cancel() }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { cont in
                lock.lock()
                continuation = cont
                let session = URLSession(configuration: .ephemeral, delegate: self, delegateQueue: nil)
                self.session = session
                if let data = try? Data(contentsOf: resumeURL), !data.isEmpty {
                    task = session.downloadTask(withResumeData: data)
                } else {
                    task = session.downloadTask(with: request)
                }
                let task = task
                lock.unlock()
                task?.resume()
            }
        } onCancel: {
            self.cancelProducingResumeData()
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64, totalBytesWritten: Int64,
                    totalBytesExpectedToWrite: Int64) {
        progress(totalBytesWritten, totalBytesExpectedToWrite)
        if isCancelled() { cancelProducingResumeData() }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didFinishDownloadingTo location: URL) {
        do {
            if let http = downloadTask.response as? HTTPURLResponse,
               !(200..<300).contains(http.statusCode) {
                throw DownloadError.network("HTTP \(http.statusCode)")
            }
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.moveItem(at: location, to: destination)
            try? FileManager.default.removeItem(at: resumeURL)
        } catch {
            moveError = error
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    didCompleteWithError error: (any Error)?) {
        lock.lock()
        let cont = continuation
        continuation = nil
        self.task = nil
        self.session = nil
        let moveError = moveError
        lock.unlock()
        session.finishTasksAndInvalidate()
        guard let cont else { return }
        if let moveError { cont.resume(throwing: moveError) }
        else if let error { cont.resume(throwing: error) }
        else { cont.resume() }
    }

    private func cancelProducingResumeData() {
        lock.lock()
        guard cancellationRequested == false else { lock.unlock(); return }
        guard let task else { lock.unlock(); return }
        cancellationRequested = true
        lock.unlock()
        task.cancel(byProducingResumeData: { data in
            guard let data, !data.isEmpty else { return }
            try? data.write(to: self.resumeURL, options: .atomic)
        })
    }
}
