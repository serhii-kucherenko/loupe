import Foundation

/// What kind of note this is. Triage uses it as a hint, not as the final word.
public enum AnnotationTag: String, Codable, Sendable, CaseIterable {
    case bug, idea, polish, question
}

/// Where the annotation points. Everything here is best-effort: the crop plus the
/// trace carry the meaning, so a missing field degrades quality, never correctness.
public struct ElementRef: Codable, Sendable, Equatable {
    /// Accessibility identifier, when the app sets one.
    public var accessibilityID: String?
    /// Visible label or title, useful for the agent to locate the view in source.
    public var label: String?
    /// The view/class name as reported by the runtime, e.g. `SearchField`.
    public var className: String?
    /// Optional source stamp when the app opted into `.annotatable()`.
    public var sourceFile: String?
    public var sourceLine: Int?
    /// On-screen bounds, in window points, used to crop the screenshot.
    public var bounds: Rect

    public init(
        accessibilityID: String? = nil,
        label: String? = nil,
        className: String? = nil,
        sourceFile: String? = nil,
        sourceLine: Int? = nil,
        bounds: Rect
    ) {
        self.accessibilityID = accessibilityID
        self.label = label
        self.className = className
        self.sourceFile = sourceFile
        self.sourceLine = sourceLine
        self.bounds = bounds
    }
}

/// Platform-free rectangle so LoupeCore stays testable without UIKit or AppKit.
public struct Rect: Codable, Sendable, Equatable {
    public var x: Double, y: Double, width: Double, height: Double
    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x; self.y = y; self.width = width; self.height = height
    }
}

/// One request the app made, captured by `NetworkRecorder`.
/// This is the linkage that ties a UI element to backend code.
public struct NetworkEvent: Codable, Sendable, Equatable {
    public var method: String
    public var url: String
    public var statusCode: Int?
    public var durationMs: Int
    public var at: Date

    public init(method: String, url: String, statusCode: Int?, durationMs: Int, at: Date) {
        self.method = method; self.url = url
        self.statusCode = statusCode; self.durationMs = durationMs; self.at = at
    }
}

/// One pick plus one comment, with its context already attached.
public struct Annotation: Codable, Sendable, Identifiable, Equatable {
    public var id: UUID
    public var comment: String
    public var tag: AnnotationTag?
    public var element: ElementRef
    /// PNG of the element, cropped to `element.bounds`. The agent reads this.
    public var screenshotPNG: Data?
    /// Requests that fired shortly before the pick.
    public var trace: [NetworkEvent]
    /// Log lines the host app produced shortly before the pick. Errors here are
    /// often the real content of the ticket.
    public var logs: [LogEvent]
    /// Where in the app this happened: route, screen name, tab.
    public var screen: String?
    public var capturedAt: Date

    public init(
        id: UUID = UUID(),
        comment: String,
        tag: AnnotationTag? = nil,
        element: ElementRef,
        screenshotPNG: Data? = nil,
        trace: [NetworkEvent] = [],
        logs: [LogEvent] = [],
        screen: String? = nil,
        capturedAt: Date = Date()
    ) {
        self.id = id; self.comment = comment; self.tag = tag
        self.element = element; self.screenshotPNG = screenshotPNG
        self.trace = trace; self.logs = logs
        self.screen = screen; self.capturedAt = capturedAt
    }

    /// Hand-written so that a bundle produced by an older build still decodes.
    /// The format contract is that adding a field is safe; synthesised `Codable`
    /// would break that by demanding every key.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        comment = try c.decode(String.self, forKey: .comment)
        tag = try c.decodeIfPresent(AnnotationTag.self, forKey: .tag)
        element = try c.decode(ElementRef.self, forKey: .element)
        screenshotPNG = try c.decodeIfPresent(Data.self, forKey: .screenshotPNG)
        trace = try c.decodeIfPresent([NetworkEvent].self, forKey: .trace) ?? []
        logs = try c.decodeIfPresent([LogEvent].self, forKey: .logs) ?? []
        screen = try c.decodeIfPresent(String.self, forKey: .screen)
        capturedAt = try c.decode(Date.self, forKey: .capturedAt)
    }
}

/// What one `Send` produces: the whole tray, plus the build it came from.
/// Triage reads this and decides the ticket mapping.
public struct AnnotationBundle: Codable, Sendable {
    public var sessionID: UUID
    public var app: AppInfo
    public var annotations: [Annotation]
    public var sentAt: Date

    public init(sessionID: UUID, app: AppInfo, annotations: [Annotation], sentAt: Date = Date()) {
        self.sessionID = sessionID; self.app = app
        self.annotations = annotations; self.sentAt = sentAt
    }
}

/// Which build produced this bundle, so the agent checks out the right code.
public struct AppInfo: Codable, Sendable, Equatable {
    public var name: String
    public var version: String?
    public var commitSHA: String?
    public var platform: String
    public var environment: String

    public init(
        name: String,
        version: String? = nil,
        commitSHA: String? = nil,
        platform: String,
        environment: String = "staging"
    ) {
        self.name = name; self.version = version; self.commitSHA = commitSHA
        self.platform = platform; self.environment = environment
    }
}
