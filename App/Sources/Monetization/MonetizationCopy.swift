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

    static let boardReady = "Your board is ready."
    /// monetization.md section 6. Purchase screens never say "free", so the line counts the
    /// first analyses instead.
    static func usedAllowance(_ allowance: Int) -> String {
        "You've used your first \(allowance) analyses."
    }

    /// Title Case, the owner's decision of 2026-09-20 for this one line and the three footer
    /// links (monetization.md section 6, design.md 14).
    static let headline = "Unlimited Best Moves"
    /// The benefit lines. The app is universal, so the second line names the device it runs on
    /// ("iPhone", "iPad", "Mac").
    static func benefits(deviceName: String) -> [String] {
        [
            "Analyze every new screenshot and position, with no limit",
            "Runs on your \(deviceName): works offline, nothing is uploaded",
            "Works on every device signed in to your Apple Account",
        ]
    }

    /// The name of the device the app runs on, for copy (`AppDevice`).
    @MainActor
    static var currentDeviceName: String {
        AppDevice.current.name
    }

    static let confirming = "Confirming..."
    /// The three footer links are Title Case and carry no separators between them (owner
    /// decision, 2026-09-20; design.md 14 records the exception). The same three labels stay
    /// in sentence case in Settings, where they are list rows rather than a purchase footer.
    static let restorePurchases = "Restore Purchases"
    static let restoring = "Restoring..."
    static let termsOfUse = "Terms of Use"
    static let privacyPolicy = "Privacy Policy"
    static let purchasesRestored = "Purchases restored."
    static let nothingToRestore = "No previous purchases found."
    static let tryAgain = "Try again"

    static let waitingForApprovalTitle = "Waiting for approval"
    static let waitingForApprovalWithBoard =
        "The person who approves purchases for your Apple Account needs to confirm it. Your board is analyzed as soon as it's approved."
    static let waitingForApprovalWithoutBoard =
        "The person who approves purchases for your Apple Account needs to confirm it. Pro unlocks as soon as it's approved."

    static let lifetimeUnlocked = "Lifetime is unlocked"
    static func subscriptionStillActive(_ plan: MonetizationProductKind) -> String {
        switch plan {
        case .yearly: "Your yearly subscription is still active"
        default: "Your weekly subscription is still active"
        }
    }
    static let subscriptionStillActiveBody =
        "Apple doesn't cancel it for you. Cancel it in your subscriptions to stop the renewals."
    static let manageSubscription = "Manage subscription"

    // MARK: Store messages (also used as `StoreLoadState.failed` and `PurchaseOutcome.failed` text)

    static let loadFailed = "Couldn't load purchase options."
    static let loadFailedOffline = "You're offline. Connect to the internet to see purchase options."
    static let purchaseFailed = "The purchase didn't go through. Please try again."
    static let purchaseFailedOffline = "You're offline. Connect to the internet and try again."
    static let purchaseNotRecorded =
        "The payment went through, but the analyses couldn't be added yet. They are added the next time you open the app."
    static let restoreFailed = "Couldn't restore purchases. Please try again."
    static let restoreFailedOffline = "You're offline. Connect to the internet and try again."

    // MARK: Downsell

    static let downsellTitle = "Just need a few?"
    static func downsellBody(price: String) -> String {
        "\(ProductID.creditsPerPack) analyses for \(price). One-time purchase, not a subscription. They never expire."
    }
    static func downsellButton(price: String) -> String {
        "Buy \(ProductID.creditsPerPack) analyses: \(price)"
    }
    static let downsellWaitingBody =
        "The person who approves purchases for your Apple Account needs to confirm it. Your board is analyzed as soon as it's approved."

    // MARK: Result screen

    static let lastFreeAnalysis = "That was your last free analysis."
    static let seeOptions = "See options"
    /// The sentence the last-free-analysis banner carries: the notice and what a tap does. The
    /// whole strip is one control, so the two parts are one string (monetization.md 4.1).
    static var lastFreeAnalysisBanner: String { "\(lastFreeAnalysis) \(seeOptions)" }
    /// VoiceOver hint of that banner. It says what double tapping does, because the banner's
    /// own label is the sentence rather than a verb.
    static let seeOptionsHint = "Double tap to see the purchase options."
    static func switchToYearlyTitle(price: String) -> String {
        "Switch to yearly: \(price)/year"
    }
    static func switchToYearlyBody(perWeek: String) -> String {
        "About \(perWeek) a week. The change starts at your next renewal."
    }
    static let dismiss = "Dismiss"

    // MARK: Products

    static func rowTitle(_ kind: MonetizationProductKind, product: StoreProduct) -> String {
        switch kind {
        case .weekly: "Weekly"
        case .yearly: "Yearly"
        case .lifetime: "Lifetime"
        case .pack, .other: product.displayName
        }
    }

    /// "$5.99/week", "$39.99/year", "$59.99".
    static func rowPrice(_ product: StoreProduct) -> String {
        guard let period = period(of: product) else { return product.displayPrice }
        return "\(product.displayPrice)/\(period)"
    }

    /// The secondary line of a paywall row.
    static func rowDetail(_ kind: MonetizationProductKind, product: StoreProduct, isCurrentPlan: Bool) -> String {
        if isCurrentPlan { return "Your current plan." }
        switch kind {
        case .yearly:
            if let perWeek = pricePerWeek(product) {
                return "Best value, about \(perWeek) a week"
            }
            return "Best value"
        case .lifetime, .pack, .other:
            if case .autoRenewable = product.kind {
                return "Renews every \(period(of: product) ?? "period"). Cancel anytime."
            }
            return "One payment. Not a subscription."
        case .weekly:
            return "Renews every \(period(of: product) ?? "week"). Cancel anytime."
        }
    }

    /// "Continue: $5.99 / week", "Continue: $59.99 once".
    static func continueButton(_ product: StoreProduct) -> String {
        guard let period = period(of: product) else { return "Continue: \(product.displayPrice) once" }
        return "Continue: \(product.displayPrice) / \(period)"
    }

    /// The terms line under the Continue button.
    static func terms(_ product: StoreProduct) -> String {
        guard let period = period(of: product) else { return "One-time payment. No renewal." }
        let each = period.contains(" ") ? "every \(period)" : "each \(period)"
        return "Payment is charged to your Apple Account when you confirm. The subscription renews automatically at the same price \(each) unless you cancel at least 24 hours before the current period ends. Manage or cancel in Settings > Apple Account > Subscriptions."
    }

    /// VoiceOver label of a paywall row: "Weekly, $5.99 per week. Renews every week. Cancel anytime."
    static func rowAccessibilityLabel(title: String, product: StoreProduct, detail: String) -> String {
        if let period = period(of: product) {
            return "\(title), \(product.displayPrice) per \(period). \(detail)"
        }
        return "\(title), \(product.displayPrice). \(detail)"
    }

    /// "week", "year", "2 weeks"; nil for a product that does not renew.
    static func period(of product: StoreProduct) -> String? {
        guard case .autoRenewable(let unit, let value) = product.kind else { return nil }
        let name: String
        switch unit {
        case .day: name = "day"
        case .week: name = "week"
        case .month: name = "month"
        case .year: name = "year"
        @unknown default: name = "period"
        }
        return value <= 1 ? name : "\(value) \(name)s"
    }

    /// The price per week of a subscription, formatted in the product's currency ("$0.77").
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
