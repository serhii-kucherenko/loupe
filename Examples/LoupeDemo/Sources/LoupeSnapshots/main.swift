#if os(macOS)
import SwiftUI
import AppKit
import LoupeCore
import LoupeUI

/// Renders the overlay to PNG, light and dark, without a screen.
///
/// It uses a real `NSWindow` and a real hosting view rather than `ImageRenderer`.
/// `ImageRenderer` cannot draw a live `TextField` - it puts a yellow box with a
/// prohibition sign where the comment field should be - and it ignores the drawing
/// appearance, so light and dark came out byte-identical. A real view hierarchy has
/// neither problem, and it is also what actually ships.
///
/// A design system only checkable by launching an app is one that stops being
/// checked. These land in `docs/screenshots/` and go in the pull request.
@MainActor
func run() {
    let output = URL(fileURLWithPath: CommandLine.arguments.count > 1
                     ? CommandLine.arguments[1]
                     : "docs/screenshots")
    try? FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

    _ = NSApplication.shared
    NSApplication.shared.setActivationPolicy(.prohibited)

    for (name, appearance) in [("light", NSAppearance(named: .aqua)!),
                               ("dark", NSAppearance(named: .darkAqua)!)] {
        for scene in Scene.allCases {
            capture(scene, appearance: appearance,
                    to: output.appendingPathComponent("\(scene.rawValue)-\(name).png"))
        }
    }
    print("wrote \(Scene.allCases.count * 2) snapshots to \(output.path)")
}

// MARK: - The fake product underneath

/// Absolute positions, so the element the overlay highlights and the row drawn on
/// screen come from the same numbers. A snapshot where the outline misses the row
/// is worse than no snapshot: it looks like the picker is broken.
enum HostLayout {
    static let size = CGSize(width: 900, height: 620)
    static let rowX: CGFloat = 40
    static let rowWidth: CGFloat = 420
    static let rowHeight: CGFloat = 36
    static let firstRowY: CGFloat = 150
    static let rowGap: CGFloat = 8

    static let rows = ["Blue canvas jacket   £128.00",
                       "Wool overshirt, ink   £96.00",
                       "Selvedge denim, 13oz   £145.00",
                       "Boiled wool cap   £38.00"]

    static func rowFrame(_ index: Int) -> CGRect {
        CGRect(x: rowX,
               y: firstRowY + CGFloat(index) * (rowHeight + rowGap),
               width: rowWidth, height: rowHeight)
    }

    static let basket = CGRect(x: 520, y: 150, width: 300, height: 110)
}

/// A host app with a design system of its own.
///
/// Loupe's own look is a warm orange, on purpose: it must read as a tool rather than
/// as part of the app underneath. But a host that *has* an accent gets to say so -
/// and an overlay in somebody else's colours is the difference between a control
/// that belongs on the screen and one that reads as broken.
enum HostBrand {
    static let accent = LoupeTheme.ColorToken(light: LoupeTheme.RGBA(hex: 0x4338CA),
                                              dark: LoupeTheme.RGBA(hex: 0xA5B4FC))

    /// What this host would pass to `Loupe.start(app:theme:)`. Three fields, which
    /// is the point: a host names what it has an opinion about and nothing else.
    static let loupe = LoupeTheme.Appearance(accent: accent,
                                             action: accent,
                                             panelRadius: 28,
                                             controlRadius: 20)
}

struct HostApp<Overlay: View>: View {
    /// nil for the plain host. A colour turns this into a branded app, so the
    /// overlay drawn over it can be seen agreeing with it.
    var brand: Color?
    @ViewBuilder var overlay: Overlay

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color(nsColor: .windowBackgroundColor)

            Text("Stock").font(.title2).bold()
                .foregroundStyle(brand ?? Color(nsColor: .labelColor))
                .frame(width: 200, height: 28, alignment: .leading)
                .offset(x: HostLayout.rowX, y: 40)

