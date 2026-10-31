import XCTest
@testable import DockLogic

final class RemotePlanTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1000)
    private let rule = String(repeating: "─", count: 40)

    private func step(_ p: DockRemotePlan.Progress, bridge: String? = "b1", ready: Bool = true, menu: Bool = false,
                      after: TimeInterval) -> (DockRemotePlan.Progress, DockRemotePlan.Action) {
        DockRemotePlan.next(p, repo: "repo", bridgeId: bridge, ready: ready, menu: menu,
                            now: t0.addingTimeInterval(after))
    }

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

    func testConnectedMenu() {
        XCTAssertTrue(DockRemotePlan.connectedMenu("  Disconnect this session\n  ❯ Continue\n  Enter to select · Esc to continue"))
        XCTAssertFalse(DockRemotePlan.connectedMenu("we talked about Disconnect this session"))
    }

    func testRepoName() {
        XCTAssertEqual(DockRemotePlan.repoName(cwd: "/a/repo/sub", commonDir: "/a/repo/.git"), "repo")
        XCTAssertEqual(DockRemotePlan.repoName(cwd: "/a/tree", commonDir: "/a/repo/.git"), "repo")
        XCTAssertEqual(DockRemotePlan.repoName(cwd: "/a/folder", commonDir: nil), "folder")
    }

    func testSessionFile() {
        let json = #"{"sessionId":"s","cwd":"/a","bridgeSessionId":"b"}"#.data(using: .utf8)!
        XCTAssertEqual(DockRemotePlan.session(json: json),
                       DockRemotePlan.Session(sessionId: "s", cwd: "/a", bridgeId: "b"))
        XCTAssertNil(DockRemotePlan.session(json: Data("{}".utf8)))
    }

    func testConnectsThenRenamesTwice() {
        var (p, a) = step(.init(), after: 0)
        XCTAssertEqual(a, .type("/remote-control repo"))
        (p, a) = step(p, after: 1)
        XCTAssertEqual(a, .wait)
        (p, a) = step(p, ready: false, menu: true, after: 5)
        XCTAssertEqual(a, .escape, "already connected: leaves the menu, stays connected")
        (p, a) = step(p, after: 6)
        XCTAssertEqual(a, .type("/rename repo-x"))
        (p, a) = step(p, after: 7)
        XCTAssertEqual(a, .wait)
        (p, a) = step(p, after: 10)
        XCTAssertEqual(a, .type("/rename repo"))
        (p, a) = step(p, after: 100)
        XCTAssertEqual(a, .wait, "done: nothing more for this bridge")
    }

    func testNeverTypesUnlessReady() {
        var p = DockRemotePlan.Progress()
        var a: DockRemotePlan.Action
        (p, a) = step(p, ready: false, after: 0)
        XCTAssertEqual(a, .wait)
        (p, a) = step(p, after: 0)
        (p, a) = step(p, ready: false, after: 9)
        XCTAssertEqual(a, .wait)
        (p, a) = step(p, after: 9)
        XCTAssertEqual(a, .type("/rename repo-x"))
        (p, a) = step(p, ready: false, after: 90)
        XCTAssertEqual(a, .wait, "someone is typing: the -x name waits, then is put right")
        (p, a) = step(p, after: 91)
        XCTAssertEqual(a, .type("/rename repo"))
    }

    func testNewBridgeIsRepaired() {
        var p = DockRemotePlan.Progress(stage: .done, at: t0, bridgeId: "b1", runs: 1)
        var a: DockRemotePlan.Action
        (p, a) = step(p, bridge: "b1", after: 1)
        XCTAssertEqual(a, .wait)
        (p, a) = step(p, bridge: "b2", after: 2)
        XCTAssertEqual(a, .type("/remote-control repo"))
        XCTAssertEqual(p.runs, 2)
    }

    func testGivesUpOnAnEndlessBridge() {
        let p = DockRemotePlan.Progress(stage: .done, at: t0, bridgeId: "b1", runs: DockRemotePlan.maxRuns)
        XCTAssertEqual(step(p, bridge: "b2", after: 1).1, .wait)
    }
}
