@testable import DockLogic
import XCTest

final class CostTests: XCTestCase {
    func line(_ model: String, id: String, usage: String, speed: String = "standard") -> String {
        #"{"type":"assistant","requestId":"req_\#(id)","message":{"id":"msg_\#(id)","model":"\#(model)","usage":{\#(usage),"speed":"\#(speed)"}}}"#
    }

    func testPricesEveryTokenClass() throws {
        // Opus 5.5: $4 in, $20 out, $0.20 cache read, 1h write 2x input.
        let l = line("claude-opus-5-5", id: "1", usage: #""input_tokens":1000000,"output_tokens":1000000,"cache_read_input_tokens":1000000,"cache_creation":{"ephemeral_1h_input_tokens":1000000,"ephemeral_5m_input_tokens":1000000}"#)
        let c = try XCTUnwrap(DockCost.cost(ofLine: Data(l.utf8)))
        XCTAssertEqual(c.dollars, 4 + 20 + 0.20 + 8 + 5, accuracy: 1e-9)
    }

    func testFastModeIsDouble() throws {
        let l = line("claude-sonnet-5-5", id: "2", usage: #""input_tokens":1000000"#, speed: "fast")
        XCTAssertEqual(try XCTUnwrap(DockCost.cost(ofLine: Data(l.utf8))).dollars, 4, accuracy: 1e-9)
    }

    func testUnknownModelAndUserLinesAreNotPriced() {
        XCTAssertNil(DockCost.cost(ofLine: Data(line("gpt-x", id: "3", usage: #""input_tokens":5"#).utf8)))
        XCTAssertNil(DockCost.cost(ofLine: Data(#"{"type":"user","message":{"usage":{}}}"#.utf8)))
    }

    func testReadsIncrementallyAndCountsEachMessageOnce() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("s.jsonl")
        let one = line("claude-haiku-4-5", id: "a", usage: #""input_tokens":1000000"#)
        try (one + "\n" + one + "\n").write(to: file, atomically: true, encoding: .utf8)
        let meter = DockCost()
        XCTAssertEqual(meter.dollars(transcript: file), 1, accuracy: 1e-9)

        let h = try FileHandle(forWritingTo: file)
        try h.seekToEnd()
        let two = line("claude-haiku-4-5", id: "b", usage: #""output_tokens":1000000"#)
        h.write(Data((two + "\n" + "{\"half").utf8))
        try h.close()
        XCTAssertEqual(meter.dollars(transcript: file), 6, accuracy: 1e-9)

        // Subagents count toward their session.
        let sub = dir.appendingPathComponent("s/subagents")
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        try (line("claude-haiku-4-5", id: "c", usage: #""input_tokens":2000000"#) + "\n")
            .write(to: sub.appendingPathComponent("agent-1.jsonl"), atomically: true, encoding: .utf8)
        XCTAssertEqual(meter.dollars(transcript: file), 8, accuracy: 1e-9)
    }

    func testFormat() {
        XCTAssertEqual(DockCost.format(0.4), "$0.40")
        XCTAssertEqual(DockCost.format(128.4), "$128")
    }
}
