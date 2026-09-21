import SwiftUI

/// Accessibility identifiers of Settings rows the UI tests look up.
enum SettingsAccessibilityID {
    /// The footer under the Purchases card that explains the free launch offer.
    static let launchOfferFooter = "settings.launchOffer"
    /// The Plan row's value.
    static let planValue = "settings.plan"
}

/// Screens pushed inside the Settings sheet.
enum SettingsRoute: Hashable {
    case engine
    case licenses
    case document(SettingsLicenseDocument)
    case networkCredit
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

    var body: some View {
        NavigationStack {
            SettingsRootContent()
                .navigationDestination(for: SettingsRoute.self) { route in
                    switch route {
                    case .engine: SettingsEngineView()
                    case .licenses: SettingsLicensesView()
                    case .document(let document): SettingsLicenseTextView(document: document)
                    case .networkCredit: SettingsNetworkCreditView()
                    case .screenshotHelp: SettingsScreenshotHelpView()
                    case .shortcutSetup:
                        ScrollView { IntentsShortcutSetupContent() }
                            .background(Palette.canvas)
                            .navigationBarTitleDisplayMode(.inline)
                    }
                }
        }
        .tint(Palette.ink)
    }
}

private struct SettingsRootContent: View {
    @Environment(AppModel.self) private var app
    @Environment(\.openURL) private var openURL

    @State private var isRestoring = false
    @State private var restoreMessage: String?
    @AccessibilityFocusState private var restoreMessageFocused: Bool
    @State private var restoreSucceeded = 0
    @State private var restoreFailed = 0

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
                    ListRow("Plan", value: planText)
                        .groupedRow()
                        .accessibilityElement(children: .combine)
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
                        restore()
                    } label: {
                        ListRow("Restore purchases", value: isRestoring ? "Restoring\u{2026}" : nil).groupedRow()
                    }
                    .buttonStyle(.listRow)
                    .disabled(isRestoring)
                    if app.store.activeSubscriptionProductID != nil {
                        GroupedRowSeparator(start: .content)
                        Button {
                            Task { await app.store.showManageSubscriptions() }
                        } label: {
                            ListRow("Manage subscription", showsChevron: true).groupedRow()
                        }
                        .buttonStyle(.listRow)
                    }
                }
                if app.store.isConfirmedLaunchCohortMember || restoreMessage != nil {
                    GroupedFooter {
                        // The launch offer explains itself where the plan row names it, and
                        // says what Restore purchases is still for (monetization.md 11). Only
                        // once Apple has confirmed it: the footer names the date this Apple
                        // Account installed the app, which an undecided cohort does not know.
                        if app.store.isConfirmedLaunchCohortMember {
                            Text(MonetizationLaunchCohortCopy.planFooter)
                                .accessibilityIdentifier(SettingsAccessibilityID.launchOfferFooter)
                        }
                        if let restoreMessage {
                            // The focus goes on the result of the restore, not on the whole
                            // footer: a member's footer also carries the launch-offer
                            // explanation, and a reader who just tapped Restore purchases wants
                            // to hear what it did first.
                            Text(restoreMessage)
                                .accessibilityFocused($restoreMessageFocused)
                        }
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

                // Last, and only where the App Store receipt is a sandbox one: a copy
                // TestFlight installed, the copy App Review runs, or one Xcode installed on a
                // device. It draws nothing in a copy from the App Store, and nothing on a
                // simulator, whose receipt carries the App Store name
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
        .sensoryFeedback(.success, trigger: restoreSucceeded)
        .sensoryFeedback(.error, trigger: restoreFailed)
    }

    private var planText: String {
        SettingsPlanRow.value(
            hasPurchasedPro: app.store.hasPurchasedPro,
            activeSubscriptionProductID: app.store.activeSubscriptionProductID,
            isLaunchCohortMember: app.store.isLaunchCohortMember,
            isConfirmedLaunchCohortMember: app.store.isConfirmedLaunchCohortMember,
            freeRemaining: app.credits.freeRemaining,
            freeAllowance: app.credits.freeAllowance,
            purchasedRemaining: app.credits.purchasedRemaining
        )
    }

    private func restore() {
        isRestoring = true
        restoreMessage = nil
        Task {
            let outcome = await app.store.restore()
            isRestoring = false
            let feedback = SettingsRestoreFeedback(outcome)
            restoreMessage = feedback.message
            switch feedback.haptic {
            case .success?: restoreSucceeded += 1
            case .error?: restoreFailed += 1
            case nil: break
            }
            // The result is a footer one element below the card and the row itself only stops
            // being dimmed, so without this a reader tapped Restore purchases, felt a haptic
            // and was never told what happened. This is the only route back to Pro on a new
            // device.
            if let message = feedback.message {
                AccessibilityNotification.Announcement(message).post()
                restoreMessageFocused = true
            }
        }
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
/// offer has its own name instead, and names itself only once Apple has confirmed it: while
/// the cohort is undecided the app grants the offer without knowing it is theirs, and the row
/// says what it is doing ("Unlimited") rather than why.
enum SettingsPlanRow {
    /// "Pro, weekly", "Unlimited, launch offer", "Unlimited", "Free, 2 of 3 left",
    /// "12 analyses left".
    static func value(
        hasPurchasedPro: Bool,
        activeSubscriptionProductID: String?,
        isLaunchCohortMember: Bool,
        isConfirmedLaunchCohortMember: Bool,
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
        if isConfirmedLaunchCohortMember { return MonetizationLaunchCohortCopy.planRow }
        if isLaunchCohortMember { return MonetizationLaunchCohortCopy.undecidedPlanRow }
        let purchasedText = purchasedRemaining == 1 ? "1 analysis" : "\(purchasedRemaining) analyses"
        if freeRemaining > 0 {
            let free = "Free, \(freeRemaining) of \(freeAllowance) left"
            return purchasedRemaining > 0 ? "\(free), plus \(purchasedText)" : free
        }
        if purchasedRemaining > 0 { return "\(purchasedText) left" }
        return "Free, none left"
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
