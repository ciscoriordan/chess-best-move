import SwiftUI
import WidgetKit

private struct ScreenshotEntry: TimelineEntry {
    let date: Date
}

private struct ScreenshotProvider: TimelineProvider {
    func placeholder(in context: Context) -> ScreenshotEntry { ScreenshotEntry(date: .now) }
    func getSnapshot(in context: Context, completion: @escaping (ScreenshotEntry) -> Void) {
        completion(ScreenshotEntry(date: .now))
    }
    func getTimeline(in context: Context, completion: @escaping (Timeline<ScreenshotEntry>) -> Void) {
        completion(Timeline(entries: [ScreenshotEntry(date: .now)], policy: .never))
    }
}

private struct ScreenshotWidgetView: View {
    @Environment(\.widgetFamily) private var family

    var body: some View {
        ScreenshotWidgetContent(family: family)
        .containerBackground(Palette.canvas, for: .widget)
        .widgetURL(WidgetDestination.latestScreenshot)
    }
}

@main
struct LatestScreenshotWidget: Widget {
    let kind = "com.motomatic.chessbestmove.latest-screenshot"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: ScreenshotProvider()) { _ in
            ScreenshotWidgetView()
        }
        .configurationDisplayName("Best Move from Screenshot")
        .description("Open Chess Best Move and analyze your latest saved screenshot.")
        .supportedFamilies([.systemSmall, .systemMedium, .accessoryCircular, .accessoryRectangular])
    }
}
