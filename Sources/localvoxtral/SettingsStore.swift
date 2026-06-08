import Carbon.HIToolbox
import Foundation
import Observation

struct DictationShortcut: Equatable, Sendable {
    var keyCode: UInt32
    var carbonModifierFlags: UInt32

    var normalized: DictationShortcut {
        DictationShortcut(
            keyCode: keyCode,
            carbonModifierFlags: DictationShortcutValidation.normalizedModifierFlags(
                carbonModifierFlags)
        )
    }
}

enum DictationOutputMode: String, CaseIterable, Identifiable {
    case overlayBuffer = "overlay_buffer"
    case liveAutoPaste = "live_auto_paste"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .overlayBuffer:
            return "Overlay Buffer"
        case .liveAutoPaste:
            return "Live Auto-Paste"
        }
    }

    var description: String {
        switch self {
        case .overlayBuffer:
            return "Keeps text in an on-screen buffer until stop."
        case .liveAutoPaste:
            return "Streams text directly into the focused app."
        }
    }
}

enum DictationShortcutMode: String, CaseIterable, Identifiable {
    case toggle = "toggle"
    case pushToTalk = "push_to_talk"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .toggle:
            return "Toggle"
        case .pushToTalk:
            return "Push to Talk"
        }
    }

    var description: String {
        switch self {
        case .toggle:
            return "Press once to start dictation, press again to stop."
        case .pushToTalk:
            return "Hold the shortcut to dictate, release to stop."
        }
    }
}

enum SendNowTargetApp: String, CaseIterable, Identifiable {
    case ghostty = "ghostty"
    case terminal = "terminal"
    case iTerm = "iterm"
    case warp = "warp"
    case wezTerm = "wezterm"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .ghostty:
            return "Ghostty"
        case .terminal:
            return "Terminal"
        case .iTerm:
            return "iTerm"
        case .warp:
            return "Warp"
        case .wezTerm:
            return "WezTerm"
        }
    }

    var bundleIdentifiers: Set<String> {
        switch self {
        case .ghostty:
            return ["com.mitchellh.ghostty"]
        case .terminal:
            return ["com.apple.Terminal"]
        case .iTerm:
            return ["com.googlecode.iterm2"]
        case .warp:
            return ["dev.warp.Warp-Stable"]
        case .wezTerm:
            return ["com.github.wez.wezterm"]
        }
    }
}

enum DictationShortcutValidation {
    static let allowedModifierFlagsMask = UInt32(cmdKey | optionKey | shiftKey | controlKey)

    static func normalizedModifierFlags(_ flags: UInt32) -> UInt32 {
        flags & allowedModifierFlagsMask
    }

    static func persistenceErrorMessage(for shortcut: DictationShortcut) -> String? {
        if shortcut.keyCode > UInt32(UInt16.max) {
            return "Shortcut key is not supported."
        }

        if normalizedModifierFlags(shortcut.carbonModifierFlags) == 0,
           !isFunctionKey(shortcut.keyCode)
        {
            return "Shortcut must include at least one modifier key unless it is a function key."
        }

        return nil
    }

    static func isFunctionKey(_ keyCode: UInt32) -> Bool {
        switch keyCode {
        case UInt32(kVK_F1), UInt32(kVK_F2), UInt32(kVK_F3), UInt32(kVK_F4),
             UInt32(kVK_F5), UInt32(kVK_F6), UInt32(kVK_F7), UInt32(kVK_F8),
             UInt32(kVK_F9), UInt32(kVK_F10), UInt32(kVK_F11), UInt32(kVK_F12),
             UInt32(kVK_F13), UInt32(kVK_F14), UInt32(kVK_F15), UInt32(kVK_F16),
             UInt32(kVK_F17), UInt32(kVK_F18), UInt32(kVK_F19), UInt32(kVK_F20):
            return true
        default:
            return false
        }
    }

