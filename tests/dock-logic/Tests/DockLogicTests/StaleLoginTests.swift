import XCTest
@testable import DockLogic

final class StaleLoginTests: XCTestCase {
    func testOnlySessionsStartedBeforeTheLogin() {
        let login = Date(timeIntervalSince1970: 1_000_000)
        let got = DockStaleLogin.stale([("old", login.addingTimeInterval(-3600)),
                                         ("new", login.addingTimeInterval(60)),
                                         ("same moment", login.addingTimeInterval(-2))], loginAt: login)
        XCTAssertEqual(got, ["old"])
    }

    func testReadsThisProcessAndTheLogin() {
        let me = DockStaleLogin.started(getpid())
        XCTAssertNotNil(me)
        XCTAssertLessThan(me!.timeIntervalSinceNow, 1)
        XCTAssertNil(DockStaleLogin.started(-1))
        // A machine running tests has a login window, started before this test.
        if let login = DockStaleLogin.loginAt() { XCTAssertLessThan(login, me!) }
    }
}
