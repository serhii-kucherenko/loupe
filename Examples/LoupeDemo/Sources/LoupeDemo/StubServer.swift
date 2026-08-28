import Foundation
import Network

enum StubServerError: Error, CustomStringConvertible {
    case didNotStart
    var description: String { "the stub server never became ready" }
}

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

    /// How many bundles have been POSTed to the intake route.
    ///
    /// Bundles, not annotations: this stub reads one 8KB chunk per request, so a
    /// body carrying screenshots is truncated and cannot be decoded. The count that
    /// matters for the offline queue is anyway "arrived, and arrived once".
    private let counter = NSLock()
    private var received = 0
    var intakeCount: Int { counter.withLock { received } }

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
        case ("POST", "/loupe/intake"):
            counter.withLock { received += 1 }
            return (200, #"{"ok":true}"#)
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
        // Wait for the listener to say it is ready before anyone builds a URL from
        // its port. Polling `listener.port` instead looks equivalent and is not: on
        // iOS it stayed nil for the whole timeout, the demo came up on port 0, and
        // every request in the captured trace was a connection failure - which looks
        // exactly like Loupe's network capture being broken. Found on an iPad.
        let ready = DispatchSemaphore(value: 0)
        listener.stateUpdateHandler = { state in
            switch state {
            case .ready, .failed, .cancelled: ready.signal()
            default: break
            }
        }

        listener.start(queue: .global())
        self.listener = listener

        _ = ready.wait(timeout: .now() + 5)
        port = listener.port?.rawValue ?? 0
        guard port != 0 else { throw StubServerError.didNotStart }
    }

    func stop() {
        listener?.cancel()
        listener = nil
    }

    var baseURL: URL { URL(string: "http://127.0.0.1:\(port)")! }

    private func serve(_ connection: NWConnection) {
        receive(on: connection, buffer: Data())
    }

    /// Reads the whole request before answering.
    ///
    /// It used to take one 8KB chunk, answer, and close. That is fine for a GET and
    /// wrong for the intake route: a bundle carrying screenshots is hundreds of
    /// kilobytes, so the socket went away while the client was still uploading and
    /// every POST failed with "the network connection was lost". Found by draining
    /// the offline queue on an iPad.
    private func receive(on connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) {
            [weak self] data, _, isComplete, error in
            guard let self else { connection.cancel(); return }

            var buffer = buffer
            if let data { buffer.append(data) }
            let done = isComplete || error != nil

            guard let blank = buffer.range(of: Data("\r\n\r\n".utf8)) else {
                if done { connection.cancel() } else { self.receive(on: connection, buffer: buffer) }
                return
            }

            let header = String(decoding: buffer[..<blank.lowerBound], as: UTF8.self)
            let body = buffer.count - blank.upperBound
            if body < Self.contentLength(in: header), !done {
                self.receive(on: connection, buffer: buffer)
                return
            }
            self.respond(on: connection, to: header)
        }
    }

    private static func contentLength(in header: String) -> Int {
        for line in header.split(separator: "\r\n")
        where line.lowercased().hasPrefix("content-length:") {
            return Int(line.dropFirst("content-length:".count)
                .trimmingCharacters(in: .whitespaces)) ?? 0
        }
        return 0
    }

    private func respond(on connection: NWConnection, to header: String) {
        let parts = header.split(separator: " ", maxSplits: 2)
        let method = parts.first.map(String.init) ?? "GET"
        let path = parts.count > 1 ? String(parts[1]) : "/"

        let result = response(for: path, method: method)
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
