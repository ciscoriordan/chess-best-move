import SwiftUI
import WidgetKit

/// WidgetKit gives these surfaces a fixed size. Keep the full description while it fits,
/// then prioritize a larger, readable title instead of clipping several enlarged text rows.
/// Shared with the app's design gallery so the actual widget content can be inspected there.
struct ScreenshotWidgetContent: View {
    let family: WidgetFamily

    var body: some View {
        Group {
            switch family {
            case .accessoryCircular:
                accessorySymbol
            case .accessoryRectangular:
                ViewThatFits {
                    Label {
                        VStack(alignment: .leading) {
                            Text("Best move").bold()
                            Text("Latest screenshot")
                        }
                        .fixedSize(horizontal: false, vertical: true)
                    } icon: { symbol }
                    Text("Best move").bold()
                        .fixedSize(horizontal: false, vertical: true)
                    accessorySymbol
                }
            default:
                ViewThatFits(in: .vertical) {
                    VStack(alignment: .leading, spacing: 8) {
                        symbol.foregroundStyle(Palette.accent).widgetAccentable()
                        title(.headline)
                        Text("Analyze latest screenshot")
                            .typography(.caption)
                            .foregroundStyle(Palette.ink2)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    title(.headline)
                    title(.callout)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity,
               alignment: family == .accessoryCircular ? .center : .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Find the best move in your latest saved screenshot")
        .accessibilityInputLabels(["Best move", "Analyze latest screenshot"])
        .accessibilityHint("Opens Chess Best Move to analyze it")
        .accessibilityAddTraits(.isButton)
    }

    private var symbol: Image { Image(systemName: "photo.badge.magnifyingglass") }

    /// Symbols inherit enlarged text sizes too. Fit the icon into the accessory slot rather
    /// than allowing its font's intrinsic dimensions to extend beyond the widget boundary.
    private var accessorySymbol: some View {
        symbol.resizable().scaledToFit()
            .frame(maxWidth: 64, maxHeight: 64)
            .padding(4)
            .widgetAccentable()
    }

    private func title(_ token: TypeToken) -> some View {
        Text("Best move")
            .typography(token)
            .foregroundStyle(Palette.ink)
            .fixedSize(horizontal: false, vertical: true)
    }
}
