import ChessCore
import Foundation
import Observation
import UIKit

/// Supplies the verified, non-revoked pack transactions from `Transaction.all`, which keeps
/// finished packs (`SKIncludeConsumableInAppPurchaseHistory`). Implemented by the store.
@MainActor
protocol MonetizationPackHistorySource: AnyObject {
    /// Nil until the transaction history has been read.
    var verifiedPackTransactionIDs: Set<UInt64>? { get }
}

/// Receives verified and revoked pack transactions from the store, which finishes the
/// transaction afterwards. Finishing never loses a pack: `Transaction.all` keeps it, so a pack
/// whose record could not be written yet still counts once the history is read.
@MainActor
protocol MonetizationPackLedger: AnyObject {
    /// Credits a verified pack transaction (idempotent).
    func creditPack(transactionID: UInt64)
    /// Applies a refunded or revoked pack (idempotent).
    func revokePack(transactionID: UInt64)
    /// Reads the synchronizable purchased record again, for example after `AppStore.sync()`.
    func reloadPurchasedCredits()
}

/// A store that hands pack transactions to a ledger.
@MainActor
protocol MonetizationPackLedgerHost: AnyObject {
    var packLedger: (any MonetizationPackLedger)? { get set }
}

/// Free analyses, purchased credits and the paid-board memory (monetization.md sections 3-5).
///
/// - Free analyses, paid boards, this device's id and this device's copy of the purchased
///   record live in a non-synchronizable Keychain item, so deleting the app does not reset them.
/// - Purchased credits live in a synchronizable Keychain item (see
///   `MonetizationPurchasedRecord`). It is read again before every decision and every change,
///   and written back merged, so spends and packs from other devices are never undone.
/// - `authorize` decides without spending. `commit` spends once per authorization id and
///   re-checks everything, so two authorizations of the same board cost one credit.
/// - Nothing is granted from defaults: while the local record cannot be read or decoded, only
///   Pro is allowed, and nothing is written over the stored data.
@MainActor
@Observable
final class MonetizationCreditsService: CreditsService, MonetizationPackLedger, MonetizationTestingGrants {
    let freeAllowance = MonetizationRules.freeAllowance

    /// 0 while the local record is unavailable.
    var freeRemaining: Int { localLoaded ? local.freeRemaining : 0 }

    /// 0 while the local record is unavailable (spends could not be attributed to this device).
    var purchasedRemaining: Int {
        guard localLoaded else { return 0 }
        return purchased.remaining(historyPackIDs: historySource?.verifiedPackTransactionIDs)
    }

    private var local: MonetizationLocalRecord
    private var purchased: MonetizationPurchasedRecord
    /// Writes to the local item are allowed only after it was read and decoded (or found
    /// missing), so an unreadable Keychain never overwrites a real balance with defaults.
    private var localLoaded = false

    @ObservationIgnored private let store: any StoreService
    @ObservationIgnored private weak var historySource: (any MonetizationPackHistorySource)?
    @ObservationIgnored private let vault: any MonetizationVault
    @ObservationIgnored private let now: () -> Date
    @ObservationIgnored private var synced: SyncedItem = .unread
    @ObservationIgnored private var committedAuthorizationIDs: Set<UUID> = []
    /// The free-edit scope of each outstanding authorization, oldest first.
    @ObservationIgnored private var freeEditByAuthorization: [(id: UUID, freeEdit: MonetizationFreeEdit)] = []
    /// How many outstanding authorizations keep their scope. One board is authorized at a time,
    /// so this is never reached in the app.
    private static let rememberedAuthorizations = 32
    @ObservationIgnored private var activationObserver: (any NSObjectProtocol)?

    /// What the last read of the synchronizable item found.
    private enum SyncedItem: Equatable {
        case unread
        /// Read and decoded (nil: the item does not exist). Writes are allowed.
        case writable(MonetizationPurchasedRecord?)
        /// Written by a newer app version: its known fields are used, but it is never written.
        case newerVersion(MonetizationPurchasedRecord)
        /// The read failed or the data could not be decoded. Never written.
        case unavailable

        var isWritable: Bool {
            if case .writable = self { return true }
            return false
        }

        var lastRead: MonetizationPurchasedRecord? {
            switch self {
            case .writable(let record): record
            case .newerVersion(let record): record
            case .unread, .unavailable: nil
            }
        }
    }

