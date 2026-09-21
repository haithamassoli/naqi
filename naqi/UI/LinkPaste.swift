import Foundation

/// In-app paste field. Hidden on iOS until this date so share-to-download is
/// the link path; the field stays in the binary and comes back on its own.
/// macOS has no share extension, so the field stays offered there.
enum LinkPaste {
    /// 2026-10-12 00:00:00 UTC — three weeks after 2026-09-21.
    static let visibleFrom = Date(timeIntervalSince1970: 1_791_763_200)

    static func isVisible(at now: Date = .now) -> Bool {
        now >= visibleFrom
    }

    static var isOffered: Bool {
        #if os(macOS)
        true
        #else
        isVisible()
        #endif
    }
}
