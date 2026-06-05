import Foundation
import os

extension DictationViewModel {
    // MARK: - Realtime Event Routing

    func handle(event: RealtimeEvent, source: ActiveClientSource) {
        guard source == activeClientSource else {
            // During stop-finalization, be permissive with disconnect routing.
            // Some backends can close on a different callback path than expected.
            if isFinalizingStop, case .disconnected = event {
                handleDisconnectedEvent()
            }
            return
        }

        switch event {
        case .connected:
            handleConnectedEvent()
        case .disconnected:
            handleDisconnectedEvent()
        case .status(let message):
            handleStatusEvent(message)
        case .partialTranscript(let delta):
            handlePartialTranscriptEvent(delta, source: source)
        case .finalTranscript(let text):
            handleFinalTranscriptEvent(text, source: source)
        case .transcriptionFinalized where source == .realtimeAPI:
            handleTranscriptionFinalizedEvent()
        case .transcriptionFinalized:
            break
        case .error(let message):
            handleErrorEvent(message)
        }
    }

    // MARK: - Event Handlers

    private func handleConnectedEvent() {
        cancelConnectTimeout()
        if isConnectingRealtimeSession {
            if shouldCancelPushToTalkStartAfterConnect() {
                abortConnectingSession()
                setRealtimeIndicatorIdle()
                statusText = "Ready"
                return
            }
            setRealtimeIndicatorConnected()
            startAudioCaptureAfterConnection()
            return
        }
        setRealtimeIndicatorConnected()
        statusText = activeStatusText
    }

    private func handleDisconnectedEvent() {
        cancelConnectTimeout()
        if isConnectingRealtimeSession {
            abortConnectingSession(disconnectSocket: false)
            handleConnectFailure(
                status: "Failed to connect.",
                message: "Unable to establish realtime connection.",
                technicalDetails: lastError?.trimmed.isEmpty == false
                    ? lastError : nil
            )
            return
        }

        if isFinalizingStop {
            finishStoppedSession(promotePendingSegment: true)
            return
        }
        guard isDictating else {
            setRealtimeIndicatorIdle()
            return
        }
        commitTask?.cancel()
        commitTask = nil
        audioSendTask?.cancel()
        audioSendTask = nil
        healthMonitor.stop()
        isAwaitingMicrophonePermission = false
        microphone.stop()
        isDictating = false
        finishStoppedSession(promotePendingSegment: true)
        let message = "Connection lost. Dictation stopped."
        statusText = message
        lastError = message
        logConnectionFailure(
            message: message,
            technicalDetails:
                "Realtime websocket disconnected unexpectedly during active dictation."
        )
        markRecentConnectionFailureIndicator()
    }

    private func handleStatusEvent(_ message: String) {
        if isConnectingRealtimeSession {
            statusText = "Connecting to realtime backend..."
            return
        }
        if !acceptsRealtimeEvents {
            statusText = "Ready"
            return
        }
        if isFinalizingStop {
            statusText = "Finalizing..."
            return
        }

        let normalized = message.trimmed.lowercased()
        if normalized.contains("session") || normalized.contains("connected")
            || normalized.contains("disconnected")
        {
            statusText = "Listening..."
        } else {
            statusText = message
        }
    }

    private func handlePartialTranscriptEvent(_ delta: String, source: ActiveClientSource) {
        guard acceptsRealtimeEvents else { return }
        let processedDelta = preprocessIncomingTranscriptChunk(delta)
        guard !processedDelta.isEmpty else { return }
        if source == .mlxAudio {
            handleMlxPartialTranscript(processedDelta)
            return
        }
        if isFinalizingStop {
            realtimeFinalizationLastActivityAt = Date()
        }

        pendingSegmentText.append(processedDelta)
        livePartialText = pendingSegmentText
        if isGhosttyAgentModeActive,
           shouldSuppressGhosttyAgentPostSubmitPunctuation(processedDelta)
        {
            pendingSegmentText = ""
            livePartialText = ""
            refreshOverlayBufferSession()
            return
        }

        if isLiveAutoPasteModeEnabled {
            textInsertion.enqueueRealtimeInsertion(processedDelta)
            if let accessibilityError = textInsertion.lastAccessibilityError {
                lastError = accessibilityError
            }
            if isGhosttyAgentModeActive,
               handleGhosttyAgentPartialCommandIfNeeded()
            {
                return
            }
        }
        statusText = isFinalizingStop ? "Finalizing..." : "Transcribing..."
        refreshOverlayBufferSession()
    }

