import SwiftUI
import WidgetKit

private struct BestMoveEntry: TimelineEntry { let date: Date }

private struct BestMoveProvider: TimelineProvider {
    func placeholder(in context: Context) -> BestMoveEntry { BestMoveEntry(date: .now) }
    func getSnapshot(in context: Context, completion: @escaping (BestMoveEntry) -> Void) {
        completion(placeholder(in: context))
    }
    func getTimeline(in context: Context, completion: @escaping (Timeline<BestMoveEntry>) -> Void) {
        completion(Timeline(entries: [BestMoveEntry(date: .now)], policy: .never))
    }
}

private struct ComplicationView: View {
    @Environment(\.widgetFamily) private var family
    var body: some View {
        Group {
            switch family {
            case .accessoryRectangular:
                VStack(alignment: .leading) {
                    Label("Best Move", systemImage: "viewfinder").font(.headline)
                    Text("Analyze screenshot").font(.caption)
                }
            case .accessoryInline:
                Label("Best Move", systemImage: "viewfinder")
            default:
                Image(systemName: "viewfinder")
                    .font(.title2)
                    .accessibilityLabel(Text("Analyze screenshot"))
            }
        }
        .containerBackground(.fill.tertiary, for: .widget)
        // Launch only. Opening a complication must never spend an analysis.
        .widgetURL(URL(string: "chessbestmove-watch://open"))
    }
}

@main
struct BestMoveComplication: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "BestMoveLauncher", provider: BestMoveProvider()) { _ in
            ComplicationView()
        }
        .configurationDisplayName("Best Move")
        .description("Open screenshot analysis on your Watch.")
        .supportedFamilies([.accessoryCircular, .accessoryRectangular, .accessoryInline])
    }
}
