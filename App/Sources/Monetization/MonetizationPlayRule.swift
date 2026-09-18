// Whether a board edit is a move in a game rather than a fix of misread squares
// (monetization.md section 5). Pure and synchronous: it runs inside `authorize` on the main
// actor for up to 20 paid boards, so it must stay well under 10 ms in the worst case.

/// Decides whether a new piece placement follows from a paid placement by legal play.
///
/// A board within 3 squares of a paid board stays free only when every square it changes is one
/// that paid board allows to change (`MonetizationFreeEdit`) and the change cannot be explained
/// by 1 to `maximumPlies` legal plies from that paid board, with either side moving first. The paid board is only a placement, so castling and en passant rights are unknown:
/// the search grants every castling right whose king and rook stand on their home squares, and
/// allows a first-ply en passant capture wherever the enemy pawn could just have made a double
/// step (it stands beside the capturing pawn, and both squares it passed are empty). After the
/// first ply, rights change as in a game. The rights of the new board are never compared.
///
/// Legal means legal chess: a move never leaves any king of the mover attacked, castling never
/// starts in, passes through or ends in check, and a side whose opponent's king is already
/// attacked cannot be the side to move. A side without a king has no check to respect.
///
/// This type answers only whether play reaches the board. Whether that costs a credit is
/// `MonetizationCreditPolicy.paidBoard(_:covers:)`, which keeps two edits free even where play
/// reaches them (owner decisions, 2026-09-17): a board that takes exactly one piece off the paid
/// board, and one that moves a single piece to a square that was empty on it, both changing
/// nothing else.
enum MonetizationPlayRule {
    /// The longest sequence of plies that makes an edit cost a credit.
    static let maximumPlies = 3

    /// True when `board` is the placement after 1 to `maximumPlies` legal plies from `paid`,
    /// with either side moving first. Identical placements, and placements that are not 64
    /// squares of FEN letters and ".", are never reachable.
    static func isReachableByPlay(from paid: MonetizationBoardKey, to board: MonetizationBoardKey) -> Bool {
        guard let start = MonetizationPlaySearch.decode(paid.squares),
              let goal = MonetizationPlaySearch.decode(board.squares) else { return false }
        return MonetizationPlaySearch.isReachable(from: start, to: goal)
    }
}

/// The search behind `MonetizationPlayRule`.
///
/// Squares are `Square.index` (a1 = 0, h8 = 63). Pieces are signed codes: 1 pawn, 2 knight,
/// 3 bishop, 4 rook, 5 queen, 6 king, positive for White, negative for Black, 0 for an empty
/// square. A side is +1 (White) or -1 (Black), so `piece * side > 0` means "own piece".
///
/// Pruning keeps the search exact (the tests compare it with plain move generation):
/// - Every square the last ply touches changes, so that ply must touch exactly the squares that
///   still differ from the goal, starting from one of them (`searchLastPly`).
/// - With two plies left (side X, then side Y), a differing square whose goal piece is X's can
///   only be filled by X's ply, which must bring exactly that piece there. Without such a square,
///   X's ply must start on a differing square whose goal is empty: any other start square would
///   need Y's ply to fill it and also to undo X's arrival square, which one ply cannot do. A
///   square holding X's piece that must end empty can only be emptied by X's own ply, so there
///   is at most one such square, or two when X castles (`searchTwoPlies`).
/// - When the second ply's side must bring a piece it has nowhere near, the search for that
///   order of sides ends before generating anything.
/// - Only the first ply is generated in full, and a ply's legality is checked only once a
///   continuation exists. A first ply that touches no differing square is skipped when it
///   cannot work: when the other side has nothing to bring or take away and the ply captures
///   nothing, or, for a side that cannot castle, when its last ply could not both refill the
///   first ply's start square and do this side's remaining work (`searchFirstPly`).
struct MonetizationPlaySearch {
    private enum MoveKind {
        case normal
        case doublePush
        case enPassant
        case castle
    }

    private struct Move {
        var from: Int
        var to: Int
        /// The piece on `to` afterwards (the promoted piece for a promotion).
        var arriving: Int8
        var kind: MoveKind
    }

    /// The squares a move changed and what they held, to take the move back.
    private struct Undo {
        var squares: (Int, Int, Int, Int) = (0, 0, 0, 0)
        var pieces: (Int8, Int8, Int8, Int8) = (0, 0, 0, 0)
        var count = 0
        var castling: UInt8
        var enPassant: Int
    }

