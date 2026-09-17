// Internal bitboard representation, attack tables, fully legal move generation and
// move making. The public `Position` converts to `BoardState` for every query, so none
// of this is exposed.

typealias Bitboard = UInt64

@inline(__always) func bit(_ square: Int) -> Bitboard { 1 &<< UInt64(square) }

// MARK: - Attack tables

enum Tables {
    // Ray directions. The first four increase the square index, the last four decrease it.
    static let north = 0, east = 1, northEast = 2, northWest = 3
    static let south = 4, west = 5, southEast = 6, southWest = 7
    static let directionSteps: [(df: Int, dr: Int)] = [
        (0, 1), (1, 0), (1, 1), (-1, 1),
        (0, -1), (-1, 0), (1, -1), (-1, -1),
    ]

    static let knight: [Bitboard] = (0..<64).map { stepAttacks($0, [(1, 2), (2, 1), (2, -1), (1, -2), (-1, -2), (-2, -1), (-2, 1), (-1, 2)]) }
    static let king: [Bitboard] = (0..<64).map { stepAttacks($0, [(1, 0), (1, 1), (0, 1), (-1, 1), (-1, 0), (-1, -1), (0, -1), (1, -1)]) }
    /// `pawnAttacks[color * 64 + square]`: squares a pawn of that color on that square attacks.
    static let pawnAttacks: [Bitboard] =
        (0..<64).map { stepAttacks($0, [(-1, 1), (1, 1)]) } + (0..<64).map { stepAttacks($0, [(-1, -1), (1, -1)]) }
    /// `rays[direction * 64 + square]`: squares from `square` (exclusive) to the board edge.
    static let rays: [Bitboard] = {
        var result = [Bitboard](repeating: 0, count: 8 * 64)
        for direction in 0..<8 {
            for square in 0..<64 {
                let (df, dr) = directionSteps[direction]
                var file = square & 7 + df, rank = square >> 3 + dr
                var bb: Bitboard = 0
                while (0...7).contains(file), (0...7).contains(rank) {
                    bb |= bit(rank * 8 + file)
                    file += df
                    rank += dr
                }
                result[direction * 64 + square] = bb
            }
        }
        return result
    }()
    /// `between[a * 64 + b]`: squares strictly between two aligned squares, else 0.
    static let between: [Bitboard] = {
        var result = [Bitboard](repeating: 0, count: 64 * 64)
        for a in 0..<64 {
            for direction in 0..<8 {
                let (df, dr) = directionSteps[direction]
                var file = a & 7 + df, rank = a >> 3 + dr
                var accumulated: Bitboard = 0
                while (0...7).contains(file), (0...7).contains(rank) {
                    let b = rank * 8 + file
                    result[a * 64 + b] = accumulated
                    accumulated |= bit(b)
                    file += df
                    rank += dr
                }
            }
        }
        return result
    }()
    /// The direction pointing the other way: north/south, east/west, northEast/southWest,
    /// northWest/southEast. (Index + 4 is only right for the orthogonal directions, because
    /// the diagonals are listed NE, NW and then SE, SW.)
    static let oppositeDirection: [Int] = [south, west, southWest, southEast, north, east, northWest, northEast]
    /// `line[a * 64 + b]`: the full line (edge to edge) through two aligned squares, else 0.
    static let line: [Bitboard] = {
        var result = [Bitboard](repeating: 0, count: 64 * 64)
        for a in 0..<64 {
            for direction in 0..<4 {
                let opposite = oppositeDirection[direction]
                let full = rays[direction * 64 + a] | rays[opposite * 64 + a] | bit(a)
                var ray = rays[direction * 64 + a] | rays[opposite * 64 + a]
                while ray != 0 {
                    let b = ray.trailingZeroBitCount
                    ray &= ray - 1
                    result[a * 64 + b] = full
                }
            }
        }
        return result
    }()

    /// Castling-rights mask indexed by square: moving from or to a square keeps only these rights.
    static let castlingMask: [UInt8] = {
        var result = [UInt8](repeating: 0x0F, count: 64)
        result[0] = 0x0F & ~2       // a1: white queenside
        result[4] = 0x0F & ~(1 | 2) // e1: white king
        result[7] = 0x0F & ~1       // h1: white kingside
        result[56] = 0x0F & ~8      // a8: black queenside
        result[60] = 0x0F & ~(4 | 8) // e8: black king
        result[63] = 0x0F & ~4      // h8: black kingside
        return result
    }()

