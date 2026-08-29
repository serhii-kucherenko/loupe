import Foundation
import Network

/// A local server that answers the way Linear's API does, and remembers what arrived.
///
/// It exists so the send can be driven over a real socket by a real `URLSession`.
/// Every other test in this target injects `fetch` and therefore never encodes a
/// body, never sets a header and never performs the upload PUT - which are precisely
/// the parts that fail against a real API.
///
/// Two bugs from the demo's own stub server are designed out here rather than
/// rediscovered: the port is read only after `.ready`, because it is nil before that
/// and binding to 0 silently yields port 0; and the whole body is read using
/// `Content-Length` rather than answering after the first chunk, because a bundle
/// carrying screenshots does not arrive in one.
final class FakeLinearServer: @unchecked Sendable {

    struct Upload {
        let method: String
        let headers: [String: String]
        let body: Data
    }

    private let listener: NWListener
    private let queue = DispatchQueue(label: "dev.loupe.fake-linear")
    private let lock = NSLock()

    private var _created: [[String: Any]] = []
    private var _uploads: [Upload] = []
    private var _authorizations: [String] = []
    private var _assetURLs: [String] = []
    private var _searches = 0
    private var _labels: [[String: String]] = []
    private var _rejectEverything = false
    private var port: UInt16 = 0

    /// Issues `issueCreate` was asked to make, as the input dictionaries.
    var created: [[String: Any]] { lock.sync { _created } }
    var uploads: [Upload] { lock.sync { _uploads } }
    var authorizations: [String] { lock.sync { _authorizations } }
    var assetURLs: [String] { lock.sync { _assetURLs } }
    var searches: Int { lock.sync { _searches } }

    /// The workspace's labels, as `id`/`name` pairs. Team-scoped labels are not
    /// modelled here: the choosing rule is proved by its own unit tests, and this
    /// file exists to prove the wire, not the rule.
    var labels: [[String: String]] {
        get { lock.sync { _labels } }
        set { lock.sync { _labels = newValue } }
    }

    /// Answer everything with 401, the way a wrong key would.
    var rejectEverything: Bool {
        get { lock.sync { _rejectEverything } }
        set { lock.sync { _rejectEverything = newValue } }
    }

    var graphQL: URL { URL(string: "http://127.0.0.1:\(port)/graphql")! }

    init() throws {
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        listener = try NWListener(using: parameters, on: .any)
    }

    func reset() {
        lock.sync {
            _created = []
            _uploads = []
            _authorizations = []
            _assetURLs = []
            _searches = 0
        }
    }

