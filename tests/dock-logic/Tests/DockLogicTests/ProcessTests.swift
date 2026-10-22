@testable import DockLogic
import XCTest

final class ProcessTests: XCTestCase {
    func testReturnsOutputAndStatus() {
        let r = DockProcess.run("/bin/sh", ["-c", "echo hello; exit 3"], timeout: 5, quiet: [3])
        XCTAssertEqual(r?.status, 3)
        XCTAssertEqual(r?.text, "hello\n")
    }

    func testStopsWhatRunsTooLong() {
        let start = Date()
        XCTAssertNil(DockProcess.run("/bin/sleep", ["10"], timeout: 0.5))
        XCTAssertLessThan(Date().timeIntervalSince(start), 4)
    }

    func testNilWhenItCannotStart() {
        XCTAssertNil(DockProcess.run("/no/such/tool", []))
        XCTAssertFalse(DockProcess.launch("/no/such/tool", []))
    }

    func testPruneKeepsOpenSessionsAndTheirAgents() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let sub = dir.appendingPathComponent("a/subagents")
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        let line = #"{"type":"assistant","timestamp":"2020-01-01T00:00:00.000Z","message":{"id":"m1","model":"claude-opus-4","usage":{"input_tokens":10,"output_tokens":5}}}"#
        for url in [dir.appendingPathComponent("a.jsonl"), dir.appendingPathComponent("b.jsonl"),
                    sub.appendingPathComponent("agent-x.jsonl")] {
            try (line.replacingOccurrences(of: "m1", with: url.lastPathComponent) + "\n").write(to: url, atomically: true, encoding: .utf8)
        }
        let agents = DockAgents()
        _ = agents.agents(transcript: dir.appendingPathComponent("a.jsonl"), sessionId: "a")
        agents.prune(keeping: [dir.appendingPathComponent("b.jsonl")])
        // Forgotten, so read again from the start: still one agent, same totals.
        let again = agents.agents(transcript: dir.appendingPathComponent("a.jsonl"), sessionId: "a")
        XCTAssertEqual(again.count, 1)
        XCTAssertEqual(again.first?.outputTokens, 5)
    }
}
