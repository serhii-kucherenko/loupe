import SwiftUI
import LoupeCore

extension Rect {
    /// The format's rectangle from a platform one. `LoupeCore` deliberately knows
    /// nothing about CoreGraphics, so the bridge lives here.
    init(_ rect: CGRect) {
        self.init(x: rect.origin.x, y: rect.origin.y,
                  width: rect.size.width, height: rect.size.height)
    }
}

/// The rectangle being dragged out, drawn while the finger is still down.
///
/// Dashed, and that is the whole point of the treatment: a solid outline is what a
/// resolved element looks like, and these two must never be confused. One says "this
/// is the thing I found", the other says "this is the area you are drawing".
struct DragRegionLayer: View {
    let rect: CGRect

    var body: some View {
        RoundedRectangle(cornerRadius: LoupeTheme.Radius.highlight, style: .continuous)
            .strokeBorder(LoupeTheme.Colors.highlight.color,
                          style: StrokeStyle(lineWidth: LoupeTheme.Stroke.highlight,
                                             dash: [6, 4]))
            .background(
                RoundedRectangle(cornerRadius: LoupeTheme.Radius.highlight,
                                 style: .continuous)
                    .fill(LoupeTheme.Colors.highlightFill.color)
            )
            .frame(width: rect.width, height: rect.height)
            .position(x: rect.midX, y: rect.midY)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}
