import Foundation
import LoupeCore

#if canImport(UIKit)
import UIKit
public typealias PlatformView = UIView
public typealias PlatformWindow = UIWindow
#elseif canImport(AppKit)
import AppKit
public typealias PlatformView = NSView
public typealias PlatformWindow = NSWindow
#endif

#if canImport(UIKit) || canImport(AppKit)

/// Turns a point you tapped into the element you meant, and a picture of it.
///
/// Hit-testing alone is not enough. It returns the deepest view under your finger,
/// which is usually a label or an icon inside the thing you were pointing at. If the
/// crop shows that inner fragment, every downstream step reasons about the wrong
/// element. So the picker climbs to the nearest *meaningful* ancestor before it
/// captures.
public enum ElementPicker {

    /// A view is meaningful when the app has named it, or when it is an interactive
    /// control. Those are the two signals that survive across UI frameworks.
    ///
    /// The climb also stops before swallowing the screen: an ancestor covering most
    /// of the window is a container, not the thing you pointed at.
    static let maxWindowAreaFraction = 0.8

    /// - Parameter point: top-left origin, in viewport points, on **every**
    ///   platform. AppKit's bottom-left origin is an AppKit detail and is dealt
    ///   with in here, not by every caller.
    @MainActor
    public static func pick(at point: CGPoint, in window: PlatformWindow) -> (view: PlatformView, ref: ElementRef)? {
        guard let hit = hitTest(point, in: window) else { return nil }
        let target = meaningfulAncestor(of: hit, in: window)
        return (target, reference(for: target, in: window))
    }

    /// Climbs from the hit view to the element a person would say they clicked.
    @MainActor
    static func meaningfulAncestor(of view: PlatformView, in window: PlatformWindow) -> PlatformView {
        let windowArea = area(of: windowBounds(window))
        var current = view

        while !isMeaningful(current), let parent = current.superview {
            // A container that covers most of the window is never what you meant.
            if windowArea > 0, area(of: parent.bounds) / windowArea > maxWindowAreaFraction {
                break
            }
            current = parent
        }
        return current
    }

    @MainActor
    static func isMeaningful(_ view: PlatformView) -> Bool {
        if let id = identifier(of: view), !id.isEmpty { return true }
        #if canImport(UIKit)
        if view is UIControl { return true }
        #elseif canImport(AppKit)
        // AppKit has no separate label class: a static label is an NSTextField,
        // which is an NSControl. Taking every NSControl as interactive therefore
        // stops the climb on the very label the walk exists to climb past, and
        // the crop shows the words instead of the thing they are inside.
        if let field = view as? NSTextField { return field.isEditable }
        if view is NSControl { return true }
        #endif
        return false
    }

    /// AppKit exposes the accessibility identifier as a method and keeps a separate
    /// `identifier` property; UIKit has one optional property. Normalise both.
    @MainActor
    static func identifier(of view: PlatformView) -> String? {
        #if canImport(UIKit)
        return view.accessibilityIdentifier
        #elseif canImport(AppKit)
        if let id = view.identifier?.rawValue, !id.isEmpty { return id }
        let a11y = view.accessibilityIdentifier()
        return a11y.isEmpty ? nil : a11y
        #endif
    }