            HStack(spacing: 8) {
                Text("wool")
                    .padding(.horizontal, 8)
                    .frame(width: 240, height: 28, alignment: .leading)
                    .background(Color(nsColor: .textBackgroundColor))
                    .border(Color.secondary.opacity(0.35))
                Text("Search")
                    .foregroundStyle(brand == nil ? Color(nsColor: .labelColor) : .white)
                    .padding(.horizontal, 12)
                    .frame(height: 28)
                    .background(brand ?? Color(nsColor: .controlColor))
                    .clipShape(RoundedRectangle(cornerRadius: brand == nil ? 0 : 14))
                    .border(brand == nil ? Color.secondary.opacity(0.35) : .clear)
            }
            .offset(x: HostLayout.rowX, y: 92)

            ForEach(Array(HostLayout.rows.enumerated()), id: \.offset) { index, row in
                let frame = HostLayout.rowFrame(index)
                Text(row)
                    .padding(.horizontal, 10)
                    .frame(width: frame.width, height: frame.height, alignment: .leading)
                    .background(Color(nsColor: .textBackgroundColor))
                    .offset(x: frame.minX, y: frame.minY)
            }

            VStack(spacing: 4) {
                Text("Your basket is empty")
                Text("0 items").font(.caption).foregroundStyle(.secondary)
            }
            .frame(width: HostLayout.basket.width, height: HostLayout.basket.height)
            .background(Color.secondary.opacity(0.08))
            .offset(x: HostLayout.basket.minX, y: HostLayout.basket.minY)

            overlay
        }
        .frame(width: HostLayout.size.width, height: HostLayout.size.height)
    }
}

// MARK: - The three states worth looking at

enum Scene: String, CaseIterable {
    case hover = "01-hover"
    case comment = "02-comment"
    case tray = "03-tray"
    /// The same drawer, in a host app's own accent and radii. Kept next to `tray`
    /// in `docs/screenshots/` precisely so the two can be looked at together: same
    /// overlay, same content, wearing somebody else's design system.
    case hosted = "11-host-theme"

    /// What the host would have passed to `Loupe.start`.
    var theme: LoupeTheme.Appearance { self == .hosted ? HostBrand.loupe : .stock }

    /// The accent the app underneath is drawn in, so the agreement is visible.
    var brand: Color? { self == .hosted ? Color(red: 0.263, green: 0.220, blue: 0.792) : nil }

    private static func ref(_ frame: CGRect, id: String, label: String) -> ElementRef {
        ElementRef(accessibilityID: id, label: label, className: "ResultRow",
                   bounds: Rect(x: frame.minX, y: frame.minY,
                                width: frame.width, height: frame.height))
    }

    /// - Parameter crop: a real picture of a rectangle of the app, so a note in the
    ///   drawer carries the thumbnail a real note would. Without it the tray shot
    ///   showed rows of text while the README beside it promised a thumbnail, which
    ///   is the sort of quiet disagreement nobody notices until they run the thing.
    @MainActor
    func model(crop: (Rect) -> Data? = { _ in nil }) -> OverlayModel {
        struct Noop: Transport { func send(_ bundle: AnnotationBundle) async throws {} }
        let model = OverlayModel(
            session: AnnotationSession(app: AppInfo(name: "Northgate Supply", platform: "macOS"),
                                       transport: Noop()))

        let row = Self.ref(HostLayout.rowFrame(1), id: "search.results",
                           label: "Wool overshirt, ink")

        model.beginAnnotating()
        switch self {
        case .hover:
            model.hover(row)
        case .comment:
            model.pick(row, screen: "/search")
            // Typed, not empty. An offscreen window is never key, so no focus ring
            // ever draws here - which left the picture showing a comment box that
            // looks inactive, beside a Save that looks broken, while the product
            // opens focused with the keyboard up. Seeding the draft removes the
            // dependence on focus entirely and shows the thing that matters: a note
            // being written, a tag chosen, Save live.
            model.draftComment = "clearing the search leaves the old results on screen"
            model.draftTag = .bug
        case .tray, .hosted:
            model.pick(row, screenshotPNG: crop(row.bounds), screen: "/search")
            model.saveComment("clearing the search leaves the old results on screen", tag: .bug)
            model.resumePicking()
            let basket = Self.ref(HostLayout.basket, id: "cart.empty",
                                  label: "Your basket is empty")
            model.pick(basket, screenshotPNG: crop(basket.bounds), screen: "/cart")
            model.saveComment("the empty basket gives you nowhere to go from here", tag: .polish)
            // Asked for, because the drawer no longer opens itself. Saving a note
            // used to change the layout under somebody's hands.
            model.setTrayExpanded(true)
        }
        return model
    }
}