    private static let pawn: Int8 = 1
    private static let knight: Int8 = 2
    private static let bishop: Int8 = 3
    private static let rook: Int8 = 4
    private static let queen: Int8 = 5
    private static let king: Int8 = 6

    private var board: [Int8]
    private let goal: [Int8]
    /// Bit `i` is set while `board[i] != goal[i]`.
    private var differing: UInt64 = 0
    private var whitePieces: UInt64 = 0
    private var blackPieces: UInt64 = 0
    private var whiteKings: UInt64 = 0
    private var blackKings: UInt64 = 0
    /// 1 White kingside, 2 White queenside, 4 Black kingside, 8 Black queenside.
    private var castling: UInt8 = 0
    /// The square a double push just passed over, or -1.
    private var enPassant = -1
    private var buffers: [[Move]] = [[], [], []]

    private init(board: [Int8], goal: [Int8]) {
        self.board = board
        self.goal = goal
        for square in 0..<64 {
            let bit: UInt64 = 1 << UInt64(square)
            let piece = board[square]
            if piece != goal[square] { differing |= bit }
            if piece > 0 { whitePieces |= bit }
            if piece < 0 { blackPieces |= bit }
            if piece == Self.king { whiteKings |= bit }
            if piece == -Self.king { blackKings |= bit }
        }
    }

    // MARK: Entry

    /// The signed piece codes of a `MonetizationBoardKey` placement, or nil when it is not 64
    /// squares of FEN piece letters and ".".
    static func decode(_ squares: String) -> [Int8]? {
        var result: [Int8] = []
        result.reserveCapacity(64)
        for byte in squares.utf8 {
            let code: Int8
            switch byte {
            case UInt8(ascii: "."): code = 0
            case UInt8(ascii: "P"): code = 1
            case UInt8(ascii: "N"): code = 2
            case UInt8(ascii: "B"): code = 3
            case UInt8(ascii: "R"): code = 4
            case UInt8(ascii: "Q"): code = 5
            case UInt8(ascii: "K"): code = 6
            case UInt8(ascii: "p"): code = -1
            case UInt8(ascii: "n"): code = -2
            case UInt8(ascii: "b"): code = -3
            case UInt8(ascii: "r"): code = -4
            case UInt8(ascii: "q"): code = -5
            case UInt8(ascii: "k"): code = -6
            default: return nil
            }
            guard result.count < 64 else { return nil }
            result.append(code)
        }
        return result.count == 64 ? result : nil
    }

    static func isReachable(from start: [Int8], to goal: [Int8]) -> Bool {
        guard start.count == 64, goal.count == 64 else { return false }
        var changed = 0
        for square in 0..<64 where start[square] != goal[square] {
            changed += 1
        }
        // Each ply changes 2 to 4 squares, and the result is never the paid board itself.
        guard changed > 0, changed <= 4 * MonetizationPlayRule.maximumPlies else { return false }
        var search = MonetizationPlaySearch(board: start, goal: goal)
        if search.searchFirstPly(side: 1) { return true }
        // A failed search takes every move back, so the same board serves the other side.
        return search.searchFirstPly(side: -1)
    }

    // MARK: Search