    private func handleFinalTranscriptEvent(_ text: String, source: ActiveClientSource) {
        guard acceptsRealtimeEvents else { return }
        let processedText = preprocessIncomingTranscriptChunk(text)
        if source == .mlxAudio {
            handleMlxFinalTranscript(processedText)
            return
        }
        if isFinalizingStop {
            realtimeFinalizationLastActivityAt = Date()
        }

        let finalizedSegment = resolvedFinalizedSegment(from: processedText)
        let hadLiveDelta = !pendingSegmentText.trimmed.isEmpty
            || !livePartialText.trimmed.isEmpty
        if isGhosttyAgentModeActive,
           isDuplicateGhosttyAgentLiveSubmittedSegment(finalizedSegment)
        {
            livePartialText = ""
            pendingSegmentText = ""
            refreshOverlayBufferSession()
            return
        }
        guard !finalizedSegment.isEmpty else {
            livePartialText = ""
            pendingSegmentText = ""
            refreshOverlayBufferSession()
            return
        }

        appendToTranscript(finalizedSegment)
        currentDictationEventText = TextMergingAlgorithms.appendToCurrentDictationEvent(
            segment: finalizedSegment,
            existingText: currentDictationEventText
        )
        lastFinalSegment = currentDictationEventText
        livePartialText = ""
        pendingSegmentText = ""
        statusText = activeStatusText

        if isGhosttyAgentModeActive {
            guard !isFinalizingStop else {
                if isLiveAutoPasteModeEnabled, settings.autoCopyEnabled {
                    copyLatestSegment(updateStatus: false)
                }
                refreshOverlayBufferSession()
                return
            }
            handleGhosttyAgentFinalizedSegment(
                finalizedSegment,
                textAlreadyInserted: hadLiveDelta
            )
        } else if !hadLiveDelta, isLiveAutoPasteModeEnabled {
            textInsertion.enqueueRealtimeInsertion(finalizedSegment)
            if let accessibilityError = textInsertion.lastAccessibilityError {
                lastError = accessibilityError
            }
        }

        if isLiveAutoPasteModeEnabled, settings.autoCopyEnabled {
            copyLatestSegment(updateStatus: false)
        }
        refreshOverlayBufferSession()
    }

    private func handleTranscriptionFinalizedEvent() {
        guard isFinalizingStop else { return }
        debugLog("transcription finalized, disconnecting")
        activeRealtimeClient().disconnect()
    }

    private func handleErrorEvent(_ message: String) {
        if isConnectingRealtimeSession {
            abortConnectingSession()
            handleConnectFailure(
                status: "Failed to connect.",
                message: "Unable to establish realtime connection.",
                technicalDetails: message
            )
            return
        }
        if !acceptsRealtimeEvents {
            statusText = "Ready"
            return
        }
        if isFinalizingStop {
            debugLog("realtime error while finalizing: \(message)")
            return
        }

        statusText = "Realtime error."
        lastError = message
        Log.dictation.error("Realtime error: \(message, privacy: .public)")
    }

    // MARK: - mlx-audio Transcript Handling

    func handleMlxPartialTranscript(_ delta: String) {
        let mergedHypothesis = TextMergingAlgorithms.normalizeTranscriptionFormatting(
            delta.trimmed
        )
        guard !mergedHypothesis.isEmpty else { return }
        let insertionMode: MlxInsertionMode =
            isLiveAutoPasteModeEnabled ? .realtime : .none
        let result = mlxStabilizer.commitHypothesis(
            mergedHypothesis,
            isFinal: false,
            insertionMode: insertionMode
        )
        currentDictationEventText = mlxStabilizer.committedEventText
        pendingSegmentText = result.unstableTail
        livePartialText = result.unstableTail

        if isLiveAutoPasteModeEnabled,
            let accessibilityError = textInsertion.lastAccessibilityError
        {
            lastError = accessibilityError
        }
        statusText = isFinalizingStop ? "Finalizing..." : "Transcribing..."
        refreshOverlayBufferSession()
    }

