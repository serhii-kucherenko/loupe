#if os(macOS)
import SwiftUI
import AppKit
import LoupeCore
import LoupeUI

/// The demo host.
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

        try? server.start()

        let app = AppInfo(name: "LoupeDemo",
                          version: "0.1.0",
                          commitSHA: gitSHA(),
                          platform: "macOS",
                          environment: "staging")
        Loupe.start(app: app)
        Seed.installIfNeeded(app: app, into: FileTransport.defaultDirectory(appName: app.name))
        LogRecorder.shared.info("stub server on \(server.port)", subsystem: "demo")
    }

    func applicationWillTerminate(_ notification: Notification) {
        server.stop()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    /// The single most useful field in a bundle: it is how an agent checks out the
    /// code that produced the screenshot.
    private func gitSHA() -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["git", "rev-parse", "--short", "HEAD"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        try? process.run()
        process.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let sha = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (sha?.isEmpty ?? true) ? nil : sha
    }
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

/// The two roles, side by side, because the point of the demo is the seam between
/// them: one person leaves notes, and the other thing reads what came out.
struct RootView: View {
    let server: StubServer
    @State private var role: Role = .annotator

    enum Role: String, CaseIterable, Identifiable {
        case annotator = "Annotator"
        case agent = "Agent inbox"
        var id: String { rawValue }
    }

    var body: some View {
        VStack(spacing: 0) {
            Picker("Role", selection: $role) {
                ForEach(Role.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(12)

            Divider()

            switch role {
            case .annotator: AnnotatorScreen(server: server)
            case .agent: AgentInbox()
            }
        }
    }
}
#endif
