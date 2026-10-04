import Foundation
import os
@preconcurrency import ffmpegkit

/// WebM is decoded into an app-owned H.264/AAC copy; the original is never written.
enum WebM {
    static let convertedName = "webm-converted.mp4"

    struct Metadata: Sendable {
        let duration: Double
        let hasVideo: Bool
        let hasAudio: Bool
        let videoBitrate: Int
    }

    static func metadata(_ url: URL) async throws -> Metadata {
        try await Task.detached(priority: .userInitiated) {
            guard let session = FFprobeKit.getMediaInformation(url.path),
                  ReturnCode.isSuccess(session.getReturnCode()),
                  let info = session.getMediaInformation() else {
                throw PreflightFailure.sourceUnreadable
            }
            let streams = info.getStreams() as? [StreamInformation] ?? []
            let video = streams.first { $0.getType() == "video" }
            let duration = Double(info.getDuration() ?? "") ?? 0
            guard duration.isFinite, duration >= 0,
                  video != nil || streams.contains(where: { $0.getType() == "audio" }) else {
                throw PreflightFailure.sourceUnreadable
            }
            let pixels = (video?.getWidth()?.intValue ?? 0) * (video?.getHeight()?.intValue ?? 0)
            return Metadata(duration: duration, hasVideo: video != nil,
                            hasAudio: streams.contains { $0.getType() == "audio" },
                            videoBitrate: video == nil ? 0 : EncodeSettings.bitrateCap(pixels: pixels))
        }.value
    }

    static func prepare(_ source: URL, in dir: URL,
                        onProgress: @escaping @Sendable (Double) -> Void = { _ in },
                        isCancelled: @escaping @Sendable () -> Bool = { false }) async throws -> URL {
        guard MediaTypes.isWebM(source) else { return source }
        if isCancelled() || Task.isCancelled { throw CancellationError() }
        let output = dir.appendingPathComponent(convertedName)
        if FileManager.default.fileExists(atPath: output.path),
           let cached = try? await MediaSource.probe(output),
           cached.video != nil || cached.audio != nil { return output }

        let info = try await metadata(source)
        // Conversion runs before normal preflight, so budget the working copy here.
        let bytes = info.duration > 0
            ? info.duration * Double(info.videoBitrate + 192_000) / 8
            : Double(Preflight.fileSize(source) ?? 0) * 4
        guard bytes < Double(Int64.max - Preflight.slackBytes) else {
            throw PreflightFailure.sourceUnreadable
        }
        let required = Int64(bytes.rounded(.up)) + Preflight.slackBytes
        let available = Preflight.availableBytes()
        if available < required {
            Preflight.lastShortfall.withLock {
                $0 = Job.Shortfall(requiredBytes: required, availableBytes: available)
            }
            throw PreflightFailure.lowSpace(requiredBytes: required, availableBytes: available)
        }
        let part = dir.appendingPathComponent("webm-converting.mp4")
        defer { try? FileManager.default.removeItem(at: part) }
        var arguments = ["-nostdin", "-v", "error", "-y", "-i", source.path,
                         "-map", "0:v:0?", "-map", "0:a:0?", "-sn", "-dn"]
        if info.hasVideo {
            arguments += ["-c:v", "h264_videotoolbox", "-allow_sw", "1",
                          "-pix_fmt", "yuv420p", "-b:v", String(info.videoBitrate),
                          "-fps_mode", "passthrough", "-video_track_timescale", "1000000"]
        }
        arguments += ["-c:a", "aac", "-b:a", "192k", "-movflags", "+faststart", part.path]
        onProgress(0)
        try await convert(arguments, duration: info.duration,
                          onProgress: onProgress, isCancelled: isCancelled)
        try Task.checkCancellation()
        if isCancelled() { throw CancellationError() }
        let converted = try await MediaSource.probe(part)
        guard (converted.video != nil) == info.hasVideo,
              (converted.audio != nil) == info.hasAudio else {
            throw PreflightFailure.sourceUnreadable
        }
        try? FileManager.default.removeItem(at: output)
        try FileManager.default.moveItem(at: part, to: output)
        onProgress(1)
        return output
    }

    private static func convert(_ arguments: [String], duration: Double,
                                onProgress: @escaping @Sendable (Double) -> Void,
                                isCancelled: @escaping @Sendable () -> Bool) async throws {
        // FFmpegKit predates Sendable; this session is executed on one queue.
        guard let created = FFmpegSession.create(
            arguments, withCompleteCallback: nil, withLogCallback: nil,
            withStatisticsCallback: { stats in
                guard let stats else { return }
                if duration > 0 {
                    onProgress(min(max(Double(stats.getTime()) / (duration * 1000), 0), 1))
                }
            }) else { throw PreflightFailure.sourceUnreadable }
        nonisolated(unsafe) let session = created
        let id = session.getId()
        let cancellation = Task {
            while !Task.isCancelled {
                if isCancelled() { FFmpegKit.cancel(id); return }
                try? await Task.sleep(for: .milliseconds(200))
            }
        }
        defer { cancellation.cancel() }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                DispatchQueue.global(qos: .userInitiated).async {
                    if isCancelled() {
                        continuation.resume(throwing: CancellationError())
                        return
                    }
                    FFmpegKitConfig.ffmpegExecute(session)
                    if isCancelled() || ReturnCode.isCancel(session.getReturnCode()) {
                        continuation.resume(throwing: CancellationError())
                    } else if ReturnCode.isSuccess(session.getReturnCode()) {
                        continuation.resume()
                    } else {
                        Log.media.error("WebM conversion failed: \(session.getOutput() ?? "", privacy: .public)")
                        continuation.resume(throwing: PreflightFailure.sourceUnreadable)
                    }
                }
            }
        } onCancel: {
            FFmpegKit.cancel(id)
        }
    }
}
