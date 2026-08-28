import XCTest
@testable import LoupeCore

final class LogRecorderTests: XCTestCase {

    func testRingBufferDropsOldestBeyondCapacity() {
        let recorder = LogRecorder(capacity: 3)
        for i in 0..<5 {
            recorder.record(LogEvent(level: .info, message: "line \(i)", at: Date()))
        }
        XCTAssertEqual(recorder.recent().map(\.message),
                       ["line 2", "line 3", "line 4"])
    }

    func testRecentKeepsOnlyTheWindowAroundThePick() {
        let recorder = LogRecorder(capacity: 10)
        let now = Date()
        recorder.record(LogEvent(level: .info, message: "old",
                                 at: now.addingTimeInterval(-120)))
        recorder.record(LogEvent(level: .error, message: "fresh",
                                 at: now.addingTimeInterval(-2)))

        XCTAssertEqual(recorder.recent(within: 30, now: now).map(\.message), ["fresh"])
    }

    // Errors are the reason this buffer exists. A long window of chatter must never
    // push the one failing line out of the picture the agent sees.
    func testErrorsSurviveEvenWhenTheBufferOverflows() {
        let recorder = LogRecorder(capacity: 3)
        recorder.record(LogEvent(level: .error, message: "the failure", at: Date()))
        for i in 0..<10 {
            recorder.record(LogEvent(level: .debug, message: "chatter \(i)", at: Date()))
        }

        XCTAssertTrue(recorder.recent().contains { $0.message == "the failure" },
                      "an error must not be evicted by later debug noise")
        XCTAssertLessThanOrEqual(recorder.recent().count, 4,
                                 "capacity still bounds the buffer")
    }

    func testConvenienceHelpersStampTheLevel() {
        let recorder = LogRecorder(capacity: 10)
        recorder.info("hello")
        recorder.error("boom", subsystem: "net")

        XCTAssertEqual(recorder.recent().map(\.level), [.info, .error])
        XCTAssertEqual(recorder.recent().last?.subsystem, "net")
    }

    func testRemoveAllEmptiesBothLanes() {
        let recorder = LogRecorder(capacity: 5)
        recorder.error("boom")
        recorder.info("hello")
        recorder.removeAll()
        XCTAssertTrue(recorder.recent().isEmpty)
    }
}
