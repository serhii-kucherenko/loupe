import XCTest
import LoupeCore
@testable import LoupeUI

final class SpyTransport: Transport, @unchecked Sendable {
    var shouldFail = false
    var sent: [AnnotationBundle] = []
    func send(_ bundle: AnnotationBundle) async throws {
        if shouldFail { throw LoupeError.transportFailed("triage returned 503") }
        sent.append(bundle)
    }
}

func ref(_ id: String) -> ElementRef {
    ElementRef(accessibilityID: id, bounds: Rect(x: 0, y: 0, width: 40, height: 20))
}

@MainActor
final class OverlayModeTests: XCTestCase {

    private var transport = SpyTransport()

    private func makeModel() -> OverlayModel {
        transport = SpyTransport()
        return OverlayModel(session: AnnotationSession(
            app: AppInfo(name: "Demo", platform: "macOS"), transport: transport))
    }

    // MARK: - The walk through the mode machine

    func testTheOverlayStartsOffAndShowsNothing() {
        let model = makeModel()
        XCTAssertEqual(model.mode, .off)
        XCTAssertFalse(model.mode.isVisible)
        XCTAssertFalse(model.mode.swallowsInput)
    }

    func testTheFullPickCommentSaveWalk() {
        let model = makeModel()

        model.beginAnnotating()
        XCTAssertEqual(model.mode, .picking(hover: nil))

        model.hover(ref("search.field"))
        XCTAssertEqual(model.mode, .picking(hover: ref("search.field")))

        model.pick(ref("search.field"))
        guard case .commenting(let pick) = model.mode else {
            return XCTFail("a click should pin the element")
        }
        XCTAssertEqual(pick.index, 1, "the first badge is 1, not 0")

        model.saveComment("stale results", tag: .bug)
        XCTAssertEqual(model.mode, .browsing)
        XCTAssertEqual(model.annotations.map(\.comment), ["stale results"])
    }

    /// The reason `browsing` exists at all: you have to be able to walk to another
    /// screen with the tray still full.
    func testOnlyPickingAndCommentingSwallowTheHostAppsInput() {
        let model = makeModel()
        XCTAssertFalse(OverlayMode.off.swallowsInput)
        XCTAssertTrue(OverlayMode.picking(hover: nil).swallowsInput)
        XCTAssertTrue(OverlayMode.commenting(
            PendingPick(ref: ref("x"), index: 1)).swallowsInput)
        XCTAssertFalse(OverlayMode.browsing.swallowsInput)

        model.beginAnnotating()
        model.pick(ref("a"))
        model.saveComment("one", tag: nil)
        XCTAssertFalse(model.mode.swallowsInput, "the app must be usable again")
        XCTAssertTrue(model.mode.isVisible, "but the tray stays on screen")
    }

    func testCancellingAPickReturnsToPickingNotOutOfAnnotateMode() {
        let model = makeModel()
        model.beginAnnotating()
        model.pick(ref("a"))
        model.cancelComment()
        XCTAssertEqual(model.mode, .picking(hover: nil))
    }

    func testAnEmptyCommentIsNotAnAnnotation() {
        let model = makeModel()
        model.beginAnnotating()
        model.pick(ref("a"))

        XCTAssertNil(model.saveComment("   \n ", tag: .bug))
        XCTAssertTrue(model.annotations.isEmpty)
        guard case .commenting = model.mode else {
            return XCTFail("an empty comment must leave the popover open")
        }
    }

    func testTheBadgeNumberCountsUpAcrossPicks() {
        let model = makeModel()
        model.beginAnnotating()
        model.pick(ref("a")); model.saveComment("one", tag: nil)
        model.resumePicking()
        model.pick(ref("b"))

        guard case .commenting(let second) = model.mode else { return XCTFail() }
        XCTAssertEqual(second.index, 2)
    }

    func testHoverIsIgnoredOutsideOfPicking() {
        let model = makeModel()
        model.hover(ref("a"))
        XCTAssertEqual(model.mode, .off, "hovering must not start a session by itself")

        model.beginAnnotating()
        model.pick(ref("a"))
        model.hover(ref("b"))
        guard case .commenting = model.mode else {
            return XCTFail("hover must not move a pinned element")
        }
    }

    func testTheHotkeyMeansAmIAnnotatingRightNow() {
        let model = makeModel()
        model.toggleAnnotating()
        XCTAssertEqual(model.mode, .picking(hover: nil))
        model.toggleAnnotating()
        XCTAssertEqual(model.mode, .off)
    }

