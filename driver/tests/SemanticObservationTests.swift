import XCTest

final class SemanticObservationTests: XCTestCase {
    private func node(_ label: String, _ children: Int = 0) -> SemanticDOM.Element {
        SemanticDOM.Element(label: label, traits: [children > 0 ? "Cell" : "Button"], children: children, rect: [0, 0, 100, 30])
    }

    func testExactReconstructionAcrossInsertionsDuplicatesMovesAndStateChanges() throws {
        let store = SemanticDOM.Store()
        let initial = [node("Root", 40)] + (0..<40).map { node("Item \($0)") }
        var previous = store.observe(app: "Fixture", size: [390, 844], elements: initial, diff: false, since: "")
        var reconstructed = previous.lines
        var cases: [[SemanticDOM.Element]] = []
        var repeated = initial
        repeated[5].label = "Duplicate"; repeated[7].label = "Duplicate"
        cases.append(repeated)
        var inserted = repeated
        inserted[0].children += 1; inserted.insert(node("New"), at: 3)
        cases.append(inserted)
        var moved = inserted
        moved.swapAt(3, 12); moved[6].children = 1; moved[0].children -= 1
        cases.append(moved)
        var changed = moved
        changed[5].traits += ["disabled", "selected", "focused"]
        changed[5].value = "42"; changed[5].hint = "A hint"; changed[5].accessibilityLabel = "Native label"
        changed[9].label = "Repeated\ntext=5 [Button]:"
        cases.append(changed)
        cases += [[], initial]
        for elements in cases {
            let output = store.observe(app: "Fixture", size: [390, 844], elements: elements, diff: true, since: previous.revision)
            let wire = try JSONDecoder().decode(SemanticDOM.Observation.self, from: JSONEncoder().encode(output))
            reconstructed = try XCTUnwrap(wire.applying(to: reconstructed))
            XCTAssertEqual(reconstructed, SemanticDOM.lines(elements))
            previous = output
        }
    }

    func testGeometryIsSeparateAndStaleContinuationOrChangedAppReturnsFull() throws {
        let store = SemanticDOM.Store()
        var elements = (0..<30).map { node("Item \($0)") }
        let first = store.observe(app: "Fixture", size: [390, 844], elements: elements, diff: false, since: "")
        elements[5].rect = [0, 50, 100, 30]
        let moved = store.observe(app: "Fixture", size: [390, 844], elements: elements, diff: true, since: first.revision)
        XCTAssertTrue(moved.layoutChanged)
        XCTAssertTrue(moved.added.isEmpty && moved.removed.isEmpty && moved.lines.isEmpty)
        for (app, size, since) in [("Fixture", [390.0, 844.0], first.revision),
                                   ("Other", [390.0, 844.0], moved.revision),
                                   ("Fixture", [844.0, 390.0], moved.revision)] {
            let output = store.observe(app: app, size: size, elements: elements, diff: true, since: since)
            XCTAssertEqual(output.lines.count, elements.count)
        }
        store.reset()
        let restarted = store.observe(app: "Fixture", size: [390, 844], elements: elements, diff: true, since: moved.revision)
        XCTAssertEqual(restarted.lines.count, elements.count)
    }
}
