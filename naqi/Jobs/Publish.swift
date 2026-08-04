import Foundation
import Photos
import os

/// Where a finished file goes.
enum Destination: String, Codable, Sendable, CaseIterable {
    case photos
    /// A folder the user picked; the URL is security-scoped.
    case userFolder
}

enum PublishError: Error, CustomStringConvertible {
    case photosDenied
    case photosFailed(String)
    case destinationUnwritable(String)

    var description: String {
        switch self {
        case .photosDenied: "permission to add to the photo library was refused"
        case .photosFailed(let s): "could not save to the photo library: \(s)"
        case .destinationUnwritable(let s): "could not write to the chosen folder: \(s)"
        }
    }
}

/// Moves the finished temp file to its destination.
///
/// The source is opened read-only and never written to — music removal copies
/// the video track sample-for-sample rather than editing in place. Deleting the
/// original is explicitly opt-in and two-step; nothing here does it.
enum Publish {

    static func save(_ temp: URL, named name: String, to destination: Destination,
                     folder: URL? = nil) async throws -> URL {
        switch destination {
        case .photos: return try await saveToPhotos(temp)
        case .userFolder:
            guard let folder else { throw PublishError.destinationUnwritable("no folder chosen") }
            return try saveToFolder(temp, named: name, folder: folder)
        }
    }

    private static func saveToPhotos(_ temp: URL) async throws -> URL {
        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard status == .authorized || status == .limited else { throw PublishError.photosDenied }
        do {
            try await PHPhotoLibrary.shared().performChanges {
                let req = PHAssetCreationRequest.forAsset()
                let opts = PHAssetResourceCreationOptions()
                // The temp file is ours and already final; letting Photos move it
                // avoids a second full-size copy on a device that just spent the
                // preflight budget.
                opts.shouldMoveFile = true
                req.addResource(with: .video, fileURL: temp, options: opts)
            }
        } catch {
            throw PublishError.photosFailed(error.localizedDescription)
        }
        Log.job.info("published to Photos")
        return temp
    }

    private static func saveToFolder(_ temp: URL, named name: String, folder: URL) throws -> URL {
        let scoped = folder.startAccessingSecurityScopedResource()
        defer { if scoped { folder.stopAccessingSecurityScopedResource() } }
        let dest = folder.appendingPathComponent(name)
        do {
            try? FileManager.default.removeItem(at: dest)
            try FileManager.default.moveItem(at: temp, to: dest)
        } catch {
            // Cross-volume move fails; fall back to copy.
            do { try FileManager.default.copyItem(at: temp, to: dest) }
            catch { throw PublishError.destinationUnwritable(error.localizedDescription) }
            try? FileManager.default.removeItem(at: temp)
        }
        Log.job.info("published to \(dest.lastPathComponent, privacy: .public)")
        return dest
    }
}