    private mutating func searchFirstPly(side: Int8) -> Bool {
        // A position in which the other side's king is attacked cannot have `side` to move.
        guard kingsAreSafe(-side) else { return false }
        castling = inferredCastlingRights()
        enPassant = -1
        guard otherSideCanBringItsPieces(side: -side) else { return false }
        var moves = takeBuffer(0)
        defer { returnBuffer(moves, 0) }
        var pieces = side > 0 ? whitePieces : blackPieces
        while pieces != 0 {
            let square = pieces.trailingZeroBitCount
            pieces &= pieces - 1
            generateMoves(from: square, side: side, anyEnPassant: true, into: &moves)
        }
        // After this ply the other side's single ply needs work: a piece of its own to bring
        // (`searchTwoPlies`) or to take away. Without such a square already, only a capture
        // creates one, and only a ply starting on a differing square can finish at once.
        let needsOtherSide = otherSideHasWork(side: -side)
        // A ply that touches no differing square leaves its start square to be refilled by this
        // side's only later ply (unless that ply castles, with two arrivals and two starts). That
        // ply then cannot bring a piece this side still owes elsewhere, and it can take away at
        // most one piece this side must lose: from that square, and of the kind it refills. Its
        // arrival square is then left for the other side's ply to undo, which only a recapture
        // (or an en passant capture of a double push) can do.
        let home = side > 0 ? 4 : 60
        var castlingArrivals: UInt64 = 0
        if castling & (side > 0 ? 1 : 4) != 0 { castlingArrivals |= 1 << UInt64(home + 1) | 1 << UInt64(home + 2) }
        if castling & (side > 0 ? 2 : 8) != 0 { castlingArrivals |= 1 << UInt64(home - 1) | 1 << UInt64(home - 2) }
        let owesPiece = ownGoalExists(side: side)
        let (emptiedCount, emptiedSquare) = ownEmptiedSquares(side: side)
        let lastRank = side > 0 ? 7 : 0
        for move in moves {
            if !needsOtherSide, differing & (1 << UInt64(move.from)) == 0,
               move.kind != .enPassant, board[move.to] == 0 { continue }
            let touches = differing & (1 << UInt64(move.from) | 1 << UInt64(move.to)) != 0
                || (move.kind == .enPassant && differing & (1 << UInt64(move.to - 8 * Int(side))) != 0)
            // Only a castling last ply that arrives on this ply's start square is the exception.
            if !touches, castlingArrivals & (1 << UInt64(move.from)) == 0 {
                if owesPiece || emptiedCount > 1 { continue }
                if emptiedCount == 1 {
                    let refills = board[emptiedSquare] == board[move.from]
                        || (board[emptiedSquare] == Self.pawn * side && move.from >> 3 == lastRank)
                    guard refills, move.kind != .castle, move.kind == .doublePush || board[move.to] != 0 else { continue }
                }
            }
            let undo = make(move, side: side)
            if differing == 0 ? kingsAreSafe(side) : searchTwoPlies(side: -side) {
                return true
            }
            unmake(undo)
        }
        return false
    }

    /// With `side` to play exactly one ply (the second), every differing square that wants a
    /// piece of `side` must receive it from that ply. The first ply cannot move or create pieces
    /// of `side`, so a piece of the wanted kind must already stand where it could arrive: a knight
    /// or king step away, on a line for a bishop, rook or queen (blockers ignored, since the first
    /// ply may clear them), behind for a pawn, or a pawn one step from promoting. False when some
    /// such square has no candidate.
    private func otherSideCanBringItsPieces(side: Int8) -> Bool {
        var bits = differing
        while bits != 0 {
            let square = bits.trailingZeroBitCount
            bits &= bits - 1
            let wanted = goal[square]
            guard wanted * side > 0 else { continue }
            if !hasCandidate(bringing: wanted, to: square, side: side) { return false }
        }
        return true
    }

    private func hasCandidate(bringing piece: Int8, to square: Int, side: Int8) -> Bool {
        let file = square & 7
        let rank = square >> 3
        let pawn = Self.pawn * side
        let forward = 8 * Int(side)
        let behind = square - forward
        func pawnBehind() -> Bool {
            guard (0..<64).contains(behind) else { return false }
            if board[behind] == pawn { return true }
            for fileStep in stride(from: -1, through: 1, by: 2) where (0...7).contains(file + fileStep) && board[behind + fileStep] == pawn {
                return true
            }
            let start = behind - forward
            return (0..<64).contains(start) && board[start] == pawn
        }
        func onLine(_ directions: Range<Int>) -> Bool {
            for direction in directions {
                let start = (square * 8 + direction) * 7
                for index in start..<start + Tables.rayCounts[square * 8 + direction] where board[Tables.raySquares[index]] == piece {
                    return true
                }
            }
            return false
        }
        let lastRank = side > 0 ? 7 : 0
        let promotion = rank == lastRank && pawnBehind()
        switch piece * side {
        case Self.pawn:
            return pawnBehind()
        case Self.knight:
            for index in square * 8..<square * 8 + Tables.knightCounts[square] where board[Tables.knightTargets[index]] == piece {
                return true
            }
            return promotion
        case Self.bishop:
            return onLine(4..<8) || promotion
        case Self.rook:
            // Castling brings the rook next to the king's home square.
            let home = side > 0 ? 4 : 60
            return onLine(0..<4) || promotion || ((square == home + 1 || square == home - 1) && board[home] == Self.king * side)
        case Self.queen:
            return onLine(0..<8) || promotion
        case Self.king:
            for index in square * 8..<square * 8 + Tables.kingCounts[square] where board[Tables.kingTargets[index]] == piece {
                return true
            }
            let home = side > 0 ? 4 : 60
            return (square == home + 2 || square == home - 2) && board[home] == piece
        default:
            return true
        }
    }

