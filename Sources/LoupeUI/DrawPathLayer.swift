import SwiftUI
import LoupeCore

/// The shape being drawn, following the finger.
///
/// Dashed, exactly like `DragRegionLayer`, and for the same reason: a solid outline
/// is what a committed pick looks like, and the two must never be confused. One says
/// "this is the thing I found", the other says "this is what you are drawing".
///
/// Closed while it is still open. The gesture is a lasso, so the shape it will become
/// is the one worth showing - joining the ends as you go is what makes it obvious
/// that letting go now selects everything inside, rather than leaving somebody to
/// guess whether they have to return to the start.
struct DrawPathLayer: View {
    let points: [Point]

    var body: some View {
        shape
            .fill(LoupeTheme.Colors.highlightFill.color, style: FillStyle(eoFill: true))
            .overlay(
                shape.stroke(LoupeTheme.Colors.highlight.color,
                             style: StrokeStyle(lineWidth: LoupeTheme.Stroke.highlight,
                                                lineCap: .round,
                                                lineJoin: .round,
                                                dash: [6, 4]))
            )
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }

    private var shape: Path {
        var path = Path()
        guard let first = points.first else { return path }
        path.move(to: CGPoint(x: first.x, y: first.y))
        for point in points.dropFirst() {
            path.addLine(to: CGPoint(x: point.x, y: point.y))
        }
        path.closeSubpath()
        return path
    }
}