    static func validationErrorMessage(for shortcut: DictationShortcut) -> String? {
        if let persistenceError = persistenceErrorMessage(for: shortcut) {
            return persistenceError
        }

        let normalized = shortcut.normalized
        switch (normalized.keyCode, normalized.carbonModifierFlags) {
        case (UInt32(kVK_Space), UInt32(cmdKey)):
            return "Command-Space is reserved by Spotlight."
        case (UInt32(kVK_Tab), UInt32(cmdKey)):
            return "Command-Tab is reserved for app switching."
        case (UInt32(kVK_ANSI_Q), UInt32(cmdKey)):
            return "Command-Q is reserved for quitting apps."
        case (UInt32(kVK_ANSI_W), UInt32(cmdKey)):
            return "Command-W is reserved for closing windows."
        default:
            return nil
        }
    }
}

@MainActor
@Observable
final class SettingsStore {
    enum RealtimeProvider: String, CaseIterable, Identifiable {
        case realtimeAPI = "realtime_api"
        case mlxAudio = "mlx_audio"

        var id: String { rawValue }

        var displayName: String {
            switch self {
            case .realtimeAPI:
                return "vLLM/voxmlx"
            case .mlxAudio:
                return "mlx-audio"
            }
        }

        var defaultEndpoint: String {
            switch self {
            case .realtimeAPI:
                return "ws://127.0.0.1:8000/v1/realtime"
            case .mlxAudio:
                return "ws://127.0.0.1:8000/v1/audio/transcriptions/realtime"
            }
        }

        var defaultModelName: String {
            switch self {
            case .realtimeAPI:
                return "T0mSIlver/Voxtral-Mini-4B-Realtime-2602-MLX-4bit"
            case .mlxAudio:
                return "mlx-community/Voxtral-Mini-4B-Realtime-2602-4bit"
            }
        }
    }

    private enum Keys {
        static let realtimeProvider = "settings.realtime_provider"
        static let realtimeAPIEndpointURL = "settings.realtime_api_endpoint_url"
        static let mlxAudioEndpointURL = "settings.mlx_audio_endpoint_url"
        static let apiKey = "settings.api_key"
        static let realtimeAPIModelName = "settings.realtime_api_model_name"
        static let mlxAudioModelName = "settings.mlx_audio_model_name"
        static let commitIntervalSeconds = "settings.commit_interval_seconds"
        static let mlxAudioTranscriptionDelayMilliseconds =
            "settings.mlx_audio_transcription_delay_ms"
        static let dictationOutputMode = "settings.dictation_output_mode"
        static let dictationShortcutMode = "settings.dictation_shortcut_mode"
        static let autoCopyEnabled = "settings.auto_copy_enabled"
        static let selectedInputDeviceUID = "settings.selected_input_device_uid"
        static let dictationShortcutEnabled = "settings.dictation_shortcut_enabled"
        static let dictationShortcutKeyCode = "settings.dictation_shortcut_key_code"
        static let dictationShortcutCarbonModifierFlags =
            "settings.dictation_shortcut_carbon_modifiers"
        static let overlayBufferShortcutEnabled = "settings.overlay_buffer_shortcut_enabled"
        static let overlayBufferShortcutKeyCode = "settings.overlay_buffer_shortcut_key_code"
        static let overlayBufferShortcutCarbonModifierFlags =
            "settings.overlay_buffer_shortcut_carbon_modifiers"
        static let liveAutoPasteShortcutEnabled = "settings.live_auto_paste_shortcut_enabled"
        static let liveAutoPasteShortcutKeyCode = "settings.live_auto_paste_shortcut_key_code"
        static let liveAutoPasteShortcutCarbonModifierFlags =
            "settings.live_auto_paste_shortcut_carbon_modifiers"
        static let sendNowCommandEnabled = "settings.send_now_command_enabled"
        static let sendNowTriggerPhrase = "settings.send_now_trigger_phrase"
        static let sendNowTargetAppIDs = "settings.send_now_target_app_ids"
        static let ghosttyAgentModeEnabled = "settings.ghostty_agent_mode_enabled"
        static let llmPolishingEnabled = "settings.llm_polishing_enabled"
        static let llmPolishingEndpointURL = "settings.llm_polishing_endpoint_url"
        static let llmPolishingAPIKey = "settings.llm_polishing_api_key"
        static let llmPolishingModel = "settings.llm_polishing_model"
        static let replacementDictionaryEnabled = "settings.replacement_dictionary_enabled"
    }