    /// How many differing squares hold a piece of `side` and must end empty, and one of them.
    private func ownEmptiedSquares(side: Int8) -> (count: Int, square: Int) {
        var count = 0
        var found = -1
        var bits = differing
        while bits != 0 {
            let square = bits.trailingZeroBitCount
            bits &= bits - 1
            if goal[square] == 0, board[square] * side > 0 {
                count += 1
                found = square
            }
        }
        return (count, found)
    }

    /// True when a differing square wants a piece of `side`.
    private func ownGoalExists(side: Int8) -> Bool {
        var bits = differing
        while bits != 0 {
            let square = bits.trailingZeroBitCount
            bits &= bits - 1
            if goal[square] * side > 0 { return true }
        }
        return false
    }

    /// True when a differing square wants a piece of `side` or must lose one of its pieces.
    private func otherSideHasWork(side: Int8) -> Bool {
        var bits = differing
        while bits != 0 {
            let square = bits.trailingZeroBitCount
            bits &= bits - 1
            let wanted = goal[square]
            if wanted * side > 0 || (wanted == 0 && board[square] * side > 0) { return true }
        }
        return false
    }

    /// `side` plays one ply, and the other side may play one more. The ply before (by the other
    /// side) is checked for legality here, once a continuation exists.
    private mutating func searchTwoPlies(side: Int8) -> Bool {
        let remaining = differing
        guard remaining.nonzeroBitCount <= 8 else { return false }
        // What the differing squares need: a piece of this side or the other brought in, or a
        // piece of this side or the other taken away. This side's pieces can only be taken away
        // by this side's own ply (the other side's ply could only capture them, which leaves a
        // piece), and each side brings or takes away one piece, two when castling.
        var ownGoal = -1, ownGoalCount = 0, otherGoalCount = 0
        var ownEmptied = -1, ownEmptiedCount = 0, otherEmptiedCount = 0
        var bits = remaining
        while bits != 0 {
            let square = bits.trailingZeroBitCount
            bits &= bits - 1
            let wanted = goal[square]
            if wanted == 0 {
                if board[square] * side > 0 {
                    ownEmptiedCount += 1
                    ownEmptied = square
                } else {
                    otherEmptiedCount += 1
                }
            } else if wanted * side > 0 {
                ownGoalCount += 1
                ownGoal = square
            } else {
                otherGoalCount += 1
            }
        }
        // (The other side can also lose a pawn to this side's en passant capture before castling.)
        guard ownGoalCount <= 2, otherGoalCount <= 2, ownEmptiedCount <= 2, otherEmptiedCount <= 3 else { return false }

        var moves = takeBuffer(1)
        defer { returnBuffer(moves, 1) }
        if ownGoalCount == 2 || ownEmptiedCount == 2 {
            generateCastling(side: side, into: &moves)
        } else if ownGoal >= 0 {
            // Only this side's ply can bring this side's piece: exactly that piece arrives.
            generateMoves(to: ownGoal, arriving: goal[ownGoal], side: side, into: &moves)
        } else if ownEmptied >= 0 {
            // Otherwise the ply starts on a square that must end empty (see the type comment).
            generateMoves(from: ownEmptied, side: side, anyEnPassant: false, into: &moves)
        }
        guard !moves.isEmpty, kingsAreSafe(-side) else { return false }
        let bringsOwnGoal = ownGoal >= 0
        for move in moves {
            if move.kind != .castle {
                if bringsOwnGoal {
                    // The square left behind must end empty or get the other side's piece.
                    if goal[move.from] * side > 0 { continue }
                } else if !(goal[move.to] * side < 0 || (goal[move.to] == 0 && move.kind == .doublePush)) {
                    // The arrival square wants no piece of this side, so the other side's last
                    // ply must capture there (or take the pawn en passant).
                    continue
                }
            }
            let undo = make(move, side: side)
            if differing == 0 ? kingsAreSafe(side) : searchLastPly(side: -side) {
                return true
            }
            unmake(undo)
        }
        return false
    }

