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
/// It exists only where the App Store receipt is a sandbox one (`MonetizationBuildChannel`):
/// a copy TestFlight installed, the copy App Review runs, or a copy Xcode installed on a
/// device. A copy from the App Store carries a receipt named `receipt` and shows nothing here,
/// and so do a build with no receipt and a run on a simulator, whose receipt carries the App
/// Store name.
///
/// It never touches Pro. Pro comes from StoreKit, and a purchase made from a TestFlight build
/// goes to the sandbox and costs nothing, which is the documented way to test it.
struct SettingsTestingSection: View {
    /// The channel that decides whether this section exists. Always this build's channel in the
    /// app; a parameter so previews and tests can ask for another one.
    var channel: MonetizationBuildChannel = .current

    @Environment(AppModel.self) private var app

    @State private var confirmsReset = false
    @State private var confirmsGrant = false
    @State private var message: String?
    @State private var actionCount = 0

    @ViewBuilder
    var body: some View {
        if channel.offersTestingTools, let grants = app.credits as? any MonetizationTestingGrants {
            content(grants)
        }
    }

    private func content(_ grants: any MonetizationTestingGrants) -> some View {
        let counts = grants.testingCounts
        return VStack(alignment: .leading, spacing: 0) {
            GroupedSectionLabel(MonetizationTestingCopy.sectionLabel)
            GroupedCard {
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
            Button(MonetizationTestingCopy.resetConfirm, role: .destructive) { reset(grants) }
            Button(MonetizationTestingCopy.cancel, role: .cancel) {}
        } message: {
            Text(MonetizationTestingCopy.resetDetail)
        }
        .confirmationDialog(
            MonetizationTestingCopy.grantQuestion(MonetizationTestingGrant.analysesPerGrant),
            isPresented: $confirmsGrant,
            titleVisibility: .visible
        ) {
            Button(MonetizationTestingCopy.grantConfirm) { grant(grants) }
            Button(MonetizationTestingCopy.cancel, role: .cancel) {}
        } message: {
            Text(MonetizationTestingCopy.grantDetail(MonetizationTestingGrant.analysesPerGrant))
        }
        .sensoryFeedback(.success, trigger: actionCount)
    }

    private func reset(_ grants: any MonetizationTestingGrants) {
        let before = grants.testingCounts
        let changed = grants.resetFreeAnalyses(for: channel)
        let after = grants.testingCounts
        message = changed ? MonetizationTestingCopy.resetDone(before: before, after: after) : MonetizationTestingCopy.nothingChanged
        actionCount += 1
    }

    private func grant(_ grants: any MonetizationTestingGrants) {
        let before = grants.testingCounts
        let changed = grants.grantTestingAnalyses(for: channel)
        let after = grants.testingCounts
        message = changed ? MonetizationTestingCopy.grantDone(before: before, after: after) : MonetizationTestingCopy.nothingChanged
        actionCount += 1
    }
}
