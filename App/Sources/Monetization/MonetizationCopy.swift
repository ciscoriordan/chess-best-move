import Foundation
import StoreKit
import UIKit

/// Copy for the paywall, the downsell and the notices (monetization.md section 6).
///
/// Prices and periods always come from StoreKit (`StoreProduct.displayPrice`, the
/// subscription period); nothing here contains a currency symbol. Purchase screens never use
/// the word "free" (`MonetizationCopyTests` checks every purchase-screen string).
enum MonetizationCopy {
    // MARK: Paywall

    static let boardReady = String(localized: "Your board is ready.")
    /// monetization.md section 6. Purchase screens never say "free", so the line counts the
    /// first analyses instead.
    static func usedAllowance(_ allowance: Int) -> String {
        String(localized: "You've used your first \(allowance) analyses.")
    }

    /// Title Case, the owner's decision of 2026-09-20 for this one line and the three footer
    /// links (monetization.md section 6, design.md 14).
    static let headline = String(localized: "Unlimited Best Moves")
    /// The benefit lines. The app is universal, so the second line names the device it runs on
    /// ("iPhone", "iPad", "Mac").
    static func benefits(deviceName: String) -> [String] {
        [
            String(localized: "Analyze every new screenshot and position, with no limit"),
            String(localized: "Runs on your \(deviceName): works offline, nothing is uploaded"),
            String(localized: "Works on every device signed in to your Apple Account"),
        ]
    }

    /// The name of the device the app runs on, for copy (`AppDevice`).
    @MainActor
    static var currentDeviceName: String {
        AppDevice.current.name
    }

    static let confirming = String(localized: "Confirming...")
    /// The three footer links are Title Case and carry no separators between them (owner
    /// decision, 2026-09-20; design.md 14 records the exception). The same three labels stay
    /// in sentence case in Settings, where they are list rows rather than a purchase footer.
    static let restorePurchases = String(localized: "Restore Purchases")
    static let restoring = String(localized: "Restoring...")
    static let termsOfUse = String(localized: "Terms of Use")
    static let privacyPolicy = String(localized: "Privacy Policy")
    static let purchasesRestored = String(localized: "Purchases restored.")
    static let nothingToRestore = String(localized: "No previous purchases found.")
    static let tryAgain = String(localized: "Try again")

    static let waitingForApprovalTitle = String(localized: "Waiting for approval")
    static let waitingForApprovalWithBoard =
        String(localized: "The person who approves purchases for your Apple Account needs to confirm it. Your board is analyzed as soon as it's approved.")
    static let waitingForApprovalWithoutBoard =
        String(localized: "The person who approves purchases for your Apple Account needs to confirm it. Pro unlocks as soon as it's approved.")

    static let lifetimeUnlocked = String(localized: "Lifetime Is Unlocked")
    static func subscriptionStillActive(_ plan: MonetizationProductKind) -> String {
        switch plan {
        case .yearly: String(localized: "Your yearly subscription is still active")
        default: String(localized: "Your weekly subscription is still active")
        }
    }
    static let subscriptionStillActiveBody =
        String(localized: "Apple doesn't cancel it for you. Cancel it in your subscriptions to stop the renewals.")
    static let manageSubscription = String(localized: "Manage subscription")
    /// Apple's sheet refused to open and the App Store took the reader to their subscriptions
    /// instead. Said, not silent, because the app went to the background: this is the line the
    /// reader finds when they come back, and it names what happened.
    static let manageSubscriptionOpenedInAppStore = String(localized: "Your subscriptions opened in the App Store.")
    /// Apple's sheet refused to open and so did the App Store page, so the words are all that is
    /// left. It names the one route that is always there.
    static let manageSubscriptionUnavailable =
        String(localized: "Apple's subscription settings didn't open. Manage your subscription in the Settings app, under your Apple Account.")

    // MARK: Store messages (also used as `StoreLoadState.failed` and `PurchaseOutcome.failed` text)

