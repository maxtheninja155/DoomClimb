import Foundation

// MARK: - Route Generator Service
// This is the mock generator. Replace the body of `generate()` with a CoreML
// inference call or a network request to your API when you're ready.

class RouteGenerator {

    // 12x12 Kilter Board: 18×18 grid, holds at 8" spacing starting 4" from each edge.
    // Normalized to 0–1: margin = 4/144 = 1/36, spacing = 8/144 = 1/18.
    static let boardColumns  = 18
    static let boardRows     = 18
    private static let holdMargin  = 1.0 / 36.0  // 0.02̄7̄  (4" / 144")
    private static let holdSpacing = 1.0 / 18.0  // 0.05̄   (8" / 144")

    static let defaultBoard: [Hold] = {
        var holds: [Hold] = []
        var idCounter = 0
        for row in 0..<boardRows {
            for col in 0..<boardColumns {
                let holdType  = HoldType.allCases.randomElement() ?? .jug
                let difficulty = Int.random(in: 1...10)
                // Pixel-accurate normalized position matching the physical board
                let x = holdMargin + Double(col) * holdSpacing
                let y = holdMargin + Double(row) * holdSpacing
                holds.append(Hold(
                    id: idCounter,
                    row: row, col: col,
                    x: x, y: y,
                    holdType: holdType,
                    difficulty: difficulty
                ))
                idCounter += 1
            }
        }
        return holds
    }()

    // MARK: - Public generation entry point

    /// Mock generation function. Signature is intentionally async so you can
    /// drop in a real model / network call later with zero call-site changes.
    func generate(
        board: [Hold],
        grade: Int,            // V-scale number (0–16)
        angle: Int,            // Wall angle in degrees
        technique: Technique
    ) async -> BoulderRoute {

        // 1. Decide route length from grade
        let moveCount = movesForGrade(grade)
        let footCount = max(1, moveCount / 2)

        // 2. Pick start holds (bottom two rows)
        let startCandidates = board.filter { $0.row <= 1 }
        let starts = pickRandom(from: startCandidates, count: 2, technique: technique)

        // 3. Pick finish holds (top two rows)
        let finishCandidates = board.filter { $0.row >= RouteGenerator.boardRows - 2 }
        let finishes = pickRandom(from: finishCandidates, count: 1, technique: technique)

        // 4. Pick middle holds (rows in between)
        let middleCandidates = board.filter { $0.row > 1 && $0.row < RouteGenerator.boardRows - 2 }
        let middles = pickRandom(from: middleCandidates, count: moveCount, technique: technique)

        // 5. Pick foot-only holds
        let footCandidates = board.filter { hold in
            !starts.contains(hold) && !finishes.contains(hold) && !middles.contains(hold)
        }
        let feet = Array(footCandidates.shuffled().prefix(footCount))

        // 6. Assemble route
        var routeHolds: [RouteHold] = []
        routeHolds += starts.map   { RouteHold(hold: $0, role: .start) }
        routeHolds += middles.map  { RouteHold(hold: $0, role: .middle) }
        routeHolds += finishes.map { RouteHold(hold: $0, role: .finish) }
        routeHolds += feet.map     { RouteHold(hold: $0, role: .footOnly) }

        return BoulderRoute(
            name: nil,
            holds: routeHolds,
            grade: "V\(grade)",
            angle: angle,
            technique: technique.rawValue,
            generatedAt: .now
        )
    }

    // MARK: - Private helpers

    private func movesForGrade(_ grade: Int) -> Int {
        switch grade {
        case 0...2:  return Int.random(in: 4...6)
        case 3...5:  return Int.random(in: 5...8)
        case 6...8:  return Int.random(in: 6...10)
        case 9...11: return Int.random(in: 7...11)
        default:     return Int.random(in: 8...13)
        }
    }

    private func pickRandom(from candidates: [Hold], count: Int,
                            technique: Technique) -> [Hold] {
        guard !candidates.isEmpty else { return [] }

        switch technique {
        case .bigSpans:
            return spreadSelection(from: candidates, count: count)
        case .highTension:
            return tensionSelection(from: candidates, count: count)
        case .crimps:
            let pool = candidates.filter { $0.holdType == .crimp }
            return Array((pool.isEmpty ? candidates : pool).shuffled().prefix(count))
        case .slopers:
            let pool = candidates.filter { $0.holdType == .sloper }
            return Array((pool.isEmpty ? candidates : pool).shuffled().prefix(count))
        default:
            return Array(candidates.shuffled().prefix(count))
        }
    }

    private func spreadSelection(from candidates: [Hold], count: Int) -> [Hold] {
        guard candidates.count >= count else { return candidates }
        let sorted = candidates.sorted { $0.col < $1.col }
        let step = max(sorted.count / max(count, 1), 1)
        var result: [Hold] = []
        var idx = 0
        while result.count < count && idx < sorted.count {
            result.append(sorted[idx])
            idx += step
        }
        return result
    }

    private func tensionSelection(from candidates: [Hold], count: Int) -> [Hold] {
        guard candidates.count >= count else { return candidates }
        let sorted = candidates.sorted { $0.row < $1.row }
        var result: [Hold] = []
        var lastCol = RouteGenerator.boardColumns / 2
        for hold in sorted {
            guard result.count < count else { break }
            if abs(hold.col - lastCol) > 3 {
                result.append(hold)
                lastCol = hold.col
            }
        }
        if result.count < count {
            let remaining = candidates.filter { !result.contains($0) }.shuffled()
            result += remaining.prefix(count - result.count)
        }
        return result
    }
}
