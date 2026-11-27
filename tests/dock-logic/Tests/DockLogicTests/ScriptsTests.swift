import XCTest
@testable import DockLogic

/// The sidebar searches every idle tab's screen and each session's child
/// command lines twice a second, on the main thread.
final class ScriptsTests: XCTestCase {
    func testHas() {
        XCTAssertTrue(DockScripts.has("a Waiting for 2 background agents", "Waiting for "))
        XCTAssertFalse(DockScripts.has("nothing here", "Waiting for "))
        XCTAssertTrue(DockScripts.has("é… still running", " still running"))
        XCTAssertFalse(DockScripts.has("", "x"))
        XCTAssertFalse(DockScripts.has("ab", "abc"))
        XCTAssertTrue(DockScripts.isClaudeShell("/bin/zsh -c source /Users/x/.claude/shell-snapshots/s.sh && eval 'ls'"))
    }

    /// The budget: 20 screens of 200 KB, searched for two phrases, in well
    /// under a frame. Foundation's range(of:) took ~300 ms for this.
    func testSearchingScreensIsCheap() {
        let screen = String(repeating: "│ some terminal output with ünïcode ─ and more text here\n", count: 3600)
        let start = Date()
        var found = 0
        for _ in 0..<20 {
            if DockScripts.has(screen, " still running") || DockScripts.has(screen, "Waiting for ") { found += 1 }
        }
        XCTAssertEqual(found, 0)
        XCTAssertLessThan(Date().timeIntervalSince(start), 0.05)
    }

    /// Counting a session's background commands reads only their arguments,
    /// not their environment, and stays cheap: this test's own process.
    func testCountIsCheap() {
        let start = Date()
        for _ in 0..<50 { _ = DockScripts.count(getpid()) }
        XCTAssertLessThan(Date().timeIntervalSince(start), 0.05)
    }
}