    /// `side` plays the last ply. The ply before (by the other side) is checked for legality
    /// here, once a candidate exists.
    private mutating func searchLastPly(side: Int8) -> Bool {
        let remaining = differing
        guard (2...4).contains(remaining.nonzeroBitCount) else { return false }
        var starts: UInt64 = 0
        var bits = remaining
        while bits != 0 {
            let square = bits.trailingZeroBitCount
            bits &= bits - 1
            // The last ply cannot bring a piece of the other side.
            if goal[square] * side < 0 { return false }
            if board[square] * side > 0 { starts |= 1 << UInt64(square) }
        }
        guard starts != 0 else { return false }
        var moves = takeBuffer(2)
        defer { returnBuffer(moves, 2) }
        while starts != 0 {
            let square = starts.trailingZeroBitCount
            starts &= starts - 1
            generateMoves(from: square, side: side, anyEnPassant: false, into: &moves)
        }
        var checkedPreviousPly = false
        for move in moves where remaining & (1 << UInt64(move.to)) != 0 {
            if !checkedPreviousPly {
                guard kingsAreSafe(-side) else { return false }
                checkedPreviousPly = true
            }
            let undo = make(move, side: side)
            if differing == 0, kingsAreSafe(side) { return true }
            unmake(undo)
        }
        return false
    }

    /// Move lists are reused across the search, one per ply, so the search does not allocate
    /// once they have grown.
    private mutating func takeBuffer(_ ply: Int) -> [Move] {
        var buffer: [Move] = []
        swap(&buffer, &buffers[ply])
        buffer.removeAll(keepingCapacity: true)
        return buffer
    }

    private mutating func returnBuffer(_ buffer: [Move], _ ply: Int) {
        buffers[ply] = buffer
    }

    // MARK: Board changes

    private mutating func set(_ square: Int, _ piece: Int8) {
        let bit: UInt64 = 1 << UInt64(square)
        let old = board[square]
        board[square] = piece
        if piece == goal[square] { differing &= ~bit } else { differing |= bit }
        if old > 0 { whitePieces &= ~bit } else if old < 0 { blackPieces &= ~bit }
        if piece > 0 { whitePieces |= bit } else if piece < 0 { blackPieces |= bit }
        if old == Self.king { whiteKings &= ~bit } else if old == -Self.king { blackKings &= ~bit }
        if piece == Self.king { whiteKings |= bit } else if piece == -Self.king { blackKings |= bit }
    }

    private mutating func make(_ move: Move, side: Int8) -> Undo {
        var undo = Undo(castling: castling, enPassant: enPassant)
        undo.squares.0 = move.to
        undo.pieces.0 = board[move.to]
        set(move.to, move.arriving)
        undo.squares.1 = move.from
        undo.pieces.1 = board[move.from]
        set(move.from, 0)
        undo.count = 2
        switch move.kind {
        case .normal, .doublePush:
            break
        case .enPassant:
            let victim = move.to - 8 * Int(side)
            undo.squares.2 = victim
            undo.pieces.2 = board[victim]
            set(victim, 0)
            undo.count = 3
        case .castle:
            let (rookFrom, rookTo) = move.to > move.from ? (move.from + 3, move.from + 1) : (move.from - 4, move.from - 1)
            undo.squares.2 = rookTo
            undo.pieces.2 = board[rookTo]
            set(rookTo, Self.rook * side)
            undo.squares.3 = rookFrom
            undo.pieces.3 = board[rookFrom]
            set(rookFrom, 0)
            undo.count = 4
        }
        castling &= Self.castlingMask(move.from) & Self.castlingMask(move.to)
        enPassant = move.kind == .doublePush ? (move.from + move.to) / 2 : -1
        return undo
    }

    private mutating func unmake(_ undo: Undo) {
        if undo.count > 3 { set(undo.squares.3, undo.pieces.3) }
        if undo.count > 2 { set(undo.squares.2, undo.pieces.2) }
        set(undo.squares.1, undo.pieces.1)
        set(undo.squares.0, undo.pieces.0)
        castling = undo.castling
        enPassant = undo.enPassant
    }

    /// The castling rights a move from or to `square` keeps.
    private static func castlingMask(_ square: Int) -> UInt8 {
        switch square {
        case 0: ~2
        case 4: ~3
        case 7: ~1
        case 56: ~8
        case 60: ~12
        case 63: ~4
        default: 0xFF
        }
    }

    private func inferredCastlingRights() -> UInt8 {
        var rights: UInt8 = 0
        if board[4] == Self.king {
            if board[7] == Self.rook { rights |= 1 }
            if board[0] == Self.rook { rights |= 2 }
        }
        if board[60] == -Self.king {
            if board[63] == -Self.rook { rights |= 4 }
            if board[56] == -Self.rook { rights |= 8 }
        }
        return rights
    }

    // MARK: Attacks

