import XCTest
import LoupeCore
@testable import LoupeLinear

/// The mapping is the piece with the least excuse for being wrong: it is pure, every
/// input is already in the bundle, and an agent reads nothing but its output.
final class IssueDraftTests: XCTestCase {

    private func annotation(_ comment: String) -> Annotation {
        Annotation(comment: comment, tag: .polish,
                   element: ElementRef(accessibilityID: "search.results",
                                       label: "Wool overshirt",
                                       className: "ListCollectionViewCell",
                                       bounds: Rect(x: 36, y: 320, width: 388, height: 71)))
    }

    private func bundle() -> AnnotationBundle {
        AnnotationBundle(sessionID: UUID(),
                         app: AppInfo(name: "Demo", version: "1.2.0", commitSHA: "abc1234",
                                      platform: "iOS", environment: "staging"),
                         annotations: [],
                         sentAt: Date())
    }

    func testTheTitleIsTheFirstLineBecauseATitleIsNotAParagraph() {
        let draft = IssueDraft(annotation: annotation("stock count is unreadable\nand the row is too tall"),
                               bundle: bundle())

        XCTAssertEqual(draft.title, "stock count is unreadable")
    }

    func testALongTitleIsCutAtAWordRatherThanMidSyllable() {
        let long = String(repeating: "unreadable ", count: 20)
        let draft = IssueDraft(annotation: annotation(long), bundle: bundle())

        XCTAssertLessThanOrEqual(draft.title.count, 81)
        XCTAssertTrue(draft.title.hasSuffix("\u{2026}"))
        XCTAssertFalse(draft.title.contains("unre\u{2026}"), "cut at a space, not a letter")
    }

    func testTheWholeCommentSurvivesInTheBodyEvenWhenTheTitleIsCut() {
        let draft = IssueDraft(annotation: annotation("first line\nsecond line"),
                               bundle: bundle())

        XCTAssertTrue(draft.description.contains("second line"))
    }

    func testTheTagBecomesALabel() {
        XCTAssertEqual(IssueDraft(annotation: annotation("x"), bundle: bundle()).labelName,
                       "polish")
    }

    // The single most useful field: it is how an agent checks out the code that
    // produced the screenshot.
    func testTheCommitIsInTheBody() {
        let draft = IssueDraft(annotation: annotation("x"), bundle: bundle())
        XCTAssertTrue(draft.description.contains("abc1234"))
    }

    func testTheMarkerIsPresentSoARetryCanFindTheIssue() {
        let note = annotation("x")
        let draft = IssueDraft(annotation: note, bundle: bundle())

        XCTAssertTrue(draft.description.contains(IssueDraft.marker(for: note.id)))
    }

    // A region pick on the web has no crop at all. That is ordinary, not an error.
    func testANoteWithNoPicturesStillMakesASensibleIssue() {
        let draft = IssueDraft(annotation: annotation("no crop here"), bundle: bundle())

        XCTAssertFalse(draft.description.contains("!["), "no broken image markdown")
        XCTAssertTrue(draft.description.contains("no crop here"))
    }

    func testAFailingRequestIsMarkedInTheTrace() {
        var note = annotation("search is broken")
        note.trace = [
            NetworkEvent(method: "GET", url: "/v2/search", statusCode: 500,
                         durationMs: 12, at: Date()),
            NetworkEvent(method: "GET", url: "/v2/cart", statusCode: 200,
                         durationMs: 8, at: Date()),
        ]

        let body = IssueDraft(annotation: note, bundle: bundle()).description

        XCTAssertTrue(body.contains("**500**"), "the failing call is why the trace is here")
        XCTAssertTrue(body.contains("| 200 ·"), "a healthy call is not shouted about")
    }

    func testARegionSaysSoRatherThanLookingLikeAnUnnamedElement() {
        var note = annotation("this whole area")
        note.element = ElementRef(kind: .region,
                                  bounds: Rect(x: 0, y: 0, width: 100, height: 80))

        let body = IssueDraft(annotation: note, bundle: bundle()).description

        XCTAssertTrue(body.contains("`region`"))
    }

    func testErrorsComeFirstInTheLogsBecauseThatIsWhyAnyoneOpensThem() {
        var note = annotation("x")
        note.logs = [
            LogEvent(level: .debug, message: "routine", subsystem: "demo", at: Date()),
            LogEvent(level: .error, message: "the thing that broke", subsystem: "demo", at: Date()),
        ]

        let body = IssueDraft(annotation: note, bundle: bundle()).description
        let errorLine = body.range(of: "the thing that broke")
        let debugLine = body.range(of: "routine")

        XCTAssertNotNil(errorLine)
        XCTAssertNotNil(debugLine)
        XCTAssertTrue(errorLine!.lowerBound < debugLine!.lowerBound)
    }
}

extension IssueDraftTests {
    /// The sentence is read by a person deciding whether to add the label, so it is
    /// worth looking at rather than only asserting a substring of.
    func testTheUnmatchedTagReadsAsASentence() {
        let draft = IssueDraft(annotation: annotation("the row is cut off"),
                               bundle: bundle())
        let line = draft.description.split(separator: "\n")
            .first { $0.hasPrefix("Tagged") }
        XCTAssertEqual(String(line ?? ""),
                       "Tagged **polish** - this workspace has no label of that name, "
                       + "so none was set.")
    }

    func testAMatchedTagSaysNothingExtra() {
        let draft = IssueDraft(annotation: annotation("the row is cut off"),
                               bundle: bundle(), labelID: "label-1")
        XCTAssertFalse(draft.description.contains("Tagged **polish**"),
                       "the label itself is on the issue, so the sentence would be noise")
    }
}
