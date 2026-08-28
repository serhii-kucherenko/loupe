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

    /// `~/.loupe/<app-name>/`
    public static func defaultDirectory(appName: String) -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".loupe", isDirectory: true)
            .appendingPathComponent(appName, isDirectory: true)
    }

    public func send(_ bundle: AnnotationBundle) async throws {
        let folder = directory.appendingPathComponent(bundle.sessionID.uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        // Screenshots go beside the JSON rather than inside it, so the JSON stays
        // readable and an agent can open the images directly.
        var stripped = bundle
        for i in stripped.annotations.indices {
            guard let png = stripped.annotations[i].screenshotPNG else { continue }
            let name = "\(stripped.annotations[i].id.uuidString).png"
            try png.write(to: folder.appendingPathComponent(name))
            stripped.annotations[i].screenshotPNG = nil
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
