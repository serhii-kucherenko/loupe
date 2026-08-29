import SwiftUI
import Combine
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

    /// Where the mouse went down, and in which window, for the whole of one drag.
    ///
    /// The window is fixed at mouse-down rather than resolved per event: a rectangle
    /// dragged half off a sheet should still be a rectangle on that sheet.
    private var dragOrigin: (window: NSWindow, point: CGPoint)?

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

        // Only picking consumes the mouse. While commenting, the popover's own
        // buttons need it, so events go through untouched.
        //
        // Down, drag and up rather than a single click: the same press has to be
        // able to become either a pick or a dragged region, and which one it is is
        // not known until the mouse comes back up.
        if let down = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown], handler: { [weak self] event in
            let consumed = MainActor.assumeIsolated { () -> Bool in
                guard let self, self.model.mode.swallowsInput,
                      let target = self.target else { return false }

                // While commenting, a click on the popover belongs to the popover -
                // its own Save and Cancel would stop working otherwise. Anything
                // outside it means "actually, that one" and starts a fresh pick.
                if case .commenting = self.model.mode {
                    let onPanel = self.model.interactiveRegions
                        .contains { $0.contains(target.point) }
                    guard !onPanel else { return false }
                    self.model.resolveDraftAndResumePicking()
                }

                self.dragOrigin = target
                return true
            }
            return consumed ? nil : event
        }) { registrations.add(monitor: down) }

        if let drag = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDragged], handler: { [weak self] event in
            let consumed = MainActor.assumeIsolated { () -> Bool in
                guard let self, let origin = self.dragOrigin,
                      let now = self.target, now.window === origin.window else { return false }
                self.model.drag(to: Rect(Self.box(origin.point, now.point)))
                return true
            }
            return consumed ? nil : event
        }) { registrations.add(monitor: drag) }

        if let up = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseUp], handler: { [weak self] event in
            let consumed = MainActor.assumeIsolated { () -> Bool in
                guard let self, let origin = self.dragOrigin else { return false }
                self.dragOrigin = nil
                self.finishDrag(from: origin)
                return true
            }
            return consumed ? nil : event
        }) { registrations.add(monitor: up) }
    }

    static func box(_ a: CGPoint, _ b: CGPoint) -> CGRect {
        CGRect(x: min(a.x, b.x), y: min(a.y, b.y),
               width: abs(a.x - b.x), height: abs(a.y - b.y))
    }

    /// A press that barely moved is a click on an element; one that swept out a
    /// rectangle is a region. `capture(rect:in:)` decides which, by refusing
    /// anything under `minimumRegionSize`.
    private func finishDrag(from origin: (window: NSWindow, point: CGPoint)) {
        let end = target?.window === origin.window ? target?.point : nil
        let rect = Self.box(origin.point, end ?? origin.point)

        if let shot = ElementPicker.capture(rect: rect, in: origin.window) {
            deliver(shot, from: origin.window)
        } else {
            pick(at: end ?? origin.point, in: origin.window)
        }
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

    private func pick(at point: CGPoint, in window: NSWindow) {
        guard let shot = ElementPicker.capture(at: point, in: window) else { return }
        deliver(shot, from: window)
    }

    private func deliver(_ shot: (ref: ElementRef, screenshotPNG: Data?,
                                  contextScreenshotPNG: Data?),
                         from window: NSWindow) {
        let size = window.contentView?.bounds.size ?? .zero
        model.pick(shot.ref,
                   screenshotPNG: shot.screenshotPNG,
                   contextScreenshotPNG: shot.contextScreenshotPNG,
                   screen: window.title.isEmpty ? nil : window.title,
                   viewport: Rect(x: 0, y: 0, width: size.width, height: size.height))
    }
}
#endif

#if canImport(UIKit)
import UIKit

/// A window above the app's own, which lets touches through wherever the overlay
/// has nothing for them.
///
/// "Nothing for them" cannot be read off `hitTest`. A `UIHostingController` is a
/// single `UIView` whatever SwiftUI draws inside it, so comparing the hit against
/// the root view answers the same for the pill, for the tray's Send button and for
/// blank space - which made every control Loupe draws in a pass-through mode
/// untappable. The controls report their own frames instead; see
/// `InteractiveRegions.swift`.
final class PassthroughWindow: UIWindow {
    var isPassthrough: () -> Bool = { true }

    /// Whether the overlay currently needs the keyboard.
    ///
    /// A stored flag rather than a read of the model, and that is not incidental:
    /// `@Published` delivers on *willSet*, so anything asking the model for its mode
    /// from inside that callback still sees the previous one. Reading it there made
    /// the window refuse key status for the mode it was in the middle of entering.
    var wantsKeyboard = false

