@testable import DockLogic
import XCTest

final class WorkspaceTests: XCTestCase {
    func testStatusBranchAheadDirty() {
        let w = DockWorkspace.parseStatus("""
            # branch.oid 0f0da90abcdef
            # branch.head main
            # branch.upstream origin/main
            # branch.ab +2 -0
            1 .M N... 100644 100644 100644 a b README.md
            ? new.txt
            """)
        XCTAssertEqual(w.branch, "main")
        XCTAssertEqual(w.ahead, 2)
        XCTAssertEqual(w.dirty, 2)
        XCTAssertEqual(w.summary, "main ↑2 ●2")
    }

    func testDetachedShowsShortSha() {
        let w = DockWorkspace.parseStatus("# branch.oid 0f0da90abcdef\n# branch.head (detached)\n")
        XCTAssertEqual(w.branch, "0f0da90")
    }

    func testPortsUnderClaude() {
        let listening = DockWorkspace.parseListening("p300\nf5\nn*:3000\np400\nn127.0.0.1:5432\n")
        let parents = DockWorkspace.parseParents("  300   250\n  250   200\n  400     1\n")
        XCTAssertEqual(DockWorkspace.ports(under: 200, listening: listening, parents: parents), [3000])
    }

    func testPullRequestAndSummary() {
        let pr = DockWorkspace.parsePullRequest(Data(#"{"number":42,"state":"OPEN","isDraft":true,"url":"u"}"#.utf8))
        XCTAssertEqual(pr?.number, 42)
        let w = DockWorkspace(branch: "feat", pr: pr, ports: [3000, 5173])
        XCTAssertEqual(w.summary, "feat · #42 draft · :3000 :5173")
    }
}
