import Foundation

/// What kind of note this is. Triage uses it as a hint, not as the final word.
public enum AnnotationTag: String, Codable, Sendable, CaseIterable {
    case bug, idea, polish, question
}

/// Where the annotation points. Everything here is best-effort: the crop plus the
/// trace carry the meaning, so a missing field degrades quality, never correctness.
/// Whether the annotation is about a thing on screen or an area of it.
///
/// A region is not a failed view pick. Plenty of real feedback is about something
/// no view corresponds to: two controls misaligned with each other, the padding
/// around a group, the gap between two rows. Those have bounds and nothing else,
/// and saying so plainly is more useful than naming whichever ancestor happened to
/// be underneath.
public enum ElementKind: String, Codable, Sendable, Equatable {
    case view
    case region
    /// A shape somebody drew. Says "these things, and not the things between them" -
    /// the one thing a rectangle cannot say, because a box around two controls at
    /// opposite corners of a card includes everything in between and means nothing.
    case path
}

public struct ElementRef: Codable, Sendable, Equatable {
    /// Defaults to `.view`, so a bundle written before this field existed still
    /// means what it meant.
    public var kind: ElementKind
    /// Accessibility identifier, when the app sets one.
    public var accessibilityID: String?
    /// Visible label or title, useful for the agent to locate the view in source.
    public var label: String?
    /// The view/class name as reported by the runtime, e.g. `SearchField`.
    public var className: String?
    /// A CSS selector that finds the element again. Web and Electron only:
    /// Apple platforms have no equivalent and leave it nil.
    public var selector: String?
    /// Optional source stamp when the app opted into `.annotatable()`.
    public var sourceFile: String?
    public var sourceLine: Int?
    /// On-screen bounds, in window points, used to crop the screenshot.
    ///
    /// Required for every kind, including `.path`, where it is the drawn shape's
    /// bounding box. That is what keeps a consumer which has never heard of a path
    /// working: it gets the rectangle it would have got from a drag. A missing field
    /// degrades quality, never correctness.
    public var bounds: Rect
    /// The drawn shape itself, in window points, closed implicitly. `.path` only.
    ///
    /// A flat point list rather than SVG path data: both SDKs already produce points,
    /// neither needs curves, and anything can render it. Simplified before it is
    /// stored, so a slow drag does not ship nine hundred points that sit on top of
    /// each other.
    public var path: [Point]?

    public init(
        kind: ElementKind = .view,
        accessibilityID: String? = nil,
        label: String? = nil,
        className: String? = nil,
        selector: String? = nil,
        sourceFile: String? = nil,
        sourceLine: Int? = nil,
        bounds: Rect,
        path: [Point]? = nil
    ) {
        self.kind = kind
        self.accessibilityID = accessibilityID
        self.label = label
        self.className = className
        self.selector = selector
        self.sourceFile = sourceFile
        self.sourceLine = sourceLine
        self.bounds = bounds
        self.path = path
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        kind = try c.decodeIfPresent(ElementKind.self, forKey: .kind) ?? .view
        accessibilityID = try c.decodeIfPresent(String.self, forKey: .accessibilityID)
        label = try c.decodeIfPresent(String.self, forKey: .label)
        className = try c.decodeIfPresent(String.self, forKey: .className)
        selector = try c.decodeIfPresent(String.self, forKey: .selector)
        sourceFile = try c.decodeIfPresent(String.self, forKey: .sourceFile)
        sourceLine = try c.decodeIfPresent(Int.self, forKey: .sourceLine)
        bounds = try c.decode(Rect.self, forKey: .bounds)
        path = try c.decodeIfPresent([Point].self, forKey: .path)
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
    /// PNG of the whole window with the element outlined. Answers "where is it and
    /// what is around it", which the tight crop deliberately does not.
    public var contextScreenshotPNG: Data?
    /// Requests that fired shortly before the pick.
    public var trace: [NetworkEvent]
    /// Log lines the host app produced shortly before the pick. Errors here are
    /// often the real content of the ticket.
    public var logs: [LogEvent]
    /// Where in the app this happened: route, screen name, tab.
    public var screen: String?
    /// The window or viewport at capture time. `element.bounds` is expressed
    /// inside this, so without it a phone and a desktop are indistinguishable.
    public var viewport: Rect?
    public var capturedAt: Date

    public init(
        id: UUID = UUID(),
        comment: String,
        tag: AnnotationTag? = nil,
        element: ElementRef,
        screenshotPNG: Data? = nil,
        contextScreenshotPNG: Data? = nil,
        trace: [NetworkEvent] = [],
        logs: [LogEvent] = [],
        screen: String? = nil,
        viewport: Rect? = nil,
        capturedAt: Date = Date()
    ) {
        self.id = id; self.comment = comment; self.tag = tag
        self.element = element; self.screenshotPNG = screenshotPNG
        self.contextScreenshotPNG = contextScreenshotPNG
        self.trace = trace; self.logs = logs
        self.screen = screen; self.viewport = viewport
        self.capturedAt = capturedAt
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
        contextScreenshotPNG = try c.decodeIfPresent(Data.self, forKey: .contextScreenshotPNG)
        trace = try c.decodeIfPresent([NetworkEvent].self, forKey: .trace) ?? []
        logs = try c.decodeIfPresent([LogEvent].self, forKey: .logs) ?? []
        screen = try c.decodeIfPresent(String.self, forKey: .screen)
        viewport = try c.decodeIfPresent(Rect.self, forKey: .viewport)
        capturedAt = try c.decode(Date.self, forKey: .capturedAt)
    }
}

/// What one `Send` produces: the whole tray, plus the build it came from.
/// Triage reads this and decides the ticket mapping.
public struct AnnotationBundle: Codable, Sendable {
    /// The current format. Bumped only by a breaking change; see
    /// `docs/bundle-format.md`. Adding a field never bumps it.
    public static let currentFormatVersion = 1

    public var formatVersion: Int
    public var sessionID: UUID
    public var app: AppInfo
    public var annotations: [Annotation]
    public var sentAt: Date

    public init(
        sessionID: UUID,
        app: AppInfo,
        annotations: [Annotation],
        sentAt: Date = Date(),
        formatVersion: Int = AnnotationBundle.currentFormatVersion
    ) {
        self.formatVersion = formatVersion
        self.sessionID = sessionID; self.app = app
        self.annotations = annotations; self.sentAt = sentAt
    }

    /// A bundle written before the field existed is version 1 by definition.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        formatVersion = try c.decodeIfPresent(Int.self, forKey: .formatVersion) ?? 1
        sessionID = try c.decode(UUID.self, forKey: .sessionID)
        app = try c.decode(AppInfo.self, forKey: .app)
        annotations = try c.decode([Annotation].self, forKey: .annotations)
        sentAt = try c.decode(Date.self, forKey: .sentAt)
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

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decode(String.self, forKey: .name)
        version = try c.decodeIfPresent(String.self, forKey: .version)
        commitSHA = try c.decodeIfPresent(String.self, forKey: .commitSHA)
        platform = try c.decode(String.self, forKey: .platform)
        environment = try c.decodeIfPresent(String.self, forKey: .environment) ?? "staging"
    }
}
