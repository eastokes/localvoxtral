import XCTest
@testable import localvoxtral

#if DEBUG
@MainActor
final class TextInsertionServiceRealtimeInsertionTests: XCTestCase {
    func testRealtimeFlush_activeModifiersAndKeyboardSuccess_clearsPendingText() {
        let service = TextInsertionService()
        service.debugConfigureInsertionHooks(
            unicodePoster: { _ in true },
            modifierStateReader: { true },
            accessibilityInserter: { _, _ in false }
        )

        service.enqueueRealtimeInsertion("hello")

        XCTAssertFalse(service.hasPendingInsertionText)
        let snapshot = service.debugInsertionSnapshot()
        XCTAssertEqual(snapshot.pendingRealtimeInsertionText, "")
        XCTAssertEqual(snapshot.keyboardFallbackSuccessCount, 1)
        XCTAssertEqual(snapshot.activeModifierFallbackCount, 1)
        XCTAssertEqual(snapshot.axInsertionSuccessCount, 0)
    }

    func testRealtimeFlush_activeModifiersAndInsertionFailure_keepsPendingTextForRetry() {
        let service = TextInsertionService()
        service.debugConfigureInsertionHooks(
            unicodePoster: { _ in false },
            modifierStateReader: { true },
            accessibilityInserter: { _, _ in false }
        )

        service.enqueueRealtimeInsertion("hello")

        XCTAssertTrue(service.hasPendingInsertionText)
        let snapshot = service.debugInsertionSnapshot()
        XCTAssertEqual(snapshot.pendingRealtimeInsertionText, "hello")
        XCTAssertEqual(snapshot.keyboardFallbackSuccessCount, 0)
        XCTAssertEqual(snapshot.activeModifierFallbackCount, 1)
        XCTAssertEqual(snapshot.axInsertionSuccessCount, 0)
    }

    func testPostReturnKey_usesPreferredPID() {
        let service = TextInsertionService()
        var observedPID: pid_t?
        service.debugConfigureInsertionHooks(
            returnKeyPoster: { preferredPID in
                observedPID = preferredPID
                return true
            }
        )

        XCTAssertTrue(service.postReturnKey(preferredAppPID: 123))
        XCTAssertEqual(observedPID, 123)
    }

}
#endif
