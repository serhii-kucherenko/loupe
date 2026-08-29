import Foundation

/// Which gesture the person means to use.
///
/// Tap-to-pick and drag-a-box both already worked, and neither was findable: "also,
/// no way to switch selection modes". So this exists to *say what is there*, which is
/// a different job from deciding what a gesture does.
///
/// **It does not lock the gesture.** A tap still picks an element with `.box`
/// selected, and a drag still makes a region with `.point` selected. A control that
/// traps someone in the wrong tool is a worse bug than the one it fixes, and both
/// gestures are unambiguous - a tap and a drag cannot be mistaken for each other.
///
/// The tool follows what you actually did, so the control teaches by reflecting
/// rather than by instructing. Drag a box with `.point` lit and `.box` lights up.
///
/// **`draw` is the one exception, and it has to be.** A drawn shape and a dragged
/// rectangle are the same gesture - finger down, move, finger up - so nothing in the
/// touch itself says which was meant. Draw therefore locks: with it lit, a drag
/// makes a shape and never a rectangle. Tapping stays untouched in every tool,
/// because a tap cannot be confused with either, and it is the way out of a tool
/// somebody did not mean to be in.
public enum PickTool: String, CaseIterable, Sendable, Equatable {

    /// Whether this tool decides what a drag means, rather than only predicting it.
    ///
    /// Only `draw` does. Point and Box are both reflections - drag a box with Point
    /// lit and you get a box, and the control moves to match. Draw cannot work that
    /// way, so it is the one place somebody can be stuck in a tool they did not mean
    /// to choose. A tap is the escape, and the hint says so out loud.
    public var locksTheDrag: Bool { self == .draw }

    /// Tap an element. The overlay climbs to the one you meant.
    case point
    /// Drag a rectangle around whatever you actually mean, element or not.
    case box
    /// Draw a shape around several things, and around the things between them.
    ///
    /// The one thing a rectangle cannot say. A box around two controls at opposite
    /// corners of a card takes in everything between them and means nothing.
    case draw

    public var symbol: String {
        switch self {
        case .point: return "hand.tap"
        case .box: return "rectangle.dashed"
        case .draw: return "lasso"
        }
    }

    public var title: String {
        switch self {
        case .point: return "Point"
        case .box: return "Box"
        case .draw: return "Draw"
        }
    }

    /// What to do, in the fewest words that are still true. Shown while picking,
    /// because the whole complaint was that nothing on screen said this.
    public var hint: String {
        switch self {
        case .point: return "Tap what looks wrong"
        case .box: return "Drag around what looks wrong"
        case .draw: return "Draw around what looks wrong. Tap to leave it."
        }
    }

    public var accessibilityLabel: String {
        switch self {
        case .point: return "Point: tap an element"
        case .box: return "Box: drag a rectangle"
        case .draw: return "Draw: trace a shape around several things"
        }
    }
}
