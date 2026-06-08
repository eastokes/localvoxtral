import AppKit
import Foundation
import Observation
import os

enum RealtimeSessionIndicatorState {
    case idle
    case connected
    case recentFailure
}

@MainActor
@Observable
final class DictationViewModel {
    private enum DictationHotKeyID: UInt32 {
        case defaultShortcut = 1
        case overlayBufferPushToTalk = 2
        case liveAutoPasteToggle = 3
    }

    enum ActiveClientSource {
        case realtimeAPI
        case mlxAudio
    }

    // Tokenized status/error categories keep control flow stable if user-facing
    // copy changes in the future.
    enum StatusToken: Equatable {
        case waitingForAccessibilityPermission
        case pasteBlockedByAccessibilityPermission
        case awaitingMicrophonePermission
        case networkLostDictationStopped
        case noNetworkConnection
        case hotKeyHandlerRegistrationFailure
        case hotKeyShortcutUnavailable
        case other

        @MainActor
        static func from(_ statusText: String) -> StatusToken {
            switch statusText {
            case StatusStrings.waitingForAccessibilityPermission:
                return .waitingForAccessibilityPermission
            case StatusStrings.pasteBlockedByAccessibilityPermission:
                return .pasteBlockedByAccessibilityPermission
            case StatusStrings.awaitingMicrophonePermission:
                return .awaitingMicrophonePermission
            case StatusStrings.networkLostDictationStopped:
                return .networkLostDictationStopped
            case StatusStrings.noNetworkConnection:
                return .noNetworkConnection
            case HotKeyManager.handlerRegistrationErrorMessage:
                return .hotKeyHandlerRegistrationFailure
            case HotKeyManager.registrationErrorStatus:
                return .hotKeyShortcutUnavailable
            default:
                return .other
            }
        }
    }

    enum ErrorToken: Equatable {
        case accessibilityPermissionRequired
        case hotKeyHandlerRegistrationFailure
        case hotKeyShortcutUnavailable
        case websocketReceiveFailed
        case other

        @MainActor
        static func from(_ message: String) -> ErrorToken {
            if message == TextInsertionService.accessibilityErrorMessage {
                return .accessibilityPermissionRequired
            }
            if message == HotKeyManager.handlerRegistrationErrorMessage {
                return .hotKeyHandlerRegistrationFailure
            }
            if message == HotKeyManager.unavailableErrorMessage {
                return .hotKeyShortcutUnavailable
            }
            if message.localizedCaseInsensitiveContains("websocket receive failed") {
                return .websocketReceiveFailed
            }
            return .other
        }
    }

    enum StatusStrings {
        static let ready = "Ready"
        static let connectingRealtimeBackend = "Connecting to realtime backend..."
        static let finalizingPreviousDictation = "Finalizing previous dictation..."
        static let polishing = "Polishing..."
        static let awaitingMicrophonePermission = "Awaiting microphone permission..."
        static let requestingMicrophonePermission = "Requesting microphone permission..."
        static let waitingForAccessibilityPermission = "Waiting for Accessibility permission."
        static let pasteBlockedByAccessibilityPermission = "Paste blocked by Accessibility permission."
        static let networkLostDictationStopped = "Network lost. Dictation stopped."
        static let noNetworkConnection = "No network connection."
        static let microphoneAccessDenied = "Microphone access denied."
        static let finalizing = "Finalizing..."
    }

    private static let microphoneDeniedMessage =
        "Grant microphone access in System Settings > Privacy & Security > Microphone."

    var isDictating = false
    var isFinalizingStop = false
    var isConnectingRealtimeSession = false
    var realtimeSessionIndicatorState: RealtimeSessionIndicatorState = .idle
    var transcriptText = ""
    var livePartialText = ""
    var statusText = StatusStrings.ready
    var lastError: String?
    var lastFinalSegment = ""
    private(set) var availableInputDevices: [MicrophoneInputDevice] = []
    private(set) var selectedInputDeviceID = ""

    var isAccessibilityTrusted: Bool { textInsertion.isAccessibilityTrusted }
    var currentStatusToken: StatusToken { StatusToken.from(statusText) }
    var currentErrorToken: ErrorToken? {
        guard let lastError else { return nil }
        return ErrorToken.from(lastError)
    }

    let settings: SettingsStore
    let textInsertion = TextInsertionService()