    private let defaults: UserDefaults

    static let defaultDictationShortcut = DictationShortcut(
        keyCode: UInt32(kVK_Space),
        carbonModifierFlags: UInt32(optionKey)
    )
    static let defaultSendNowTriggerPhrase = "send now"
    static let defaultSendNowTargetApps: [SendNowTargetApp] = [.ghostty]

    var realtimeProvider: RealtimeProvider {
        didSet { defaults.set(realtimeProvider.rawValue, forKey: Keys.realtimeProvider) }
    }

    var realtimeAPIEndpointURL: String {
        didSet { defaults.set(realtimeAPIEndpointURL, forKey: Keys.realtimeAPIEndpointURL) }
    }

    var mlxAudioEndpointURL: String {
        didSet { defaults.set(mlxAudioEndpointURL, forKey: Keys.mlxAudioEndpointURL) }
    }

    var apiKey: String {
        didSet { defaults.set(apiKey, forKey: Keys.apiKey) }
    }

    var realtimeAPIModelName: String {
        didSet { defaults.set(realtimeAPIModelName, forKey: Keys.realtimeAPIModelName) }
    }

    var mlxAudioModelName: String {
        didSet { defaults.set(mlxAudioModelName, forKey: Keys.mlxAudioModelName) }
    }

    var commitIntervalSeconds: Double {
        didSet { defaults.set(commitIntervalSeconds, forKey: Keys.commitIntervalSeconds) }
    }

    var mlxAudioTranscriptionDelayMilliseconds: Int {
        didSet {
            defaults.set(
                mlxAudioTranscriptionDelayMilliseconds,
                forKey: Keys.mlxAudioTranscriptionDelayMilliseconds)
        }
    }

    var autoCopyEnabled: Bool {
        didSet { defaults.set(autoCopyEnabled, forKey: Keys.autoCopyEnabled) }
    }

    var dictationOutputMode: DictationOutputMode {
        didSet { defaults.set(dictationOutputMode.rawValue, forKey: Keys.dictationOutputMode) }
    }

    var dictationShortcutMode: DictationShortcutMode {
        didSet { defaults.set(dictationShortcutMode.rawValue, forKey: Keys.dictationShortcutMode) }
    }

    var selectedInputDeviceUID: String {
        didSet { defaults.set(selectedInputDeviceUID, forKey: Keys.selectedInputDeviceUID) }
    }

    var dictationShortcutEnabled: Bool {
        didSet { defaults.set(dictationShortcutEnabled, forKey: Keys.dictationShortcutEnabled) }
    }

    private var dictationShortcutKeyCode: UInt32 {
        didSet { defaults.set(dictationShortcutKeyCode, forKey: Keys.dictationShortcutKeyCode) }
    }

    private var dictationShortcutCarbonModifierFlags: UInt32 {
        didSet {
            defaults.set(
                dictationShortcutCarbonModifierFlags,
                forKey: Keys.dictationShortcutCarbonModifierFlags)
        }
    }

    var overlayBufferShortcutEnabled: Bool {
        didSet { defaults.set(overlayBufferShortcutEnabled, forKey: Keys.overlayBufferShortcutEnabled) }
    }

    private var overlayBufferShortcutKeyCode: UInt32 {
        didSet { defaults.set(overlayBufferShortcutKeyCode, forKey: Keys.overlayBufferShortcutKeyCode) }
    }

    private var overlayBufferShortcutCarbonModifierFlags: UInt32 {
        didSet {
            defaults.set(
                overlayBufferShortcutCarbonModifierFlags,
                forKey: Keys.overlayBufferShortcutCarbonModifierFlags)
        }
    }

    var liveAutoPasteShortcutEnabled: Bool {
        didSet { defaults.set(liveAutoPasteShortcutEnabled, forKey: Keys.liveAutoPasteShortcutEnabled) }
    }

