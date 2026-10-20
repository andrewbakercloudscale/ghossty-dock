import XCTest
@testable import DockCore

final class RowsTests: XCTestCase {
    func term(_ id: String, tab: String, index: Int, selected: Bool = false, window: String = "w1",
              wd: String = "", name: String = "") -> GhosttyTerminal {
        GhosttyTerminal(windowId: window, windowIndex: 1, tabId: tab, tabIndex: index, tabSelected: selected,
                        terminalId: id, workingDirectory: wd, tabName: name)
    }

    func session(_ key: String, _ status: String, since: Int = 100, created: Int = 1, name: String = "proj",
                 dock: String? = nil, ghostty: Int32? = 50) -> SessionRecord {
        SessionRecord(key: key, status: status, since: since, updated: since, created: created,
                      project: "/x/" + name, cwd: "/x/" + name, name: name, dockTabId: dock,
                      claudePid: 1, ghosttyPid: ghostty)
    }

    func inputs(sessions: [SessionRecord] = [], tabs: [TabRecord] = [], terminals: [GhosttyTerminal] = [],
                frontmost: Bool = false, instances: [GhosttyInstance] = [], seen: [String: Int] = [:],
                home: Int32? = nil, front: Int32? = nil) -> RowInputs {
        RowInputs(sessions: sessions, tabs: tabs,
                  snapshot: GhosttySnapshot(frontmost: frontmost, frontWindowId: "w1", terminals: terminals),
                  instances: instances, seen: seen, homePid: home, frontmostPid: front)
    }

    func testDockTabMapsToItsTerminalAndTeachesHomePid() {
        let r = buildRows(inputs(
            sessions: [session("tab-a", "running", dock: "a", ghostty: 77)],
            tabs: [TabRecord(dockTabId: "a", terminalId: "T2", folder: "/x/proj", created: 1)],
            terminals: [term("T1", tab: "t1", index: 1, name: "zsh"), term("T2", tab: "t2", index: 2, name: "✳ proj")],
            instances: [GhosttyInstance(pid: 77, folder: nil, started: 0)]))
        XCTAssertEqual(r.rows.map(\.id), ["tab-a", "term-T1"])
        XCTAssertEqual(r.rows[0].target, .terminal("T2"))
        XCTAssertEqual(r.rows[0].status, .running)
        XCTAssertEqual(r.homePid, 77)
        XCTAssertEqual(r.rows[1].status, .shell)
        XCTAssertEqual(r.rows[1].name, "zsh")
    }

    func testSplitsInOneTabAreOneRow() {
        let r = buildRows(inputs(
            sessions: [session("tab-a", "waiting", dock: "a")],
            tabs: [TabRecord(dockTabId: "a", terminalId: "T1", folder: "/x/proj", created: 1)],
            terminals: [term("T1", tab: "t1", index: 1), term("P1", tab: "t1", index: 1, name: "usage panel")]))
        XCTAssertEqual(r.rows.count, 1)
        XCTAssertEqual(r.rows[0].status, .waiting)
    }

    func testDoneIsUnreadUntilSeen() {
        let s = session("tty-1", "done", since: 500)
        XCTAssertEqual(buildRows(inputs(sessions: [s], seen: [:])).rows[0].status, .unread)
        XCTAssertEqual(buildRows(inputs(sessions: [s], seen: ["tty-1": 499])).rows[0].status, .unread)
        XCTAssertEqual(buildRows(inputs(sessions: [s], seen: ["tty-1": 500])).rows[0].status, .inactive)
        XCTAssertEqual(buildRows(inputs(sessions: [session("tty-2", "idle")])).rows[0].status, .inactive)
    }

    func testViewedTabIsTheSelectedTabOfTheFrontWindowWhenGhosttyIsFrontmost() {
        let base = inputs(
            sessions: [session("tab-a", "done", dock: "a")],
            tabs: [TabRecord(dockTabId: "a", terminalId: "T1", folder: "", created: 1)],
            terminals: [term("T1", tab: "t1", index: 1, selected: true)],
            frontmost: true)
        XCTAssertEqual(buildRows(base).viewedId, "tab-a")
        var behind = base
        behind.snapshot.frontmost = false
        XCTAssertNil(buildRows(behind).viewedId)
    }

