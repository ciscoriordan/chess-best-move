#if DEBUG
import Foundation
import StoreKit

/// DEBUG builds only: a StoreKit stand-in that behaves like the App Store for the store
/// logic (transactions, entitlements, Ask to Buy, refunds, expiry, billing grace periods,
/// crossgrades). Finished consumables stay in the history, as they do in the App Store with
/// `SKIncludeConsumableInAppPurchaseHistory`. Unit tests script it; the `-monetizationDemo`
/// launch argument uses it so the paywall can be seen with products in a simulator that has
/// no StoreKit configuration (`xcrun simctl launch`).
@MainActor
final class MonetizationScriptedStoreKitClient: MonetizationStoreKitClient {
    enum PurchaseBehavior: Equatable {
        case succeed
        case pending
        case cancel
        case failOffline
        case unverified
    }

    static let groupID = "scripted.pro.group"

    var availableProducts: [MonetizationLoadedProduct]
    var loadFailsOffline = false
    var purchaseBehavior: PurchaseBehavior = .succeed
    var syncFails = false
    /// `autoRenewPreference` by subscription group. A crossgrade purchase sets it.
    var autoRenewProductIDs: [String: String] = [:]
    /// The end of a billing grace period by subscription group: the group's expired subscription
    /// stays in `currentEntitlements` until then, and `renewalStatus` reports the end.
    var gracePeriodEnds: [String: Date] = [:]
    /// Makes `renewalStatus` return nil, as when the status cannot be read.
    var renewalStatusFails = false
    var now = Date()
    /// How long `purchase` takes before it returns (StoreKit's sheet and the network).
    var purchaseDelay: Duration = .zero
    /// How long the entitlement and history reads take. Each read takes its snapshot first, so
    /// a slow read returns what was true when it started, as a real read would.
    var currentEntitlementsDelay: Duration = .zero
    var allTransactionsDelay: Duration = .zero
    var renewalStatusDelay: Duration = .zero
    /// Products `loadProducts` leaves out, as App Store Connect does for a product that is not
    /// cleared for sale.
    var unservedProductIDs: Set<String> = []

    private(set) var transactions: [MonetizationTransactionFacts] = []
    private(set) var finishedTransactionIDs: Set<UInt64> = []
    private(set) var pendingProductIDs: [String] = []
    private(set) var loadCount = 0
    private(set) var syncCount = 0
    private(set) var manageSubscriptionsCount = 0
    private var nextTransactionID: UInt64 = 1_000
    private var updatesContinuation: AsyncStream<MonetizationTransactionFacts>.Continuation?

    init(products: [MonetizationLoadedProduct] = MonetizationScriptedStoreKitClient.sampleProducts()) {
        availableProducts = products
    }

    // MARK: Scripting

    /// Ask to Buy approved: the transaction arrives through `Transaction.updates`.
    @discardableResult
    func approvePendingPurchase(_ productID: String) -> MonetizationTransactionFacts? {
        guard let index = pendingProductIDs.firstIndex(of: productID) else { return nil }
        pendingProductIDs.remove(at: index)
        let transaction = makeTransaction(productID)
        updatesContinuation?.yield(transaction)
        return transaction
    }

    /// Ask to Buy declined: nothing is delivered, as with the App Store.
    func declinePendingPurchase(_ productID: String) {
        pendingProductIDs.removeAll { $0 == productID }
    }

    /// A purchase made outside the app, a renewal, or an approval, delivered through updates.
    @discardableResult
    func deliverTransaction(_ productID: String, purchaseDate: Date? = nil) -> MonetizationTransactionFacts {
        let transaction = makeTransaction(productID, purchaseDate: purchaseDate)
        updatesContinuation?.yield(transaction)
        return transaction
    }

    /// A transaction recorded before the app started (for example on another device).
    @discardableResult
    func addHistoricalTransaction(_ productID: String, purchaseDate: Date, finished: Bool = true) -> MonetizationTransactionFacts {
        let transaction = makeTransaction(productID, purchaseDate: purchaseDate)
        if finished { finishedTransactionIDs.insert(transaction.id) }
        return transaction
    }

    /// Refund: the revoked transaction arrives through updates.
    func refund(transactionID: UInt64) {
        guard let index = transactions.firstIndex(where: { $0.id == transactionID }) else { return }
        transactions[index].revocationDate = now
        finishedTransactionIDs.remove(transactionID)
        updatesContinuation?.yield(transactions[index])
    }

    /// Ends every subscription: expiry produces no transaction, only fewer entitlements.
    func expireSubscriptions() {
        for index in transactions.indices where transactions[index].kind == .autoRenewable {
            transactions[index].expirationDate = now.addingTimeInterval(-1)
        }
    }

    // MARK: MonetizationStoreKitClient

    func loadProducts(_ identifiers: [String]) async throws -> [MonetizationLoadedProduct] {
        loadCount += 1
        if loadFailsOffline { throw URLError(.notConnectedToInternet) }
        return availableProducts.filter { identifiers.contains($0.product.id) && !unservedProductIDs.contains($0.product.id) }
    }

