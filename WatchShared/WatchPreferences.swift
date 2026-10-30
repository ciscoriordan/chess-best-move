import Foundation

/// Local preferences sent by the phone; older peers can omit newly added values.
struct WatchPreferences: Equatable, Sendable {
    enum Key {
        static let moveDisplayFormat = "moveDisplayFormat"
        static let automaticallyAnalyzesOnOpen = "automaticallyAnalyzesOnOpen"
    }

    var moveDisplayFormat: MoveDisplayFormat = .words
    var automaticallyAnalyzesOnOpen = true

    init(moveDisplayFormat: MoveDisplayFormat = .words, automaticallyAnalyzesOnOpen: Bool = true) {
        self.moveDisplayFormat = moveDisplayFormat
        self.automaticallyAnalyzesOnOpen = automaticallyAnalyzesOnOpen
    }

    init(defaults: UserDefaults) {
        moveDisplayFormat = MoveDisplayFormat(rawValue: defaults.string(forKey: Key.moveDisplayFormat) ?? "") ?? .words
        automaticallyAnalyzesOnOpen = defaults.object(forKey: Key.automaticallyAnalyzesOnOpen) == nil
            ? true : defaults.bool(forKey: Key.automaticallyAnalyzesOnOpen)
    }

    func merging(moveDisplayFormat rawValue: String?, automaticallyAnalyzesOnOpen: Bool?) -> Self {
        Self(moveDisplayFormat: rawValue.flatMap(MoveDisplayFormat.init(rawValue:)) ?? moveDisplayFormat,
             automaticallyAnalyzesOnOpen: automaticallyAnalyzesOnOpen ?? self.automaticallyAnalyzesOnOpen)
    }

    var applicationContext: [String: Any] {
        [Key.moveDisplayFormat: moveDisplayFormat.rawValue,
         Key.automaticallyAnalyzesOnOpen: automaticallyAnalyzesOnOpen]
    }

    func save(to defaults: UserDefaults) {
        defaults.set(moveDisplayFormat.rawValue, forKey: Key.moveDisplayFormat)
        defaults.set(automaticallyAnalyzesOnOpen, forKey: Key.automaticallyAnalyzesOnOpen)
    }
}
