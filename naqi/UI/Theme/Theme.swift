import SwiftUI

/// The Naqi design language, ported from Android `ui/theme/`.
///
/// Concept: filtered water / clarity. **Jade is the interaction colour** —
/// every button, switch, selected state and trust mark. Ink/paper is the
/// reading surface. (The Apple task list describes this as "ink = interaction /
/// jade = video-truth", which inverts the shipped roles; the shipped semantics
/// win, because the app icon and every Android screenshot are built on them.
/// See `docs/apple-port/spec-jobs-ui.md` §6.1.)
///
/// Dynamic/system accent tinting is deliberately **not** adopted: the brand
/// identity has to beat the wallpaper palette (Android `ui/theme/Theme.kt:9`).
enum Naqi {

    // MARK: Brand

    enum Brand {
        static let jade = Color(hex: 0x1F6E5A)
        static let jadeBright = Color(hex: 0x55C3A1)
        static let deep = Color(hex: 0x0C1512)
        static let ink = Color(hex: 0x10201C)
        static let paper = Color(hex: 0xF5F7F3)
    }

    // MARK: Semantic colours

    /// Each token resolves per colour scheme. Light values are the Android
    /// light scheme, dark values the `values-night` scheme.
    enum C {
        static let primary = dyn(0x1F6E5A, 0x55C3A1)
        static let onPrimary = dyn(0xFFFFFF, 0x00382A)
        static let primaryContainer = dyn(0xA8E9D3, 0x005440)
        static let onPrimaryContainer = dyn(0x00251A, 0xA8E9D3)

        static let secondary = dyn(0x4B635A, 0xB1CCBF)
        static let onSecondary = dyn(0xFFFFFF, 0x1D352C)
        static let secondaryContainer = dyn(0xCDE9DC, 0x344B42)
        static let onSecondaryContainer = dyn(0x072019, 0xCDE9DC)

        static let tertiary = dyn(0x7C5A34, 0xE7C08C)
        static let onTertiary = dyn(0xFFFFFF, 0x452B08)
        static let tertiaryContainer = dyn(0xF5DDBB, 0x5F421F)
        static let onTertiaryContainer = dyn(0x2A1800, 0xF5DDBB)

        static let error = dyn(0xBA1A1A, 0xFFB4AB)
        static let onError = dyn(0xFFFFFF, 0x690005)
        static let errorContainer = dyn(0xFFDAD6, 0x93000A)
        static let onErrorContainer = dyn(0x410002, 0xFFDAD6)

        static let background = dyn(0xF5F7F3, 0x0C1512)
        static let onBackground = dyn(0x10201C, 0xDEE8E2)
        static let surface = dyn(0xF5F7F3, 0x0C1512)
        static let onSurface = dyn(0x10201C, 0xDEE8E2)
        static let surfaceVariant = dyn(0xDBE5DF, 0x3F4A45)
        static let onSurfaceVariant = dyn(0x3F4A45, 0xBEC9C2)

        static let surfaceContainerLowest = dyn(0xFFFFFF, 0x070E0C)
        static let surfaceContainerLow = dyn(0xEFF4F0, 0x141D19)
        static let surfaceContainer = dyn(0xECF1ED, 0x182420)
        static let surfaceContainerHigh = dyn(0xE6ECE8, 0x222E2A)
        static let surfaceContainerHighest = dyn(0xE0E7E2, 0x2D3935)

        static let outline = dyn(0x6F7A74, 0x89948D)
        static let outlineVariant = dyn(0xBFC9C3, 0x3F4A45)
        static let inverseSurface = dyn(0x2B322F, 0xDEE8E2)
        static let inverseOnSurface = dyn(0xECF1ED, 0x2B322F)
        static let inversePrimary = dyn(0x55C3A1, 0x1F6E5A)
        static let scrim = Color.black

        private static func dyn(_ light: UInt32, _ dark: UInt32) -> Color {
            #if canImport(UIKit)
            Color(UIColor { $0.userInterfaceStyle == .dark ? UIColor(rgb: dark) : UIColor(rgb: light) })
            #else
            Color(nsColor: NSColor(name: nil) {
                $0.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? NSColor(rgb: dark) : NSColor(rgb: light)
            })
            #endif
        }
    }

    // MARK: Spacing — base unit 4

    enum S {
        static let s1: CGFloat = 4
        static let s2: CGFloat = 8
        static let s3: CGFloat = 12
        static let s4: CGFloat = 16
        static let s5: CGFloat = 24
        static let s6: CGFloat = 32
        static let s7: CGFloat = 48
        /// Screen-edge padding.
        static let gutter: CGFloat = 20
    }

    enum R {
        static let extraSmall: CGFloat = 8
        static let small: CGFloat = 12
        static let medium: CGFloat = 16
        static let card: CGFloat = 24
        static let large: CGFloat = 28
        static let button: CGFloat = 20
    }

    /// Depth is a `surfaceContainer` fill plus a 1 pt `outlineVariant` border —
    /// never a shadow. Two components use a heavier 1.5 pt border.
    enum Border {
        static let hairline: CGFloat = 1
        static let emphasis: CGFloat = 1.5
        /// Dividers are outlineVariant at 70 % opacity.
        static let dividerOpacity: Double = 0.7
    }

    /// One spring for every state transition in the app. Android uses
    /// `spring(stiffness: 400, dampingRatio: 0.5)`; SwiftUI's response/damping
    /// form of the same underdamped curve.
    static let spring = Animation.spring(response: 0.32, dampingFraction: 0.5)
}

// MARK: - Hex helpers

extension Color {
    init(hex: UInt32) {
        self.init(.sRGB,
                  red: Double((hex >> 16) & 0xFF) / 255,
                  green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255,
                  opacity: 1)
    }
}

#if canImport(UIKit)
import UIKit
extension UIColor {
    convenience init(rgb: UInt32) {
        self.init(red: CGFloat((rgb >> 16) & 0xFF) / 255,
                  green: CGFloat((rgb >> 8) & 0xFF) / 255,
                  blue: CGFloat(rgb & 0xFF) / 255, alpha: 1)
    }
}
#else
import AppKit
extension NSColor {
    convenience init(rgb: UInt32) {
        self.init(srgbRed: CGFloat((rgb >> 16) & 0xFF) / 255,
                  green: CGFloat((rgb >> 8) & 0xFF) / 255,
                  blue: CGFloat(rgb & 0xFF) / 255, alpha: 1)
    }
}
#endif

// MARK: - Shared component styling

extension View {
    /// The app's card treatment: container fill, 24 pt corners, hairline border.
    func naqiCard(emphasised: Bool = false) -> some View {
        self
            .background(Naqi.C.surfaceContainer, in: .rect(cornerRadius: Naqi.R.card))
            .overlay(
                RoundedRectangle(cornerRadius: Naqi.R.card)
                    .strokeBorder(Naqi.C.outlineVariant,
                                  lineWidth: emphasised ? Naqi.Border.emphasis : Naqi.Border.hairline)
            )
    }
}
