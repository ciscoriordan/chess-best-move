import ChessCore
import Foundation

// Pure credit rules (monetization.md sections 3 and 5). Nothing here touches StoreKit, the
// Keychain or the main actor, so every rule is unit tested directly.

// MARK: - Boards

/// A 64-square piece placement as stored for the paid-board memory: one character per square
/// in `Square.index` order, the FEN letter of the piece or "." for an empty square.
struct MonetizationBoardKey: Codable, Sendable, Hashable {
    let squares: String

    init(_ board: [Piece?]) {
        squares = String(board.map { $0?.fenCharacter ?? "." })
    }

    init(squares: String) {
        self.squares = squares
    }

    /// The same board rotated by 180 degrees (what Flip does: square `i` becomes `63 - i`).
    var rotated: MonetizationBoardKey {
        MonetizationBoardKey(squares: String(squares.reversed()))
    }

    /// The number of squares whose content differs. Boards of different length (never
    /// produced by the app) count every missing square as different.
    func squareDifference(to other: MonetizationBoardKey) -> Int {
        let lhs = Array(squares.utf8)
        let rhs = Array(other.squares.utf8)
        var count = abs(lhs.count - rhs.count)
        for index in 0..<min(lhs.count, rhs.count) where lhs[index] != rhs[index] {
            count += 1
        }
        return count
    }

    /// The smaller difference to `paid` as displayed or flipped.
    func differenceIgnoringFlip(to paid: MonetizationBoardKey) -> Int {
        min(squareDifference(to: paid), squareDifference(to: paid.rotated))
    }

    /// True when this board is `other` with exactly one piece taken off and nothing else
    /// changed: one square holds a piece in `other` and is empty here, and every other square
    /// is identical (monetization.md section 5, the always-free fix).
    func removesExactlyOnePiece(from other: MonetizationBoardKey) -> Bool {
        let mine = Array(squares.utf8)
        let theirs = Array(other.squares.utf8)
        guard mine.count == theirs.count else { return false }
        let empty = UInt8(ascii: ".")
        var removed = false
        for index in 0..<mine.count where mine[index] != theirs[index] {
            guard !removed, mine[index] == empty, theirs[index] != empty else { return false }
            removed = true
        }
        return removed
    }
}

// MARK: - Decisions

enum MonetizationCreditPolicy {
    /// True when one of `paidBoards` covers `board` (`paidBoard(_:covers:)`).
    static func isCoveredByPaidBoard(_ board: MonetizationBoardKey, paidBoards: [MonetizationBoardKey]) -> Bool {
        paidBoards.contains { paidBoard($0, covers: board) }
    }

    /// Whether `paid` makes analyzing `board` free (monetization.md section 5). The count is
    /// always from the paid board, never from the last edit.
    ///
    /// - The same placement, as shown or flipped (square `i` as `63 - i`), is covered.
    /// - A placement that takes exactly one piece off a paid board and changes nothing else is
    ///   covered, whatever play could also produce it (owner decision, 2026-09-17): a single
    ///   vanished piece is a misread square, and the three plies that end with that piece
    ///   captured on the square it just entered are not what the user did.
    /// - A placement within `MonetizationRules.maximumFreeSquareDifference` squares, as shown or
    ///   flipped, is a fix of misread squares and covered, unless 1 to 3 legal plies from the
    ///   paid board explain it (`MonetizationPlayRule`). Then it costs like a new board, so
    ///   following a game by editing costs a credit per move even when a capture and its
    ///   recapture change only 2 or 3 squares.
    /// - Either board may have been read upside down, so each explanation is tried in both
    ///   orientations of the pair: as shown (paid to board, both rotated) and flipped (paid to the
    ///   rotated board, the rotated paid board to board).
    static func paidBoard(_ paid: MonetizationBoardKey, covers board: MonetizationBoardKey) -> Bool {
        let asShown = board.squareDifference(to: paid)
        let flipped = board.squareDifference(to: paid.rotated)
        if asShown == 0 || flipped == 0 { return true }
        if board.removesExactlyOnePiece(from: paid) || board.removesExactlyOnePiece(from: paid.rotated) { return true }
        let limit = MonetizationRules.maximumFreeSquareDifference
        guard asShown <= limit || flipped <= limit else { return false }
        if asShown <= limit,
           MonetizationPlayRule.isReachableByPlay(from: paid, to: board)
            || MonetizationPlayRule.isReachableByPlay(from: paid.rotated, to: board.rotated) {
            return false
        }
        if flipped <= limit,
           MonetizationPlayRule.isReachableByPlay(from: paid, to: board.rotated)
            || MonetizationPlayRule.isReachableByPlay(from: paid.rotated, to: board) {
            return false
        }
        return true
    }