    static let loadFailed = String(localized: "Couldn't load purchase options.")
    static let loadFailedOffline = String(localized: "You're offline. Connect to the internet to see purchase options.")
    static let purchaseFailed = String(localized: "The purchase didn't go through. Please try again.")
    static let purchaseFailedOffline = String(localized: "You're offline. Connect to the internet and try again.")
    static let purchaseNotRecorded =
        String(localized: "The payment went through, but the analyses couldn't be added yet. They are added the next time you open the app.")
    static let restoreFailed = String(localized: "Couldn't restore purchases. Please try again.")
    static let restoreFailedOffline = String(localized: "You're offline. Connect to the internet and try again.")

    // MARK: Downsell

    static let downsellTitle = String(localized: "Just Need a Few?")
    static func downsellBody(price: String) -> String {
        String(localized: "\(ProductID.creditsPerPack) analyses for \(price). One-time purchase, not a subscription. They never expire.")
    }
    static func downsellButton(price: String) -> String {
        String(localized: "Buy \(ProductID.creditsPerPack) analyses: \(price)")
    }
    static let downsellWaitingBody =
        String(localized: "The person who approves purchases for your Apple Account needs to confirm it. Your board is analyzed as soon as it's approved.")

    // MARK: Result screen

    static let lastFreeAnalysis = String(localized: "That was your last free analysis.")
    static let seeOptions = String(localized: "See options")
    /// The sentence the last-free-analysis banner carries: the notice and what a tap does. The
    /// whole strip is one control, so the two parts are one string (monetization.md 4.1).
    static var lastFreeAnalysisBanner: String { String(localized: "\(lastFreeAnalysis) \(seeOptions)") }
    /// VoiceOver hint of that banner. It says what double tapping does, because the banner's
    /// own label is the sentence rather than a verb.
    static let seeOptionsHint = String(localized: "Double tap to see the purchase options.")
    static func switchToYearlyTitle(price: String) -> String {
        String(localized: "Switch to yearly: \(price)/year")
    }
    static func switchToYearlyBody(perWeek: String) -> String {
        String(localized: "About \(perWeek) a week. The change starts at your next renewal.")
    }
    static let dismiss = String(localized: "Dismiss")

    // MARK: Products

    static func rowTitle(_ kind: MonetizationProductKind, product: StoreProduct) -> String {
        switch kind {
        case .weekly: String(localized: "Weekly")
        case .yearly: String(localized: "Yearly")
        case .lifetime: String(localized: "Lifetime")
        case .pack: String(localized: "\(ProductID.creditsPerPack) analyses")
        case .other: product.displayName
        }
    }

    /// "$2.99/week", "$24.99/year", "$49.99".
    static func rowPrice(_ product: StoreProduct) -> String {
        guard let period = period(of: product) else { return product.displayPrice }
        return "\(product.displayPrice)/\(period)"
    }

    /// The secondary line of a paywall row.
    static func rowDetail(_ kind: MonetizationProductKind, product: StoreProduct, isCurrentPlan: Bool) -> String {
        if isCurrentPlan { return String(localized: "Your current plan.") }
        switch kind {
        case .yearly:
            if let perWeek = pricePerWeek(product) {
                return String(localized: "Best value, about \(perWeek) a week")
            }
            return String(localized: "Best value")
        case .lifetime, .pack, .other:
            if case .autoRenewable = product.kind {
                return String(localized: "Renews every \(period(of: product) ?? String(localized: "billing period")). Cancel anytime.")
            }
            return String(localized: "One payment. Not a subscription.")
        case .weekly:
            return String(localized: "Renews every \(period(of: product) ?? String(localized: "week")). Cancel anytime.")
        }
    }

    /// "Continue: $2.99 / week", "Continue: $49.99 once".
    static func continueButton(_ product: StoreProduct) -> String {
        guard let period = period(of: product) else { return String(localized: "Continue: \(product.displayPrice) once") }
        return String(localized: "Continue: \(product.displayPrice) / \(period)")
    }

