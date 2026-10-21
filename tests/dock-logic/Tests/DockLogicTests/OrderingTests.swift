@testable import DockLogic
import XCTest

final class OrderingTests: XCTestCase {
    struct R { var key: String; var name: String; var status: DockStatus; var since: Double? = nil
        var place: [Int]; var pinned = false; var folder: String? = nil; var tag: DockTag? = nil }

    let rows = [
        R(key: "a", name: "zeta", status: .running, place: [0, 0]),
        R(key: "b", name: "Alpha", status: .idle, since: 100, place: [0, 1]),
        R(key: "c", name: "mid", status: .waiting, place: [1, 0]),
        R(key: "d", name: "beta", status: .unread, since: 200, place: [0, 2]),
    ]

    func keys(_ order: DockOrdering.Order, _ rows: [R], manual: [String] = []) -> [String] {
        DockOrdering.sorted(rows, order: order, manual: manual) {
            DockOrdering.Facts(key: $0.key, name: $0.name, status: $0.status,
                               since: $0.since.map(Date.init(timeIntervalSince1970:)), place: $0.place, pinned: $0.pinned)
        }.map(\.key)
    }

    func testAlphabeticalIgnoresCase() { XCTAssertEqual(keys(.alphabetical, rows), ["b", "d", "c", "a"]) }
    func testUrgencyNeedsYouFirstRecentIdleNextRunningLast() { XCTAssertEqual(keys(.urgency, rows), ["c", "d", "b", "a"]) }
    func testRunningFirst() { XCTAssertEqual(keys(.runningFirst, rows), ["a", "c", "d", "b"]) }
    func testTabOrder() { XCTAssertEqual(keys(.tabs, rows), ["a", "b", "d", "c"]) }

    func testPinnedAlwaysOnTop() {
        var r = rows
        r[0].pinned = true
        XCTAssertEqual(keys(.alphabetical, r).first, "a")
        XCTAssertEqual(keys(.urgency, r).first, "a")
    }

    func testManualOrderThenUnknownInTabOrder() {
        XCTAssertEqual(keys(.manual, rows, manual: ["c", "a"]), ["c", "a", "b", "d"])
    }

    func testMoveStartsFromWhatIsShown() {
        let moved = DockOrdering.move("d", before: "b", visible: ["b", "d", "c", "a"], manual: [])
        XCTAssertEqual(moved, ["d", "b", "c", "a"])
    }

    func testMoveToEndAndKeepsClosedRows() {
        let moved = DockOrdering.move("b", before: nil, visible: ["b", "c"], manual: ["x", "b", "c"])
        XCTAssertEqual(moved, ["c", "b", "x"])
    }

    func testGroupByFolderPinnedFirstOtherLast() {
        var r = rows
        r[0].folder = "work"; r[1].folder = "Play"; r[2].pinned = true; r[2].folder = "work"
        let g = DockOrdering.grouped(r, by: .folder, pinned: \.pinned, folder: \.folder, tag: \.tag)
        XCTAssertEqual(g.map(\.title), ["Pinned", "Play", "work", "Other"])
        XCTAssertEqual(g.map { $0.items.map(\.key) }, [["c"], ["b"], ["a"], ["d"]])
    }

    func testGroupByColourInTagOrder() {
        var r = rows
        r[0].tag = .blue; r[1].tag = .red
        let g = DockOrdering.grouped(r, by: .colour, pinned: \.pinned, folder: \.folder, tag: \.tag)
        XCTAssertEqual(g.map(\.title), ["Red", "Blue", "No colour"])
    }

    func testNoGroupingIsOneUntitledGroup() {
        let g = DockOrdering.grouped(rows, by: .none, pinned: \.pinned, folder: \.folder, tag: \.tag)
        XCTAssertEqual(g.count, 1)
        XCTAssertEqual(g[0].title, "")
    }

    func testFolderOfProject() {
        XCTAssertEqual(DockOrdering.folder(ofProject: "/Users/me/code/acme/api"), "acme")
        XCTAssertEqual(DockOrdering.folder(ofProject: "/Users/me/code/acme/api/.claude/worktrees/agent-1"), "acme")
        XCTAssertNil(DockOrdering.folder(ofProject: "/api"))
    }
}
