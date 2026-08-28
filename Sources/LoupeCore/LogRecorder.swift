import Foundation

/// How loud one log line is. Errors are treated specially by `LogRecorder`.
public enum LogLevel: String, Codable, Sendable, CaseIterable {
    case debug, info, warning, error
}

/// One line the host app logged, captured for the bundle.
///
/// Loupe never intercepts `os_log` or `stderr`: that is invasive and fragile.
/// The host calls `LogRecorder.shared.error(...)` from its own logger instead.
public struct LogEvent: Codable, Sendable, Equatable {
    public var level: LogLevel
    public var message: String
    /// Which part of the app produced it, e.g. `net` or `auth`. Free-form.
    public var subsystem: String?
    public var at: Date

    public init(level: LogLevel, message: String, subsystem: String? = nil, at: Date = Date()) {
        self.level = level
        self.message = message
        self.subsystem = subsystem
        self.at = at
    }
}

/// A ring buffer of recent log lines, shaped like `NetworkRecorder`.
///
/// It keeps **two** lanes, and that is the whole point. Errors are the reason a
/// person is annotating at all, so a burst of debug chatter after the failure must
/// never evict the failing line. Each lane is bounded, so memory still stays flat.
public final class LogRecorder: @unchecked Sendable {
    public static let shared = LogRecorder(capacity: 200)

    private let capacity: Int
    private let lock = NSLock()

    /// Insertion order, not wall-clock order. Two lines stamped in the same
    /// millisecond still come back in the order the app produced them.
    private var sequence = 0
    private var general: [(seq: Int, event: LogEvent)] = []
    private var errors: [(seq: Int, event: LogEvent)] = []

    public init(capacity: Int) {
        self.capacity = capacity
    }

    public func record(_ event: LogEvent) {
        lock.lock(); defer { lock.unlock() }
        sequence += 1
        let entry = (seq: sequence, event: event)

        if event.level == .error {
            errors.append(entry)
            trim(&errors)
        } else {
            general.append(entry)
            trim(&general)
        }
    }

    /// The lines the agent should see for one pick: everything in the last
    /// `window` seconds, in the order the app logged them.
    public func recent(within window: TimeInterval = 30, now: Date = Date()) -> [LogEvent] {
        lock.lock(); defer { lock.unlock() }
        let cutoff = now.addingTimeInterval(-window)
        return (general + errors)
            .filter { $0.event.at >= cutoff }
            .sorted { $0.seq < $1.seq }
            .map(\.event)
    }

    public func removeAll() {
        lock.lock(); defer { lock.unlock() }
        general.removeAll()
        errors.removeAll()
    }

    private func trim(_ lane: inout [(seq: Int, event: LogEvent)]) {
        if lane.count > capacity {
            lane.removeFirst(lane.count - capacity)
        }
    }

    // MARK: - Convenience

    public func debug(_ message: String, subsystem: String? = nil) {
        record(LogEvent(level: .debug, message: message, subsystem: subsystem))
    }

    public func info(_ message: String, subsystem: String? = nil) {
        record(LogEvent(level: .info, message: message, subsystem: subsystem))
    }

    public func warning(_ message: String, subsystem: String? = nil) {
        record(LogEvent(level: .warning, message: message, subsystem: subsystem))
    }

    public func error(_ message: String, subsystem: String? = nil) {
        record(LogEvent(level: .error, message: message, subsystem: subsystem))
    }
}