    func handleMlxFinalTranscript(_ text: String) {
        let hypothesis = TextMergingAlgorithms.normalizeTranscriptionFormatting(
            text.trimmed
        )
        guard !hypothesis.isEmpty else {
            livePartialText = ""
            pendingSegmentText = ""
            mlxStabilizer.resetSegment()
            return
        }

        let insertionMode: MlxInsertionMode
        if isLiveAutoPasteModeEnabled {
            insertionMode = isFinalizingStop ? .finalized : .realtime
        } else {
            insertionMode = .none
        }

        _ = mlxStabilizer.commitHypothesis(
            hypothesis,
            isFinal: true,
            insertionMode: insertionMode
        )
        currentDictationEventText = mlxStabilizer.committedEventText

        let finalizedDelta = mlxStabilizer.consumeCommittedSinceLastFinal().trimmed
        if !finalizedDelta.isEmpty {
            appendToTranscript(finalizedDelta)
            if isGhosttyAgentModeActive, !isFinalizingStop {
                handleGhosttyAgentFinalizedSegment(
                    finalizedDelta,
                    textAlreadyInserted: true
                )
            }
        }

        lastFinalSegment = currentDictationEventText
        livePartialText = ""
        pendingSegmentText = ""
        mlxStabilizer.resetSegment()
        statusText = activeStatusText

        if isLiveAutoPasteModeEnabled, settings.autoCopyEnabled {
            copyLatestSegment(updateStatus: false)
        }
        refreshOverlayBufferSession()
    }

    // MARK: - Segment Promotion

    @discardableResult
    func promotePendingMlxTextToLatestSegment() -> String? {
        let promotion = mlxStabilizer.promotePendingText()
        currentDictationEventText = mlxStabilizer.committedEventText

        if !promotion.allCommitted.isEmpty {
            appendToTranscript(promotion.allCommitted)
        }

        lastFinalSegment = currentDictationEventText
        livePartialText = ""
        pendingSegmentText = ""
        mlxStabilizer.resetSegment()

        if isLiveAutoPasteModeEnabled, settings.autoCopyEnabled {
            copyLatestSegment(updateStatus: false)
        }

        return promotion.newlyPromotedTail
    }

    @discardableResult
    func promotePendingRealtimeTextToLatestSegment() -> String? {
        let pendingSegment = resolvedFinalizedSegment(from: "")
        guard !pendingSegment.isEmpty else { return nil }

        currentDictationEventText = TextMergingAlgorithms.appendToCurrentDictationEvent(
            segment: pendingSegment,
            existingText: currentDictationEventText
        )
        lastFinalSegment = currentDictationEventText
        livePartialText = ""
        pendingSegmentText = ""

        if isLiveAutoPasteModeEnabled, settings.autoCopyEnabled {
            copyLatestSegment(updateStatus: false)
        }

        return pendingSegment
    }

    @discardableResult
    func handleGhosttyAgentFinalizedSegment(
        _ segment: String,
        textAlreadyInserted: Bool = false
    ) -> Bool {
        guard isGhosttyAgentModeActive else { return false }
        let preferredPID = liveAutoPasteTargetAppPID

        switch GhosttyAgentCommandParser.parse(segment) {
        case .none:
            return true

        case .insertText(let text):
            if textAlreadyInserted {
                return true
            }
            return insertGhosttyAgentText(text, preferredPID: preferredPID)

        case .pressReturn(let deleteCharacterCount):
            if textAlreadyInserted,
               !deleteGhosttyAgentText(count: deleteCharacterCount, preferredPID: preferredPID)
            {
                return false
            }
            return postGhosttyAgentReturn(preferredPID: preferredPID)

        case .insertTextAndPressReturn(let text, let deleteCharacterCount):
            if textAlreadyInserted {
                guard deleteGhosttyAgentText(count: deleteCharacterCount, preferredPID: preferredPID) else {
                    return false
                }
            } else {
                guard insertGhosttyAgentText(text, preferredPID: preferredPID) else { return false }
            }
            return postGhosttyAgentReturn(preferredPID: preferredPID)
        }
    }

    private func handleGhosttyAgentPartialCommandIfNeeded() -> Bool {
        let liveSegment = pendingSegmentText.trimmed
        guard GhosttyAgentCommandParser.containsReturnCommand(liveSegment) else {
            return false
        }

        let action = GhosttyAgentCommandParser.parse(liveSegment)
        let submittedText: String
        switch action {
        case .insertTextAndPressReturn(let text, _):
            submittedText = text
        case .pressReturn:
            submittedText = ""
        case .insertText, .none:
            return false
        }

        guard handleGhosttyAgentFinalizedSegment(liveSegment, textAlreadyInserted: true) else {
            return false
        }

        if !submittedText.isEmpty {
            appendToTranscript(submittedText)
            currentDictationEventText = TextMergingAlgorithms.appendToCurrentDictationEvent(
                segment: submittedText,
                existingText: currentDictationEventText
            )
            lastFinalSegment = currentDictationEventText
        }

        lastGhosttyAgentLiveSubmittedSegment = liveSegment
        livePartialText = ""
        pendingSegmentText = ""
        statusText = activeStatusText
        refreshOverlayBufferSession()
        return true
    }

