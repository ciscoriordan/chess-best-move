// Basic value types shared by every module: colors, piece kinds, pieces, squares,
// castling rights and moves.

// MARK: - PieceColor

public enum PieceColor: String, Sendable, Hashable, CaseIterable, Codable {
    case white
    case black

    public var opposite: PieceColor { self == .white ? .black : .white }

    /// 0 for white, 1 for black. Used by the bitboard internals.
    @inline(__always) var code: Int { self == .white ? 0 : 1 }

    @inline(__always) init(code: Int) { self = code == 0 ? .white : .black }
}

// MARK: - PieceKind

public enum PieceKind: String, Sendable, Hashable, CaseIterable, Codable {
    case pawn
    case knight
    case bishop
    case rook
    case queen
    case king

    /// 0 pawn, 1 knight, 2 bishop, 3 rook, 4 queen, 5 king. Used by the bitboard internals.
    @inline(__always) var code: Int {
        switch self {
        case .pawn: return 0
        case .knight: return 1
        case .bishop: return 2
        case .rook: return 3
        case .queen: return 4
        case .king: return 5
        }
    }

    init(code: Int) {
        switch code {
        case 0: self = .pawn
        case 1: self = .knight
        case 2: self = .bishop
        case 3: self = .rook
        case 4: self = .queen
        default: self = .king
        }
    }

    /// Lowercase letter used in FEN and UCI ("p", "n", "b", "r", "q", "k").
    public var lowercaseLetter: Character {
        switch self {
        case .pawn: return "p"
        case .knight: return "n"
        case .bishop: return "b"
        case .rook: return "r"
        case .queen: return "q"
        case .king: return "k"
        }
    }

    /// Uppercase letter used in SAN ("N", "B", "R", "Q", "K"); empty for pawns.
    public var sanLetter: String {
        self == .pawn ? "" : String(lowercaseLetter).uppercased()
    }

    /// Parses a piece letter in either case.
    public init?(letter: Character) {
        switch letter {
        case "p", "P": self = .pawn
        case "n", "N": self = .knight
        case "b", "B": self = .bishop
        case "r", "R": self = .rook
        case "q", "Q": self = .queen
        case "k", "K": self = .king
        default: return nil
        }
    }
}

// MARK: - Piece

public struct Piece: Sendable, Hashable {
    public var color: PieceColor
    public var kind: PieceKind

    public init(color: PieceColor, kind: PieceKind) {
        self.color = color
        self.kind = kind
    }

    /// Creates a piece from its FEN letter: uppercase is white, lowercase is black.
    ///
    /// The character must be one of `PNBRQKpnbrqk`; any other character is a programmer
    /// error and traps. Use `init?(validatingFENCharacter:)` for untrusted input.
    public init(fenCharacter: Character) {
        guard let piece = Piece(validatingFENCharacter: fenCharacter) else {
            preconditionFailure("Invalid FEN piece character: \(fenCharacter)")
        }
        self = piece
    }

    /// Creates a piece from its FEN letter, returning nil for anything outside `PNBRQKpnbrqk`.
    public init?(validatingFENCharacter character: Character) {
        guard let kind = PieceKind(letter: character) else { return nil }
        self.kind = kind
        self.color = character.isUppercase ? .white : .black
    }

    public var fenCharacter: Character {
        let letter = kind.lowercaseLetter
        return color == .white ? Character(letter.uppercased()) : letter
    }
}

extension Piece: CustomStringConvertible {
    public var description: String { String(fenCharacter) }
}

extension Piece: Codable {
    /// Encoded as the one-character FEN letter, e.g. "K" or "p".
    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        let string = try container.decode(String.self)
        guard string.count == 1, let piece = Piece(validatingFENCharacter: string.first!) else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Invalid piece \"\(string)\"")
        }
        self = piece
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(String(fenCharacter))
    }
}

// MARK: - Square

/// A board square. `file` 0...7 is a...h, `rank` 0...7 is rank 1...8, `index = rank * 8 + file`.
public struct Square: Sendable, Hashable {
    public let file: Int
    public let rank: Int

    public init?(file: Int, rank: Int) {
        guard (0...7).contains(file), (0...7).contains(rank) else { return nil }
        self.file = file
        self.rank = rank
    }

