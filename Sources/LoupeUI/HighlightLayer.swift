import SwiftUI
import LoupeCore

/// The outline over the element under the pointer, and the badge that numbers it.
///
/// `DESIGN.md` is explicit that the highlight is never the only signal, so the badge
/// is not decoration: it is the second channel, for anyone who cannot separate the
/// outline from the app's own colours.
struct HighlightLayer: View {
    let rect: CGRect
    /// nil while hovering, a number once the element is pinned.
    var badge: Int?
    var isPinned: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: LoupeTheme.Radius.highlight, style: .continuous)
                .fill(LoupeTheme.Colors.highlightFill.color)
                .overlay(
                    RoundedRectangle(cornerRadius: LoupeTheme.Radius.highlight, style: .continuous)
                        .strokeBorder(LoupeTheme.Colors.highlight.color,
                                      lineWidth: LoupeTheme.Stroke.highlight)
                )
                .frame(width: rect.width, height: rect.height)
                .position(x: rect.midX, y: rect.midY)

            if let badge {
                BadgeView(number: badge)
                    // Sat on the corner of the element, pulled half outside it so it
                    // never covers the thing being annotated.
                    .position(x: rect.minX, y: rect.minY)
            }
        }
        .allowsHitTesting(false)
        .animation(LoupeTheme.Motion.resolved(LoupeTheme.Motion.hover,
                                              reduceMotion: reduceMotion),
                   value: rect)
        .accessibilityElement()
        .accessibilityLabel(isPinned ? "Picked element" : "Element under the pointer")
    }
}

/// The numbered badge. Also used in the tray, so one annotation reads as one number
/// in both places.
struct BadgeView: View {
    let number: Int
    var diameter: CGFloat = LoupeTheme.Hit.pointer

    var body: some View {
        Text("\(number)")
            .font(LoupeTheme.Typography.caption)
            .foregroundStyle(LoupeTheme.Colors.surface.color)
            .frame(width: diameter, height: diameter)
            .background(Circle().fill(LoupeTheme.Colors.highlight.color))
            .accessibilityLabel("Annotation \(number)")
    }
}
