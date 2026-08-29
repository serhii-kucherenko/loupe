#if os(macOS)
import SwiftUI
import AppKit
import LoupeCore
import LoupeUI

/// The demo host, on a Mac.
///
/// Deliberately styled as a plain, slightly dull admin app, using nothing from
/// `DESIGN.md`. That is the test: the overlay has to read as a tool sitting on top
/// of someone else's product, and it cannot prove that against a host that shares
/// its own palette.
@main
struct LoupeDemoApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        WindowGroup("Northgate Supply — staging") {
            RootView(server: delegate.server)
                .tint(DemoLaunch.hostTint)
                .frame(minWidth: 900, minHeight: 640)
                .background(WindowAccessor { window in
                    // Attaching needs a window, and there is none at launch.
                    Loupe.attach(to: window)
                })
        }
        .windowStyle(.titleBar)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    let server = StubServer()

    func applicationDidFinishLaunching(_ notification: Notification) {
        // `swift run` produces a bare executable, which AppKit treats as a
        // background process unless it is told otherwise.
        NSApplication.shared.setActivationPolicy(.regular)
        NSApplication.shared.activate(ignoringOtherApps: true)

        DemoLaunch.start(server: server, platform: "macOS")
    }

    func applicationWillTerminate(_ notification: Notification) {
        server.stop()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

/// Reaches the `NSWindow` behind a SwiftUI scene, once there is one.
struct WindowAccessor: NSViewRepresentable {
    let onWindow: (NSWindow) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            if let window = view.window { onWindow(window) }
        }
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {}
}
#endif