    /// Key status belongs to the app, except while the overlay needs the keyboard.
    ///
    /// The overlay sits above `.alert` and is never hidden, so UIKit was happy to
    /// hand it key status the moment it appeared - and key events go to the key
    /// window's responder chain. A host's `UIKeyCommand` then fired or did not
    /// depending on which window happened to be key, which is exactly the kind of
    /// intermittent fault nobody can reproduce. Found in a real app.
    ///
    /// `.picking` and `.commenting` genuinely need it: the comment field has to take
    /// the keyboard. `.off` and `.browsing` are the modes that promise the app
    /// underneath behaves exactly as it normally does.
    override var canBecomeKey: Bool { wantsKeyboard }


    /// Window-coordinate frames of the overlay's own controls.
    var interactiveRegions: () -> [CGRect] = { [] }

    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        let hit = super.hitTest(point, with: event)
        // Picking and commenting take everything, as before.
        guard isPassthrough() else { return hit }
        guard interactiveRegions().contains(where: { $0.contains(point) }) else { return nil }
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
        candidates(among: windows, excluding: overlay).max(by: inFront)
    }

    /// The window that actually has something under `point`.
    ///
    /// "Topmost" alone is not enough. UIKit keeps utility windows in the scene -
    /// `UITextEffectsWindow` sits above the app at level 1 with nothing in it, and
    /// on a scene where any text interaction has happened it wins on level every
    /// time. The pick then hit-tests an empty pane: the person points at a menu
    /// item and annotates a blank window instead. A window that hit-tests to
    /// nothing at the point is not what anyone was pointing at, so skip it.
    static func topmost(among windows: [UIWindow],
                        excluding overlay: UIWindow?,
                        at point: CGPoint) -> UIWindow? {
        let live = candidates(among: windows, excluding: overlay)
            .filter { $0.hitTest(point, with: nil) != nil }
        // Fall back to the plain rule rather than returning nothing: a pick that
        // lands somewhere imperfect still beats a tap that does nothing at all.
        return live.max(by: inFront) ?? candidates(among: windows, excluding: overlay).max(by: inFront)
    }

    private static func candidates(among windows: [UIWindow], excluding overlay: UIWindow?) -> [UIWindow] {
        windows.filter { $0 !== overlay && !$0.isHidden && $0.alpha > 0 }
    }

    private static func inFront(_ a: UIWindow, _ b: UIWindow) -> Bool {
        if a.windowLevel != b.windowLevel { return a.windowLevel < b.windowLevel }
        // Same level: the key window is the one in front.
        return (a.isKeyWindow ? 1 : 0) < (b.isKeyWindow ? 1 : 0)
    }

    static func topmost(in scene: UIWindowScene, excluding overlay: UIWindow?) -> UIWindow? {
        topmost(among: scene.windows, excluding: overlay)
    }

    static func topmost(in scene: UIWindowScene,
                        excluding overlay: UIWindow?,
                        at point: CGPoint) -> UIWindow? {
        topmost(among: scene.windows, excluding: overlay, at: point)
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
    /// Who gets the keyboard back when the overlay stops needing it.
    private weak var hostWindow: UIWindow?
    private var modeWatch: AnyCancellable?

    /// Fails when the host window has no scene, rather than inventing one. A window
    /// without a scene cannot have a sibling above it, so there is nothing to build.
    public init?(model: OverlayModel, host: UIWindow) {
        guard let scene = host.windowScene else { return nil }
        self.model = model
        self.scene = scene
        self.hostWindow = host

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
        func deliver(_ shot: (ref: ElementRef, screenshotPNG: Data?,
                              contextScreenshotPNG: Data?)?,
                     to model: OverlayModel, from target: UIWindow) {
            guard let shot else { return }
            model.pick(shot.ref,
                       screenshotPNG: shot.screenshotPNG,
                       contextScreenshotPNG: shot.contextScreenshotPNG,
                       viewport: Rect(x: 0, y: 0,
                                      width: target.bounds.width, height: target.bounds.height))
        }

        let content = OverlayRootWithPill(model: model, onTap: { [weak model, weak scene] point in
            guard let model, let scene,
                  let target = WindowFinder.topmost(in: scene, excluding: overlayWindow, at: point)
            else { return }
            model.resolveDraftAndResumePicking()
            deliver(ElementPicker.capture(at: point, in: target), to: model, from: target)
        }, onDrag: { [weak model, weak scene] rect in
            guard let model, let scene,
                  // The centre, not a corner: a rectangle drawn over a dialog should
                  // find the dialog's window, and a corner can easily sit outside it.
                  let target = WindowFinder.topmost(in: scene, excluding: overlayWindow,
                                                    at: CGPoint(x: rect.midX, y: rect.midY))
            else { return }
            model.resolveDraftAndResumePicking()
            deliver(ElementPicker.capture(rect: rect, in: target), to: model, from: target)
        }, window: window)

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
        window.interactiveRegions = { [weak model] in model?.interactiveRegions ?? [] }

        // `canBecomeKey` only stops the overlay from being handed the keyboard; it
        // neither takes it when the overlay does need it nor gives back what was
        // already taken. Both halves matter, and the second one is the half that
        // would have gone unnoticed: leaving the comment field unable to type is a
        // worse bug than the one being fixed.
        //
        // Observed rather than routed through `onModeChange`, which is a single slot
        // the host may want for itself.
        modeWatch = model.$mode.sink { [weak self] mode in
            self?.updateKeyWindow(for: mode)
        }
        // Once for the mode it starts in, so `wantsKeyboard` is never left at its
        // default while the overlay is already on screen.
        updateKeyWindow(for: model.mode)
    }

    /// Take the overlay off the screen, now.
    ///
    /// **A `UIWindow` shown in a scene is retained by the scene, not by whoever made
    /// it.** So dropping the last reference to `OverlayHost` deallocated the host and
    /// left the window exactly where it was - with nothing behind it driving it,
    /// which is worse than leaving it running. Somebody turned annotate mode off from
    /// their app's own menu and the pill stayed on screen.
    ///
    /// Not a `deinit`. `OverlayHost` is `@MainActor` and a `deinit` is nonisolated,
    /// so touching `window` from one is a Swift 6 error - the same rejection the
    /// monitor registrations hit. Teardown has to be asked for.
    public func stop() {
        modeWatch?.cancel()
        modeWatch = nil

        let scene = window.windowScene
        window.wantsKeyboard = false
        window.isHidden = true
        window.rootViewController = nil
        // Both, and in this order. Hiding it alone leaves the scene holding a window
        // it will happily show again on the next layout pass.
        window.windowScene = nil

        // Somebody has to be key afterwards, or the app has no keyboard at all - the
        // text field simply refuses focus and nothing says why.
        //
        // `hostWindow` is weak and is often already nil by the time a host tears
        // Loupe down, so it cannot be the only answer. Ask the scene for whatever is
        // left, which is the question that actually matters.
        let survivor = hostWindow ?? scene?.windows.first { $0 !== window && !$0.isHidden }
        survivor?.makeKey()
    }

    /// Who holds the keyboard, for one mode.
    private func updateKeyWindow(for mode: OverlayMode) {
        window.wantsKeyboard = mode.swallowsInput
        if mode.swallowsInput {
            if !window.isKeyWindow { window.makeKey() }
        } else if window.isKeyWindow {
            hostWindow?.makeKey()
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
    var onDrag: (CGRect) -> Void
    /// The overlay's own window, for turning the keyboard's screen frame into an
    /// inset. Weak-ish by construction: the view is rebuilt, never stored.
    weak var window: UIWindow?

    @State private var safeArea = EdgeInsets()
    @State private var keyboardInset: CGFloat = 0
    @State private var dragOrigin: CGPoint?

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            // The tap catcher exists only while picking, and sits *under* the
            // panels so the popover's own buttons still get their touches.
            //
            // It used to be `.contentShape(Rectangle())` on the whole overlay, all
            // the time, which made an idle overlay hit-testable across the entire
            // screen - one SwiftUI implementation detail away from making the host
            // app unusable.
            // Also while commenting, which is the whole of SER-695: pointing
            // somewhere else used to hit nothing, so the only way to change your
            // mind was to find Cancel first. The catcher sits under the panels, so
            // the popover's own controls still get their touches.
            if model.mode.swallowsInput {
                Color.clear
                    .contentShape(Rectangle())
                    .onTapGesture { point in onTap(point) }
                    // A drag draws a region; a tap still picks an element. The
                    // minimum distance is what keeps them apart - without it a tap
                    // that moves two points becomes a rectangle nobody meant.
                    .gesture(
                        DragGesture(minimumDistance: ElementPicker.minimumRegionSize)
                            .onChanged { value in
                                let origin = dragOrigin ?? value.startLocation
                                dragOrigin = origin
                                model.drag(to: Rect(box(origin, value.location)))
                            }
                            .onEnded { value in
                                let origin = dragOrigin ?? value.startLocation
                                dragOrigin = nil
                                onDrag(box(origin, value.location))
                            }
                    )
            }

            // The enter/exit control lives inside `OverlayRoot` so both platforms
            // get the same one in the same place.
            OverlayRoot(model: model, safeArea: safeArea, keyboardInset: keyboardInset)

            SafeAreaReader { safeArea = $0 }
        }
        .onPreferenceChange(InteractiveRegionsKey.self) { regions in
            MainActor.assumeIsolated { model.interactiveRegions = regions }
        }
        // The popover opens before the keyboard rises, so this has to re-place it
        // rather than only being read once.
        .onReceive(NotificationCenter.default.publisher(
            for: UIResponder.keyboardWillChangeFrameNotification)) { note in
            guard let end = note.userInfo?[UIResponder.keyboardFrameEndUserInfoKey]
                    as? CGRect,
                  let height = window?.bounds.height else { return }
            keyboardInset = max(0, height - end.minY)
        }
    }

    private func box(_ a: CGPoint, _ b: CGPoint) -> CGRect {
        CGRect(x: min(a.x, b.x), y: min(a.y, b.y),
               width: abs(a.x - b.x), height: abs(a.y - b.y))
    }
}
#endif
