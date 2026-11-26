import XCTest
@testable import DockLogic

/// The app's session save looks at every process on the Mac, so it must not
/// run every tick: only when the sessions change, or once a heartbeat.
final class SaveScheduleTests: XCTestCase {
    let t0 = Date(timeIntervalSince1970: 1_000_000)
    let a = DockSaveSchedule.fingerprint([(key: "t1", sessionId: "s1", project: "/p", pid: 10)])

    func testTheFirstSaveIsDue() {
        XCTAssertTrue(DockSaveSchedule().due(a, now: t0))
    }

    func testNothingChangedIsNotSavedEachTick() {
        var s = DockSaveSchedule()
        s.saved(a, at: t0)
        var saves = 0
        // A minute of ticks with nothing changing: none, then the heartbeat.
        for i in 1...6 {
            let now = t0.addingTimeInterval(Double(i) * DockSaveSchedule.tick)
            if s.due(a, now: now) { saves += 1; s.saved(a, at: now) }
        }
        XCTAssertEqual(saves, 1)
    }

    func testAChangeIsSavedAtOnce() {
        var s = DockSaveSchedule()
        s.saved(a, at: t0)
        let b = DockSaveSchedule.fingerprint([(key: "t1", sessionId: "s2", project: "/p", pid: 10)])
        XCTAssertTrue(s.due(b, now: t0.addingTimeInterval(DockSaveSchedule.tick)))
        let closed = DockSaveSchedule.fingerprint([])
        XCTAssertTrue(s.due(closed, now: t0.addingTimeInterval(DockSaveSchedule.tick)))
    }

    func testOrderDoesNotCount() {
        let x = DockSaveSchedule.fingerprint([(key: "a", sessionId: "1", project: nil, pid: nil),
                                              (key: "b", sessionId: "2", project: nil, pid: nil)])
        let y = DockSaveSchedule.fingerprint([(key: "b", sessionId: "2", project: nil, pid: nil),
                                              (key: "a", sessionId: "1", project: nil, pid: nil)])
        XCTAssertEqual(x, y)
    }

    /// The budget: a save at most once a minute while nothing changes.
    func testTheHeartbeatIsAMinuteOrMore() {
        XCTAssertGreaterThanOrEqual(DockSaveSchedule.heartbeat, 60)
        XCTAssertGreaterThanOrEqual(DockSaveSchedule.tick, 5)
    }
}