    // Services — internal so extension files can access them.
    @ObservationIgnored
    private var hasInitializedMicrophone = false
    @ObservationIgnored
    lazy var microphone: MicrophoneCaptureService = {
        hasInitializedMicrophone = true
        return MicrophoneCaptureService()
    }()
    @ObservationIgnored
    let networkMonitor = NetworkMonitor()
    @ObservationIgnored
    let realtimeAPIClient = RealtimeAPIWebSocketClient()
    @ObservationIgnored
    let mlxAudioRealtimeClient = MlxAudioRealtimeWebSocketClient()
    @ObservationIgnored
    let audioChunkBuffer = AudioChunkBuffer()
    @ObservationIgnored
    let healthMonitor = AudioCaptureHealthMonitor()
    @ObservationIgnored
    var llmPolishingService: any LLMPolishingServicing = LLMPolishingService()
    @ObservationIgnored
    var appConfigStore: any AppConfigServing = AppConfigStore()
    @ObservationIgnored
    var sessionStore: DictationSessionStore?
    @ObservationIgnored
    let mlxStabilizer = MlxHypothesisStabilizer()
    @ObservationIgnored
    let overlayBufferCoordinator: OverlayBufferSessionCoordinating
    @ObservationIgnored
    var preResolvedOverlayAnchor: OverlayAnchor?
    @ObservationIgnored
    private let hotKeyManager = HotKeyManager()

    // Mutable state — internal so extension files can access.
    @ObservationIgnored
    var activeClientSource: ActiveClientSource?
    @ObservationIgnored
    var commitTask: Task<Void, Never>?
    @ObservationIgnored
    var audioSendTask: Task<Void, Never>?
    @ObservationIgnored
    var stopFinalizationTask: Task<Void, Never>?
    @ObservationIgnored
    var connectTimeoutTask: Task<Void, Never>?
    @ObservationIgnored
    var recentFailureResetTask: Task<Void, Never>?
    @ObservationIgnored
    var finalizationWatchdogTask: Task<Void, Never>?
    @ObservationIgnored
    var isShowingConnectionFailureAlert = false
    @ObservationIgnored
    var realtimeFinalizationLastActivityAt: Date?
    @ObservationIgnored
    var isAwaitingMicrophonePermission = false
    @ObservationIgnored
    private var startupPermissionTask: Task<Void, Never>?
    @ObservationIgnored
    private var hasRequestedStartupPermissions = false
    @ObservationIgnored
    var pendingSegmentText = ""
    @ObservationIgnored
    var currentDictationEventText = ""
    @ObservationIgnored
    var sessionOutputMode: DictationOutputMode?
    @ObservationIgnored
    var requestedSessionOutputMode: DictationOutputMode?
    @ObservationIgnored
    var polishAndCommitTask: Task<Void, Never>?
    @ObservationIgnored
    // Several finalization callbacks can converge here; keep stop cleanup
    // idempotent until commit/post-processing fully finishes.
    var isCompletingStoppedSession = false
    @ObservationIgnored
    var wasCancelled = false
    @ObservationIgnored
    let escapeCancelHandler = EscapeCancelHandler()
    @ObservationIgnored
    var sessionStartedAt: Date?
    @ObservationIgnored
    var sessionProvider: SettingsStore.RealtimeProvider?
    @ObservationIgnored
    var sessionModelName: String?
    @ObservationIgnored
    var liveAutoPasteTargetAppPID: pid_t?
    @ObservationIgnored
    var liveAutoPasteTargetAppBundleID: String?
    @ObservationIgnored
    var lastSendNowLiveSubmittedSegment: String?
    @ObservationIgnored
    var firstChunkPreprocessor = FirstChunkPreprocessor()

    @ObservationIgnored
    let debugLoggingEnabled = ProcessInfo.processInfo.environment["LOCALVOXTRAL_DEBUG"] == "1"

    @ObservationIgnored
    private var lifecycleObservers: [NSObjectProtocol] = []
    @ObservationIgnored
    private let managesRuntimeServices: Bool
    // Tracks physical key state so repeat key-down events do not retrigger actions.
    @ObservationIgnored
    private var isPushToTalkShortcutHeld = false
    // True only when a start attempt was initiated by push-to-talk and may still need
    // to be cancelled if the user releases before dictation actually begins.
    @ObservationIgnored
    private var hasActivePushToTalkShortcutSession = false
    @ObservationIgnored
    private var activeShortcutMode: DictationShortcutMode?
    @ObservationIgnored
    private var activePushToTalkHotKeyID: UInt32?

    init(
        settings: SettingsStore,
        overlayBufferCoordinator: OverlayBufferSessionCoordinating? = nil,
        startRuntimeServices: Bool = true
    ) {
        self.settings = settings
        self.managesRuntimeServices = startRuntimeServices
        if let overlayBufferCoordinator {
            self.overlayBufferCoordinator = overlayBufferCoordinator
        } else {
            let anchorResolver = OverlayAnchorResolver()
            self.overlayBufferCoordinator = OverlayBufferSessionCoordinator(
                stateMachine: OverlayBufferStateMachine(),
                renderer: DictationOverlayController(),
                anchorResolver: anchorResolver
            )
        }

        realtimeAPIClient.setEventHandler { [weak self] event in
            // Preserve callback order for back-to-back events (e.g. final transcript
            // followed by transcription finalized) by routing through main-queue FIFO.
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                MainActor.assumeIsolated {
                    self.handle(event: event, source: .realtimeAPI)
                }
            }
        }

