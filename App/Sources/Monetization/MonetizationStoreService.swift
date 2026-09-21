import Foundation
import Observation
import StoreKit
import UIKit

/// What a product id is, by prefix, so experiment products such as
/// `com.motomatic.chessbestmove.pro.weekly.p799` (monetization.md section 8) are recognized.
enum MonetizationProductKind: Sendable, Hashable {
    case weekly
    case yearly
    case lifetime
    case pack
    case other

    init(productID: String) {
        if productID.hasPrefix(ProductID.proWeekly) {
            self = .weekly
        } else if productID.hasPrefix(ProductID.proAnnual) {
            self = .yearly
        } else if productID.hasPrefix(ProductID.proLifetime) {
            self = .lifetime
        } else if productID.hasPrefix(ProductID.credits15) {
            self = .pack
        } else {
            self = .other
        }
    }
}

/// Entitlement rules (monetization.md sections 2, 3 and 4.9), free of StoreKit types.
enum MonetizationEntitlementRules {
    struct Summary: Sendable, Hashable {
        var isPro = false
        var activeSubscriptionProductID: String?
        var activeSubscriptionGroupID: String?
        var activeSubscriptionExpiration: Date?
        var ownsLifetime = false
        /// Verified, non-revoked pack transactions in the history.
        var verifiedPackTransactionIDs: Set<UInt64> = []
        /// Revoked pack transactions in the history.
        var revokedPackTransactionIDs: Set<UInt64> = []
        /// Paid weeks of the weekly plan, over the whole history.
        var paidWeeklyTransactions = 0
    }

    /// Pro is any active transaction in the Pro subscription group, or a verified lifetime
    /// purchase. `proGroupID` is learned from the loaded subscription products; while it is
    /// unknown (never loaded, offline), any subscription counts, because the app has exactly
    /// one subscription group.
    static func grantsPro(_ transaction: MonetizationTransactionFacts, proGroupID: String?) -> Bool {
        guard transaction.revocationDate == nil else { return false }
        switch transaction.kind {
        case .autoRenewable:
            guard !transaction.isUpgraded else { return false }
            guard let proGroupID else { return true }
            return transaction.subscriptionGroupID == proGroupID
        case .nonConsumable:
            return MonetizationProductKind(productID: transaction.productID) == .lifetime
        case .consumable, .nonRenewing:
            return false
        }
    }

    /// Whether `transaction` on its own proves Pro right now: `grantsPro`, and for a subscription
    /// an expiration date still in the future. Used when a verified transaction arrives before
    /// `Transaction.currentEntitlements` lists it; an old renewal delivered late (for example
    /// an unfinished one from before the plan lapsed) proves nothing.
    static func provesProNow(_ transaction: MonetizationTransactionFacts, proGroupID: String?, now: Date) -> Bool {
        guard grantsPro(transaction, proGroupID: proGroupID) else { return false }
        if transaction.kind == .autoRenewable {
            return (transaction.expirationDate ?? .distantFuture) > now
        }
        return true
    }

    /// `entitlements` come from `Transaction.currentEntitlements` (which already leaves out
    /// expired subscriptions), `history` from `Transaction.all`.
    static func summarize(
        entitlements: [MonetizationTransactionFacts],
        history: [MonetizationTransactionFacts],
        proGroupID: String?
    ) -> Summary {
        var summary = Summary()
        for transaction in entitlements where grantsPro(transaction, proGroupID: proGroupID) {
            summary.isPro = true
            switch transaction.kind {
            case .autoRenewable:
                if summary.activeSubscriptionExpiration == nil
                    || (transaction.expirationDate ?? .distantFuture) > (summary.activeSubscriptionExpiration ?? .distantPast) {
                    summary.activeSubscriptionProductID = transaction.productID
                    summary.activeSubscriptionGroupID = transaction.subscriptionGroupID
                    summary.activeSubscriptionExpiration = transaction.expirationDate ?? .distantFuture
                }
            case .nonConsumable:
                summary.ownsLifetime = true
            case .consumable, .nonRenewing:
                break
            }
        }
        if summary.activeSubscriptionExpiration == .distantFuture {
            summary.activeSubscriptionExpiration = nil
        }
        for transaction in history {
            switch MonetizationProductKind(productID: transaction.productID) {
            case .pack where transaction.kind == .consumable:
                if transaction.revocationDate == nil {
                    summary.verifiedPackTransactionIDs.insert(transaction.id)
                } else {
                    summary.revokedPackTransactionIDs.insert(transaction.id)
                }
            case .weekly where transaction.kind == .autoRenewable && transaction.revocationDate == nil:
                summary.paidWeeklyTransactions += 1
            default:
                break
            }
        }
        return summary
    }