    private static func stepAttacks(_ square: Int, _ steps: [(Int, Int)]) -> Bitboard {
        var bb: Bitboard = 0
        for (df, dr) in steps {
            let file = square & 7 + df, rank = square >> 3 + dr
            if (0...7).contains(file), (0...7).contains(rank) { bb |= bit(rank * 8 + file) }
        }
        return bb
    }

    @inline(__always) static func ray(_ square: Int, _ direction: Int, _ occupied: Bitboard) -> Bitboard {
        let r = rays[direction * 64 + square]
        let blockers = r & occupied
        if blockers == 0 { return r }
        let first = direction < 4 ? blockers.trailingZeroBitCount : 63 - blockers.leadingZeroBitCount
        return r ^ rays[direction * 64 + first]
    }

    @inline(__always) static func rookAttacks(_ square: Int, _ occupied: Bitboard) -> Bitboard {
        ray(square, north, occupied) | ray(square, east, occupied) | ray(square, south, occupied) | ray(square, west, occupied)
    }

    @inline(__always) static func bishopAttacks(_ square: Int, _ occupied: Bitboard) -> Bitboard {
        ray(square, northEast, occupied) | ray(square, northWest, occupied) | ray(square, southEast, occupied) | ray(square, southWest, occupied)
    }
}

// MARK: - Internal move

struct InternalMove: Hashable {
    static let flagNone: UInt8 = 0
    static let flagDoublePush: UInt8 = 1
    static let flagEnPassant: UInt8 = 2
    static let flagCastle: UInt8 = 3

    var from: UInt8
    var to: UInt8
    /// 255 when not a promotion, otherwise the `PieceKind.code` of the promoted piece.
    var promotion: UInt8
    var flag: UInt8

    @inline(__always) init(from: Int, to: Int, promotion: Int = 255, flag: UInt8 = InternalMove.flagNone) {
        self.from = UInt8(from)
        self.to = UInt8(to)
        self.promotion = UInt8(promotion)
        self.flag = flag
    }

    var publicMove: Move {
        Move(
            from: Square(uncheckedIndex: Int(from)),
            to: Square(uncheckedIndex: Int(to)),
            promotion: promotion == 255 ? nil : PieceKind(code: Int(promotion))
        )
    }

    func matches(_ move: Move) -> Bool {
        Int(from) == move.from.index && Int(to) == move.to.index
            && (promotion == 255 ? move.promotion == nil : move.promotion?.code == Int(promotion))
    }
}

// MARK: - Board state

struct BoardState {
    var colors: (Bitboard, Bitboard) = (0, 0)
    var kinds: (Bitboard, Bitboard, Bitboard, Bitboard, Bitboard, Bitboard) = (0, 0, 0, 0, 0, 0)
    /// 0 white, 1 black.
    var side: Int = 0
    /// `CastlingRights.rawValue`.
    var castling: UInt8 = 0
    /// En passant target square, or -1.
    var enPassant: Int = -1
    var halfmove: Int = 0
    var fullmove: Int = 1

    init(_ position: Position) {
        let count = min(position.board.count, 64)
        for index in 0..<count {
            if let piece = position.board[index] {
                toggle(color: piece.color.code, kind: piece.kind.code, bit(index))
            }
        }
        side = position.sideToMove.code
        castling = position.castlingRights.rawValue
        enPassant = position.enPassant?.index ?? -1
        // Clamped so `make` can count up without overflowing, whatever the public fields hold.
        halfmove = Position.clampedHalfmoveClock(position.halfmoveClock)
        fullmove = Position.clampedFullmoveNumber(position.fullmoveNumber)
    }

    @inline(__always) func color(_ code: Int) -> Bitboard { code == 0 ? colors.0 : colors.1 }

    @inline(__always) func kind(_ code: Int) -> Bitboard {
        switch code {
        case 0: return kinds.0
        case 1: return kinds.1
        case 2: return kinds.2
        case 3: return kinds.3
        case 4: return kinds.4
        default: return kinds.5
        }
    }

