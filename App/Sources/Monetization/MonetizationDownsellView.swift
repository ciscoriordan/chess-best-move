import SwiftUI

/// The half-height pack offer shown after the credit-trigger paywall was closed
/// (monetization.md 4.6 and section 6). `AppModel` decides whether it appears
/// (`CreditsService.shouldOfferDownsell`) and records a close without buying, which starts the
/// 24-hour pause. The close control is never disabled: tapped while the pack purchase is in
/// flight, the sheet ends as soon as StoreKit returns and reports what actually happened, so a
/// bought pack is never recorded as a decline (`MonetizationSheetRules`).
struct DownsellView: View {
    let context: DownsellContext
    let onFinish: (DownsellOutcome) -> Void

    @Environment(AppModel.self) private var app

    @State private var phase: DownsellPhase = .choosing
    @State private var errorText: String?
    @State private var successFeedback = 0
    @State private var errorFeedback = 0
    @State private var hasFinished = false
    /// The sheet was opened for a pending analysis (captured when it appears, because
    /// `AppModel` may resume that analysis before this sheet ends).
    @State private var opensForPendingAnalysis = false
    /// The close control was tapped while the purchase was in flight.
    @State private var closeRequested = false
    /// The height of the sheet's content and of the bars around it, for a sheet that fits its
    /// content instead of a fixed half-height detent with empty space below the button.
    @State private var contentHeight: CGFloat = 0
    @State private var chromeHeight: CGFloat = 0

    init(context: DownsellContext, onFinish: @escaping (DownsellOutcome) -> Void) {
        self.context = context
        self.onFinish = onFinish
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Spacing.s3) {
                    Text(MonetizationCopy.downsellTitle)
                        .typography(.title)
                        .foregroundStyle(Palette.ink)
                        .accessibilityAddTraits(.isHeader)
                    content
                    if let errorText {
                        Text(errorText)
                            .typography(.callout)
                            .foregroundStyle(Palette.danger)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .sideGutter()
                .padding(.bottom, Spacing.s5)
                .onGeometryChange(for: CGFloat.self) { proxy in
                    proxy.size.height
                } action: { height in
                    contentHeight = height
                }
            }
            .scrollBounceBehavior(.basedOnSize)
            .onGeometryChange(for: CGFloat.self) { proxy in
                proxy.safeAreaInsets.top + proxy.safeAreaInsets.bottom
            } action: { height in
                chromeHeight = height
            }
            .background(Palette.raised)
            .navigationBarTitleDisplayMode(.inline)
            .modalCloseButton(placement: .topBarTrailing) { close() }
        }
        .presentationDetents(detents)
        .interactiveDismissDisabled(phase != .choosing)
        .accessibilityIdentifier(MonetizationAccessibilityID.downsellScreen)
        .sensoryFeedback(.success, trigger: successFeedback)
        .sensoryFeedback(.error, trigger: errorFeedback)
        .onAppear {
            if app.pendingAnalysis != nil { opensForPendingAnalysis = true }
            finishIfNoLongerNeeded()
        }
        .task { await app.store.loadProducts() }
        .onChange(of: app.credits.purchasedRemaining) { oldValue, newValue in
            guard newValue > oldValue else { return }
            if phase == .waitingForApproval {
                // An Ask to Buy approval arrived while the sheet is still open.
                successFeedback += 1
                finish(.purchased)
            } else {
                finishIfNoLongerNeeded()
            }
        }
        .onChange(of: app.store.isPro) { _, isPro in
            guard isPro else { return }
            finishIfNoLongerNeeded()
        }
    }

    /// Pro or purchased credits arrived while the offer waits for the user's choice (for
    /// example a Pro purchase from the paywall that returned after it closed): the pending
    /// analysis can run, so the sheet ends as bought, without recording a decline.
    private func finishIfNoLongerNeeded() {
        guard phase == .choosing,
              MonetizationSheetRules.downsellShouldFinishAsPurchased(
                  hasPendingAnalysis: opensForPendingAnalysis,
                  isPro: app.store.isPro,
                  purchasedRemaining: app.credits.purchasedRemaining
              ) else { return }
        finish(.purchased)
    }

    /// Fits the content; the system caps a detent taller than the screen at the large height.
    private var detents: Set<PresentationDetent> {
        guard contentHeight > 0 else { return [.medium] }
        return [.height((contentHeight + chromeHeight).rounded(.up))]
    }

    private var pack: StoreProduct? {
        app.store.products.first { MonetizationProductKind(productID: $0.id) == .pack }
    }

    @ViewBuilder
    private var content: some View {
        if let pack {
            Text(MonetizationCopy.downsellBody(price: pack.displayPrice))
                .typography(.body)
                .foregroundStyle(Palette.ink2)
                .fixedSize(horizontal: false, vertical: true)
            if phase == .waitingForApproval {
                MonetizationWaitingForApproval(explanation: MonetizationCopy.downsellWaitingBody)
            } else {
                Button {
                    Task { await buy(pack) }
                } label: {
                    HStack(spacing: Spacing.s2) {
                        if phase == .purchasing {
                            ProgressView()
                                .tint(Palette.ink3)
                            Text(MonetizationCopy.confirming)
                        } else {
                            Text(MonetizationCopy.downsellButton(price: pack.displayPrice))
                        }
                    }
                }
                .buttonStyle(.primary)
                .disabled(phase != .choosing)
                .padding(.top, Spacing.s2)
                .accessibilityIdentifier(MonetizationAccessibilityID.downsellBuy)
            }
        } else if let reason = MonetizationSheetRules.unavailableReason(loadState: app.store.loadState) {
            Text(reason)
                .typography(.body)
                .foregroundStyle(Palette.ink)
                .fixedSize(horizontal: false, vertical: true)
            SecondaryButton(MonetizationCopy.tryAgain) {
                Task { await app.store.loadProducts() }
            }
        } else {
            VStack(alignment: .leading, spacing: Spacing.s2) {
                RoundedRectangle(cornerRadius: Radius.r1, style: .continuous)
                    .fill(Palette.sunken)
                    .frame(height: 46)
                RoundedRectangle(cornerRadius: Radius.r2, style: .continuous)
                    .fill(Palette.sunken)
                    .frame(height: Layout.buttonHeight)
                    .padding(.top, Spacing.s2)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Loading purchase options")
        }
    }

    private func buy(_ pack: StoreProduct) async {
        errorText = nil
        phase = .purchasing
        let outcome = await app.store.purchase(pack.id)
        if case .purchased = outcome { successFeedback += 1 }
        switch MonetizationSheetRules.downsellStep(after: outcome, closeRequested: closeRequested) {
        case .finish(let result):
            phase = .choosing
            finish(result)
        case .waitForApproval:
            phase = .waitingForApproval
        case .choose(let errorMessage):
            phase = .choosing
            if let errorMessage {
                errorText = errorMessage
                errorFeedback += 1
            }
        }
    }

    private func close() {
        switch phase {
        case .waitingForApproval:
            finish(.pendingApproval)
        case .purchasing:
            // `buy` finishes with the purchase's real outcome as soon as StoreKit returns.
            closeRequested = true
        case .choosing:
            finish(.closed)
        }
    }

    private func finish(_ outcome: DownsellOutcome) {
        guard !hasFinished else { return }
        hasFinished = true
        onFinish(outcome)
    }
}

enum DownsellPhase: Hashable {
    case choosing
    case purchasing
    case waitingForApproval
}
