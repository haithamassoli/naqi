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

/// Where a finished job actually left the file.
///
/// A URL alone cannot describe both destinations. A Photos publish also copies
/// into the photo library, but the playable file is the one `OutputLibrary`
/// kept — that is what Play, Share and Save act on. The identifier is the
/// Photos handle for jobs that still need to fall back to the library (a
/// queue file written before the local copy existed).
struct Published: Codable, Sendable, Equatable {
    /// The name the file was published under. Always known.
    let name: String
    /// A file still on disk. Present for a folder publish, and for a Photos
    /// publish that kept a local copy in `OutputLibrary`.
    let url: URL?
    /// `PHAsset` local identifier, for a Photos publish.
    let assetID: String?
}

/// Moves the finished temp file to its destination.
///
/// The source is opened read-only and never written to — music removal copies
/// the video track sample-for-sample rather than editing in place. Deleting the
/// original is explicitly opt-in and two-step; nothing here does it.
enum Publish {

    static func save(_ temp: URL, named name: String, to destination: Destination,
                     folder: URL? = nil) async throws -> Published {
        switch destination {
        case .photos: return try await saveToPhotos(temp, named: name)
        case .userFolder:
            guard let folder else { throw PublishError.destinationUnwritable("no folder chosen") }
            return try saveToFolder(temp, named: name, folder: folder)
        }
    }

    private static func saveToPhotos(_ temp: URL, named name: String) async throws -> Published {
        // `Preflight.photosAccess` asked the same question at the head of the
        // job so a refusal costs seconds instead of an hour. It is an early
        // exit, not a promise: the user can revoke access from Settings during
        // the hour in between, and this is the call that would actually fail.
        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard status == .authorized || status == .limited else { throw PublishError.photosDenied }
        // Captured inside the change block and read after it commits — the
        // placeholder's identifier is the asset's real one once it lands.
        var assetID: String?
        do {
            try await PHPhotoLibrary.shared().performChanges {
                let req = PHAssetCreationRequest.forAsset()
                let opts = PHAssetResourceCreationOptions()
                // Copy, do not move: Play/Share/Save need the file to stay in
                // our container. The extra full-size copy is charged in
                // preflight as `extraCopies` on the Photos destination.
                opts.shouldMoveFile = false
                opts.originalFilename = name
                req.addResource(with: .video, fileURL: temp, options: opts)
                assetID = req.placeholderForCreatedAsset?.localIdentifier
            }
        } catch {
            throw PublishError.photosFailed(error.localizedDescription)
        }
        let local = try OutputLibrary.adopt(temp, named: name)
        Log.job.info("published to Photos and \(local.lastPathComponent, privacy: .public)")
        return Published(name: name, url: local, assetID: assetID)
    }

    private static func saveToFolder(_ temp: URL, named name: String, folder: URL) throws -> Published {
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
        return Published(name: name, url: dest, assetID: nil)
    }
}
