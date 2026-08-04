import Foundation

/// The one identifier the app, the share extension and the widget must agree
/// on, plus the two paths derived from it.
///
/// This file is compiled into all three targets (a synchronized group listed in
/// each), which is the point: a share extension that writes to a container the
/// app does not read is a bug with no compile error and no runtime error — the
/// video simply never arrives. Sharing the constant makes that unrepresentable.
enum AppGroup {
    static let identifier = "group.com.haithamassoli.naqi"

    static var container: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: identifier)
    }

    /// Where the extension drops shared videos and the app picks them up.
    static var inbox: URL? {
        container?.appendingPathComponent("Inbox", isDirectory: true)
    }

    /// Shared defaults. The app writes last-used options here so a share-in can
    /// inherit them without the extension having to ask.
    static var defaults: UserDefaults? { UserDefaults(suiteName: identifier) }
}

/// What the extension writes beside each copied video.
///
/// **Deliberately has no options field.** Share-in always inherits the app's
/// last-used settings (`AppGroup.defaults`), so the extension never needs to
/// know what `FilterOps` is — which keeps `FilterOps` and everything it drags
/// in out of a target with a ~120 MB ceiling.
struct ShareManifest: Codable, Sendable {
    var id: UUID
    var fileName: String
    var receivedAt: Date

    static func mediaURL(_ dir: URL, id: UUID, ext: String) -> URL {
        dir.appendingPathComponent("\(id.uuidString).\(ext)")
    }

    /// **The manifest is the completion marker.** The extension copies the
    /// movie first and writes `<id>.json` only once the copy has finished, so
    /// the app can never pick up a half-copied video — the same atomicity story
    /// as the checkpoint layer, and for the same reason: no second piece of
    /// state to keep in sync with the first.
    static func manifestURL(_ dir: URL, id: UUID) -> URL {
        dir.appendingPathComponent("\(id.uuidString).json")
    }
}
