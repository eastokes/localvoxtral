import XCTest
@testable import localvoxtral

final class GhosttyAgentCommandParserTests: XCTestCase {
    func testParse_plainTextInsertsText() {
        XCTAssertEqual(
            GhosttyAgentCommandParser.parse("explain the error"),
            .insertText("explain the error")
        )
    }

    func testParse_sendNowOnlyPressesReturn() {
        XCTAssertEqual(
            GhosttyAgentCommandParser.parse("send now"),
            .pressReturn(deleteCharacterCount: 8)
        )
        XCTAssertEqual(
            GhosttyAgentCommandParser.parse("Send now."),
            .pressReturn(deleteCharacterCount: 9)
        )
    }

    func testParse_trailingSendNowInsertsTextAndPressesReturn() {
        XCTAssertEqual(
            GhosttyAgentCommandParser.parse("show me the failing test send now"),
            .insertTextAndPressReturn("show me the failing test", deleteCharacterCount: 9)
        )
    }

    func testParse_trailingSendNowStripsPunctuation() {
        XCTAssertEqual(
            GhosttyAgentCommandParser.parse("run the focused test, send now."),
            .insertTextAndPressReturn("run the focused test", deleteCharacterCount: 11)
        )
    }

    func testParse_emptyTextDoesNothing() {
        XCTAssertEqual(GhosttyAgentCommandParser.parse("   "), .none)
    }

    func testParse_sendNowInsideWordDoesNotTriggerCommand() {
        XCTAssertEqual(
            GhosttyAgentCommandParser.parse("resend now"),
            .insertText("resend now")
        )
    }
}
