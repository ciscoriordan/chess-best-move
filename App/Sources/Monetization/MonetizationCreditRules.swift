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

    /// The indices (`Square.index`) whose content differs. Squares past the end of either
    /// board (never produced by the app) count as differing.
    func differingSquares(to other: MonetizationBoardKey) -> [Int] {
        let lhs = Array(squares.utf8)
        let rhs = Array(other.squares.utf8)
        var indices: [Int] = []
        for index in 0..<max(lhs.count, rhs.count) where index >= min(lhs.count, rhs.count) || lhs[index] != rhs[index] {
            indices.append(index)
        }
        return indices
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

    /// True when this board is `other` with exactly one piece moved to a square that was empty
    /// on `other`, the piece keeping its kind and color, and nothing else changed
    /// (monetization.md section 5, the misread-placement fix; owner decision, 2026-09-17).
    ///
    /// A capture is never this shape: its destination held a piece on `other`, so that square
    /// changes from one piece to another and the check fails.
    func movesExactlyOnePieceToAnEmptySquare(from other: MonetizationBoardKey) -> Bool {
        let mine = Array(squares.utf8)
        let theirs = Array(other.squares.utf8)
        guard mine.count == theirs.count else { return false }
        let empty = UInt8(ascii: ".")
        var from: Int?
        var to: Int?
        for index in 0..<mine.count where mine[index] != theirs[index] {
            if mine[index] == empty, theirs[index] != empty {
                guard from == nil else { return false }
                from = index
            } else if mine[index] != empty, theirs[index] == empty {
                guard to == nil else { return false }
                to = index
            } else {
                // One piece replaced another: a capture, or two misread squares at once.
                return false
            }
        }
        guard let from, let to else { return false }
        return theirs[from] == mine[to]
    }
}

// MARK: - Paid boards

/// Which squares of a paid board a later edit may change without paying again (monetization.md
/// section 5, owner decision 2026-09-17).
enum MonetizationFreeEdit: Sendable, Hashable {
    /// Recognition read this board, and these squares (`Square.index`) are the ones it doubted
    /// when the credit was spent, plus the ones that already differed from what it read (the
    /// user had corrected them). Empty when recognition was sure of every square, and for a
    /// board no recognizer read at all: then only the same placement is free.
    case squares(Set<Int>)
    /// Nothing is known about what recognition contributed: a paid board stored before this
    /// rule, or an authorization made without that evidence. Every square counts as free to
    /// change, which is the rule as it stood before 2026-09-17.
    case anySquare

    /// The same squares on a board rotated by 180 degrees (square `i` becomes `63 - i`).
    var rotated: MonetizationFreeEdit {
        switch self {
        case .anySquare: .anySquare
        case .squares(let squares): .squares(Set(squares.map { 63 - $0 }))
        }
    }

    /// True when every one of `changed` may be changed for free.
    func allows(_ changed: [Int]) -> Bool {
        switch self {
        case .anySquare: true
        case .squares(let squares): changed.allSatisfy(squares.contains)
        }
    }
}

/// One remembered paid board: the placement a credit was spent on, and the squares later edits
/// may change for free.
///
/// Stored as `{"squares": "...", "freeEdit": [12, 13]}`. A record written before the doubt-scoped
/// rule has no `freeEdit` key and decodes as `.anySquare`, so boards paid for by an earlier
/// version keep the rule they were paid under. An older app version reading a newer record
/// ignores the extra key and still finds the placement.
struct MonetizationPaidBoard: Codable, Sendable, Hashable {
    let key: MonetizationBoardKey
    let freeEdit: MonetizationFreeEdit

    init(key: MonetizationBoardKey, freeEdit: MonetizationFreeEdit) {
        self.key = key
        self.freeEdit = freeEdit
    }

    private enum CodingKeys: String, CodingKey {
        case squares, freeEdit
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        key = MonetizationBoardKey(squares: try container.decode(String.self, forKey: .squares))
        let stored = (try? container.decodeIfPresent([Int].self, forKey: .freeEdit)) ?? nil
        freeEdit = stored.map { MonetizationFreeEdit.squares(Set($0)) } ?? .anySquare
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(key.squares, forKey: .squares)
        if case .squares(let squares) = freeEdit {
            try container.encode(squares.sorted(), forKey: .freeEdit)
        }
    }
}

/// What recognition contributed to the board an analysis is authorized for, which decides the
/// squares later edits may change for free (`MonetizationFreeEdit`). Nil at the call site for a
/// board no recognizer read: one set up by hand, or one restored from disk for an Ask to Buy
/// approval, which keeps no reading.
struct MonetizationRecognitionEvidence: Sendable, Hashable {
    /// `BoardSnapshot.recognizedBoard`: the pieces as recognized, before any edit.
    let recognizedBoard: [Piece?]?
    /// `BoardSnapshot.lowConfidenceSquares`: the squares recognition still doubts. The editor
    /// takes a square out of this set once the user has changed or confirmed it, and a changed
    /// square is then covered by `recognizedBoard` instead.
    let doubtedSquares: Set<Square>

    init(recognizedBoard: [Piece?]?, doubtedSquares: Set<Square>) {
        self.recognizedBoard = recognizedBoard
        self.doubtedSquares = doubtedSquares
    }

    init(_ snapshot: BoardSnapshot) {
        self.init(recognizedBoard: snapshot.recognizedBoard, doubtedSquares: snapshot.lowConfidenceSquares)
    }

