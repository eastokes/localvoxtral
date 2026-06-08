import Foundation

enum SendNowCommandAction: Equatable {
    case insertText(String)
    case pressReturn(deleteCharacterCount: Int)
    case insertTextAndPressReturn(String, deleteCharacterCount: Int)
    case none
}

enum SendNowCommandParser {
    static func parse(_ text: String, triggerPhrase: String) -> SendNowCommandAction {
        let trimmed = text.trimmed
        guard !trimmed.isEmpty else { return .none }

        let normalizedTriggerPhrase = normalizedCommandText(triggerPhrase)
        guard !normalizedTriggerPhrase.isEmpty else {
            return .insertText(trimmed)
        }

        let normalized = normalizedCommandText(trimmed)
        if normalized == normalizedTriggerPhrase {
            return .pressReturn(deleteCharacterCount: trimmed.count)
        }

        guard normalized.hasSuffix(normalizedTriggerPhrase) else {
            return .insertText(trimmed)
        }

        let prefixLength = normalized.count - normalizedTriggerPhrase.count
        if prefixLength > 0 {
            let boundaryIndex = normalized.index(normalized.startIndex, offsetBy: prefixLength)
            let previousIndex = normalized.index(before: boundaryIndex)
            guard TextMergingAlgorithms.isWordBoundaryCharacter(normalized[previousIndex]) else {
                return .insertText(trimmed)
            }
        }

        let prefixEnd = trimmed.index(trimmed.startIndex, offsetBy: min(prefixLength, trimmed.count))
        let textBeforeCommand = String(trimmed[..<prefixEnd])
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: ".,;:!?"))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let deleteCharacterCount = trimmed.count - textBeforeCommand.count

        return textBeforeCommand.isEmpty
            ? .pressReturn(deleteCharacterCount: trimmed.count)
            : .insertTextAndPressReturn(
                textBeforeCommand,
                deleteCharacterCount: deleteCharacterCount
            )
    }

    static func containsReturnCommand(_ text: String, triggerPhrase: String) -> Bool {
        switch parse(text, triggerPhrase: triggerPhrase) {
        case .pressReturn, .insertTextAndPressReturn:
            return true
        case .insertText, .none:
            return false
        }
    }

    static func normalizedCommandText(_ text: String) -> String {
        text.lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: ".,;:!?"))
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
