#if os(macOS)
import Foundation
import LoupeCore

/// Realistic fixtures. An empty demo teaches nothing: there has to be something on
/// screen worth complaining about before anyone can show what complaining does.
enum Seed {

    struct Product: Identifiable, Hashable {
        let id: Int
        let name: String
        let price: String
        let stock: Int
    }

    static let products: [Product] = [
        Product(id: 1, name: "Blue canvas jacket", price: "£128.00", stock: 4),
        Product(id: 2, name: "Wool overshirt, ink", price: "£96.00", stock: 0),
        Product(id: 3, name: "Selvedge denim, 13oz", price: "£145.00", stock: 12),
        Product(id: 4, name: "Boiled wool cap", price: "£38.00", stock: 2),
        Product(id: 5, name: "Waxed cotton tote", price: "£64.00", stock: 7),
        Product(id: 6, name: "Merino crew, oat", price: "£72.00", stock: 0),
    ]

    static func searchJSON(matching query: String) -> String {
        let matches = products.filter {
            $0.name.localizedCaseInsensitiveContains(query.replacingOccurrences(of: "%20", with: " "))
        }
        let items = matches.map {
            #"{"id":\#($0.id),"name":"\#($0.name)","price":"\#($0.price)","stock":\#($0.stock)}"#
        }
        return #"{"items":[\#(items.joined(separator: ","))]}"#
    }

    /// One bundle written to disk at launch, so the Agent role is never an empty
    /// screen on first run. It is a plausible pair of notes from a previous session.
    static func bundle(app: AppInfo) -> AnnotationBundle {
        let now = Date().addingTimeInterval(-3600)

        let stale = Annotation(
            comment: "clearing the search leaves the old results on screen",
            tag: .bug,
            element: ElementRef(accessibilityID: "search.results",
                                label: "Search results",
                                className: "ResultsList",
                                bounds: Rect(x: 24, y: 132, width: 452, height: 320)),
            trace: [
                NetworkEvent(method: "GET", url: "http://127.0.0.1/v2/search?q=wool",
                             statusCode: 200, durationMs: 141,
                             at: now.addingTimeInterval(-8)),
                NetworkEvent(method: "GET", url: "http://127.0.0.1/v2/search?q=",
                             statusCode: 500, durationMs: 62,
                             at: now.addingTimeInterval(-3)),
            ],
            logs: [
                LogEvent(level: .error,
                         message: "SearchStore kept the last good page after a 500",
                         subsystem: "search", at: now.addingTimeInterval(-3))
            ],
            screen: "/search",
            viewport: Rect(x: 0, y: 0, width: 900, height: 620),
            capturedAt: now)

        let emptyState = Annotation(
            comment: "the empty cart gives you nowhere to go from here",
            tag: .polish,
            element: ElementRef(accessibilityID: "cart.empty",
                                label: "Your basket is empty",
                                className: "EmptyState",
                                bounds: Rect(x: 300, y: 260, width: 300, height: 120)),
            trace: [
                NetworkEvent(method: "GET", url: "http://127.0.0.1/v2/cart",
                             statusCode: 200, durationMs: 39, at: now.addingTimeInterval(-1))
            ],
            screen: "/cart",
            viewport: Rect(x: 0, y: 0, width: 900, height: 620),
            capturedAt: now.addingTimeInterval(20))

        return AnnotationBundle(sessionID: UUID(), app: app,
                                annotations: [stale, emptyState],
                                sentAt: now.addingTimeInterval(30))
    }

    /// Writes the seeded bundle once. Running the demo twice must not pile up
    /// duplicates of the same fixture.
    static func installIfNeeded(app: AppInfo, into directory: URL) {
        let marker = directory.appendingPathComponent(".seeded")
        guard !FileManager.default.fileExists(atPath: marker.path) else { return }
        Task {
            try? await FileTransport(directory: directory).send(bundle(app: app))
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try? Data().write(to: marker)
        }
    }
}
#endif