// MARK: - Rendering

/// The app with nothing drawn over it, so notes can carry real crops of it.
///
/// A separate first pass, because the model has to be built before the window that
/// would be its source. Rendering twice is cheaper than every other way of getting a
/// truthful picture into a thumbnail.
@MainActor
func hostOnly(appearance: NSAppearance, brand: Color? = nil) -> CGImage? {
    let window = NSWindow(contentRect: NSRect(origin: .zero, size: HostLayout.size),
                          styleMask: [.borderless], backing: .buffered, defer: false)
    window.appearance = appearance
    window.contentView = NSHostingView(rootView: HostApp(brand: brand) { EmptyView() })
    window.orderBack(nil)
    RunLoop.main.run(until: Date().addingTimeInterval(0.35))
    defer { window.close() }

    guard let content = window.contentView,
          let rep = content.bitmapImageRepForCachingDisplay(in: content.bounds) else {
        return nil
    }
    content.cacheDisplay(in: content.bounds, to: rep)
    return rep.cgImage
}

/// One rectangle of that picture, as a PNG.
///
/// `bounds` counts down from the top like every rectangle Loupe deals in, and so does
/// a `CGImage`, so this is a scale and nothing else - no flip. The scale is real: the
/// bitmap is at the display's backing scale and the rectangle is in points.
func cut(_ image: CGImage, to bounds: Rect) -> Data? {
    let scaleX = Double(image.width) / HostLayout.size.width
    let scaleY = Double(image.height) / HostLayout.size.height
    let box = CGRect(x: bounds.x * scaleX, y: bounds.y * scaleY,
                     width: bounds.width * scaleX, height: bounds.height * scaleY)
    guard box.width >= 1, box.height >= 1,
          let piece = image.cropping(to: box) else { return nil }
    return NSBitmapImageRep(cgImage: piece).representation(using: .png, properties: [:])
}

@MainActor
func capture(_ scene: Scene, appearance: NSAppearance, to url: URL) {
    // Set before the model is built and the window is rendered: the theme is what
    // every token reads, so anything drawn before this point is drawn in the last
    // scene's colours.
    LoupeTheme.appearance = scene.theme
    defer { LoupeTheme.appearance = .stock }

    let host = hostOnly(appearance: appearance, brand: scene.brand)
    let model = scene.model { bounds in host.flatMap { cut($0, to: bounds) } }
    let window = NSWindow(contentRect: NSRect(origin: .zero, size: HostLayout.size),
                          styleMask: [.borderless], backing: .buffered, defer: false)
    window.appearance = appearance
    window.contentView = NSHostingView(
        rootView: HostApp(brand: scene.brand) { OverlayRoot(model: model) })
    window.orderBack(nil)

    // Let SwiftUI lay out and settle before the bitmap is taken.
    RunLoop.main.run(until: Date().addingTimeInterval(0.35))

    guard let content = window.contentView,
          let rep = content.bitmapImageRepForCachingDisplay(in: content.bounds) else {
        print("could not render \(url.lastPathComponent)"); return
    }
    content.cacheDisplay(in: content.bounds, to: rep)
    guard let png = rep.representation(using: .png, properties: [:]) else { return }
    try? png.write(to: url)
    window.close()
}

MainActor.assumeIsolated { run() }
#endif
