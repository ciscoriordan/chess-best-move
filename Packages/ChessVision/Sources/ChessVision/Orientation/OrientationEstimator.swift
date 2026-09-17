import ChessCore
import Foundation

/// Orientation priors from piece placement and the last move. Every function returns log-odds
/// in favor of white at the bottom (positive) versus black at the bottom (negative).
@_spi(Testing)
public enum OrientationEstimator {
    /// Piece-count bucket of the placement model.
    struct PlacementBucket: Sendable {
        let minimumPieces: Int
        let maximumPieces: Int
        /// One weight per entry of `placementFeatures`.
        let weights: [Double]
    }

    /// Number of entries `placementFeatures` returns.
    static let placementFeatureCount = 56

    /// Piece-placement log-odds from the display grid (64 cells, row-major from the top-left).
    ///
    /// A logistic model fitted on real game positions by Scripts/fit_orientation_prior.py (the
    /// weights and the data they were fitted on are in PiecePlacementPriorWeights.swift), one weight
    /// vector per piece-count bucket, so the log-odds are calibrated: on held-out positions, a
    /// board with 2 to 5 pieces is read right 74% of the time, 6 to 8 pieces 88%, 9 to 11
    /// pieces 98.7%, and 12 or more over 99.9%, and the reported confidence matches those rates.
    /// The log-odds are w . (features read with White at the bottom - features read with Black
    /// at the bottom), so flipping the display negates them.
    public static func pieceLogOdds(displayPieces: [Piece?]) -> Double {
        var whiteBottom: [(rank: Int, file: Int, piece: Piece)] = []
        var blackBottom: [(rank: Int, file: Int, piece: Piece)] = []
        for cell in 0..<64 {
            guard let piece = displayPieces[cell] else { continue }
            let row = cell / 8, column = cell % 8
            whiteBottom.append((7 - row, column, piece))
            blackBottom.append((row, 7 - column, piece))
        }
        let count = whiteBottom.count
        guard count >= 2 else { return 0 }
        let bucket = placementBuckets.first { count >= $0.minimumPieces && count <= $0.maximumPieces } ?? placementBuckets[placementBuckets.count - 1]
        let a = placementFeatures(whiteBottom), b = placementFeatures(blackBottom)
        var total = 0.0
        for i in 0..<placementFeatureCount {
            total += bucket.weights[i] * (a[i] - b[i])
        }
        return total
    }

    /// Features of the pieces read in one orientation (rank 0 = rank 1). Must match `features`
    /// in Scripts/fit_orientation_prior.py.
    /// - 0...47: count of each piece kind (pawn, knight, bishop, rook, queen, king) on each rank
    ///   counted from its own side.
    /// - 48, 49: pairs of a white and a black pawn on one file with the white pawn below (above).
    /// - 50, 51: kings below (above) the mean rank of their own pawns, from their own side.
    /// - 52, 53: mean own-side rank of White's (Black's) pieces other than pawns, scaled to -1...1.
    /// - 54, 55: pairs of a white and a black pawn on neighboring files with the white pawn
    ///   below (above).
    static func placementFeatures(_ pieces: [(rank: Int, file: Int, piece: Piece)]) -> [Double] {
        var v = [Double](repeating: 0, count: placementFeatureCount)
        var whitePawns = [[Int]](repeating: [], count: 8), blackPawns = [[Int]](repeating: [], count: 8)
        var kingRanks: [PieceColor: Int] = [:]
        var officerRanks: [PieceColor: [Int]] = [.white: [], .black: []]
        for (rank, file, piece) in pieces {
            let own = piece.color == .white ? rank : 7 - rank
            let kind: Int
            switch piece.kind {
            case .pawn: kind = 0
            case .knight: kind = 1
            case .bishop: kind = 2
            case .rook: kind = 3
            case .queen: kind = 4
            case .king: kind = 5
            }
            v[kind * 8 + own] += 1
            if piece.kind == .pawn {
                if piece.color == .white { whitePawns[file].append(rank) } else { blackPawns[file].append(rank) }
            } else {
                officerRanks[piece.color]!.append(own)
            }
            if piece.kind == .king { kingRanks[piece.color] = rank }
        }
        for file in 0..<8 {
            for a in whitePawns[file] {
                for b in blackPawns[file] {
                    if a < b { v[48] += 1 }
                    if a > b { v[49] += 1 }
                }
                for neighbor in [file - 1, file + 1] where (0..<8).contains(neighbor) {
                    for b in blackPawns[neighbor] {
                        if a < b { v[54] += 1 }
                        if a > b { v[55] += 1 }
                    }
                }
            }
        }
        for color in PieceColor.allCases {
            guard let rank = kingRanks[color] else { continue }
            let own = color == .white ? rank : 7 - rank
            let pawns = (color == .white ? whitePawns : blackPawns).flatMap { $0 }.map { color == .white ? $0 : 7 - $0 }
            guard !pawns.isEmpty else { continue }
            let mean = Double(pawns.reduce(0, +)) / Double(pawns.count)
            if Double(own) < mean { v[50] += 1 }
            if Double(own) > mean { v[51] += 1 }
        }
        for (color, index) in [(PieceColor.white, 52), (.black, 53)] {
            let ranks = officerRanks[color]!
            guard !ranks.isEmpty else { continue }
            v[index] += (Double(ranks.reduce(0, +)) / Double(ranks.count) - 3.5) / 3.5
        }
        return v
    }