    private var liveAutoPasteShortcutKeyCode: UInt32 {
        didSet { defaults.set(liveAutoPasteShortcutKeyCode, forKey: Keys.liveAutoPasteShortcutKeyCode) }
    }

    private var liveAutoPasteShortcutCarbonModifierFlags: UInt32 {
        didSet {
            defaults.set(
                liveAutoPasteShortcutCarbonModifierFlags,
                forKey: Keys.liveAutoPasteShortcutCarbonModifierFlags)
        }
    }

    var sendNowCommandEnabled: Bool {
        didSet { defaults.set(sendNowCommandEnabled, forKey: Keys.sendNowCommandEnabled) }
    }

    var sendNowTriggerPhrase: String {
        didSet { defaults.set(sendNowTriggerPhrase, forKey: Keys.sendNowTriggerPhrase) }
    }

    private var sendNowTargetAppIDs: [String] {
        didSet { defaults.set(sendNowTargetAppIDs, forKey: Keys.sendNowTargetAppIDs) }
    }

    var llmPolishingEnabled: Bool {
        didSet { defaults.set(llmPolishingEnabled, forKey: Keys.llmPolishingEnabled) }
    }

    var llmPolishingEndpointURL: String {
        didSet { defaults.set(llmPolishingEndpointURL, forKey: Keys.llmPolishingEndpointURL) }
    }

    var llmPolishingAPIKey: String {
        didSet { defaults.set(llmPolishingAPIKey, forKey: Keys.llmPolishingAPIKey) }
    }

    var llmPolishingModel: String {
        didSet { defaults.set(llmPolishingModel, forKey: Keys.llmPolishingModel) }
    }

    var replacementDictionaryEnabled: Bool {
        didSet {
            defaults.set(replacementDictionaryEnabled, forKey: Keys.replacementDictionaryEnabled)
        }
    }