    func testLegacySessionsTargetTheirOwnApp() {
        let r = buildRows(inputs(
            sessions: [session("tty-9", "running", created: 5, name: "old", ghostty: 900)],
            instances: [GhosttyInstance(pid: 900, folder: "/x/old", started: 5),
                        GhosttyInstance(pid: 901, folder: "/x/quiet", started: 9)],
            front: 900))
        XCTAssertEqual(r.rows.map(\.id), ["tty-9", "pid-901"])
        XCTAssertEqual(r.rows[0].target, .app(900))
        XCTAssertEqual(r.viewedId, "tty-9")
        XCTAssertEqual(r.rows[1].status, .unknown)
        XCTAssertEqual(r.rows[1].name, "quiet")
    }

    func testSessionInHomeGhosttyWithoutDockIdMatchesByTitle() {
        let r = buildRows(inputs(
            sessions: [session("tty-3", "running", name: "ghossty-dock", ghostty: 12)],
            terminals: [term("T1", tab: "t1", index: 1, name: "zsh"),
                        term("T2", tab: "t2", index: 2, name: "◐ ghossty-dock")],
            instances: [GhosttyInstance(pid: 12, folder: "/x/ghossty-dock", started: 0)],
            home: 12))
        XCTAssertEqual(r.rows.map(\.id), ["tty-3", "term-T1"])
        XCTAssertEqual(r.rows[0].target, .terminal("T2"))
    }

    func testHomeInstanceIsNotListedTwice() {
        let r = buildRows(inputs(
            terminals: [term("T1", tab: "t1", index: 1, name: "zsh")],
            instances: [GhosttyInstance(pid: 12, folder: nil, started: 0)],
            home: 12))
        XCTAssertEqual(r.rows.map(\.id), ["term-T1"])
    }

    func testSortsNeedsYouThenBusyThenIdleKeepingTabOrderWithinEach() {
        let r = buildRows(inputs(
            sessions: [session("s1", "done", since: 10, name: "a", dock: "1"),
                       session("s2", "running", name: "b", dock: "2"),
                       session("s3", "idle", name: "c", dock: "3"),
                       session("s4", "waiting", name: "d", dock: "4"),
                       session("s5", "running", name: "e", dock: "5")],
            tabs: (1...5).map { TabRecord(dockTabId: "\($0)", terminalId: "T\($0)", folder: "", created: 1) },
            terminals: (1...5).map { term("T\($0)", tab: "t\($0)", index: $0) } + [term("T6", tab: "t6", index: 6)],
            seen: ["s3": 999]))
        XCTAssertEqual(r.rows.map(\.id), ["s4", "s2", "s5", "s1", "s3", "term-T6"])
    }

    func testParseSnapshot() {
        let s = parseSnapshot("true\nw1\nw1\t1\tt1\t1\ttrue\tT1\t/tmp\t◐ my\ttab\nw1\t1\tt2\t2\tfalse\tT2\t\tzsh\n")
        XCTAssertTrue(s.frontmost)
        XCTAssertEqual(s.frontWindowId, "w1")
        XCTAssertEqual(s.terminals.count, 2)
        XCTAssertEqual(s.terminals[0].tabName, "◐ my tab")
        XCTAssertEqual(s.terminals[1].workingDirectory, "")
        XCTAssertEqual(parseSnapshot(""), .empty)
    }

    func testCleanTitleAndLauncherFolder() {
        XCTAssertEqual(cleanTitle("◐ ghossty-dock"), "ghossty-dock")
        XCTAssertEqual(cleanTitle("✳ ~/x"), "~/x")
        XCTAssertEqual(launcherFolder(arguments: ["ghostty", "--a", "-e", "/l", "/x/y"]), "/x/y")
        XCTAssertNil(launcherFolder(arguments: ["ghostty"]))
    }

    func testPruneRemovesDeadSessionsAndLineage() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let files = StateFiles(root: dir)
        try FileManager.default.createDirectory(at: files.sessionsDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: files.lineageDir, withIntermediateDirectories: true)
        var dead = session("tty-dead", "running"); dead.claudePid = 4242
        var live = session("tty-live", "running"); live.claudePid = 1
        for s in [dead, live] {
            try JSONEncoder().encode(s).write(to: files.sessionsDir.appendingPathComponent(s.key + ".json"))
        }
        try "x".write(to: files.lineageDir.appendingPathComponent("4242"), atomically: true, encoding: .utf8)
        XCTAssertEqual(files.sessions().count, 2)
        let kept = files.prune(sessions: files.sessions(), liveTerminals: nil, isAlive: { $0 == 1 })
        XCTAssertEqual(kept.map(\.key), ["tty-live"])
        XCTAssertEqual(files.sessions().map(\.key), ["tty-live"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: files.lineageDir.appendingPathComponent("4242").path))
    }
}
