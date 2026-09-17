import ChessCore
import SwiftUI

/// Accessibility identifiers of the monetization screens, for UI tests.
enum MonetizationAccessibilityID {
    static let paywallScreen = "paywall.screen"
    static let paywallContinue = "paywall.continue"
    static let paywallRestore = "paywall.restore"
    static let paywallMessage = "paywall.message"
    static let paywallWaitingForApproval = "paywall.waitingForApproval"
    static let paywallLifetimeNotice = "paywall.lifetimeNotice"
    static func paywallOption(_ productID: String) -> String { "paywall.option.\(productID)" }
    static let downsellScreen = "downsell.screen"
    static let downsellBuy = "downsell.buy"
    static let lastFreeAnalysisNotice = "result.lastFreeAnalysisNotice"
    static let switchToYearlyCard = "result.switchToYearly"
}

/// The paywall sheet (design.md 9.7, monetization.md sections 4 and 6).
///
/// It reports how it ended through `onFinish` and never dismisses itself; `AppModel` decides
/// what follows. Closing while a purchase waits for approval reports `.pendingApproval`;
/// closing the "subscription is still active" notice after buying lifetime reports
/// `.unlocked`. The close control is never disabled: tapped while a purchase or restore is in
/// flight, the sheet ends as soon as StoreKit returns and reports what actually happened, so a
/// purchase is never reported as a close (`MonetizationSheetRules`).
struct PaywallView: View {
    let context: PaywallContext
    let onFinish: (PaywallOutcome) -> Void

    @Environment(AppModel.self) private var app
    @Environment(\.openURL) private var openURL
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var selectedProductID: String?
    @State private var phase: PaywallPhase = .choosing
    @State private var message: PaywallMessage?
    @State private var isRestoring = false
    @State private var successFeedback = 0
    @State private var errorFeedback = 0
    @State private var hasFinished = false
    /// The sheet was opened for a pending analysis (captured when it appears, because
    /// `AppModel` may resume that analysis before this sheet ends).
    @State private var opensForPendingAnalysis = false
    /// The close control was tapped while a purchase or restore was in flight.
    @State private var closeRequested = false

    init(context: PaywallContext, onFinish: @escaping (PaywallOutcome) -> Void) {
        self.context = context
        self.onFinish = onFinish
    }

