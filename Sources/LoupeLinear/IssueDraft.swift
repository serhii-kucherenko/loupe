import Foundation
import LoupeCore

/// One annotation, as the issue it should become.
///
/// Pure: no network, no dates of its own, no randomness. Everything that makes the
/// body is already in the bundle, so this is the piece worth testing hardest and the
/// piece with the least excuse for being wrong.
public struct IssueDraft: Equatable, Sendable {
    public var title: String
    public var description: String
    public var labelName: String?
    /// The Linear label the tag matched, when the workspace has one. Resolved by
    /// the transport, because only the workspace can answer it.
    public var labelID: String?
    /// The annotation this came from. Written into the body so a retry can find it
    /// again rather than creating a second issue.
    public var annotationID: UUID

    /// The marker a retry searches for. Deliberately ugly and unambiguous: it has to
    /// survive somebody editing the issue around it.
    public static func marker(for id: UUID) -> String { "loupe:\(id.uuidString)" }
}

public extension IssueDraft {

    /// - Parameter assets: asset URLs for this annotation's images, once uploaded.
    ///   Absent is normal rather than exceptional: a region pick on the web has no
    ///   crop at all.
    /// - Parameter labelID: the label the tag matched, or nil when nothing matched.
    ///   nil is the default because most callers - the tests, the docs, anything
    ///   that has not asked Linear yet - genuinely do not know.
    init(annotation: Annotation,
         bundle: AnnotationBundle,
         assets: Assets = Assets(),
         labelID: String? = nil) {
        annotationID = annotation.id
        title = Self.title(from: annotation.comment)
        labelName = annotation.tag?.rawValue
        self.labelID = labelID
        description = Self.body(annotation: annotation, bundle: bundle,
                                assets: assets, matchedALabel: labelID != nil)
    }

    struct Assets: Equatable, Sendable {
        public var crop: String?
        public var context: String?
        public init(crop: String? = nil, context: String? = nil) {
            self.crop = crop
            self.context = context
        }
    }

    /// The first line, because a comment can be a paragraph and a title cannot.
    /// It is the only human-authored field, so it is worth keeping readable.
    private static func title(from comment: String) -> String {
        let firstLine = comment
            .split(separator: "\n", omittingEmptySubsequences: true)
            .first
            .map(String.init)?
            .trimmingCharacters(in: .whitespaces) ?? comment

        guard firstLine.count > 80 else { return firstLine }
        // Cut at a word rather than mid-syllable.
        let clipped = String(firstLine.prefix(80))
        guard let space = clipped.lastIndex(of: " "), space > clipped.startIndex else {
            return clipped + "\u{2026}"
        }
        return String(clipped[..<space]) + "\u{2026}"
    }

    private static func body(annotation: Annotation,
                             bundle: AnnotationBundle,
                             assets: Assets,
                             matchedALabel: Bool) -> String {
        var out: [String] = [annotation.comment, ""]

        // Somebody chose this on the iPad. If the workspace has no label of that
        // name, the choice still has to arrive - as a sentence, since it could not
        // arrive as a label. Dropping it would be the quietest kind of lie.
        if let note = windowNote(annotation: annotation, bundle: bundle) {
            out += [note, ""]
        }

        if let tag = annotation.tag, !matchedALabel {
            out += ["Tagged **\(tag.rawValue)** - this workspace has no label of "
                    + "that name, so none was set.", ""]
        }

        if let crop = assets.crop { out += ["![The element](\(crop))", ""] }
        if let context = assets.context { out += ["![Where it sits](\(context))", ""] }

        out += ["## The element", ""]
        out += elementRows(annotation)

        if !annotation.trace.isEmpty {
            out += ["", "## What the app asked for", ""]
            out += traceTable(annotation.trace)
        }

        if !annotation.logs.isEmpty {
            out += ["", "## Logs", "", "```"]
            // Errors first: they are why anyone opens this section.
            let ordered = annotation.logs.sorted { a, b in
                (a.level == .error ? 0 : 1) < (b.level == .error ? 0 : 1)
            }
            out += ordered.prefix(20).map { "\($0.level.rawValue): \($0.message)" }
            out += ["```"]
        }

        out += ["", "## Where this came from", ""]
        out += appRows(bundle: bundle, annotation: annotation)

        out += ["", "---", "",
                "Captured by [Loupe](https://github.com/serhii-kucherenko/loupe) · "
                + IssueDraft.marker(for: annotation.id)]
        return out.joined(separator: "\n")
    }