    /// Log-odds from the start position: strong when the display shows the standard initial
    /// setup for exactly one orientation.
    public static func startPositionLogOdds(displayPieces: [Piece?]) -> Double {
        let start = Position.start.board
        let whiteBottom = DisplayGrid.toCells(start, whiteAtBottom: true)
        let blackBottom = DisplayGrid.toCells(start, whiteAtBottom: false)
        let matchesWhite = zip(displayPieces, whiteBottom).filter { $0 != $1 }.count
        let matchesBlack = zip(displayPieces, blackBottom).filter { $0 != $1 }.count
        if matchesWhite <= 2 && matchesBlack > 8 { return 8 }
        if matchesBlack <= 2 && matchesWhite > 8 { return -8 }
        return 0
    }

    /// Log-odds from a highlighted move in display cells: a pawn moves toward the opponent,
    /// and castling starts on the e-file.
    public static func lastMoveLogOdds(tintedCells: [Int], tintDistances: [[Double]]? = nil, displayPieces: [Piece?],
                                       premove: [Bool]? = nil) -> Double {
        let white = LastMoveResolver.resolve(
            tinted: tintedCells.map { DisplayGrid.square(row: $0 / 8, column: $0 % 8, whiteAtBottom: true) },
            tintDistances: tintDistances, board: DisplayGrid.toSquares(displayPieces, whiteAtBottom: true), premove: premove)
        let black = LastMoveResolver.resolve(
            tinted: tintedCells.map { DisplayGrid.square(row: $0 / 8, column: $0 % 8, whiteAtBottom: false) },
            tintDistances: tintDistances, board: DisplayGrid.toSquares(displayPieces, whiteAtBottom: false), premove: premove)
        func plausible(_ r: LastMoveResolver.Resolution?, whiteAtBottom: Bool) -> Bool? {
            guard let r else { return nil }
            let board = DisplayGrid.toSquares(displayPieces, whiteAtBottom: whiteAtBottom)
            guard let piece = board[r.to.index] else { return nil }
            guard piece.kind == .pawn || piece.kind == .king else { return nil }
            return LastMoveResolver.isPlausible(piece, from: r.from, to: r.to)
                || LastMoveResolver.castling(r.highlighted[0], r.highlighted[1], board: board) != nil
        }
        switch (plausible(white, whiteAtBottom: true), plausible(black, whiteAtBottom: false)) {
        case (true?, false?): return 3
        case (false?, true?): return -3
        case (true?, nil): return 2
        case (nil, true?): return -2
        default: return 0
        }
    }

    /// Log-odds from a tinted (selected) pawn and the legal-move dots straight ahead of it: a
    /// white pawn's dots lie above it when white is at the bottom.
    public static func pawnHintLogOdds(tintedCells: [Int], dotCells: [Int], displayPieces: [Piece?]) -> Double {
        guard !dotCells.isEmpty else { return 0 }
        var total = 0.0
        for cell in tintedCells {
            guard let piece = displayPieces[cell], piece.kind == .pawn else { continue }
            let row = cell / 8, column = cell % 8
            let ahead = dotCells.filter { $0 % 8 == column && abs($0 / 8 - row) <= 2 && $0 / 8 != row }
            guard !ahead.isEmpty else { continue }
            let up = ahead.allSatisfy { $0 / 8 < row }, down = ahead.allSatisfy { $0 / 8 > row }
            guard up != down else { continue }
            // Up the screen is forward for white when white is at the bottom.
            total += (up == (piece.color == .white)) ? 2.5 : -2.5
        }
        return max(-4, min(4, total))
    }