    /// Parses lowercase algebraic notation such as "e4".
    public init?(_ algebraic: String) {
        let scalars = Array(algebraic.unicodeScalars)
        guard scalars.count == 2 else { return nil }
        let fileValue = Int(scalars[0].value) - Int(("a" as Unicode.Scalar).value)
        let rankValue = Int(scalars[1].value) - Int(("1" as Unicode.Scalar).value)
        guard (0...7).contains(fileValue), (0...7).contains(rankValue) else { return nil }
        self.file = fileValue
        self.rank = rankValue
    }

    public init?(index: Int) {
        guard (0..<64).contains(index) else { return nil }
        self.file = index & 7
        self.rank = index >> 3
    }

    /// Non-validating initializer for internal use with indices known to be 0..<64.
    @inline(__always) init(uncheckedIndex index: Int) {
        self.file = index & 7
        self.rank = index >> 3
    }

    public var index: Int { rank * 8 + file }

    public var algebraic: String {
        let fileLetter = Character(Unicode.Scalar(UInt8(97 + file)))
        return "\(fileLetter)\(rank + 1)"
    }

    /// All 64 squares in index order (a1, b1, ..., h8).
    public static let all: [Square] = (0..<64).map { Square(uncheckedIndex: $0) }
}

extension Square: Comparable {
    public static func < (lhs: Square, rhs: Square) -> Bool { lhs.index < rhs.index }
}

extension Square: CustomStringConvertible {
    public var description: String { algebraic }
}

extension Square: Codable {
    /// Encoded as the algebraic string, e.g. "e4".
    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        let string = try container.decode(String.self)
        guard let square = Square(string) else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Invalid square \"\(string)\"")
        }
        self = square
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(algebraic)
    }
}

// MARK: - CastlingRights

public struct CastlingRights: OptionSet, Sendable, Hashable, Codable {
    public let rawValue: UInt8

    public init(rawValue: UInt8) {
        self.rawValue = rawValue & 0x0F
    }

    public static let whiteKingside = CastlingRights(rawValue: 1)
    public static let whiteQueenside = CastlingRights(rawValue: 2)
    public static let blackKingside = CastlingRights(rawValue: 4)
    public static let blackQueenside = CastlingRights(rawValue: 8)

    public static let all: CastlingRights = [.whiteKingside, .whiteQueenside, .blackKingside, .blackQueenside]

    /// FEN castling field: some ordered subset of "KQkq", or "-" when empty.
    public var fen: String {
        var result = ""
        if contains(.whiteKingside) { result.append("K") }
        if contains(.whiteQueenside) { result.append("Q") }
        if contains(.blackKingside) { result.append("k") }
        if contains(.blackQueenside) { result.append("q") }
        return result.isEmpty ? "-" : result
    }
}

// MARK: - Move

public struct Move: Sendable, Hashable {
    public var from: Square
    public var to: Square
    public var promotion: PieceKind?

    public init(from: Square, to: Square, promotion: PieceKind? = nil) {
        self.from = from
        self.to = to
        self.promotion = promotion
    }

    /// Parses UCI long algebraic notation: "e2e4", "e7e8q". Castling is the king's
    /// two-square move ("e1g1"). The promotion letter must be n, b, r or q (either case).
    /// The null move "0000" and anything malformed return nil.
    public init?(uci: String) {
        let characters = Array(uci)
        guard characters.count == 4 || characters.count == 5,
              let from = Square(String(characters[0...1])),
              let to = Square(String(characters[2...3])),
              from != to
        else { return nil }
        var promotion: PieceKind?
        if characters.count == 5 {
            guard let kind = PieceKind(letter: characters[4]),
                  kind != .pawn, kind != .king
            else { return nil }
            promotion = kind
        }
        self.init(from: from, to: to, promotion: promotion)
    }

    public var uci: String {
        var result = from.algebraic + to.algebraic
        if let promotion { result.append(promotion.lowercaseLetter) }
        return result
    }
}

extension Move: CustomStringConvertible {
    public var description: String { uci }
}

extension Move: Codable {
    /// Encoded as the UCI string, e.g. "e7e8q".
    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        let string = try container.decode(String.self)
        guard let move = Move(uci: string) else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Invalid UCI move \"\(string)\"")
        }
        self = move
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(uci)
    }
}
