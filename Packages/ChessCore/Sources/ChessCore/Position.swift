// The public position type: board contents plus the FEN state fields, with FEN
// parsing/serialization, legal move generation and move application.

public enum FENError: Error, Sendable, Hashable {
    /// FEN needs 2 to 6 whitespace-separated fields (board and side to move are required).
    case wrongFieldCount(Int)
    case invalidBoard(String)
    case invalidSideToMove(String)
    case invalidCastlingRights(String)
    case invalidEnPassant(String)
    case invalidHalfmoveClock(String)
    case invalidFullmoveNumber(String)
}

extension FENError: CustomStringConvertible {
    public var description: String {
        switch self {
        case .wrongFieldCount(let count): return "FEN has \(count) fields; expected 2 to 6"
        case .invalidBoard(let reason): return "Invalid FEN board: \(reason)"
        case .invalidSideToMove(let field): return "Invalid FEN side to move \"\(field)\""
        case .invalidCastlingRights(let field): return "Invalid FEN castling rights \"\(field)\""
        case .invalidEnPassant(let field): return "Invalid FEN en passant square \"\(field)\""
        case .invalidHalfmoveClock(let field): return "Invalid FEN halfmove clock \"\(field)\""
        case .invalidFullmoveNumber(let field): return "Invalid FEN fullmove number \"\(field)\""
        }
    }
}

public struct Position: Sendable, Hashable {
    /// 64 entries indexed by `Square.index` (a1 = 0, h8 = 63).
    public var board: [Piece?]
    public var sideToMove: PieceColor
    public var castlingRights: CastlingRights
    public var enPassant: Square?
    /// Plies since the last capture or pawn move. `fen` and `applying(_:)` treat it as clamped
    /// to 0...32767, the range Stockfish accepts.
    public var halfmoveClock: Int
    /// `fen` and `applying(_:)` treat it as clamped to 1...100000, the range Stockfish accepts.
    public var fullmoveNumber: Int

    /// Halfmove clocks Stockfish accepts ("Rule50 counter out of range" otherwise).
    static let halfmoveClockRange = 0...32767
    /// Fullmove numbers Stockfish accepts ("Game ply out of range" otherwise; 0 is read as 1).
    static let fullmoveNumberRange = 1...100_000

    static func clampedHalfmoveClock(_ value: Int) -> Int {
        min(max(value, halfmoveClockRange.lowerBound), halfmoveClockRange.upperBound)
    }

    static func clampedFullmoveNumber(_ value: Int) -> Int {
        min(max(value, fullmoveNumberRange.lowerBound), fullmoveNumberRange.upperBound)
    }

    /// Clocks outside 0...32767 (halfmove) and 1...100000 (fullmove) are clamped into range.
    public init(
        board: [Piece?],
        sideToMove: PieceColor = .white,
        castlingRights: CastlingRights = [],
        enPassant: Square? = nil,
        halfmoveClock: Int = 0,
        fullmoveNumber: Int = 1
    ) {
        var normalized = Array(board.prefix(64))
        if normalized.count < 64 {
            normalized.append(contentsOf: [Piece?](repeating: nil, count: 64 - normalized.count))
        }
        self.board = normalized
        self.sideToMove = sideToMove
        self.castlingRights = castlingRights
        self.enPassant = enPassant
        self.halfmoveClock = Position.clampedHalfmoveClock(halfmoveClock)
        self.fullmoveNumber = Position.clampedFullmoveNumber(fullmoveNumber)
    }

    /// An empty board, white to move, no castling rights.
    public static let empty = Position(board: [Piece?](repeating: nil, count: 64))

    public static let start: Position = {
        // swiftlint:disable:next force_try
        try! Position(fen: "rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1")
    }()

    // MARK: FEN

    /// Parses Forsyth-Edwards Notation.
    ///
    /// Board and side to move are required. Missing castling, en passant, halfmove and
    /// fullmove fields default to "-", "-", 0 and 1. Extra whitespace is ignored. A fullmove
    /// number of 0 (written by some tools) is read as 1. The halfmove clock must be 0...32767
    /// and the fullmove number 0...100000, the ranges Stockfish accepts. The en passant square must be on
    /// rank 6 when white is to move and rank 3 when black is to move; it is stored as given,
    /// even when no capture is possible (see `removeInvalidEnPassant()`).
    ///
    /// Piece counts and kings are not checked here; use `validate()` for that.
    public init(fen: String) throws {
        let fields = fen.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        guard (2...6).contains(fields.count) else { throw FENError.wrongFieldCount(fields.count) }

        board = try Position.parseBoard(fields[0])

        switch fields[1] {
        case "w": sideToMove = .white
        case "b": sideToMove = .black
        default: throw FENError.invalidSideToMove(fields[1])
        }

        castlingRights = []
        if fields.count > 2 && fields[2] != "-" {
            for character in fields[2] {
                let right: CastlingRights
                switch character {
                case "K": right = .whiteKingside
                case "Q": right = .whiteQueenside
                case "k": right = .blackKingside
                case "q": right = .blackQueenside
                default: throw FENError.invalidCastlingRights(fields[2])
                }
                guard !castlingRights.contains(right) else { throw FENError.invalidCastlingRights(fields[2]) }
                castlingRights.insert(right)
            }
        }

        enPassant = nil
        if fields.count > 3 && fields[3] != "-" {
            guard let square = Square(fields[3]),
                  square.rank == (sideToMove == .white ? 5 : 2)
            else { throw FENError.invalidEnPassant(fields[3]) }
            enPassant = square
        }

        halfmoveClock = 0
        if fields.count > 4 {
            guard fields[4].allSatisfy(\.isASCIIDigit), let value = Int(fields[4]),
                  Position.halfmoveClockRange.contains(value)
            else { throw FENError.invalidHalfmoveClock(fields[4]) }
            halfmoveClock = value
        }

        fullmoveNumber = 1
        if fields.count > 5 {
            guard fields[5].allSatisfy(\.isASCIIDigit), let value = Int(fields[5]),
                  value <= Position.fullmoveNumberRange.upperBound
            else { throw FENError.invalidFullmoveNumber(fields[5]) }
            fullmoveNumber = max(value, 1)
        }
    }

