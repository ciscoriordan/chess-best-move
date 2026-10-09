import SwiftUI

/// Home's outlined wordmark, rasterized at 1x/2x/3x from design/wordmark.svg.
/// Its compact image stays in the navigation bar at every text size; VoiceOver reads
/// the full app name as one heading. Template rendering follows the normal ink color.
struct AppWordmark: View {
    var body: some View {
        Image("HomeWordmark")
            .renderingMode(.template)
            .resizable()
            .scaledToFit()
            .frame(maxWidth: 224, maxHeight: 40)
            .foregroundStyle(Palette.ink)
            .accessibilityLabel("Chess Best Move")
            .accessibilityAddTraits(.isHeader)
            .accessibilityIdentifier("home.wordmark")
    }
}