    /// True when no king of `side` is attacked.
    private func kingsAreSafe(_ side: Int8) -> Bool {
        var kings = side > 0 ? whiteKings : blackKings
        while kings != 0 {
            let square = kings.trailingZeroBitCount
            kings &= kings - 1
            if isAttacked(square, by: -side) { return false }
        }
        return true
    }

    private func isAttacked(_ square: Int, by side: Int8) -> Bool {
        let file = square & 7
        let rank = square >> 3
        let pawn = Self.pawn * side
        if side > 0 {
            if rank > 0 {
                if file > 0, board[square - 9] == pawn { return true }
                if file < 7, board[square - 7] == pawn { return true }
            }
        } else if rank < 7 {
            if file > 0, board[square + 7] == pawn { return true }
            if file < 7, board[square + 9] == pawn { return true }
        }
        let knight = Self.knight * side
        for index in square * 8..<square * 8 + Tables.knightCounts[square] where board[Tables.knightTargets[index]] == knight {
            return true
        }
        let king = Self.king * side
        for index in square * 8..<square * 8 + Tables.kingCounts[square] where board[Tables.kingTargets[index]] == king {
            return true
        }
        let rook = Self.rook * side, bishop = Self.bishop * side, queen = Self.queen * side
        for direction in 0..<8 {
            let start = (square * 8 + direction) * 7
            for index in start..<start + Tables.rayCounts[square * 8 + direction] {
                let piece = board[Tables.raySquares[index]]
                if piece == 0 { continue }
                if piece == queen || piece == (direction < 4 ? rook : bishop) { return true }
                break
            }
        }
        return false
    }

    // MARK: Move generation (pseudo-legal; legality is checked after making the move)

    /// Every move of the piece on `square`. `anyEnPassant` allows an en passant capture of any
    /// enemy pawn that could just have made a double step (first ply only).
    private func generateMoves(from square: Int, side: Int8, anyEnPassant: Bool, into moves: inout [Move]) {
        let piece = board[square]
        switch piece * side {
        case Self.pawn:
            generatePawnMoves(from: square, side: side, anyEnPassant: anyEnPassant, into: &moves)
        case Self.knight:
            for index in square * 8..<square * 8 + Tables.knightCounts[square] {
                addStep(from: square, to: Tables.knightTargets[index], piece: piece, side: side, into: &moves)
            }
        case Self.bishop:
            addSlides(from: square, directions: 4..<8, piece: piece, side: side, into: &moves)
        case Self.rook:
            addSlides(from: square, directions: 0..<4, piece: piece, side: side, into: &moves)
        case Self.queen:
            addSlides(from: square, directions: 0..<8, piece: piece, side: side, into: &moves)
        case Self.king:
            for index in square * 8..<square * 8 + Tables.kingCounts[square] {
                addStep(from: square, to: Tables.kingTargets[index], piece: piece, side: side, into: &moves)
            }
            generateCastling(side: side, into: &moves)
        default:
            break
        }
    }

    private func addStep(from square: Int, to target: Int, piece: Int8, side: Int8, into moves: inout [Move]) {
        let occupant = board[target]
        guard occupant * side <= 0, occupant != -Self.king * side else { return }
        moves.append(Move(from: square, to: target, arriving: piece, kind: .normal))
    }

    private func addSlides(from square: Int, directions: Range<Int>, piece: Int8, side: Int8, into moves: inout [Move]) {
        for direction in directions {
            let start = (square * 8 + direction) * 7
            for index in start..<start + Tables.rayCounts[square * 8 + direction] {
                let target = Tables.raySquares[index]
                let occupant = board[target]
                if occupant == 0 {
                    moves.append(Move(from: square, to: target, arriving: piece, kind: .normal))
                    continue
                }
                if occupant * side < 0, occupant != -Self.king * side {
                    moves.append(Move(from: square, to: target, arriving: piece, kind: .normal))
                }
                break
            }
        }
    }