    init(
        defaults: UserDefaults = .standard,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) {
        self.defaults = defaults

        let configuredProvider = Self.loadString(
            defaults: defaults, key: Keys.realtimeProvider,
            envKey: "REALTIME_PROVIDER", fallback: RealtimeProvider.realtimeAPI.rawValue,
            environment: environment
        )
        realtimeProvider = RealtimeProvider(rawValue: configuredProvider) ?? .realtimeAPI

        realtimeAPIEndpointURL = Self.loadString(
            defaults: defaults, key: Keys.realtimeAPIEndpointURL,
            envKey: "REALTIME_ENDPOINT", fallback: RealtimeProvider.realtimeAPI.defaultEndpoint,
            environment: environment
        )

        mlxAudioEndpointURL = Self.loadString(
            defaults: defaults, key: Keys.mlxAudioEndpointURL,
            envKey: "MLX_AUDIO_REALTIME_ENDPOINT",
            fallback: RealtimeProvider.mlxAudio.defaultEndpoint,
            environment: environment
        )

        apiKey = Self.loadString(
            defaults: defaults, key: Keys.apiKey,
            envKey: "OPENAI_API_KEY", fallback: "",
            environment: environment
        )

        realtimeAPIModelName = Self.loadModelName(
            defaults: defaults, key: Keys.realtimeAPIModelName,
            envKey: "REALTIME_MODEL", provider: .realtimeAPI,
            environment: environment
        )

        mlxAudioModelName = Self.loadModelName(
            defaults: defaults, key: Keys.mlxAudioModelName,
            envKey: "MLX_AUDIO_REALTIME_MODEL", provider: .mlxAudio,
            environment: environment
        )

        let storedInterval = defaults.double(forKey: Keys.commitIntervalSeconds)
        commitIntervalSeconds =
            storedInterval > 0
            ? min(max(storedInterval, 0.1), 1.0)
            : 0.9

        let delayDefault = 900
        if defaults.object(forKey: Keys.mlxAudioTranscriptionDelayMilliseconds) != nil {
            mlxAudioTranscriptionDelayMilliseconds = Self.clampedTranscriptionDelay(
                defaults.integer(forKey: Keys.mlxAudioTranscriptionDelayMilliseconds))
        } else if let envDelay = environment["MLX_AUDIO_REALTIME_TRANSCRIPTION_DELAY_MS"],
            let parsedDelay = Int(envDelay)
        {
            mlxAudioTranscriptionDelayMilliseconds = Self.clampedTranscriptionDelay(parsedDelay)
        } else {
            mlxAudioTranscriptionDelayMilliseconds = delayDefault
        }

        autoCopyEnabled = Self.loadBool(
            defaults: defaults, key: Keys.autoCopyEnabled, fallback: false)
        if let storedOutputMode = defaults.string(forKey: Keys.dictationOutputMode),
            let parsedMode = DictationOutputMode(rawValue: storedOutputMode)
        {
            dictationOutputMode = parsedMode
        } else {
            dictationOutputMode = .overlayBuffer
        }
        if let storedShortcutMode = defaults.string(forKey: Keys.dictationShortcutMode),
            let parsedShortcutMode = DictationShortcutMode(rawValue: storedShortcutMode)
        {
            dictationShortcutMode = parsedShortcutMode
        } else {
            dictationShortcutMode = .toggle
        }
        selectedInputDeviceUID = defaults.string(forKey: Keys.selectedInputDeviceUID) ?? ""
        dictationShortcutEnabled = Self.loadBool(
            defaults: defaults, key: Keys.dictationShortcutEnabled, fallback: true)

        let storedKeyCode = (defaults.object(forKey: Keys.dictationShortcutKeyCode) as? NSNumber)?
            .uint32Value
        let storedModifierFlags =
            (defaults.object(forKey: Keys.dictationShortcutCarbonModifierFlags) as? NSNumber)?
            .uint32Value

        let resolvedShortcut: DictationShortcut
        if let storedKeyCode, let storedModifierFlags {
            let candidate = DictationShortcut(
                keyCode: storedKeyCode,
                carbonModifierFlags: storedModifierFlags
            ).normalized
            resolvedShortcut =
                DictationShortcutValidation.persistenceErrorMessage(for: candidate) == nil
                ? candidate : Self.defaultDictationShortcut
        } else {
            resolvedShortcut = Self.defaultDictationShortcut
        }

        dictationShortcutKeyCode = resolvedShortcut.keyCode
        dictationShortcutCarbonModifierFlags = resolvedShortcut.carbonModifierFlags

        let overlayShortcut = Self.loadOptionalShortcut(
            defaults: defaults,
            enabledKey: Keys.overlayBufferShortcutEnabled,
            keyCodeKey: Keys.overlayBufferShortcutKeyCode,
            modifierFlagsKey: Keys.overlayBufferShortcutCarbonModifierFlags,
            fallback: Self.defaultDictationShortcut
        )
        overlayBufferShortcutEnabled = overlayShortcut.isEnabled
        overlayBufferShortcutKeyCode = overlayShortcut.shortcut.keyCode
        overlayBufferShortcutCarbonModifierFlags = overlayShortcut.shortcut.carbonModifierFlags

        let liveShortcut = Self.loadOptionalShortcut(
            defaults: defaults,
            enabledKey: Keys.liveAutoPasteShortcutEnabled,
            keyCodeKey: Keys.liveAutoPasteShortcutKeyCode,
            modifierFlagsKey: Keys.liveAutoPasteShortcutCarbonModifierFlags,
            fallback: Self.defaultDictationShortcut
        )
        liveAutoPasteShortcutEnabled = liveShortcut.isEnabled
        liveAutoPasteShortcutKeyCode = liveShortcut.shortcut.keyCode
        liveAutoPasteShortcutCarbonModifierFlags = liveShortcut.shortcut.carbonModifierFlags

        if defaults.object(forKey: Keys.sendNowCommandEnabled) != nil {
            sendNowCommandEnabled = defaults.bool(forKey: Keys.sendNowCommandEnabled)
        } else {
            sendNowCommandEnabled = Self.loadBool(
                defaults: defaults,
                key: Keys.ghosttyAgentModeEnabled,
                fallback: false
            )
        }
        sendNowTriggerPhrase = defaults.string(forKey: Keys.sendNowTriggerPhrase)
            ?? Self.defaultSendNowTriggerPhrase
        sendNowTargetAppIDs = Self.loadSendNowTargetAppIDs(defaults: defaults)

        llmPolishingEnabled = Self.loadBool(
            defaults: defaults, key: Keys.llmPolishingEnabled, fallback: false)
        llmPolishingEndpointURL = Self.loadString(
            defaults: defaults, key: Keys.llmPolishingEndpointURL,
            envKey: "LLM_POLISHING_ENDPOINT",
            fallback: "http://127.0.0.1:8080/v1/chat/completions",
            environment: environment
        )
        llmPolishingAPIKey = Self.loadString(
            defaults: defaults, key: Keys.llmPolishingAPIKey,
            envKey: "LLM_POLISHING_API_KEY", fallback: "",
            environment: environment
        )
        llmPolishingModel = Self.loadString(
            defaults: defaults, key: Keys.llmPolishingModel,
            envKey: "LLM_POLISHING_MODEL", fallback: "mlx-community/Qwen3.5-0.8B-8bit",
            environment: environment
        )
        replacementDictionaryEnabled = Self.loadBool(
            defaults: defaults, key: Keys.replacementDictionaryEnabled, fallback: false)
    }