    var body: some View {
        NavigationStack {
            ScrollViewReader { scroller in
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        header
                        Text(MonetizationCopy.headline)
                            .typography(.display)
                            .foregroundStyle(Palette.ink)
                            .accessibilityAddTraits(.isHeader)
                            .padding(.top, showsHeader ? Spacing.s5 : 0)
                        Hairline()
                            .padding(.vertical, Spacing.s4)
                        benefits
                        switch phase {
                        case .lifetimeWhileSubscribed(_, let subscriptionProductID):
                            lifetimeNotice(subscriptionProductID: subscriptionProductID)
                                .padding(.top, Spacing.s5)
                        default:
                            options
                                .padding(.top, Spacing.s5)
                            purchaseArea
                                .padding(.top, Spacing.s4)
                                .id(PaywallScrollTarget.purchaseArea)
                        }
                        links
                            .padding(.top, Spacing.s2)
                        if let message {
                            Text(message.text)
                                .typography(.callout)
                                .foregroundStyle(message.isError ? Palette.danger : Palette.ink2)
                                .fixedSize(horizontal: false, vertical: true)
                                .accessibilityIdentifier(MonetizationAccessibilityID.paywallMessage)
                                .id(PaywallScrollTarget.message)
                        }
                    }
                    .sideGutter()
                    .padding(.bottom, Spacing.s5)
                }
                .onChange(of: phase) { _, newPhase in
                    // Ask to Buy: bring "Waiting for approval" into view.
                    guard case .waitingForApproval = newPhase else { return }
                    withAnimation(reduceMotion ? nil : .easeOut(duration: Motion.stateLong)) {
                        scroller.scrollTo(PaywallScrollTarget.purchaseArea, anchor: .bottom)
                    }
                }
                .onChange(of: message) { _, newMessage in
                    guard newMessage != nil else { return }
                    withAnimation(reduceMotion ? nil : .easeOut(duration: Motion.stateLong)) {
                        scroller.scrollTo(PaywallScrollTarget.message, anchor: .bottom)
                    }
                }
            }
            .background(Palette.canvas)
            .navigationBarTitleDisplayMode(.inline)
            .modalCloseButton(placement: .topBarTrailing) { close() }
        }
        .interactiveDismissDisabled(phase.blocksSwipeDismissal || isRestoring)
        .accessibilityIdentifier(MonetizationAccessibilityID.paywallScreen)
        .sensoryFeedback(.success, trigger: successFeedback)
        .sensoryFeedback(.error, trigger: errorFeedback)
        .onAppear {
            if app.pendingAnalysis != nil { opensForPendingAnalysis = true }
            unlockIfEntitlementArrived()
        }
        .task { await app.store.loadProducts() }
        .onChange(of: app.store.isPro) { _, isPro in
            guard isPro else { return }
            if case .waitingForApproval(let productID) = phase {
                // An Ask to Buy approval arrived while the sheet is still open.
                successFeedback += 1
                finish(.unlocked(productID: productID))
            } else {
                unlockIfEntitlementArrived()
            }
        }
        .onChange(of: app.credits.purchasedRemaining) { oldValue, newValue in
            guard newValue > oldValue else { return }
            unlockIfEntitlementArrived()
        }
    }

    /// Pro (for example once the launch refresh finished) or purchased credits arrived while this
    /// credit-trigger paywall waits for the user's choice: the pending board no longer needs a
    /// purchase, so the sheet ends as unlocked and the analysis starts.
    private func unlockIfEntitlementArrived() {
        guard phase == .choosing, !isRestoring,
              let productID = MonetizationSheetRules.paywallUnlockedProductID(
                  trigger: context.trigger,
                  hasPendingAnalysis: opensForPendingAnalysis,
                  isPro: app.store.isPro,
                  activeSubscriptionProductID: app.store.activeSubscriptionProductID,
                  purchasedRemaining: app.credits.purchasedRemaining
              ) else { return }
        finish(.unlocked(productID: productID))
    }

    // MARK: Header

    private var usedAllowance: Bool {
        !app.store.isPro && app.credits.freeRemaining == 0
    }

    private var showsHeader: Bool {
        context.board != nil || (usedAllowance && context.trigger != .switchToYearly)
    }

    @ViewBuilder
    private var header: some View {
        if let board = context.board {
            HStack(alignment: .top, spacing: Spacing.s3) {
                MonetizationBoardThumbnail(snapshot: board)
                    .frame(width: 72, height: 72)
                VStack(alignment: .leading, spacing: Spacing.s1) {
                    Text(MonetizationCopy.boardReady)
                        .typography(.body)
                        .foregroundStyle(Palette.ink)
                    if usedAllowance {
                        Text(MonetizationCopy.usedAllowance(app.credits.freeAllowance))
                            .typography(.callout)
                            .foregroundStyle(Palette.ink2)
                    }
                }
                .fixedSize(horizontal: false, vertical: true)
            }
            .accessibilityElement(children: .combine)
        } else if usedAllowance, context.trigger != .switchToYearly {
            Text(MonetizationCopy.usedAllowance(app.credits.freeAllowance))
                .typography(.callout)
                .foregroundStyle(Palette.ink2)
        }
    }

    private var benefits: some View {
        VStack(alignment: .leading, spacing: Spacing.s2) {
            ForEach(MonetizationCopy.benefits(deviceName: MonetizationCopy.currentDeviceName), id: \.self) { benefit in
                HStack(alignment: .firstTextBaseline, spacing: Spacing.s3) {
                    Text("\u{2013}")
                        .typography(.body)
                        .foregroundStyle(Palette.ink2)
                        .accessibilityHidden(true)
                    Text(benefit)
                        .typography(.body)
                        .foregroundStyle(Palette.ink)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    // MARK: Options

    private var paywallProducts: [StoreProduct] {
        let order: [MonetizationProductKind] = [.weekly, .yearly, .lifetime]
        return app.store.products
            .filter { order.contains(MonetizationProductKind(productID: $0.id)) }
            .sorted {
                order.firstIndex(of: MonetizationProductKind(productID: $0.id))!
                    < order.firstIndex(of: MonetizationProductKind(productID: $1.id))!
            }
    }

    /// The selected product: the user's choice, else the context's preselection, else Weekly.
    private var selectedProduct: StoreProduct? {
        let products = paywallProducts
        for candidate in [selectedProductID, context.preselectedProductID] {
            if let candidate, let product = products.first(where: { $0.id == candidate }) {
                return product
            }
        }
        return products.first { MonetizationProductKind(productID: $0.id) == .weekly } ?? products.first
    }

    /// Why no row can be shown, once loading has ended without the paywall products.
    private var productsUnavailableReason: String? {
        guard paywallProducts.isEmpty else { return nil }
        return MonetizationSheetRules.unavailableReason(loadState: app.store.loadState)
    }

    @ViewBuilder
    private var options: some View {
        let products = paywallProducts
        if !products.isEmpty {
            VStack(spacing: Spacing.s3) {
                ForEach(products) { product in
                    let kind = MonetizationProductKind(productID: product.id)
                    PaywallOptionRow(
                        title: MonetizationCopy.rowTitle(kind, product: product),
                        price: MonetizationCopy.rowPrice(product),
                        detail: MonetizationCopy.rowDetail(
                            kind,
                            product: product,
                            isCurrentPlan: product.id == app.store.activeSubscriptionProductID
                        ),
                        accessibilityLabel: MonetizationCopy.rowAccessibilityLabel(
                            title: MonetizationCopy.rowTitle(kind, product: product),
                            product: product,
                            detail: MonetizationCopy.rowDetail(
                                kind,
                                product: product,
                                isCurrentPlan: product.id == app.store.activeSubscriptionProductID
                            )
                        ),
                        isSelected: product.id == selectedProduct?.id
                    ) {
                        selectedProductID = product.id
                    }
                    .disabled(!phase.allowsSelection)
                    .accessibilityIdentifier(MonetizationAccessibilityID.paywallOption(product.id))
                }
            }
        } else if let reason = productsUnavailableReason {
            VStack(alignment: .leading, spacing: Spacing.s3) {
                Text(reason)
                    .typography(.body)
                    .foregroundStyle(Palette.ink)
                    .fixedSize(horizontal: false, vertical: true)
                SecondaryButton(MonetizationCopy.tryAgain) {
                    Task { await app.store.loadProducts() }
                }
            }
        } else {
            VStack(spacing: Spacing.s3) {
                ForEach(0..<3, id: \.self) { _ in
                    RoundedRectangle(cornerRadius: Radius.r3, style: .continuous)
                        .fill(Palette.sunken)
                        .frame(height: PaywallOptionRow.placeholderHeight)
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Loading purchase options")
        }
    }

    // MARK: Purchase

    @ViewBuilder
    private var purchaseArea: some View {
        if case .waitingForApproval = phase {
            MonetizationWaitingForApproval(
                explanation: context.board == nil
                    ? MonetizationCopy.waitingForApprovalWithoutBoard
                    : MonetizationCopy.waitingForApprovalWithBoard
            )
            .accessibilityIdentifier(MonetizationAccessibilityID.paywallWaitingForApproval)
        } else if productsUnavailableReason != nil {
            // design.md 9.7: the error state is the message and "Try again" only.
            EmptyView()
        } else {
            let product = selectedProduct
            VStack(alignment: .leading, spacing: Spacing.s3) {
                Button {
                    guard let product else { return }
                    Task { await buy(product) }
                } label: {
                    HStack(spacing: Spacing.s2) {
                        if phase.isPurchasing {
                            ProgressView()
                                .tint(Palette.ink3)
                            Text(MonetizationCopy.confirming)
                        } else if let product {
                            Text(MonetizationCopy.continueButton(product))
                        } else {
                            Text("Continue")
                        }
                    }
                }
                .buttonStyle(.primary)
                .disabled(product == nil || !phase.allowsSelection || isRestoring)
                .accessibilityIdentifier(MonetizationAccessibilityID.paywallContinue)

                if let product {
                    Text(MonetizationCopy.terms(product))
                        .typography(.caption)
                        .foregroundStyle(Palette.ink2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private func lifetimeNotice(subscriptionProductID: String) -> some View {
        VStack(alignment: .leading, spacing: Spacing.s3) {
            Text(MonetizationCopy.lifetimeUnlocked)
                .typography(.title)
                .foregroundStyle(Palette.ink)
                .accessibilityAddTraits(.isHeader)
            Text(MonetizationCopy.subscriptionStillActive(MonetizationProductKind(productID: subscriptionProductID)))
                .typography(.headline)
                .foregroundStyle(Palette.ink)
                .fixedSize(horizontal: false, vertical: true)
            Text(MonetizationCopy.subscriptionStillActiveBody)
                .typography(.body)
                .foregroundStyle(Palette.ink2)
                .fixedSize(horizontal: false, vertical: true)
            PrimaryButton(MonetizationCopy.manageSubscription) {
                Task { await app.store.showManageSubscriptions() }
            }
            .padding(.top, Spacing.s2)
        }
        .accessibilityIdentifier(MonetizationAccessibilityID.paywallLifetimeNotice)
    }

    // MARK: Links

    private var links: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: Spacing.s2) {
                restoreLink
                separator
                termsLink
                separator
                privacyLink
            }
            VStack(alignment: .leading, spacing: 0) {
                restoreLink
                termsLink
                privacyLink
            }
        }
    }

    private var separator: some View {
        Text("\u{00B7}")
            .typography(.callout)
            .foregroundStyle(Palette.ink3)
            .accessibilityHidden(true)
    }

    private var restoreLink: some View {
        Button(isRestoring ? MonetizationCopy.restoring : MonetizationCopy.restorePurchases) {
            Task { await restore() }
        }
        .buttonStyle(.textLink)
        .disabled(isRestoring || phase.isPurchasing)
        .accessibilityIdentifier(MonetizationAccessibilityID.paywallRestore)
    }

    private var termsLink: some View {
        Button(MonetizationCopy.termsOfUse) { openURL(MonetizationLegalLinks.termsOfUse) }
            .buttonStyle(.textLink)
            .accessibilityAddTraits(.isLink)
    }

    private var privacyLink: some View {
        Button(MonetizationCopy.privacyPolicy) { openURL(MonetizationLegalLinks.privacyPolicy) }
            .buttonStyle(.textLink)
            .accessibilityAddTraits(.isLink)
    }

    // MARK: Actions

    private func buy(_ product: StoreProduct) async {
        message = nil
        let subscriptionBefore = app.store.activeSubscriptionProductID
        phase = .purchasing(product.id)
        let outcome = await app.store.purchase(product.id)
        let step = MonetizationSheetRules.paywallStep(
            after: outcome,
            productID: product.id,
            activeSubscriptionProductID: app.store.activeSubscriptionProductID ?? subscriptionBefore,
            closeRequested: closeRequested
        )
        if case .purchased = outcome { successFeedback += 1 }
        switch step {
        case .finish(let result):
            phase = .choosing
            finish(result)
        case .showLifetimeNotice(let lifetimeProductID, let subscriptionProductID):
            // monetization.md 4.5: Apple does not cancel the subscription automatically, so the
            // notice is shown even if the close control was tapped during the purchase.
            closeRequested = false
            phase = .lifetimeWhileSubscribed(lifetimeProductID: lifetimeProductID, subscriptionProductID: subscriptionProductID)
        case .waitForApproval(let productID):
            phase = .waitingForApproval(productID: productID)
        case .choose(let errorMessage):
            phase = .choosing
            if let errorMessage {
                message = PaywallMessage(text: errorMessage, isError: true)
                errorFeedback += 1
            }
        }
    }

    private func restore() async {
        message = nil
        isRestoring = true
        let outcome = await app.store.restore()
        isRestoring = false
        let step = MonetizationSheetRules.paywallStep(
            afterRestore: outcome,
            isPro: app.store.isPro,
            activeSubscriptionProductID: app.store.activeSubscriptionProductID,
            trigger: context.trigger,
            purchasedRemaining: app.credits.purchasedRemaining,
            closeRequested: closeRequested
        )
        if case .restored = outcome { successFeedback += 1 }
        switch step {
        case .finish(let result):
            finish(result)
        case .message(let text, let isError):
            message = PaywallMessage(text: text, isError: isError)
            if isError { errorFeedback += 1 }
        case .choose:
            break
        }
    }

    private func close() {
        switch phase {
        case .waitingForApproval:
            finish(.pendingApproval)
        case .lifetimeWhileSubscribed(let lifetimeProductID, _):
            finish(.unlocked(productID: lifetimeProductID))
        case .purchasing:
            // `buy` finishes with the purchase's real outcome as soon as StoreKit returns.
            closeRequested = true
        case .choosing:
            if isRestoring {
                closeRequested = true
            } else {
                finish(.closed)
            }
        }
    }

    private func finish(_ outcome: PaywallOutcome) {
        guard !hasFinished else { return }
        hasFinished = true
        onFinish(outcome)
    }
}

// MARK: - Parts

enum PaywallPhase: Hashable {
    case choosing
    case purchasing(String)
    case waitingForApproval(productID: String)
    case lifetimeWhileSubscribed(lifetimeProductID: String, subscriptionProductID: String)

    var isPurchasing: Bool {
        if case .purchasing = self { return true }
        return false
    }

    var allowsSelection: Bool { self == .choosing }

    /// While a purchase is in flight or its result is on screen, only the close control ends
    /// the sheet, so the outcome it reports is never lost to a swipe.
    var blocksSwipeDismissal: Bool { self != .choosing }
}

/// How the paywall and the downsell end, free of SwiftUI so the rules are unit tested
/// (monetization.md 4.4-4.7, design.md 9.7).
enum MonetizationSheetRules {
    enum PaywallStep: Hashable {
        case finish(PaywallOutcome)
        case showLifetimeNotice(lifetimeProductID: String, subscriptionProductID: String)
        case waitForApproval(productID: String)
        /// Back to choosing, with an error line when the purchase failed.
        case choose(errorMessage: String?)
    }

    enum RestoreStep: Hashable {
        case finish(PaywallOutcome)
        case message(String, isError: Bool)
        /// Back to choosing with nothing to report (the user canceled the sign-in).
        case choose
    }

    enum DownsellStep: Hashable {
        case finish(DownsellOutcome)
        case waitForApproval
        case choose(errorMessage: String?)
    }

    /// What the paywall does when a purchase returns. When the close control was tapped while
    /// the purchase was in flight, the sheet ends with what actually happened: unlocked if
    /// bought, pending approval if pending, closed otherwise (which can lead to the downsell).
    static func paywallStep(
        after outcome: PurchaseOutcome,
        productID: String,
        activeSubscriptionProductID: String?,
        closeRequested: Bool
    ) -> PaywallStep {
        switch outcome {
        case .purchased(let purchasedID):
            if MonetizationProductKind(productID: purchasedID) == .lifetime, let activeSubscriptionProductID {
                return .showLifetimeNotice(lifetimeProductID: purchasedID, subscriptionProductID: activeSubscriptionProductID)
            }
            return .finish(.unlocked(productID: purchasedID))
        case .pending:
            return closeRequested ? .finish(.pendingApproval) : .waitForApproval(productID: productID)
        case .cancelled:
            return closeRequested ? .finish(.closed) : .choose(errorMessage: nil)
        case .failed(let reason):
            return closeRequested ? .finish(.closed) : .choose(errorMessage: reason)
        }
    }

    /// What the paywall does when a restore returns.
    static func paywallStep(
        afterRestore outcome: RestoreOutcome,
        isPro: Bool,
        activeSubscriptionProductID: String?,
        trigger: PaywallTrigger,
        purchasedRemaining: Int,
        closeRequested: Bool
    ) -> RestoreStep {
        switch outcome {
        case .restored:
            if isPro {
                return .finish(.unlocked(productID: activeSubscriptionProductID ?? ProductID.proLifetime))
            }
            if trigger == .creditsExhausted, purchasedRemaining > 0 {
                return .finish(.unlocked(productID: ProductID.credits15))
            }
            return closeRequested ? .finish(.closed) : .message(MonetizationCopy.purchasesRestored, isError: false)
        case .nothingFound:
            return closeRequested ? .finish(.closed) : .message(MonetizationCopy.nothingToRestore, isError: false)
        case .canceled:
            // Like a canceled purchase: no message, no error haptic.
            return closeRequested ? .finish(.closed) : .choose
        case .failed(let reason):
            return closeRequested ? .finish(.closed) : .message(reason, isError: true)
        }
    }

    /// What the downsell does when the pack purchase returns (see `paywallStep(after:)`). A
    /// close tapped during the purchase never records a decline for a pack that was bought.
    static func downsellStep(after outcome: PurchaseOutcome, closeRequested: Bool) -> DownsellStep {
        switch outcome {
        case .purchased:
            return .finish(.purchased)
        case .pending:
            return closeRequested ? .finish(.pendingApproval) : .waitForApproval
        case .cancelled:
            return closeRequested ? .finish(.closed) : .choose(errorMessage: nil)
        case .failed(let reason):
            return closeRequested ? .finish(.closed) : .choose(errorMessage: reason)
        }
    }

    /// The product a credit-trigger paywall reports as unlocked when Pro or purchased credits
    /// arrived while it was open for a pending analysis, or nil when it stays open.
    static func paywallUnlockedProductID(
        trigger: PaywallTrigger,
        hasPendingAnalysis: Bool,
        isPro: Bool,
        activeSubscriptionProductID: String?,
        purchasedRemaining: Int
    ) -> String? {
        guard trigger == .creditsExhausted, hasPendingAnalysis else { return nil }
        if isPro { return activeSubscriptionProductID ?? ProductID.proLifetime }
        if purchasedRemaining > 0 { return ProductID.credits15 }
        return nil
    }

    /// Whether the downsell for a pending analysis should end as if the pack was bought: Pro or
    /// purchased credits arrived while it was open, so the analysis can run.
    static func downsellShouldFinishAsPurchased(hasPendingAnalysis: Bool, isPro: Bool, purchasedRemaining: Int) -> Bool {
        hasPendingAnalysis && (isPro || purchasedRemaining > 0)
    }

    /// The error line of a purchase screen whose products are not there once loading ended:
    /// the load failed, or it succeeded without them (App Store Connect served only some
    /// products). Nil while loading.
    static func unavailableReason(loadState: StoreLoadState) -> String? {
        switch loadState {
        case .failed(let reason): reason
        case .loaded: MonetizationCopy.loadFailed
        case .idle, .loading: nil
        }
    }
}

enum PaywallScrollTarget: Hashable {
    case purchaseArea
    case message
}

struct PaywallMessage: Hashable {
    var text: String
    var isError: Bool
}

/// One paywall option: radio symbol, title, billed price, secondary line. Selected: 2 pt
/// `accent` border on `accentSubtle`; otherwise a 1 pt `rule2` border (design.md 9.7).
struct PaywallOptionRow: View {
    let title: String
    let price: String
    let detail: String
    let accessibilityLabel: String
    let isSelected: Bool
    let action: () -> Void

    static let placeholderHeight: CGFloat = 76

    @Environment(\.isEnabled) private var isEnabled
    /// The radio symbol grows with the row's `headline` title (text style `title3`) and stops
    /// growing where that token does (34 pt of 20 pt, so 37 pt of 22 pt).
    @ScaledMetric(relativeTo: .title3) private var radioSize: CGFloat = 22

    var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: Spacing.s3) {
                let radio = min(radioSize, 37)
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: radio, weight: .regular))
                    .foregroundStyle(isSelected ? Palette.accent : Palette.ink2)
                    .frame(width: radio + 2, height: radio + 2)
                    .padding(.top, 1)
                VStack(alignment: .leading, spacing: Spacing.s1) {
                    ViewThatFits(in: .horizontal) {
                        HStack(alignment: .firstTextBaseline, spacing: Spacing.s2) {
                            titleText
                            Spacer(minLength: Spacing.s2)
                            priceText
                        }
                        VStack(alignment: .leading, spacing: Spacing.s1) {
                            titleText
                                .fixedSize(horizontal: false, vertical: true)
                            // Stacked (large text, long local prices): the price wraps instead
                            // of running past the row (design.md 12: prices never truncate).
                            Text(price)
                                .typography(.data)
                                .foregroundStyle(Palette.ink)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    Text(detail)
                        .typography(.caption)
                        .foregroundStyle(Palette.ink2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.horizontal, Spacing.s4)
            .padding(.vertical, Spacing.s3)
            .frame(maxWidth: .infinity, minHeight: Self.placeholderHeight, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: Radius.r3, style: .continuous)
                    .fill(isSelected ? Palette.accentSubtle : Color.clear)
            )
            .overlay(
                RoundedRectangle(cornerRadius: Radius.r3, style: .continuous)
                    .strokeBorder(
                        isSelected ? Palette.accent : Palette.rule2,
                        lineWidth: isSelected ? LineWidth.selection : LineWidth.control
                    )
            )
            .contentShape(RoundedRectangle(cornerRadius: Radius.r3, style: .continuous))
            .opacity(isEnabled || isSelected ? 1 : 0.6)
        }
        .buttonStyle(PaywallOptionButtonStyle())
        .accessibilityLabel(accessibilityLabel)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private var titleText: some View {
        Text(title)
            .typography(.headline)
            .foregroundStyle(Palette.ink)
    }

    private var priceText: some View {
        Text(price)
            .typography(.data)
            .foregroundStyle(Palette.ink)
            .fixedSize(horizontal: true, vertical: false)
    }
}

private struct PaywallOptionButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.7 : 1)
    }
}

/// "Waiting for approval" in place of the purchase button.
struct MonetizationWaitingForApproval: View {
    let explanation: String

    /// The symbol grows with the `headline` title next to it (text style `title3`) and stops
    /// growing where that token does (34 pt of 20 pt, so 29 pt of 17 pt).
    @ScaledMetric(relativeTo: .title3) private var symbolSize: CGFloat = 17

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.s2) {
            HStack(alignment: .firstTextBaseline, spacing: Spacing.s2) {
                Image(systemName: "hourglass")
                    .font(.system(size: min(symbolSize, 29), weight: .semibold))
                    .foregroundStyle(Palette.ink)
                    .accessibilityHidden(true)
                Text(MonetizationCopy.waitingForApprovalTitle)
                    .typography(.headline)
                    .foregroundStyle(Palette.ink)
            }
            Text(explanation)
                .typography(.body)
                .foregroundStyle(Palette.ink2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, Spacing.s2)
        .accessibilityElement(children: .combine)
    }
}

/// The user's board at thumbnail size: the screenshot crop, or the diagram when the board was
/// edited or set up by hand.
struct MonetizationBoardThumbnail: View {
    let snapshot: BoardSnapshot

    var body: some View {
        BoardFrame {
            if !snapshot.showsDiagram, let image = snapshot.boardImage {
                BoardScreenshot(image: image, snapshot: snapshot)
            } else {
                DiagramBoard(board: snapshot.position.board, whiteAtBottom: snapshot.whiteAtBottom, showsCoordinates: false)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Your board")
    }
}