    /// The "Switch to yearly" card (monetization.md 4.9): a weekly subscriber from the 4th paid
    /// week, shown once, and not when the plan already renews into another product or the
    /// user owns lifetime.
    static func shouldOfferSwitchToYearly(
        activeSubscriptionProductID: String?,
        ownsLifetime: Bool,
        paidWeeklyTransactions: Int,
        autoRenewProductID: String?,
        alreadyShown: Bool
    ) -> Bool {
        guard !alreadyShown, !ownsLifetime,
              let active = activeSubscriptionProductID,
              MonetizationProductKind(productID: active) == .weekly else { return false }
        if let autoRenewProductID, MonetizationProductKind(productID: autoRenewProductID) != .weekly {
            return false
        }
        return paidWeeklyTransactions >= MonetizationRules.switchToYearlyFromPaidWeek
    }
}

/// The last known Pro state, kept across launches so a subscriber is not treated as a free
/// user while the first entitlement refresh of a launch is still running.
struct MonetizationCachedEntitlements: Codable, Sendable, Hashable {
    var ownsLifetime: Bool
    var activeSubscriptionProductID: String?
    /// The expiration date of the subscription's latest transaction.
    var subscriptionExpiration: Date?
    /// When the subscription's billing grace period ends, while StoreKit lists it past
    /// `subscriptionExpiration`. The exact end once the renewal status was read, until then the
    /// longest possible end (`MonetizationRules.longestBillingGracePeriod`). Nil outside a grace
    /// period, and in caches written before this field existed.
    var gracePeriodExpiration: Date?

    init(ownsLifetime: Bool, activeSubscriptionProductID: String?, subscriptionExpiration: Date?, gracePeriodExpiration: Date? = nil) {
        self.ownsLifetime = ownsLifetime
        self.activeSubscriptionProductID = activeSubscriptionProductID
        self.subscriptionExpiration = subscriptionExpiration
        self.gracePeriodExpiration = gracePeriodExpiration
    }

    /// When the subscription stops granting Pro: its expiration date, or the end of its grace
    /// period when that is later.
    var subscriptionAccessEnd: Date? {
        guard let subscriptionExpiration else { return gracePeriodExpiration }
        guard let gracePeriodExpiration else { return subscriptionExpiration }
        return max(subscriptionExpiration, gracePeriodExpiration)
    }

    /// Pro according to the cache at `now`: lifetime, or a subscription whose expiration date or
    /// grace period has not ended.
    func isPro(at now: Date) -> Bool {
        if ownsLifetime { return true }
        guard activeSubscriptionProductID != nil, let subscriptionAccessEnd else { return false }
        return subscriptionAccessEnd > now
    }
}

