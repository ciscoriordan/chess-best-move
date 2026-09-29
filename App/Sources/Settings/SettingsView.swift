import SwiftUI

/// Accessibility identifiers of Settings rows the UI tests look up.
enum SettingsAccessibilityID {
    /// The Plan row, which pushes the plan screen.
    static let planValue = "settings.plan"
    /// The line under the Purchases card that says what Restore purchases did.
    static let restoreMessage = "settings.restoreMessage"
}

/// Screens pushed inside the Settings sheet.
enum SettingsRoute: Hashable {
    case engine
    case licenses
    case document(SettingsLicenseDocument)
    case networkCredit
    case plan
    case screenshotHelp
    case shortcutSetup
}

/// Settings (design.md 9.8), presented as a sheet with the native close control.
///
/// Every section is a `GroupedCard` with a `GroupedSectionLabel` above it and, where there is
/// something to explain, a `GroupedFooter` under it: the same components Home draws its import
/// actions with (design.md section 6), so the two screens are one visual language.
struct SettingsView: View {
    @Environment(AppModel.self) private var app

    /// The pushed screens. It is a bound path, rather than SwiftUI's own, only so a DEBUG launch
    /// argument can open Settings with one screen already pushed for the screenshot runs; every
    /// row still pushes itself through its `NavigationLink`.
    @State private var path: [SettingsRoute] = []

    var body: some View {
        NavigationStack(path: $path) {
            SettingsRootContent()
                .navigationDestination(for: SettingsRoute.self) { route in
                    switch route {
                    case .engine: SettingsEngineView()
                    case .licenses: SettingsLicensesView()
                    case .document(let document): SettingsLicenseTextView(document: document)
                    case .networkCredit: SettingsNetworkCreditView()
                    case .plan: SettingsPlanView()
                    case .screenshotHelp: SettingsScreenshotHelpView()
                    case .shortcutSetup:
                        ScrollView { IntentsShortcutSetupContent() }
                            .background(Palette.canvas)
                            .navigationBarTitleDisplayMode(.inline)
                    }
                }
        }
        .tint(Palette.ink)
        #if DEBUG
        .onAppear {
            if let route = DebugLaunchOptions.settingsRoute, path.isEmpty {
                path = [route]
            }
        }
        #endif
    }
}

private struct SettingsRootContent: View {
    @Environment(AppModel.self) private var app
    @Environment(\.openURL) private var openURL

    @State private var purchases = SettingsPurchasesModel()
    @AccessibilityFocusState private var restoreMessageFocused: Bool

