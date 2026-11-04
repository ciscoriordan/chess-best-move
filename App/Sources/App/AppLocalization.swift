import Foundation

/// App language follows iOS's per-app language selection. The same language is used when
/// opening the public support and legal pages. Unsupported preferences fall back to English.
enum AppLocalization {
    static let supportedLanguages = ["en", "es", "es-419", "pt-BR", "fr", "de", "it", "tr", "hi", "fil"]

    static func websiteURL(_ page: String, language: String? = nil) -> URL {
        let selected = language ?? Bundle.main.preferredLocalizations.first ?? "en"
        let locale = supportedLanguages.contains(selected) ? selected : "en"
        let websiteLanguage = switch locale {
        case "es-419": "es"
        case "hi", "fil": "en"
        default: locale
        }
        let prefix = websiteLanguage == "en" ? "" : "\(websiteLanguage)/"
        return URL(string: "https://chessbestmove.app/\(prefix)\(page)")!
    }
}
