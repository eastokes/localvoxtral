import Foundation

enum GhosttyAgentCommandAction: Equatable {
    case insertText(String)
    case pressReturn(deleteCharacterCount: Int)
    case insertTextAndPressReturn(String, deleteCharacterCount: Int)
    case none
}

enum GhosttyAgentCommandParser {
    private static let sendPhrase = "send now"

    static func parse(_ text: String) -> GhosttyAgentCommandAction {
        let trimmed = text.trimmed
        guard !trimmed.isEmpty else { return .none }

        let normalized = normalizedCommandText(trimmed)
        if normalized == sendPhrase {
            return .pressReturn(deleteCharacterCount: trimmed.count)
        }

        guard normalized.hasSuffix(sendPhrase) else {
            return .insertText(trimmed)
        }

        let prefixLength = normalized.count - sendPhrase.count
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

    static func containsReturnCommand(_ text: String) -> Bool {
        switch parse(text) {
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