    private static func elementRows(_ annotation: Annotation) -> [String] {
        let element = annotation.element
        var rows = ["| | |", "|---|---|"]

        // A region has no name because nothing on screen corresponds to it, and
        // saying "region" is more use than an empty row.
        rows.append("| kind | `\(element.kind.rawValue)` |")
        if let id = element.accessibilityID { rows.append("| id | `\(id)` |") }
        if let label = element.label { rows.append("| label | \(label) |") }
        if let name = element.className { rows.append("| class | `\(name)` |") }
        if let selector = element.selector { rows.append("| selector | `\(selector)` |") }
        if let screen = annotation.screen { rows.append("| screen | \(screen) |") }

        let b = element.bounds
        rows.append("| bounds | \(rect(b)) |")
        if let viewport = annotation.viewport {
            rows.append("| viewport | \(rect(viewport)) |")
        }
        return rows
    }

    private static func traceTable(_ events: [NetworkEvent]) -> [String] {
        var rows = ["| | | |", "|---|---|---|"]
        for event in events.suffix(20) {
            let status = event.statusCode.map(String.init) ?? "\u{2013}"
            // A failing call is the reason the trace is here at all.
            let failed = (event.statusCode ?? 0) < 200 || (event.statusCode ?? 0) >= 300
            let marked = failed ? "**\(status)**" : status
            rows.append("| `\(event.method)` | `\(event.url)` | \(marked) · \(event.durationMs)ms |")
        }
        return rows
    }

    private static func appRows(bundle: AnnotationBundle, annotation: Annotation) -> [String] {
        let app = bundle.app
        var rows = ["| | |", "|---|---|"]
        rows.append("| app | \(app.name)\(app.version.map { " \($0)" } ?? "") |")
        rows.append("| platform | \(platform(app)) |")
        rows.append("| environment | \(app.environment) |")
        if let device = app.device {
            if let machine = describe(device) { rows.append("| device | \(machine) |") }
            if let screen = device.screen {
                rows.append("| screen | \(size(screen)) |")
            }
        }
        // The single most useful field: it is how an agent checks out the code that
        // produced the screenshot.
        if let sha = app.commitSHA { rows.append("| commit | `\(sha)` |") }
        rows.append("| captured | \(ISO8601DateFormatter().string(from: annotation.capturedAt)) |")
        return rows
    }

    /// `iPadOS 26.5`. Joined here rather than stored joined, so the point release and
    /// the platform name stay one value each and cannot come to disagree.
    private static func platform(_ app: AppInfo) -> String {
        guard let version = app.device?.osVersion else { return app.platform }
        return "\(app.platform) \(version)"
    }

    /// `iPad Pro 11-inch (iPad8,3)`, or just the identifier for a model Loupe has not
    /// been taught. Never the name alone: the identifier is the precise one.
    private static func describe(_ device: DeviceInfo) -> String? {
        switch (device.name, device.identifier) {
        case let (name?, identifier?): return "\(name) (`\(identifier)`)"
        case let (nil, identifier?): return "`\(identifier)`"
        case let (name?, nil): return name
        case (nil, nil): return nil
        }
    }

    private static func size(_ screen: DeviceInfo.Screen) -> String {
        let scale = screen.scale == screen.scale.rounded()
            ? String(Int(screen.scale)) : String(format: "%.1f", screen.scale)
        return "\(Int(screen.width))\u{00d7}\(Int(screen.height)) @\(scale)x"
    }

    /// The line that earns the whole device field.
    ///
    /// A window smaller than the screen means Split View or Slide Over, and a
    /// screenshot cropped to the app cannot show it - so the cause of a whole class of
    /// "it looks wrong" arrives invisible. Two numbers disagreeing in a table is not
    /// something a reader notices. A sentence is.
    static func windowNote(annotation: Annotation, bundle: AnnotationBundle) -> String? {
        guard let device = bundle.app.device,
              device.isPartOfTheScreen(viewport: annotation.viewport) == true,
              let screen = device.screen, let viewport = annotation.viewport
        else { return nil }

        let sharing = viewport.width < screen.width - 1 ? "Split View or Slide Over"
                                                        : "a window shorter than the screen"
        return "**The app was not using the whole screen** - \(sharing), "
            + "\(Int(viewport.width))\u{00d7}\(Int(viewport.height))pt of "
            + "\(Int(screen.width))\u{00d7}\(Int(screen.height))pt. "
            + "A screenshot cropped to the app cannot show that."
    }

    private static func rect(_ r: Rect) -> String {
        "\(Int(r.x)), \(Int(r.y)) \u{00b7} \(Int(r.width))\u{00d7}\(Int(r.height))"
    }
}