        mlxAudioRealtimeClient.setEventHandler { [weak self] event in
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                MainActor.assumeIsolated {
                    self.handle(event: event, source: .mlxAudio)
                }
            }
        }

        if startRuntimeServices {
            microphone.onConfigurationChange = { [weak self] in
                Task { @MainActor [weak self] in
                    self?.healthMonitor.handleConfigurationChange()
                }
            }

            microphone.onInputDevicesChanged = { [weak self] in
                Task { @MainActor [weak self] in
                    self?.healthMonitor.handleInputDevicesChanged()
                }
            }

            microphone.onError = { [weak self] message in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    self.lastError = message
                }
            }
        }

        textInsertion.onAccessibilityTrustChanged = { [weak self] in
            guard let self else { return }
            if self.currentErrorToken == .accessibilityPermissionRequired {
                self.lastError = nil
            }
            if !self.isDictating,
               (self.currentStatusToken == .waitingForAccessibilityPermission
                   || self.currentStatusToken == .pasteBlockedByAccessibilityPermission)
            {
                self.statusText = StatusStrings.ready
            }
        }

        networkMonitor.onChange = { [weak self] connected in
            Task { @MainActor [weak self] in
                self?.handleNetworkChange(connected: connected)
            }
        }
        if startRuntimeServices {
            networkMonitor.start()
        }

        hotKeyManager.onPress = { [weak self] id in self?.handleDictationHotKeyPress(id: id) }
        hotKeyManager.onRelease = { [weak self] id in self?.handleDictationHotKeyRelease(id: id) }
        if startRuntimeServices {
            switch registerConfiguredHotKeys() {
            case .success:
                break
            case .failure(let reason):
                applyHotKeyRegistrationFailure(reason)
            }
        }

        escapeCancelHandler.onCancel = { [weak self] in self?.cancelDictation() }

        mlxStabilizer.onRealtimeInsertion = { [weak self] delta in
            self?.handleMlxRealtimeInsertionDelta(delta)
        }
        mlxStabilizer.onFinalizedInsertion = { [weak self] delta in
            self?.handleMlxFinalizedInsertionDelta(delta)
        }
        textInsertion.refreshAccessibilityTrustState()
        if startRuntimeServices {
            sessionStore = DictationSessionStore()
            refreshMicrophoneInputs()
            registerLifecycleObservers()
            requestStartupPermissionsIfNeeded()
        }
    }

    @MainActor
    deinit {
        for observer in lifecycleObservers {
            NotificationCenter.default.removeObserver(observer)
        }
        lifecycleObservers.removeAll()
        commitTask?.cancel()
        audioSendTask?.cancel()
        stopFinalizationTask?.cancel()
        connectTimeoutTask?.cancel()
        recentFailureResetTask?.cancel()
        finalizationWatchdogTask?.cancel()
        startupPermissionTask?.cancel()
        polishAndCommitTask?.cancel()
        textInsertion.stopAllTasks()
        overlayBufferCoordinator.reset()
        healthMonitor.cancelTasks()
        escapeCancelHandler.stop()
        if managesRuntimeServices {
            if hasInitializedMicrophone {
                microphone.stop()
            }
            networkMonitor.stop()
            realtimeAPIClient.disconnect()
            mlxAudioRealtimeClient.disconnect()
            hotKeyManager.unregister()
        }
    }

    // MARK: - Lifecycle Observers

    private func registerLifecycleObservers() {
        let nc = NotificationCenter.default

        let sleepObserver = nc.addObserver(
            forName: NSWorkspace.willSleepNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.isDictating else { return }
                self.stopDictation(reason: "system sleep", finalizeRemainingAudio: false)
            }
        }

        let terminateObserver = nc.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.isDictating else { return }
                self.stopDictation(reason: "app terminating", finalizeRemainingAudio: false)
            }
        }

        lifecycleObservers = [sleepObserver, terminateObserver]
    }

    private func requestStartupPermissionsIfNeeded() {
        guard managesRuntimeServices else { return }
        guard !hasRequestedStartupPermissions else { return }
        hasRequestedStartupPermissions = true

        startupPermissionTask?.cancel()
        startupPermissionTask = Task { @MainActor [weak self] in
            guard let self else { return }
            self.prepareLLMPolishingPromptAccessIfNeeded()
            guard !Task.isCancelled else { return }
            await self.requestStartupMicrophonePermissionIfNeeded()
            guard !Task.isCancelled else { return }
            self.requestStartupAccessibilityPermissionIfNeeded()
        }
    }

    func prepareLLMPolishingPromptAccessIfNeeded() {
        guard settings.llmPolishingEnabled else { return }

        debugLog("preloading LLM polishing prompt/config files")
        _ = appConfigStore.loadLLMPromptTemplates()
    }

    private func requestStartupAccessibilityPermissionIfNeeded() {
        refreshAccessibilityTrustState()
        guard !textInsertion.isAccessibilityTrusted else { return }

        debugLog("startup accessibility permission prompt requested")
        textInsertion.requestAccessibilityPermissionIfNeeded()
    }

    private func requestStartupMicrophonePermissionIfNeeded() async {
        guard !isAwaitingMicrophonePermission else { return }
        guard microphone.authorizationStatus() == .notDetermined else { return }

        isAwaitingMicrophonePermission = true
        debugLog("startup microphone permission prompt requested")

        let granted = await withCheckedContinuation { continuation in
            microphone.requestAccess { granted in
                continuation.resume(returning: granted)
            }
        }

        guard !Task.isCancelled else { return }
        isAwaitingMicrophonePermission = false
        debugLog("startup microphone permission result granted=\(granted)")

        guard granted else {
            if !isDictating, !isFinalizingStop, !isConnectingRealtimeSession {
                statusText = StatusStrings.microphoneAccessDenied
            }
            lastError = Self.microphoneDeniedMessage
            return
        }

        if !isDictating, !isFinalizingStop, !isConnectingRealtimeSession,
           currentStatusToken == .awaitingMicrophonePermission
        {
            statusText = StatusStrings.ready
        }
    }

    // MARK: - Network

    private func handleNetworkChange(connected: Bool) {
        if connected {
            debugLog("network restored")
            if !isDictating, !isFinalizingStop, !isConnectingRealtimeSession,
               (currentStatusToken == .networkLostDictationStopped
                   || currentStatusToken == .noNetworkConnection)
            {
                statusText = StatusStrings.ready
                lastError = nil
            }
        } else {
            debugLog("network lost")
            if isConnectingRealtimeSession {
                abortConnectingSession()
                let message = "Network connection was lost while connecting."
                handleConnectFailure(
                    status: StatusStrings.networkLostDictationStopped,
                    message: message,
                    technicalDetails: "Network path changed to unavailable while opening websocket."
                )
            } else if isDictating {
                stopDictation(reason: "network lost", finalizeRemainingAudio: false)
                statusText = StatusStrings.networkLostDictationStopped
                lastError = "Network connection was lost during dictation."
            } else if isFinalizingStop {
                activeRealtimeClient().disconnect()
                finishStoppedSession(promotePendingSegment: true)
                statusText = StatusStrings.networkLostDictationStopped
                lastError = "Network connection was lost during dictation."
            } else {
                statusText = StatusStrings.noNetworkConnection
            }
        }
    }

    // MARK: - Public API

    private func handleDictationHotKeyPress(id: UInt32) {
        guard let hotKeyID = DictationHotKeyID(rawValue: id) else { return }

        switch hotKeyID {
        case .defaultShortcut:
            handleDictationShortcutPress(
                hotKeyID: id,
                outputMode: nil,
                shortcutMode: settings.dictationShortcutMode
            )
        case .overlayBufferPushToTalk:
            handleDictationShortcutPress(
                hotKeyID: id,
                outputMode: .overlayBuffer,
                shortcutMode: .pushToTalk
            )
        case .liveAutoPasteToggle:
            handleDictationShortcutPress(
                hotKeyID: id,
                outputMode: .liveAutoPaste,
                shortcutMode: .toggle
            )
        }
    }

    private func handleDictationHotKeyRelease(id: UInt32) {
        guard let hotKeyID = DictationHotKeyID(rawValue: id) else { return }

        switch hotKeyID {
        case .defaultShortcut, .overlayBufferPushToTalk, .liveAutoPasteToggle:
            handleDictationShortcutRelease(hotKeyID: id)
        }
    }

    private func handleDictationShortcutPress(
        hotKeyID: UInt32,
        outputMode: DictationOutputMode?,
        shortcutMode: DictationShortcutMode
    ) {
        switch shortcutMode {
        case .toggle:
            hasActivePushToTalkShortcutSession = false
            activePushToTalkHotKeyID = nil
            activeShortcutMode = .toggle
            toggleDictation(outputMode: outputMode)
        case .pushToTalk:
            guard !isPushToTalkShortcutHeld else { return }
            isPushToTalkShortcutHeld = true
            guard !isDictating, !isConnectingRealtimeSession, !isFinalizingStop else { return }
            hasActivePushToTalkShortcutSession = true
            activeShortcutMode = .pushToTalk
            activePushToTalkHotKeyID = hotKeyID
            startDictation(outputMode: outputMode)
            if !isDictating, !isConnectingRealtimeSession, !isAwaitingMicrophonePermission {
                hasActivePushToTalkShortcutSession = false
                activeShortcutMode = nil
                activePushToTalkHotKeyID = nil
            }
        }
    }

    private func handleDictationShortcutRelease(hotKeyID: UInt32) {
        guard activePushToTalkHotKeyID == hotKeyID else { return }
        guard isPushToTalkShortcutHeld else { return }
        isPushToTalkShortcutHeld = false

        guard activeShortcutMode == .pushToTalk else {
            hasActivePushToTalkShortcutSession = false
            activeShortcutMode = nil
            activePushToTalkHotKeyID = nil
            return
        }
        guard hasActivePushToTalkShortcutSession else { return }

        if isConnectingRealtimeSession {
            // Keep the connection attempt alive so timeout/errors surface to the user
            // instead of silently resetting to Ready on key release.
            statusText = StatusStrings.connectingRealtimeBackend
            return
        } else if isDictating {
            stopDictation(reason: "push-to-talk release")
        } else if isAwaitingMicrophonePermission {
            // Keep the session marker until the permission callback resolves so we can
            // suppress starting if the key was released before permission was granted.
            statusText = StatusStrings.ready
            return
        }
        clearPushToTalkShortcutSessionAttempt()
    }

    func shouldCancelPushToTalkStartAfterConnect() -> Bool {
        activeShortcutMode == .pushToTalk
            && hasActivePushToTalkShortcutSession
            && !isPushToTalkShortcutHeld
    }

    func clearPushToTalkShortcutSessionAttempt() {
        hasActivePushToTalkShortcutSession = false
        activeShortcutMode = nil
        activePushToTalkHotKeyID = nil
    }

    func toggleDictation(outputMode: DictationOutputMode? = nil) {
        hasActivePushToTalkShortcutSession = false
        activePushToTalkHotKeyID = nil
        if isDictating {
            stopDictation(reason: "manual toggle")
        } else if isConnectingRealtimeSession {
            statusText = StatusStrings.connectingRealtimeBackend
        } else if isFinalizingStop {
            statusText = StatusStrings.finalizingPreviousDictation
        } else {
            startDictation(outputMode: outputMode)
        }
    }

    func cancelDictation() {
        guard isDictating || isFinalizingStop || isConnectingRealtimeSession else { return }
        wasCancelled = true
        if isDictating {
            stopDictation(reason: "cancelled", finalizeRemainingAudio: false)
        } else if isConnectingRealtimeSession {
            abortConnectingSession()
            statusText = StatusStrings.ready
        } else if isFinalizingStop {
            activeRealtimeClient().disconnect()
            finishStoppedSession(promotePendingSegment: false)
        }
    }

    func updateDictationShortcut(_ shortcut: DictationShortcut?) {
        let previousShortcut = settings.dictationShortcut
        let previousWasEnabled = settings.dictationShortcutEnabled

        settings.setDictationShortcut(shortcut)

        switch registerConfiguredHotKeys() {
        case .success:
            clearHotKeyRegistrationErrorIfNeeded()
            return
        case .failure(let reason):
            if previousWasEnabled {
                settings.setDictationShortcut(previousShortcut ?? SettingsStore.defaultDictationShortcut)
            } else {
                settings.setDictationShortcut(nil)
            }
            _ = registerConfiguredHotKeys()
            applyHotKeyRegistrationFailure(reason)
        }
    }

    func updateOverlayBufferPushToTalkShortcut(_ shortcut: DictationShortcut?) {
        let previousShortcut = settings.overlayBufferPushToTalkShortcut
        let previousWasEnabled = settings.overlayBufferShortcutEnabled

        settings.setOverlayBufferPushToTalkShortcut(shortcut)

        switch registerConfiguredHotKeys() {
        case .success:
            clearHotKeyRegistrationErrorIfNeeded()
        case .failure(let reason):
            settings.setOverlayBufferPushToTalkShortcut(
                previousWasEnabled ? previousShortcut ?? SettingsStore.defaultDictationShortcut : nil)
            _ = registerConfiguredHotKeys()
            applyHotKeyRegistrationFailure(reason)
        }
    }

    func updateLiveAutoPasteToggleShortcut(_ shortcut: DictationShortcut?) {
        let previousShortcut = settings.liveAutoPasteToggleShortcut
        let previousWasEnabled = settings.liveAutoPasteShortcutEnabled

        settings.setLiveAutoPasteToggleShortcut(shortcut)

        switch registerConfiguredHotKeys() {
        case .success:
            clearHotKeyRegistrationErrorIfNeeded()
        case .failure(let reason):
            settings.setLiveAutoPasteToggleShortcut(
                previousWasEnabled ? previousShortcut ?? SettingsStore.defaultDictationShortcut : nil)
            _ = registerConfiguredHotKeys()
            applyHotKeyRegistrationFailure(reason)
        }
    }

    func refreshMicrophoneInputs() {
        let devices = microphone.availableInputDevices()
        if availableInputDevices != devices {
            availableInputDevices = devices
        }

        let savedSelection = settings.selectedInputDeviceUID.trimmed
        let currentSelection = selectedInputDeviceID.trimmed
        let explicitSelection = !savedSelection.isEmpty ? savedSelection : currentSelection

        guard !devices.isEmpty else { return }

        if !explicitSelection.isEmpty,
           devices.contains(where: { $0.id == explicitSelection })
        {
            if selectedInputDeviceID != explicitSelection {
                selectedInputDeviceID = explicitSelection
            }
            if settings.selectedInputDeviceUID != explicitSelection {
                settings.selectedInputDeviceUID = explicitSelection
            }
            return
        }

        let resolvedSelection: String
        if let defaultID = microphone.defaultInputDeviceID(),
           devices.contains(where: { $0.id == defaultID })
        {
            resolvedSelection = defaultID
        } else if let firstDevice = devices.first {
            resolvedSelection = firstDevice.id
        } else {
            return
        }

        if selectedInputDeviceID != resolvedSelection {
            selectedInputDeviceID = resolvedSelection
        }
        if settings.selectedInputDeviceUID != resolvedSelection {
            settings.selectedInputDeviceUID = resolvedSelection
        }
    }

    func selectMicrophoneInput(id: String) {
        guard !id.isEmpty else { return }
        guard selectedInputDeviceID != id else { return }

        selectedInputDeviceID = id
        settings.selectedInputDeviceUID = id

        guard isDictating else { return }
        stopDictation(reason: "input device changed by user", finalizeRemainingAudio: false)
        startDictation()
    }

    func startDictation(outputMode: DictationOutputMode? = nil) {
        guard !isDictating else { return }
        guard !isConnectingRealtimeSession else {
            statusText = StatusStrings.connectingRealtimeBackend
            return
        }
        if isFinalizingStop {
            guard cancelPolishingForNewSessionIfNeeded() else {
                statusText = StatusStrings.finalizingPreviousDictation
                return
            }
        }
        guard !isAwaitingMicrophonePermission else {
            statusText = StatusStrings.awaitingMicrophonePermission
            return
        }
        guard networkMonitor.isConnected else {
            statusText = StatusStrings.noNetworkConnection
            lastError = "Connect to a network before starting dictation."
            return
        }
        debugLog("startDictation requested")
        requestedSessionOutputMode = outputMode
        refreshMicrophoneInputs()
        if debugLoggingEnabled {
            let inputs = availableInputDevices.map { "\($0.name)=\($0.id)" }.joined(separator: ", ")
            debugLog("available inputs: \(inputs)")
            debugLog("selected input id=\(selectedInputDeviceID)")
        }
        lastError = nil

        switch microphone.authorizationStatus() {
        case .authorized:
            beginDictationSession()
        case .notDetermined:
            isAwaitingMicrophonePermission = true
            statusText = StatusStrings.requestingMicrophonePermission
            debugLog("microphone permission prompt requested")
            microphone.requestAccess { [weak self] granted in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    self.isAwaitingMicrophonePermission = false
                    self.debugLog("microphone permission result granted=\(granted)")
                    guard granted else {
                        self.statusText = StatusStrings.microphoneAccessDenied
                        self.lastError = Self.microphoneDeniedMessage
                        self.hasActivePushToTalkShortcutSession = false
                        self.activeShortcutMode = nil
                        self.activePushToTalkHotKeyID = nil
                        self.requestedSessionOutputMode = nil
                        return
                    }
                    if self.hasActivePushToTalkShortcutSession,
                        !self.isPushToTalkShortcutHeld
                    {
                        self.statusText = StatusStrings.ready
                        self.hasActivePushToTalkShortcutSession = false
                        self.activeShortcutMode = nil
                        self.activePushToTalkHotKeyID = nil
                        self.requestedSessionOutputMode = nil
                        return
                    }
                    self.beginDictationSession()
                }
            }
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(120))
                guard let self, self.isAwaitingMicrophonePermission else { return }
                self.isAwaitingMicrophonePermission = false
                self.statusText = StatusStrings.ready
                if self.hasActivePushToTalkShortcutSession && !self.isPushToTalkShortcutHeld {
                    self.hasActivePushToTalkShortcutSession = false
                    self.activeShortcutMode = nil
                    self.activePushToTalkHotKeyID = nil
                    self.requestedSessionOutputMode = nil
                }
                self.debugLog("microphone permission prompt timed out")
            }
        case .denied, .restricted:
            requestedSessionOutputMode = nil
            activeShortcutMode = nil
            activePushToTalkHotKeyID = nil
            statusText = StatusStrings.microphoneAccessDenied
            lastError = Self.microphoneDeniedMessage
            debugLog("microphone access denied or restricted")
        }
    }

    func stopDictation(reason: String = "unspecified", finalizeRemainingAudio: Bool = true) {
        guard isDictating else { return }
        debugLog("stopDictation reason=\(reason)")
        hasActivePushToTalkShortcutSession = false

        polishAndCommitTask?.cancel()
        polishAndCommitTask = nil
        commitTask?.cancel()
        commitTask = nil
        audioSendTask?.cancel()
        audioSendTask = nil
        healthMonitor.stop()
        isAwaitingMicrophonePermission = false

        microphone.stop()
        flushBufferedAudio()
        isDictating = false
        EscapeCancelHandler.isDictatingRef = false
        escapeCancelHandler.stop()

        guard finalizeRemainingAudio else {
            activeRealtimeClient().disconnect()
            finishStoppedSession(promotePendingSegment: true)
            return
        }

        isFinalizingStop = true
        statusText = StatusStrings.finalizing
        setRealtimeIndicatorConnected()
        if isOverlayBufferModeEnabled {
            beginOverlayFinalization()
        }
        scheduleStopFinalization()
        startStopFinalizationWatchdog()
    }

    func clearTranscript() {
        transcriptText = ""
        livePartialText = ""
        lastFinalSegment = ""
        pendingSegmentText = ""
        currentDictationEventText = ""
        if !isDictating, !isFinalizingStop, !isConnectingRealtimeSession {
            sessionOutputMode = nil
        }
        firstChunkPreprocessor.reset()
        mlxStabilizer.reset()
        overlayBufferCoordinator.reset()
        lastError = nil
    }

    func copyTranscript() {
        let fullText = fullTranscript.trimmed
        guard !fullText.isEmpty else { return }

        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(fullText, forType: .string)

        statusText = "Transcript copied."
    }

    func copyLatestSegment(updateStatus: Bool = true) {
        let segment = lastFinalSegment.trimmed
        guard !segment.isEmpty else { return }

        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(segment, forType: .string)

        if updateStatus {
            statusText = "Latest segment copied."
        }
    }

    func requestAccessibilityPermission() {
        textInsertion.requestAccessibilityPermission()

        if textInsertion.isAccessibilityTrusted {
            statusText = StatusStrings.ready
        } else {
            statusText = StatusStrings.waitingForAccessibilityPermission
        }
    }

    func resetAccessibilityPermission() {
        guard textInsertion.resetAccessibilityPermission() else {
            lastError = "Unable to reset Accessibility permission for this app build."
            return
        }

        statusText = StatusStrings.waitingForAccessibilityPermission
        lastError = nil
        textInsertion.requestAccessibilityPermission()
    }

    func refreshAccessibilityTrustState() {
        let wasTrusted = textInsertion.isAccessibilityTrusted
        textInsertion.refreshAccessibilityTrustState()

        if textInsertion.isAccessibilityTrusted, !wasTrusted, !isDictating,
           (currentStatusToken == .waitingForAccessibilityPermission
               || currentStatusToken == .pasteBlockedByAccessibilityPermission)
        {
            statusText = StatusStrings.ready
        }

        if let axError = textInsertion.lastAccessibilityError {
            if lastError == nil || currentErrorToken == .accessibilityPermissionRequired {
                lastError = axError
            }
        } else if currentErrorToken == .accessibilityPermissionRequired {
            lastError = nil
        }
    }

    func openConfigFolder() {
        let url = appConfigStore.configDirectoryURL()
        NSWorkspace.shared.open(url)
    }

    func pasteLatestSegment() {
        let segment = lastFinalSegment.trimmed
        guard !segment.isEmpty else { return }

        textInsertion.refreshAccessibilityTrustState()

        let directInsertResult = textInsertion.insertText(segment)
        if directInsertResult.isSuccess {
            statusText = "Pasted latest segment."
            return
        }

        if textInsertion.pasteUsingCommandV(segment) {
            statusText = "Pasted latest segment."
            return
        }

        if !textInsertion.isAccessibilityTrusted {
            statusText = StatusStrings.pasteBlockedByAccessibilityPermission
        } else {
            statusText = "Unable to paste latest segment."
        }
    }

    var fullTranscript: String {
        let finalPart = transcriptText.trimmed
        let livePart = livePartialText.trimmed

        if finalPart.isEmpty { return livePart }
        if livePart.isEmpty { return finalPart }
        return finalPart + "\n" + livePart
    }

    var acceptsRealtimeEvents: Bool {
        isDictating || isFinalizingStop
    }

    var isOverlayBufferModeEnabled: Bool {
        activeOutputMode == .overlayBuffer
    }

    var isLiveAutoPasteModeEnabled: Bool {
        activeOutputMode == .liveAutoPaste
    }

    var isSendNowCommandActive: Bool {
        guard settings.sendNowCommandEnabled,
              isLiveAutoPasteModeEnabled,
              liveAutoPasteTargetAppPID != nil,
              let bundleID = liveAutoPasteTargetAppBundleID
        else {
            return false
        }
        return settings.matchesSendNowTargetApp(bundleIdentifier: bundleID)
    }

    private var activeOutputMode: DictationOutputMode {
        sessionOutputMode ?? settings.dictationOutputMode
    }

    func debugLog(_ message: String) {
        guard debugLoggingEnabled else { return }
        Log.dictation.debug("\(message)")
    }

    private func applyHotKeyRegistrationFailure(_ reason: HotKeyManager.RegistrationFailure) {
        switch reason {
        case .handlerInstallFailed:
            statusText = HotKeyManager.handlerRegistrationErrorMessage
            lastError = HotKeyManager.handlerRegistrationErrorMessage
        case .shortcutUnavailable:
            statusText = HotKeyManager.registrationErrorStatus
            lastError = HotKeyManager.unavailableErrorMessage
        }
    }

    @discardableResult
    private func registerConfiguredHotKeys() -> HotKeyManager.RegistrationResult {
        hotKeyManager.register(shortcuts: [
            DictationHotKeyID.defaultShortcut.rawValue: settings.dictationShortcut,
            DictationHotKeyID.overlayBufferPushToTalk.rawValue:
                settings.overlayBufferPushToTalkShortcut,
            DictationHotKeyID.liveAutoPasteToggle.rawValue:
                settings.liveAutoPasteToggleShortcut,
        ])
    }

    private func clearHotKeyRegistrationErrorIfNeeded() {
        if !isDictating, !isFinalizingStop,
           (currentStatusToken == .hotKeyHandlerRegistrationFailure
            || currentStatusToken == .hotKeyShortcutUnavailable)
        {
            statusText = StatusStrings.ready
        }

        if currentErrorToken == .hotKeyShortcutUnavailable
            || currentErrorToken == .hotKeyHandlerRegistrationFailure
        {
            lastError = nil
        }
    }

    private func handleMlxRealtimeInsertionDelta(_ delta: String) {
        guard isLiveAutoPasteModeEnabled else { return }
        textInsertion.enqueueRealtimeInsertion(delta)
    }

    private func handleMlxFinalizedInsertionDelta(_ delta: String) {
        guard isLiveAutoPasteModeEnabled, !isSendNowCommandActive else { return }
        if !textInsertion.insertTextUsingAccessibilityOnly(delta) {
            _ = textInsertion.pasteUsingCommandV(delta)
        }
    }
}

