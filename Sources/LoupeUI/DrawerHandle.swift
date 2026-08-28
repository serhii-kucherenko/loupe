import CoreGraphics

/// Where the drawer's pull sits on the trailing edge.
///
/// A fraction of the window's height rather than a point, so a rotation or a split
/// view moves it proportionally instead of leaving it off screen.
///
/// It moves along one edge and no further, on purpose. The shape Serhii asked for is
/// a drawer - "you make it a sliding panel, when it only leaves a handler I click on
/// and the side panel with appear" - and a pull that can be dragged into the
/// bottom-left while the panel still slides out of the right is not a drawer any
/// more, it is two objects pretending to be one.
///
/// It still has to get out of the way: "also that handler should be draggeble as
/// sometimes I might need to move it as it might be blocking element I need to
/// annotate". Sliding along the edge is enough for that, because whatever it was
/// covering is no longer under it.
public struct DrawerHandle: Sendable, Equatable {

    /// 0 is the top of the usable edge, 1 the bottom.
    public private(set) var fraction: Double

    /// How much of the edge the handle may not enter, at each end.
    ///
    /// Keeps it clear of a notch, a home indicator, and the corner radius of the
    /// screen itself, none of which it can see from here.
    public static let margin: Double = 0.12

    public init(fraction: Double = 0.5) {
        self.fraction = Self.clamp(fraction)
    }

    public static func clamp(_ fraction: Double) -> Double {
        min(max(fraction, margin), 1 - margin)
    }

    public mutating func move(to fraction: Double) {
        self.fraction = Self.clamp(fraction)
    }

    /// The centre of the handle, for a window of this height.
    public func centreY(in height: CGFloat) -> CGFloat {
        height * CGFloat(fraction)
    }

    /// The fraction a point corresponds to, so a drag can be turned back into one.
    public static func fraction(forY y: CGFloat, in height: CGFloat) -> Double {
        guard height > 0 else { return 0.5 }
        return clamp(Double(y / height))
    }
}