    private func generatePawnMoves(from square: Int, side: Int8, anyEnPassant: Bool, into moves: inout [Move]) {
        let forward = 8 * Int(side)
        let file = square & 7
        let rank = square >> 3
        let one = square + forward
        guard (0..<64).contains(one) else { return }
        if board[one] == 0 {
            addPawnArrival(from: square, to: one, side: side, into: &moves)
            let startRank = side > 0 ? 1 : 6
            if rank == startRank, board[one + forward] == 0 {
                moves.append(Move(from: square, to: one + forward, arriving: Self.pawn * side, kind: .doublePush))
            }
        }
        for fileStep in stride(from: -1, through: 1, by: 2) where (0...7).contains(file + fileStep) {
            let target = one + fileStep
            let occupant = board[target]
            if occupant * side < 0 {
                if occupant != -Self.king * side {
                    addPawnArrival(from: square, to: target, side: side, into: &moves)
                }
                continue
            }
            guard occupant == 0, board[square + fileStep] == -Self.pawn * side else { continue }
            let victimJustMoved = target == enPassant
            // The captured pawn passed over `target` from the square beyond it.
            let victimCouldHaveMoved = anyEnPassant && rank == (side > 0 ? 4 : 3) && board[target + forward] == 0
            if victimJustMoved || victimCouldHaveMoved {
                moves.append(Move(from: square, to: target, arriving: Self.pawn * side, kind: .enPassant))
            }
        }
    }

    /// A pawn move onto `target`, as the four promotions when it reaches the last rank.
    private func addPawnArrival(from square: Int, to target: Int, side: Int8, into moves: inout [Move]) {
        if target >> 3 == (side > 0 ? 7 : 0) {
            for kind in [Self.queen, Self.rook, Self.bishop, Self.knight] {
                moves.append(Move(from: square, to: target, arriving: kind * side, kind: .normal))
            }
        } else {
            moves.append(Move(from: square, to: target, arriving: Self.pawn * side, kind: .normal))
        }
    }

    private func generateCastling(side: Int8, into moves: inout [Move]) {
        let home = side > 0 ? 4 : 60
        let kingside: UInt8 = side > 0 ? 1 : 4
        let queenside: UInt8 = side > 0 ? 2 : 8
        guard castling & (kingside | queenside) != 0, board[home] == Self.king * side,
              !isAttacked(home, by: -side) else { return }
        let rook = Self.rook * side
        if castling & kingside != 0, board[home + 3] == rook, board[home + 1] == 0, board[home + 2] == 0,
           !isAttacked(home + 1, by: -side), !isAttacked(home + 2, by: -side) {
            moves.append(Move(from: home, to: home + 2, arriving: Self.king * side, kind: .castle))
        }
        if castling & queenside != 0, board[home - 4] == rook, board[home - 1] == 0, board[home - 2] == 0,
           board[home - 3] == 0, !isAttacked(home - 1, by: -side), !isAttacked(home - 2, by: -side) {
            moves.append(Move(from: home, to: home - 2, arriving: Self.king * side, kind: .castle))
        }
    }

    /// Every move of `side` after which `arriving` stands on `square`.
    private func generateMoves(to square: Int, arriving: Int8, side: Int8, into moves: inout [Move]) {
        let occupant = board[square]
        guard occupant * side <= 0, occupant != -Self.king * side, arriving * side > 0 else { return }
        let forward = 8 * Int(side)
        let file = square & 7
        let rank = square >> 3
        let lastRank = side > 0 ? 7 : 0
        let behind = square - forward

        switch arriving * side {
        case Self.pawn:
            guard rank != lastRank, (0..<64).contains(behind) else { return }
            if occupant == 0 {
                if board[behind] == Self.pawn * side {
                    moves.append(Move(from: behind, to: square, arriving: arriving, kind: .normal))
                } else if board[behind] == 0 {
                    let start = behind - forward
                    if (0..<64).contains(start), start >> 3 == (side > 0 ? 1 : 6), board[start] == Self.pawn * side {
                        moves.append(Move(from: start, to: square, arriving: arriving, kind: .doublePush))
                    }
                }
                if square == enPassant, board[behind] == -Self.pawn * side {
                    for fileStep in stride(from: -1, through: 1, by: 2) where (0...7).contains(file + fileStep) && board[behind + fileStep] == Self.pawn * side {
                        moves.append(Move(from: behind + fileStep, to: square, arriving: arriving, kind: .enPassant))
                    }
                }
            } else {
                for fileStep in stride(from: -1, through: 1, by: 2) where (0...7).contains(file + fileStep) && board[behind + fileStep] == Self.pawn * side {
                    moves.append(Move(from: behind + fileStep, to: square, arriving: arriving, kind: .normal))
                }
            }
            return
        case Self.knight:
            for index in square * 8..<square * 8 + Tables.knightCounts[square] where board[Tables.knightTargets[index]] == arriving {
                moves.append(Move(from: Tables.knightTargets[index], to: square, arriving: arriving, kind: .normal))
            }
        case Self.bishop:
            addSlideOrigins(to: square, directions: 4..<8, arriving: arriving, into: &moves)
        case Self.rook:
            addSlideOrigins(to: square, directions: 0..<4, arriving: arriving, into: &moves)
            var castles: [Move] = []
            generateCastling(side: side, into: &castles)
            for castle in castles where (castle.to > castle.from ? castle.from + 1 : castle.from - 1) == square {
                moves.append(castle)
            }
        case Self.queen:
            addSlideOrigins(to: square, directions: 0..<8, arriving: arriving, into: &moves)
        case Self.king:
            for index in square * 8..<square * 8 + Tables.kingCounts[square] where board[Tables.kingTargets[index]] == arriving {
                moves.append(Move(from: Tables.kingTargets[index], to: square, arriving: arriving, kind: .normal))
            }
            var castles: [Move] = []
            generateCastling(side: side, into: &castles)
            moves.append(contentsOf: castles.filter { $0.to == square })
            return
        default:
            return
        }
        // A promotion also brings a knight, bishop, rook or queen.
        guard rank == lastRank, (0..<64).contains(behind) else { return }
        let pawn = Self.pawn * side
        if occupant == 0 {
            if board[behind] == pawn {
                moves.append(Move(from: behind, to: square, arriving: arriving, kind: .normal))
            }
        } else {
            for fileStep in stride(from: -1, through: 1, by: 2) where (0...7).contains(file + fileStep) && board[behind + fileStep] == pawn {
                moves.append(Move(from: behind + fileStep, to: square, arriving: arriving, kind: .normal))
            }
        }
    }