    init(
        store: any StoreService,
        vault: any MonetizationVault,
        now: @escaping () -> Date = Date.init
    ) {
        self.store = store
        self.vault = vault
        self.now = now
        local = .newInstall
        purchased = MonetizationPurchasedRecord()
        historySource = store as? any MonetizationPackHistorySource
        loadLocalIfNeeded()
        reloadPurchased()
        (store as? any MonetizationPackLedgerHost)?.packLedger = self
        // Another device may have spent or bought credits while the app was in the background.
        activationObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.loadLocalIfNeeded()
                self?.reloadPurchased()
            }
        }
    }

    // MARK: CreditsService

    /// The call the app shell makes. `recognition` is what recognition contributed to this
    /// board, which decides the squares a later edit may change for free (monetization.md
    /// section 5); nil for a board no recognizer read (set up by hand, or restored from disk
    /// for an Ask to Buy approval).
    func authorize(
        board: [Piece?],
        origin: AnalysisOrigin,
        recognition: MonetizationRecognitionEvidence?
    ) -> CreditAuthorization {
        authorize(board: board, origin: origin, freeEdit: recognition?.freeEdit(for: board) ?? .squares([]))
    }

    /// The same decision with the evidence unknown, which is not the `CreditsService` call: the
    /// app shell always passes evidence. Nothing is known about what recognition contributed, so
    /// the board is remembered as one paid under the rule before the doubt-scoped one
    /// (`MonetizationFreeEdit.anySquare`) rather than as one the app read correctly everywhere.
    /// Kept for the tests that exercise the credit arithmetic on hand-built boards.
    func authorize(board: [Piece?], origin: AnalysisOrigin) -> CreditAuthorization {
        authorize(board: board, origin: origin, freeEdit: .anySquare)
    }

    private func authorize(board: [Piece?], origin: AnalysisOrigin, freeEdit: MonetizationFreeEdit) -> CreditAuthorization {
        loadLocalIfNeeded()
        reloadPurchased()
        guard localLoaded else {
            MonetizationLog.credits.error("authorize without a readable local record: only Pro is allowed")
            let decision = MonetizationCreditPolicy.decide(
                board: MonetizationBoardKey(board),
                origin: origin,
                isPro: store.isPro,
                freeRemaining: 0,
                purchasedRemaining: 0,
                paidBoards: []
            )
            let authorization = CreditAuthorization(board: board, origin: origin, decision: decision)
            keepFreeEdit(freeEdit, for: authorization)
            return authorization
        }
        let decision = MonetizationCreditPolicy.decide(
            board: MonetizationBoardKey(board),
            origin: origin,
            isPro: store.isPro,
            freeRemaining: freeRemaining,
            purchasedRemaining: purchasedRemaining,
            paidBoards: local.paidBoards
        )
        let authorization = CreditAuthorization(board: board, origin: origin, decision: decision)
        keepFreeEdit(freeEdit, for: authorization)
        return authorization
    }

    /// Keeps the free-edit scope until `commit` stores the paid board. `CreditAuthorization` is
    /// a contract type the app shell passes around, so the scope is held here, by authorization
    /// id. An authorization that never reaches `commit` is dropped once
    /// `rememberedAuthorizations` newer ones have arrived; a board committed after that is
    /// stored with no free squares, which charges for later edits rather than giving them away.
    private func keepFreeEdit(_ freeEdit: MonetizationFreeEdit, for authorization: CreditAuthorization) {
        freeEditByAuthorization.append((authorization.id, freeEdit))
        if freeEditByAuthorization.count > Self.rememberedAuthorizations {
            freeEditByAuthorization.removeFirst(freeEditByAuthorization.count - Self.rememberedAuthorizations)
        }
    }

    func commit(_ authorization: CreditAuthorization) {
        guard committedAuthorizationIDs.insert(authorization.id).inserted else { return }
        switch authorization.decision {
        case .allowedFreeReanalysis, .needsPaywall:
            return
        case .allowedPro, .spendFree, .spendPurchased:
            break
        }
        loadLocalIfNeeded()
        guard localLoaded else {
            MonetizationLog.credits.error("commit without a readable local record for authorization \(authorization.id, privacy: .public)")
            return
        }
        let key = MonetizationBoardKey(authorization.board)
        let index = freeEditByAuthorization.lastIndex { $0.id == authorization.id }
        let paid = MonetizationPaidBoard(key: key, freeEdit: index.map { freeEditByAuthorization[$0].freeEdit } ?? .squares([]))
        if let index { freeEditByAuthorization.remove(at: index) }
        // A board analyzed while Pro was active is remembered like a paid board, so changing
        // only its side to move or castling rights in the editor stays free after Pro lapses
        // (monetization.md section 5). Re-check at commit time: Pro may have started since
        // `authorize`.
        if authorization.decision == .allowedPro || store.isPro {
            local.rememberPaidBoard(paid)
            saveLocal()
            return
        }
        // Another commit may have paid for this board since `authorize`.
        guard !MonetizationCreditPolicy.isCoveredByPaidBoard(key, paidBoards: local.paidBoards) else { return }

        if local.freeRemaining > 0 {
            local.freeRemaining -= 1
        } else {
            reloadPurchased()
            guard purchasedRemaining > 0 else {
                MonetizationLog.credits.error("commit found no credit left for authorization \(authorization.id, privacy: .public)")
                return
            }
            purchased.spendOne(deviceID: local.deviceID)
            local.purchased = purchased
            // The spend is kept in the local item even if the synchronizable one cannot be
            // written; the next successful write merges it.
            saveSynced(purchased)
        }
        local.rememberPaidBoard(paid)
        saveLocal()
    }

    func shouldOfferDownsell(after trigger: PaywallTrigger) -> Bool {
        guard trigger == .creditsExhausted, !store.isPro else { return false }
        loadLocalIfNeeded()
        guard localLoaded else { return false }
        return local.offersDownsell(now: now())
    }

    func recordDownsellDeclined() {
        loadLocalIfNeeded()
        guard localLoaded else { return }
        local.lastDownsellDeclinedAt = now()
        saveLocal()
    }

    // MARK: MonetizationPackLedger

    func creditPack(transactionID: UInt64) {
        loadLocalIfNeeded()
        reloadPurchased()
        var candidate = purchased
        // Refunded before it was credited: nothing to add.
        guard !candidate.revokedPackTransactionIDs.contains(transactionID) else { return }
        if candidate.creditPack(transactionID: transactionID) {
            apply(candidate, clearingDownsellPause: true)
        }
        // The record counts the pack before the history is read and carries it to devices that
        // have not read theirs; a failed write is retried by the next one.
        if !(synced.lastRead?.creditedPackTransactionIDs.contains(transactionID) ?? false) {
            saveSynced(purchased)
        }
    }

    func revokePack(transactionID: UInt64) {
        loadLocalIfNeeded()
        reloadPurchased()
        var candidate = purchased
        if candidate.revokePack(transactionID: transactionID, historyPackIDs: historySource?.verifiedPackTransactionIDs) {
            // A revocation takes effect at once, whether or not it can be stored yet.
            apply(candidate, clearingDownsellPause: false)
        }
        if !(synced.lastRead?.revokedPackTransactionIDs.contains(transactionID) ?? false) {
            saveSynced(purchased)
        }
    }

    func reloadPurchasedCredits() {
        loadLocalIfNeeded()
        reloadPurchased()
    }

    // MARK: MonetizationTestingGrants

    /// What the Settings Testing section shows (MonetizationTesting.swift). Reading it costs
    /// nothing: every number is already in memory.
    var testingCounts: MonetizationTestingCounts {
        MonetizationTestingCounts(
            freeRemaining: freeRemaining,
            freeAllowance: freeAllowance,
            purchasedRemaining: purchasedRemaining,
            paidBoards: localLoaded ? local.paidBoards.count : 0,
            isStorageReadable: localLoaded
        )
    }

    /// Back to what a new install has: the full free allowance, no remembered paid boards (so
    /// no board is free under the 3-square rule any more), no downsell pause, and every pack
    /// this section granted taken back.
    ///
    /// Granted packs are taken back through `revokePack`, the same path a refund takes, so a
    /// bought pack is never touched and analyses spent beyond what is left are written off
    /// rather than left as a debt against the next real purchase.
    @discardableResult
    func resetFreeAnalyses(for channel: MonetizationBuildChannel) -> Bool {
        guard channel.offersTestingTools else { return false }
        loadLocalIfNeeded()
        reloadPurchased()
        guard localLoaded else {
            MonetizationLog.credits.error("testing reset without a readable local record: nothing changed")
            return false
        }
        let granted = purchased
            .validPacks(historyPackIDs: historySource?.verifiedPackTransactionIDs)
            .filter(MonetizationTestingGrant.isTestingTransactionID)
            .sorted()
        for transactionID in granted {
            revokePack(transactionID: transactionID)
        }
        local.freeRemaining = freeAllowance
        local.paidBoards = []
        local.lastDownsellDeclinedAt = nil
        let stored = saveLocal()
        MonetizationLog.credits.notice(
            "testing reset: free analyses back to \(self.freeAllowance, privacy: .public), paid boards forgotten, \(granted.count, privacy: .public) granted packs taken back, stored \(stored, privacy: .public)"
        )
        return stored
    }

    /// One pack's worth of analyses without a purchase, credited through the ordinary pack
    /// ledger under an id the App Store cannot issue (`MonetizationTestingGrant`).
    @discardableResult
    func grantTestingAnalyses(for channel: MonetizationBuildChannel) -> Bool {
        guard channel.offersTestingTools else { return false }
        loadLocalIfNeeded()
        reloadPurchased()
        guard localLoaded else {
            MonetizationLog.credits.error("testing grant without a readable local record: nothing changed")
            return false
        }
        var used = purchased.creditedPackTransactionIDs.union(purchased.revokedPackTransactionIDs)
        used.formUnion(historySource?.verifiedPackTransactionIDs ?? [])
        let transactionID = MonetizationTestingGrant.nextTransactionID(notIn: used)
        let before = purchasedRemaining
        creditPack(transactionID: transactionID)
        let granted = purchasedRemaining - before
        MonetizationLog.credits.notice(
            "testing grant: \(granted, privacy: .public) analyses as pack \(transactionID, privacy: .public)"
        )
        return granted > 0
    }

    // MARK: Storage

    /// Replaces the in-memory purchased record with `record` (which already holds everything
    /// read) and keeps this device's copy in the local item.
    private func apply(_ record: MonetizationPurchasedRecord, clearingDownsellPause: Bool) {
        purchased = record
        guard localLoaded else { return }
        local.purchased = record
        // monetization.md 4.7: the 24-hour pause only counts closes without a purchase.
        if clearingDownsellPause { local.lastDownsellDeclinedAt = nil }
        saveLocal()
    }

    private func loadLocalIfNeeded() {
        guard !localLoaded else { return }
        let data: Data?
        do {
            data = try vault.data(for: .local)
        } catch {
            MonetizationLog.credits.error("reading free analyses failed: \(String(describing: error), privacy: .public)")
            return
        }
        guard let data else {
            var record = MonetizationLocalRecord.newInstall
            record.purchased = purchased
            local = record
            localLoaded = true
            saveLocal()
            return
        }
        let record: MonetizationLocalRecord
        do {
            record = try JSONDecoder().decode(MonetizationLocalRecord.self, from: data)
        } catch {
            // Keep the stored data untouched and grant nothing from defaults.
            MonetizationLog.credits.error("the free-analyses record could not be decoded and was left untouched: \(String(describing: error), privacy: .public)")
            return
        }
        var loaded = record
        loaded.freeRemaining = min(max(0, loaded.freeRemaining), freeAllowance)
        let needsSave = loaded.deviceID.isEmpty || loaded != record
        if loaded.deviceID.isEmpty { loaded.deviceID = UUID().uuidString }
        let merged = purchased.merged(with: loaded.purchased)
        loaded.purchased = merged
        local = loaded
        if merged != purchased { purchased = merged }
        localLoaded = true
        if needsSave { saveLocal() }
    }

    /// Reads the synchronizable item and merges it into the in-memory record.
    private func reloadPurchased() {
        let data: Data?
        do {
            data = try vault.data(for: .purchased)
        } catch {
            MonetizationLog.credits.error("reading purchased credits failed: \(String(describing: error), privacy: .public)")
            synced = .unavailable
            return
        }
        guard let data else {
            synced = .writable(nil)
            return
        }
        let record: MonetizationPurchasedRecord
        do {
            record = try JSONDecoder().decode(MonetizationPurchasedRecord.self, from: data)
        } catch {
            MonetizationLog.credits.error("the purchased-credits record could not be decoded and was left untouched: \(String(describing: error), privacy: .public)")
            synced = .unavailable
            return
        }
        synced = record.version > MonetizationPurchasedRecord.currentVersion ? .newerVersion(record) : .writable(record)
        let merged = purchased.merged(with: record)
        if merged != purchased { purchased = merged }
    }

    @discardableResult
    private func saveLocal() -> Bool {
        guard localLoaded else { return false }
        return save(local, to: .local)
    }

    /// Writes `record` over the synchronizable item. Only allowed right after that item was
    /// read, and `record` must already be merged with what was read.
    @discardableResult
    private func saveSynced(_ record: MonetizationPurchasedRecord) -> Bool {
        guard synced.isWritable, record.version <= MonetizationPurchasedRecord.currentVersion else { return false }
        guard save(record, to: .purchased) else { return false }
        synced = .writable(record)
        return true
    }

    private func save(_ value: some Encodable, to item: MonetizationVaultItem) -> Bool {
        do {
            try vault.setData(try JSONEncoder().encode(value), for: item)
            return true
        } catch {
            MonetizationLog.credits.error("saving \(item.account, privacy: .public) failed: \(String(describing: error), privacy: .public)")
            return false
        }
    }
}
