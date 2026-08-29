import Foundation
import LoupeCore
import WebKit

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
    /// Above this share of the window, something nobody named is not an element
    /// anyone pointed at.
    ///
    /// Was 0.8, which is far too generous. A SwiftUI shelf on an iPad reported as
    /// one element at 1032x621 - every book on the screen, the search field and the
    /// filter chips - and that is only 45% of the window, so it sailed through.
    /// Past about a third, a crop stops answering "what is this element" and becomes
    /// a screenshot, which the context shot already provides.
    ///
    /// Deliberately a measurement rather than a list of framework class names.
    /// `PlatformGroupContainer` is the culprit today, but it is a private SwiftUI
    /// type that can be renamed in any OS release, and a rule keyed on it would go
    /// quiet rather than fail when that happens.
    static let maxWindowAreaFraction = 1.0 / 3.0

    /// - Parameter point: top-left origin, in viewport points, on **every**
    ///   platform. AppKit's bottom-left origin is an AppKit detail and is dealt
    ///   with in here, not by every caller.
    @MainActor
    public static func pick(at point: CGPoint, in window: PlatformWindow) -> (view: PlatformView, ref: ElementRef)? {
        guard let hit = hitTest(point, in: window) else { return nil }
        let target = meaningfulAncestor(of: hit, in: window)
        guard !isBackdrop(target, in: window) else { return nil }
        return (target, reference(for: target, in: window))
    }

    /// Whether the pick landed on nothing.
    ///
    /// The area guard in the climb only fires while climbing, so it misses the case
    /// that matters most: pointing at empty space, where hit-testing hands back the
    /// window-sized background view and there is nothing to climb from. Reporting
    /// that produced a note with a blank crop and the element name "UIView", which
    /// is worse than no note. Refused only when the view is *also* anonymous - a
    /// full-screen map or image the app has named is a real element, and someone
    /// pointing at it means it.
    @MainActor
    static func isBackdrop(_ view: PlatformView, in window: PlatformWindow) -> Bool {
        guard isTooLarge(view, area(of: windowBounds(window))) else { return false }
        return !isMeaningful(view)
    }

    @MainActor
    private static func isTooLarge(_ view: PlatformView, _ windowArea: CGFloat) -> Bool {
        windowArea > 0 && area(of: view.bounds) / windowArea > maxWindowAreaFraction
    }

    /// Climbs from the hit view to the element a person would say they clicked.
    @MainActor
    static func meaningfulAncestor(of view: PlatformView, in window: PlatformWindow) -> PlatformView {
        let windowArea = area(of: windowBounds(window))
        var current = view

        while !isMeaningful(current), let parent = current.superview {
            // A container that covers most of the window is never what you meant,
            // named or not. That is not in tension with `isBackdrop` letting a named
            // full-screen element through: there, the big thing is what the person
            // hit, and there was nothing more specific to offer. Here the walk
            // already has something more specific and would be giving it away.
            if isTooLarge(parent, windowArea) { break }
            current = parent
        }
        return current
    }

    @MainActor
    static func isMeaningful(_ view: PlatformView) -> Bool {
        if let id = identifier(of: view), !id.isEmpty { return true }
        #if canImport(UIKit)
        if view is UIControl { return true }

        // A cell *is* "one row of a list", which is exactly what a person means when
        // they point at a row. Without this, a SwiftUI `List` - which renders into
        // very few UIViews and names none of them - climbs all the way to the list
        // itself, and the crop is the whole table instead of the line you meant.
        // Framework-provided, so it needs no cooperation from the host app.
        if view is UITableViewCell || view is UICollectionViewCell { return true }
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
    public static func screenshotPNG(of view: PlatformView) async -> Data? {
        guard view.bounds.width > 0, view.bounds.height > 0 else { return nil }
        let web = await webContent(in: view)

        #if canImport(UIKit)
        let renderer = UIGraphicsImageRenderer(bounds: view.bounds)
        return renderer.image { context in
            view.drawHierarchy(in: view.bounds, afterScreenUpdates: true)
            draw(web, over: view, in: context.cgContext)
        }.pngData()

        #elseif canImport(AppKit)
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return nil }
        view.cacheDisplay(in: view.bounds, to: rep)
        guard let context = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        draw(web, over: view, in: context.cgContext)
        NSGraphicsContext.restoreGraphicsState()
        return rep.representation(using: .png, properties: [:])
        #endif
    }

    // MARK: - Content this process cannot draw

    /// One web view and the pixels WebKit says it is showing.
    struct WebShot {
        let view: WKWebView
        /// nil when WebKit could not or would not answer.
        let image: CGImage?
    }

    /// **`drawHierarchy` cannot see a `WKWebView`.**
    ///
    /// Web content is rendered in a separate process and handed to the compositor, so
    /// a hierarchy draw contains everything *this* process knows how to draw and
    /// nothing else. What lands in the picture is whatever was last composited into
    /// our own layers - which, on a screen somebody has just navigated to, is the
    /// screen they came from. Annotating inside a book produced a picture of the
    /// shelf, and nothing about the picture said so.
    ///
    /// A picture of the wrong screen is worse than no picture: it is confidently
    /// wrong, and whoever reads the ticket has no way to tell.
    ///
    /// `takeSnapshot` is the only API that asks WebKit for its current pixels, and it
    /// is asynchronous - which is why every capture path here is now `async`. That is
    /// the whole reason for the signature change.
    ///
    /// - Note: web views are the reported case and the common one, but they are not
    ///   the only out-of-process content. A `MapKit` view, an `AVPlayerLayer` and
    ///   anything backed by Metal all composite the same way and will all come back
    ///   stale. There is no general API for those; if one turns up in a host app, it
    ///   needs the same treatment as this and a way to ask it for its pixels.
    /// The screen somebody is actually looking at, inside a window.
    ///
    /// A view controller presented over another does not remove it - the one
    /// underneath stays in the window with all its views. So "every web view in this
    /// window" includes web views on screens nobody can see, and painting their
    /// pixels on top puts a hidden screen over the visible one. That is exactly what
    /// happened the first time this was fixed: drawing the window got the right
    /// screen, and the composite pass then painted the covered one back over it.
    ///
    /// Follows the presentation chain to the end, which is the same answer UIKit
    /// gives when it decides what to show.
    @MainActor
    static func topmostContent(in window: PlatformWindow) -> PlatformView {
        #if canImport(UIKit)
        var controller = window.rootViewController
        while let presented = controller?.presentedViewController {
            controller = presented
        }
        return controller?.view ?? window
        #elseif canImport(AppKit)
        return window.contentView ?? PlatformView()
        #endif
    }

    @MainActor
    static func webContent(in view: PlatformView) async -> [WebShot] {
        var found: [WKWebView] = []
        func walk(_ candidate: PlatformView) {
            if let web = candidate as? WKWebView { found.append(web) }
            for child in candidate.subviews { walk(child) }
        }
        walk(view)
        guard !found.isEmpty else { return [] }

        var shots: [WebShot] = []
        for web in found {
            shots.append(WebShot(view: web, image: await snapshot(web)))
        }
        return shots
    }

    @MainActor
    private static func snapshot(_ web: WKWebView) async -> CGImage? {
        guard web.bounds.width > 0, web.bounds.height > 0 else { return nil }
        let configuration = WKSnapshotConfiguration()
        configuration.rect = web.bounds
        configuration.afterScreenUpdates = true

        return await withCheckedContinuation { continuation in
            web.takeSnapshot(with: configuration) { image, _ in
                #if canImport(UIKit)
                continuation.resume(returning: image?.cgImage)
                #elseif canImport(AppKit)
                continuation.resume(returning:
                    image?.cgImage(forProposedRect: nil, context: nil, hints: nil))
                #endif
            }
        }
    }

    /// Which end of every colour token to use when drawing into a file.
    ///
    /// A crop is a picture of the app, so it should sit on the ground the app is
    /// using. A light fill in the middle of a dark screenshot looks like a printing
    /// error rather than a deliberate gap.
    @MainActor
    static func isDarkAppearance() -> Bool {
        #if canImport(UIKit)
        return UITraitCollection.current.userInterfaceStyle == .dark
        #elseif canImport(AppKit)
        return NSApp?.effectiveAppearance
            .bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        #else
        return false
        #endif
    }

    /// Paints each web view's real pixels over the hole the hierarchy draw left.
    ///
    /// **A web view WebKit would not answer for is filled with `loupe.cutaway`, not
    /// left as it was.** Left as it was means the stale frame underneath, which is
    /// the whole bug. A flat rectangle is visibly not content: the picture says "not
    /// captured here" instead of quietly showing the wrong screen, and the rest of
    /// the shot survives - which matters when the web view is a banner and the note
    /// is about something else entirely.
    @MainActor
    private static func draw(_ shots: [WebShot],
                             over view: PlatformView,
                             in context: CGContext) {
        guard !shots.isEmpty else { return }
        let ground = LoupeTheme.Colors.cutaway.value(dark: isDarkAppearance())

        for shot in shots {
            let frame = shot.view.convert(shot.view.bounds, to: view)
            guard frame.width > 0, frame.height > 0 else { continue }

            context.saveGState()
            #if canImport(UIKit)
            // UIKit's graphics context counts down from the top; CoreGraphics draws
            // an image up from the bottom, so without this flip the web content
            // arrives upside down inside an otherwise correct picture.
            context.translateBy(x: frame.minX, y: frame.maxY)
            context.scaleBy(x: 1, y: -1)
            let box = CGRect(x: 0, y: 0, width: frame.width, height: frame.height)
            #else
            let flipped = view.isFlipped
                ? CGRect(x: frame.minX, y: view.bounds.height - frame.maxY,
                         width: frame.width, height: frame.height)
                : frame
            let box = flipped
            #endif

            if let image = shot.image {
                context.draw(image, in: box)
            } else {
                context.setFillColor(red: ground.red, green: ground.green,
                                     blue: ground.blue, alpha: 1)
                context.fill(box)
            }
            context.restoreGState()
        }
    }

    // MARK: - When there is no element

    /// How wide a crop to take when the framework hands back no element.
    ///
    /// Big enough to carry the thing pointed at plus what sits beside it, small
    /// enough that it is still a crop rather than a screenshot.
    public static let regionSize: CGFloat = 180

    /// A pick for a point the UI framework cannot resolve to anything.
    ///
    /// This is not an edge case on iOS. SwiftUI only backs a few kinds of content
    /// with a real `UIView` - list cells, text fields, the controls it has to - and
    /// draws everything else, headings and stacks and backgrounds included, into one
    /// shared layer. Verified on an iPad: neither view nor layer hit-testing can tell
    /// a point over a heading from a point over blank space. Without this, most of a
    /// SwiftUI screen simply could not be annotated, which breaks the one promise the
    /// tool makes.
    ///
    /// So the fallback answers the question the tool is actually for: it takes a box
    /// around the point and captures that. The reference carries no class and no
    /// name, because there genuinely is none - and an agent reading a bundle can tell
    /// an unresolved region from a real element by exactly that.
    @MainActor
    public static func regionRef(at point: CGPoint, in window: PlatformWindow) -> ElementRef? {
        guard let box = regionBox(at: point, in: window) else { return nil }
        return regionRef(box)
    }

    private static func regionRef(_ box: CGRect) -> ElementRef {
        ElementRef(kind: .region,
                   bounds: Rect(x: box.origin.x, y: box.origin.y,
                                width: box.width, height: box.height))
    }

    /// The smallest drag worth treating as a region rather than a slipped tap.
    public static let minimumRegionSize: CGFloat = 12

    /// Everything a dragged rectangle produces.
    ///
    /// The gesture people actually asked for: point at nothing in particular and say
    /// "this bit". Two controls misaligned with each other, the padding around a
    /// group, the gap between two rows - none of those is a view, and the walk can
    /// only ever answer with whichever one happens to be underneath.
    ///
    /// - Parameter rect: top-left origin, in window points, like every other
    ///   rectangle the picker deals in. Clipped to the window.
    @MainActor
    public static func capture(rect: CGRect, in window: PlatformWindow) async
        -> (ref: ElementRef, screenshotPNG: Data?, contextScreenshotPNG: Data?)? {
        let bounds = windowBounds(window)
        guard bounds.width > 0, bounds.height > 0 else { return nil }

        let box = rect.standardized
            .intersection(CGRect(origin: .zero, size: bounds.size))
        guard box.width >= minimumRegionSize, box.height >= minimumRegionSize else { return nil }

        return (regionRef(box),
                await regionPNG(box, in: window),
                await contextPNG(ofRegion: box, in: window))
    }

    /// The box a region pick covers: centred on the point, clipped to the window.
    ///
    /// Separate from the capture so hovering can draw the highlight without taking a
    /// pair of window-sized snapshots on every pointer move.
    @MainActor
    static func regionBox(at point: CGPoint, in window: PlatformWindow) -> CGRect? {
        let bounds = windowBounds(window)
        guard bounds.width > 0, bounds.height > 0 else { return nil }

        let half = regionSize / 2
        let box = CGRect(x: point.x - half, y: point.y - half,
                         width: regionSize, height: regionSize)
            .intersection(CGRect(origin: .zero, size: bounds.size))
        guard box.width > 1, box.height > 1 else { return nil }
        return box
    }

    /// Everything one pick produces, whether or not the framework could name an
    /// element. Every capture path goes through here so the fallback cannot be
    /// wired into one platform and forgotten in another.
    @MainActor
    public static func capture(at point: CGPoint, in window: PlatformWindow) async
        -> (ref: ElementRef, screenshotPNG: Data?, contextScreenshotPNG: Data?)? {
        if let picked = pick(at: point, in: window) {
            return (picked.ref,
                    await screenshotPNG(of: picked.view),
                    await contextPNG(of: picked.view, in: window))
        }
        guard let box = regionBox(at: point, in: window),
              let ref = regionRef(at: point, in: window) else { return nil }
        return (ref,
                await regionPNG(box, in: window),
                await contextPNG(ofRegion: box, in: window))
    }

    /// What the highlight should follow, element or region.
    @MainActor
    public static func hoverRef(at point: CGPoint, in window: PlatformWindow) -> ElementRef? {
        pick(at: point, in: window)?.ref ?? regionRef(at: point, in: window)
    }

    /// The whole window, with the picked element outlined.
    ///
    /// The tight crop is the better picture of *the element*, but it strips every
    /// clue about where the element sits and what it sits next to, and an agent
    /// reasoning about a layout problem needs exactly that. The outline is what makes
    /// the shot usable: without it, a full window is just a screenshot again.
    @MainActor
    public static func contextPNG(of view: PlatformView, in window: PlatformWindow) async -> Data? {
        await contextPNG(ofRegion: boundsInWindow(view, window), in: window)
    }

    /// The same shot for a plain rectangle, which is what a region pick has instead
    /// of a view.
    ///
    /// - Parameter box: top-left origin, in window points, like everything else the
    ///   picker hands out. The flip back to AppKit's bottom-left happens here.
    /// **The window, not its root view controller's view.**
    ///
    /// A view controller presented modally is not a subview of the root's view - UIKit
    /// puts it in its own container beside it. So drawing the root drew whatever the
    /// *root* is showing, which on an app that presents a reader over a shelf is the
    /// shelf. Somebody annotated a page in a book and the picture in the ticket was
    /// their library, with the highlight over empty space below the last row.
    ///
    /// The hit test never had this problem: it asks `window.hitTest`, which sees
    /// presented content. So the walk and the render disagreed about which screen was
    /// on the screen, and only the render was wrong.
    ///
    /// A `UIWindow` is a `UIView`, so this needs no conversion either - the box is
    /// already in window coordinates, which is what every rectangle here is in.
    @MainActor
    public static func contextPNG(ofRegion box: CGRect, in window: PlatformWindow) async -> Data? {
        #if canImport(UIKit)
        guard window.bounds.width > 0, window.bounds.height > 0 else { return nil }
        let web = await webContent(in: topmostContent(in: window))

        let renderer = UIGraphicsImageRenderer(bounds: window.bounds)
        return renderer.image { context in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
            draw(web, over: window, in: context.cgContext)
            outline(box, in: context.cgContext)
        }.pngData()

        #elseif canImport(AppKit)
        guard let content = window.contentView,
              content.bounds.width > 0, content.bounds.height > 0,
              let rep = content.bitmapImageRepForCachingDisplay(in: content.bounds)
        else { return nil }

        content.cacheDisplay(in: content.bounds, to: rep)

        // The bitmap is drawn bottom-left like the rest of AppKit, so the top-left
        // box has to be flipped back before it is drawn on.
        let frame = CGRect(x: box.minX, y: content.bounds.height - box.maxY,
                           width: box.width, height: box.height)

        guard let context = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        outline(frame, in: context.cgContext)
        NSGraphicsContext.restoreGraphicsState()

        return rep.representation(using: .png, properties: [:])
        #endif
    }

    /// Just the box, cropped out of the window.
    /// The window again, for the same reason as `contextPNG(ofRegion:in:)`: a
    /// presented view controller is not inside the root's view, so a crop taken from
    /// the root is a crop of the screen underneath the one somebody is looking at.
    @MainActor
    static func regionPNG(_ box: CGRect, in window: PlatformWindow) async -> Data? {
        #if canImport(UIKit)
        guard window.bounds.width > 0, window.bounds.height > 0 else { return nil }
        let web = await webContent(in: topmostContent(in: window))

        let renderer = UIGraphicsImageRenderer(size: box.size)
        return renderer.image { context in
            // Draw the whole window shifted so the box lands at the origin. Cropping
            // the finished image would work too and cost a second full-size bitmap.
            let shifted = CGRect(x: -box.origin.x, y: -box.origin.y,
                                 width: window.bounds.width, height: window.bounds.height)
            window.drawHierarchy(in: shifted, afterScreenUpdates: true)

            context.cgContext.saveGState()
            context.cgContext.translateBy(x: -box.origin.x, y: -box.origin.y)
            draw(web, over: window, in: context.cgContext)
            context.cgContext.restoreGState()
        }.pngData()

        #elseif canImport(AppKit)
        guard let content = window.contentView, content.bounds.height > 0 else { return nil }
        let frame = CGRect(x: box.minX, y: content.bounds.height - box.maxY,
                           width: box.width, height: box.height)
        guard let rep = content.bitmapImageRepForCachingDisplay(in: frame) else { return nil }
        content.cacheDisplay(in: frame, to: rep)
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
        let frame = clamped(boundsInWindow(view, window), to: window)
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
    /// The part of the element that is actually on screen.
    ///
    /// A scrolling container reported `{-14, 50, 1046, 635}` in a 1032-wide window on
    /// an iPad: wider than the screen, starting off the left edge. Bounds like that
    /// draw the highlight and the context outline in the wrong place, and
    /// `docs/bundle-format.md` says bounds are in `viewport` coordinates, which a
    /// negative origin is not. Clipping is also the more useful answer: it is the
    /// part of the element the person could see when they pointed at it.
    ///
    /// An element entirely off screen keeps its raw frame rather than becoming
    /// nothing, because "where is it" is still worth reporting.
    @MainActor
    private static func clamped(_ frame: CGRect, to window: PlatformWindow) -> CGRect {
        let viewport = CGRect(origin: .zero, size: windowBounds(window).size)
        let visible = frame.intersection(viewport)
        return visible.isNull || visible.isEmpty ? frame : visible
    }

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

    /// What a person would call this element.
    ///
    /// The element's own text first, then its accessible name, and finally the text
    /// of whatever is inside it. That last fallback is what makes a container
    /// useful: a SwiftUI list row is a `ListCollectionViewCell` with no name of its
    /// own, and "ListCollectionViewCell" tells an agent nothing, while
    /// "Wool overshirt, ink £96.00" locates the row immediately.
    @MainActor
    private static func label(of view: PlatformView) -> String? {
        #if canImport(UIKit)
        if let label = view as? UILabel, let text = label.text, !text.isEmpty { return text }
        if let button = view as? UIButton, let title = button.title(for: .normal),
           !title.isEmpty { return title }
        if let name = view.accessibilityLabel, !name.isEmpty { return name }
        #elseif canImport(AppKit)
        if let control = view as? NSControl, !control.stringValue.isEmpty {
            return control.stringValue
        }
        if let name = view.accessibilityLabel(), !name.isEmpty { return name }
        #endif
        return descendantText(of: view)
    }

    /// Nothing to find on iOS under SwiftUI. SwiftUI draws a row's text straight
    /// into one layer and keeps its accessibility tree unbuilt until an assistive
    /// client is running, so a `List` row has no `UILabel` inside it, no accessible
    /// name, and no identifier at the UIKit level - it can only be reported as
    /// `ListCollectionViewCell`. Verified on an iPad simulator, not assumed. The
    /// crop and the context shot are what carry the meaning there, which is the
    /// reason both are captured. This still earns its keep for AppKit and for any
    /// UIKit view hierarchy built out of real views.
    ///
    /// The text inside a container, trimmed. Bounded on purpose: a whole screen of
    /// words in a bundle field helps nobody, and neither does walking a deep tree
    /// on every pointer move.
    @MainActor
    static func descendantText(of view: PlatformView, limit: Int = 6) -> String? {
        var found: [String] = []

        func walk(_ view: PlatformView, depth: Int) {
            guard depth < 4, found.count < limit else { return }
            for subview in view.subviews {
                #if canImport(UIKit)
                if let label = subview as? UILabel, let text = label.text, !text.isEmpty {
                    found.append(text)
                }
                #elseif canImport(AppKit)
                if let field = subview as? NSTextField, !field.stringValue.isEmpty {
                    found.append(field.stringValue)
                }
                #endif
                walk(subview, depth: depth + 1)
            }
        }
        walk(view, depth: 0)

        let text = found.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        return text.count > 80 ? String(text.prefix(79)) + "\u{2026}" : text
    }

    private static func area(of rect: CGRect) -> Double {
        Double(rect.width * rect.height)
    }
}

#endif
