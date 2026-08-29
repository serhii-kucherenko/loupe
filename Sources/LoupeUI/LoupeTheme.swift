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

// MARK: - What a host may replace

public extension LoupeTheme {

    /// The tokens a host app can supply so the overlay stops looking like a visitor.
    ///
    /// Loupe sits inside somebody else's product. Wearing its own palette on top of
    /// theirs is the difference between a tool that belongs there and a control that
    /// reads as broken - "the button is not following design system buttons that I
    /// already have in the app" was the report, and it is a fair one.
    ///
    /// **Deliberately not a styling API.** There are no per-control overrides and no
    /// slots for custom views. An overlay that can be restyled arbitrarily becomes a
    /// UI framework; the point is for this one to disappear into its host.
    ///
    /// Every field has a default, so a host names only what it has an opinion about:
    ///
    ///     Loupe.start(app: app, theme: LoupeTheme.Appearance(
    ///         accent: .init(light: .init(hex: 0x2563EB), dark: .init(hex: 0x7AA5F5)),
    ///         label: .headline))
    struct Appearance: Sendable, Equatable {

        /// The picked-element outline, badges and the focus ring. The host's accent.
        public var accent: ColorToken
        /// The wash inside a picked element. Follows `accent` unless it is given.
        public var accentFill: ColorToken
        /// Tray and comment panels.
        public var surface: ColorToken
        public var ink: ColorToken
        public var inkSoft: ColorToken
        public var line: ColorToken
        /// Send, and confirmation.
        public var action: ColorToken
        /// The ground behind a letterboxed thumbnail.
        public var cutaway: ColorToken
        /// Dimming while picking, and behind the tray.
        public var scrim: ColorToken
        /// Dimming behind a panel that has to be answered first.
        public var scrimModal: ColorToken
        /// What a translucent surface actually sits on. Only used to check contrast.
        public var backdrop: ColorToken

        public var body: Font
        public var label: Font
        public var caption: Font
        public var note: Font

        public var panelRadius: CGFloat
        public var controlRadius: CGFloat
        public var highlightRadius: CGFloat

        /// - Parameter accentFill: nil derives it from `accent`, which is almost
        ///   always what a host wants: it names one accent and the wash follows.
        ///   Passing a value is for a host whose own fill is not its accent faded.
        public init(accent: ColorToken = Appearance.stock.accent,
                    accentFill: ColorToken? = nil,
                    surface: ColorToken = Appearance.stock.surface,
                    ink: ColorToken = Appearance.stock.ink,
                    inkSoft: ColorToken = Appearance.stock.inkSoft,
                    line: ColorToken = Appearance.stock.line,
                    action: ColorToken = Appearance.stock.action,
                    cutaway: ColorToken = Appearance.stock.cutaway,
                    scrim: ColorToken = Appearance.stock.scrim,
                    scrimModal: ColorToken = Appearance.stock.scrimModal,
                    backdrop: ColorToken = Appearance.stock.backdrop,
                    body: Font = Appearance.stock.body,
                    label: Font = Appearance.stock.label,
                    caption: Font = Appearance.stock.caption,
                    note: Font = Appearance.stock.note,
                    panelRadius: CGFloat = Appearance.stock.panelRadius,
                    controlRadius: CGFloat = Appearance.stock.controlRadius,
                    highlightRadius: CGFloat = Appearance.stock.highlightRadius) {
            self.accent = accent
            self.accentFill = accentFill ?? Self.fill(from: accent)
            self.surface = surface
            self.ink = ink
            self.inkSoft = inkSoft
            self.line = line
            self.action = action
            self.cutaway = cutaway
            self.scrim = scrim
            self.scrimModal = scrimModal
            self.backdrop = backdrop
            self.body = body
            self.label = label
            self.caption = caption
            self.note = note
            self.panelRadius = panelRadius
            self.controlRadius = controlRadius
            self.highlightRadius = highlightRadius
        }

