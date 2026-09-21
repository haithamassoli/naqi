import Foundation

/// In-app paste field and the About yt-dlp card. Hidden on every platform
/// until this date; share-to-download stays the link path on iOS meanwhile.
/// Both stay in the binary and come back on their own.
enum LinkPaste {
    /// 2026-10-12 00:00:00 UTC — three weeks after 2026-09-21.
    static let visibleFrom = Date(timeIntervalSince1970: 1_791_763_200)

    static func isVisible(at now: Date = .now) -> Bool {
        now >= visibleFrom
    }

    static var isOffered: Bool { isVisible() }
}
