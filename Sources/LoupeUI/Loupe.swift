import Foundation
import SwiftUI
import LoupeCore

#if canImport(UIKit) || canImport(AppKit)

/// The entry point an app uses.
///
/// Two calls at launch, in dev and staging builds only, and the rest is the
/// overlay's problem:
///
///     Loupe.start(app: AppInfo(name: "Demo", platform: "macOS"))
///     Loupe.attach(to: window)
///
/// After that ⌥⌘L on macOS, or the floating pill on iPhone and iPad, opens
/// annotate mode. Nothing else in the host app has to know Loupe exists.
@MainActor
public enum Loupe {
    public private(set) static var session: AnnotationSession?
    public private(set) static var model: OverlayModel?
    private static var host: OverlayHost?

    /// Installs the network recorder and opens the tray.
    ///
    /// Defaults to writing bundles into `~/.loupe/<app>/` on macOS, so it works with
    /// no server to run. The tray itself is written to disk on every change, so
    /// killing the app does not lose what someone already typed.
    /// - Parameter theme: the host's own tokens, so the overlay stops looking like a
    ///   visitor in somebody else's app. Every field has a default, so a host names
    ///   only what it has an opinion about, and omitting the argument entirely gives
    ///   exactly Loupe's own look.
    public static func start(app: AppInfo,
                             transport: Transport? = nil,
                             theme: LoupeTheme.Appearance = .stock) {
        LoupeTheme.appearance = theme
        NetworkRecorder.install()

        // Asked here rather than of the host. A layout bug needs the device and the
        // screen, and a host that had to fill those in would fill them in once, from
        // whatever machine the developer was on that day.
        var app = app
        if app.device == nil { app.device = DeviceInfo.current() }

        let directory = FileTransport.defaultDirectory(appName: app.name)
        let resolved = transport ?? FileTransport(directory: directory)
        let session = AnnotationSession(
            app: app,
            transport: resolved,
            persistingTo: directory.appendingPathComponent("tray.json"))

        self.session = session
        self.model = OverlayModel(session: session, queue: resolved as? QueuedTransport)
    }

    /// Puts the overlay above one of the app's windows.
    ///
    /// Separate from `start` because a window rarely exists yet at the moment an app
    /// wants to begin recording, and the recorder should not wait for one.
    /// - Returns: whether the overlay is now above that window. It is
    ///   `@discardableResult` because most hosts have nothing useful to do with a
    ///   failure - but a failure is not silent: attaching before `start` is a
    ///   programmer error that otherwise produces an SDK which simply never appears,
    ///   with nothing anywhere saying why. That is the single hardest kind of bug to
    ///   find in something whose whole job is to be an overlay.
    @discardableResult
    public static func attach(to window: PlatformWindow) -> Bool {
        guard let model else {
            assertionFailure("Loupe.attach(to:) was called before Loupe.start(app:). "
                             + "The overlay will not appear.")
            return false
        }
        // See OverlayWindow.swift: os(macOS) rather than canImport(AppKit), because
        // Catalyst can import AppKit and must still take the UIKit path.
        #if os(macOS)
        host = OverlayHost(model: model, host: window)
        return true
        #else
        host = OverlayHost(model: model, host: window)
        return host != nil
        #endif
    }

    public static func beginAnnotating() { model?.beginAnnotating() }
    public static func endAnnotating() { model?.endAnnotating() }
    public static func toggleAnnotating() { model?.toggleAnnotating() }

    /// For a host that wants shake-to-annotate: call this from your own
    /// `motionEnded`. Loupe does not read the gesture itself, because a pass-through
    /// window above the app is not a reliable place to hear it.
    public static func handleShake() { model?.toggleAnnotating() }

    /// Resolves the point to a meaningful element, captures its picture and the
    /// recent requests, and adds the whole thing to the tray. This is the path for
    /// a host driving Loupe itself, without the overlay.
    ///
    /// - Parameter point: top-left origin, in viewport points, on every platform.
    ///
    /// Asynchronous, and that is a deliberate break for anybody calling it: a
    /// `WKWebView` renders out of process, and the only way to get its real pixels is
    /// to ask WebKit and wait. The alternative was a picture of the previous screen,
    /// which is worse than no picture because nothing about it says it is wrong.
    @discardableResult
    public static func capture(
        at point: CGPoint,
        in window: PlatformWindow,
        comment: String,
        tag: AnnotationTag? = nil,
        screen: String? = nil
    ) async -> Annotation? {
        guard let session,
              let shot = await ElementPicker.capture(at: point, in: window) else { return nil }

        let annotation = Annotation(
            comment: comment,
            tag: tag,
            element: shot.ref,
            screenshotPNG: shot.screenshotPNG,
            contextScreenshotPNG: shot.contextScreenshotPNG,
            trace: NetworkRecorder.shared.recent(),
            logs: LogRecorder.shared.recent(),
            screen: screen,
            viewport: viewport(of: window))
        session.add(annotation)
        return annotation
    }

    @discardableResult
    public static func send() async throws -> AnnotationBundle {
        guard let session else { throw LoupeError.emptySession }
        return try await session.send()
    }

    public static func stop() {
        // Back to Loupe's own look, so a second `start` with no theme is not still
        // wearing the last host's.
        LoupeTheme.appearance = .stock
        NetworkRecorder.uninstall()
        // Ask, do not assume. Dropping the reference is not a teardown: on iOS the
        // scene retains the overlay's window, so `host = nil` on its own left the
        // pill on screen with nothing behind it.
        host?.stop()
        host = nil
        model = nil
        session = nil
    }

    private static func viewport(of window: PlatformWindow) -> Rect {
        #if canImport(UIKit)
        let size = window.bounds.size
        #elseif canImport(AppKit)
        let size = window.contentView?.bounds.size ?? .zero
        #endif
        return Rect(x: 0, y: 0, width: size.width, height: size.height)
    }
}

#endif
