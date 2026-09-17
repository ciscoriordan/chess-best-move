import Foundation
import StoreKit
import UIKit

// The boundary between the store service and StoreKit. `MonetizationStoreService` holds all
// purchase and entitlement logic and talks to StoreKit only through
// `MonetizationStoreKitClient`, so that logic runs in unit tests with a scripted client.

/// The parts of a verified `StoreKit.Transaction` the store logic needs.
struct MonetizationTransactionFacts: Sendable, Hashable {
    enum Kind: Sendable, Hashable {
        case autoRenewable
        case nonConsumable
        case consumable
        case nonRenewing
    }

    var id: UInt64
    var originalID: UInt64
    var productID: String
    var kind: Kind
    var subscriptionGroupID: String?
    var purchaseDate: Date
    var expirationDate: Date?
    var revocationDate: Date?
    /// A newer transaction in the same group replaced this one (an upgrade).
    var isUpgraded: Bool

    init(
        id: UInt64,
        originalID: UInt64? = nil,
        productID: String,
        kind: Kind,
        subscriptionGroupID: String? = nil,
        purchaseDate: Date = Date(),
        expirationDate: Date? = nil,
        revocationDate: Date? = nil,
        isUpgraded: Bool = false
    ) {
        self.id = id
        self.originalID = originalID ?? id
        self.productID = productID
        self.kind = kind
        self.subscriptionGroupID = subscriptionGroupID
        self.purchaseDate = purchaseDate
        self.expirationDate = expirationDate
        self.revocationDate = revocationDate
        self.isUpgraded = isUpgraded
    }
}

/// The renewal state of the active subscription in a group, from
/// `Product.SubscriptionInfo.status(for:)`.
struct MonetizationRenewalFacts: Sendable, Hashable {
    /// The product the subscription renews into (`RenewalInfo.autoRenewPreference`).
    var autoRenewProductID: String?
    /// When the billing grace period ends, while the subscription is in one (state
    /// `.inGracePeriod`, `RenewalInfo.gracePeriodExpirationDate`). StoreKit keeps the subscription
    /// in `Transaction.currentEntitlements` until then, although its expiration date has passed.
    var gracePeriodExpirationDate: Date?

    init(autoRenewProductID: String? = nil, gracePeriodExpirationDate: Date? = nil) {
        self.autoRenewProductID = autoRenewProductID
        self.gracePeriodExpirationDate = gracePeriodExpirationDate
    }
}

/// A loaded product plus the subscription group it belongs to.
struct MonetizationLoadedProduct: Sendable, Hashable {
    var product: StoreProduct
    var subscriptionGroupID: String?
}

enum MonetizationPurchaseResult: Sendable, Hashable {
    case verified(MonetizationTransactionFacts)
    /// StoreKit could not verify the transaction's signature. Nothing is granted.
    case unverified
    /// Ask to Buy or parental consent; the decision arrives through `transactionUpdates`.
    case pending
    case userCancelled
}

/// StoreKit as the store service uses it. Every transaction handed out through
/// `purchase`, `unfinishedTransactions` or `transactionUpdates` must be passed to `finish`
/// once it has been granted.
@MainActor
protocol MonetizationStoreKitClient: AnyObject {
    func loadProducts(_ identifiers: [String]) async throws -> [MonetizationLoadedProduct]
    func purchase(_ productID: String) async throws -> MonetizationPurchaseResult
    /// `Transaction.currentEntitlements`, verified only.
    func currentEntitlements() async -> [MonetizationTransactionFacts]
    /// `Transaction.all`, verified only.
    func allTransactions() async -> [MonetizationTransactionFacts]
    /// `Transaction.unfinished`, verified only.
    func unfinishedTransactions() async -> [MonetizationTransactionFacts]
    /// `Transaction.updates`, verified only. Called once.
    func transactionUpdates() -> AsyncStream<MonetizationTransactionFacts>
    func finish(_ transaction: MonetizationTransactionFacts) async
    /// `AppStore.sync()`.
    func sync() async throws
    /// The renewal state of the active subscription in `subscriptionGroupID`, or nil when there
    /// is none or it could not be read. May need the network.
    func renewalStatus(subscriptionGroupID: String) async -> MonetizationRenewalFacts?
    func showManageSubscriptions() async
}

enum MonetizationStoreKitFailure: Error, Sendable {
    case productUnavailable
}

extension Error {
    /// True for errors that mean "no connection", so the UI can say so.
    var monetizationIsOffline: Bool {
        if let storeKitError = self as? StoreKitError, case .networkError(let urlError) = storeKitError {
            return Self.offlineCodes.contains(urlError.code)
        }
        if let urlError = self as? URLError {
            return Self.offlineCodes.contains(urlError.code)
        }
        return false
    }

    /// True when the user dismissed a StoreKit sheet (for example the sign-in for Restore).
    var monetizationIsUserCancellation: Bool {
        if let storeKitError = self as? StoreKitError, case .userCancelled = storeKitError { return true }
        return false
    }

    private static var offlineCodes: Set<URLError.Code> {
        [.notConnectedToInternet, .networkConnectionLost, .dataNotAllowed, .internationalRoamingOff, .timedOut, .cannotFindHost, .cannotConnectToHost]
    }
}

// MARK: - Live StoreKit 2

@MainActor
final class MonetizationLiveStoreKitClient: MonetizationStoreKitClient {
    private var productsByID: [String: Product] = [:]
    /// Transactions handed out and not finished yet, by transaction id.
    private var unfinished: [UInt64: StoreKit.Transaction] = [:]