    private static func parseBoard(_ field: String) throws -> [Piece?] {
        let rows = field.split(separator: "/", omittingEmptySubsequences: false)
        guard rows.count == 8 else { throw FENError.invalidBoard("expected 8 ranks, found \(rows.count)") }
        var board = [Piece?](repeating: nil, count: 64)
        for (rowIndex, row) in rows.enumerated() {
            let rank = 7 - rowIndex
            var file = 0
            for character in row {
                if let digit = character.wholeNumberValue, character.isASCIIDigit {
                    guard (1...8).contains(digit) else {
                        throw FENError.invalidBoard("bad empty-square count \(character) on rank \(rank + 1)")
                    }
                    file += digit
                } else if let piece = Piece(validatingFENCharacter: character) {
                    guard file < 8 else { throw FENError.invalidBoard("rank \(rank + 1) has more than 8 squares") }
                    board[rank * 8 + file] = piece
                    file += 1
                } else {
                    throw FENError.invalidBoard("unexpected character \"\(character)\" on rank \(rank + 1)")
                }
                guard file <= 8 else { throw FENError.invalidBoard("rank \(rank + 1) has more than 8 squares") }
            }
            guard file == 8 else { throw FENError.invalidBoard("rank \(rank + 1) has \(file) squares") }
        }
        return board
    }

    /// The position in FEN. Clocks are written clamped to the ranges `init(fen:)` accepts, so
    /// the result always parses again.
    public var fen: String {
        var placement = ""
        for rank in stride(from: 7, through: 0, by: -1) {
            var empty = 0
            for file in 0..<8 {
                let index = rank * 8 + file
                if index < board.count, let piece = board[index] {
                    if empty > 0 { placement.append(String(empty)); empty = 0 }
                    placement.append(piece.fenCharacter)
                } else {
                    empty += 1
                }
            }
            if empty > 0 { placement.append(String(empty)) }
            if rank > 0 { placement.append("/") }
        }
        let side = sideToMove == .white ? "w" : "b"
        let ep = enPassant?.algebraic ?? "-"
        let halfmove = Position.clampedHalfmoveClock(halfmoveClock)
        let fullmove = Position.clampedFullmoveNumber(fullmoveNumber)
        return "\(placement) \(side) \(castlingRights.fen) \(ep) \(halfmove) \(fullmove)"
    }

    // MARK: Board access

    public subscript(square: Square) -> Piece? {
        get { square.index < board.count ? board[square.index] : nil }
        set {
            if board.count < 64 { board.append(contentsOf: [Piece?](repeating: nil, count: 64 - board.count)) }
            board[square.index] = newValue
        }
    }

    // MARK: Moves

    /// All legal moves for the side to move.
    public func legalMoves() -> [Move] {
        BoardState(self).legalMoves().map(\.publicMove)
    }

    /// Whether any king of `color` is attacked. False when that color has no king.
    public func isInCheck(_ color: PieceColor) -> Bool {
        BoardState(self).isInCheck(color.code)
    }

    public var isCheckmate: Bool { isInCheck(sideToMove) && legalMoves().isEmpty }

    public var isStalemate: Bool { !isInCheck(sideToMove) && legalMoves().isEmpty }

    /// The position after `move`, or nil if the move is not legal here. A pawn move to the
    /// last rank must carry its promotion piece. The resulting en passant square is set only
    /// when the side to move can legally capture en passant (the convention used by Stockfish
    /// and modern tools).
    public func applying(_ move: Move) -> Position? {
        let state = BoardState(self)
        guard let internalMove = state.legalMoves().first(where: { $0.matches(move) }) else { return nil }
        var next = state
        next.make(internalMove)
        return Position(state: next)
    }