    var body: some View {
        @Bindable var settings = app.settings
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                GroupedSectionLabel("Analysis")
                GroupedCard {
                    VStack(alignment: .leading, spacing: Spacing.s2) {
                        Text("Default think time")
                            .typography(.body)
                            .foregroundStyle(Palette.ink)
                            .fixedSize(horizontal: false, vertical: true)
                        ThinkTimeControl(selection: $settings.thinkTime)
                        Text("Longer think times find deeper moves. Re-running a board with another think time is free.")
                            .typography(.caption)
                            .foregroundStyle(Palette.ink2)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .groupedRow(verticalPadding: Spacing.s3)
                    GroupedRowSeparator(start: .content)
                    // The two Pro settings of the longer background search (design.md 16).
                    // Shown to free users too, disabled, each carrying a Pro tag.
                    SettingsLongerSearchSection()
                }
                SettingsLongerSearchFooter()

                GroupedSectionLabel("Purchases")
                GroupedCard {
                    // A control, not a value row (owner decision of 2026-09-28). It was a plain
                    // `ListRow`, so a tap on it did nothing in every state, and App Review
                    // rejected version 1.0.6 for exactly that: "the app did not produce any
                    // further actions after tapping Plan button". It now pushes the plan screen,
                    // which has Restore purchases on it whatever the state, so the row leads
                    // somewhere for every reader (`SettingsPlanView`).
                    NavigationLink(value: SettingsRoute.plan) {
                        ListRow("Plan", value: planText, showsChevron: true).groupedRow()
                    }
                    .buttonStyle(.listRow)
                    .accessibilityIdentifier(SettingsAccessibilityID.planValue)
                    if !app.store.isPro {
                        GroupedRowSeparator(start: .content)
                        Button {
                            app.presentPaywall(trigger: .settings)
                        } label: {
                            ListRow("Unlock unlimited", showsChevron: true).groupedRow()
                        }
                        .buttonStyle(.listRow)
                    }
                    GroupedRowSeparator(start: .content)
                    Button {
                        Task { await purchases.restore(store: app.store, focus: $restoreMessageFocused) }
                    } label: {
                        ListRow("Restore purchases", value: purchases.isRestoring ? "Restoring\u{2026}" : nil).groupedRow()
                    }
                    .buttonStyle(.listRow)
                    .disabled(purchases.isRestoring)
                    if app.store.activeSubscriptionProductID != nil {
                        GroupedRowSeparator(start: .content)
                        // Apple's sheet can refuse to open (a sandbox Apple Account, or an account
                        // with no manageable subscription for this app), so the outcome is
                        // reported in the footer below and the App Store's subscriptions page is
                        // opened instead. A tap here never does nothing
                        // (`MonetizationManageSubscriptionFeedback`).
                        Button {
                            Task {
                                await purchases.manageSubscription(store: app.store, focus: $restoreMessageFocused) {
                                    await openURL.accepted($0)
                                }
                            }
                        } label: {
                            ListRow("Manage subscription", showsChevron: true).groupedRow()
                        }
                        .buttonStyle(.listRow)
                        .disabled(purchases.isManagingSubscription)
                    }
                }
                if let message = purchases.message {
                    GroupedFooter {
                        Text(message)
                            .accessibilityFocused($restoreMessageFocused)
                            .accessibilityIdentifier(SettingsAccessibilityID.restoreMessage)
                    }
                }

                GroupedSectionLabel("Help")
                GroupedCard {
                    NavigationLink(value: SettingsRoute.screenshotHelp) {
                        ListRow("How to take a screenshot", showsChevron: true).groupedRow()
                    }
                    .buttonStyle(.listRow)
                    GroupedRowSeparator(start: .content)
                    NavigationLink(value: SettingsRoute.shortcutSetup) {
                        ListRow("Set up the one-step Shortcut", showsChevron: true).groupedRow()
                    }
                    .buttonStyle(.listRow)
                    GroupedRowSeparator(start: .content)
                    Button { openURL(SettingsLinks.support) } label: {
                        ListRow("Support", showsChevron: true).groupedRow()
                    }
                    .buttonStyle(.listRow)
                    .accessibilityHint("Opens in Safari.")
                }
                GroupedFooter {
                    Text(AppCopy.fairPlayNote)
                        .accessibilityIdentifier("settings.fairPlayNote")
                }

                GroupedSectionLabel("About")
                GroupedCard {
                    ListRow("Version", value: Self.version)
                        .groupedRow()
                        .accessibilityElement(children: .combine)
                    GroupedRowSeparator(start: .content)
                    NavigationLink(value: SettingsRoute.engine) {
                        ListRow("Chess engine", value: app.engine.engineVersion, showsChevron: true).groupedRow()
                    }
                    .buttonStyle(.listRow)
                    GroupedRowSeparator(start: .content)
                    NavigationLink(value: SettingsRoute.licenses) {
                        ListRow("Licenses", showsChevron: true).groupedRow()
                    }
                    .buttonStyle(.listRow)
                    GroupedRowSeparator(start: .content)
                    Button { openURL(SettingsLinks.privacyPolicy) } label: {
                        ListRow("Privacy policy", showsChevron: true).groupedRow()
                    }
                    .buttonStyle(.listRow)
                    .accessibilityHint("Opens in Safari.")
                    GroupedRowSeparator(start: .content)
                    Button { openURL(SettingsLinks.termsOfUse) } label: {
                        ListRow("Terms of use", showsChevron: true).groupedRow()
                    }
                    .buttonStyle(.listRow)
                    .accessibilityHint("Opens in Safari.")
                }

                // Last, and only in a sandbox build: a copy TestFlight installed, the copy App
                // Review runs, or one Xcode installed on a device. Which build this is,
                // `AppTransaction.environment` decides once it has been read, and the name of the
                // receipt file decides until then (owner decision of 2026-09-28). It draws nothing
                // in a copy from the App Store, and nothing on a simulator, whose receipt carries
                // the App Store name and whose app transaction usually cannot be read at all
                // (SettingsTesting.swift, monetization.md section 3).
                SettingsTestingSection()
            }
            .sideGutter()
            .padding(.bottom, Spacing.s6)
        }
        .background(Palette.canvas)
        .navigationTitle("Settings")
        .navigationBarTitleDisplayMode(.inline)
        .modalCloseButton { app.dismissSheet() }
        .sensoryFeedback(.success, trigger: purchases.succeeded)
        .sensoryFeedback(.error, trigger: purchases.failed)
    }

    private var planText: String {
        SettingsPlanRow.value(
            hasPurchasedPro: app.store.hasPurchasedPro,
            activeSubscriptionProductID: app.store.activeSubscriptionProductID,
            isLaunchCohortMember: app.store.isLaunchCohortMember,
            freeRemaining: app.credits.freeRemaining,
            freeAllowance: app.credits.freeAllowance,
            purchasedRemaining: app.credits.purchasedRemaining
        )
    }

    private static var version: String {
        let marketing = AppBuild.shortVersion
        let build = AppBuild.buildNumber
        return "\(marketing.isEmpty ? "?" : marketing) (\(build.isEmpty ? "?" : build))"
    }
}

