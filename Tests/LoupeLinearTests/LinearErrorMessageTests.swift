import XCTest
@testable import LoupeLinear

/// That the sentence written for a person is the sentence a person gets.
///
/// The first real send in this project's life failed, and what reached the tray was
/// `"The operation couldn't be completed. (LoupeLinear.LinearError error 3.)"` - a
/// bare Swift enum bridged to `NSError`. Every case carried a real explanation and
/// none of it was on screen, which is the same shape as everything else that went
/// wrong that night: the thing that could say what happened said nothing.
///
/// Error 3, incidentally, was `.api` and not `.rateLimited` as the case order
/// suggests: Swift numbers cases *with associated values* first. Worth knowing only
/// because reasoning about it produced the wrong answer and reading it off produced
/// the right one.
final class LinearErrorMessageTests: XCTestCase {

    private let every: [LinearError] = [
        .notConfigured,
        .credentialRejected,
        .notPermitted("Core Team"),
        .rateLimited(retryAfter: 5),
        .unreachable("the network is offline"),
        .api("Access denied"),
        .couldNotStore(errSecMissingEntitlement),
    ]

    /// The one that failed. Anything reaching for `localizedDescription` - most of
    /// Apple's frameworks, and most host code - must get the written sentence.
    func testLocalizedDescriptionIsTheWrittenSentence() {
        for error in every {
            XCTAssertEqual(error.localizedDescription, error.description,
                           "\(error) is still bridging to an NSError code")
        }
    }

    /// The exact failure, named so it cannot come back: no message may be the
    /// generic bridge string, and none may end in a bare case number.
    func testNoMessageIsTheGenericBridgedString() {
        for error in every {
            let message = error.localizedDescription
            XCTAssertFalse(message.contains("The operation couldn"), message)
            XCTAssertFalse(message.contains("LinearError error"), message)
        }
    }

    /// A message is only useful if it says something. Each of these is read by
    /// somebody who has to decide what to do next.
    func testEveryMessageIsASentenceSomebodyCouldActOn() {
        for error in every {
            let message = error.localizedDescription
            XCTAssertGreaterThan(message.count, 12, "\(error) says almost nothing")
            XCTAssertTrue(message.first?.isUppercase == true
                          || message.first?.isLetter == false,
                          "reads mid-sentence: \(message)")
        }
    }

    /// The associated value is the whole point of `.api` - it is Linear's own words,
    /// and it is what was thrown away.
    func testAnApiFailureCarriesLinearsOwnWords() {
        XCTAssertEqual(LinearError.api("Access denied").localizedDescription,
                       "Access denied")
        XCTAssertTrue(LinearError.notPermitted("Core Team")
            .localizedDescription.contains("Core Team"))
        XCTAssertTrue(LinearError.unreachable("offline")
            .localizedDescription.contains("offline"))
    }
}
