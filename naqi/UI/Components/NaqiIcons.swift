import SwiftUI

/// The hand-built icon set from Android `ui/NaqiIcons.kt`, ported path for path
/// in the same 24×24 viewport. SF Symbols would cover all four, but they sit
/// beside `NaqiMark` — the brand droplet, and genuinely custom — and a set that
/// mixes one hand-drawn path with three system glyphs stops reading as a
/// family. System chrome (back, close, overflow) still uses SF Symbols.
///
/// The standalone `droplet` glyph the Android set carried is gone: `NaqiMark`
/// is the only droplet any screen draws, and the two outlines were never the
/// same shape anyway.
struct NaqiIcon: Shape {
    let glyph: Glyph

    init(_ glyph: Glyph) { self.glyph = glyph }

    enum Glyph: Sendable { case video, musicOff, shield, check }

    /// None of these four is directional, and SwiftUI mirrors a `Shape` in a
    /// right-to-left layout by default — which turned the tick into a backwards
    /// tick and flipped the slash on the music-off mark in Arabic. Only the back
    /// arrow should mirror, and that one is a system symbol.
    var layoutDirectionBehavior: LayoutDirectionBehavior { .fixed }

    func path(in rect: CGRect) -> Path {
        var p = Path()
        switch glyph {
        case .video:
            p.move(to: CGPoint(x: 5, y: 6.5))
            p.addLine(to: CGPoint(x: 13, y: 6.5))
            p.addQuadCurve(to: CGPoint(x: 15, y: 8.5), control: CGPoint(x: 15, y: 6.5))
            p.addLine(to: CGPoint(x: 15, y: 15.5))
            p.addQuadCurve(to: CGPoint(x: 13, y: 17.5), control: CGPoint(x: 15, y: 17.5))
            p.addLine(to: CGPoint(x: 5, y: 17.5))
            p.addQuadCurve(to: CGPoint(x: 3, y: 15.5), control: CGPoint(x: 3, y: 17.5))
            p.addLine(to: CGPoint(x: 3, y: 8.5))
            p.addQuadCurve(to: CGPoint(x: 5, y: 6.5), control: CGPoint(x: 3, y: 6.5))
            p.closeSubpath()
            p.move(to: CGPoint(x: 15, y: 10))
            p.addLine(to: CGPoint(x: 20.5, y: 7))
            p.addQuadCurve(to: CGPoint(x: 21, y: 7.6), control: CGPoint(x: 21, y: 6.8))
            p.addLine(to: CGPoint(x: 21, y: 16.4))
            p.addQuadCurve(to: CGPoint(x: 20.5, y: 17), control: CGPoint(x: 21, y: 17.2))
            p.addLine(to: CGPoint(x: 15, y: 14))
            p.closeSubpath()

        case .musicOff:
            p.addRect(CGRect(x: 6.2, y: 10, width: 1.6, height: 4))
            p.addRect(CGRect(x: 10.2, y: 6.5, width: 1.6, height: 11))
            p.addRect(CGRect(x: 14.2, y: 9, width: 1.6, height: 6))
            p.move(to: CGPoint(x: 4, y: 18.6))
            p.addLine(to: CGPoint(x: 18.6, y: 4))
            p.addLine(to: CGPoint(x: 20, y: 5.4))
            p.addLine(to: CGPoint(x: 5.4, y: 20))
            p.closeSubpath()

        case .shield:
            p.move(to: CGPoint(x: 12, y: 2.5))
            p.addLine(to: CGPoint(x: 19.5, y: 5.5))
            p.addLine(to: CGPoint(x: 19.5, y: 11.2))
            p.addCurve(to: CGPoint(x: 12, y: 21),
                       control1: CGPoint(x: 19.5, y: 15.9), control2: CGPoint(x: 16.4, y: 19.5))
            p.addCurve(to: CGPoint(x: 4.5, y: 11.2),
                       control1: CGPoint(x: 7.6, y: 19.5), control2: CGPoint(x: 4.5, y: 15.9))
            p.addLine(to: CGPoint(x: 4.5, y: 5.5))
            p.closeSubpath()

        case .check:
            p.move(to: CGPoint(x: 9.8, y: 16.2))
            p.addLine(to: CGPoint(x: 5.6, y: 12))
            p.addLine(to: CGPoint(x: 4.2, y: 13.4))
            p.addLine(to: CGPoint(x: 9.8, y: 19))
            p.addLine(to: CGPoint(x: 20, y: 8.8))
            p.addLine(to: CGPoint(x: 18.6, y: 7.4))
            p.closeSubpath()
        }
        return p.applying(Self.fit(24, in: rect))
    }

