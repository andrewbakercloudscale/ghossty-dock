import XCTest
@testable import DockCore

final class GhosttyConfigTests: XCTestCase {
    let base = "font-size = 14\n# macos-hidden = always\ntheme = x\n"

    func testOnAddsOneLineAndOffRemovesIt() {
        XCTAssertFalse(GhosttyConfig.isHidden(base))
        let on = GhosttyConfig.setHidden(true, in: base)
        XCTAssertTrue(GhosttyConfig.isHidden(on))
        XCTAssertEqual(GhosttyConfig.setHidden(true, in: on), on, "turning it on twice adds nothing")
        let off = GhosttyConfig.setHidden(false, in: on)
        XCTAssertFalse(GhosttyConfig.isHidden(off))
        XCTAssertEqual(off, base, "off restores the file, comments included")
    }

    func testLastLineWinsAndOffRemovesTheUsersOwnLineToo() {
        let text = "macos-hidden = always\nmacos-hidden = never\n"
        XCTAssertFalse(GhosttyConfig.isHidden(text))
        XCTAssertTrue(GhosttyConfig.isHidden("macos-hidden=never\n macos-hidden =  always \n"))
        XCTAssertFalse(GhosttyConfig.setHidden(false, in: "a = 1\nmacos-hidden = always\n").contains("macos-hidden"))
    }
}
