import SwiftUI

/// Accessibility identifiers of the plan screen, used by the UI tests.
enum SettingsPlanAccessibilityID {
    static let screen = "settings.plan.screen"
    static let title = "settings.plan.title"
    static let unlock = "settings.plan.unlock"
    static let restore = "settings.plan.restore"
    static let manageSubscription = "settings.plan.manageSubscription"
    static let restoreMessage = "settings.plan.restoreMessage"
}

/// What Settings' Plan row leads to (design.md 9.8, owner decision of 2026-09-28).
///
/// **Why the screen exists.** App Review rejected version 1.0.6 under Guideline 2.1(b) with "the
/// app did not produce any further actions after tapping Plan button": the Plan row was a plain
/// value row with no gesture on it, so a tap on it did nothing in every state. It is now a
/// `NavigationLink` to this screen, which names the plan, says what it covers, says what is left
/// to spend, and carries every control that belongs to the plan. **Restore purchases is on it in
/// every state**, so it is never a dead end, whatever this Apple Account is entitled to.
///
/// The value is computed apart from the view so every state can be pinned in a unit test; the
/// view only lays it out.
struct SettingsPlanDetail: Equatable, Sendable {
    /// The plan's name, and the screen's heading: "Pro", "Unlimited", "Free" or "Pay as you go".
    let title: String
    /// Paragraphs under the heading, in order: what the plan is, then what is left to spend.
    let paragraphs: [String]
    /// The section label over `covers`.
    let coversLabel: String
    /// What the reader gets, one line each.
    let covers: [String]
    /// The rows in the screen's Purchases card, in order.
    ///
    /// **It always contains `.restore`**, in every state, which is what makes the Plan row lead
    /// somewhere for every reader: a plan screen with no control on it would be the same dead
    /// end App Review rejected, one screen further in.
    let actions: [SettingsPlanAction]

    /// Everything Pro and the launch offer give (monetization.md sections 2 and 4.10). One list,
    /// read by the plan that has it and by the free tier that does not, so the two can never
    /// describe Pro differently.
    static let proBenefits = [
        "Unlimited analyses, at every think time.",
        "A longer search that keeps running after the answer, up to 2 minutes.",
        "The move on screen switches to a better one by itself, if you ask it to.",
    ]

    static let includedLabel = "Included"
    static let withProLabel = "With Pro"

    /// The name of the free tier while it has an allowance to spend.
    static let freeTitle = "Free"
    /// The name of the free tier once the three free analyses are spent and a pack was bought.
    /// A reader in that state paid for what they have, so the screen does not call it free
    /// (design.md 9.8). `SettingsPlanRow.value` leads with the same name.
    static let payAsYouGoTitle = "Pay as you go"

