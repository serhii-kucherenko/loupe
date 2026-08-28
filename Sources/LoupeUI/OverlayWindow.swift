import SwiftUI
import LoupeCore

#if canImport(AppKit)
import AppKit

/// Puts the overlay above a host window without becoming part of it.
///
/// The hard requirement is that the app underneath stays usable. A panel that
/// covers the screen and takes every click would make it impossible to navigate to
/// a second screen, and `AnnotationSession` exists precisely so one tray can span
/// several. So the panel's *frame* is the switch: while picking it covers the host
/// window, and while browsing it shrinks to the strip the tray occupies. Everything
/// outside that strip is then pass-through by construction, with no guessing about
/// what SwiftUI's hit-testing will do.
@MainActor
public final class OverlayHost {
    private let panel: NSPanel
    private let model: OverlayModel
    private weak var host: NSWindow?
    private var monitors: [Any] = []
    private var observers: [NSObjectProtocol] = []

    /// Width of the strip the tray needs, panel padding included.
    private var trayStripWidth: CGFloat { TrayPanel.width + LoupeTheme.Space.lg * 2 }

    public init(model: OverlayModel, host: NSWindow) {
        self.model = model
        self.host = host

        panel = NSPanel(contentRect: host.frame,
                        styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered,
                        defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.contentView = NSHostingView(rootView: OverlayRoot(model: model))

        model.onModeChange = { [weak self] mode in self?.apply(mode) }
        installMonitors()
        observeHostWindow()
        apply(model.mode)
    }

    deinit {
        let monitors = monitors
        let observers = observers
        MainActor.assumeIsolated {
            monitors.forEach(NSEvent.removeMonitor)
            observers.forEach(NotificationCenter.default.removeObserver)
        }
    }

    // MARK: - Mode

    private func apply(_ mode: OverlayMode) {
        guard let host else { return }
        guard mode.isVisible else { panel.orderOut(nil); return }

        panel.setFrame(frame(for: mode, host: host), display: true)
        panel.order(.above, relativeTo: host.windowNumber)
    }

    private func frame(for mode: OverlayMode, host: NSWindow) -> NSRect {
        guard mode == .browsing else { return host.frame }
        // Only the tray is live, so only the tray blocks the app.
        return NSRect(x: host.frame.maxX - trayStripWidth,
                      y: host.frame.minY,
                      width: trayStripWidth,
                      height: host.frame.height)
    }

    private func observeHostWindow() {
        for name in [NSWindow.didResizeNotification, NSWindow.didMoveNotification] {
            observers.append(NotificationCenter.default.addObserver(
                forName: name, object: host, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.apply(self?.model.mode ?? .off) }
            })
        }
    }

    // MARK: - Input

    /// Each monitor decides *whether* it consumed the event on the main actor, and
    /// returns the event itself from outside. NSEvent is not Sendable, so it must
    /// never cross the isolation boundary.
    private func installMonitors() {
        // ⌥⌘L. A default gesture means adopting Loupe needs no UI work from the host.
        if let hotkey = NSEvent.addLocalMonitorForEvents(matching: .keyDown, handler: { [weak self] event in
            let wanted: NSEvent.ModifierFlags = [.option, .command]
            let isToggle = event.modifierFlags.intersection(.deviceIndependentFlagsMask) == wanted
                && event.charactersIgnoringModifiers?.lowercased() == "l"
            guard isToggle else { return event }

            MainActor.assumeIsolated { self?.model.toggleAnnotating() }
            return nil
        }) { monitors.append(hotkey) }

        if let move = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved], handler: { [weak self] event in
            MainActor.assumeIsolated { self?.hover() }
            return event
        }) { monitors.append(move) }

        // Only picking consumes clicks. While commenting, the popover's own buttons
        // need them, so the event goes through untouched.
        if let click = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown], handler: { [weak self] event in
            let consumed = MainActor.assumeIsolated { () -> Bool in
                guard let self, case .picking = self.model.mode else { return false }
                self.pick()
                return true
            }
            return consumed ? nil : event
        }) { monitors.append(click) }
    }

    /// Where the pointer is, in the host window's top-left coordinates.
    private var pointerInHost: CGPoint? {
        guard let host, let content = host.contentView else { return nil }
        let inWindow = host.convertPoint(fromScreen: NSEvent.mouseLocation)
        let point = CGPoint(x: inWindow.x, y: content.bounds.height - inWindow.y)
        guard content.bounds.contains(CGPoint(x: point.x, y: inWindow.y)) else { return nil }
        return point
    }

    private func hover() {
        guard case .picking = model.mode, let host, let point = pointerInHost else { return }
        model.hover(ElementPicker.pick(at: point, in: host)?.ref)
    }

    private func pick() {
        guard let host, let point = pointerInHost,
              let picked = ElementPicker.pick(at: point, in: host) else { return }
        let size = host.contentView?.bounds.size ?? .zero
        model.pick(picked.ref,
                   screenshotPNG: ElementPicker.screenshotPNG(of: picked.view),
                   contextScreenshotPNG: ElementPicker.contextPNG(of: picked.view, in: host),
                   screen: host.title.isEmpty ? nil : host.title,
                   viewport: Rect(x: 0, y: 0, width: size.width, height: size.height))
    }
}
#endif

