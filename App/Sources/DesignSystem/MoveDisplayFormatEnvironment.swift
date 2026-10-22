import SwiftUI

private struct MoveDisplayFormatKey: EnvironmentKey {
    static let defaultValue = MoveDisplayFormat.words
}

extension EnvironmentValues {
    var moveDisplayFormat: MoveDisplayFormat {
        get { self[MoveDisplayFormatKey.self] }
        set { self[MoveDisplayFormatKey.self] = newValue }
    }
}
