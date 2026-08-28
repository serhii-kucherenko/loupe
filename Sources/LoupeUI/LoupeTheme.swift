import SwiftUI
import LoupeCore

/// `DESIGN.md`, as code.
///
/// This is the only file in Loupe allowed to hold a colour value, a font choice, a
/// spacing step or a duration. Everything visible reads them by name. A new token
/// goes in `DESIGN.md` in the same change, or it does not exist.
///
/// The overlay sits on top of someone else's product, so it must read as a tool and
/// never as part of the app underneath.
public enum LoupeTheme {}

// MARK: - Colour

public extension LoupeTheme {

    /// A colour with its raw components kept, not just a `Color`.
    ///
    /// Contrast is a promise `DESIGN.md` makes out loud, and a promise you cannot
    /// measure is a promise you will break. Keeping the numbers lets a test check it.
    struct RGBA: Sendable, Equatable {
        public let red: Double, green: Double, blue: Double, alpha: Double

        public init(red: Double, green: Double, blue: Double, alpha: Double = 1) {
            self.red = red; self.green = green; self.blue = blue; self.alpha = alpha
        }

        public init(hex: UInt32, alpha: Double = 1) {
            self.init(red: Double((hex >> 16) & 0xFF) / 255,
                      green: Double((hex >> 8) & 0xFF) / 255,
                      blue: Double(hex & 0xFF) / 255,
                      alpha: alpha)
        }

        /// Flatten a translucent colour onto what sits behind it. Every panel here is
        /// translucent, so the contrast that matters is the composited one.
        public func composited(over backdrop: RGBA) -> RGBA {
            func mix(_ top: Double, _ bottom: Double) -> Double {
                top * alpha + bottom * (1 - alpha)
            }
            return RGBA(red: mix(red, backdrop.red),
                        green: mix(green, backdrop.green),
                        blue: mix(blue, backdrop.blue))
        }

        /// WCAG 2.1 relative luminance.
        public var relativeLuminance: Double {
            func channel(_ c: Double) -> Double {
                c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
            }
            return 0.2126 * channel(red) + 0.7152 * channel(green) + 0.0722 * channel(blue)
        }

        /// WCAG 2.1 contrast ratio, 1 to 21.
        public func contrastRatio(against other: RGBA) -> Double {
            let a = relativeLuminance, b = other.relativeLuminance
            return (max(a, b) + 0.05) / (min(a, b) + 0.05)
        }
    }

    /// One semantic colour. Light and dark are both first-class; neither is derived
    /// from the other, because a derived dark theme always looks derived.
    struct ColorToken: Sendable, Equatable {
        public let light: RGBA
        public let dark: RGBA

        public init(light: RGBA, dark: RGBA) {
            self.light = light; self.dark = dark
        }

        public func value(dark isDark: Bool) -> RGBA { isDark ? dark : light }

        /// The SwiftUI colour, resolved by the host's appearance at draw time.
        public var color: Color {
            #if canImport(UIKit)
            return Color(UIColor { traits in
                Self.platformColor(traits.userInterfaceStyle == .dark ? dark : light)
            })
            #elseif canImport(AppKit)
            let light = light, dark = dark
            return Color(NSColor(name: nil) { appearance in
                let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
                return Self.platformColor(isDark ? dark : light)
            })
            #else
            return Color(.sRGB, red: light.red, green: light.green,
                         blue: light.blue, opacity: light.alpha)
            #endif
        }

        #if canImport(UIKit)
        private static func platformColor(_ c: RGBA) -> UIColor {
            UIColor(red: c.red, green: c.green, blue: c.blue, alpha: c.alpha)
        }
        #elseif canImport(AppKit)
        private static func platformColor(_ c: RGBA) -> NSColor {
            NSColor(srgbRed: c.red, green: c.green, blue: c.blue, alpha: c.alpha)
        }
        #endif
    }

    /// Semantic names, never literal ones. The table in `DESIGN.md`, one for one.
    enum Colors {
        /// The picked element outline, tray index badges, and the focus ring.
        public static let highlight = ColorToken(light: RGBA(hex: 0xB5551D),
                                                 dark: RGBA(hex: 0xE29A5A))
        /// The wash inside a picked element.
        public static let highlightFill = ColorToken(light: RGBA(hex: 0xB5551D, alpha: 0.10),
                                                     dark: RGBA(hex: 0xE29A5A, alpha: 0.14))
        /// Tray and comment panels.
        public static let surface = ColorToken(light: RGBA(hex: 0xFFFFFF, alpha: 0.92),
                                               dark: RGBA(hex: 0x141F1A, alpha: 0.92))
        public static let ink = ColorToken(light: RGBA(hex: 0x17211C),
                                           dark: RGBA(hex: 0xE9EFEA))
        public static let inkSoft = ColorToken(light: RGBA(hex: 0x4C5A52),
                                               dark: RGBA(hex: 0xA2B2A8))
        public static let line = ColorToken(light: RGBA(hex: 0xD6DED8),
                                            dark: RGBA(hex: 0x293830))
        /// Send button, confirmation.
        public static let action = ColorToken(light: RGBA(hex: 0x2F7D5B),
                                              dark: RGBA(hex: 0x62C68E))
        /// Dimming behind the tray.
        public static let scrim = ColorToken(light: RGBA(hex: 0x17211C, alpha: 0.08),
                                             dark: RGBA(hex: 0x000000, alpha: 0.24))