    /// The terms line under the Continue button.
    static func terms(_ product: StoreProduct) -> String {
        guard let period = period(of: product) else { return String(localized: "One-time payment. No renewal.") }
        let multiple: Bool
        if case .autoRenewable(_, let count) = product.kind {
            multiple = count > 1
        } else {
            multiple = false
        }
        let each = multiple ? String(localized: "every \(period)") : String(localized: "each \(period)")
        return String(localized: "Payment is charged to your Apple Account when you confirm. The subscription renews automatically at the same price \(each) unless you cancel at least 24 hours before the current period ends. Manage or cancel in Settings > Apple Account > Subscriptions.")
    }

    /// VoiceOver label of a paywall row: "Weekly, $2.99 per week. Renews every week. Cancel anytime."
    static func rowAccessibilityLabel(title: String, product: StoreProduct, detail: String) -> String {
        if let period = period(of: product) {
            return String(localized: "\(title), \(product.displayPrice) per \(period). \(detail)")
        }
        return String(localized: "\(title), \(product.displayPrice). \(detail)")
    }

    /// "week", "year", "2 weeks"; nil for a product that does not renew.
    static func period(of product: StoreProduct) -> String? {
        guard case .autoRenewable(let unit, let value) = product.kind else { return nil }
        switch unit {
        case .day: return value <= 1 ? String(localized: "day") : String(localized: "\(value) days")
        case .week: return value <= 1 ? String(localized: "week") : String(localized: "\(value) weeks")
        case .month: return value <= 1 ? String(localized: "month") : String(localized: "\(value) months")
        case .year: return value <= 1 ? String(localized: "year") : String(localized: "\(value) years")
        @unknown default: return String(localized: "billing period")
        }
    }

    /// The price per week of a subscription, formatted in the product's currency ("$0.48").
    static func pricePerWeek(_ product: StoreProduct) -> String? {
        guard case .autoRenewable(let unit, let value) = product.kind, value > 0 else { return nil }
        let weeksPerUnit: Decimal
        switch unit {
        case .day: weeksPerUnit = Decimal(1) / Decimal(7)
        case .week: weeksPerUnit = 1
        case .month: weeksPerUnit = Decimal(52) / Decimal(12)
        case .year: weeksPerUnit = 52
        @unknown default: return nil
        }
        let weeks = weeksPerUnit * Decimal(value)
        return (product.price / weeks).formatted(product.priceFormatStyle)
    }
}

/// What the app says after a tap on "Manage subscription", wherever it is offered: Settings'
/// PURCHASES card, the plan screen behind the Plan row, and the primary button of the paywall's
/// "your subscription is still active" screen (design.md 9.7 and 9.8).
///
/// **Why it exists (owner decision of 2026-09-28).** `showManageSubscriptions` used to return
/// `Void` and log its failures, so a tap that could not show Apple's sheet did nothing at all,
/// on a purchase control one screen from the Plan row App Review rejected 1.0.6 over. The sheet
/// throws for an Apple Account with no manageable subscription for this app and in the sandbox,
/// which is the account a reviewer uses. So the failure now has words, and the app also opens
/// the Apple Account's subscriptions in the App Store, which is a route that exists whatever
/// StoreKit says.
///
/// One type for the three screens, so none of them can be the silent one.
struct MonetizationManageSubscriptionFeedback: Equatable, Sendable {
    /// The line to show, or nil when Apple's own sheet is on screen and says everything.
    let message: String?
    /// Drawn and felt as a failure: nothing opened, so the words are all the reader has.
    let isError: Bool

    init(message: String?, isError: Bool) {
        self.message = message
        self.isError = isError
    }

    /// - Parameters:
    ///   - outcome: what `StoreService.showManageSubscriptions()` answered.
    ///   - openedAccountPage: whether the system accepted
    ///     `MonetizationAppleLinks.accountSubscriptions` afterwards. Ignored for `.shown`,
    ///     because the page is only tried when the sheet refused.
    init(outcome: ManageSubscriptionsOutcome, openedAccountPage: Bool) {
        switch outcome {
        case .shown:
            self.init(message: nil, isError: false)
        case .unavailable:
            self.init(
                message: openedAccountPage
                    ? MonetizationCopy.manageSubscriptionOpenedInAppStore
                    : MonetizationCopy.manageSubscriptionUnavailable,
                isError: !openedAccountPage
            )
        }
    }
}