    /// Renders the picked element on its own. Rendering the view directly is the
    /// crop: there is no rectangle maths to get wrong.
    ///
    /// This answers "what is this element". `contextPNG` answers "where is it, and
    /// what is around it", which is a different question - so both are kept rather
    /// than one being padded until it half-answers both.
    @MainActor
    public static func screenshotPNG(of view: PlatformView) -> Data? {
        #if canImport(UIKit)
        guard view.bounds.width > 0, view.bounds.height > 0 else { return nil }
        let renderer = UIGraphicsImageRenderer(bounds: view.bounds)
        let image = renderer.image { _ in
            view.drawHierarchy(in: view.bounds, afterScreenUpdates: true)
        }
        return image.pngData()
        #elseif canImport(AppKit)
        guard view.bounds.width > 0, view.bounds.height > 0,
              let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return nil }
        view.cacheDisplay(in: view.bounds, to: rep)
        return rep.representation(using: .png, properties: [:])
        #endif
    }

    /// The whole window, with the picked element outlined.
    ///
    /// The tight crop is the better picture of *the element*, but it strips every
    /// clue about where the element sits and what it sits next to, and an agent
    /// reasoning about a layout problem needs exactly that. The outline is what makes
    /// the shot usable: without it, a full window is just a screenshot again.
    @MainActor
    public static func contextPNG(of view: PlatformView, in window: PlatformWindow) -> Data? {
        #if canImport(UIKit)
        guard let root = window.rootViewController?.view ?? window.subviews.first,
              root.bounds.width > 0, root.bounds.height > 0 else { return nil }
        let frame = view.convert(view.bounds, to: root)

        let renderer = UIGraphicsImageRenderer(bounds: root.bounds)
        return renderer.image { context in
            root.drawHierarchy(in: root.bounds, afterScreenUpdates: true)
            outline(frame, in: context.cgContext)
        }.pngData()

        #elseif canImport(AppKit)
        guard let content = window.contentView,
              content.bounds.width > 0, content.bounds.height > 0,
              let rep = content.bitmapImageRepForCachingDisplay(in: content.bounds)
        else { return nil }

        content.cacheDisplay(in: content.bounds, to: rep)

        // AppKit hands back a bottom-left frame, and the bitmap is drawn the same
        // way up, so no flip is needed here - unlike `boundsInWindow`, which
        // normalises for the format.
        let frame = view.convert(view.bounds, to: nil)

        guard let context = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        outline(frame, in: context.cgContext)
        NSGraphicsContext.restoreGraphicsState()

        return rep.representation(using: .png, properties: [:])
        #endif
    }

    /// `stroke.highlight` in `loupe.highlight`, the same outline the overlay draws.
    private static func outline(_ frame: CGRect, in context: CGContext) {
        let colour = LoupeTheme.Colors.highlight.light
        context.setStrokeColor(red: colour.red, green: colour.green,
                               blue: colour.blue, alpha: 1)
        context.setLineWidth(LoupeTheme.Stroke.highlight)
        let path = CGPath(roundedRect: frame.insetBy(dx: -1, dy: -1),
                          cornerWidth: LoupeTheme.Radius.highlight,
                          cornerHeight: LoupeTheme.Radius.highlight,
                          transform: nil)
        context.addPath(path)
        context.strokePath()
    }

    // MARK: - Platform seams

    @MainActor
    private static func hitTest(_ point: CGPoint, in window: PlatformWindow) -> PlatformView? {
        #if canImport(UIKit)
        return window.hitTest(point, with: nil)
        #elseif canImport(AppKit)
        // NSView.hitTest takes a point in the receiver's superview coordinates,
        // which for the content view means window coordinates - and those are
        // bottom-left, while everything else in Loupe is top-left.
        guard let content = window.contentView else { return nil }
        return content.hitTest(CGPoint(x: point.x, y: content.bounds.height - point.y))
        #endif
    }

    @MainActor
    private static func windowBounds(_ window: PlatformWindow) -> CGRect {
        #if canImport(UIKit)
        return window.bounds
        #elseif canImport(AppKit)
        return window.contentView?.bounds ?? .zero
        #endif
    }

    @MainActor
    private static func reference(for view: PlatformView, in window: PlatformWindow) -> ElementRef {
        let frame = boundsInWindow(view, window)
        return ElementRef(
            accessibilityID: identifier(of: view),
            label: label(of: view),
            className: String(describing: type(of: view)),
            bounds: Rect(x: frame.origin.x, y: frame.origin.y,
                         width: frame.size.width, height: frame.size.height)
        )
    }

    /// Always top-left origin, on every platform.
    ///
    /// AppKit windows are bottom-left, so a raw `convert` here would put macOS
    /// bounds in a different coordinate space from iOS ones. The bundle format
    /// promises one space (`docs/bundle-format.md`), and the overlay draws in the
    /// top-left one, so the flip happens here rather than at every reader.
    @MainActor
    private static func boundsInWindow(_ view: PlatformView, _ window: PlatformWindow) -> CGRect {
        #if canImport(UIKit)
        return view.convert(view.bounds, to: window)
        #elseif canImport(AppKit)
        let inWindow = view.convert(view.bounds, to: nil)
        let height = window.contentView?.bounds.height ?? inWindow.maxY
        return CGRect(x: inWindow.origin.x,
                      y: height - inWindow.maxY,
                      width: inWindow.width,
                      height: inWindow.height)
        #endif
    }

    @MainActor
    private static func label(of view: PlatformView) -> String? {
        #if canImport(UIKit)
        if let label = view as? UILabel { return label.text }
        if let button = view as? UIButton { return button.title(for: .normal) }
        return view.accessibilityLabel
        #elseif canImport(AppKit)
        if let control = view as? NSControl { return control.stringValue }
        return view.accessibilityLabel()
        #endif
    }

    private static func area(of rect: CGRect) -> Double {
        Double(rect.width * rect.height)
    }
}

#endif
