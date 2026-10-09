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
        Group {
            switch family {
            case .accessoryCircular:
                Image(systemName: "photo.badge.magnifyingglass")
                    .widgetAccentable()
            case .accessoryRectangular:
                Label {
                    VStack(alignment: .leading) {
                        Text("Best move").bold()
                        Text("Latest screenshot")
                    }
                } icon: {
                    Image(systemName: "photo.badge.magnifyingglass")
                }
            default:
                VStack(alignment: .leading, spacing: 8) {
                    Image(systemName: "photo.badge.magnifyingglass")
                        .foregroundStyle(Palette.accent)
                        .widgetAccentable()
                    Text("Best move")
                        .typography(.headline)
                        .foregroundStyle(Palette.ink)
                    Text("Analyze latest screenshot")
                        .typography(.caption)
                        .foregroundStyle(Palette.ink2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            }
        }
        .containerBackground(Palette.canvas, for: .widget)
        .widgetURL(WidgetDestination.latestScreenshot)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Find the best move in your latest saved screenshot")
        .accessibilityHint("Opens Chess Best Move to analyze it")
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