    func purchase(_ productID: String) async throws -> MonetizationPurchaseResult {
        guard availableProducts.contains(where: { $0.product.id == productID }) else {
            throw MonetizationStoreKitFailure.productUnavailable
        }
        if purchaseDelay > .zero { try? await Task.sleep(for: purchaseDelay) }
        switch purchaseBehavior {
        case .succeed:
            if let current = activeSubscription(sameGroupAs: productID), current.productID != productID {
                // A crossgrade: like the App Store, the current subscription's transaction comes
                // back, and the bought product starts at the next renewal.
                if let group = current.subscriptionGroupID { autoRenewProductIDs[group] = productID }
                return .verified(current)
            }
            return .verified(makeTransaction(productID))
        case .pending:
            pendingProductIDs.append(productID)
            return .pending
        case .cancel:
            return .userCancelled
        case .failOffline:
            throw URLError(.notConnectedToInternet)
        case .unverified:
            return .unverified
        }
    }

    func currentEntitlements() async -> [MonetizationTransactionFacts] {
        var latestSubscriptionByGroup: [String: MonetizationTransactionFacts] = [:]
        var result: [MonetizationTransactionFacts] = []
        for transaction in transactions where transaction.revocationDate == nil {
            switch transaction.kind {
            case .autoRenewable:
                let group = transaction.subscriptionGroupID ?? ""
                guard (transaction.expirationDate ?? .distantFuture) > now || (gracePeriodEnds[group] ?? .distantPast) > now else { continue }
                if let current = latestSubscriptionByGroup[group], current.purchaseDate > transaction.purchaseDate { continue }
                latestSubscriptionByGroup[group] = transaction
            case .nonConsumable:
                result.append(transaction)
            case .consumable, .nonRenewing:
                break
            }
        }
        let snapshot = result + latestSubscriptionByGroup.values.sorted { $0.id < $1.id }
        if currentEntitlementsDelay > .zero { try? await Task.sleep(for: currentEntitlementsDelay) }
        return snapshot
    }

    func allTransactions() async -> [MonetizationTransactionFacts] {
        let snapshot = transactions
        if allTransactionsDelay > .zero { try? await Task.sleep(for: allTransactionsDelay) }
        return snapshot
    }

    func unfinishedTransactions() async -> [MonetizationTransactionFacts] {
        transactions.filter { !finishedTransactionIDs.contains($0.id) }
    }

    func transactionUpdates() -> AsyncStream<MonetizationTransactionFacts> {
        AsyncStream { continuation in
            updatesContinuation = continuation
        }
    }

    func finish(_ transaction: MonetizationTransactionFacts) async {
        finishedTransactionIDs.insert(transaction.id)
    }

    func sync() async throws {
        syncCount += 1
        if syncFails { throw URLError(.notConnectedToInternet) }
    }

    func renewalStatus(subscriptionGroupID: String) async -> MonetizationRenewalFacts? {
        var snapshot: MonetizationRenewalFacts?
        if !renewalStatusFails {
            let latest = transactions
                .filter { $0.kind == .autoRenewable && $0.subscriptionGroupID == subscriptionGroupID && $0.revocationDate == nil }
                .max { $0.purchaseDate < $1.purchaseDate }
            var graceEnd: Date?
            if let latest, (latest.expirationDate ?? .distantFuture) <= now,
               let end = gracePeriodEnds[subscriptionGroupID], end > now {
                graceEnd = end
            }
            snapshot = MonetizationRenewalFacts(
                autoRenewProductID: autoRenewProductIDs[subscriptionGroupID],
                gracePeriodExpirationDate: graceEnd
            )
        }
        if renewalStatusDelay > .zero { try? await Task.sleep(for: renewalStatusDelay) }
        return snapshot
    }

    func showManageSubscriptions() async {
        manageSubscriptionsCount += 1
    }

    // MARK: Helpers

    /// The subscription that is active now in the group of `productID`, if that product is a
    /// subscription.
    private func activeSubscription(sameGroupAs productID: String) -> MonetizationTransactionFacts? {
        guard let group = availableProducts.first(where: { $0.product.id == productID })?.subscriptionGroupID else { return nil }
        return transactions
            .filter { $0.kind == .autoRenewable && $0.subscriptionGroupID == group && $0.revocationDate == nil && ($0.expirationDate ?? .distantFuture) > now }
            .max { $0.purchaseDate < $1.purchaseDate }
    }

