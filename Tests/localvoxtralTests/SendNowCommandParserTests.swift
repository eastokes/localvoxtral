import XCTest
@testable import localvoxtral

final class SendNowCommandParserTests: XCTestCase {
    func testParse_plainTextInsertsText() {
        XCTAssertEqual(
            SendNowCommandParser.parse("explain the error", triggerPhrase: "send now"),
            .insertText("explain the error")
        )
    }

    func testParse_sendNowOnlyPressesReturn() {
        XCTAssertEqual(
            SendNowCommandParser.parse("send now", triggerPhrase: "send now"),
            .pressReturn(deleteCharacterCount: 8)
        )
        XCTAssertEqual(
            SendNowCommandParser.parse("Send now.", triggerPhrase: "send now"),
            .pressReturn(deleteCharacterCount: 9)
        )
    }

    func testParse_trailingSendNowInsertsTextAndPressesReturn() {
        XCTAssertEqual(
            SendNowCommandParser.parse(
                "show me the failing test send now",
                triggerPhrase: "send now"
            ),
            .insertTextAndPressReturn("show me the failing test", deleteCharacterCount: 9)
        )
    }

    func testParse_trailingSendNowStripsPunctuation() {
        XCTAssertEqual(
            SendNowCommandParser.parse(
                "run the focused test, send now.",
                triggerPhrase: "send now"
            ),
            .insertTextAndPressReturn("run the focused test", deleteCharacterCount: 11)
        )
    }

    func testParse_emptyTextDoesNothing() {
        XCTAssertEqual(SendNowCommandParser.parse("   ", triggerPhrase: "send now"), .none)
    }

    func testParse_sendNowInsideWordDoesNotTriggerCommand() {
        XCTAssertEqual(
            SendNowCommandParser.parse("resend now", triggerPhrase: "send now"),
            .insertText("resend now")
        )
    }

    func testParse_customTriggerPhraseIsSupported() {
        XCTAssertEqual(
            SendNowCommandParser.parse(
                "run the focused test ship it",
                triggerPhrase: "ship it"
            ),
            .insertTextAndPressReturn("run the focused test", deleteCharacterCount: 8)
        )
    }

    func testParse_blankTriggerPhraseDisablesCommandParsing() {
        XCTAssertEqual(
            SendNowCommandParser.parse("send now", triggerPhrase: "   "),
            .insertText("send now")
        )
    }
}
