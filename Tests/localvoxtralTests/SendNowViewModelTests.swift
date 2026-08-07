import Foundation
import XCTest
@testable import localvoxtral

#if DEBUG
@MainActor
final class SendNowViewModelTests: XCTestCase {
    private static var retainedViewModels: [DictationViewModel] = []

    private func makeViewModel(
        selectedApps: Set<SendNowTargetApp> = [.ghostty]
    ) -> (DictationViewModel, SendNowTestOverlayCoordinator, Insertions) {
        let suiteName = "localvoxtral.SendNowViewModelTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        addTeardownBlock {
            defaults.removePersistentDomain(forName: suiteName)
        }

        let settings = SettingsStore(defaults: defaults, environment: [:])
        settings.dictationOutputMode = .liveAutoPaste
        let coordinator = SendNowTestOverlayCoordinator()
        coordinator.commitTargetAppPID = 123
        let viewModel = DictationViewModel(
            settings: settings,
            overlayBufferCoordinator: coordinator,
            startRuntimeServices: false
        )
        Self.retainedViewModels.append(viewModel)

        viewModel.isDictating = true
        viewModel.sessionOutputMode = .liveAutoPaste
        viewModel.sessionSendNowEnabled = true
        viewModel.sessionSendNowTriggerPhrase = "send now"
        viewModel.sessionSendNowTargetApps = selectedApps
        viewModel.preCapturedSessionTargetVerdict = .init(
            decision: .init(isTerminalLike: true, reason: .bundleMatch),
            secureKeyboardEntryEnabled: false
        )
        viewModel.applyPreCapturedSessionTargetVerdict()
        viewModel.debugResolveTargetAppBundleIDOverride = { "com.mitchellh.ghostty" }
        viewModel.textInsertion.beginLiveReplacementSession(
            dictionary: ReplacementDictionary(entries: []),
            preferredAppPID: 123,
            isTerminalLikeTarget: true
        )

        let insertions = Insertions()
        viewModel.textInsertion.debugConfigureInsertionHooks(
            unicodePoster: { text in
                insertions.text.append(text)
                return true
            },
            modifierStateReader: { false },
            accessibilityInserter: { text, pid in
                insertions.text.append(text)
                insertions.insertionPIDs.append(pid)
                return true
            },
            returnKeyPoster: { pid in
                insertions.returnPIDs.append(pid)
                return true
            }
        )
        return (viewModel, coordinator, insertions)
    }

    func testSelectedTerminalWithholdsPartialsAndSubmitsFinalizedBodyOnce() {
        let (viewModel, _, insertions) = makeViewModel()

        viewModel.handle(event: .partialTranscript("run the focused test send now"))
        XCTAssertEqual(insertions.text, [])
        XCTAssertEqual(insertions.returnPIDs, [])

        viewModel.handle(event: .finalTranscript("run the focused test send now"))
        XCTAssertEqual(insertions.text.joined(), "run the focused test")
        XCTAssertEqual(insertions.insertionPIDs, [123])
        XCTAssertEqual(insertions.returnPIDs, [123])

        viewModel.handle(event: .finalTranscript("run the focused test send now"))
        XCTAssertEqual(insertions.text.joined(), "run the focused test")
        XCTAssertEqual(insertions.returnPIDs, [123])

        viewModel.handle(event: .partialTranscript("run the focused test send now"))
        viewModel.handle(event: .finalTranscript("run the focused test send now"))
        XCTAssertEqual(
            insertions.text.joined(),
            "run the focused testrun the focused test"
        )
        XCTAssertEqual(insertions.insertionPIDs, [123, 123])
        XCTAssertEqual(insertions.returnPIDs, [123, 123])
    }

    func testNonSelectedTerminalTreatsTriggerAsLiteralText() {
        let (viewModel, _, insertions) = makeViewModel(selectedApps: [])

        viewModel.handle(event: .partialTranscript("send now"))
        viewModel.handle(event: .finalTranscript("send now"))

        XCTAssertEqual(insertions.text.joined(), "send now")
        XCTAssertEqual(insertions.returnPIDs, [])
    }

    func testTerminalHoldBackSanitizesNewlineBeforeReturn() {
        let (viewModel, _, insertions) = makeViewModel()

        viewModel.handle(event: .finalTranscript("run tests\nthen report send now"))

        XCTAssertEqual(insertions.text.joined(), "run tests then report")
        XCTAssertEqual(insertions.returnPIDs, [123])
    }
}

private final class Insertions {
    var text: [String] = []
    var insertionPIDs: [pid_t?] = []
    var returnPIDs: [pid_t?] = []
}

@MainActor
private final class SendNowTestOverlayCoordinator: OverlayBufferSessionCoordinating {
    var commitTargetAppPID: pid_t?

    func resolveAnchorNow() -> OverlayAnchor {
        OverlayAnchor(
            targetRect: CGRect(x: 0, y: 0, width: 100, height: 24),
            source: .windowCenter
        )
    }
    func startSession(preResolvedAnchor: OverlayAnchor?) {}
    func beginFinalizing(displayBufferText: String, commitBufferText: String) {}
    func refresh(displayBufferText: String, commitBufferText: String) {}
    func commitIfNeeded(
        using textCommitter: OverlayTextCommitting,
        autoCopyEnabled: Bool
    ) -> OverlayBufferCommitOutcome { .succeeded }
    func dismissAfterHold(minimumVisibility: TimeInterval) {}
    func reset() {}
    func captureLiveCommitTargetAppPID() {}
}
#endif
