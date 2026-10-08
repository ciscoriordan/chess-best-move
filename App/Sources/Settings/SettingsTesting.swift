import SwiftUI

/// Accessibility identifiers of the Testing section, used by `SettingsTestingUITests`. There
/// is none for the section as a whole: an identifier on a container replaces the identifier of
/// every element inside it, so the note is what says the section is there.
enum SettingsTestingAccessibilityID {
    static let note = "settings.testing.note"
    static let free = "settings.testing.free"
    static let purchased = "settings.testing.purchased"
    static let paidBoards = "settings.testing.paidBoards"
    static let reset = "settings.testing.reset"
    static let grant = "settings.testing.grant"
    static let message = "settings.testing.message"
}

/// The Testing section at the bottom of Settings: free analyses back to three, and the pack's
/// 15 analyses without a purchase, so the owner can keep testing without running out
/// (docs/monetization.md section 3, "Testing tools").
///
/// It exists only in a sandbox build (`MonetizationBuildChannel`): a copy TestFlight installed,
/// the copy App Review runs, or a copy Xcode installed. A copy from the App Store shows nothing
/// here, and so does a run on a simulator, whose receipt carries the App Store name and whose app
/// transaction usually cannot be read at all.
///
/// The channel is Apple's own answer (`AppTransaction.environment`) once it has been read, and the
/// receipt file's name until then, so this section is drawn from a value that is there at the
/// first frame and never delays Settings (`MonetizationBuildChannelResolver`).
///
/// It never touches Pro. Pro comes from StoreKit, and a purchase made from a TestFlight build
/// goes to the sandbox and costs nothing, which is the documented way to test it.
struct SettingsTestingSection: View {
    /// The channel that decides whether this section exists. nil is this build's own, resolved at
    /// launch; previews and tests pass another one.
    var channel: MonetizationBuildChannel?

    @Environment(AppModel.self) private var app

    @State private var confirmsReset = false
    @State private var confirmsGrant = false
    @State private var message: String?
    @State private var actionCount = 0

    @ViewBuilder
    var body: some View {
        // Read inside the body, so the view redraws if Apple's answer replaces the receipt
        // name's after launch.
        let channel = channel ?? MonetizationBuildChannel.resolved
        if channel.offersTestingTools, let grants = app.credits as? any MonetizationTestingGrants {
            content(grants, channel: channel)
        }
    }

    private func content(
        _ grants: any MonetizationTestingGrants,
        channel: MonetizationBuildChannel
    ) -> some View {
        let counts = grants.testingCounts
        return VStack(alignment: .leading, spacing: 0) {
            GroupedSectionLabel(MonetizationTestingCopy.sectionLabel)
            GroupedCard {
                if let cohort = app.store as? any MonetizationLaunchCohortTesting {
                    Toggle("Show the purchase screens", isOn: Binding(
                        get: { cohort.leavesLaunchCohortForTesting },
                        set: { _ = cohort.setLeavesLaunchCohortForTesting($0, for: channel) }
                    ))
                    .typography(.body)
                    .groupedRow()
                    .accessibilityIdentifier("settings.testing.purchaseScreens")
                    GroupedRowSeparator(start: .content)
                }
                ListRow(MonetizationTestingCopy.freeRow, value: MonetizationTestingCopy.freeValue(counts))
                    .groupedRow()
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier(SettingsTestingAccessibilityID.free)
                GroupedRowSeparator(start: .content)
                ListRow(MonetizationTestingCopy.purchasedRow, value: "\(counts.purchasedRemaining)")
                    .groupedRow()
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier(SettingsTestingAccessibilityID.purchased)
                GroupedRowSeparator(start: .content)
                ListRow(MonetizationTestingCopy.paidBoardsRow, value: "\(counts.paidBoards)")
                    .groupedRow()
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier(SettingsTestingAccessibilityID.paidBoards)
                GroupedRowSeparator(start: .content)
                Button { confirmsReset = true } label: {
                    ListRow(MonetizationTestingCopy.reset).groupedRow()
                }
                .buttonStyle(.listRow)
                .accessibilityIdentifier(SettingsTestingAccessibilityID.reset)
                GroupedRowSeparator(start: .content)
                Button { confirmsGrant = true } label: {
                    ListRow(MonetizationTestingCopy.grant(MonetizationTestingGrant.analysesPerGrant)).groupedRow()
                }
                .buttonStyle(.listRow)
                .accessibilityIdentifier(SettingsTestingAccessibilityID.grant)
            }
            // The footer carries what the section is and what the last action did. Both
            // actions ask before they change anything, and the confirmation dialog repeats
            // the detail, so nothing here has to be read before a tap.
            GroupedFooter {
                Text("Turn on Show the purchase screens to test the three-free-analysis allowance and purchases instead of the launch offer. Turn it off to restore launch access. This only affects sandbox testing.")
                Text(MonetizationTestingCopy.note)
                    .accessibilityIdentifier(SettingsTestingAccessibilityID.note)
                if let message {
                    Text(message)
                        .accessibilityIdentifier(SettingsTestingAccessibilityID.message)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .confirmationDialog(
            MonetizationTestingCopy.resetQuestion,
            isPresented: $confirmsReset,
            titleVisibility: .visible
        ) {
            Button(MonetizationTestingCopy.resetConfirm, role: .destructive) { reset(grants, channel: channel) }
            Button(MonetizationTestingCopy.cancel, role: .cancel) {}
        } message: {
            Text(MonetizationTestingCopy.resetDetail)
        }
        .confirmationDialog(
            MonetizationTestingCopy.grantQuestion(MonetizationTestingGrant.analysesPerGrant),
            isPresented: $confirmsGrant,
            titleVisibility: .visible
        ) {
            Button(MonetizationTestingCopy.grantConfirm) { grant(grants, channel: channel) }
            Button(MonetizationTestingCopy.cancel, role: .cancel) {}
        } message: {
            Text(MonetizationTestingCopy.grantDetail(MonetizationTestingGrant.analysesPerGrant))
        }
        .sensoryFeedback(.success, trigger: actionCount)
    }

    private func reset(_ grants: any MonetizationTestingGrants, channel: MonetizationBuildChannel) {
        let before = grants.testingCounts
        let changed = grants.resetFreeAnalyses(for: channel)
        let after = grants.testingCounts
        message = changed ? MonetizationTestingCopy.resetDone(before: before, after: after) : MonetizationTestingCopy.nothingChanged
        actionCount += 1
    }

    private func grant(_ grants: any MonetizationTestingGrants, channel: MonetizationBuildChannel) {
        let before = grants.testingCounts
        let changed = grants.grantTestingAnalyses(for: channel)
        let after = grants.testingCounts
        message = changed ? MonetizationTestingCopy.grantDone(before: before, after: after) : MonetizationTestingCopy.nothingChanged
        actionCount += 1
    }
}
