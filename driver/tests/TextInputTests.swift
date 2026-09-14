import XCTest

final class TextInputTests: XCTestCase {
    func testSelectionUsesUnmodifiedUTF16AndDisambiguatingContext() throws {
        let text = "  👨‍👩‍👧 e\u{301} cat / cat  "
        let range = try textSelectionRange(in: text, text: "cat", prefix: "/ ", suffix: "  ", selectionType: "text")
        let expected = (text as NSString).range(of: "cat", options: .backwards)
        XCTAssertEqual(range, expected)
        XCTAssertEqual(try textSelectionRange(in: text, text: "cat", prefix: "/ ", suffix: "  ", selectionType: "cursor_before"), NSRange(location: expected.location, length: 0))
        XCTAssertEqual(try textSelectionRange(in: text, text: "cat", prefix: "/ ", suffix: "  ", selectionType: "cursor_after"), NSRange(location: NSMaxRange(expected), length: 0))
        XCTAssertThrowsError(try textSelectionRange(in: text, text: "cat", prefix: "", suffix: "", selectionType: "text"))
        XCTAssertThrowsError(try textSelectionRange(in: text, text: "missing", prefix: "", suffix: "", selectionType: "text"))
    }

    func testChordKeepsControlAndCommandDistinctAndRejectsUnknownModifiers() throws {
        XCTAssertEqual(try KeyboardChord.parse("ctrl+shift+a").modifiers, XCUIElement.KeyModifierFlags.control.union(.shift).rawValue)
        XCTAssertEqual(try KeyboardChord.parse("super+a").modifiers, XCUIElement.KeyModifierFlags.command.rawValue)
        XCTAssertThrowsError(try KeyboardChord.parse("control+"))
        XCTAssertThrowsError(try KeyboardChord.parse("bogus+a"))
    }
}