    func start() throws {
        let ready = DispatchSemaphore(value: 0)
        listener.stateUpdateHandler = { [weak self] state in
            // Only once it is ready does `listener.port` mean anything. Reading it
            // any earlier hands back nothing and every request then goes to port 0,
            // which looks exactly like the server being broken.
            if case .ready = state, let self {
                self.port = self.listener.port?.rawValue ?? 0
                ready.signal()
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            connection.start(queue: self?.queue ?? .main)
            self?.read(connection)
        }
        listener.start(queue: queue)
        guard ready.wait(timeout: .now() + 5) == .success, port != 0 else {
            throw LinearFakeError.didNotStart
        }
    }

    func stop() { listener.cancel() }

    // MARK: - HTTP, the little of it that is needed

    private func read(_ connection: NWConnection, buffer: Data = Data()) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) {
            [weak self] chunk, _, isComplete, error in
            guard let self, error == nil else { connection.cancel(); return }
            var buffer = buffer
            if let chunk { buffer.append(chunk) }

            guard let headerEnd = buffer.range(of: Data("\r\n\r\n".utf8)) else {
                if isComplete { connection.cancel() } else { self.read(connection, buffer: buffer) }
                return
            }

            let head = String(decoding: buffer[..<headerEnd.lowerBound], as: UTF8.self)
            let body = buffer[headerEnd.upperBound...]
            let expected = Self.contentLength(in: head) ?? 0

            // The whole body, not the first chunk. A bundle with two screenshots in
            // it does not arrive in one, and answering early truncated the upload.
            guard body.count >= expected else {
                if isComplete { connection.cancel() } else { self.read(connection, buffer: buffer) }
                return
            }

            self.respond(to: head, body: Data(body.prefix(expected)), on: connection)
        }
    }

    private static func contentLength(in head: String) -> Int? {
        for line in head.split(separator: "\r\n") where line.lowercased().hasPrefix("content-length:") {
            return Int(line.split(separator: ":")[1].trimmingCharacters(in: .whitespaces))
        }
        return nil
    }

    private static func headers(in head: String) -> [String: String] {
        var found: [String: String] = [:]
        for line in head.split(separator: "\r\n").dropFirst() {
            let parts = line.split(separator: ":", maxSplits: 1)
            guard parts.count == 2 else { continue }
            found[String(parts[0])] = parts[1].trimmingCharacters(in: .whitespaces)
        }
        return found
    }

    private func respond(to head: String, body: Data, on connection: NWConnection) {
        let requestLine = head.split(separator: "\r\n").first.map(String.init) ?? ""
        let method = requestLine.split(separator: " ").first.map(String.init) ?? ""
        let path = requestLine.split(separator: " ").dropFirst().first.map(String.init) ?? ""
        let headers = Self.headers(in: head)

        if let authorization = headers["Authorization"] {
            lock.sync { _authorizations.append(authorization) }
        }

        if rejectEverything {
            return send(status: 401, json: #"{"error":"unauthorized"}"#, on: connection)
        }

        // The upload half: a PUT of the bytes to wherever `fileUpload` pointed.
        if method == "PUT" {
            lock.sync {
                _uploads.append(Upload(method: method, headers: headers, body: body))
            }
            return send(status: 200, json: "", on: connection)
        }

        guard path.hasSuffix("/graphql"),
              let query = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any],
              let text = query["query"] as? String else {
            return send(status: 404, json: #"{"error":"not found"}"#, on: connection)
        }

        let variables = query["variables"] as? [String: Any] ?? [:]
        send(status: 200, json: answer(to: text, variables: variables), on: connection)
    }

    private func answer(to query: String, variables: [String: Any]) -> String {
        if query.contains("fileUpload") {
            let id = UUID().uuidString
            let asset = "http://127.0.0.1:\(port)/assets/\(id).png"
            lock.sync { _assetURLs.append(asset) }
            return """
            {"data":{"fileUpload":{"success":true,"uploadFile":{\
            "uploadUrl":"http://127.0.0.1:\(port)/upload/\(id)",\
            "assetUrl":"\(asset)",\
            "headers":[{"key":"x-linear-test","value":"echoed"}]}}}}
            """
        }

        if query.contains("issueLabels") {
            let nodes = labels
                .map { #"{"id":"\#($0["id"] ?? "")","name":"\#($0["name"] ?? "")"}"# }
                .joined(separator: ",")
            return #"{"data":{"issueLabels":{"nodes":[\#(nodes)]}}}"#
        }

        if query.contains("issueCreate") {
            let input = variables["input"] as? [String: Any] ?? [:]
            lock.sync { _created.append(input) }
            return #"{"data":{"issueCreate":{"success":true,"issue":{"id":"issue-1","identifier":"SER-1","url":"http://example.invalid/SER-1"}}}}"#
        }

        // Anything else is the marker search that runs before a create. Answering
        // with whatever has already been filed is what makes a repeat send a no-op.
        //
        // The marker arrives as a *variable*, not inside the query text - the query
        // is a constant with `$marker` in it. Reading it from the text found nothing,
        // every search came back empty, and the second send filed everything again:
        // a stub that lies in exactly the shape the code under test is defending
        // against.
        lock.sync { _searches += 1 }
        let marker = variables["marker"] as? String ?? "\u{0}"
        let matches = lock.sync { _created }.contains { input in
            (input["description"] as? String)?.contains(marker) ?? false
        }
        let nodes = matches
            ? #"{"id":"issue-1","identifier":"SER-1","url":"http://example.invalid/SER-1"}"#
            : ""
        return #"{"data":{"issues":{"nodes":[\#(nodes)]}}}"#
    }

    private func send(status: Int, json: String, on connection: NWConnection) {
        let body = Data(json.utf8)
        let head = """
        HTTP/1.1 \(status) OK\r
        Content-Type: application/json\r
        Content-Length: \(body.count)\r
        Connection: close\r
        \r

        """
        connection.send(content: Data(head.utf8) + body,
                        completion: .contentProcessed { _ in connection.cancel() })
    }
}

enum LinearFakeError: Error { case didNotStart }

private extension NSLock {
    /// Named `sync` rather than `withLock`, which Foundation also defines - two
    /// overloads that differ only in Sendable annotations is a coin toss.
    func sync<T>(_ body: () -> T) -> T {
        lock(); defer { unlock() }
        return body()
    }
}
