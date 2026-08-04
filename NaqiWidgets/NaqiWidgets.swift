import ActivityKit
import SwiftUI
import WidgetKit

/// Live Activity for a running filter job — Android's foreground-service
/// notification, in the shape iOS gives it.
///
/// The extension renders state the app posts through `LiveActivity`; it never
/// computes anything and never loads a model. Everything it draws comes from
/// `NaqiJobAttributes.ContentState`, which is one shared file so the two sides
/// cannot drift.
@main
struct NaqiWidgets: WidgetBundle {
    var body: some Widget { NaqiJobActivity() }
}

struct NaqiJobActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: NaqiJobAttributes.self) { context in
            LockScreenView(context: context)
                .activityBackgroundTint(Brand.deep)
                .activitySystemActionForegroundColor(Brand.jadeBright)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Image(systemName: "wand.and.sparkles")
                        .foregroundStyle(Brand.jadeBright)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Text(percent(context.state.fraction))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(Brand.jadeBright)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(context.attributes.title).font(.caption).lineLimit(1)
                        Bar(fraction: context.state.fraction)
                    }
                }
            } compactLeading: {
                Image(systemName: "wand.and.sparkles").foregroundStyle(Brand.jadeBright)
            } compactTrailing: {
                Text(percent(context.state.fraction))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(Brand.jadeBright)
            } minimal: {
                Image(systemName: "wand.and.sparkles").foregroundStyle(Brand.jadeBright)
            }
            .keylineTint(Brand.jadeBright)
        }
    }
}

private struct LockScreenView: View {
    let context: ActivityViewContext<NaqiJobAttributes>

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(context.attributes.title)
                    .font(.footnote.weight(.medium))
                    .lineLimit(1)
                Spacer()
                Text(percent(context.state.fraction))
                    .font(.footnote.monospacedDigit().weight(.semibold))
                    .foregroundStyle(Brand.jadeBright)
            }
            Bar(fraction: context.state.fraction)
            HStack {
                Text(stageLabel)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Spacer()
                // 0 means "too early to say" — print nothing rather than a
                // number that will be wrong.
                if context.state.etaSeconds > 0 {
                    Text(Duration.seconds(context.state.etaSeconds)
                        .formatted(.units(allowed: [.hours, .minutes], width: .narrow)) + " left")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(16)
        .foregroundStyle(Brand.paper)
    }

    /// Stage names arrive raw so the app and the widget do not both need the
    /// string catalog; the two-pass vocabulary is small enough to map here.
    private var stageLabel: String {
        switch context.state.stage {
        case "separating", "encodingAudio": String(localized: "Removing music")
        case "analyzing": String(localized: "Analyzing")
        case "rendering": String(localized: "Rendering")
        case "publishing": String(localized: "Saving")
        default: String(localized: "Working")
        }
    }
}

private struct Bar: View {
    let fraction: Double

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Brand.paper.opacity(0.18))
                Capsule().fill(Brand.jadeBright)
                    .frame(width: max(0, min(1, fraction)) * geo.size.width)
            }
        }
        .frame(height: 6)
    }
}

private func percent(_ f: Double) -> String {
    "\(Int((max(0, min(1, f)) * 100).rounded()))%"
}

/// The three brand colours the activity needs. Duplicated from `Naqi.C` rather
/// than sharing the whole theme: pulling `Theme.swift` in would drag the app's
/// entire design system into an extension that draws one bar.
private enum Brand {
    static let deep = Color(red: 0x0C / 255, green: 0x15 / 255, blue: 0x12 / 255)
    static let jadeBright = Color(red: 0x55 / 255, green: 0xC3 / 255, blue: 0xA1 / 255)
    static let paper = Color(red: 0xF5 / 255, green: 0xF7 / 255, blue: 0xF3 / 255)
}