    @inline(__always) func pieces(_ colorCode: Int, _ kindCode: Int) -> Bitboard { color(colorCode) & kind(kindCode) }

    @inline(__always) var occupied: Bitboard { colors.0 | colors.1 }

    @inline(__always) mutating func toggle(color colorCode: Int, kind kindCode: Int, _ bb: Bitboard) {
        if colorCode == 0 { colors.0 ^= bb } else { colors.1 ^= bb }
        switch kindCode {
        case 0: kinds.0 ^= bb
        case 1: kinds.1 ^= bb
        case 2: kinds.2 ^= bb
        case 3: kinds.3 ^= bb
        case 4: kinds.4 ^= bb
        default: kinds.5 ^= bb
        }
    }

    /// Kind code of the piece on `square`, or -1 when empty.
    @inline(__always) func kindCode(at square: Int) -> Int {
        let b = bit(square)
        if occupied & b == 0 { return -1 }
        if kinds.0 & b != 0 { return 0 }
        if kinds.1 & b != 0 { return 1 }
        if kinds.2 & b != 0 { return 2 }
        if kinds.3 & b != 0 { return 3 }
        if kinds.4 & b != 0 { return 4 }
        return 5
    }

    /// Color code of the piece on `square`, or -1 when empty.
    @inline(__always) func colorCode(at square: Int) -> Int {
        let b = bit(square)
        if colors.0 & b != 0 { return 0 }
        if colors.1 & b != 0 { return 1 }
        return -1
    }

    /// Every piece (of both colors) that attacks `square`, given an occupancy.
    @inline(__always) func attackers(to square: Int, occupied: Bitboard) -> Bitboard {
        let diagonal = kinds.2 | kinds.4
        let straight = kinds.3 | kinds.4
        return (Tables.pawnAttacks[square] & kinds.0 & colors.1)
            | (Tables.pawnAttacks[64 + square] & kinds.0 & colors.0)
            | (Tables.knight[square] & kinds.1)
            | (Tables.king[square] & kinds.5)
            | (Tables.bishopAttacks(square, occupied) & diagonal)
            | (Tables.rookAttacks(square, occupied) & straight)
    }

    /// True when any king of `colorCode` is attacked by the other color.
    func isInCheck(_ colorCode: Int) -> Bool {
        var kingsBB = pieces(colorCode, 5)
        let them = color(1 - colorCode)
        let occ = occupied
        while kingsBB != 0 {
            let square = kingsBB.trailingZeroBitCount
            kingsBB &= kingsBB - 1
            if attackers(to: square, occupied: occ) & them != 0 { return true }
        }
        return false
    }

    // MARK: Move generation

