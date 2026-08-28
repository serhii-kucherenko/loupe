#if os(macOS)
import Foundation
import Network

/// A local HTTP server, about sixty lines of it, so the demo's network trace is
/// real rather than mocked.
///
/// This matters more than it looks. The whole claim Loupe makes is that it ties a UI
/// element to the backend call behind it. A demo that faked the trace would be
/// demonstrating the claim rather than testing it, and the first real app would find
/// out that `URLProtocol` interception did not work.
final class StubServer: @unchecked Sendable {
    private var listener: NWListener?
    private(set) var port: UInt16 = 0

    /// Seeded routes. `/v2/search` with an empty query is deliberately broken:
    /// the demo needs something genuinely wrong to annotate.
    private func response(for path: String, method: String) -> (status: Int, body: String) {
        switch (method, path) {
        case ("GET", let p) where p.hasPrefix("/v2/search"):
            // Parsed properly rather than split on "=": "/v2/search?q=" splits into
            // one piece, so the naive version read the path back as the query and
            // the seeded failure never fired.
            let query = URLComponents(string: "http://stub\(p)")?
                .queryItems?.first(where: { $0.name == "q" })?.value ?? ""
            if query.isEmpty {
                return (500, #"{"error":"query must not be empty"}"#)
            }
            return (200, Seed.searchJSON(matching: query))
        case ("GET", "/v2/cart"):
            return (200, #"{"items":[]}"#)
        case ("POST", "/v2/orders"):
            return (500, #"{"error":"payment provider timed out"}"#)
        default:
            return (404, #"{"error":"no such route"}"#)
        }
    }

    func start() throws {
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        let listener = try NWListener(using: parameters, on: .any)

        listener.newConnectionHandler = { [weak self] connection in
            connection.start(queue: .global())
            self?.serve(connection)
        }
        listener.start(queue: .global())
        self.listener = listener

        // Wait for the kernel to hand back a port before anyone builds a URL from it.
        let deadline = Date().addingTimeInterval(2)
        while listener.port?.rawValue == nil, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.01)
        }
        port = listener.port?.rawValue ?? 0
    }

    func stop() {
        listener?.cancel()
        listener = nil
    }

    var baseURL: URL { URL(string: "http://127.0.0.1:\(port)")! }

    private func serve(_ connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] data, _, _, _ in
            guard let self, let data, let request = String(data: data, encoding: .utf8) else {
                connection.cancel(); return
            }
            let parts = request.split(separator: " ", maxSplits: 2)
            let method = parts.first.map(String.init) ?? "GET"
            let path = parts.count > 1 ? String(parts[1]) : "/"

            let result = self.response(for: path, method: method)
            let body = Data(result.body.utf8)
            let head = """
            HTTP/1.1 \(result.status) \(result.status == 200 ? "OK" : "Error")\r
            Content-Type: application/json\r
            Content-Length: \(body.count)\r
            Connection: close\r
            \r
            
            """
            connection.send(content: Data(head.utf8) + body,
                            completion: .contentProcessed { _ in connection.cancel() })
        }
    }
}
#endif
