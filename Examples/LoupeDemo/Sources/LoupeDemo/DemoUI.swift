import SwiftUI
import LoupeCore
import LoupeUI
import LoupeLinear

/// The bits of the demo that differ between a Mac window and an iPad screen.
///
/// Kept deliberately small. The demo's job is to be someone else's product, and a
/// host app that needed a platform abstraction layer to show two columns would be
/// testing the abstraction rather than the overlay.

/// Two columns on a wide screen, stacked on a narrow one.
///
/// `HSplitView` is AppKit-only, and an iPhone has no room for two columns anyway.
struct Columns<Leading: View, Trailing: View>: View {
    @ViewBuilder var leading: Leading
    @ViewBuilder var trailing: Trailing

    #if canImport(UIKit)
    @Environment(\.horizontalSizeClass) private var sizeClass
    private var isWide: Bool { sizeClass != .compact }
    #else
    private var isWide: Bool { true }
    #endif

    var body: some View {
        if isWide {
            HStack(alignment: .top, spacing: 0) {
                leading
                Divider()
                trailing
            }
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    leading
                    Divider()
                    trailing
                }
            }
        }
    }
}

/// A minimum width a narrow screen is allowed to ignore.
///
/// A plain `.frame(minWidth:)` is a promise the layout cannot keep on a phone: the
/// content is forced wider than the screen and simply runs off the left edge. Found
/// on an iPhone, where "Stock" read "tock" and the search field started off-screen.
extension View {
    func columnWidth(_ width: CGFloat) -> some View { modifier(ColumnWidth(width: width)) }
}

private struct ColumnWidth: ViewModifier {
    let width: CGFloat

    #if canImport(UIKit)
    @Environment(\.horizontalSizeClass) private var sizeClass
    private var isWide: Bool { sizeClass != .compact }
    #else
    private var isWide: Bool { true }
    #endif

    func body(content: Content) -> some View {
        if isWide {
            content.frame(minWidth: width)
        } else {
            content.frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// A PNG from disk, as a SwiftUI image, on either platform.
func demoImage(contentsOf url: URL) -> Image? {
    guard let data = try? Data(contentsOf: url) else { return nil }
    #if canImport(UIKit)
    guard let image = UIImage(data: data) else { return nil }
    return Image(uiImage: image)
    #elseif canImport(AppKit)
    guard let image = NSImage(data: data) else { return nil }
    return Image(nsImage: image)
    #else
    return nil
    #endif
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

/// Everything the demo needs to say at launch, in one place, so both app entry
/// points stay to the few lines that are genuinely per-platform.
@MainActor
enum DemoLaunch {
    static func start(server: StubServer, platform: String) {
        Self.server = server
        do {
            try server.start()
            print("LOUPE-DEMO stub server on port \(server.port)")
        } catch {
            // Never swallowed. A demo whose server did not start looks exactly like
            // a demo whose network capture is broken, and that is the one claim the
            // whole thing exists to show.
            print("LOUPE-DEMO stub server failed: \(error)")
        }

        let app = AppInfo(name: "LoupeDemo",
                          version: "0.1.0",
                          commitSHA: gitSHA(),
                          platform: platform,
                          environment: "staging")
        // Keep the folder, and deliver to Linear once somebody has configured it.
        // Not configured is not a failure: annotating works from the first launch,
        // and delivery switches itself on when the credential exists.
        let local = queuedTransport(server: server, appName: app.name)
            ?? FileTransport(directory: FileTransport.defaultDirectory(appName: app.name))
        Loupe.start(app: app, transport: LinearDelivery(keeping: local))

        // Puts the settings panel behind the tray's gear. Everything Linear in this
        // demo is these two lines.
        LoupeLinear.enable()
        Seed.installIfNeeded(app: app, into: FileTransport.defaultDirectory(appName: app.name))
        LogRecorder.shared.info("stub server on \(server.port)", subsystem: "demo")
    }

    /// The transport for a run that is testing the offline queue.
    ///
    /// `endpoint=dead` points at a port nothing listens on, so every send fails and
    /// the bundle stays on disk. `endpoint=stub` points at the demo's own intake
    /// route. Run one, kill the app, run the other: that is the whole offline story,
    /// and it is the half that cannot be checked without a real process boundary.
    /// Absent the argument, the demo writes files like it always has.
    private(set) static var queue: QueuedTransport?
    /// So a scene can read what the stub actually received.
    private(set) static var server: StubServer?

    private static func queuedTransport(server: StubServer, appName: String) -> Transport? {
        let arguments = ProcessInfo.processInfo.arguments
        guard let raw = arguments.first(where: { $0.hasPrefix("endpoint=") }) else { return nil }

        let endpoint = String(raw.dropFirst("endpoint=".count)) == "stub"
            ? server.baseURL.appendingPathComponent("loupe/intake")
            : URL(string: "http://127.0.0.1:1/nothing-is-listening")!

        let directory = FileTransport.defaultDirectory(appName: appName)
            .appendingPathComponent("queue")
        let queue = QueuedTransport(wrapping: HTTPTransport(endpoint: endpoint),
                                    directory: directory)
        Self.queue = queue
        print("LOUPE-DEMO queue at \(directory.path), endpoint \(endpoint)")
        return queue
    }

    /// The single most useful field in a bundle: it is how an agent checks out the
    /// code that produced the screenshot. Only reachable on a Mac, where the demo
    /// runs from its own checkout; on a device it is baked in at build time or absent.
    private static func gitSHA() -> String? {
        #if os(macOS)
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
        #else
        return Bundle.main.infoDictionary?["GitSHA"] as? String
        #endif
    }
}
