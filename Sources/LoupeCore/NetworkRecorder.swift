import Foundation

/// A ring buffer of recent requests, kept from app start.
///
/// This is the linkage that makes an annotation useful: it pins which endpoints the
/// screen actually called, instead of leaving the agent to guess from static code.
/// Only the last `capacity` events are kept, so memory stays flat in a long session.
public final class NetworkRecorder: @unchecked Sendable {
    public static let shared = NetworkRecorder(capacity: 200)

    private let capacity: Int
    private var events: [NetworkEvent] = []
    private let lock = NSLock()

    public init(capacity: Int) {
        self.capacity = capacity
    }

    public func record(_ event: NetworkEvent) {
        lock.lock(); defer { lock.unlock() }
        events.append(event)
        if events.count > capacity {
            events.removeFirst(events.count - capacity)
        }
    }

    /// The events the agent should see for one pick: everything in the last
    /// `window` seconds, newest last. A short window keeps unrelated background
    /// polling out of the ticket.
    public func recent(within window: TimeInterval = 30, now: Date = Date()) -> [NetworkEvent] {
        lock.lock(); defer { lock.unlock() }
        let cutoff = now.addingTimeInterval(-window)
        return events.filter { $0.at >= cutoff }
    }

    public func removeAll() {
        lock.lock(); defer { lock.unlock() }
        events.removeAll()
    }

    /// Start recording every request made through `URLSession.shared` and any
    /// session built from `URLSessionConfiguration.default`.
    public static func install() {
        URLProtocol.registerClass(LoupeURLProtocol.self)
    }

    public static func uninstall() {
        URLProtocol.unregisterClass(LoupeURLProtocol.self)
    }
}

/// Records a request, then lets it proceed untouched.
///
/// `handledKey` breaks the recursion: the request we re-issue carries the marker,
/// so `canInit` declines it and the real network stack handles it.
final class LoupeURLProtocol: URLProtocol, @unchecked Sendable {
    private static let handledKey = "LoupeHandled"
    private var proxyTask: URLSessionDataTask?
    private var startedAt = Date()

    override class func canInit(with request: URLRequest) -> Bool {
        URLProtocol.property(forKey: handledKey, in: request) == nil
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        startedAt = Date()
        guard let marked = (request as NSURLRequest).mutableCopy() as? NSMutableURLRequest else {
            client?.urlProtocol(self, didFailWithError: LoupeError.transportFailed("bad request"))
            return
        }
        URLProtocol.setProperty(true, forKey: Self.handledKey, in: marked)

        proxyTask = URLSession.shared.dataTask(with: marked as URLRequest) { [weak self] data, response, error in
            guard let self else { return }
            self.log(response: response)

            if let error {
                self.client?.urlProtocol(self, didFailWithError: error)
                return
            }
            if let response {
                self.client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            }
            if let data {
                self.client?.urlProtocol(self, didLoad: data)
            }
            self.client?.urlProtocolDidFinishLoading(self)
        }
        proxyTask?.resume()
    }

    override func stopLoading() {
        proxyTask?.cancel()
    }

    private func log(response: URLResponse?) {
        NetworkRecorder.shared.record(
            NetworkEvent(
                method: request.httpMethod ?? "GET",
                url: request.url?.absoluteString ?? "",
                statusCode: (response as? HTTPURLResponse)?.statusCode,
                durationMs: Int(Date().timeIntervalSince(startedAt) * 1000),
                at: startedAt
            )
        )
    }
}
