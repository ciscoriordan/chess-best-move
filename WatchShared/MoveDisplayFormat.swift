import Foundation

enum MoveDisplayFormat: String, CaseIterable, Codable, Sendable, Identifiable {
    case words
    case notation
    case both
    var id: String { rawValue }

    var label: String {
        switch self {
        case .words: String(localized: "Plain English")
        case .notation: String(localized: "Chess Notation")
        case .both: String(localized: "Both")
        }
    }

    func text(words: String?, notation: String?) -> String? {
        if self == .both {
            let parts = [words, notation].compactMap { $0 }.filter { !$0.isEmpty }
            return parts.isEmpty ? nil : parts.joined(separator: "\n")
        }
        let preferred = self == .words ? words : notation
        let fallback = self == .words ? notation : words
        return preferred.flatMap { $0.isEmpty ? nil : $0 } ?? fallback.flatMap { $0.isEmpty ? nil : $0 }
    }
}
