import SwiftUI

/// The one-step Shortcut setup sheet (design.md 9.1), with the native close control.
struct ShortcutSetupView: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        NavigationStack {
            ScrollView {
                IntentsShortcutSetupContent()
            }
            .background(Palette.canvas)
            .navigationBarTitleDisplayMode(.inline)
            .modalCloseButton { app.dismissSheet() }
        }
        .tint(Palette.ink)
    }
}

/// The setup steps, shared by the sheet and the Settings > Help page.
struct IntentsShortcutSetupContent: View {
    @Environment(AppModel.self) private var app
    @Environment(\.openURL) private var openURL

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("One-step Shortcut")
                .typography(.title)
                .foregroundStyle(Palette.ink)
                .accessibilityAddTraits(.isHeader)
            Text("Take a screenshot and analyze it in one step.")
                .typography(.body)
                .foregroundStyle(Palette.ink2)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, Spacing.s2)

            SectionLabel("Steps")
            IntentsSetupStep(number: 1, text: "In the Shortcuts app, create a shortcut with \u{201C}Take Screenshot\u{201D}, then add \u{201C}Find Best Move\u{201D} after it.") {
                SecondaryButton("Open Shortcuts", systemImage: "square.2.layers.3d") {
                    if let url = URL(string: "shortcuts://") { openURL(url) }
                }
                .fixedSize(horizontal: true, vertical: false)
                .padding(.top, Spacing.s2)
            }
            .padding(.bottom, Spacing.s4)
            IntentsSetupStep(number: 2, text: "Assign the shortcut to the Action button, or to Back Tap in Settings > Accessibility > Touch > Back Tap.")
                .padding(.bottom, Spacing.s4)
            IntentsSetupStep(number: 3, text: "With a position on screen, run the shortcut. Chess Best Move opens and analyzes the screenshot.")
                .padding(.bottom, Spacing.s4)

            // Only for a reader who has a free allowance to spend. A Pro subscriber and a
            // member of the free launch window (monetization.md section 11) have unlimited
            // analyses, so this is the one line left in the app that would tell a member
            // about an allowance they do not have and never see counted anywhere else.
            if !app.store.isPro {
                Hairline()
                Text("The shortcut uses the same free analyses as the app. Board not found never uses one.")
                    .typography(.caption)
                    .foregroundStyle(Palette.ink2)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, Spacing.s3)
            }
        }
        .sideGutter()
        .padding(.top, Spacing.s4)
        .padding(.bottom, Spacing.s6)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A numbered step with the number in a hanging indent and optional content below the text.
private struct IntentsSetupStep<Accessory: View>: View {
    let number: Int
    let text: String
    @ViewBuilder var accessory: () -> Accessory

    init(number: Int, text: String, @ViewBuilder accessory: @escaping () -> Accessory = { EmptyView() }) {
        self.number = number
        self.text = text
        self.accessory = accessory
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Spacing.s3) {
            Text("\(number)")
                .typography(.data)
                .foregroundStyle(Palette.ink2)
                .frame(minWidth: 16, alignment: .leading)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 0) {
                Text(text)
                    .typography(.body)
                    .foregroundStyle(Palette.ink)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityLabel("Step \(number): \(text)")
                accessory()
            }
        }
    }
}