    private func addSlideOrigins(to square: Int, directions: Range<Int>, arriving: Int8, into moves: inout [Move]) {
        for direction in directions {
            let start = (square * 8 + direction) * 7
            for index in start..<start + Tables.rayCounts[square * 8 + direction] {
                let origin = Tables.raySquares[index]
                let piece = board[origin]
                if piece == 0 { continue }
                if piece == arriving {
                    moves.append(Move(from: origin, to: square, arriving: arriving, kind: .normal))
                }
                break
            }
        }
    }

    // MARK: Tables

    /// Flat lookup tables (nested arrays cost a reference count per lookup).
    private enum Tables {
        /// Knight targets of `square` at `square * 8 ..< square * 8 + knightCounts[square]`.
        static let knightTargets = steps([(1, 2), (2, 1), (2, -1), (1, -2), (-1, -2), (-2, -1), (-2, 1), (-1, 2)])
        static let knightCounts = counts(knightTargets)
        /// King targets of `square` at `square * 8 ..< square * 8 + kingCounts[square]`.
        static let kingTargets = steps([(1, 0), (1, 1), (0, 1), (-1, 1), (-1, 0), (-1, -1), (0, -1), (1, -1)])
        static let kingCounts = counts(kingTargets)
        /// The squares from `square` in `direction`, nearest first, at
        /// `(square * 8 + direction) * 7 ..< ... + rayCounts[square * 8 + direction]`.
        /// Directions 0-3 run along ranks and files, 4-7 along diagonals.
        static let raySquares: [Int] = (0..<64).flatMap { square in
            [(1, 0), (0, 1), (-1, 0), (0, -1), (1, 1), (-1, 1), (-1, -1), (1, -1)].flatMap { step in
                var result: [Int] = []
                var file = (square & 7) + step.0
                var rank = (square >> 3) + step.1
                while (0...7).contains(file), (0...7).contains(rank) {
                    result.append(rank * 8 + file)
                    file += step.0
                    rank += step.1
                }
                return result + [Int](repeating: -1, count: 7 - result.count)
            }
        }
        static let rayCounts: [Int] = stride(from: 0, to: 64 * 8 * 7, by: 7).map { start in
            (start..<start + 7).filter { raySquares[$0] >= 0 }.count
        }

        private static func steps(_ steps: [(Int, Int)]) -> [Int] {
            (0..<64).flatMap { square in
                let targets = steps.compactMap { step -> Int? in
                    let file = (square & 7) + step.0
                    let rank = (square >> 3) + step.1
                    return (0...7).contains(file) && (0...7).contains(rank) ? rank * 8 + file : nil
                }
                return targets + [Int](repeating: -1, count: 8 - targets.count)
            }
        }

        private static func counts(_ table: [Int]) -> [Int] {
            stride(from: 0, to: 64 * 8, by: 8).map { start in (start..<start + 8).filter { table[$0] >= 0 }.count }
        }
    }
}
