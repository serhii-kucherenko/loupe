import Foundation

/// Where a sent bundle goes. Triage sits on the other side of this.
public protocol Transport: Sendable {
    func send(_ bundle: AnnotationBundle) async throws
}

/// Writes the bundle to a folder as JSON plus one PNG per annotation.
///
/// This is the default on purpose: the tool is useful on day one with no server to
/// run, and an agent with filesystem access can read the folder directly.
public struct FileTransport: Transport {
    public let directory: URL

    public init(directory: URL) {
        self.directory = directory
    }

    /// Where bundles land when you do not name a directory.
    ///
    /// On macOS this is `~/.loupe/<app-name>/`, which an agent on the same machine
    /// can read directly. iOS and iPadOS sandbox the app, so there is no home
    /// directory to write to and nothing outside the app could read it anyway:
    /// there, bundles go to Application Support and are really only useful until
    /// they are uploaded. On a device, prefer `HTTPTransport`.
    public static func defaultDirectory(appName: String) -> URL {
        defaultDirectory(appName: appName,
                         environment: ProcessInfo.processInfo.environment)
    }

    /// Whether the process is inside an App Sandbox container.
    ///
    /// The environment is a parameter so this is testable: the alternative is a rule
    /// nothing can exercise until someone ships a sandboxed build and finds out.
    static func isSandboxed(_ environment: [String: String]) -> Bool {
        environment["APP_SANDBOX_CONTAINER_ID"] != nil
    }

    static func defaultDirectory(appName: String, environment: [String: String]) -> URL {
        // Catalyst is `os(iOS)` plus `targetEnvironment(macCatalyst)`, so a plain
        // `os(macOS)` test is false there and a Mac app built with Catalyst was
        // quietly writing into its container while the docs told the agent to look
        // in `~/.loupe`. The agent found nothing and had no way to know why.
        //
        // Sandboxing is the other half, and it is why this is not a one-word change:
        // a sandboxed app cannot write to `~/.loupe` at all. That applies to a
        // sandboxed macOS app too, which had the same latent bug.
        #if os(macOS) || targetEnvironment(macCatalyst)
        if !isSandboxed(environment) {
            // `NSHomeDirectory()` rather than `homeDirectoryForCurrentUser`, which is
            // unavailable under Catalyst. Outside a sandbox the two agree.
            return URL(fileURLWithPath: NSHomeDirectory())
                .appendingPathComponent(".loupe", isDirectory: true)
                .appendingPathComponent(appName, isDirectory: true)
        }
        #endif

        let base = (try? FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )) ?? URL(fileURLWithPath: NSTemporaryDirectory())

        return base
            .appendingPathComponent("Loupe", isDirectory: true)
            .appendingPathComponent(appName, isDirectory: true)
    }

    public func send(_ bundle: AnnotationBundle) async throws {
        let folder = directory.appendingPathComponent(bundle.sessionID.uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        // Screenshots go beside the JSON rather than inside it, so the JSON stays
        // readable and an agent can open the images directly.
        var stripped = bundle
        for i in stripped.annotations.indices {
            let id = stripped.annotations[i].id.uuidString
            if let png = stripped.annotations[i].screenshotPNG {
                try png.write(to: folder.appendingPathComponent("\(id).png"))
                stripped.annotations[i].screenshotPNG = nil
            }
            if let context = stripped.annotations[i].contextScreenshotPNG {
                try context.write(to: folder.appendingPathComponent("\(id)-context.png"))
                stripped.annotations[i].contextScreenshotPNG = nil
            }
        }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(stripped)
        try data.write(to: folder.appendingPathComponent("bundle.json"))
    }
}

/// POSTs the bundle to a triage endpoint.
public struct HTTPTransport: Transport {
    public let endpoint: URL
    public let headers: [String: String]

    public init(endpoint: URL, headers: [String: String] = [:]) {
        self.endpoint = endpoint
        self.headers = headers
    }

    public func send(_ bundle: AnnotationBundle) async throws {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        for (k, v) in headers { request.setValue(v, forHTTPHeaderField: k) }

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        request.httpBody = try encoder.encode(bundle)

        let (_, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? -1
            throw LoupeError.transportFailed("triage returned \(code)")
        }
    }
}