        /// What a translucent surface actually sits on. Only used to check contrast.
        public static let backdrop = ColorToken(light: RGBA(hex: 0xFFFFFF),
                                                dark: RGBA(hex: 0x000000))
    }

    /// Tags reuse the palette rather than adding colours.
    static func color(for tag: AnnotationTag) -> ColorToken {
        switch tag {
        case .bug: return Colors.highlight
        case .polish, .idea: return Colors.inkSoft
        case .question: return Colors.action
        }
    }
}

// MARK: - Type

public extension LoupeTheme {
    /// System faces only. The overlay must not ship fonts or clash with the host app.
    enum Typography {
        /// Comment text.
        public static let body = Font.body
        /// Panel titles, buttons.
        public static let label = Font.subheadline.weight(.semibold)
        /// Endpoints, counts, element names.
        public static let caption = Font.caption.monospaced()
    }
}

// MARK: - Spacing and shape

public extension LoupeTheme {
    /// A 4pt base, and only these steps. A value not on this list is a bug.
    enum Space {
        public static let xs: CGFloat = 4
        public static let sm: CGFloat = 8
        public static let md: CGFloat = 12
        public static let lg: CGFloat = 16
        public static let xl: CGFloat = 24
        public static let xxl: CGFloat = 32

        public static let all: [CGFloat] = [xs, sm, md, lg, xl, xxl]
    }

    enum Radius {
        /// Tray, comment popover.
        public static let panel: CGFloat = 16
        /// Buttons, tag chips.
        public static let control: CGFloat = 10
        /// The outline around a picked element.
        public static let highlight: CGFloat = 6
    }

    enum Stroke {
        public static let highlight: CGFloat = 2
        public static let focus: CGFloat = 2
        public static let focusOffset: CGFloat = 2
        public static let hairline: CGFloat = 1
    }

    /// Floating panels. y8 blur24 at 18%.
    enum Elevation {
        public static let panelRadius: CGFloat = 24
        public static let panelOffsetY: CGFloat = 8
        public static let panelOpacity: Double = 0.18
    }

    /// Minimum hit targets. Below these, a control is decoration.
    enum Hit {
        public static let touch: CGFloat = 44
        public static let pointer: CGFloat = 28
    }
}

// MARK: - Motion

public extension LoupeTheme {
    /// Fast and quiet. The overlay must never make someone wait to leave a note.
    enum Motion {
        public static let hoverDuration: Double = 0.09
        public static let panelDuration: Double = 0.18
        public static let commitDuration: Double = 0.22

        /// The highlight following the pointer.
        public static let hover = Animation.easeOut(duration: hoverDuration)
        /// The tray and the popover appearing.
        public static let panel = Animation.spring(response: panelDuration, dampingFraction: 0.9)
        /// An annotation flying into the tray.
        public static let commit = Animation.easeInOut(duration: commitDuration)

        /// Reduce Motion replaces every transition with a cross-fade at `motion.hover`.
        /// Spatial movement is what makes people ill, so it is the part that goes.
        public static func resolved(_ animation: Animation, reduceMotion: Bool) -> Animation {
            reduceMotion ? .easeOut(duration: hoverDuration) : animation
        }
    }
}

// MARK: - Shorthands the overlay actually writes

public extension View {
    /// The panel treatment from `DESIGN.md`: translucent surface, hairline, elevation.
    func loupePanel() -> some View {
        self
            .background(
                RoundedRectangle(cornerRadius: LoupeTheme.Radius.panel, style: .continuous)
                    .fill(LoupeTheme.Colors.surface.color)
            )
            .overlay(
                RoundedRectangle(cornerRadius: LoupeTheme.Radius.panel, style: .continuous)
                    .strokeBorder(LoupeTheme.Colors.line.color,
                                  lineWidth: LoupeTheme.Stroke.hairline)
            )
            .shadow(color: .black.opacity(LoupeTheme.Elevation.panelOpacity),
                    radius: LoupeTheme.Elevation.panelRadius,
                    y: LoupeTheme.Elevation.panelOffsetY)
    }

    /// A visible focus ring that never animates in. See `DESIGN.md`.
    @ViewBuilder
    func loupeFocusRing(_ focused: Bool, cornerRadius: CGFloat = LoupeTheme.Radius.control) -> some View {
        overlay(
            RoundedRectangle(cornerRadius: cornerRadius + LoupeTheme.Stroke.focusOffset,
                             style: .continuous)
                .strokeBorder(LoupeTheme.Colors.highlight.color,
                              lineWidth: LoupeTheme.Stroke.focus)
                .padding(-LoupeTheme.Stroke.focusOffset)
                .opacity(focused ? 1 : 0)
        )
    }
}
