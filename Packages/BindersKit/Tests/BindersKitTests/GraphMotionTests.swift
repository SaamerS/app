import XCTest
@testable import BindersKit

/// The graph holds still once it has settled: its hover highlight lands on its end, a layout can be run to rest at once
/// (Reduce Motion), and new data carries on from the old layout instead of blooming again.
final class GraphMotionTests: XCTestCase {
    private func sample(_ count: Int = 12) -> ([GraphNode], [GraphEdge]) {
        let nodes = (0..<count).map { GraphNode(id: "n\($0)", weight: Double($0 % 3 + 1)) }
        let edges = (1..<count).map { GraphEdge(from: "n\($0 < count / 2 ? 0 : count / 2)", to: "n\($0)") }
        return (nodes, edges)
    }

    func testTheHighlightLandsAndStopsEasing() {
        var highlight = GraphHighlight()
        XCTAssertFalse(highlight.isEasing(toward: nil), "nothing to do with nothing hovered")
        XCTAssertTrue(highlight.isEasing(toward: "a"))
        var steps = 0
        while highlight.isEasing(toward: "a"), steps < 200 {
            highlight.step(toward: "a")
            steps += 1
        }
        XCTAssertEqual(highlight["a"], 1, "fully lit, exactly")
        XCTAssertLessThan(steps, 30, "in about a third of a second")
        XCTAssertFalse(highlight.isEasing(toward: "a"), "and resting on a node needs no more frames")

        // Moving to another node: one eases in while the other fades out and is dropped.
        steps = 0
        while highlight.isEasing(toward: "b"), steps < 200 {
            highlight.step(toward: "b")
            steps += 1
            XCTAssertLessThanOrEqual(highlight["a"], 1)
        }
        XCTAssertEqual(highlight.amounts, ["b": 1])
        steps = 0
        while highlight.isEasing(toward: nil), steps < 200 {
            highlight.step(toward: nil)
            steps += 1
        }
        XCTAssertEqual(highlight.amounts, [:])
        XCTAssertLessThan(steps, 30)
    }

    func testSnappingIsInstant() {
        var highlight = GraphHighlight()
        highlight.snap(to: "a")
        XCTAssertEqual(highlight.amounts, ["a": 1])
        XCTAssertFalse(highlight.isEasing(toward: "a"))
        highlight.snap(to: nil)
        XCTAssertFalse(highlight.isEasing(toward: nil))
    }

    func testSettleRunsTheLayoutToRest() {
        let (nodes, edges) = sample()
        var stepped = GraphSimulation(nodes: nodes, edges: edges)
        for _ in 0..<400 { stepped.step() }
        var settled = GraphSimulation(nodes: nodes, edges: edges)
        settled.settle()
        XCTAssertTrue(settled.isSettled)
        XCTAssertEqual(settled.positions, stepped.positions, "the same picture the animation would have ended on")
        // A lone node, warmed up, doesn't keep it busy.
        var one = GraphSimulation(nodes: [GraphNode(id: "a", weight: 1)], edges: [])
        one.reheat(1)
        one.settle()
        XCTAssertTrue(one.isSettled)
    }

    func testTheSameGraphStaysWhereItWas() {
        let (nodes, edges) = sample()
        var before = GraphSimulation(nodes: nodes, edges: edges)
        before.settle()
        var after = GraphSimulation(nodes: nodes, edges: edges)
        after.carryOver(from: before)
        XCTAssertEqual(after.positions, before.positions)
        XCTAssertTrue(after.isSettled, "nothing changed, so nothing moves")
    }

    func testNewDataMovesThePictureALittle() {
        let (nodes, edges) = sample()
        var before = GraphSimulation(nodes: nodes, edges: edges)
        before.settle()
        let added = nodes + [GraphNode(id: "new", weight: 1)]
        var after = GraphSimulation(nodes: added, edges: edges + [GraphEdge(from: "n3", to: "new")])
        after.carryOver(from: before)
        XCTAssertFalse(after.isSettled)
        XCTAssertLessThan(after.alpha, 0.5, "a gentle nudge, not a new bloom")
        for (offset, node) in nodes.enumerated() {
            XCTAssertEqual(after.positions[after.index(of: node.id)!], before.positions[offset], "\(node.id) keeps its place")
        }
        let neighbour = before.positions[3], placed = after.positions[after.index(of: "new")!]
        XCTAssertLessThan(hypot(placed.x - neighbour.x, placed.y - neighbour.y), 0.05, "the new node starts by the node it links to")
        after.settle()
        // Settling again moves the old nodes only a little.
        let drift = nodes.indices.map { hypot(after.positions[$0].x - before.positions[$0].x, after.positions[$0].y - before.positions[$0].y) }
        XCTAssertLessThan(drift.reduce(0, +) / Double(drift.count), 0.1)
    }

    func testAGraphWithNothingInCommonBloomsAsNew() {
        let (nodes, edges) = sample()
        var before = GraphSimulation(nodes: nodes, edges: edges)
        before.settle()
        let others = (0..<5).map { GraphNode(id: "m\($0)", weight: 1) }
        var after = GraphSimulation(nodes: others, edges: [GraphEdge(from: "m0", to: "m1")])
        let seeded = after.positions
        after.carryOver(from: before)
        XCTAssertEqual(after.alpha, 1)
        XCTAssertEqual(after.positions, seeded)
    }
}