    /// Uniform scale + centre, so a glyph never stretches in a non-square frame.
    static func fit(_ viewport: CGFloat, in rect: CGRect) -> CGAffineTransform {
        let s = min(rect.width, rect.height) / viewport
        return CGAffineTransform(translationX: rect.minX + (rect.width - viewport * s) / 2,
                                 y: rect.minY + (rect.height - viewport * s) / 2)
            .scaledBy(x: s, y: s)
    }
}

/// The brand mark: the bowl of ن holding a droplet. It rhymes with the نـ of the
/// wordmark, so mark and wordmark read as one lockup rather than a logo parked
/// above a title. Ported from `res/drawable/ic_naqi_mark.xml`, including that
/// file's group transform (scale 2.1 about (54, 55.1), then translate y −1.1).
struct NaqiMark: Shape {
    /// A mirrored brand mark is a different brand mark.
    var layoutDirectionBehavior: LayoutDirectionBehavior { .fixed }

    func path(in rect: CGRect) -> Path {
        var p = Path()

        // Bowl.
        p.move(to: CGPoint(x: 30.2, y: 36.2))
        p.addLine(to: CGPoint(x: 30.2, y: 52))
        p.addCurve(to: CGPoint(x: 54, y: 78.4),
                   control1: CGPoint(x: 30.2, y: 68.37), control2: CGPoint(x: 39.24, y: 78.4))
        p.addCurve(to: CGPoint(x: 77.8, y: 52),
                   control1: CGPoint(x: 68.76, y: 78.4), control2: CGPoint(x: 77.8, y: 68.37))
        p.addLine(to: CGPoint(x: 77.8, y: 36.2))
        p.addLine(to: CGPoint(x: 68.1, y: 40.2))
        p.addLine(to: CGPoint(x: 68.1, y: 50))
        p.addCurve(to: CGPoint(x: 54, y: 68.7),
                   control1: CGPoint(x: 68.1, y: 61.59), control2: CGPoint(x: 62.74, y: 68.7))
        p.addCurve(to: CGPoint(x: 39.9, y: 50),
                   control1: CGPoint(x: 45.26, y: 68.7), control2: CGPoint(x: 39.9, y: 61.59))
        p.addLine(to: CGPoint(x: 39.9, y: 40.2))
        p.closeSubpath()

        // Droplet held in the bowl.
        p.move(to: CGPoint(x: 54, y: 31.8))
        p.addCurve(to: CGPoint(x: 46.17, y: 45.57),
                   control1: CGPoint(x: 51.2, y: 35.72), control2: CGPoint(x: 46.17, y: 40.53))
        p.addCurve(to: CGPoint(x: 54, y: 53.4),
                   control1: CGPoint(x: 46.17, y: 49.93), control2: CGPoint(x: 49.64, y: 53.4))
        p.addCurve(to: CGPoint(x: 61.83, y: 45.57),
                   control1: CGPoint(x: 58.36, y: 53.4), control2: CGPoint(x: 61.83, y: 49.93))
        p.addCurve(to: CGPoint(x: 54, y: 31.8),
                   control1: CGPoint(x: 61.83, y: 40.53), control2: CGPoint(x: 56.8, y: 35.72))
        p.closeSubpath()

        let group = CGAffineTransform(translationX: 54, y: 55.1 - 1.1)
            .scaledBy(x: 2.1, y: 2.1)
            .translatedBy(x: -54, y: -55.1)
        return p.applying(group).applying(NaqiIcon.fit(108, in: rect))
    }
}