    /// The decision for one analysis. Order of use: Pro, then no credit needed (a board covered
    /// by a paid board), then free, then purchased. The origin gives no free pass: think time,
    /// side to move and flip re-run the same session and never reach `authorize`, and an
    /// editor change of side to move or castling rights keeps the piece placement, so a paid
    /// board covers it.
    ///
    /// A low-confidence recognition (`.recognition` after Check position), a board set up by
    /// hand (`.handSetup`) and a board from the App Shortcut (`.shortcut`) get no special
    /// treatment: they cost a credit like any new board, and are free only when a paid board
    /// covers them (for example the same screenshot imported again).
    static func decide(
        board: MonetizationBoardKey,
        origin: AnalysisOrigin,
        isPro: Bool,
        freeRemaining: Int,
        purchasedRemaining: Int,
        paidBoards: [MonetizationBoardKey]
    ) -> CreditDecision {
        if isPro { return .allowedPro }
        if isCoveredByPaidBoard(board, paidBoards: paidBoards) { return .allowedFreeReanalysis }
        if freeRemaining > 0 { return .spendFree }
        if purchasedRemaining > 0 { return .spendPurchased }
        return .needsPaywall
    }
}

// MARK: - Stored records

/// The non-synchronizable record: free analyses, the paid-board memory, the downsell cooldown,
/// this device's id and this device's copy of the purchased-credit record.
///
/// Decoding never fails for a missing or changed field: each field falls back on its own, so
/// an update that adds a field, or a record written by another app version, never resets the
/// balance. A missing `freeRemaining` decodes as 0, never as a new install's allowance.
struct MonetizationLocalRecord: Codable, Sendable, Equatable {
    var freeRemaining: Int
    /// Oldest first, at most `MonetizationRules.rememberedPaidBoards`.
    var paidBoards: [MonetizationBoardKey]
    var lastDownsellDeclinedAt: Date?
    /// A random id for this device's spend counter in `MonetizationPurchasedRecord`. Empty when
    /// the stored record predates it; the credits service then assigns one and saves it.
    var deviceID: String
    /// This device's latest view of the synchronizable purchased record. It is merged into the
    /// synchronizable item on every write, so a write that iCloud Keychain loses to another
    /// device (last writer wins) is restored by this device's next write.
    var purchased: MonetizationPurchasedRecord

    init(
        freeRemaining: Int,
        paidBoards: [MonetizationBoardKey],
        lastDownsellDeclinedAt: Date?,
        deviceID: String = UUID().uuidString,
        purchased: MonetizationPurchasedRecord = MonetizationPurchasedRecord()
    ) {
        self.freeRemaining = freeRemaining
        self.paidBoards = paidBoards
        self.lastDownsellDeclinedAt = lastDownsellDeclinedAt
        self.deviceID = deviceID
        self.purchased = purchased
    }

    /// A new install: the full free allowance and a new device id.
    static var newInstall: MonetizationLocalRecord {
        MonetizationLocalRecord(freeRemaining: MonetizationRules.freeAllowance, paidBoards: [], lastDownsellDeclinedAt: nil)
    }

    private enum CodingKeys: String, CodingKey {
        case freeRemaining, paidBoards, lastDownsellDeclinedAt, deviceID, purchased
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        freeRemaining = (try? container.decodeIfPresent(Int.self, forKey: .freeRemaining)) ?? 0
        paidBoards = (try? container.decodeIfPresent([MonetizationBoardKey].self, forKey: .paidBoards)) ?? []
        lastDownsellDeclinedAt = try? container.decodeIfPresent(Date.self, forKey: .lastDownsellDeclinedAt)
        deviceID = (try? container.decodeIfPresent(String.self, forKey: .deviceID)) ?? ""
        purchased = (try? container.decodeIfPresent(MonetizationPurchasedRecord.self, forKey: .purchased)) ?? MonetizationPurchasedRecord()
    }