    init() {}

    func loadProducts(_ identifiers: [String]) async throws -> [MonetizationLoadedProduct] {
        let products = try await Product.products(for: identifiers)
        for product in products {
            productsByID[product.id] = product
        }
        return products.map { product in
            MonetizationLoadedProduct(
                product: Self.storeProduct(product),
                subscriptionGroupID: product.subscription?.subscriptionGroupID
            )
        }
    }

    func purchase(_ productID: String) async throws -> MonetizationPurchaseResult {
        if productsByID[productID] == nil {
            _ = try await loadProducts([productID])
        }
        guard let product = productsByID[productID] else { throw MonetizationStoreKitFailure.productUnavailable }
        let result: Product.PurchaseResult
        if let scene = Self.activeWindowScene {
            result = try await product.purchase(confirmIn: scene)
        } else {
            result = try await product.purchase()
        }
        switch result {
        case .success(.verified(let transaction)):
            unfinished[transaction.id] = transaction
            return .verified(Self.facts(transaction))
        case .success(.unverified(let transaction, let error)):
            MonetizationLog.store.error("unverified purchase of \(transaction.productID, privacy: .public): \(String(describing: error), privacy: .public)")
            return .unverified
        case .pending:
            return .pending
        case .userCancelled:
            return .userCancelled
        @unknown default:
            return .userCancelled
        }
    }

    func currentEntitlements() async -> [MonetizationTransactionFacts] {
        var result: [MonetizationTransactionFacts] = []
        for await verification in StoreKit.Transaction.currentEntitlements {
            if case .verified(let transaction) = verification {
                result.append(Self.facts(transaction))
            }
        }
        return result
    }

    func allTransactions() async -> [MonetizationTransactionFacts] {
        var result: [MonetizationTransactionFacts] = []
        for await verification in StoreKit.Transaction.all {
            if case .verified(let transaction) = verification {
                result.append(Self.facts(transaction))
            }
        }
        return result
    }

    func unfinishedTransactions() async -> [MonetizationTransactionFacts] {
        var result: [MonetizationTransactionFacts] = []
        for await verification in StoreKit.Transaction.unfinished {
            if case .verified(let transaction) = verification {
                unfinished[transaction.id] = transaction
                result.append(Self.facts(transaction))
            }
        }
        return result
    }

    func transactionUpdates() -> AsyncStream<MonetizationTransactionFacts> {
        AsyncStream { continuation in
            let task = Task { @MainActor [weak self] in
                for await verification in StoreKit.Transaction.updates {
                    guard case .verified(let transaction) = verification else {
                        MonetizationLog.store.error("ignored an unverified transaction update")
                        continue
                    }
                    self?.unfinished[transaction.id] = transaction
                    continuation.yield(Self.facts(transaction))
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    func finish(_ transaction: MonetizationTransactionFacts) async {
        guard let storeKitTransaction = unfinished.removeValue(forKey: transaction.id) else { return }
        await storeKitTransaction.finish()
    }

    func sync() async throws {
        try await AppStore.sync()
    }

    func renewalStatus(subscriptionGroupID: String) async -> MonetizationRenewalFacts? {
        guard let statuses = try? await Product.SubscriptionInfo.status(for: subscriptionGroupID) else { return nil }
        for status in statuses where status.state == .subscribed || status.state == .inGracePeriod || status.state == .inBillingRetryPeriod {
            if case .verified(let renewalInfo) = status.renewalInfo {
                return MonetizationRenewalFacts(
                    autoRenewProductID: renewalInfo.autoRenewPreference,
                    gracePeriodExpirationDate: status.state == .inGracePeriod ? renewalInfo.gracePeriodExpirationDate : nil
                )
            }
        }
        return nil
    }

    func showManageSubscriptions() async {
        guard let scene = Self.activeWindowScene else { return }
        do {
            try await AppStore.showManageSubscriptions(in: scene)
        } catch {
            MonetizationLog.store.error("showManageSubscriptions failed: \(String(describing: error), privacy: .public)")
        }
    }

    // MARK: Mapping

    private static var activeWindowScene: UIWindowScene? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        return scenes.first { $0.activationState == .foregroundActive } ?? scenes.first
    }

    private static func facts(_ transaction: StoreKit.Transaction) -> MonetizationTransactionFacts {
        let kind: MonetizationTransactionFacts.Kind
        switch transaction.productType {
        case .autoRenewable: kind = .autoRenewable
        case .nonConsumable: kind = .nonConsumable
        case .consumable: kind = .consumable
        default: kind = .nonRenewing
        }
        return MonetizationTransactionFacts(
            id: transaction.id,
            originalID: transaction.originalID,
            productID: transaction.productID,
            kind: kind,
            subscriptionGroupID: transaction.subscriptionGroupID,
            purchaseDate: transaction.purchaseDate,
            expirationDate: transaction.expirationDate,
            revocationDate: transaction.revocationDate,
            isUpgraded: transaction.isUpgraded
        )
    }

    private static func storeProduct(_ product: Product) -> StoreProduct {
        let kind: StoreProduct.Kind
        if let period = product.subscription?.subscriptionPeriod {
            kind = .autoRenewable(period: period.unit, value: period.value)
        } else if product.type == .nonConsumable {
            kind = .nonConsumable
        } else {
            kind = .consumable
        }
        return StoreProduct(
            id: product.id,
            displayName: product.displayName,
            description: product.description,
            displayPrice: product.displayPrice,
            price: product.price,
            priceFormatStyle: product.priceFormatStyle,
            kind: kind
        )
    }
}