    private func shouldSuppressGhosttyAgentPostSubmitPunctuation(_ delta: String) -> Bool {
        guard lastGhosttyAgentLiveSubmittedSegment != nil else { return false }
        let trimmed = delta.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        return trimmed.unicodeScalars.allSatisfy {
            CharacterSet(charactersIn: ".,;:!?").contains($0)
        }
    }

    private func isDuplicateGhosttyAgentLiveSubmittedSegment(_ segment: String) -> Bool {
        guard let lastGhosttyAgentLiveSubmittedSegment else { return false }
        let normalizedSegment = GhosttyAgentCommandParser.normalizedCommandText(segment)
        let normalizedLastSubmitted = GhosttyAgentCommandParser.normalizedCommandText(
            lastGhosttyAgentLiveSubmittedSegment
        )
        guard !normalizedSegment.isEmpty,
              normalizedSegment == normalizedLastSubmitted
        else {
            return false
        }
        self.lastGhosttyAgentLiveSubmittedSegment = nil
        return true
    }

    private func insertGhosttyAgentText(_ text: String, preferredPID: pid_t?) -> Bool {
        let primaryResult = textInsertion.insertTextPrioritizingKeyboard(
            text,
            preferredAppPID: preferredPID
        )
        if primaryResult.isSuccess {
            return true
        }

        if textInsertion.pasteUsingCommandV(text, preferredAppPID: preferredPID) {
            return true
        }

        if let accessibilityError = textInsertion.lastAccessibilityError {
            lastError = accessibilityError
        } else {
            lastError = "Unable to insert finalized text into Ghostty."
        }
        return false
    }

    private func deleteGhosttyAgentText(count: Int, preferredPID: pid_t?) -> Bool {
        guard textInsertion.postBackspace(count: count, preferredAppPID: preferredPID) else {
            lastError = "Unable to remove spoken command from Ghostty."
            return false
        }
        return true
    }

    private func postGhosttyAgentReturn(preferredPID: pid_t?) -> Bool {
        guard textInsertion.postReturnKey(preferredAppPID: preferredPID) else {
            lastError = "Unable to send Return to Ghostty."
            return false
        }
        return true
    }

    // MARK: - Helpers

    /// Append a finalized segment to the running transcript.
    private func appendToTranscript(_ segment: String) {
        if transcriptText.isEmpty {
            transcriptText = segment
        } else {
            transcriptText += "\n" + segment
        }
    }

    /// Status text appropriate for the current dictation phase.
    private var activeStatusText: String {
        if isDictating { return "Listening..." }
        if isFinalizingStop { return "Finalizing..." }
        return "Ready"
    }

    private func preprocessIncomingTranscriptChunk(_ chunk: String) -> String {
        firstChunkPreprocessor.preprocess(chunk)
    }

    // MARK: - Finalized Segment Resolution

    func resolvedFinalizedSegment(from finalText: String) -> String {
        let finalizedText = finalText.trimmed
        let bufferedText = pendingSegmentText.trimmed
        let fallbackBufferedText = livePartialText.trimmed
        let pendingText = bufferedText.isEmpty ? fallbackBufferedText : bufferedText

        if finalizedText.isEmpty {
            return pendingText
        }

        if pendingText.isEmpty {
            return finalizedText
        }

        if finalizedText.count > pendingText.count, finalizedText.hasPrefix(pendingText) {
            return finalizedText
        }
        if pendingText.hasSuffix(finalizedText) {
            return pendingText
        }
        if pendingText.hasPrefix(finalizedText) {
            return pendingText
        }

        if let pendingLast = pendingText.last,
            let finalizedFirst = finalizedText.first,
            !pendingLast.isWhitespace,
            !finalizedFirst.isWhitespace
        {
            return pendingText + " " + finalizedText
        }
        return pendingText + finalizedText
    }

    func currentOverlayDisplayText() -> String {
        OverlayBufferTextAssembler.displayText(
            committedText: currentDictationEventText,
            pendingText: pendingSegmentText,
            fallbackPendingText: livePartialText
        )
    }

    func currentOverlayCommitText() -> String {
        OverlayBufferTextAssembler.commitText(
            committedText: currentDictationEventText,
            pendingText: pendingSegmentText,
            fallbackPendingText: livePartialText
        )
    }
}
