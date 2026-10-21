@testable import DockLogic
import XCTest

final class AgentConfigTests: XCTestCase {
    func testParsesFrontMatterListsBlocksAndQuotes() {
        let text = """
        ---
        name: reviewer
        description: "Reviews code: severity-rated"
        tools:
          - Read
          - Grep
        model: opus
        level: 3
        notes: |
          one
          two
        ---

        You review code.
        """
        let (fields, body) = DockAgentConfig.parse(text)
        let v = Dictionary(fields.map { ($0.key, $0.value) }, uniquingKeysWith: { a, _ in a })
        XCTAssertEqual(v["description"], "Reviews code: severity-rated")
        XCTAssertEqual(v["tools"], "Read, Grep")
        XCTAssertEqual(v["notes"], "one\ntwo")
        XCTAssertEqual(body, "You review code.")
    }

    func testSaveKeepsUnknownKeysAndRoundTrips() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("r.md")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try "---\nname: r\ndescription: x\nlevel: 3\nhooks:\n  a: b\n---\nBody\n".write(to: url, atomically: true, encoding: .utf8)
        var def = try XCTUnwrap(DockAgentConfig.load(url, source: .user))
        XCTAssertEqual(def.extra, ["level: 3", "hooks:", "  a: b"])
        def.description = "Use when: reviewing # carefully"
        def.model = "sonnet"
        def.tools = "Read, Grep"
        try DockAgentConfig.save(def)
        let again = try XCTUnwrap(DockAgentConfig.load(url, source: .user))
        XCTAssertEqual(again, def)
        XCTAssertTrue(try String(contentsOf: url, encoding: .utf8).contains("level: 3\nhooks:\n  a: b\n---"))
    }

    func testAllFindsUserProjectAndPluginAgents() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: home) }
        let fm = FileManager.default
        func put(_ path: String, _ text: String) throws {
            let url = home.appendingPathComponent(path)
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try text.write(to: url, atomically: true, encoding: .utf8)
        }
        try put(".claude/agents/mine.md", "---\nname: mine\ndescription: d\n---\nx")
        try put("proj/.git/HEAD", "")
        try put("proj/.claude/agents/local.md", "---\nname: local\ndescription: d\n---\nx")
        try fm.createDirectory(at: home.appendingPathComponent("proj/src"), withIntermediateDirectories: true)
        try put("plug/agents/helper.md", "---\nname: helper\ndescription: d\n---\nx")
        try put(".claude/plugins/installed_plugins.json",
                #"{"plugins":{"tools@market":[{"installPath":"\#(home.path)/plug"}]}}"#)
        let defs = DockAgentConfig.all(projects: [home.appendingPathComponent("proj/src").path], home: home)
        XCTAssertEqual(defs.filter { $0.source != .builtIn }.map(\.agentType), ["mine", "local", "tools:helper"])
        XCTAssertEqual(defs.first { $0.name == "local" }?.source, .project(home.appendingPathComponent("proj").path))
        XCTAssertTrue(defs.first { $0.name == "mine" }!.editable)
        XCTAssertFalse(defs.first { $0.name == "helper" }!.editable)
    }

    func testSlugAndQuoting() {
        XCTAssertEqual(DockAgentConfig.slug("Code Reviewer!"), "code-reviewer")
        XCTAssertEqual(DockAgentConfig.yaml("plain words"), "plain words")
        XCTAssertEqual(DockAgentConfig.yaml("a: b"), "\"a: b\"")
    }
}
