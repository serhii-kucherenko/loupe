import Foundation
import LoupeCore

#if canImport(UIKit) || canImport(AppKit)

/// The entry point an app uses.
///
/// Wire it once at launch, then call `capture` each time the person picks an element
/// and types a comment. The tray fills up on its own; `send` ships the batch.
///
///     Loupe.start(app: AppInfo(name: "Demo", platform: "macOS"))
///     Loupe.capture(at: point, in: window, comment: "stale results", tag: .bug)
///     try await Loupe.send()
@MainActor
public enum Loupe {
    public private(set) static var session: AnnotationSession?

    /// Installs the network recorder and opens the first tray.
    /// Defaults to writing bundles into `~/.loupe/<app>/`, so it works with no server.
    public static func start(app: AppInfo, transport: Transport? = nil) {
        NetworkRecorder.install()
        session = AnnotationSession(
            app: app,
            transport: transport ?? FileTransport(directory: FileTransport.defaultDirectory(appName: app.name))
        )
    }

    /// Resolves the point to a meaningful element, captures its picture and the
    /// recent requests, and adds the whole thing to the tray.
    @discardableResult
    public static func capture(
        at point: CGPoint,
        in window: PlatformWindow,
        comment: String,
        tag: AnnotationTag? = nil,
        screen: String? = nil
    ) -> Annotation? {
        guard let session, let picked = ElementPicker.pick(at: point, in: window) else { return nil }

        let annotation = Annotation(
            comment: comment,
            tag: tag,
            element: picked.ref,
            screenshotPNG: ElementPicker.screenshotPNG(of: picked.view),
            trace: NetworkRecorder.shared.recent(),
            screen: screen
        )
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
        session = nil
    }
}

#endif
