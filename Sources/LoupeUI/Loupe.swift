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
    public static func start(app: AppInfo, transport: Transport? = nil) {
        NetworkRecorder.install()

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
    @discardableResult
    public static func capture(
        at point: CGPoint,
        in window: PlatformWindow,
        comment: String,
        tag: AnnotationTag? = nil,
        screen: String? = nil
    ) -> Annotation? {
        guard let session,
              let shot = ElementPicker.capture(at: point, in: window) else { return nil }

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
        NetworkRecorder.uninstall()
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
