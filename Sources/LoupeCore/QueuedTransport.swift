import Foundation

/// Persist-then-send wrapper around any other `Transport`.
///
/// Without it, a failed send survives only while the app is alive: the tray keeps
/// the annotations in memory and a kill loses them. The realistic case on a phone is
/// annotating in a tunnel, backgrounding the app, and coming back later.
///
/// So every bundle hits disk *before* the inner transport is tried. A success
/// deletes the file. A failure leaves it, and `drain` ships the backlog later,
/// oldest first. Nothing is held in memory, so a fresh process over the same folder
/// finds whatever the previous one could not deliver.
public final class QueuedTransport: Transport, @unchecked Sendable {
    private let inner: Transport
    public let directory: URL
    private let lock = NSLock()

    public init(wrapping inner: Transport, directory: URL) {
        self.inner = inner
        self.directory = directory
    }

    /// How many bundles are waiting. Read from disk, never from memory.
    public var pendingCount: Int { pendingFiles().count }

    public func send(_ bundle: AnnotationBundle) async throws {
        let file = try persist(bundle)
        do {
            try await inner.send(bundle)
            remove(file)
        } catch {
            // The file stays. `drain` will pick it up.
            throw error
        }
    }

    /// Ship everything waiting, oldest first.
    ///
    /// It stops at the first failure and rethrows, rather than skipping ahead: a
    /// backlog delivered out of order would reorder someone's annotations, and a
    /// network that just failed will almost certainly fail again on the next one.
    public func drain() async throws {
        for file in pendingFiles() {
            let bundle = try decode(file)
            try await inner.send(bundle)
            remove(file)
        }
    }

    /// Same as `drain`, but keeps trying while the network is still coming back.
    ///
    /// The delay doubles each time. The caller decides when to start this - app
    /// foreground, a reachability change - because only the caller knows whether
    /// waiting is worth it.
    public func drain(attempts: Int, initialDelay: TimeInterval = 1) async throws {
        var delay = initialDelay
        for attempt in 1...max(1, attempts) {
            do {
                try await drain()
                return
            } catch {
                guard attempt < attempts else { throw error }
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                delay *= 2
            }
        }
    }

    // MARK: - Disk

    /// Fixed-width seconds keep the names sortable as plain text, and the session id
    /// keeps two bundles stamped in the same microsecond from colliding.
    private func persist(_ bundle: AnnotationBundle) throws -> URL {
        lock.lock(); defer { lock.unlock() }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let stamp = String(format: "%020.6f", bundle.sentAt.timeIntervalSince1970)
        let file = directory.appendingPathComponent("\(stamp)-\(bundle.sessionID.uuidString).json")

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(bundle).write(to: file)
        return file
    }

    private func decode(_ file: URL) throws -> AnnotationBundle {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(AnnotationBundle.self, from: Data(contentsOf: file))
    }

    private func pendingFiles() -> [URL] {
        lock.lock(); defer { lock.unlock() }
        let found = (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil)) ?? []
        return found
            .filter { $0.pathExtension == "json" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    /// Drops a bundle that has been sent.
    ///
    /// A delete that fails is not cosmetic: the bundle stays in the queue, so it is
    /// sent again on the next drain, and `pendingCount` never comes down - the tray
    /// says "waiting to send" for ever about something that already arrived. Linear
    /// survives that because a repeat send is a no-op, but an ordinary `HTTPTransport`
    /// would receive it again every time.
    ///
    /// Still not thrown: the send genuinely succeeded, and failing it afterwards
    /// would be a worse lie than the one being fixed. It is loud in a debug build,
    /// which is all this SDK ever ships in.
    private func remove(_ file: URL) {
        lock.lock(); defer { lock.unlock() }
        do {
            try FileManager.default.removeItem(at: file)
        } catch {
            assertionFailure("Loupe sent \(file.lastPathComponent) but could not "
                             + "remove it from the queue, so it will be sent again: "
                             + "\(error.localizedDescription)")
        }
    }
}