        /// The wash is the accent at the alphas `DESIGN.md` names, so a host that
        /// changes its accent does not also have to think about the fill.
        static func fill(from accent: ColorToken) -> ColorToken {
            ColorToken(light: accent.light.at(alpha: 0.10),
                       dark: accent.dark.at(alpha: 0.14))
        }
    }
}

public extension LoupeTheme.Appearance {

    /// Loupe's own look: exactly the table in `DESIGN.md`, and the default for every
    /// field above.
    ///
    /// Every argument is passed, so none of the defaults are evaluated - which is
    /// what keeps this from being a definition of itself.
    static let stock = LoupeTheme.Appearance(
        accent: Token(light: RGB(hex: 0xB5551D), dark: RGB(hex: 0xE29A5A)),
        accentFill: Token(light: RGB(hex: 0xB5551D, alpha: 0.10),
                          dark: RGB(hex: 0xE29A5A, alpha: 0.14)),
        surface: Token(light: RGB(hex: 0xFFFFFF, alpha: 0.92),
                       dark: RGB(hex: 0x141F1A, alpha: 0.92)),
        ink: Token(light: RGB(hex: 0x17211C), dark: RGB(hex: 0xE9EFEA)),
        inkSoft: Token(light: RGB(hex: 0x4C5A52), dark: RGB(hex: 0xA2B2A8)),
        line: Token(light: RGB(hex: 0xD6DED8), dark: RGB(hex: 0x293830)),
        action: Token(light: RGB(hex: 0x2F7D5B), dark: RGB(hex: 0x62C68E)),
        cutaway: Token(light: RGB(hex: 0xE8EDEA), dark: RGB(hex: 0x1E2823)),
        scrim: Token(light: RGB(hex: 0x17211C, alpha: 0.08),
                     dark: RGB(hex: 0x000000, alpha: 0.24)),
        scrimModal: Token(light: RGB(hex: 0x17211C, alpha: 0.32),
                          dark: RGB(hex: 0x000000, alpha: 0.48)),
        backdrop: Token(light: RGB(hex: 0xFFFFFF), dark: RGB(hex: 0x000000)),
        body: .body,
        label: .subheadline.weight(.semibold),
        // Monospaced because it is machine text and the eye should be able to tell
        // it from a sentence at a glance.
        caption: .caption.monospaced(),
        note: .caption,
        panelRadius: 16,
        controlRadius: 10,
        highlightRadius: 6)
}

/// Local shorthands, so the table above reads as a table.
private typealias Token = LoupeTheme.ColorToken
private typealias RGB = LoupeTheme.RGBA

public extension LoupeTheme {

