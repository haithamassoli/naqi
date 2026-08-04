#if canImport(ActivityKit) && os(iOS)
import ActivityKit
import Foundation

/// The ongoing-progress surface: Android's foreground-service notification with
/// a determinate 0-100 bar and a Cancel action.
///
/// Compiled into both the app (which posts updates) and the widget extension
/// (which renders them). ActivityKit matches the two by type name *and* by the
/// `ContentState` encoding, so this cannot be two declarations that merely look
/// alike — it has to be one file in both targets.
struct NaqiJobAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        /// Raw stage name. The localized copy lives with the screens.
        var stage: String
        var fraction: Double
        /// 0 means "too early to say"; the surface hides the line rather than
        /// printing a number.
        var etaSeconds: Int
    }

    var title: String
}
#endif
