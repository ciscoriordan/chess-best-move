import SwiftUI

/// CreditsIndicator (design.md section 6, monetization.md section 3).
///
/// Remaining free analyses as a tally of small squares followed by text. At zero free
/// analyses the squares are all outlined and the text reads "No free analyses" in `accent`.
/// Purchased credits (a separate balance) show in text ("12 analyses left") once the free ones
/// are used up. Hidden entirely for Pro.
///
/// **It opens the paywall in every state (owner decision of 2026-09-28).** It used to be a
/// button only at zero, while keeping its 44 pt hit target and its tappable shape in every
/// state: a reader on a fresh install who tapped "3 free" got nothing, which is the defect App
/// Review rejected version 1.0.6 for on Settings' Plan row, on the one purchase-adjacent thing
/// the first screen shows. Buying early is also a thing a reader may want to do, and this is
/// the shortest way to the prices.
///
/// This view is presentation only; `CreditsToolbarIndicator` (App/Sources/App) connects it
/// to the credits and store services.
struct CreditsIndicator: View {
    var freeRemaining: Int
    var freeAllowance: Int = 3
    var purchasedRemaining: Int = 0
    var isPro: Bool
    var onOpenPaywall: () -> Void

    var body: some View {
        if !isPro {
            Button(action: onOpenPaywall) { content }
                .buttonStyle(.plain)
                .accessibilityHint(Self.hint)
        }
    }

    /// Said in every state, because the button is there in every state.
    static let hint = "Opens purchase options"

    private var isExhausted: Bool { freeRemaining <= 0 && purchasedRemaining <= 0 }

    private var content: some View {
        HStack(spacing: Spacing.s2) {
            if purchasedRemaining <= 0 || freeRemaining > 0 {
                CreditsTally(remaining: max(0, freeRemaining), allowance: freeAllowance)
            }
            Text(text)
                .typography(.callout)
                .foregroundStyle(isExhausted ? Palette.accent : Palette.ink2)
                // No line limit: below the accessibility sizes the string is short enough for
                // the toolbar, and at those sizes the indicator has moved into the scrolling
                // content (`CreditsInlineIndicator`), where it may wrap.
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(minHeight: Layout.minimumHitTarget)
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
    }

    private var text: String {
        if freeRemaining > 0 { return "\(freeRemaining) free" }
        if purchasedRemaining > 0 { return purchasedRemaining == 1 ? "1 analysis left" : "\(purchasedRemaining) analyses left" }
        return "No free analyses"
    }

    private var accessibilityText: String {
        if freeRemaining > 0 { return "\(freeRemaining) of \(freeAllowance) free analyses left" }
        if purchasedRemaining > 0 { return text }
        return "No free analyses left"
    }
}

/// The tally of squares: 8 x 8 pt, radius 1, 3 pt gap. Filled `ink` for remaining,
/// outlined `rule2` for used.
///
/// The squares grow with the `callout` text beside them, so the graphical half of the
/// indicator does not disappear next to a 49 pt figure. They stop at `Layout.maximumRowIcon`
/// for the same reason a row's icon does.
struct CreditsTally: View {
    var remaining: Int
    var allowance: Int = 3

    @ScaledMetric(relativeTo: .subheadline) private var scaledSide: CGFloat = 8
    @ScaledMetric(relativeTo: .subheadline) private var scaledGap: CGFloat = 3

    private var side: CGFloat { min(scaledSide, Layout.maximumRowIcon) }

    var body: some View {
        HStack(spacing: min(scaledGap, Layout.maximumRowIcon / 2)) {
            ForEach(0..<allowance, id: \.self) { index in
                let shape = RoundedRectangle(cornerRadius: side / 8, style: .continuous)
                if index < remaining {
                    shape.fill(Palette.ink).frame(width: side, height: side)
                } else {
                    shape.strokeBorder(Palette.rule2, lineWidth: 1).frame(width: side, height: side)
                }
            }
        }
        .accessibilityHidden(true)
    }
}

#Preview("Credits indicator") {
    VStack(alignment: .trailing, spacing: Spacing.s3) {
        CreditsIndicator(freeRemaining: 3, isPro: false) {}
        CreditsIndicator(freeRemaining: 2, isPro: false) {}
        CreditsIndicator(freeRemaining: 1, isPro: false) {}
        CreditsIndicator(freeRemaining: 0, isPro: false) {}
        CreditsIndicator(freeRemaining: 0, purchasedRemaining: 12, isPro: false) {}
        CreditsIndicator(freeRemaining: 2, isPro: true) {}
    }
    .padding(Spacing.s4)
    .background(Palette.canvas)
}