    // MARK: - Init Helpers

    private static func loadString(
        defaults: UserDefaults, key: String, envKey: String, fallback: String,
        environment: [String: String]
    ) -> String {
        defaults.string(forKey: key)
            ?? environment[envKey]
            ?? fallback
    }

    private static func loadBool(
        defaults: UserDefaults, key: String, fallback: Bool
    ) -> Bool {
        defaults.object(forKey: key) != nil
            ? defaults.bool(forKey: key)
            : fallback
    }

    private static func loadOptionalShortcut(
        defaults: UserDefaults,
        enabledKey: String,
        keyCodeKey: String,
        modifierFlagsKey: String,
        fallback: DictationShortcut
    ) -> (isEnabled: Bool, shortcut: DictationShortcut) {
        let isEnabled = loadBool(defaults: defaults, key: enabledKey, fallback: false)
        let storedKeyCode = (defaults.object(forKey: keyCodeKey) as? NSNumber)?.uint32Value
        let storedModifierFlags = (defaults.object(forKey: modifierFlagsKey) as? NSNumber)?.uint32Value

        guard let storedKeyCode, let storedModifierFlags else {
            return (isEnabled, fallback)
        }

        let candidate = DictationShortcut(
            keyCode: storedKeyCode,
            carbonModifierFlags: storedModifierFlags
        ).normalized

        guard DictationShortcutValidation.persistenceErrorMessage(for: candidate) == nil else {
            return (isEnabled, fallback)
        }

        return (isEnabled, candidate)
    }

    private static func loadModelName(
        defaults: UserDefaults,
        key: String,
        envKey: String,
        provider: RealtimeProvider,
        environment: [String: String]
    ) -> String {
        let configured = loadString(
            defaults: defaults,
            key: key,
            envKey: envKey,
            fallback: provider.defaultModelName,
            environment: environment
        )
        let normalized = normalizedModelName(from: configured)
        return normalized.isEmpty ? provider.defaultModelName : normalized
    }

    private static func loadSendNowTargetAppIDs(defaults: UserDefaults) -> [String] {
        guard let storedIDs = defaults.array(forKey: Keys.sendNowTargetAppIDs) as? [String] else {
            return defaultSendNowTargetApps.map(\.rawValue)
        }

        let storedIDSet = Set(storedIDs)
        return SendNowTargetApp.allCases
            .map(\.rawValue)
            .filter { storedIDSet.contains($0) }
    }

    var trimmedAPIKey: String {
        apiKey.trimmed
    }

    var effectiveModelName: String {
        effectiveModelName(for: realtimeProvider)
    }