    /// Coordinate evidence (glyph shapes plus text) of at least this size is decisive: across
    /// about 9,400 rendered screenshots with coordinate evidence of 4 or more it never pointed the
    /// wrong way, while readings of 3 to 4 were wrong 4 times in 686.
    static let decisiveCoordinateEvidence = 4.0
    /// Factor applied to decisive coordinate evidence, so that coordinates that were read clearly
    /// outweigh the placement of the pieces (real_100: coordinates -6, five promoted queens on
    /// the far rank +6.3).
    static let decisiveCoordinateWeight = 2.5
    /// Below this confidence, an orientation that no coordinate reading or start position
    /// supports is reported as a doubt. The placement model is calibrated on real positions, so
    /// this flags about half of the boards with 6 to 8 pieces and 8% of those with 9 to 11, and
    /// lets through about 2% of the wrong orientations among them.
    static let unsupportedOrientationConfidence: Float = 0.97

    /// The log-odds `decide` uses: the evidence total with decisive coordinate evidence weighted up.
    public static func combinedLogOdds(_ evidence: OrientationEvidence) -> Double {
        let coordinates = evidence.textRecognition + evidence.glyphShapes
        let weight = abs(coordinates) >= decisiveCoordinateEvidence ? decisiveCoordinateWeight : 1
        return evidence.total + (weight - 1) * coordinates
    }

    /// Combines log-odds into (whiteAtBottom, confidence).
    public static func decide(_ evidence: OrientationEvidence) -> (Bool, Float) {
        let total = combinedLogOdds(evidence)
        let probability = 1 / (1 + exp(-abs(total)))
        return (total >= 0, Float(probability))
    }

    /// A doubt when the orientation rests on piece placement (and possibly the direction of a
    /// highlighted move) without decisive coordinates or the start position, and the confidence
    /// is below `unsupportedOrientationConfidence`: sparse boards without readable coordinates
    /// are the ones read upside down.
    ///
    /// Coordinates of at least `confirmingCoordinateEvidence` that agree with the decision confirm
    /// it; if they disagree, the placement outweighed them, which is itself a doubt. Without them, a board with promoted material (two queens, or three rooks, bishops or
    /// knights, of one color) is always doubted: such positions are rare in real games, so the
    /// placement model's confidence does not hold for them (real_102: three black queens and the
    /// black king on their own back ranks, which the model reads as just-promoted queens mating a
    /// king on its home rank, at confidence 0.99).
    public static func doubt(_ evidence: OrientationEvidence, displayPieces: [Piece?]) -> String? {
        let coordinates = evidence.textRecognition + evidence.glyphShapes
        let (whiteAtBottom, confidence) = decide(evidence)
        if abs(coordinates) >= confirmingCoordinateEvidence {
            if (coordinates > 0) == whiteAtBottom { return nil }
            return String(format: "coordinates disagree with the piece placement (confidence %.2f)", confidence)
        }
        guard evidence.startPosition == 0 else { return nil }
        if hasPromotedMaterial(displayPieces) {
            return String(format: "orientation not confirmed by coordinates, promoted pieces (confidence %.2f)", confidence)
        }
        guard confidence < unsupportedOrientationConfidence else { return nil }
        return String(format: "orientation not confirmed by coordinates (confidence %.2f)", confidence)
    }

    /// Coordinate evidence that confirms an orientation it agrees with. Readings of 3 to 4 were
    /// wrong 4 times in 686, each time outweighed by strong piece evidence.
    static let confirmingCoordinateEvidence = 3.0

    /// Whether one color has more than one queen, or more than two rooks, bishops or knights.
    static func hasPromotedMaterial(_ pieces: [Piece?]) -> Bool {
        var counts: [Piece: Int] = [:]
        for piece in pieces.compactMap({ $0 }) { counts[piece, default: 0] += 1 }
        return counts.contains { piece, count in
            switch piece.kind {
            case .queen: return count > 1
            case .rook, .bishop, .knight: return count > 2
            case .pawn, .king: return false
            }
        }
    }
}
