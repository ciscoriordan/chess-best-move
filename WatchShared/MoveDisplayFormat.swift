import Foundation

enum MoveDisplayFormat: String, CaseIterable, Codable, Sendable, Identifiable {
    case words
    case notation
    var id: String { rawValue }

    var label: String {
        switch self {
        case .words: String(localized: "Words")
        case .notation: String(localized: "Chess Notation")
        }
    }

    func text(words: String?, notation: String?) -> String? {
        let preferred = self == .words ? words : notation
        let fallback = self == .words ? notation : words
        return preferred.flatMap { $0.isEmpty ? nil : $0 } ?? fallback.flatMap { $0.isEmpty ? nil : $0 }
    }
}
