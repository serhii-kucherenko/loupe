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
    /// ponytail: tight crop only. If the agent turns out to need surroundings, add a
    /// second full-screen shot with the bounds drawn on it rather than padding this one.
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

    // MARK: - Platform seams

    @MainActor
    private static func hitTest(_ point: CGPoint, in window: PlatformWindow) -> PlatformView? {
        #if canImport(UIKit)
        return window.hitTest(point, with: nil)
        #elseif canImport(AppKit)
        // NSView.hitTest takes a point in the receiver's superview coordinates,
        // which for the content view means window coordinates.
        return window.contentView?.hitTest(point)
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

    @MainActor
    private static func boundsInWindow(_ view: PlatformView, _ window: PlatformWindow) -> CGRect {
        #if canImport(UIKit)
        return view.convert(view.bounds, to: window)
        #elseif canImport(AppKit)
        return view.convert(view.bounds, to: nil)
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
