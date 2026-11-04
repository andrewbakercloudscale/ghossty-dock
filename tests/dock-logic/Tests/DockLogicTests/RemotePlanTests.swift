import XCTest
@testable import DockLogic

final class RemotePlanTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1000)
    private let rule = String(repeating: "─", count: 40)

    func testEmptyPrompt() {
        XCTAssertTrue(DockRemotePlan.promptEmpty("out\n\(rule)\n❯ \u{a0}\n\(rule)\n  status"))
        XCTAssertTrue(DockRemotePlan.promptEmpty("\(rule)\n❯    │ panel text\n\(rule)"))
    }

    func testPromptNotEmpty() {
        XCTAssertFalse(DockRemotePlan.promptEmpty("\(rule)\n❯ half a thought\n\(rule)"))
        XCTAssertFalse(DockRemotePlan.promptEmpty("\(rule)\n❯ 1. Yes\n  2. No"))
        // A shell whose prompt is also ❯.
        XCTAssertFalse(DockRemotePlan.promptEmpty("~/repo\n❯ "))
        XCTAssertFalse(DockRemotePlan.promptEmpty("no prompt here"))
    }

    func testRepoName() {
        XCTAssertEqual(DockRemotePlan.repoName(cwd: "/a/repo/sub", commonDir: "/a/repo/.git"), "repo")
        XCTAssertEqual(DockRemotePlan.repoName(cwd: "/a/tree", commonDir: "/a/repo/.git"), "repo")
        XCTAssertEqual(DockRemotePlan.repoName(cwd: "/a/folder", commonDir: nil), "folder")
    }

    func testSessionFile() {
        let json = #"{"sessionId":"s","cwd":"/a","pid":7}"#.data(using: .utf8)!
        XCTAssertEqual(DockRemotePlan.session(json: json),
                       DockRemotePlan.Session(sessionId: "s", cwd: "/a", pid: 7))
        XCTAssertNil(DockRemotePlan.session(json: Data("{}".utf8)))
    }

    func testBackgroundWork() {
        XCTAssertTrue(DockRemotePlan.backgroundWork("\(rule)\n❯ \n\(rule)\n  ⏵⏵ auto mode on · 1 shell"))
        XCTAssertFalse(DockRemotePlan.backgroundWork("\(rule)\n❯ \n\(rule)\n  ⏵⏵ auto mode on (shift+tab to cycle)"))
        XCTAssertFalse(DockRemotePlan.backgroundWork("done · 3 files\n\(rule)\n❯ \n\(rule)\n  status"), "above the box")
    }

    func testRelaunchesOnceAfterSettling() {
        var p = DockRemotePlan.Progress()
        var go: Bool
        (p, go) = DockRemotePlan.next(p, ready: true, now: t0)
        XCTAssertFalse(go)
        (p, go) = DockRemotePlan.next(p, ready: true, now: t0.addingTimeInterval(299))
        XCTAssertFalse(go)
        (p, go) = DockRemotePlan.next(p, ready: true, now: t0.addingTimeInterval(300))
        XCTAssertTrue(go)
        (p, go) = DockRemotePlan.next(p, ready: true, now: t0.addingTimeInterval(900))
        XCTAssertFalse(go, "once")
    }

    func testBusyStartsTheWaitAgain() {
        var p = DockRemotePlan.Progress()
        var go: Bool
        (p, go) = DockRemotePlan.next(p, ready: true, now: t0)
        (p, go) = DockRemotePlan.next(p, ready: false, now: t0.addingTimeInterval(200))
        (p, go) = DockRemotePlan.next(p, ready: true, now: t0.addingTimeInterval(300))
        XCTAssertFalse(go)
        (p, go) = DockRemotePlan.next(p, ready: true, now: t0.addingTimeInterval(599))
        XCTAssertFalse(go)
        (p, go) = DockRemotePlan.next(p, ready: true, now: t0.addingTimeInterval(600))
        XCTAssertTrue(go)
    }
}
