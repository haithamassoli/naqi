import SwiftUI

/// The single most distinctive moving element in the app: M3 Expressive's
/// `LinearWavyProgressIndicator`. The filled portion is a travelling sine wave,
/// the remaining track a flat rule. SwiftUI has no equivalent and a plain
/// `ProgressView` loses the signature, so it is drawn by hand at 10 pt.
///
/// The wave travels on a `TimelineView` clock rather than a repeating
/// animation: a determinate bar that also animates its own phase would fight
/// the value animation, and the phase must keep moving while the value sits
/// still for minutes at a time.
struct WavyProgress: View {
    /// 0…1.
    let value: Double
    var animating = true

    /// `Canvas` draws in absolute coordinates, so a bar that grows from x = 0
    /// grows from the *left* in Arabic — filling towards where the job started
    /// instead of away from it.
    @Environment(\.layoutDirection) private var layoutDirection

    /// Peak-to-trough 5 pt inside a 10 pt box, leaving room for the 4 pt stroke.
    private let amplitude: CGFloat = 2.5
    private let wavelength: CGFloat = 22
    private let stroke: CGFloat = 4
    /// Points per second the crest travels. Slow enough to read as "working",
    /// not as a spinner.
    private let speed: CGFloat = 26

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: !animating)) { ctx in
            Canvas { gc, size in
                let clamped = min(1, max(0, value))
                let filled = size.width * clamped
                let mid = size.height / 2
                let phase = animating
                    ? CGFloat(ctx.date.timeIntervalSinceReferenceDate) * speed
                    : 0

                // Remaining track: a flat rule, with a gap after the crest so
                // the two halves never touch.
                let gap: CGFloat = filled > 0 && filled < size.width ? 6 : 0
                if filled + gap < size.width {
                    var track = Path()
                    track.move(to: CGPoint(x: filled + gap, y: mid))
                    track.addLine(to: CGPoint(x: size.width - stroke / 2, y: mid))
                    gc.stroke(track, with: .color(Naqi.C.surfaceContainerHighest),
                              style: StrokeStyle(lineWidth: stroke, lineCap: .round))
                }

                guard filled > 0 else { return }
                var wave = Path()
                var x: CGFloat = 0
                while x <= filled {
                    let y = mid + amplitude * sin((x + phase) * 2 * .pi / wavelength)
                    if x == 0 { wave.move(to: CGPoint(x: x, y: y)) }
                    else { wave.addLine(to: CGPoint(x: x, y: y)) }
                    x += 1
                }
                gc.stroke(wave, with: .color(Naqi.C.primary),
                          style: StrokeStyle(lineWidth: stroke, lineCap: .round))
            }
        }
        .frame(height: 10)
        .scaleEffect(x: layoutDirection == .rightToLeft ? -1 : 1, y: 1)
        .animation(Naqi.spring, value: value)
        .accessibilityElement()
        .accessibilityValue(Text(value, format: .percent.precision(.fractionLength(0))))
    }
}

#Preview {
    VStack(spacing: 24) {
        WavyProgress(value: 0.0)
        WavyProgress(value: 0.37)
        WavyProgress(value: 1.0)
    }
    .padding(40)
    .background(Naqi.C.background)
}