    /// The squares of `board` (the placement being paid for) that later edits may change for
    /// free: the ones recognition doubts, and the ones that already differ from what it read.
    func freeEdit(for board: [Piece?]) -> MonetizationFreeEdit {
        var squares = Set(doubtedSquares.map(\.index))
        if let recognizedBoard, recognizedBoard.count == board.count {
            for index in 0..<board.count where recognizedBoard[index] != board[index] {
                squares.insert(index)
            }
        }
        return .squares(squares)
    }
}

// MARK: - Decisions

enum MonetizationCreditPolicy {
    /// True when one of `paidBoards` covers `board` (`paidBoard(_:covers:)`).
    static func isCoveredByPaidBoard(_ board: MonetizationBoardKey, paidBoards: [MonetizationPaidBoard]) -> Bool {
        paidBoards.contains { paidBoard($0, covers: board) }
    }

    /// Whether `paid` makes analyzing `board` free (monetization.md section 5). The count is
    /// always from the paid board, never from the last edit.
    ///
    /// - The same placement, as shown or flipped (square `i` as `63 - i`), is covered.
    /// - A placement within `MonetizationRules.maximumFreeSquareDifference` squares, as shown or
    ///   flipped, is covered only when it is a fix of squares the user may still change for free
    ///   (owner decision, 2026-09-17): every square that differs from the paid board must be one
    ///   recognition doubted when the credit was spent, or one the user had already corrected on
    ///   that board (`MonetizationFreeEdit`). Editing a square the app read and the user left
    ///   alone is never free, which is what stops one credit buying a whole game: pay for the real
    ///   position with one piece deleted, and putting that piece back is free, but the squares the
    ///   next move changes are squares the app read.
    /// - Within that scope, a change counts as a fix unless 1 to 3 legal plies from the paid board
    ///   explain it (`MonetizationPlayRule`), with two exceptions that are fixes whatever play
    ///   could also produce them (owner decisions, 2026-09-17):
    ///   - exactly one piece taken off and nothing else changed (the vanished-piece fix), and
    ///   - exactly one piece moved to a square that was empty on the paid board, keeping its kind
    ///     and color (the misread-placement fix), which needs both squares to be free to change,
    ///     so it never turns following a game into a free re-analysis. A capture is not this
    ///     shape and still costs.
    /// - Either board may have been read upside down, so each explanation is tried in both
    ///   orientations of the pair: as shown (paid to board, both rotated) and flipped (paid to the
    ///   rotated board, the rotated paid board to board). The free squares turn with the board.
    /// - A paid board stored before this rule carries no record of what recognition contributed
    ///   (`MonetizationFreeEdit.anySquare`) and keeps exactly the rule it was paid under: the
    ///   window, the play rule and the vanished-piece fix, with no scope on which squares may
    ///   change and without the misread-placement fix.
    static func paidBoard(_ paid: MonetizationPaidBoard, covers board: MonetizationBoardKey) -> Bool {
        let key = paid.key
        let asShown = board.squareDifference(to: key)
        let flipped = board.squareDifference(to: key.rotated)
        if asShown == 0 || flipped == 0 { return true }
        let limit = MonetizationRules.maximumFreeSquareDifference
        if asShown <= limit, isFix(of: key, freeEdit: paid.freeEdit, to: board) { return true }
        if flipped <= limit, isFix(of: key.rotated, freeEdit: paid.freeEdit.rotated, to: board) { return true }
        return false
    }

    /// Whether `board` is a free fix of `paid`, for one orientation of the pair. `freeEdit` is
    /// in `paid`'s own frame (`paidBoard(_:covers:)` turns it with the board).
    private static func isFix(of paid: MonetizationBoardKey, freeEdit: MonetizationFreeEdit, to board: MonetizationBoardKey) -> Bool {
        guard freeEdit.allows(board.differingSquares(to: paid)) else { return false }
        if board.removesExactlyOnePiece(from: paid) { return true }
        // The misread-placement fix needs the squares it changes to be ones this board is
        // allowed to change. Where nothing is known about them (a board paid for before the
        // rule), a piece moved to an empty square is an ordinary move and costs.
        if case .squares = freeEdit, board.movesExactlyOnePieceToAnEmptySquare(from: paid) { return true }
        // This pairing may itself have been read upside down, so play is tried both ways up.
        return !(MonetizationPlayRule.isReachableByPlay(from: paid, to: board)
            || MonetizationPlayRule.isReachableByPlay(from: paid.rotated, to: board.rotated))
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
        paidBoards: [MonetizationPaidBoard]
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
    var paidBoards: [MonetizationPaidBoard]
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
        paidBoards: [MonetizationPaidBoard],
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
        paidBoards = (try? container.decodeIfPresent([MonetizationPaidBoard].self, forKey: .paidBoards)) ?? []
        lastDownsellDeclinedAt = try? container.decodeIfPresent(Date.self, forKey: .lastDownsellDeclinedAt)
        deviceID = (try? container.decodeIfPresent(String.self, forKey: .deviceID)) ?? ""
        purchased = (try? container.decodeIfPresent(MonetizationPurchasedRecord.self, forKey: .purchased)) ?? MonetizationPurchasedRecord()
    }

    /// Remembers a board a credit was spent on (or that was analyzed while Pro was active).
    /// Re-paying a remembered placement moves it to the newest position and keeps the squares
    /// of the newest payment as the ones free to change; the oldest board is forgotten beyond
    /// the limit.
    mutating func rememberPaidBoard(_ board: MonetizationPaidBoard) {
        paidBoards.removeAll { $0.key == board.key }
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