    /// The plan this Apple Account is on.
    ///
    /// The order is the order of `SettingsPlanRow.value`, so the row and the screen can never
    /// disagree: what was **bought** first, then the launch offer, then the free tier.
    init(
        hasPurchasedPro: Bool,
        activeSubscriptionProductID: String?,
        isLaunchCohortMember: Bool,
        freeRemaining: Int,
        freeAllowance: Int,
        purchasedRemaining: Int
    ) {
        if hasPurchasedPro {
            title = "Pro"
            coversLabel = Self.includedLabel
            covers = Self.proBenefits
            actions = activeSubscriptionProductID != nil ? [.restore, .manageSubscription] : [.restore]
            var paragraphs = [Self.proPlan(activeSubscriptionProductID)]
            // Free and purchased analyses are kept while Pro is active and are usable again if it
            // lapses (monetization.md section 3), so the screen says so rather than leaving a
            // reader to wonder where their count went.
            if let kept = Self.keptWhilePro(freeRemaining: freeRemaining, purchasedRemaining: purchasedRemaining) {
                paragraphs.append(kept)
            }
            self.paragraphs = paragraphs
            return
        }
        if isLaunchCohortMember {
            title = MonetizationLaunchCohortCopy.planRow
            paragraphs = [MonetizationLaunchCohortCopy.planDetail]
            coversLabel = Self.includedLabel
            covers = Self.proBenefits
            actions = [.restore]
            return
        }
        // "Free" for the three analyses that come with the app, and **"Pay as you go" once they
        // are spent and a pack has been bought** (owner decision of 2026-09-28, design.md 9.8).
        // Heading a screen "Free" over the line "No free analyses left, and 12 analyses you
        // bought." told somebody who paid that they are on the free tier, and it was the one
        // state where the row in Settings ("12 analyses left") and this heading disagreed.
        title = purchasedRemaining > 0 && freeRemaining <= 0 ? Self.payAsYouGoTitle : Self.freeTitle
        paragraphs = [
            Self.freeCount(
                freeRemaining: freeRemaining,
                freeAllowance: freeAllowance,
                purchasedRemaining: purchasedRemaining
            ),
            // design.md 14 asks for "is free" where something is free, and this is a Settings
            // screen rather than a purchase screen, so the word is allowed here.
            "An analysis is spent on a position you have not analyzed before. Re-running the same board, at any think time, is free.",
        ]
        coversLabel = Self.withProLabel
        covers = Self.proBenefits
        actions = [.unlock, .restore]
    }

    /// "Pro Weekly, which renews every week until you cancel it."
    private static func proPlan(_ activeSubscriptionProductID: String?) -> String {
        switch activeSubscriptionProductID {
        case ProductID.proWeekly?:
            return "Pro Weekly, which renews every week until you cancel it."
        case ProductID.proAnnual?:
            return "Pro Yearly, which renews every year until you cancel it."
        case nil:
            return "Pro Lifetime, bought once. It does not renew and it does not expire."
        default:
            // An experiment's product id (monetization.md section 8), which this build does not
            // know by name. It is a subscription, because a lifetime purchase has no id here.
            return "A Pro subscription, which renews until you cancel it."
        }
    }

    /// What a Pro reader still has in the bank, or nil when there is nothing.
    private static func keptWhilePro(freeRemaining: Int, purchasedRemaining: Int) -> String? {
        let counts = [
            freeRemaining > 0 ? "\(analyses(freeRemaining)) of the three that come with the app" : nil,
            purchasedRemaining > 0 ? "\(analyses(purchasedRemaining)) you bought" : nil,
        ].compactMap(\.self)
        guard !counts.isEmpty else { return nil }
        return "\(counts.joined(separator: " and ")) are kept, and you can spend them if Pro ends."
    }

    /// "2 of 3 free analyses left, plus 12 analyses you bought."
    ///
    /// The word "free" appears only where there are two balances to tell apart, which is the
    /// shape Settings' Plan row uses as well ("Free, 2 of 3 left, plus 12 analyses").
    private static func freeCount(freeRemaining: Int, freeAllowance: Int, purchasedRemaining: Int) -> String {
        guard purchasedRemaining > 0 else {
            return freeRemaining > 0 ? "\(freeRemaining) of \(freeAllowance) analyses left." : "No analyses left."
        }
        let bought = "\(analyses(purchasedRemaining)) you bought"
        if freeRemaining > 0 {
            return "\(freeRemaining) of \(freeAllowance) free analyses left, plus \(bought)."
        }
        return "No free analyses left, and \(bought)."
    }

    /// The plural of "analysis" this count needs.
    private static func analyses(_ count: Int) -> String {
        count == 1 ? "1 analysis" : "\(count) analyses"
    }
}

/// A row in the plan screen's Purchases card. Their titles are the same words Settings' own
/// Purchases card uses, because they are the same actions (design.md section 14: plain verbs, and
/// the paywall's Title Case exception stops at the paywall).
enum SettingsPlanAction: Sendable, Hashable, CaseIterable {
    /// Opens the purchase screen.
    case unlock
    /// `AppStore.sync()` and a refresh: the one route back to a purchase made on another device.
    case restore
    /// Apple's subscription management sheet.
    case manageSubscription

