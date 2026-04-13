import Foundation

// MARK: - Climbability Validator
// Determines whether a generated Kilter Board climb is physically possible
// by checking that hand holds form a connected path from start to finish
// within human reach distance.
//
// Algorithm: graph reachability via BFS
//   1. Collect all "hand holds" (start + middle + finish roles)
//   2. Build adjacency graph — two holds are connected if within maxReach
//   3. BFS from start holds — if any finish hold is reachable, it's climbable
//
// The maxReach threshold (0.3179) was calibrated from 66K real Kilter Board
// climbs using the 95th percentile of MST longest-edge distances.

enum ClimbabilityValidator {

    /// Calibrated from real climb data: 95th percentile of critical reaches.
    static let maxReach: Double = 0.3179

    /// Validate whether a climb is physically climbable.
    /// Returns `true` if a connected path exists from any start hold to any finish hold.
    static func isClimbable(_ holds: [RouteHold]) -> Bool {
        // Collect hand holds (start + middle + finish) with positions
        var handHolds: [(id: Int, x: Double, y: Double)] = []
        var startIndices: [Int] = []
        var finishIndices: [Int] = []

        for rh in holds {
            guard rh.role != .footOnly else { continue }

            let idx = handHolds.count
            handHolds.append((id: rh.hold.id, x: rh.hold.x, y: rh.hold.y))

            switch rh.role {
            case .start:  startIndices.append(idx)
            case .finish: finishIndices.append(idx)
            default:      break
            }
        }

        // Structural checks
        guard !startIndices.isEmpty,
              !finishIndices.isEmpty,
              handHolds.count >= 3 else {
            return false
        }

        // Build adjacency graph
        let n = handHolds.count
        var adj = [[Int]](repeating: [], count: n)
        for i in 0..<n {
            for j in (i + 1)..<n {
                let dx = handHolds[i].x - handHolds[j].x
                let dy = handHolds[i].y - handHolds[j].y
                let dist = (dx * dx + dy * dy).squareRoot()
                if dist <= maxReach {
                    adj[i].append(j)
                    adj[j].append(i)
                }
            }
        }

        // BFS from all start holds
        let finishSet = Set(finishIndices)
        var visited = Set(startIndices)
        var queue = startIndices

        var head = 0
        while head < queue.count {
            let node = queue[head]
            head += 1

            if finishSet.contains(node) {
                return true
            }

            for neighbor in adj[node] {
                if !visited.contains(neighbor) {
                    visited.insert(neighbor)
                    queue.append(neighbor)
                }
            }
        }

        return false
    }
}
