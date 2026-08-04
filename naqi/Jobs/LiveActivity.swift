import Foundation
import os
#if canImport(ActivityKit) && os(iOS)
import ActivityKit
#endif

/// Start / update / end, guarded so every call is a no-op when the platform or
/// the user's settings cannot support an activity.
///
/// The activity itself is rendered by the `NaqiWidgets` extension;
/// `NaqiJobAttributes` lives in `NaqiShared/` because ActivityKit matches the
/// two processes on that type's encoding, so it has to be one declaration.
@MainActor
enum LiveActivity {
    #if canImport(ActivityKit) && os(iOS)
    private static var current: Activity<NaqiJobAttributes>?
    #endif

    static func start(title: String) {
        #if canImport(ActivityKit) && os(iOS)
        guard current == nil, ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        do {
            current = try Activity.request(
                attributes: NaqiJobAttributes(title: title),
                content: ActivityContent(state: .init(stage: "", fraction: 0, etaSeconds: 0),
                                         staleDate: nil))
        } catch {
            Log.job.notice("live activity unavailable: \(error.localizedDescription, privacy: .public)")
        }
        #endif
    }

    static func update(_ progress: JobProgress, etaSeconds: Int = 0) async {
        #if canImport(ActivityKit) && os(iOS)
        guard let activity = current else { return }
        // `Activity` is not `Sendable` but its mutators are `@concurrent`, so
        // the hand-off off the main actor has to be spelled out. Safe here: the
        // handle is written only by `start`/`end`, both main-actor isolated.
        nonisolated(unsafe) let live = activity
        await live.update(ActivityContent(
            state: .init(stage: progress.stage?.rawValue ?? "",
                         fraction: progress.fraction,
                         etaSeconds: etaSeconds),
            // The bar only moves on a real change, which on a long analyze pass
            // can be minutes apart; without a stale date the system would grey
            // a perfectly live activity out.
            staleDate: Date().addingTimeInterval(15 * 60)))
        #endif
    }

    static func end() async {
        #if canImport(ActivityKit) && os(iOS)
        guard let activity = current else { return }
        current = nil
        nonisolated(unsafe) let live = activity
        await live.end(nil, dismissalPolicy: .immediate)
        #endif
    }
}