/// The value of the Plan row in Settings' Purchases card.
///
/// It is asked what was **bought** first, and separately from `StoreService.isPro`, which is
/// also true for a member of the free launch cohort: the row must never tell somebody who
/// bought nothing that they are on "Pro, lifetime" (monetization.md section 11). The launch
/// offer reads "Unlimited" instead, which is what the app is doing and claims nothing about
/// when this Apple Account installed the app. It used to read "Unlimited, launch offer" for a
/// member Apple had confirmed and "Unlimited" while the cohort was undecided; the window closed
/// on 2026-09-28, so no shipped string names an offer any more and the two states read alike.
enum SettingsPlanRow {
    /// "Pro, weekly", "Unlimited", "Free, 2 of 3 left", "Pay as you go, 12 left".
    static func value(
        hasPurchasedPro: Bool,
        activeSubscriptionProductID: String?,
        isLaunchCohortMember: Bool,
        freeRemaining: Int,
        freeAllowance: Int,
        purchasedRemaining: Int
    ) -> String {
        if hasPurchasedPro {
            switch activeSubscriptionProductID {
            case ProductID.proWeekly?: return "Pro, weekly"
            case ProductID.proAnnual?: return "Pro, yearly"
            case nil: return "Pro, lifetime"
            default: return "Pro"
            }
        }
        if isLaunchCohortMember { return MonetizationLaunchCohortCopy.planRow }
        let purchasedText = purchasedRemaining == 1 ? "1 analysis" : "\(purchasedRemaining) analyses"
        if freeRemaining > 0 {
            let free = "\(SettingsPlanDetail.freeTitle), \(freeRemaining) of \(freeAllowance) left"
            return purchasedRemaining > 0 ? "\(free), plus \(purchasedText)" : free
        }
        // The plan's name, then the count: with the three free analyses spent and a pack bought,
        // the word "free" would be wrong about the count and "Free" wrong about the plan, so both
        // the row and the screen call it "Pay as you go" (design.md 9.8). It used to read
        // "12 analyses left", which named no plan and disagreed with the screen's heading.
        if purchasedRemaining > 0 { return "\(SettingsPlanDetail.payAsYouGoTitle), \(purchasedRemaining) left" }
        return "\(SettingsPlanDetail.freeTitle), none left"
    }
}

/// What the Restore purchases row shows and plays for a restore outcome.
struct SettingsRestoreFeedback: Equatable, Sendable {
    enum Haptic: Equatable, Sendable {
        case success
        case error
    }

    /// The line under the row; nil shows nothing.
    let message: String?
    let haptic: Haptic?

    init(message: String?, haptic: Haptic?) {
        self.message = message
        self.haptic = haptic
    }

    init(_ outcome: RestoreOutcome) {
        switch outcome {
        case .restored:
            self.init(message: MonetizationCopy.purchasesRestored, haptic: .success)
        case .nothingFound:
            self.init(message: MonetizationCopy.nothingToRestore, haptic: nil)
        case .canceled:
            // The user closed the Apple Account sign-in: nothing failed, like a canceled
            // purchase (no message, no haptic).
            self.init(message: nil, haptic: nil)
        case .failed(let message):
            // The store's text is already a full sentence ("Couldn't restore purchases.
            // Please try again."), so it is shown as is, like the paywall does.
            self.init(message: message, haptic: .error)
        }
    }
}

/// "How to take a screenshot" (Settings > Help).
struct SettingsScreenshotHelpView: View {
    /// The button combinations of this device family, then the way back.
    private var steps: [String] {
        AppDevice.current.screenshotButtonSteps + ["Come back to Chess Best Move and tap Use latest screenshot."]
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                Text("How to take a screenshot")
                    .typography(.title)
                    .foregroundStyle(Palette.ink)
                    .padding(.top, Spacing.s4)
                    .accessibilityAddTraits(.isHeader)
                SectionLabel("Steps")
                ForEach(Array(steps.enumerated()), id: \.offset) { index, step in
                    SettingsNumberedStep(number: index + 1, text: step)
                        .padding(.bottom, Spacing.s3)
                }
                SectionLabel("For the best result")
                Text("Use a screenshot of the board, not a photo of a screen. The whole board must be visible.")
                    .typography(.body)
                    .foregroundStyle(Palette.ink)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .sideGutter()
            .padding(.bottom, Spacing.s6)
        }
        .background(Palette.canvas)
        .navigationTitle("Screenshots")
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// A numbered step with the number in a hanging indent.
struct SettingsNumberedStep: View {
    let number: Int
    let text: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Spacing.s3) {
            Text("\(number)")
                .typography(.data)
                .foregroundStyle(Palette.ink2)
                .frame(minWidth: 16, alignment: .leading)
            Text(text)
                .typography(.body)
                .foregroundStyle(Palette.ink)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }
}
