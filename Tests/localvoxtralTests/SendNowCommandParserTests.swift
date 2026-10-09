import XCTest
@testable import localvoxtral

final class SendNowCommandParserTests: XCTestCase {
    func testParse_plainTextInsertsText() {
        XCTAssertEqual(
            SendNowCommandParser.parse("explain the error", triggerPhrases: ["send now"]),
            .insertText("explain the error")
        )
    }

    func testParse_sendNowOnlyPressesReturn() {
        XCTAssertEqual(
            SendNowCommandParser.parse("send now", triggerPhrases: ["send now"]),
            .pressReturn
        )
        XCTAssertEqual(
            SendNowCommandParser.parse("Send now.", triggerPhrases: ["send now"]),
            .pressReturn
        )
    }

    func testParse_trailingSendNowInsertsTextAndPressesReturn() {
        XCTAssertEqual(
            SendNowCommandParser.parse(
                "show me the failing test send now",
                triggerPhrases: ["send now"]
            ),
            .insertTextAndPressReturn("show me the failing test")
        )
    }

    func testParse_trailingSendNowStripsPunctuation() {
        XCTAssertEqual(
            SendNowCommandParser.parse(
                "run the focused test, send now.",
                triggerPhrases: ["send now"]
            ),
            .insertTextAndPressReturn("run the focused test")
        )
    }

    func testParse_emptyTextDoesNothing() {
        XCTAssertEqual(SendNowCommandParser.parse("   ", triggerPhrases: ["send now"]), .none)
    }

    func testParse_sendNowInsideWordDoesNotTriggerCommand() {
        XCTAssertEqual(
            SendNowCommandParser.parse("resend now", triggerPhrases: ["send now"]),
            .insertText("resend now")
        )
    }

    func testParse_customTriggerPhraseIsSupported() {
        XCTAssertEqual(
            SendNowCommandParser.parse(
                "run the focused test ship it",
                triggerPhrases: ["ship it"]
            ),
            .insertTextAndPressReturn("run the focused test")
        )
    }

    func testParse_blankTriggerPhraseDisablesCommandParsing() {
        XCTAssertEqual(
            SendNowCommandParser.parse("send now", triggerPhrases: ["   "]),
            .insertText("send now")
        )
    }
}