    var displayModelName: String {
        effectiveModelName
    }

    var endpointPlaceholder: String {
        realtimeProvider.defaultEndpoint
    }

    var modelPlaceholder: String {
        realtimeProvider.defaultModelName
    }

    var dictationShortcut: DictationShortcut? {
        guard dictationShortcutEnabled else { return nil }

        let candidate = DictationShortcut(
            keyCode: dictationShortcutKeyCode,
            carbonModifierFlags: dictationShortcutCarbonModifierFlags
        ).normalized

        if DictationShortcutValidation.persistenceErrorMessage(for: candidate) != nil {
            return Self.defaultDictationShortcut
        }

        return candidate
    }

    var overlayBufferPushToTalkShortcut: DictationShortcut? {
        guard overlayBufferShortcutEnabled else { return nil }

        return resolvedShortcut(
            keyCode: overlayBufferShortcutKeyCode,
            modifierFlags: overlayBufferShortcutCarbonModifierFlags
        )
    }

    var liveAutoPasteToggleShortcut: DictationShortcut? {
        guard liveAutoPasteShortcutEnabled else { return nil }

        return resolvedShortcut(
            keyCode: liveAutoPasteShortcutKeyCode,
            modifierFlags: liveAutoPasteShortcutCarbonModifierFlags
        )
    }

    private func resolvedShortcut(keyCode: UInt32, modifierFlags: UInt32) -> DictationShortcut {
        let candidate = DictationShortcut(
            keyCode: keyCode,
            carbonModifierFlags: modifierFlags
        ).normalized

        if DictationShortcutValidation.persistenceErrorMessage(for: candidate) != nil {
            return Self.defaultDictationShortcut
        }

        return candidate
    }

    var effectiveSendNowTriggerPhrase: String {
        let trimmed = sendNowTriggerPhrase.trimmed
        return trimmed.isEmpty ? Self.defaultSendNowTriggerPhrase : trimmed
    }

    var selectedSendNowTargetApps: [SendNowTargetApp] {
        let selectedIDSet = Set(sendNowTargetAppIDs)
        return SendNowTargetApp.allCases.filter { selectedIDSet.contains($0.rawValue) }
    }

    func isSendNowTargetAppSelected(_ app: SendNowTargetApp) -> Bool {
        sendNowTargetAppIDs.contains(app.rawValue)
    }

    func setSendNowTargetApp(_ app: SendNowTargetApp, isSelected: Bool) {
        let selectedIDs = Set(sendNowTargetAppIDs)
        let updatedIDs = isSelected
            ? selectedIDs.union([app.rawValue])
            : selectedIDs.subtracting([app.rawValue])
        sendNowTargetAppIDs = SendNowTargetApp.allCases
            .map(\.rawValue)
            .filter { updatedIDs.contains($0) }
    }

    func matchesSendNowTargetApp(bundleIdentifier: String) -> Bool {
        sendNowTargetApp(for: bundleIdentifier) != nil
    }

    func sendNowTargetApp(for bundleIdentifier: String) -> SendNowTargetApp? {
        selectedSendNowTargetApps.first { $0.bundleIdentifiers.contains(bundleIdentifier) }
    }

    func setDictationShortcut(_ shortcut: DictationShortcut?) {
        guard let shortcut else {
            dictationShortcutEnabled = false
            return
        }

        let normalizedShortcut = shortcut.normalized
        let resolvedShortcut: DictationShortcut
        if DictationShortcutValidation.persistenceErrorMessage(for: normalizedShortcut) == nil {
            resolvedShortcut = normalizedShortcut
        } else {
            resolvedShortcut = Self.defaultDictationShortcut
        }

        dictationShortcutKeyCode = resolvedShortcut.keyCode
        dictationShortcutCarbonModifierFlags = resolvedShortcut.carbonModifierFlags
        dictationShortcutEnabled = true
    }

    func resetDictationShortcutToDefault() {
        setDictationShortcut(Self.defaultDictationShortcut)
    }

