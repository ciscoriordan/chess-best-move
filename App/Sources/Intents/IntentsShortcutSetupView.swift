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
            Text("Take a screenshot, save it to Photos, and analyze it with one shortcut.")
                .typography(.body)
                .foregroundStyle(Palette.ink2)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, Spacing.s2)

            SectionLabel("Create the shortcut")
            IntentsSetupStep(number: 1, text: "In the Shortcuts app, create a shortcut named \u{201C}Analyze my chess screenshot\u{201D}. Add \u{201C}Take Screenshot\u{201D} as its first action.") {
                SecondaryButton("Open Shortcuts", systemImage: "square.2.layers.3d") {
                    if let url = URL(string: "shortcuts://") { openURL(url) }
                }
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, Spacing.s2)
            }
            .padding(.bottom, Spacing.s4)
            IntentsSetupStep(number: 2, text: "Add \u{201C}Save to Photo Album\u{201D}. Choose Recents as the album. For its input, select the Screenshot variable produced by Take Screenshot. This saves a copy to Photos; Take Screenshot alone does not save one.")
                .padding(.bottom, Spacing.s4)
            IntentsSetupStep(number: 3, text: "Add \u{201C}Find Best Move\u{201D} from Chess Best Move. Tap its Screenshot input, choose Select Variable, and select the output of Take Screenshot. It should read \u{201C}Find the best move in Screenshot\u{201D}, with Screenshot shown as a variable token with the screenshot icon, like the input in Save to Photo Album. A pale Screenshot placeholder is not a connected image. Do not type the word Screenshot or leave the input set to Ask Each Time. The app receives this image directly, without looking it up in Photos.")
                .padding(.bottom, Spacing.s4)
            SectionLabel("Run with Siri")
            IntentsSetupStep(number: 1, text: "Keep the chess position you want to analyze on screen. Say \u{201C}Siri, analyze my chess screenshot\u{201D}, using the exact name of the shortcut you created.")
                .padding(.bottom, Spacing.s4)
            IntentsSetupStep(number: 2, text: "Unlock your device and allow any requested permissions. When Siri runs the shortcut, it takes the screenshot, saves it to Recents, and opens Chess Best Move to analyze it.")
                .padding(.bottom, Spacing.s4)

            SectionLabel("Run from Control Center")
            IntentsSetupStep(number: 1, text: "Only for the Control Center path: add Wait (3 seconds) before Take Screenshot. Do not add this delay for Siri, the Action button, or Back Tap. If you use both paths, duplicate the shortcut, name the copy Chess Screenshot Control, and add Wait only to that copy. A Wait action runs every time its shortcut runs.")
                .padding(.bottom, Spacing.s4)
            IntentsSetupStep(number: 2, text: "Open Control Center, tap +, and choose Add a Control > Shortcut. Tap Choose and select the version of your shortcut with the wait. With a chess position on screen, open Control Center and tap your shortcut control. Immediately dismiss Control Center so the board is visible before the wait ends. Take Screenshot captures whatever is visible, including Control Center if it is still open. Increase the wait if you need more time.")
                .padding(.bottom, Spacing.s4)

            SectionLabel("Run with the Action button")
            Text("The Action button is a physical button on the left side of supported iPhones, above the volume buttons. It replaces the Ring/Silent switch and can run a shortcut when you press and hold it. If your iPhone has a Ring/Silent switch instead, use Back Tap or another option.")
                .typography(.body)
                .foregroundStyle(Palette.ink2)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.bottom, Spacing.s4)
            IntentsSetupStep(number: 1, text: "Open Settings > Action Button. Swipe to Shortcut, tap Choose a Shortcut, and select Analyze my chess screenshot without the Wait action.")
                .padding(.bottom, Spacing.s4)
            IntentsSetupStep(number: 2, text: "Keep the chess position on screen and press and hold the Action button. You do not need to open Control Center or add a three-second wait. The button now runs this shortcut instead of its previous action.")
                .padding(.bottom, Spacing.s4)

            SectionLabel("Only in your board app")
            Text("Optional: create a separate shortcut named Chess Action Button. Add Get Current App, then an If action that compares the current app’s Name with the name of your board app. Inside If, add Run Shortcut and choose Analyze my chess screenshot without the Wait action. Leave Otherwise empty. Assign Chess Action Button to the Action button. It will do nothing in other apps, rather than return to the button’s previous function.")
                .typography(.body)
                .foregroundStyle(Palette.ink2)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.bottom, Spacing.s4)
            Text("Use the name reported by Get Current App, which may differ from the App Store title. To check it, temporarily add Show Result with the current app’s Name after Get Current App, then run it with the Action button while your board app is visible. Remove Show Result after checking. Test the finished shortcut with your board app visible and again in another app. Running it from the shortcut editor checks Shortcuts instead of your board app.")
                .typography(.body)
                .foregroundStyle(Palette.ink2)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.bottom, Spacing.s4)

            SectionLabel("Run with Back Tap")
            Text("Back Tap lets you run a shortcut by quickly tapping the back of your iPhone with your finger two or three times. It is a gesture on the back of the phone, not a button on the screen.")
                .typography(.body)
                .foregroundStyle(Palette.ink2)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.bottom, Spacing.s4)
            IntentsSetupStep(number: 1, text: "Open Settings > Accessibility > Touch > Back Tap. Choose Double Tap or Triple Tap, scroll to Shortcuts, and select Analyze my chess screenshot without the Wait action.")
                .padding(.bottom, Spacing.s4)
            IntentsSetupStep(number: 2, text: "Keep the chess position on screen, then quickly tap the back of your iPhone two or three times, matching your setting. You do not need to open Control Center or add a three-second wait.")
                .padding(.bottom, Spacing.s4)

            SectionLabel("Troubleshooting")
            Text("If Siri offers ChatGPT instead, try saying \u{201C}Siri, run the shortcut Analyze my chess screenshot\u{201D}. If it still does not run your shortcut, use one of the controls above. If Siri asks for a screenshot, check that you are running your saved shortcut and that both image inputs use the Screenshot variable from Take Screenshot.")
                .typography(.body)
                .foregroundStyle(Palette.ink2)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.bottom, Spacing.s4)

            SectionLabel("Home and Lock Screen widgets")
            Text("Save a screenshot first. Touch and hold the Home Screen, then choose Edit > Add Widget > Chess Best Move. On the Lock Screen, touch and hold, choose Customize, then Add Widgets. Tap the widget to open the app and analyze your latest saved screenshot. With limited Photos access, choose the screenshot when prompted.")
                .typography(.body)
                .foregroundStyle(Palette.ink2)
                .fixedSize(horizontal: false, vertical: true)
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