    /// The theme in force. Set by `Loupe.start(app:transport:theme:)`.
    ///
    /// Main-actor because the overlay is drawn on the main thread and nothing else
    /// reads it - which makes this a plain variable rather than a lock.
    @MainActor static var appearance: Appearance = .stock
}

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

        /// The same colour at a different alpha. Used to derive the accent wash
        /// from whatever accent a host supplied.
        public func at(alpha: Double) -> RGBA {
            RGBA(red: red, green: green, blue: blue, alpha: alpha)
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
    ///
    /// These read from `LoupeTheme.appearance`, so a host that supplied its own
    /// tokens is honoured everywhere without a single call site changing. Nothing
    /// outside this file has ever named a colour, which is what made that possible.
    enum Colors {
        /// The picked element outline, tray index badges, and the focus ring.
        @MainActor public static var highlight: ColorToken { appearance.accent }
        /// The wash inside a picked element.
        @MainActor public static var highlightFill: ColorToken { appearance.accentFill }
        /// Tray and comment panels.
        @MainActor public static var surface: ColorToken { appearance.surface }
        @MainActor public static var ink: ColorToken { appearance.ink }
        @MainActor public static var inkSoft: ColorToken { appearance.inkSoft }
        @MainActor public static var line: ColorToken { appearance.line }
        /// Send button, confirmation.
        @MainActor public static var action: ColorToken { appearance.action }

        /// The ground behind a letterboxed thumbnail.
        ///
        /// A crop is whatever shape the thing on screen was - usually a row, six
        /// hundred points wide and forty tall. Fitted into a square that leaves
        /// space above and below, and that space has to be a defined colour rather
        /// than whatever the panel happens to be, or the picture has no edges.
        ///
        /// Not `backdrop`, which is flat white: on a light panel a white ground makes
        /// a pale screenshot look like it is bleeding into the row.
        @MainActor public static var cutaway: ColorToken { appearance.cutaway }

        /// Dimming behind the tray, and over the whole screen while picking.
        ///
        /// Deliberately barely there: while picking, the app underneath is the thing
        /// being read, and anything heavier would make it hard to see what you are
        /// pointing at.
        @MainActor public static var scrim: ColorToken { appearance.scrim }

        /// Behind a panel that has to be answered before anything else.
        ///
        /// A separate token because the two jobs pull in opposite directions and one
        /// value cannot do both. At 8% a settings panel left the tray behind it at
        /// full strength, so three primary buttons competed on one screen and none of
        /// them read as the thing to press.
        @MainActor public static var scrimModal: ColorToken { appearance.scrimModal }

        /// What a translucent surface actually sits on. Only used to check contrast.
        @MainActor public static var backdrop: ColorToken { appearance.backdrop }
    }

    /// Tags reuse the palette rather than adding colours.
    @MainActor static func color(for tag: AnnotationTag) -> ColorToken {
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
        @MainActor public static var body: Font { appearance.body }
        /// Panel titles, buttons.
        @MainActor public static var label: Font { appearance.label }
        /// Endpoints, counts, element names. Monospaced because it is machine text
        /// and the eye should be able to tell it from a sentence at a glance.
        @MainActor public static var caption: Font { appearance.caption }
        /// Small prose: field labels, hints, status lines. The same size as
        /// `caption` and deliberately not monospaced - a settings panel written in
        /// a code face reads as output rather than as something to fill in, and it
        /// wraps far worse in a narrow column.
        @MainActor public static var note: Font { appearance.note }
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
        @MainActor public static var panel: CGFloat { appearance.panelRadius }
        /// Buttons, tag chips.
        @MainActor public static var control: CGFloat { appearance.controlRadius }
        /// The outline around a picked element.
        @MainActor public static var highlight: CGFloat { appearance.highlightRadius }
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
    @MainActor
    func loupePanel() -> some View {
        self
            .background(
                // Blur, then scrim, then the surface. A 92% panel on its own lets
                // the host app's own text read straight through a comment. The blur
                // turns what shows through into depth rather than someone else's
                // words, which is the whole reason the surface can stay translucent.
                RoundedRectangle(cornerRadius: LoupeTheme.Radius.panel, style: .continuous)
                    .fill(LoupeTheme.Colors.surface.color)
                    .background(
                        RoundedRectangle(cornerRadius: LoupeTheme.Radius.panel,
                                         style: .continuous)
                            .fill(LoupeTheme.Colors.scrim.color)
                    )
                    .background(
                        RoundedRectangle(cornerRadius: LoupeTheme.Radius.panel,
                                         style: .continuous)
                            .fill(.ultraThinMaterial)
                    )
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
    ///
    /// - Parameter cornerRadius: nil takes the theme's control radius. It cannot be
    ///   the default *expression*, because the theme is main-actor state now and a
    ///   default argument is evaluated wherever the caller happens to be.
    @MainActor
    @ViewBuilder
    func loupeFocusRing(_ focused: Bool, cornerRadius: CGFloat? = nil) -> some View {
        let radius = cornerRadius ?? LoupeTheme.Radius.control
        overlay(
            RoundedRectangle(cornerRadius: radius + LoupeTheme.Stroke.focusOffset,
                             style: .continuous)
                .strokeBorder(LoupeTheme.Colors.highlight.color,
                              lineWidth: LoupeTheme.Stroke.focus)
                .padding(-LoupeTheme.Stroke.focusOffset)
                .opacity(focused ? 1 : 0)
        )
    }
}