    private func makeTransaction(_ productID: String, purchaseDate: Date? = nil) -> MonetizationTransactionFacts {
        nextTransactionID += 1
        let loaded = availableProducts.first { $0.product.id == productID }
        let kind: MonetizationTransactionFacts.Kind
        var expiration: Date?
        let date = purchaseDate ?? now
        switch loaded?.product.kind {
        case .autoRenewable(let unit, let value):
            kind = .autoRenewable
            let days: Double
            switch unit {
            case .day: days = 1
            case .week: days = 7
            case .month: days = 30
            case .year: days = 365
            @unknown default: days = 7
            }
            expiration = date.addingTimeInterval(days * Double(value) * 24 * 60 * 60)
        case .nonConsumable:
            kind = .nonConsumable
        case .consumable, .none:
            kind = .consumable
        }
        let transaction = MonetizationTransactionFacts(
            id: nextTransactionID,
            productID: productID,
            kind: kind,
            subscriptionGroupID: kind == .autoRenewable ? loaded?.subscriptionGroupID : nil,
            purchaseDate: date,
            expirationDate: expiration
        )
        transactions.append(transaction)
        return transaction
    }

    /// The four products of monetization.md section 2 at US prices.
    static func sampleProducts(groupID: String = MonetizationScriptedStoreKitClient.groupID) -> [MonetizationLoadedProduct] {
        let currency = Decimal.FormatStyle.Currency(code: "USD", locale: Locale(identifier: "en_US"))
        func product(_ id: String, _ name: String, _ description: String, _ price: String, _ kind: StoreProduct.Kind) -> MonetizationLoadedProduct {
            let decimal = Decimal(string: price)!
            let isSubscription: Bool
            if case .autoRenewable = kind { isSubscription = true } else { isSubscription = false }
            return MonetizationLoadedProduct(
                product: StoreProduct(
                    id: id,
                    displayName: name,
                    description: description,
                    displayPrice: decimal.formatted(currency),
                    price: decimal,
                    priceFormatStyle: currency,
                    kind: kind
                ),
                subscriptionGroupID: isSubscription ? groupID : nil
            )
        }
        return [
            product(ProductID.proWeekly, "Pro Weekly", "Unlimited analyses, billed weekly", "5.99", .autoRenewable(period: .week, value: 1)),
            product(ProductID.proAnnual, "Pro Yearly", "Unlimited analyses, billed yearly", "39.99", .autoRenewable(period: .year, value: 1)),
            product(ProductID.proLifetime, "Pro Lifetime", "Unlimited analyses, one payment", "59.99", .nonConsumable),
            product(ProductID.credits15, "15 Analyses", "15 analyses that never expire", "2.99", .consumable),
        ]
    }
}

/// DEBUG launch arguments for the monetization screens:
/// - `-monetizationDemo <free analyses left>` uses `MonetizationScriptedStoreKitClient` and an
///   in-memory vault with that many free analyses (0 to 3).
/// - `-monetizationDemoPurchase succeed|pending|cancel|offline` sets what a purchase does.
/// - `-monetizationDemoSubscribed weekly|yearly` starts with an active subscription.
/// - `-monetizationDemoLoad offline` makes loading products fail as if offline;
///   `-monetizationDemoLoad noPack` loads every product except the 15-pack.
/// - `-monetizationDemoPurchaseDelay <seconds>` makes a purchase take that long to return.
enum MonetizationDebugOptions {
    static var demoFreeRemaining: Int? {
        guard UserDefaults.standard.object(forKey: "monetizationDemo") != nil else { return nil }
        return min(max(UserDefaults.standard.integer(forKey: "monetizationDemo"), 0), MonetizationRules.freeAllowance)
    }

    @MainActor
    static func makeDemoClient() -> MonetizationScriptedStoreKitClient {
        let defaults = UserDefaults.standard
        let client = MonetizationScriptedStoreKitClient()
        switch defaults.string(forKey: "monetizationDemoPurchase") {
        case "pending": client.purchaseBehavior = .pending
        case "cancel": client.purchaseBehavior = .cancel
        case "offline": client.purchaseBehavior = .failOffline
        default: client.purchaseBehavior = .succeed
        }
        switch defaults.string(forKey: "monetizationDemoLoad") {
        case "offline": client.loadFailsOffline = true
        case "noPack": client.unservedProductIDs = [ProductID.credits15]
        default: break
        }
        let purchaseDelay = defaults.double(forKey: "monetizationDemoPurchaseDelay")
        if purchaseDelay > 0 {
            client.purchaseDelay = .milliseconds(Int(purchaseDelay * 1000))
        }
        switch defaults.string(forKey: "monetizationDemoSubscribed") {
        case "weekly": client.addHistoricalTransaction(ProductID.proWeekly, purchaseDate: Date().addingTimeInterval(-3600))
        case "yearly": client.addHistoricalTransaction(ProductID.proAnnual, purchaseDate: Date().addingTimeInterval(-3600))
        default: break
        }
        return client
    }

    static func makeDemoVault(freeRemaining: Int) -> MonetizationInMemoryVault {
        let vault = MonetizationInMemoryVault()
        var record = MonetizationLocalRecord.newInstall
        record.freeRemaining = freeRemaining
        if let data = try? JSONEncoder().encode(record) {
            try? vault.setData(data, for: .local)
        }
        return vault
    }

    /// The demo defaults domain, so the demo never touches the real one.
    static var demoDefaults: UserDefaults {
        UserDefaults(suiteName: "com.motomatic.chessbestmove.monetization-demo") ?? .standard
    }
}
#endif
