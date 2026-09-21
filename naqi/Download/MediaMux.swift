import AVFoundation
import Foundation

/// Join a video-only file and an audio-only file into one mp4. yt-dlp would
/// call ffmpeg for `bv*+ba`; AVFoundation is the Apple equivalent and keeps
/// ffmpeg out of the bundle.
enum MediaMux {
    static func merge(video: URL, audio: URL, into output: URL) async throws {
        let videoAsset = AVURLAsset(url: video)
        let audioAsset = AVURLAsset(url: audio)
        let vTracks = try await videoAsset.loadTracks(withMediaType: .video)
        let aTracks = try await audioAsset.loadTracks(withMediaType: .audio)
        guard let vTrack = vTracks.first, let aTrack = aTracks.first else {
            throw DownloadError.generic("mux: missing video or audio track")
        }
        let composition = AVMutableComposition()
        guard let vComp = composition.addMutableTrack(withMediaType: .video,
                                                      preferredTrackID: kCMPersistentTrackID_Invalid),
              let aComp = composition.addMutableTrack(withMediaType: .audio,
                                                      preferredTrackID: kCMPersistentTrackID_Invalid)
        else { throw DownloadError.generic("mux: composition") }

        let vRange = try await vTrack.load(.timeRange)
        let aRange = try await aTrack.load(.timeRange)
        try vComp.insertTimeRange(vRange, of: vTrack, at: .zero)
        try aComp.insertTimeRange(CMTimeRange(start: .zero, duration: vRange.duration),
                                  of: aTrack, at: .zero)
        _ = aRange

        try? FileManager.default.removeItem(at: output)
        guard let session = AVAssetExportSession(asset: composition,
                                                 presetName: AVAssetExportPresetPassthrough)
        else { throw DownloadError.generic("mux: no export session") }
        session.outputURL = output
        session.outputFileType = .mp4
        await session.export()
        guard session.status == .completed else {
            throw DownloadError.generic(session.error?.localizedDescription ?? "mux failed")
        }
    }
}
