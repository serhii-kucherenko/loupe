import Foundation
import LoupeCore

/// The element the person has pinned but not yet described.
public struct PendingPick: Equatable, Sendable {
    public var ref: ElementRef
    public var screenshotPNG: Data?
    public var contextScreenshotPNG: Data?
    /// 1-based, and it is what the badge shows. `DESIGN.md` requires the highlight
    /// never to be the only signal, so the number is part of the pick, not decoration.
    public var index: Int
    public var screen: String?
    public var viewport: Rect?

    public init(ref: ElementRef, screenshotPNG: Data? = nil,
                contextScreenshotPNG: Data? = nil, index: Int,
                screen: String? = nil, viewport: Rect? = nil) {
        self.ref = ref; self.screenshotPNG = screenshotPNG
        self.contextScreenshotPNG = contextScreenshotPNG; self.index = index
        self.screen = screen; self.viewport = viewport
    }
}

/// What the overlay is doing, and therefore whether it swallows the host app's input.
///
/// The distinction that matters is `browsing`. You have to be able to navigate the app
/// to annotate a second screen, so once a comment is committed the overlay stops
/// intercepting clicks and just shows the tray. `AnnotationSession` already assumes a
/// tray outlives navigation; this is the mode that makes that true.
public enum OverlayMode: Equatable, Sendable {
    /// Not annotating. Nothing on screen, nothing intercepted.
    case off
    /// The highlight follows the pointer. Input is intercepted.
    case picking(hover: ElementRef?)
    /// An element is pinned and the popover is open. Input is intercepted.
    case commenting(PendingPick)
    /// The tray is visible and clicks pass through to the app underneath.
    case browsing

    /// Whether the overlay takes the host app's clicks in this mode.
    public var swallowsInput: Bool {
        switch self {
        case .off, .browsing: return false
        case .picking, .commenting: return true
        }
    }

    /// Whether anything is drawn at all.
    public var isVisible: Bool { self != .off }
}

/// Where a `Send` has got to. The tray's button reads this, which is how it gets
/// its loading, error and success states without inventing its own bookkeeping.
public enum SendState: Equatable, Sendable {
    case idle
    case sending
    /// Why it failed, and whether pressing the button again could possibly help.
    /// A "Try again" on a rejected credential is confidently wrong advice.
    case failed(String, canRetry: Bool)
    /// How many annotations went out. Shown briefly, then the overlay closes.
    case sent(Int)
}
