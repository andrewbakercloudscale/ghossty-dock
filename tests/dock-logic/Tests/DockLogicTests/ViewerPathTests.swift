@testable import DockLogic
import XCTest

final class ViewerPathTests: XCTestCase {
    private var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("plans"),
                                                withIntermediateDirectories: true)
        try "# Plan".write(to: folder.appendingPathComponent("plans/plan.md"), atomically: true, encoding: .utf8)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    private var plan: String { folder.appendingPathComponent("plans/plan.md").path }

    func testAFileThatIsThereIsLeftAlone() {
        XCTAssertEqual(DockViewerPath.located(URL(filePath: plan), in: nil).path, plan)
    }

    func testAFullStopEndingTheSentenceIsDropped() {
        XCTAssertEqual(DockViewerPath.located(URL(filePath: plan + "."), in: nil).path, plan)
        XCTAssertEqual(DockViewerPath.located(URL(filePath: plan + "`),"), in: nil).path, plan)
    }

    func testARelativeNameIsFoundInTheTerminalsFolder() {
        let url = URL(filePath: "plans/plan.md.", relativeTo: URL(filePath: "/"))
        XCTAssertEqual(DockViewerPath.located(url, in: folder.path).path, plan)
    }

    func testANameThatIsNowhereComesBackAsItWas() {
        let url = URL(filePath: folder.path + "/nothing.md.")
        XCTAssertEqual(DockViewerPath.located(url, in: folder.path), url)
        let web = URL(string: "https://example.com/a.")!
        XCTAssertEqual(DockViewerPath.located(web, in: folder.path), web)
    }
}
