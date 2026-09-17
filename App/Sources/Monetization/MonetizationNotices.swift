import SwiftUI

/// The line under a result that used the last free analysis (monetization.md 4.1): "That was
/// your last free analysis." with a "See options" link that opens the paywall. No popup.
///
/// Analysis places it under the result of any session; it draws nothing unless that session
/// spent the last free analysis and no other credit or Pro remains.
struct LastFreeAnalysisNotice: View {
    let session: AnalysisSession

    @Environment(AppModel.self) private var app

    init(session: AnalysisSession) {
        self.session = session
    }

    var body: some View {
        if Self.isShown(
            decision: session.authorization?.decision,
            isCreditCommitted: session.isCreditCommitted,
            freeRemaining: app.credits.freeRemaining,
            purchasedRemaining: app.credits.purchasedRemaining,
            isPro: app.store.isPro
        ) {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .firstTextBaseline, spacing: Spacing.s2) {
                    message
                    link
                }
                VStack(alignment: .leading, spacing: 0) {
                    message
                    link
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityIdentifier(MonetizationAccessibilityID.lastFreeAnalysisNotice)
        }
    }

    /// Shown for the session that spent a free analysis once nothing is left to spend.
    static func isShown(
        decision: CreditDecision?,
        isCreditCommitted: Bool,
        freeRemaining: Int,
        purchasedRemaining: Int,
        isPro: Bool
    ) -> Bool {
        decision == .spendFree && isCreditCommitted && freeRemaining == 0 && purchasedRemaining == 0 && !isPro
    }

    private var message: some View {
        Text(MonetizationCopy.lastFreeAnalysis)
            .typography(.callout)
            .foregroundStyle(Palette.ink2)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var link: some View {
        Button(MonetizationCopy.seeOptions) {
            app.presentPaywall(trigger: .lastFreeAnalysisNotice)
        }
        .buttonStyle(.textLink)
    }
}

/// The one-time "Switch to yearly" card for weekly subscribers from their 4th paid week
/// (monetization.md 4.9). Analysis places it on the result screen; it draws nothing unless
/// `StoreService.shouldOfferSwitchToYearly` is true. Tapping it opens the paywall with Yearly
/// preselected; tapping it or its dismiss control records that it was shown.
struct SwitchToYearlyCard: View {
    @Environment(AppModel.self) private var app

    init() {}

    var body: some View {
        Group {
            if app.store.shouldOfferSwitchToYearly, let yearly {
                VStack(spacing: 0) {
                    Hairline()
                    HStack(alignment: .top, spacing: Spacing.s2) {
                        Button {
                            app.store.recordSwitchToYearlyOfferShown()
                            app.presentPaywall(trigger: .switchToYearly, preselectedProductID: yearly.id)
                        } label: {
                            VStack(alignment: .leading, spacing: Spacing.s1) {
                                Text(MonetizationCopy.switchToYearlyTitle(price: yearly.displayPrice))
                                    .typography(.headline)
                                    .foregroundStyle(Palette.ink)
                                    .fixedSize(horizontal: false, vertical: true)
                                if let perWeek = MonetizationCopy.pricePerWeek(yearly) {
                                    Text(MonetizationCopy.switchToYearlyBody(perWeek: perWeek))
                                        .typography(.callout)
                                        .foregroundStyle(Palette.ink2)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                            }
                            .frame(maxWidth: .infinity, minHeight: Layout.minimumHitTarget, alignment: .leading)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.listRow)
                        Button {
                            app.store.recordSwitchToYearlyOfferShown()
                        } label: {
                            Image(systemName: "xmark")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(Palette.ink2)
                                .frame(width: Layout.minimumHitTarget, height: Layout.minimumHitTarget)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(MonetizationCopy.dismiss)
                    }
                    .padding(.vertical, Spacing.s2)
                    Hairline()
                }
                .accessibilityIdentifier(MonetizationAccessibilityID.switchToYearlyCard)
            }
        }
        .task(id: app.store.shouldOfferSwitchToYearly) {
            if app.store.shouldOfferSwitchToYearly {
                await app.store.loadProducts()
            }
        }
    }

    private var yearly: StoreProduct? {
        app.store.products.first { MonetizationProductKind(productID: $0.id) == .yearly }
    }
}
