#if canImport(AppKit)
import XCTest
import AppKit
import LoupeCore
@testable import LoupeUI

/// The whole path, with nothing stubbed out except the person's hand: a real window,
/// a real view, the real picker, the real tray, the real transport, and then the
/// bundle read back off disk the way an agent would read it.
///
/// Every piece of this is tested on its own elsewhere. This is here because the
/// seams between them are where a tool like this actually breaks.
@MainActor
final class EndToEndTests: XCTestCase {

    // See SessionPersistenceTests: a `let` of a Sendable type is readable from the
    // nonisolated tearDown, and XCTest gives each test its own instance regardless.
    private let directory = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent(UUID().uuidString)

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
        NetworkRecorder.shared.removeAll()
        LogRecorder.shared.removeAll()
        super.tearDown()
    }

    func testPointAtSomethingTypeAComplaintAndAnAgentCanReadIt() async throws {
        // A window with a named card, a label inside it, and a button.
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 400),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.title = "/search"
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        window.contentView = content

        let card = NSView(frame: NSRect(x: 40, y: 240, width: 300, height: 80))
        card.identifier = NSUserInterfaceItemIdentifier("search.results")
        card.wantsLayer = true
        card.layer?.backgroundColor = NSColor.white.cgColor
        let label = NSTextField(labelWithString: "Wool overshirt, ink")
        label.frame = NSRect(x: 12, y: 30, width: 200, height: 20)
        card.addSubview(label)
        content.addSubview(card)

        // What the app was doing at the time.
        NetworkRecorder.shared.record(NetworkEvent(
            method: "GET", url: "https://api.example.test/v2/search?q=",
            statusCode: 500, durationMs: 62, at: Date()))
        LogRecorder.shared.error("kept the last good page after a 500", subsystem: "search")

        let session = AnnotationSession(
            app: AppInfo(name: "E2E", version: "1.0", commitSHA: "abc1234", platform: "macOS"),
            transport: FileTransport(directory: directory))
        let model = OverlayModel(session: session)

        // Point at the label inside the card. The walk must land on the card.
        model.beginAnnotating()
        let point = CGPoint(x: 100, y: 400 - 280)          // top-left coordinates
        guard let picked = ElementPicker.pick(at: point, in: window) else {
            return XCTFail("nothing was picked")
        }
        XCTAssertEqual(picked.ref.accessibilityID, "search.results")

        model.pick(picked.ref,
                   screenshotPNG: ElementPicker.screenshotPNG(of: picked.view),
                   contextScreenshotPNG: ElementPicker.contextPNG(of: picked.view, in: window),
                   screen: window.title,
                   viewport: Rect(x: 0, y: 0, width: 600, height: 400))
        model.saveComment("clearing the search leaves the old results on screen", tag: .bug)
        XCTAssertEqual(model.mode, .browsing, "the app must be usable again after a save")

        await model.send()
        XCTAssertEqual(model.mode, .off)

        // Now read it exactly the way an agent would.
        let folders = try FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil)
        guard let folder = folders.first(where: { $0.hasDirectoryPath }) else {
            return XCTFail("nothing was written")
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let bundle = try decoder.decode(
            AnnotationBundle.self,
            from: Data(contentsOf: folder.appendingPathComponent("bundle.json")))

        XCTAssertEqual(bundle.formatVersion, 1)
        XCTAssertEqual(bundle.app.commitSHA, "abc1234", "the agent needs the build")
        XCTAssertEqual(bundle.annotations.count, 1)

        let annotation = bundle.annotations[0]
        XCTAssertEqual(annotation.comment, "clearing the search leaves the old results on screen")
        XCTAssertEqual(annotation.tag, .bug)
        XCTAssertEqual(annotation.element.accessibilityID, "search.results")
        XCTAssertEqual(annotation.screen, "/search")
        XCTAssertEqual(annotation.viewport?.width, 600)

        // Top-left bounds: the card sits 240..320 up from the bottom of 400.
        XCTAssertEqual(annotation.element.bounds.y, 80, accuracy: 1)

        XCTAssertEqual(annotation.trace.first?.statusCode, 500,
                       "the endpoint behind the element is the point of the tool")
        XCTAssertEqual(annotation.logs.first?.level, .error)

        // The crop is a real PNG, named by annotation id, sitting beside the JSON.
        let png = folder.appendingPathComponent("\(annotation.id.uuidString).png")
        let data = try Data(contentsOf: png)
        XCTAssertEqual(data.prefix(4), Data([0x89, 0x50, 0x4E, 0x47]), "not a PNG")

        let image = NSImage(data: data)
        XCTAssertEqual(image?.size.width ?? 0, 300, accuracy: 1,
                       "the crop is the card, not the label inside it")
        XCTAssertEqual(image?.size.height ?? 0, 80, accuracy: 1)

        // And the second picture, which answers the other question.
        let context = try Data(contentsOf:
            folder.appendingPathComponent("\(annotation.id.uuidString)-context.png"))
        let whole = NSImage(data: context)
        XCTAssertEqual(whole?.size.width ?? 0, 600, accuracy: 1,
                       "the context shot is the window, not the element")
        XCTAssertEqual(whole?.size.height ?? 0, 400, accuracy: 1)
    }

    /// The other half of what makes the tool usable: one tray, several screens.
    func testOneTraySpansTwoScreens() async throws {
        let session = AnnotationSession(
            app: AppInfo(name: "E2E", platform: "macOS"),
            transport: FileTransport(directory: directory))
        let model = OverlayModel(session: session)

        model.beginAnnotating()
        model.pick(ElementRef(accessibilityID: "search.results",
                              bounds: Rect(x: 0, y: 0, width: 10, height: 10)),
                   screen: "/search")
        model.saveComment("stale results", tag: .bug)

        // Between the two, the person navigated. The overlay was not in the way.
        XCTAssertFalse(model.mode.swallowsInput)

        model.resumePicking()
        model.pick(ElementRef(accessibilityID: "cart.empty",
                              bounds: Rect(x: 0, y: 0, width: 10, height: 10)),
                   screen: "/cart")
        model.saveComment("no way forward from the empty basket", tag: .polish)

        await model.send()

        let folders = try FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil)
        XCTAssertEqual(folders.filter(\.hasDirectoryPath).count, 1,
                       "two screens, one bundle")

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let bundle = try decoder.decode(
            AnnotationBundle.self,
            from: Data(contentsOf: folders.first(where: \.hasDirectoryPath)!
                .appendingPathComponent("bundle.json")))
        XCTAssertEqual(bundle.annotations.map(\.screen), ["/search", "/cart"])
    }
}

/// The three entry points a host app is told to call. `handleShake` in particular had
/// no test at all, and it is documented in the README, in the install guide and in the
/// design notes as the way to wire shake-to-annotate.
@MainActor
final class LoupeEntryPointTests: XCTestCase {

    private let directory = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent(UUID().uuidString)

    override func setUp() {
        super.setUp()
        Loupe.start(app: AppInfo(name: "Demo", platform: "macOS"),
                    transport: FileTransport(directory: directory))
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
        super.tearDown()
    }

    func testShakeOpensAnnotateModeAndShakingAgainLeaves() {
        XCTAssertEqual(Loupe.model?.mode, .off)

        Loupe.handleShake()
        XCTAssertEqual(Loupe.model?.mode, .picking(hover: nil))

        Loupe.handleShake()
        XCTAssertEqual(Loupe.model?.mode, .off)
    }

    func testBeginAndEndAreNotAToggle() {
        Loupe.beginAnnotating()
        Loupe.beginAnnotating()
        XCTAssertEqual(Loupe.model?.mode, .picking(hover: nil), "begin twice still means begin")

        Loupe.endAnnotating()
        XCTAssertEqual(Loupe.model?.mode, .off)
    }
}
#endif