#if canImport(UIKit)
import UIKit

/// A window above the app's own, which lets clicks through wherever the overlay is
/// not drawing anything.
///
/// UIKit makes this easy in a way AppKit does not: the hosting controller's root
/// view is returned by `hitTest` for empty space, so returning nil for exactly that
/// case gives a clean pass-through.
final class PassthroughWindow: UIWindow {
    var isPassthrough: () -> Bool = { true }

    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        let hit = super.hitTest(point, with: event)
        if isPassthrough(), hit === rootViewController?.view { return nil }
        return hit
    }
}

/// Puts the overlay above the app on iPhone and iPad.
///
/// Annotate mode is entered from a floating pill rather than a shake. A shake read
/// from a pass-through window above the app is unreliable, and a pill is something
/// a person can find without being told. `Loupe.handleShake()` is there for a host
/// that wants to wire the gesture from its own responder, where it does work.
@MainActor
public final class OverlayHost {
    private let window: PassthroughWindow
    private let model: OverlayModel
    private weak var host: UIWindow?

    /// Fails when the host window has no scene, rather than inventing one. A window
    /// without a scene cannot have a sibling above it, so there is nothing to build.
    public init?(model: OverlayModel, host: UIWindow) {
        guard let scene = host.windowScene else { return nil }
        self.model = model
        self.host = host

        window = PassthroughWindow(windowScene: scene)
        window.windowLevel = host.windowLevel + 1
        window.backgroundColor = .clear
        window.isHidden = false

        // Weak on both: the overlay must never be the reason the host window or the
        // model stays alive.
        let content = OverlayRootWithPill(model: model, onTap: { [weak model, weak host] point in
            guard let model, let host,
                  let picked = ElementPicker.pick(at: point, in: host) else { return }
            model.pick(picked.ref,
                       screenshotPNG: ElementPicker.screenshotPNG(of: picked.view),
                       contextScreenshotPNG: ElementPicker.contextPNG(of: picked.view, in: host),
                       viewport: Rect(x: 0, y: 0,
                                      width: host.bounds.width, height: host.bounds.height))
        })

        let controller = UIHostingController(rootView: content)
        controller.view.backgroundColor = .clear
        window.rootViewController = controller

        window.isPassthrough = { [weak model] in
            !(model?.mode.swallowsInput ?? false)
        }
    }
}

/// The overlay plus the pill that opens it. iOS only: macOS has the hotkey.
private struct OverlayRootWithPill: View {
    @ObservedObject var model: OverlayModel
    var onTap: (CGPoint) -> Void

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            OverlayRoot(model: model)
                .contentShape(Rectangle())
                .onTapGesture { point in
                    guard case .picking = model.mode else { return }
                    onTap(point)
                }

            if model.mode == .off {
                Button {
                    model.beginAnnotating()
                } label: {
                    Label("Annotate", systemImage: "scope")
                }
                .buttonStyle(LoupeButtonStyle(kind: .primary))
                .loupePanel()
                .padding(LoupeTheme.Space.lg)
                .accessibilityLabel("Start annotating")
            }
        }
    }
}
#endif