    var title: String {
        switch self {
        case .unlock: "Unlock unlimited"
        case .restore: "Restore purchases"
        case .manageSubscription: "Manage subscription"
        }
    }
}

/// "Plan" (Settings > Purchases > Plan). Pushed inside Settings' own `NavigationStack`.
struct SettingsPlanView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.openURL) private var openURL

    @State private var purchases = SettingsPurchasesModel()
    @AccessibilityFocusState private var restoreMessageFocused: Bool

    private var detail: SettingsPlanDetail {
        SettingsPlanDetail(
            hasPurchasedPro: app.store.hasPurchasedPro,
            activeSubscriptionProductID: app.store.activeSubscriptionProductID,
            isLaunchCohortMember: app.store.isLaunchCohortMember,
            freeRemaining: app.credits.freeRemaining,
            freeAllowance: app.credits.freeAllowance,
            purchasedRemaining: app.credits.purchasedRemaining
        )
    }

    var body: some View {
        let detail = detail
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                Text(detail.title)
                    .typography(.title)
                    .foregroundStyle(Palette.ink)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, Spacing.s4)
                    .padding(.bottom, Spacing.s3)
                    .accessibilityAddTraits(.isHeader)
                    .accessibilityIdentifier(SettingsPlanAccessibilityID.title)
                ForEach(Array(detail.paragraphs.enumerated()), id: \.offset) { _, paragraph in
                    Text(paragraph)
                        .typography(.body)
                        .foregroundStyle(Palette.ink)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.bottom, Spacing.s3)
                }

                GroupedSectionLabel(detail.coversLabel)
                GroupedCard {
                    ForEach(Array(detail.covers.enumerated()), id: \.offset) { index, line in
                        if index > 0 {
                            GroupedRowSeparator(start: .content)
                        }
                        Text(line)
                            .typography(.body)
                            .foregroundStyle(Palette.ink)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .groupedRow(verticalPadding: Spacing.s3)
                    }
                }

                GroupedSectionLabel("Purchases")
                GroupedCard {
                    ForEach(Array(detail.actions.enumerated()), id: \.element) { index, action in
                        if index > 0 {
                            GroupedRowSeparator(start: .content)
                        }
                        row(action)
                    }
                }
                if let message = purchases.message {
                    GroupedFooter {
                        Text(message)
                            .accessibilityFocused($restoreMessageFocused)
                            .accessibilityIdentifier(SettingsPlanAccessibilityID.restoreMessage)
                    }
                }
            }
            .sideGutter()
            .padding(.bottom, Spacing.s6)
        }
        .background(Palette.canvas)
        .navigationTitle("Plan")
        .navigationBarTitleDisplayMode(.inline)
        .accessibilityIdentifier(SettingsPlanAccessibilityID.screen)
        .sensoryFeedback(.success, trigger: purchases.succeeded)
        .sensoryFeedback(.error, trigger: purchases.failed)
    }

    @ViewBuilder
    private func row(_ action: SettingsPlanAction) -> some View {
        switch action {
        case .unlock:
            Button {
                app.presentPaywall(trigger: .settings)
            } label: {
                ListRow(action.title, showsChevron: true).groupedRow()
            }
            .buttonStyle(.listRow)
            .accessibilityIdentifier(SettingsPlanAccessibilityID.unlock)
        case .restore:
            Button {
                Task { await purchases.restore(store: app.store, focus: $restoreMessageFocused) }
            } label: {
                ListRow(action.title, value: purchases.isRestoring ? "Restoring\u{2026}" : nil).groupedRow()
            }
            .buttonStyle(.listRow)
            .disabled(purchases.isRestoring)
            .accessibilityIdentifier(SettingsPlanAccessibilityID.restore)
        case .manageSubscription:
            Button {
                Task {
                    await purchases.manageSubscription(store: app.store, focus: $restoreMessageFocused) {
                        await openURL.accepted($0)
                    }
                }
            } label: {
                ListRow(action.title, showsChevron: true).groupedRow()
            }
            .buttonStyle(.listRow)
            .disabled(purchases.isManagingSubscription)
            .accessibilityIdentifier(SettingsPlanAccessibilityID.manageSubscription)
        }
    }
}

