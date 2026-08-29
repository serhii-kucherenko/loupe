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
/// A free-hand path will be the exception when it lands, because a drawn shape and a
/// dragged rectangle *are* the same gesture, and something has to say which one is
/// meant. That is the one tool that will need to be chosen rather than inferred.
public enum PickTool: String, CaseIterable, Sendable, Equatable {
    /// Tap an element. The overlay climbs to the one you meant.
    case point
    /// Drag a rectangle around whatever you actually mean, element or not.
    case box

    public var symbol: String {
        switch self {
        case .point: return "hand.tap"
        case .box: return "rectangle.dashed"
        }
    }

    public var title: String {
        switch self {
        case .point: return "Point"
        case .box: return "Box"
        }
    }

    /// What to do, in the fewest words that are still true. Shown while picking,
    /// because the whole complaint was that nothing on screen said this.
    public var hint: String {
        switch self {
        case .point: return "Tap what looks wrong"
        case .box: return "Drag around what looks wrong"
        }
    }

    public var accessibilityLabel: String {
        switch self {
        case .point: return "Point: tap an element"
        case .box: return "Box: drag a rectangle"
        }
    }
}