    /// Remembers a board a credit was spent on (or that was analyzed while Pro was active).
    /// Re-paying a remembered board moves it to the newest position; the oldest board is
    /// forgotten beyond the limit.
    mutating func rememberPaidBoard(_ board: MonetizationBoardKey) {
        paidBoards.removeAll { $0 == board }
        paidBoards.append(board)
        if paidBoards.count > MonetizationRules.rememberedPaidBoards {
            paidBoards.removeFirst(paidBoards.count - MonetizationRules.rememberedPaidBoards)
        }
    }

    func offersDownsell(now: Date) -> Bool {
        guard let declined = lastDownsellDeclinedAt else { return true }
        return now.timeIntervalSince(declined) >= MonetizationRules.downsellCooldown
    }
}

/// The synchronizable record for purchased credits, shared by every device of the Apple
/// Account through iCloud Keychain.
///
/// iCloud Keychain keeps whichever whole-item write is newest, so the record is built to merge
/// (`merged(with:)`) instead of being overwritten: spends are grow-only counters per device
/// (merged by maximum), credited and revoked packs are sets (merged by union). The credits
/// service reads the item right before every change and writes the merge back.
///
///     remaining = 15 x |(credited packs ∪ history packs) - revoked packs| - (spent - forgiven), floored at 0
///
/// History packs are the verified pack transactions in `Transaction.all`, which keeps finished
/// consumables on iOS 18 and later with `SKIncludeConsumableInAppPurchaseHistory`. The credited
/// set counts a pack before the history has been read and carries it to devices that have not
/// read theirs yet.
struct MonetizationPurchasedRecord: Codable, Sendable, Equatable {
    /// The schema written by this app version. An app version that reads a newer schema uses
    /// the fields it knows but never writes the item, so it cannot drop fields it does not know.
    static let currentVersion = 2
    /// The key that holds the single `spent` counter of a version 1 record.
    static let legacyDeviceID = "legacy"

    var version = MonetizationPurchasedRecord.currentVersion
    /// Credits spent from packs, by device id. Each device only ever raises its own counter.
    var spentByDevice: [String: Int] = [:]
    /// Pack transactions already credited. Makes crediting idempotent (a transaction can be
    /// delivered by the purchase call, `Transaction.unfinished` and `Transaction.updates`).
    var creditedPackTransactionIDs: Set<UInt64> = []
    /// Pack revocations already applied. Makes revocation idempotent.
    var revokedPackTransactionIDs: Set<UInt64> = []
    /// Spends forgiven when a revoked pack left more spent than bought, by transaction id, so
    /// the next pack is worth the full 15 ("never going below 0", monetization.md section 3).
    var forgivenByRevokedPack: [String: Int] = [:]

    init() {}

    private enum CodingKeys: String, CodingKey {
        case version, spentByDevice, creditedPackTransactionIDs, revokedPackTransactionIDs, forgivenByRevokedPack
        /// Version 1: one counter for all devices.
        case spent
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = (try? container.decodeIfPresent(Int.self, forKey: .version)) ?? 1
        spentByDevice = (try? container.decodeIfPresent([String: Int].self, forKey: .spentByDevice)) ?? [:]
        if let legacySpent = try? container.decodeIfPresent(Int.self, forKey: .spent), legacySpent > 0 {
            spentByDevice[Self.legacyDeviceID] = max(spentByDevice[Self.legacyDeviceID] ?? 0, legacySpent)
        }
        creditedPackTransactionIDs = (try? container.decodeIfPresent(Set<UInt64>.self, forKey: .creditedPackTransactionIDs)) ?? []
        revokedPackTransactionIDs = (try? container.decodeIfPresent(Set<UInt64>.self, forKey: .revokedPackTransactionIDs)) ?? []
        forgivenByRevokedPack = (try? container.decodeIfPresent([String: Int].self, forKey: .forgivenByRevokedPack)) ?? [:]
        // Version 1 also wrote `storedBalance`, the balance its iOS 17 accounting kept. It is not
        // read: version 1 itself ignored it on iOS 18 and later (the minimum now) and derived the
        // balance from `spent` and the packs, as this version does, and reading it could only
        // grant credits nobody bought. Its `spent` counter becomes `legacyDeviceID`'s counter,
        // and the next write stores the record as version 2 without either old key.
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(version, forKey: .version)
        try container.encode(spentByDevice, forKey: .spentByDevice)
        try container.encode(creditedPackTransactionIDs, forKey: .creditedPackTransactionIDs)
        try container.encode(revokedPackTransactionIDs, forKey: .revokedPackTransactionIDs)
        try container.encode(forgivenByRevokedPack, forKey: .forgivenByRevokedPack)
    }

