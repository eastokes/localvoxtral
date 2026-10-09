import Foundation
import XCTest
@testable import localvoxtral

#if DEBUG
@MainActor
final class SendNowViewModelTests: XCTestCase {

    private func makeViewModel(
        selectedApps: Set<SendNowTargetApp> = [.ghostty]
    ) -> (DictationViewModel, MockOverlayCoordinator, Insertions) {
        let settings = makeSettings(outputMode: .liveAutoPaste)
        settings.sendNowCommandEnabled = true
        for app in SendNowTargetApp.allCases {
            settings.setSendNowTargetApp(app, isSelected: selectedApps.contains(app))
        }
        let coordinator = MockOverlayCoordinator()
        coordinator.commitTargetAppPID = 123
        let viewModel = DictationViewModel(
            settings: settings,
            overlayBufferCoordinator: coordinator,
            startRuntimeServices: false
        )
        retainForTestProcessLifetime(viewModel)
        viewModel.isDictating = true
        viewModel.session.sessionOutputMode = .liveAutoPaste
        viewModel.dependencies.bundleIdentifier = { pid in
            pid == 123 ? "com.mitchellh.ghostty" : "com.example.editor"
        }
        viewModel.session.preCapturedSessionTargetVerdict = .init(
            decision: .init(isTerminalLike: true, reason: .bundleMatch),
            secureKeyboardEntryEnabled: false
        )
        viewModel.session.applyPreCapturedSessionTargetVerdict()
        viewModel.textInsertion.debugSetAccessibilityTrusted(true)
        viewModel.textInsertion.beginLiveReplacementSession(
            dictionary: ReplacementDictionary(entries: []),
            preferredAppPID: 123,
            isTerminalLikeTarget: true
        )

        let insertions = Insertions()
        viewModel.textInsertion.debugConfigureInsertionHooks(
            unicodePoster: { text in
                insertions.text.append(text)
                insertions.insertionPIDs.append(insertions.frontmostPID)
                return true
            },
            modifierStateReader: { false },
            accessibilityInserter: { _, _ in false },
            returnKeyPoster: { pid in
                insertions.returnPIDs.append(pid)
                return true
            },
            frontmostPIDReader: { insertions.frontmostPID }
        )
        TerminalTargetDetector.debugSecureEventInputOverride = { false }
        addTeardownBlock { @MainActor in
            TerminalTargetDetector.debugSecureEventInputOverride = nil
        }
        return (viewModel, coordinator, insertions)
    }

    func testSelectedTerminalWithholdsPartialsAndSubmitsFinalizedBodyOnce() {
        let (viewModel, _, insertions) = makeViewModel()

        viewModel.session.handle(event: .partialTranscript("run the focused test send now"))
        XCTAssertEqual(insertions.text, [])
        XCTAssertEqual(insertions.returnPIDs, [])

        viewModel.session.handle(event: .finalTranscript("run the focused test send now"))
        XCTAssertEqual(insertions.text.joined(), "run the focused test")
        XCTAssertEqual(insertions.insertionPIDs, [123])
        XCTAssertEqual(insertions.returnPIDs, [123])

        viewModel.session.handle(event: .finalTranscript("run the focused test send now"))
        XCTAssertEqual(insertions.text.joined(), "run the focused test")
        XCTAssertEqual(insertions.returnPIDs, [123])

        viewModel.session.handle(event: .partialTranscript("run the focused test send now"))
        viewModel.session.handle(event: .finalTranscript("run the focused test send now"))
        XCTAssertEqual(
            insertions.text.joined(),
            "run the focused test"
        )
        XCTAssertEqual(insertions.insertionPIDs, [123])
        XCTAssertEqual(insertions.returnPIDs, [123])
    }

    func testCustomTriggerUsesTheStoredPhrase() {
        let (viewModel, _, insertions) = makeViewModel()
        viewModel.settings.sendNowTriggerPhrase = "ship it"
        viewModel.session.handle(event: .finalTranscript("run tests ship it"))
        XCTAssertEqual(insertions.text.joined(), "run tests")
        XCTAssertEqual(insertions.returnPIDs, [123])
    }

    func testFocusChangeKeepsTheTriggerAndDoesNotSubmitOrReactivateGhostty() {
        let (viewModel, _, insertions) = makeViewModel()
        viewModel.session.handle(event: .partialTranscript("run tests send now"))
        insertions.frontmostPID = 456
        viewModel.session.handle(event: .finalTranscript("run tests send now"))
        XCTAssertEqual(insertions.text.joined(), "run tests send now")
        XCTAssertEqual(insertions.insertionPIDs, [456])
        XCTAssertEqual(insertions.returnPIDs, [])
        XCTAssertEqual(insertions.frontmostPID, 456)
    }

    func testNonSelectedTerminalTreatsTriggerAsLiteralText() {
        let (viewModel, _, insertions) = makeViewModel(selectedApps: [])

        viewModel.session.handle(event: .partialTranscript("send now"))
        viewModel.session.handle(event: .finalTranscript("send now"))

        XCTAssertEqual(insertions.text.joined(), "send now")
        XCTAssertEqual(insertions.returnPIDs, [])
    }

    func testTerminalHoldBackSanitizesNewlineBeforeReturn() {
        let (viewModel, _, insertions) = makeViewModel()

        viewModel.session.handle(event: .finalTranscript("run tests\nthen report send now"))

        XCTAssertEqual(insertions.text.joined(), "run tests then report")
        XCTAssertEqual(insertions.returnPIDs, [123])
    }
}

private final class Insertions {
    var frontmostPID: pid_t? = 123
    var text: [String] = []
    var insertionPIDs: [pid_t?] = []
    var returnPIDs: [pid_t?] = []
}

#endif