    // MARK: - Send

    func testASuccessfulSendShipsTheTrayAndClosesTheOverlay() async {
        let model = makeModel()
        model.beginAnnotating()
        model.pick(ref("a")); model.saveComment("one", tag: .bug)

        await model.send()

        XCTAssertEqual(transport.sent.count, 1)
        XCTAssertEqual(model.sendState, .sent(1))
        XCTAssertEqual(model.mode, .off, "Send is the end of the job")
        XCTAssertTrue(model.annotations.isEmpty)
    }

    func testAFailedSendKeepsTheTrayAndSaysWhy() async {
        let model = makeModel()
        transport.shouldFail = true
        model.beginAnnotating()
        model.pick(ref("a")); model.saveComment("one", tag: .bug)

        await model.send()

        XCTAssertEqual(model.sendState, .failed("triage returned 503"))
        XCTAssertEqual(model.annotations.count, 1, "nothing is lost on a failure")
        XCTAssertEqual(model.mode, .browsing, "the overlay stays so it can be retried")
    }

    func testSendingAnEmptyTrayDoesNothing() async {
        let model = makeModel()
        model.beginAnnotating()
        await model.send()
        XCTAssertEqual(model.sendState, .idle)
        XCTAssertTrue(transport.sent.isEmpty)
    }

    func testTheSendErrorCanBeDismissedWithoutLosingTheTray() async {
        let model = makeModel()
        transport.shouldFail = true
        model.beginAnnotating()
        model.pick(ref("a")); model.saveComment("one", tag: nil)
        await model.send()

        model.dismissSendError()
        XCTAssertEqual(model.sendState, .idle)
        XCTAssertEqual(model.annotations.count, 1)
    }

    // MARK: - Tray editing

    func testTheTrayCanBeEditedAfterTheFact() {
        let model = makeModel()
        model.beginAnnotating()
        model.pick(ref("a")); model.saveComment("typo hree", tag: .polish)
        let id = model.annotations[0].id

        model.updateComment(id: id, comment: "typo here")
        model.updateTag(id: id, tag: .bug)
        XCTAssertEqual(model.annotations[0].comment, "typo here")
        XCTAssertEqual(model.annotations[0].tag, .bug)

        model.remove(id: id)
        XCTAssertTrue(model.annotations.isEmpty)
    }

    /// The host has to be told when to stop taking clicks, and it can only be told
    /// on a change it actually hears about.
    func testEveryModeChangeIsAnnouncedOnce() {
        let model = makeModel()
        var heard: [OverlayMode] = []
        model.onModeChange = { heard.append($0) }

        model.beginAnnotating()
        model.beginAnnotating()          // already annotating: no second announcement
        model.hover(nil)                 // no change: silent
        model.pick(ref("a"))
        model.saveComment("one", tag: nil)
        model.endAnnotating()

        XCTAssertEqual(heard, [.picking(hover: nil),
                               .commenting(PendingPick(ref: ref("a"), index: 1)),
                               .browsing,
                               .off])
    }

    // MARK: - The offline queue, surfaced

    func testTheTrayKnowsHowManyBundlesAreStuckOnDisk() async {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }

        let inner = SpyTransport()
        inner.shouldFail = true
        let queue = QueuedTransport(wrapping: inner, directory: directory)
        let model = OverlayModel(
            session: AnnotationSession(app: AppInfo(name: "Demo", platform: "iOS"),
                                       transport: queue),
            queue: queue)

        model.beginAnnotating()
        model.pick(ref("a")); model.saveComment("in a tunnel", tag: nil)
        await model.send()

        XCTAssertEqual(model.pendingCount, 1)

        inner.shouldFail = false
        await model.drainPending()
        XCTAssertEqual(model.pendingCount, 0)
        XCTAssertEqual(model.sendState, .idle)
    }
}

/// The tray must never be the reason part of the app cannot be pointed at.
@MainActor
final class TrayVisibilityTests: XCTestCase {

    private func makeModel() -> OverlayModel {
        OverlayModel(session: AnnotationSession(
            app: AppInfo(name: "Demo", platform: "macOS"), transport: SpyTransport()))
    }

