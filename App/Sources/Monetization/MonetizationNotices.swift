import SwiftUI

/// A banner under a result: a rule, then one strip carrying a sentence and a chevron at the
/// trailing edge. The `Button` wraps the whole strip and the fill is drawn inside it, so a tap
/// anywhere on the width opens what the banner offers. VoiceOver reads the sentence and then
/// the hint, which says what double tapping does.
///
/// It spans the width it is given, which on the result screen is the content column inside the
/// side gutter.
struct MonetizationBanner: View {
    let message: String
    /// The VoiceOver hint: what double tapping does.
    let hint: String
    let identifier: String
    let action: () -> Void

    /// The chevron grows with the `callout` message (text style `subheadline`) and stops at
    /// 28 pt, so at accessibility sizes the message keeps the width it needs to wrap in.
    @ScaledMetric(relativeTo: .subheadline) private var chevronSize: CGFloat = 17

    var body: some View {
        VStack(spacing: 0) {
            Hairline()
            Button(action: action) {
                HStack(spacing: Spacing.s3) {
                    Text(message)
                        .typography(.callout)
                        .foregroundStyle(Palette.ink)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Image(systemName: "chevron.right.circle.fill")
                        .font(.system(size: min(chevronSize, 28)))
                        .foregroundStyle(Palette.ink2)
                        .accessibilityHidden(true)
                }
                .padding(.horizontal, Spacing.s3)
                .padding(.vertical, Spacing.s3)
                .frame(maxWidth: .infinity, minHeight: Layout.minimumHitTarget, alignment: .leading)
                // The fill belongs inside the button: it is what makes the whole strip, rather
                // than the words in it, the tap target.
                .background(Palette.raised)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier(identifier)
            .accessibilityLabel(message)
            .accessibilityHint(hint)
        }
        .frame(maxWidth: .infinity)
    }
}

/// The banner under a result that used the last free analysis (monetization.md 4.1): "That was
/// your last free analysis. See options", tappable across its whole width, which opens the
/// paywall. No popup.
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
            MonetizationBanner(
                message: MonetizationCopy.lastFreeAnalysisBanner,
                hint: MonetizationCopy.seeOptionsHint,
                identifier: MonetizationAccessibilityID.lastFreeAnalysisNotice
            ) {
                app.presentPaywall(trigger: .lastFreeAnalysisNotice)
            }
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
}

/// The one-time "Switch to yearly" card for weekly subscribers from their 4th paid week
/// (monetization.md 4.9). Analysis places it on the result screen; it draws nothing unless
/// `StoreService.shouldOfferSwitchToYearly` is true. Tapping it opens the paywall with Yearly
/// preselected; tapping it or its dismiss control records that it was shown.
///
/// It is not a `MonetizationBanner`, and forcing it into one would cost the user something:
/// the card carries a second control (the dismiss button), so the whole strip cannot be one
/// tap target, and it carries a title and a body line rather than a single sentence.
struct SwitchToYearlyCard: View {
    @Environment(AppModel.self) private var app

    /// The dismiss glyph grows with the body text beside it.
    @ScaledMetric(relativeTo: .body) private var dismissGlyphSize: CGFloat = 13

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
                            // The only way to decline the offer without opening the paywall.
                            // It used to be a literal 13 pt glyph at every text size, which
                            // made it the smallest affordance in the app.
                            Image(systemName: "xmark")
                                .font(.system(size: min(dismissGlyphSize, Layout.maximumRowChevron), weight: .semibold))
                                .foregroundStyle(Palette.ink2)
                                .frame(
                                    minWidth: Layout.minimumHitTarget,
                                    minHeight: Layout.minimumHitTarget
                                )
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
