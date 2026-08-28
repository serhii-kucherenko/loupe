import SwiftUI
import LoupeCore

// `os(macOS)`, not `canImport(AppKit)`.
//
// Under Mac Catalyst **both** are importable, so a standalone `canImport(AppKit)`
// block compiles alongside the UIKit one - two `OverlayHost` declarations - and then
// fails anyway, because NSPanel and NSWindow are unavailable there. Catalyst is an
// iOS app wearing a Mac coat, so it takes the UIKit path.
//
// Elsewhere in LoupeUI the same choice is made by putting `canImport(UIKit)` first
// and AppKit in an `#elseif`, which is safe for the same reason: UIKit wins.
#if os(macOS)
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
/// Owns the event monitors and notification observers, and can be emptied from a
/// nonisolated `deinit` because it is Sendable and does its own locking.
private final class Registrations: @unchecked Sendable {
    private let lock = NSLock()
    private var monitors: [Any] = []
    private var observers: [NSObjectProtocol] = []

    func add(monitor: Any) {
        lock.lock(); defer { lock.unlock() }
        monitors.append(monitor)
    }

    func add(observer: NSObjectProtocol) {
        lock.lock(); defer { lock.unlock() }
        observers.append(observer)
    }

    func removeAll() {
        lock.lock()
        let monitors = self.monitors, observers = self.observers
        self.monitors = []; self.observers = []
        lock.unlock()

        // Both APIs are main-thread-only, and a host is only ever released there.
        MainActor.assumeIsolated {
            monitors.forEach(NSEvent.removeMonitor)
            observers.forEach(NotificationCenter.default.removeObserver)
        }
    }
}

/// Which window a pick actually means, on AppKit.
///
/// The same problem as on iOS, in AppKit clothing: a sheet, a popover and a modal
/// are each their own `NSWindow`. Hit-testing only the window Loupe was attached to
/// would silently annotate whatever sits behind the sheet the person is looking at.
@MainActor
enum WindowFinder {
    /// Takes the list rather than reaching for `NSApp`, so the rule can be tested.
    /// `orderedIndex` counts from the front, so the smallest wins.
    static func topmost(among windows: [NSWindow], at screenPoint: CGPoint,
                        excluding overlay: NSWindow?) -> NSWindow? {
        windows
            .filter { $0 !== overlay && $0.isVisible && $0.frame.contains(screenPoint) }
            .min { $0.orderedIndex < $1.orderedIndex }
    }
}

@MainActor
public final class OverlayHost {
    private let panel: NSPanel
    private let model: OverlayModel
    private weak var host: NSWindow?

