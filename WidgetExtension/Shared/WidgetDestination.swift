import Foundation

/// Shared by the app and widget; contains no screenshot data or extension-side work.
enum WidgetDestination {
    static let latestScreenshot = URL(string: "chessbestmove://latest-screenshot")!

    static func isLatestScreenshot(_ url: URL) -> Bool {
        url == latestScreenshot
    }
}
