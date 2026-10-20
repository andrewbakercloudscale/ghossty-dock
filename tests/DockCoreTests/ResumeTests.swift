import XCTest
@testable import DockCore

final class ResumeTests: XCTestCase {
    func testPinnedSessionBecomesResumeKeepingOtherFlags() {
        let argv = ["--session-id", "abc", "--dangerously-skip-permissions", "--remote-control", "my proj"]
        XCTAssertEqual(Resume.pinnedSessionId(argv), "abc")
        XCTAssertEqual(Resume.arguments(from: argv, sessionId: "abc"),
                       ["--resume", "abc", "--dangerously-skip-permissions", "--remote-control", "my proj"])
    }

    func testCurrentIdWinsOverThePinnedOneAfterAClear() {
        XCTAssertEqual(Resume.arguments(from: ["--session-id=old", "-c"], sessionId: "new"), ["--resume", "new"])
    }

    func testUnknownIdContinues() {
        XCTAssertEqual(Resume.arguments(from: ["--continue", "--dangerously-skip-permissions"], sessionId: nil),
                       ["--continue", "--dangerously-skip-permissions"])
        XCTAssertEqual(Resume.arguments(from: ["--resume", "--verbose"], sessionId: nil), ["--continue", "--verbose"])
    }

    func testProjectDirNameAndQuote() {
        XCTAssertEqual(Resume.projectDirName("/Users/a/my_proj.x"), "-Users-a-my-proj-x")
        XCTAssertEqual(Resume.shellQuote("it's"), "'it'\\''s'")
    }
}