    /// Kept in a Sendable box rather than in stored arrays.
    ///
    /// Under Swift 6 a `deinit` is nonisolated and may not touch a non-Sendable
    /// stored property of an isolated class - and an NSEvent monitor is `Any`, while
    /// a notification observer is `any NSObjectProtocol`. Neither is Sendable. The
    /// box owns its own locking, so dropping the host still unhooks everything.
    private let registrations = Registrations()

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
        registrations.removeAll()
    }

    /// Unhook everything now rather than waiting to be deallocated.
    public func stop() {
        registrations.removeAll()
        panel.orderOut(nil)
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
            registrations.add(observer: NotificationCenter.default.addObserver(
                forName: name, object: host, queue: .main
            ) { [weak self] _ in
                // `Notification` is not Sendable, so it must not be captured out of
                // this closure. Nothing here needs it: the event is the signal.
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
        }) { registrations.add(monitor: hotkey) }

        if let move = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved], handler: { [weak self] event in
            MainActor.assumeIsolated { self?.hover() }
            return event
        }) { registrations.add(monitor: move) }

        // Only picking consumes clicks. While commenting, the popover's own buttons
        // need them, so the event goes through untouched.
        if let click = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown], handler: { [weak self] event in
            let consumed = MainActor.assumeIsolated { () -> Bool in
                guard let self, case .picking = self.model.mode else { return false }
                self.pick()
                return true
            }
            return consumed ? nil : event
        }) { registrations.add(monitor: click) }
    }

    /// The window under the pointer, and the pointer's position inside it in
    /// top-left coordinates.
    ///
    /// Resolved per event rather than captured at `attach` time, so a sheet or a
    /// modal - each of which is its own window - is what gets annotated when it is
    /// the thing on screen.
    private var target: (window: NSWindow, point: CGPoint)? {
        let screenPoint = NSEvent.mouseLocation
        guard let window = WindowFinder.topmost(among: NSApp.windows, at: screenPoint,
                                                excluding: panel),
              let content = window.contentView else { return nil }

        let inWindow = window.convertPoint(fromScreen: screenPoint)
        guard content.bounds.contains(inWindow) else { return nil }
        return (window, CGPoint(x: inWindow.x, y: content.bounds.height - inWindow.y))
    }

    private func hover() {
        guard case .picking = model.mode, let target else { return }
        model.hover(ElementPicker.hoverRef(at: target.point, in: target.window))
    }

    private func pick() {
        guard let target,
              let shot = ElementPicker.capture(at: target.point, in: target.window) else { return }
        let size = target.window.contentView?.bounds.size ?? .zero
        model.pick(shot.ref,
                   screenshotPNG: shot.screenshotPNG,
                   contextScreenshotPNG: shot.contextScreenshotPNG,
                   screen: target.window.title.isEmpty ? nil : target.window.title,
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

/// Which window a pick actually means.
///
/// Not the one Loupe was attached to. A dialog, an alert, an action sheet - each of
/// those is presented in its **own** window, above the app's. Hit-testing the window
/// captured at `attach` time would silently annotate whatever sits behind the thing
/// the person is looking at.
@MainActor
enum WindowFinder {
    /// Takes the list rather than the scene, so the rule can be tested. A SwiftPM
    /// test bundle has no app host and therefore no `UIWindowScene` at all - a
    /// version of this that only accepted a scene could only ever be skipped.
    static func topmost(among windows: [UIWindow], excluding overlay: UIWindow?) -> UIWindow? {
        windows
            .filter { $0 !== overlay && !$0.isHidden && $0.alpha > 0 }
            .max { a, b in
                if a.windowLevel != b.windowLevel { return a.windowLevel < b.windowLevel }
                // Same level: the key window is the one in front.
                return (a.isKeyWindow ? 1 : 0) < (b.isKeyWindow ? 1 : 0)
            }
    }

    static func topmost(in scene: UIWindowScene, excluding overlay: UIWindow?) -> UIWindow? {
        topmost(among: scene.windows, excluding: overlay)
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
    /// Internal rather than private so tests can assert on it without the type
    /// growing a test-only API.
    /// One step above `.alert`, which is where dialogs, action sheets and alerts
    /// present themselves.
    static let windowLevel = UIWindow.Level(rawValue: UIWindow.Level.alert.rawValue + 1)

    /// Internal rather than private so tests can assert on it without the type
    /// growing a test-only API.
    let window: PassthroughWindow
    private let model: OverlayModel
    private weak var scene: UIWindowScene?

    /// Fails when the host window has no scene, rather than inventing one. A window
    /// without a scene cannot have a sibling above it, so there is nothing to build.
    public init?(model: OverlayModel, host: UIWindow) {
        guard let scene = host.windowScene else { return nil }
        self.model = model
        self.scene = scene

        window = PassthroughWindow(windowScene: scene)
        // Above alerts, not above the host.
        //
        // `host.windowLevel + 1` put the overlay *underneath* any dialog, because a
        // dialog gets its own window at `.alert`. The pill was then behind the
        // dialog, and a tap where it appeared landed on the dialog's dimming view -
        // which dismissed the dialog instead of starting annotate mode.
        window.windowLevel = Self.windowLevel
        window.backgroundColor = .clear
        window.isHidden = false

        let overlayWindow = window
        // Weak on both: the overlay must never be the reason a window or the model
        // stays alive.
        let content = OverlayRootWithPill(model: model, onTap: { [weak model, weak scene] point in
            guard let model, let scene,
                  let target = WindowFinder.topmost(in: scene, excluding: overlayWindow),
                  let shot = ElementPicker.capture(at: point, in: target) else { return }
            model.pick(shot.ref,
                       screenshotPNG: shot.screenshotPNG,
                       contextScreenshotPNG: shot.contextScreenshotPNG,
                       viewport: Rect(x: 0, y: 0,
                                      width: target.bounds.width, height: target.bounds.height))
        })

        let controller = UIHostingController(rootView: content.ignoresSafeArea())
        controller.view.backgroundColor = .clear
        // Without this the SwiftUI origin sits below the status bar while
        // `ElementRef.bounds` is in window coordinates, so every highlight is drawn
        // a safe-area inset too low. The panels re-apply the insets themselves.
        controller.view.insetsLayoutMarginsFromSafeArea = false
        window.rootViewController = controller

        window.isPassthrough = { [weak model] in
            !(model?.mode.swallowsInput ?? false)
        }
    }
}

/// The overlay plus the pill that opens it. iOS only: macOS has the hotkey.
/// Reports the host window's safe area, and keeps reporting it after a rotation.
///
/// The overlay ignores the safe area on purpose so its coordinates match the window
/// the picker measures in, which means SwiftUI reports it as having none. The window
/// still knows the real numbers.
private struct SafeAreaReader: UIViewRepresentable {
    let onChange: (EdgeInsets) -> Void

    final class Reader: UIView {
        var onChange: ((EdgeInsets) -> Void)?

        override func safeAreaInsetsDidChange() {
            super.safeAreaInsetsDidChange()
            report()
        }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            report()
        }

        private func report() {
            guard let insets = window?.safeAreaInsets else { return }
            onChange?(EdgeInsets(top: insets.top, leading: insets.left,
                                 bottom: insets.bottom, trailing: insets.right))
        }
    }

    func makeUIView(context: Context) -> Reader {
        let view = Reader()
        view.isUserInteractionEnabled = false
        view.onChange = onChange
        return view
    }

    func updateUIView(_ view: Reader, context: Context) { view.onChange = onChange }
}

private struct OverlayRootWithPill: View {
    @ObservedObject var model: OverlayModel
    var onTap: (CGPoint) -> Void

    @State private var safeArea = EdgeInsets()

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            // The tap catcher exists only while picking, and sits *under* the
            // panels so the popover's own buttons still get their touches.
            //
            // It used to be `.contentShape(Rectangle())` on the whole overlay, all
            // the time, which made an idle overlay hit-testable across the entire
            // screen - one SwiftUI implementation detail away from making the host
            // app unusable.
            if case .picking = model.mode {
                Color.clear
                    .contentShape(Rectangle())
                    .onTapGesture { point in onTap(point) }
            }

            OverlayRoot(model: model, safeArea: safeArea)

            SafeAreaReader { safeArea = $0 }

            if model.mode == .off {
                Button {
                    model.beginAnnotating()
                } label: {
                    Label("Annotate", systemImage: "scope")
                }
                .buttonStyle(LoupeButtonStyle(kind: .primary))
                .loupePanel()
                .padding(LoupeTheme.Space.lg)
                // The overlay ignores the safe area, so without this the pill sits
                // in the home indicator's space.
                .padding(.bottom, safeArea.bottom)
                .padding(.trailing, safeArea.trailing)
                .accessibilityLabel("Start annotating")
            }
        }
    }
}
#endif