    func setOverlayBufferPushToTalkShortcut(_ shortcut: DictationShortcut?) {
        let resolved = resolvedPersistableShortcut(shortcut)
        overlayBufferShortcutKeyCode = resolved.keyCode
        overlayBufferShortcutCarbonModifierFlags = resolved.carbonModifierFlags
        overlayBufferShortcutEnabled = shortcut != nil
    }

    func setLiveAutoPasteToggleShortcut(_ shortcut: DictationShortcut?) {
        let resolved = resolvedPersistableShortcut(shortcut)
        liveAutoPasteShortcutKeyCode = resolved.keyCode
        liveAutoPasteShortcutCarbonModifierFlags = resolved.carbonModifierFlags
        liveAutoPasteShortcutEnabled = shortcut != nil
    }

    private func resolvedPersistableShortcut(_ shortcut: DictationShortcut?) -> DictationShortcut {
        guard let shortcut else { return Self.defaultDictationShortcut }

        let normalizedShortcut = shortcut.normalized
        if DictationShortcutValidation.persistenceErrorMessage(for: normalizedShortcut) == nil {
            return normalizedShortcut
        }

        return Self.defaultDictationShortcut
    }

    func modelName(for provider: RealtimeProvider) -> String {
        switch provider {
        case .realtimeAPI:
            return realtimeAPIModelName
        case .mlxAudio:
            return mlxAudioModelName
        }
    }

    func effectiveModelName(for provider: RealtimeProvider) -> String {
        let normalized = Self.normalizedModelName(from: modelName(for: provider))
        return normalized.isEmpty ? provider.defaultModelName : normalized
    }

    func endpointURL(for provider: RealtimeProvider) -> String {
        switch provider {
        case .realtimeAPI:
            return realtimeAPIEndpointURL
        case .mlxAudio:
            return mlxAudioEndpointURL
        }
    }

    var resolvedWebSocketURL: URL? {
        resolvedWebSocketURL(for: realtimeProvider)
    }

    func resolvedWebSocketURL(for provider: RealtimeProvider) -> URL? {
        let trimmed = endpointURL(for: provider).trimmed
        guard !trimmed.isEmpty else { return nil }

        if trimmed.hasPrefix("ws://") || trimmed.hasPrefix("wss://") {
            return URL(string: trimmed)
        }

        if trimmed.hasPrefix("http://") {
            return URL(string: "ws://" + trimmed.dropFirst("http://".count))
        }

        if trimmed.hasPrefix("https://") {
            return URL(string: "wss://" + trimmed.dropFirst("https://".count))
        }

        return URL(string: "ws://\(trimmed)")
    }

    private static func normalizedModelName(from raw: String) -> String {
        let trimmed = raw.trimmed
        guard !trimmed.isEmpty else { return "" }

        let lines =
            trimmed
            .split(whereSeparator: \.isNewline)
            .map { String($0).trimmed }
            .filter { !$0.isEmpty }

        guard let candidate = lines.last else {
            return trimmed
        }

        if candidate.contains(" ") {
            let tokens = candidate.split(whereSeparator: \.isWhitespace).map(String.init)
            if let token = tokens.last {
                return token
            }
        }

        return candidate
    }

    private static func clampedTranscriptionDelay(_ value: Int) -> Int {
        min(max(value, 400), 2_000)
    }

    var llmPolishingConfiguration: LLMPolishingConfiguration? {
        guard llmPolishingEnabled else { return nil }
        let trimmedEndpoint = llmPolishingEndpointURL.trimmed
        guard !trimmedEndpoint.isEmpty, let url = URL(string: trimmedEndpoint) else { return nil }
        guard
            let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
            let scheme = components.scheme?.lowercased(),
            (scheme == "http" || scheme == "https"),
            components.host != nil
        else {
            return nil
        }
        return LLMPolishingConfiguration(
            endpointURL: url,
            apiKey: llmPolishingAPIKey.trimmed,
            model: llmPolishingModel.trimmed.isEmpty
                ? "mlx-community/Qwen3.5-0.8B-8bit"
                : llmPolishingModel.trimmed
        )
    }
}