#if DEBUG
extension DictationViewModel {
    func debugHandleDictationShortcutPressForTesting() {
        handleDictationHotKeyPress(id: DictationHotKeyID.defaultShortcut.rawValue)
    }

    func debugHandleOverlayBufferPushToTalkShortcutPressForTesting() {
        handleDictationHotKeyPress(id: DictationHotKeyID.overlayBufferPushToTalk.rawValue)
    }

    func debugHandleLiveAutoPasteToggleShortcutPressForTesting() {
        handleDictationHotKeyPress(id: DictationHotKeyID.liveAutoPasteToggle.rawValue)
    }

    func debugHandleDictationShortcutReleaseForTesting() {
        handleDictationShortcutRelease(hotKeyID: DictationHotKeyID.defaultShortcut.rawValue)
    }

    func debugHandleOverlayBufferPushToTalkShortcutReleaseForTesting() {
        handleDictationShortcutRelease(hotKeyID: DictationHotKeyID.overlayBufferPushToTalk.rawValue)
    }

    func debugSetPushToTalkShortcutStateForTesting(
        isHeld: Bool,
        hasActiveSession: Bool
    ) {
        isPushToTalkShortcutHeld = isHeld
        hasActivePushToTalkShortcutSession = hasActiveSession
        activeShortcutMode = hasActiveSession ? .pushToTalk : nil
        activePushToTalkHotKeyID = hasActiveSession
            ? DictationHotKeyID.defaultShortcut.rawValue
            : nil
    }
}
#endif