    /// Appends every legal move for the side to move.
    ///
    /// When the side to move has no king, the moves are pseudo-legal (nothing can be in check).
    /// With several kings, legality is judged against the lowest-index king only; such
    /// positions are rejected by `Position.validate()` and only need to not crash here.
    func generateLegalMoves(into moves: inout [InternalMove]) {
        let us = side, them = 1 - side
        let usBB = color(us), themBB = color(them)
        let occ = usBB | themBB
        let kingBB = pieces(us, 5)
        let hasKing = kingBB != 0
        let kingSquare = hasKing ? kingBB.trailingZeroBitCount : -1

        var checkMask: Bitboard = ~0
        var pinned: Bitboard = 0
        var checkerCount = 0

        if hasKing {
            let checkers = attackers(to: kingSquare, occupied: occ) & themBB
            checkerCount = checkers.nonzeroBitCount

            // King steps: test each target with the king lifted off the board so it cannot
            // hide behind itself on a checking ray.
            let occWithoutKing = occ ^ bit(kingSquare)
            var targets = Tables.king[kingSquare] & ~usBB
            while targets != 0 {
                let to = targets.trailingZeroBitCount
                targets &= targets - 1
                if attackers(to: to, occupied: occWithoutKing) & themBB == 0 {
                    moves.append(InternalMove(from: kingSquare, to: to))
                }
            }
            if checkerCount > 1 { return }
            if checkerCount == 1 {
                let checker = checkers.trailingZeroBitCount
                checkMask = checkers | Tables.between[kingSquare * 64 + checker]
            }

            // Pins: enemy sliders that would see the king through exactly one of our pieces.
            let diagonal = (kinds.2 | kinds.4) & themBB
            let straight = (kinds.3 | kinds.4) & themBB
            var snipers = (Tables.bishopAttacks(kingSquare, themBB) & diagonal)
                | (Tables.rookAttacks(kingSquare, themBB) & straight)
            while snipers != 0 {
                let sniper = snipers.trailingZeroBitCount
                snipers &= snipers - 1
                let blockers = Tables.between[kingSquare * 64 + sniper] & occ
                if blockers.nonzeroBitCount == 1 && blockers & usBB != 0 {
                    pinned |= blockers
                }
            }
        }

        let targetMask = ~usBB & checkMask

        // Knights (a pinned knight can never move).
        var knights = pieces(us, 1) & ~pinned
        while knights != 0 {
            let from = knights.trailingZeroBitCount
            knights &= knights - 1
            appendTargets(from: from, Tables.knight[from] & targetMask, into: &moves)
        }

        // Sliders.
        var diagonalSliders = (kinds.2 | kinds.4) & usBB
        while diagonalSliders != 0 {
            let from = diagonalSliders.trailingZeroBitCount
            diagonalSliders &= diagonalSliders - 1
            var targets = Tables.bishopAttacks(from, occ) & targetMask
            if pinned & bit(from) != 0 { targets &= Tables.line[kingSquare * 64 + from] }
            appendTargets(from: from, targets, into: &moves)
        }
        var straightSliders = (kinds.3 | kinds.4) & usBB
        while straightSliders != 0 {
            let from = straightSliders.trailingZeroBitCount
            straightSliders &= straightSliders - 1
            var targets = Tables.rookAttacks(from, occ) & targetMask
            if pinned & bit(from) != 0 { targets &= Tables.line[kingSquare * 64 + from] }
            appendTargets(from: from, targets, into: &moves)
        }

        // Pawns.
        let forward = us == 0 ? 8 : -8
        let startRank = us == 0 ? 1 : 6
        let promotionRank = us == 0 ? 7 : 0
        var pawns = pieces(us, 0)
        while pawns != 0 {
            let from = pawns.trailingZeroBitCount
            pawns &= pawns - 1
            let pinMask: Bitboard = pinned & bit(from) != 0 ? Tables.line[kingSquare * 64 + from] : ~0

            let single = from + forward
            if (0..<64).contains(single) && occ & bit(single) == 0 {
                if checkMask & pinMask & bit(single) != 0 {
                    appendPawnMove(from: from, to: single, promotionRank: promotionRank, into: &moves)
                }
                let double = single + forward
                if from >> 3 == startRank && occ & bit(double) == 0 && checkMask & pinMask & bit(double) != 0 {
                    moves.append(InternalMove(from: from, to: double, flag: InternalMove.flagDoublePush))
                }
            }

            let attacks = Tables.pawnAttacks[us * 64 + from]
            var captures = attacks & themBB & checkMask & pinMask
            while captures != 0 {
                let to = captures.trailingZeroBitCount
                captures &= captures - 1
                appendPawnMove(from: from, to: to, promotionRank: promotionRank, into: &moves)
            }

            if enPassant >= 0 && attacks & bit(enPassant) != 0 {
                let move = InternalMove(from: from, to: enPassant, flag: InternalMove.flagEnPassant)
                if isValidEnPassantShape() {
                    // Rare enough to verify by playing it: covers the horizontal pin through
                    // both pawns and captures that remove (or fail to address) a checker.
                    var copy = self
                    copy.make(move)
                    if !copy.isInCheck(us) { moves.append(move) }
                }
            }
        }

        // Castling.
        if hasKing && checkerCount == 0 && castling != 0 {
            let home = us == 0 ? 4 : 60
            if kingSquare == home {
                let rooks = pieces(us, 3)
                let kingsideRight: UInt8 = us == 0 ? 1 : 4
                let queensideRight: UInt8 = us == 0 ? 2 : 8
                if castling & kingsideRight != 0 && rooks & bit(home + 3) != 0
                    && occ & (bit(home + 1) | bit(home + 2)) == 0
                    && attackers(to: home + 1, occupied: occ) & themBB == 0
                    && attackers(to: home + 2, occupied: occ) & themBB == 0 {
                    moves.append(InternalMove(from: home, to: home + 2, flag: InternalMove.flagCastle))
                }
                if castling & queensideRight != 0 && rooks & bit(home - 4) != 0
                    && occ & (bit(home - 1) | bit(home - 2) | bit(home - 3)) == 0
                    && attackers(to: home - 1, occupied: occ) & themBB == 0
                    && attackers(to: home - 2, occupied: occ) & themBB == 0 {
                    moves.append(InternalMove(from: home, to: home - 2, flag: InternalMove.flagCastle))
                }
            }
        }
    }

