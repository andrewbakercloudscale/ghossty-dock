import XCTest
@testable import DockLogic

final class AgentsTests: XCTestCase {
    private func line(_ s: String) -> [String: Any] {
        try! JSONSerialization.jsonObject(with: Data(s.utf8)) as! [String: Any]
    }

    func testFoldsUsageToolsAndErrors() {
        var a = DockAgents.Agent(id: "agent-a1", sessionId: "s")
        var counted: Set<String> = []
        let reply = #"{"type":"assistant","requestId":"r1","timestamp":"2026-10-21T10:00:00.000Z","message":{"id":"m1","model":"claude-opus-5-5","usage":{"input_tokens":10,"output_tokens":5,"cache_read_input_tokens":100,"cache_creation_input_tokens":20},"content":[{"type":"tool_use","name":"Edit","input":{"file_path":"/x.swift"}}]}}"#
        DockAgents.apply(line(reply), to: &a, counted: &counted)
        // The same message again (one line per content block) is not counted twice.
        DockAgents.apply(line(reply.replacingOccurrences(of: "10:00:00", with: "10:00:30")), to: &a, counted: &counted)
        DockAgents.apply(line(#"{"type":"user","message":{"content":[{"type":"tool_result","is_error":true}]}}"#), to: &a, counted: &counted)
        XCTAssertEqual(a.tokens, 135)
        XCTAssertEqual(a.context, 130)
        XCTAssertEqual(a.replies, 1)
        XCTAssertEqual(a.toolCalls, 2)
        XCTAssertEqual(a.tools["Edit"], 2)
        XCTAssertEqual(a.files, ["/x.swift"])
        XCTAssertEqual(a.toolErrors, 1)
        XCTAssertEqual(a.lastTool, "Edit: /x.swift")
        XCTAssertEqual(a.model, "claude-opus-5-5")
        XCTAssertGreaterThan(a.dollars, 0)
        XCTAssertEqual(a.lastActive!.timeIntervalSince(a.started!), 30)
    }

    func testLiveNeedsUnfinishedAndRecent() {
        var a = DockAgents.Agent(id: "agent-a1", sessionId: "s")
        a.lastActive = Date()
        XCTAssertTrue(a.live())
        a.finished = true
        XCTAssertFalse(a.live())
        a.finished = false
        a.lastActive = Date(timeIntervalSinceNow: -3600)
        XCTAssertFalse(a.live())
    }

    func testReadsTranscriptAndMeta() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let dir = root.appendingPathComponent("s1/subagents")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let transcript = root.appendingPathComponent("s1.jsonl")
        try Data().write(to: transcript)
        try Data(#"{"agentType":"Explore","description":"Find it","worktreeBranch":"wt-1","requestShape":"background","finished":false}"#.utf8)
            .write(to: dir.appendingPathComponent("agent-a1.meta.json"))
        let body = #"{"type":"assistant","timestamp":"2026-10-21T10:00:00.000Z","message":{"id":"m1","model":"claude-haiku-5-5","usage":{"input_tokens":1,"output_tokens":2},"content":[{"type":"text","text":"Found it\nsecond line"}]}}"# + "\n"
        try Data(body.utf8).write(to: dir.appendingPathComponent("agent-a1.jsonl"))
        let meter = DockAgents()
        let agents = meter.agents(transcript: transcript, sessionId: "s1")
        XCTAssertEqual(agents.count, 1)
        XCTAssertEqual(agents[0].type, "Explore")
        XCTAssertEqual(agents[0].branch, "wt-1")
        XCTAssertTrue(agents[0].background)
        XCTAssertEqual(agents[0].lastText, "Found it")
        XCTAssertEqual(agents[0].tokens, 3)
        // A second read adds nothing new.
        XCTAssertEqual(meter.agents(transcript: transcript, sessionId: "s1")[0].tokens, 3)
    }

    func testFormats() {
        XCTAssertEqual(DockAgents.shortModel("claude-opus-5-5"), "opus 5.5")
        XCTAssertEqual(DockAgents.shortModel("claude-haiku-4-5-20251001"), "haiku 4.5")
        XCTAssertEqual(DockAgents.duration(42), "42s")
        XCTAssertEqual(DockAgents.duration(3900), "1h 5m")
    }
}