/// The purchase actions Settings' Purchases card and the plan screen share — Restore purchases
/// and Manage subscription — with the one line that reports what either of them did and the
/// haptic it plays.
///
/// Restore is the one route back to a purchase made on another device, so both places behave the
/// same and both announce the result: the row itself only stops being dimmed, and the outcome is a
/// footer one element below the card. Manage subscription reports through the same line, because
/// Apple's sheet can refuse to open and a control that then does nothing is the defect App Review
/// rejected (`MonetizationManageSubscriptionFeedback`).
@MainActor
@Observable
final class SettingsPurchasesModel {
    private(set) var isRestoring = false
    /// Apple's subscription sheet is being asked for. A second tap while it is in flight does
    /// nothing, the way a second tap on Restore purchases does nothing.
    private(set) var isManagingSubscription = false
    private(set) var message: String?
    /// Trigger counters for `sensoryFeedback`.
    private(set) var succeeded = 0
    private(set) var failed = 0

    /// `focus` is where VoiceOver is moved when the line appears; it is optional so the sequence
    /// can be tested without a view (`MonetizationManageSubscriptionTests`).
    func restore(store: any StoreService, focus: AccessibilityFocusState<Bool>.Binding?) async {
        guard !isRestoring else { return }
        isRestoring = true
        message = nil
        let outcome = await store.restore()
        isRestoring = false
        let feedback = SettingsRestoreFeedback(outcome)
        message = feedback.message
        switch feedback.haptic {
        case .success?: succeeded += 1
        case .error?: failed += 1
        case nil: break
        }
        say(feedback.message, focus: focus)
    }

    /// Apple's subscription sheet, and something to show when it cannot be shown.
    ///
    /// `openAccountPage` opens the Apple Account's subscriptions in the App Store and answers
    /// whether the system took it (`OpenURLAction.accepted(_:)`). It is only asked when Apple's
    /// own sheet refused, and it is a parameter so the rule can be tested without a window.
    func manageSubscription(
        store: any StoreService,
        focus: AccessibilityFocusState<Bool>.Binding?,
        openAccountPage: (URL) async -> Bool
    ) async {
        guard !isManagingSubscription else { return }
        isManagingSubscription = true
        message = nil
        let outcome = await store.showManageSubscriptions()
        var openedAccountPage = false
        if outcome == .unavailable {
            openedAccountPage = await openAccountPage(MonetizationAppleLinks.accountSubscriptions)
        }
        isManagingSubscription = false
        let feedback = MonetizationManageSubscriptionFeedback(outcome: outcome, openedAccountPage: openedAccountPage)
        message = feedback.message
        if feedback.isError { failed += 1 }
        say(feedback.message, focus: focus)
    }

    /// Says the line to VoiceOver and moves focus to it, which is where nobody swipes otherwise.
    private func say(_ message: String?, focus: AccessibilityFocusState<Bool>.Binding?) {
        guard let message else { return }
        AccessibilityNotification.Announcement(message).post()
        focus?.wrappedValue = true
    }
}

extension OpenURLAction {
    /// `openURL` with its completion awaited: whether the system accepted the URL. A false answer
    /// means nothing opened, so the caller still owes the reader an explanation.
    @MainActor
    func accepted(_ url: URL) async -> Bool {
        await withCheckedContinuation { continuation in
            self(url) { accepted in continuation.resume(returning: accepted) }
        }
    }
}
