import Foundation
import VideoToolbox

/// One stream yt-dlp (or the native extractor) can fetch. `url` is a direct
/// HTTP(S) media URL, not the page the user pasted.
struct MediaFormat: Sendable, Equatable {
    var id: String
    var url: URL
    var ext: String
    var height: Int?
    var vcodec: String?
    var acodec: String?
    var filesize: Int64?
    var tbr: Double?
    var httpHeaders: [String: String]
    var fps: Int? = nil
    /// InnerTube `lastModified`: with `filesize`, the identity a resumed
    /// `.part` must still match.
    var lastModified: String? = nil

    var hasVideo: Bool {
        guard let vcodec, !vcodec.isEmpty, vcodec != "none" else { return false }
        return true
    }
    var hasAudio: Bool {
        guard let acodec, !acodec.isEmpty, acodec != "none" else { return false }
        return true
    }
}

struct ExtractedMedia: Sendable {
    var title: String
    var webpageURL: String
    var formats: [MediaFormat]
    var durationSec: Double? = nil
    /// Kept for the deferred HLS path; nothing reads it yet.
    var hlsManifestURL: URL? = nil
    /// InnerTube client that answered (`VISIONOS`, …), nil off YouTube.
    var client: String? = nil
}

/// Live transfer numbers, summed over every stream of one download.
struct DownloadStats: Sendable, Equatable, Codable {
    var done: Int64
    var total: Int64?
    var bytesPerSec: Double
    var etaSec: Double?

    var fraction: Double? {
        guard let total, total > 0 else { return nil }
        return min(1, Double(done) / Double(total))
    }
}

/// What the job will do to the file, which decides the format policy.
enum Processing: Sendable, Equatable {
    case none, music, visual
}

/// Hardware decoders the format policy may rely on. A value, not a probe, so
/// tests can pass any device.
struct DeviceCodecs: Sendable, Equatable {
    var av1: Bool
    var hevc: Bool
}

enum DownloadError: Error, Sendable {
    case unsupported
    case network(String)
    case noFile
    case noSpace
    case cancelled
    case generic(String)
    /// Removed, private, members-only, age-gated: retrying cannot help.
    case unavailable(String)
    case geo(String)
    case rateLimited
    /// A format URL answered 403 even after one re-extraction.
    case forbidden
    /// Every client returned nothing usable: YouTube changed.
    case extractor(String)

    var localizedDescription: String {
        switch self {
        case .unsupported: "unsupported url"
        case .network(let s): "network: \(s)"
        case .noFile: "download reported success but produced no file"
        case .noSpace: "no space left"
        case .cancelled: "cancelled"
        case .generic(let s): s
        case .unavailable(let s): "unavailable: \(s)"
        case .geo(let s): "geo: \(s)"
        case .rateLimited: "rate limited"
        case .forbidden: "forbidden"
        case .extractor(let s): "extractor: \(s)"
        }
    }
}

extension DeviceCodecs {
    static let current = DeviceCodecs(av1: VTIsHardwareDecodeSupported(kCMVideoCodecType_AV1),
                                      hevc: VTIsHardwareDecodeSupported(kCMVideoCodecType_HEVC))
}

extension DownloadQuality {
    // CONTRACT STUB (Phase 4 replaces the body): filter- and hardware-aware policy.
    func select(_ formats: [MediaFormat], processing: Processing,
                hw: DeviceCodecs = .current) -> [MediaFormat] {
        select(formats)
    }

    /// Pick 1–2 formats matching this quality. Combined (audio+video) wins so
    /// we skip a mux; otherwise best video under the cap plus best audio.
    func select(_ formats: [MediaFormat]) -> [MediaFormat] {
        let usable = formats.filter { $0.url.scheme == "http" || $0.url.scheme == "https" || $0.url.isFileURL }
        if self == .audio {
            if let audio = Self.bestAudioOnly(usable) { return [audio] }
            if let combined = Self.bestCombined(usable, cap: nil) { return [combined] }
            return []
        }
        let cap = heightCap
        let video = Self.bestVideoOnly(usable, cap: cap)
        let audio = Self.bestAudioOnly(usable)
        let combined = Self.bestCombined(usable, cap: cap)
        // A combined stream at the best available resolution avoids a second
        // transfer and mux. Keep separate streams only when they buy pixels.
        if let combined,
           video == nil || (combined.height ?? 0) >= (video?.height ?? 0) { return [combined] }
        if let video, let audio { return [video, audio] }
        if let combined { return [combined] }
        if let video { return [video] }
        if let audio { return [audio] }
        return []
    }

    private static func bestVideoOnly(_ formats: [MediaFormat], cap: Int?) -> MediaFormat? {
        formats
            .filter { $0.hasVideo && !$0.hasAudio && (cap == nil || ($0.height ?? 0) <= cap!) }
            .max(by: Self.videoRank)
    }

    private static func bestAudioOnly(_ formats: [MediaFormat]) -> MediaFormat? {
        formats.filter { $0.hasAudio && !$0.hasVideo }.max(by: Self.audioRank)
    }

    private static func bestCombined(_ formats: [MediaFormat], cap: Int?) -> MediaFormat? {
        formats
            .filter { $0.hasVideo && $0.hasAudio && (cap == nil || ($0.height ?? 0) <= cap!) }
            .max(by: Self.videoRank)
    }

    /// Prefer mp4, then taller, then higher bitrate.
    private static func videoRank(_ a: MediaFormat, _ b: MediaFormat) -> Bool {
        let aMp4 = a.ext == "mp4" || a.ext == "m4v"
        let bMp4 = b.ext == "mp4" || b.ext == "m4v"
        if aMp4 != bMp4 { return !aMp4 && bMp4 }
        if (a.height ?? 0) != (b.height ?? 0) { return (a.height ?? 0) < (b.height ?? 0) }
        return (a.tbr ?? 0) < (b.tbr ?? 0)
    }

    /// Prefer m4a/mp4 (AAC) over webm/opus so the pipeline can probe it.
    private static func audioRank(_ a: MediaFormat, _ b: MediaFormat) -> Bool {
        let aM4 = a.ext == "m4a" || a.ext == "mp4"
        let bM4 = b.ext == "m4a" || b.ext == "mp4"
        if aM4 != bM4 { return !aM4 && bM4 }
        return (a.tbr ?? 0) < (b.tbr ?? 0)
    }
}