    func testTheFullTrayBelongsToBrowsingOnly() {
        let model = makeModel()
        model.beginAnnotating()
        model.pick(ref("a"))
        model.saveComment("one", tag: nil)
        XCTAssertEqual(model.mode, .browsing, "after a save you are reviewing")

        model.resumePicking()
        XCTAssertEqual(model.mode, .picking(hover: nil),
                       "and while picking the page must be reachable again")
    }

    func testReviewOpensTheTrayFromTheCompactBar() {
        let model = makeModel()
        model.beginAnnotating()
        model.pick(ref("a"))
        model.saveComment("one", tag: nil)
        model.resumePicking()

        model.review()
        XCTAssertEqual(model.mode, .browsing)
    }

    func testReviewDoesNothingFromAnywhereElse() {
        let model = makeModel()
        model.review()
        XCTAssertEqual(model.mode, .off)

        model.beginAnnotating()
        model.pick(ref("a"))
        model.review()
        guard case .commenting = model.mode else {
            return XCTFail("review must not interrupt a comment being typed")
        }
    }
}

/// SER-695, reported as friction: "when I point at smth I can't then simply point at
/// another place, I need to manually close the previously clicked unsaved one".
@MainActor
final class RepickWhileCommentingTests: XCTestCase {

    private func commenting() -> OverlayModel {
        let model = OverlayModel(session: AnnotationSession(
            app: AppInfo(name: "Demo", platform: "macOS"), transport: SpyTransport()))
        model.beginAnnotating()
        model.pick(ref("row"))
        return model
    }

    func testAnEmptyDraftIsThrownAwayAndPickingResumes() {
        let model = commenting()

        model.resolveDraftAndResumePicking()

        XCTAssertEqual(model.mode, .picking(hover: nil), "ready for the next pick")
        XCTAssertTrue(model.annotations.isEmpty, "nothing was said, so nothing is kept")
    }

    // The one unacceptable option is silently dropping what somebody typed.
    func testADraftWithWordsInItBecomesANoteFirst() {
        let model = commenting()
        model.draftComment = "this row is unreadable"
        model.draftTag = .polish

        model.resolveDraftAndResumePicking()

        XCTAssertEqual(model.mode, .picking(hover: nil))
        XCTAssertEqual(model.annotations.count, 1)
        XCTAssertEqual(model.annotations.first?.comment, "this row is unreadable")
        XCTAssertEqual(model.annotations.first?.tag, .polish)
    }

    func testTheDraftDoesNotLeakIntoTheNextComment() {
        let model = commenting()
        model.draftComment = "first"
        model.resolveDraftAndResumePicking()

        model.pick(ref("another row"))

        XCTAssertEqual(model.draftComment, "", "a new pick starts with an empty field")
        XCTAssertNil(model.draftTag)
    }

    func testItDoesNothingWhenNoCommentIsOpen() {
        let model = OverlayModel(session: AnnotationSession(
            app: AppInfo(name: "Demo", platform: "macOS"), transport: SpyTransport()))

        model.resolveDraftAndResumePicking()

        XCTAssertEqual(model.mode, .off)
    }
}

/// SER-698: "when I select another area while prev one is selected, I don't see what
/// I'm selecting until I release the dragging". Drawing blind, on a touch screen,
/// with a hand over the thing being sized.
@MainActor
final class DragPreviewTests: XCTestCase {

    private func model() -> OverlayModel {
        OverlayModel(session: AnnotationSession(
            app: AppInfo(name: "Demo", platform: "macOS"), transport: SpyTransport()))
    }

    func testTheShapeIsVisibleWhileDraggingDuringAPick() {
        let model = model()
        model.beginAnnotating()

        model.drag(to: Rect(x: 0, y: 0, width: 40, height: 40))

        XCTAssertNotNil(model.dragRegion)
    }

    // The case that was broken: a drag begun while a comment is still open.
    func testTheShapeIsVisibleWhileDraggingOverAnOpenComment() {
        let model = model()
        model.beginAnnotating()
        model.pick(ref("row"))

        model.drag(to: Rect(x: 0, y: 0, width: 40, height: 40))

        XCTAssertNotNil(model.dragRegion, "sizing a rectangle blind is the complaint")
    }

    func testNothingIsDrawnWhenTheOverlayIsNotTakingInput() {
        let model = model()
        model.drag(to: Rect(x: 0, y: 0, width: 40, height: 40))
        XCTAssertNil(model.dragRegion)
    }
}