    /// The en passant square is on the correct rank for the side to move, is empty, and an
    /// enemy pawn stands directly in front of it (from the capturing side's point of view).
    func isValidEnPassantShape() -> Bool {
        guard enPassant >= 0 else { return false }
        let expectedRank = side == 0 ? 5 : 2
        guard enPassant >> 3 == expectedRank, occupied & bit(enPassant) == 0 else { return false }
        let victim = side == 0 ? enPassant - 8 : enPassant + 8
        return pieces(1 - side, 0) & bit(victim) != 0
    }

    @inline(__always) private func appendTargets(from: Int, _ targets: Bitboard, into moves: inout [InternalMove]) {
        var remaining = targets
        while remaining != 0 {
            let to = remaining.trailingZeroBitCount
            remaining &= remaining - 1
            moves.append(InternalMove(from: from, to: to))
        }
    }

    @inline(__always) private func appendPawnMove(from: Int, to: Int, promotionRank: Int, into moves: inout [InternalMove]) {
        if to >> 3 == promotionRank {
            moves.append(InternalMove(from: from, to: to, promotion: 4))
            moves.append(InternalMove(from: from, to: to, promotion: 3))
            moves.append(InternalMove(from: from, to: to, promotion: 2))
            moves.append(InternalMove(from: from, to: to, promotion: 1))
        } else {
            moves.append(InternalMove(from: from, to: to))
        }
    }

    func legalMoves() -> [InternalMove] {
        var moves: [InternalMove] = []
        moves.reserveCapacity(64)
        generateLegalMoves(into: &moves)
        return moves
    }

    // MARK: Making moves

    /// Plays a move produced by `generateLegalMoves`. The en passant square is set after
    /// every double push; `Position` narrows it to the legal-capture convention afterwards.
    mutating func make(_ move: InternalMove) {
        let us = side, them = 1 - side
        let from = Int(move.from), to = Int(move.to)
        let moving = kindCode(at: from)
        var resetsClock = moving == 0

        if move.flag == InternalMove.flagEnPassant {
            let victim = us == 0 ? to - 8 : to + 8
            toggle(color: them, kind: 0, bit(victim))
            resetsClock = true
        } else {
            let captured = kindCode(at: to)
            if captured >= 0 {
                toggle(color: colorCode(at: to), kind: captured, bit(to))
                resetsClock = true
            }
        }

        toggle(color: us, kind: moving, bit(from))
        toggle(color: us, kind: move.promotion == 255 ? moving : Int(move.promotion), bit(to))

        if move.flag == InternalMove.flagCastle {
            let (rookFrom, rookTo) = to > from ? (from + 3, from + 1) : (from - 4, from - 1)
            toggle(color: us, kind: 3, bit(rookFrom) | bit(rookTo))
        }

        castling &= Tables.castlingMask[from] & Tables.castlingMask[to]
        enPassant = move.flag == InternalMove.flagDoublePush ? (from + to) / 2 : -1
        // Both clocks stop at the largest value Stockfish accepts instead of overflowing.
        let maxHalfmove = Position.halfmoveClockRange.upperBound
        halfmove = resetsClock ? 0 : (halfmove < maxHalfmove ? halfmove + 1 : maxHalfmove)
        if us == 1 && fullmove < Position.fullmoveNumberRange.upperBound { fullmove += 1 }
        side = them
    }

    // MARK: Perft

    func perft(_ depth: Int) -> Int {
        if depth <= 0 { return 1 }
        var moves: [InternalMove] = []
        moves.reserveCapacity(64)
        generateLegalMoves(into: &moves)
        if depth == 1 { return moves.count }
        var total = 0
        for move in moves {
            var child = self
            child.make(move)
            total += child.perft(depth - 1)
        }
        return total
    }
}
