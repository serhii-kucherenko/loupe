import SwiftUI

/// Where the overlay must take a touch even while it is otherwise letting touches
/// through to the app underneath.
///
/// A `UIHostingController` is one `UIView`, however much SwiftUI is inside it. So
/// `hitTest` cannot tell Loupe's own pill or tray from the empty space around them,
/// and a window that passes through "wherever the overlay draws nothing" ends up
/// passing through the controls too - which is how the pill and every button in the
/// tray became untappable on iOS.
///
/// The fix is to stop guessing. Anything that has to be tappable while the overlay
/// is passing through reports its own frame, and the window passes a touch through
/// only when it lands outside all of them.
///
/// Only the modes that do **not** swallow input need this - `.off` and `.browsing`.
/// While picking or commenting the overlay takes everything anyway.
struct InteractiveRegionsKey: PreferenceKey {
    static var defaultValue: [CGRect] { [] }

    static func reduce(value: inout [CGRect], nextValue: () -> [CGRect]) {
        value.append(contentsOf: nextValue())
    }
}

extension View {
    /// Marks this view as one the overlay window must not pass touches through.
    ///
    /// Uses `.global`, which inside the overlay window is window coordinates - the
    /// same space `hitTest` is asked about, and the same space `ElementRef.bounds`
    /// is expressed in.
    func loupeInteractive() -> some View {
        background(
            GeometryReader { proxy in
                Color.clear.preference(
                    key: InteractiveRegionsKey.self,
                    value: [proxy.frame(in: .global)])
            }
        )
    }
}
