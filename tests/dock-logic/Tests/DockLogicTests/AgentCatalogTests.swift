@testable import DockLogic
import XCTest

final class AgentCatalogTests: XCTestCase {
    private func agent(_ raw: String, id: String = "agency/ui-designer", slug: String = "ui-designer",
                       model: String? = nil) -> DockCatalogAgent {
        DockCatalogAgent(id: id, name: "UI Designer", slug: slug, description: "Designs UIs", oneLiner: "Designs UIs",
                         category: "design", source: "agency", emoji: nil, vibe: nil, icon: nil, model: model,
                         attribution: "", risk: [], allTools: true, raw: raw)
    }

    func testRenderNamesBySlugAndSwapsDatedModels() {
        let a = agent("---\nname: UI Designer\ndescription: Designs UIs\nmodel: claude-sonnet-4-20250514\n---\n\nYou design.\n",
                      model: "claude-sonnet-4-20250514")
        XCTAssertEqual(DockAgentInstall.render(a),
                       "---\nname: ui-designer\ndescription: Designs UIs\nmodel: sonnet\n---\n\nYou design.\n")
    }

    func testRenderKeepsAliasesAndDropsBlockNameLines() {
        let a = agent("---\nname: >\n  UI\n  Designer\nmodel: opus\n---\nBody\n", model: "opus")
        XCTAssertEqual(DockAgentInstall.render(a), "---\nname: ui-designer\nmodel: opus\n---\nBody\n")
        XCTAssertEqual(DockAgentInstall.family("inherit"), "inherit")
        XCTAssertEqual(DockAgentInstall.family(nil), nil)
    }

    func testStateAddRemove() throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        DockAgentInstall.ledgerURL = tmp.appendingPathComponent("added.json")
        let dir = tmp.appendingPathComponent("agents")
        let a = agent("---\nname: UI Designer\n---\nBody\n")
        XCTAssertEqual(DockAgentInstall.state(a, in: dir), .notAdded)
        try DockAgentInstall.add(a, in: dir)
        XCTAssertEqual(DockAgentInstall.state(a, in: dir), .added)
        XCTAssertEqual(DockAgentInstall.addedIds(), [a.id])
        try "changed".write(to: DockAgentInstall.file(a, in: dir), atomically: true, encoding: .utf8)
        XCTAssertEqual(DockAgentInstall.state(a, in: dir), .edited)
        // Someone else's file with the same name is not ours to replace.
        let other = agent("---\nname: x\n---\n", id: "voltagent/ui-designer")
        XCTAssertEqual(DockAgentInstall.state(other, in: dir), .clash)
        try DockAgentInstall.remove(a, in: dir)
        XCTAssertEqual(DockAgentInstall.state(a, in: dir), .notAdded)
        try? FileManager.default.removeItem(at: tmp)
    }

    func testShippedCatalogueLoadsAndSearches() throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("../../../../Resources/agent-catalog/catalog.json.deflate").standardized
        let catalog = try XCTUnwrap(DockAgentCatalog.load(url))
        XCTAssertGreaterThan(catalog.agents.count, 500)
        let hits = catalog.search("code reviewer")
        XCTAssertFalse(hits.isEmpty)
        XCTAssertTrue(hits[0].slug.contains("reviewer"), hits[0].slug)
        XCTAssertTrue(catalog.search("zzzqqq").isEmpty)
        XCTAssertEqual(Set(catalog.agents.map(\.slug)).count, catalog.agents.count, "slugs are file names")
    }
}