/// The StoreKit 2 store (monetization.md sections 2-4).
///
/// - The `Transaction.updates` listener starts in `start()` at launch. It delivers Ask to Buy
///   approvals, renewals, purchases made elsewhere and refunds.
/// - A pack transaction is finished only after the credits service stored the 15 credits; any
///   other transaction after entitlements were refreshed.
/// - `Transaction.unfinished` is processed at launch, so a purchase interrupted before
///   `finish()` is granted then.
/// - Pro starts from the last known state (`MonetizationCachedEntitlements`) and is published as
///   soon as `Transaction.currentEntitlements` has been read, before the slower history and
///   subscription status reads.
/// - A subscription in a billing grace period stays Pro, also for the next launch, until the
///   grace period ends, and a refresh is scheduled for that moment.
/// - The free launch cohort (monetization.md section 11) is decided here too, because it grants
///   the same thing a purchase grants. `isPro` is "unlimited analyses, no commercial surface"
///   and is true for a member; `hasPurchasedPro` is the narrower fact that somebody bought
///   something, and it is what Settings' plan row and `restore()` answer to.
@MainActor
@Observable
final class MonetizationStoreService: StoreService, MonetizationPackHistorySource, MonetizationPackLedgerHost, MonetizationLaunchCohortTesting {
    private(set) var loadState: StoreLoadState = .idle
    private(set) var products: [StoreProduct] = []
    private(set) var hasPurchasedPro = false
    /// Unlimited analyses: a purchase, or membership of the free launch cohort.
    var isPro: Bool { hasPurchasedPro || isLaunchCohortMember }
    /// Whether the app is granting the launch offer. See `MonetizationLaunchCohort`: it is
    /// also true while nothing has been decided yet, which is the honest answer for a first
    /// launch with no connection.
    var isLaunchCohortMember: Bool { launchCohort.grantsUnlimitedAnalyses }
    /// Apple has confirmed the offer, so copy may say so. See `MonetizationLaunchCohort`.
    var isConfirmedLaunchCohortMember: Bool { launchCohort.offerIsConfirmed }
    private(set) var activeSubscriptionProductID: String?
    private(set) var shouldOfferSwitchToYearly = false
    private(set) var verifiedPackTransactionIDs: Set<UInt64>?
    private(set) var ownsLifetime = false
    /// True once `Transaction.currentEntitlements` has been read in this launch. Until then
    /// `isPro` comes from the cache of the previous launch.
    private(set) var hasLoadedEntitlements = false

    @ObservationIgnored weak var packLedger: (any MonetizationPackLedger)?

    @ObservationIgnored private let client: any MonetizationStoreKitClient
    @ObservationIgnored private let launchCohort: MonetizationLaunchCohort
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let now: () -> Date
    @ObservationIgnored private var observers: [@MainActor (StoreEvent) -> Void] = []
    @ObservationIgnored private var updatesTask: Task<Void, Never>?
    @ObservationIgnored private var expiryTask: Task<Void, Never>?
    @ObservationIgnored private var activationObserver: (any NSObjectProtocol)?
    @ObservationIgnored private var isLoadingProducts = false
    /// Each refresh gets a number when it starts. A refresh applies each part of its result
    /// only if no newer refresh has applied that part yet, so the newest data wins and an
    /// older refresh never overwrites a newer one.
    @ObservationIgnored private var refreshGeneration = 0
    @ObservationIgnored private var appliedEntitlementsGeneration = 0
    @ObservationIgnored private var appliedHistoryGeneration = 0
    @ObservationIgnored private var appliedOfferGeneration = 0
    /// Packs granted in this launch. A refresh that read the history before the purchase must
    /// not remove them.
    @ObservationIgnored private var grantedPackTransactionIDs: Set<UInt64> = []

    private enum DefaultsKey {
        static let proSubscriptionGroupID = "monetization.proSubscriptionGroupID"
        static let switchToYearlyOfferShown = "monetization.switchToYearlyOfferShown"
        static let cachedEntitlements = "monetization.cachedEntitlements"
    }