    /// Credits spent on every device.
    var spent: Int { spentByDevice.values.reduce(0) { $0 + max(0, $1) } }

    /// Spent credits that still count against bought ones.
    var effectiveSpent: Int {
        max(0, spent - forgivenByRevokedPack.values.reduce(0) { $0 + max(0, $1) })
    }

    /// Bought, non-revoked packs: the credited ones plus the ones in `Transaction.all`.
    func validPacks(historyPackIDs: Set<UInt64>?) -> Set<UInt64> {
        creditedPackTransactionIDs.union(historyPackIDs ?? []).subtracting(revokedPackTransactionIDs)
    }

    /// Purchased credits left. `historyPackIDs` is the set of verified, non-revoked pack
    /// transactions from `Transaction.all`, or nil when it has not been (or cannot be) read.
    func remaining(historyPackIDs: Set<UInt64>?) -> Int {
        max(0, validPacks(historyPackIDs: historyPackIDs).count * ProductID.creditsPerPack - effectiveSpent)
    }

    /// Credits a verified pack transaction. Returns false when it was already credited or has
    /// been revoked.
    @discardableResult
    mutating func creditPack(transactionID: UInt64) -> Bool {
        guard !creditedPackTransactionIDs.contains(transactionID),
              !revokedPackTransactionIDs.contains(transactionID) else { return false }
        creditedPackTransactionIDs.insert(transactionID)
        return true
    }

    /// Applies a refunded or revoked pack: 15 credits fewer, never below 0. Spending more than
    /// is bought now would leave a debt that swallows the next pack; the debt is forgiven.
    /// Returns false when this revocation was already applied.
    @discardableResult
    mutating func revokePack(transactionID: UInt64, historyPackIDs: Set<UInt64>?) -> Bool {
        guard !revokedPackTransactionIDs.contains(transactionID) else { return false }
        revokedPackTransactionIDs.insert(transactionID)
        let bought = validPacks(historyPackIDs: historyPackIDs).count * ProductID.creditsPerPack
        let debt = effectiveSpent - bought
        if debt > 0 {
            let key = String(transactionID)
            forgivenByRevokedPack[key] = max(forgivenByRevokedPack[key] ?? 0, debt)
        }
        return true
    }

    /// Spends one purchased credit on this device.
    mutating func spendOne(deviceID: String) {
        spentByDevice[deviceID, default: 0] += 1
    }

    /// The record that holds everything either side has seen. Commutative, associative and
    /// idempotent, so devices can merge in any order and any number of times.
    func merged(with other: MonetizationPurchasedRecord) -> MonetizationPurchasedRecord {
        var result = self
        result.version = max(version, other.version)
        result.spentByDevice.merge(other.spentByDevice, uniquingKeysWith: max)
        result.creditedPackTransactionIDs.formUnion(other.creditedPackTransactionIDs)
        result.revokedPackTransactionIDs.formUnion(other.revokedPackTransactionIDs)
        result.forgivenByRevokedPack.merge(other.forgivenByRevokedPack, uniquingKeysWith: max)
        return result
    }

    /// True when `other` holds nothing this record lacks.
    func contains(_ other: MonetizationPurchasedRecord) -> Bool {
        merged(with: other) == self
    }
}