    init(state: BoardState) {
        var board = [Piece?](repeating: nil, count: 64)
        var occupied = state.occupied
        while occupied != 0 {
            let index = occupied.trailingZeroBitCount
            occupied &= occupied - 1
            board[index] = Piece(color: PieceColor(code: state.colorCode(at: index)), kind: PieceKind(code: state.kindCode(at: index)))
        }
        var legalEnPassant: Square?
        if state.enPassant >= 0 && state.isValidEnPassantShape()
            && state.legalMoves().contains(where: { $0.flag == InternalMove.flagEnPassant }) {
            legalEnPassant = Square(uncheckedIndex: state.enPassant)
        }
        self.init(
            board: board,
            sideToMove: PieceColor(code: state.side),
            castlingRights: CastlingRights(rawValue: state.castling),
            enPassant: legalEnPassant,
            halfmoveClock: state.halfmove,
            fullmoveNumber: state.fullmove
        )
    }

    /// Number of leaf nodes of the legal move tree to `depth` plies (move-generator test).
    public func perft(_ depth: Int) -> Int {
        BoardState(self).perft(depth)
    }

    /// Perft split by root move: each legal move and the leaf count below it.
    public func divide(_ depth: Int) -> [Move: Int] {
        let state = BoardState(self)
        var result: [Move: Int] = [:]
        for move in state.legalMoves() {
            var child = state
            child.make(move)
            result[move.publicMove] = child.perft(depth - 1)
        }
        return result
    }

    // MARK: En passant helpers

    /// Clears `enPassant` unless the side to move has a legal en passant capture onto it.
    public mutating func removeInvalidEnPassant() {
        guard enPassant != nil else { return }
        let state = BoardState(self)
        let legal = state.isValidEnPassantShape()
            && state.legalMoves().contains(where: { $0.flag == InternalMove.flagEnPassant })
        if !legal { enPassant = nil }
    }

    /// The en passant square implied by the last move, for a board that already shows the
    /// position after that move (for example one recognized from a screenshot with a
    /// last-move highlight).
    ///
    /// Returns the square the pawn skipped when the last move was a double pawn push by the
    /// side NOT to move, and the side to move has a legal en passant capture onto it.
    /// Otherwise nil. The two squares may be given in either order: the one holding the pawn
    /// is taken as the destination.
    public func enPassantSquare(lastMoveFrom first: Square, to second: Square) -> Square? {
        let pawnColor = sideToMove.opposite
        let movedPawn = Piece(color: pawnColor, kind: .pawn)
        let (from, to): (Square, Square)
        if self[second] == movedPawn && self[first] == nil {
            (from, to) = (first, second)
        } else if self[first] == movedPawn && self[second] == nil {
            (from, to) = (second, first)
        } else {
            return nil
        }
        let startRank = pawnColor == .white ? 1 : 6
        let direction = pawnColor == .white ? 1 : -1
        guard from.file == to.file, from.rank == startRank, to.rank == startRank + 2 * direction,
              let skipped = Square(file: from.file, rank: from.rank + direction),
              self[skipped] == nil
        else { return nil }
        var candidate = self
        candidate.enPassant = skipped
        candidate.removeInvalidEnPassant()
        return candidate.enPassant
    }

    /// Sets `enPassant` from the last move using `enPassantSquare(lastMoveFrom:to:)`.
    public mutating func inferEnPassant(lastMoveFrom from: Square, to: Square) {
        enPassant = enPassantSquare(lastMoveFrom: from, to: to)
    }

    // MARK: Castling helpers

    /// Grants each castling right whose king and rook stand on their home squares, and
    /// removes every other right.
    public mutating func inferCastlingRights() {
        castlingRights = inferredCastlingRights
    }

    /// The rights `inferCastlingRights()` would set.
    public var inferredCastlingRights: CastlingRights {
        var rights: CastlingRights = []
        let whiteKing = Piece(color: .white, kind: .king), whiteRook = Piece(color: .white, kind: .rook)
        let blackKing = Piece(color: .black, kind: .king), blackRook = Piece(color: .black, kind: .rook)
        func at(_ index: Int) -> Piece? { index < board.count ? board[index] : nil }
        if at(4) == whiteKing {
            if at(7) == whiteRook { rights.insert(.whiteKingside) }
            if at(0) == whiteRook { rights.insert(.whiteQueenside) }
        }
        if at(60) == blackKing {
            if at(63) == blackRook { rights.insert(.blackKingside) }
            if at(56) == blackRook { rights.insert(.blackQueenside) }
        }
        return rights
    }

    /// Drops castling rights whose king or rook is not on its home square. Unlike
    /// `inferCastlingRights()`, this never grants a right.
    public mutating func removeInconsistentCastlingRights() {
        castlingRights = castlingRights.intersection(inferredCastlingRights)
    }
}

extension Position: CustomStringConvertible {
    public var description: String { fen }
}

extension Position: Codable {
    /// Encoded as the FEN string.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        let string = try container.decode(String.self)
        do {
            try self.init(fen: string)
        } catch {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Invalid FEN \"\(string)\": \(error)")
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(fen)
    }
}

extension Character {
    /// "0" through "9" only (no other Unicode digits).
    var isASCIIDigit: Bool { isASCII && ("0"..."9").contains(self) }
}