    init(
        client: any MonetizationStoreKitClient,
        launchCohort: MonetizationLaunchCohort,
        defaults: UserDefaults = .standard,
        now: @escaping () -> Date = Date.init
    ) {
        self.client = client
        self.launchCohort = launchCohort
        self.defaults = defaults
        self.now = now
        if let cached = cachedEntitlements, cached.isPro(at: now()) {
            hasPurchasedPro = true
            ownsLifetime = cached.ownsLifetime
            if let end = cached.subscriptionAccessEnd, end > now() {
                activeSubscriptionProductID = cached.activeSubscriptionProductID
            }
        }
    }

    private var cachedEntitlements: MonetizationCachedEntitlements? {
        guard let data = defaults.data(forKey: DefaultsKey.cachedEntitlements) else { return nil }
        return try? JSONDecoder().decode(MonetizationCachedEntitlements.self, from: data)
    }

    /// Removes the last known Pro state, for a store whose StoreKit starts empty at every launch
    /// (the DEBUG demo store).
    static func forgetCachedEntitlements(in defaults: UserDefaults) {
        defaults.removeObject(forKey: DefaultsKey.cachedEntitlements)
    }

    /// The subscription group of the Pro plans, learned from the loaded products and kept
    /// across launches.
    var proSubscriptionGroupID: String? {
        defaults.string(forKey: DefaultsKey.proSubscriptionGroupID)
    }

    // MARK: StoreService

    func start() {
        guard updatesTask == nil else { return }
        let updates = client.transactionUpdates()
        updatesTask = Task { [weak self] in
            for await transaction in updates {
                guard let self else { return }
                await self.process(transaction)
            }
        }
        activationObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                await self?.refreshEntitlements()
                // Asked again every time the app comes forward while nothing is decided, so a
                // launch that started with no connection is settled as soon as there is one.
                await self?.resolveLaunchCohort()
            }
        }
        Task { [weak self] in
            guard let self else { return }
            // Before the transactions: this decides whether there is anything to sell at all,
            // and a member must not see a purchase screen flash past while it is decided.
            await self.resolveLaunchCohort()
            for transaction in await self.client.unfinishedTransactions() {
                await self.process(transaction)
            }
            await self.refreshEntitlements()
            await self.loadProducts()
        }
    }

    /// Decides the launch cohort from Apple's signed app transaction, once
    /// (`MonetizationLaunchCohort`). Does nothing once a verdict is stored.
    func resolveLaunchCohort() async {
        await launchCohort.resolve { [client] in await client.appTransactionOriginalPurchaseDate() }
    }

    // MARK: MonetizationLaunchCohortTesting

    var launchCohortStatus: MonetizationLaunchCohortStatus { launchCohort.status }

    var leavesLaunchCohortForTesting: Bool { launchCohort.leavesCohortForTesting }

    @discardableResult
    func setLeavesLaunchCohortForTesting(_ leaves: Bool, for channel: MonetizationBuildChannel) -> Bool {
        launchCohort.setLeavesCohortForTesting(leaves, for: channel)
    }

    /// Loads the products. Loads again when any product of `ProductID.all` is missing, for
    /// example when App Store Connect served only some of them.
    func loadProducts() async {
        guard !isLoadingProducts else { return }
        if loadState == .loaded, Set(products.map(\.id)).isSuperset(of: ProductID.all) { return }
        isLoadingProducts = true
        loadState = .loading
        defer { isLoadingProducts = false }
        do {
            let loaded = try await client.loadProducts(ProductID.all)
            let byID = Dictionary(loaded.map { ($0.product.id, $0) }, uniquingKeysWith: { first, _ in first })
            products = ProductID.all.compactMap { byID[$0]?.product }
            if let groupID = loaded.first(where: { $0.subscriptionGroupID != nil })?.subscriptionGroupID,
               groupID != proSubscriptionGroupID {
                defaults.set(groupID, forKey: DefaultsKey.proSubscriptionGroupID)
            }
            if products.count < ProductID.all.count {
                let missing = ProductID.all.filter { byID[$0] == nil }
                MonetizationLog.store.error("products not served: \(missing.joined(separator: ", "), privacy: .public)")
            }
            loadState = products.isEmpty ? .failed(MonetizationCopy.loadFailed) : .loaded
        } catch {
            MonetizationLog.store.error("loading products failed: \(String(describing: error), privacy: .public)")
            loadState = .failed(error.monetizationIsOffline ? MonetizationCopy.loadFailedOffline : MonetizationCopy.loadFailed)
        }
    }

    func purchase(_ productID: String) async -> PurchaseOutcome {
        do {
            switch try await client.purchase(productID) {
            case .verified(let transaction):
                guard await grant(transaction) else {
                    return .failed(MonetizationCopy.purchaseNotRecorded)
                }
                await client.finish(transaction)
                notify(.transactionVerified(productID: transaction.productID))
                // Named after the product bought, not the transaction: a weekly subscriber who buys
                // Yearly (a crossgrade within the same level) gets the current weekly transaction
                // back, and Yearly starts at the next renewal.
                return .purchased(productID: productID)
            case .unverified:
                return .failed(MonetizationCopy.purchaseFailed)
            case .pending:
                return .pending
            case .userCancelled:
                return .cancelled
            }
        } catch {
            MonetizationLog.store.error("purchase of \(productID, privacy: .public) failed: \(String(describing: error), privacy: .public)")
            return .failed(error.monetizationIsOffline ? MonetizationCopy.purchaseFailedOffline : MonetizationCopy.purchaseFailed)
        }
    }

    func restore() async -> RestoreOutcome {
        do {
            try await client.sync()
        } catch {
            MonetizationLog.store.error("restore failed: \(String(describing: error), privacy: .public)")
            if error.monetizationIsUserCancellation { return .canceled }
            return .failed(error.monetizationIsOffline ? MonetizationCopy.restoreFailedOffline : MonetizationCopy.restoreFailed)
        }
        await refreshEntitlements()
        packLedger?.reloadPurchasedCredits()
        // `Transaction.all` keeps finished packs, including every pack whose credits are spent.
        // `hasPurchasedPro`, not `isPro`: a launch-cohort member bought nothing, so telling
        // them purchases were restored would be a lie.
        return hasPurchasedPro || !(verifiedPackTransactionIDs ?? []).isEmpty ? .restored : .nothingFound
    }

    func refreshEntitlements() async {
        refreshGeneration += 1
        let generation = refreshGeneration

        let entitlements = await client.currentEntitlements()
        let proSummary = MonetizationEntitlementRules.summarize(
            entitlements: entitlements,
            history: [],
            proGroupID: proSubscriptionGroupID
        )
        // During a billing grace period StoreKit keeps listing the subscription after its
        // expiration date.
        let listedPastExpiration = proSummary.activeSubscriptionExpiration.map { $0 <= now() } ?? false
        if generation > appliedEntitlementsGeneration {
            appliedEntitlementsGeneration = generation
            var gracePeriodEnd: Date?
            if listedPastExpiration, let expiration = proSummary.activeSubscriptionExpiration {
                gracePeriodEnd = knownGracePeriodEnd(productID: proSummary.activeSubscriptionProductID, expiration: expiration)
                    ?? expiration.addingTimeInterval(MonetizationRules.longestBillingGracePeriod)
            }
            setEntitlements(
                isPro: proSummary.isPro,
                activeSubscriptionProductID: proSummary.activeSubscriptionProductID,
                ownsLifetime: proSummary.ownsLifetime,
                subscriptionExpiration: proSummary.activeSubscriptionExpiration,
                gracePeriodExpiration: gracePeriodEnd
            )
            hasLoadedEntitlements = true
            if listedPastExpiration {
                // Until the renewal status gives the end of the grace period.
                scheduleRefresh(at: now().addingTimeInterval(MonetizationRules.gracePeriodStatusRetry))
            } else {
                scheduleRefresh(at: proSummary.activeSubscriptionExpiration)
            }
        }

        let history = await client.allTransactions()
        let summary = MonetizationEntitlementRules.summarize(
            entitlements: entitlements,
            history: history,
            proGroupID: proSubscriptionGroupID
        )
        if generation > appliedHistoryGeneration {
            appliedHistoryGeneration = generation
            verifiedPackTransactionIDs = summary.verifiedPackTransactionIDs
                .union(grantedPackTransactionIDs.subtracting(summary.revokedPackTransactionIDs))
            for transactionID in summary.revokedPackTransactionIDs.sorted() {
                packLedger?.revokePack(transactionID: transactionID)
            }
        }

        // The renewal status may need the network; nothing above waits for it. It gives the
        // "Switch to yearly" card its renewal preference and a grace period its end.
        var renewal: MonetizationRenewalFacts?
        if let groupID = summary.activeSubscriptionGroupID,
           let active = summary.activeSubscriptionProductID,
           listedPastExpiration || MonetizationProductKind(productID: active) == .weekly {
            renewal = await client.renewalStatus(subscriptionGroupID: groupID)
        }
        guard generation > appliedOfferGeneration else { return }
        appliedOfferGeneration = generation
        shouldOfferSwitchToYearly = MonetizationEntitlementRules.shouldOfferSwitchToYearly(
            activeSubscriptionProductID: summary.activeSubscriptionProductID,
            ownsLifetime: summary.ownsLifetime,
            paidWeeklyTransactions: summary.paidWeeklyTransactions,
            autoRenewProductID: renewal?.autoRenewProductID,
            alreadyShown: defaults.bool(forKey: DefaultsKey.switchToYearlyOfferShown)
        )
        if listedPastExpiration, generation == appliedEntitlementsGeneration,
           let gracePeriodEnd = renewal?.gracePeriodExpirationDate, gracePeriodEnd > now() {
            setEntitlements(
                isPro: proSummary.isPro,
                activeSubscriptionProductID: proSummary.activeSubscriptionProductID,
                ownsLifetime: proSummary.ownsLifetime,
                subscriptionExpiration: proSummary.activeSubscriptionExpiration,
                gracePeriodExpiration: gracePeriodEnd
            )
            scheduleRefresh(at: gracePeriodEnd)
        }
    }

    /// The exact grace period end an earlier refresh read for the same subscription period, if
    /// it has not passed.
    private func knownGracePeriodEnd(productID: String?, expiration: Date) -> Date? {
        guard let cached = cachedEntitlements,
              cached.activeSubscriptionProductID == productID,
              cached.subscriptionExpiration == expiration,
              let end = cached.gracePeriodExpiration, end > now(),
              end < expiration.addingTimeInterval(MonetizationRules.longestBillingGracePeriod) else { return nil }
        return end
    }

    func showManageSubscriptions() async {
        await client.showManageSubscriptions()
    }

    func addTransactionObserver(_ observer: @escaping @MainActor (StoreEvent) -> Void) {
        observers.append(observer)
    }

    func recordSwitchToYearlyOfferShown() {
        defaults.set(true, forKey: DefaultsKey.switchToYearlyOfferShown)
        shouldOfferSwitchToYearly = false
    }

    // MARK: Transactions

    /// Handles a transaction from `Transaction.updates` or `Transaction.unfinished`.
    private func process(_ transaction: MonetizationTransactionFacts) async {
        if transaction.revocationDate != nil {
            var stored = true
            if MonetizationProductKind(productID: transaction.productID) == .pack {
                verifiedPackTransactionIDs?.remove(transaction.id)
                grantedPackTransactionIDs.remove(transaction.id)
                if let packLedger {
                    packLedger.revokePack(transactionID: transaction.id)
                } else {
                    stored = false
                }
            }
            await refreshEntitlements()
            if stored {
                await client.finish(transaction)
            } else {
                MonetizationLog.store.error("left revoked transaction \(transaction.id, privacy: .public) unfinished: no credits ledger")
            }
            notify(.transactionRevoked(productID: transaction.productID))
            return
        }
        guard await grant(transaction) else {
            MonetizationLog.store.error("left transaction \(transaction.id, privacy: .public) unfinished: it could not be granted yet")
            return
        }
        await client.finish(transaction)
        notify(.transactionVerified(productID: transaction.productID))
    }

    /// Grants what a verified transaction bought. Returns false when it could not be granted
    /// yet; the transaction must then stay unfinished.
    private func grant(_ transaction: MonetizationTransactionFacts) async -> Bool {
        if transaction.kind == .consumable, MonetizationProductKind(productID: transaction.productID) == .pack {
            guard let packLedger else {
                MonetizationLog.store.error("no credits ledger for pack transaction \(transaction.id, privacy: .public)")
                return false
            }
            grantedPackTransactionIDs.insert(transaction.id)
            verifiedPackTransactionIDs?.insert(transaction.id)
            packLedger.creditPack(transactionID: transaction.id)
            return true
        }
        await refreshEntitlements()
        // `hasPurchasedPro`: a launch-cohort member already has unlimited analyses, and their
        // purchase still has to be recorded as a purchase.
        if !hasPurchasedPro, MonetizationEntitlementRules.provesProNow(transaction, proGroupID: proSubscriptionGroupID, now: now()) {
            // The verified transaction itself proves the entitlement, even if the refreshed
            // entitlements do not list it yet. Refresh again when it ends.
            switch transaction.kind {
            case .autoRenewable:
                setEntitlements(
                    isPro: true,
                    activeSubscriptionProductID: transaction.productID,
                    ownsLifetime: ownsLifetime,
                    subscriptionExpiration: transaction.expirationDate,
                    gracePeriodExpiration: nil
                )
                scheduleRefresh(at: transaction.expirationDate)
            case .nonConsumable:
                setEntitlements(
                    isPro: true,
                    activeSubscriptionProductID: activeSubscriptionProductID,
                    ownsLifetime: true,
                    subscriptionExpiration: nil,
                    gracePeriodExpiration: nil
                )
            case .consumable, .nonRenewing:
                break
            }
        }
        return true
    }

    /// Publishes the purchased-Pro state and keeps it for the next launch. It never touches
    /// the launch cohort, which is decided from Apple's app transaction and nothing else.
    private func setEntitlements(
        isPro: Bool,
        activeSubscriptionProductID: String?,
        ownsLifetime: Bool,
        subscriptionExpiration: Date?,
        gracePeriodExpiration: Date?
    ) {
        if hasPurchasedPro != isPro { hasPurchasedPro = isPro }
        if self.activeSubscriptionProductID != activeSubscriptionProductID { self.activeSubscriptionProductID = activeSubscriptionProductID }
        if self.ownsLifetime != ownsLifetime { self.ownsLifetime = ownsLifetime }
        let cached = MonetizationCachedEntitlements(
            ownsLifetime: ownsLifetime,
            activeSubscriptionProductID: activeSubscriptionProductID,
            subscriptionExpiration: subscriptionExpiration,
            gracePeriodExpiration: gracePeriodExpiration
        )
        if let data = try? JSONEncoder().encode(cached) {
            defaults.set(data, forKey: DefaultsKey.cachedEntitlements)
        }
    }

    private func notify(_ event: StoreEvent) {
        for observer in observers {
            observer(event)
        }
    }

    /// Refreshes again when the active subscription or its grace period is due to end, so Pro
    /// ends on time while the app stays open.
    private func scheduleRefresh(at date: Date?) {
        expiryTask?.cancel()
        guard let date else { return }
        let delay = date.timeIntervalSince(now()) + 1
        guard delay > 0, delay < 400 * 24 * 60 * 60 else { return }
        expiryTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            await self?.refreshEntitlements()
        }
    }
}
