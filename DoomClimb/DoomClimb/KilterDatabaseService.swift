import Foundation
import SQLite3

// MARK: - Kilter Database Service
// Queries kilter.db (bundled in the app) to fetch real community-set routes.
// Hold positions come from HoldSocketMap (blob-detected image centers),
// NOT from a mathematical formula.

final class KilterDatabaseService {

    private var db: OpaquePointer?

    private static let layoutId = 1
    private static let setId    = 1

    private static let validAngles = [0, 5, 10, 15, 20, 25, 30, 35, 40, 45, 50, 55, 60, 65, 70]

    // MARK: - Init

    init?() {
        guard let path = Bundle.main.path(forResource: "kilter", ofType: "db") else {
            print("KilterDB ❌  kilter.db not found in app bundle")
            return nil
        }
        guard sqlite3_open_v2(path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            print("KilterDB ❌  failed to open database at \(path)")
            return nil
        }
        print("KilterDB ✅  opened — \(HoldSocketMap.positions.count) sockets loaded (set 1 + set 20)")
    }

    deinit { sqlite3_close(db) }

    // MARK: - Public API

    func fetchRandomClimb(grade: Int, angle: Int) -> BoulderRoute? {
        let snappedAngle       = Self.nearestAngle(to: angle)
        let (minDiff, maxDiff) = Self.difficultyRange(for: grade)

        let sql = """
            SELECT c.name, c.frames
            FROM   climbs c
            JOIN   climb_stats cs ON cs.climb_uuid = c.uuid
            WHERE  cs.angle                = ?
              AND  cs.difficulty_average  >= ?
              AND  cs.difficulty_average   < ?
              AND  c.is_listed             = 1
              AND  c.frames_count          = 1
              AND  c.layout_id             = ?
            ORDER  BY RANDOM()
            LIMIT  1
        """

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_int(stmt,    1, Int32(snappedAngle))
        sqlite3_bind_double(stmt, 2, minDiff)
        sqlite3_bind_double(stmt, 3, maxDiff)
        sqlite3_bind_int(stmt,    4, Int32(Self.layoutId))

        guard sqlite3_step(stmt) == SQLITE_ROW else {
            print("KilterDB ⚠️  No climb found for V\(grade) at \(snappedAngle)°")
            return nil
        }

        let name   = String(cString: sqlite3_column_text(stmt, 0))
        let frames = String(cString: sqlite3_column_text(stmt, 1))

        let routeHolds = parseFrames(frames)
        guard !routeHolds.isEmpty else { return nil }

        print("KilterDB ✅  '\(name)' — \(routeHolds.count) holds, V\(grade) at \(snappedAngle)°")

        return BoulderRoute(
            name: name,
            holds: routeHolds,
            grade: "V\(grade)",
            angle: snappedAngle,
            technique: "Kilter Board",
            generatedAt: .now
        )
    }

    // MARK: - Frame parsing

    private func parseFrames(_ frames: String) -> [RouteHold] {
        let parts = frames.components(separatedBy: "p").filter { !$0.isEmpty }

        var placements: [(id: Int, roleId: Int)] = []
        for part in parts {
            let tokens = part.components(separatedBy: "r")
            guard tokens.count == 2,
                  let pid = Int(tokens[0]),
                  let rid = Int(tokens[1]) else { continue }
            placements.append((pid, rid))
        }

        // Look up each placement in the socket map — no DB query needed for positions.
        // HoldSocketMap contains exactly the 476 real climbable sockets for the
        // 12×12 with kickboard (323 bolt-ons + 153 screw-ons). Any placement_id
        // not in the map is automatically a frame bolt or unsupported hold.
        return placements.compactMap { p in
            guard let pos = HoldSocketMap.positions[p.id] else {
                print("KilterDB ⚠️  No socket for placement \(p.id) — skipping (not a climbable hold on this board)")
                return nil
            }

            let hold = Hold(id: p.id, row: 0, col: 0,
                            x: Double(pos.x), y: Double(pos.y),
                            holdType: .jug, difficulty: 5)
            return RouteHold(hold: hold, role: Self.mapRole(p.roleId))
        }
    }

    // MARK: - Duplicate Detection

    /// Per-grade cache of hold-set fingerprints. Loaded lazily on first check for each grade.
    private var fingerprintCache: [Int: Set<String>] = [:]

    /// Returns true if the placement IDs exactly match a known community climb at this grade.
    func isKnownClimb(placementIds: [Int], grade: Int) -> Bool {
        if fingerprintCache[grade] == nil {
            fingerprintCache[grade] = loadFingerprints(for: grade)
        }
        let fingerprint = placementIds.sorted().map(String.init).joined(separator: ",")
        return fingerprintCache[grade]?.contains(fingerprint) ?? false
    }

    private func loadFingerprints(for grade: Int) -> Set<String> {
        let (minDiff, maxDiff) = Self.difficultyRange(for: grade)
        let sql = """
            SELECT c.frames
            FROM   climbs c
            JOIN   climb_stats cs ON cs.climb_uuid = c.uuid
            WHERE  cs.difficulty_average >= ?
              AND  cs.difficulty_average  < ?
              AND  c.is_listed    = 1
              AND  c.layout_id    = ?
              AND  c.frames_count = 1
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_double(stmt, 1, minDiff)
        sqlite3_bind_double(stmt, 2, maxDiff)
        sqlite3_bind_int(stmt,    3, Int32(Self.layoutId))

        var fingerprints = Set<String>()
        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let raw = sqlite3_column_text(stmt, 0) else { continue }
            let frames = String(cString: raw)
            let ids = extractPlacementIds(from: frames).sorted().map(String.init).joined(separator: ",")
            if !ids.isEmpty { fingerprints.insert(ids) }
        }

        print("KilterDB ✅  Cached \(fingerprints.count) fingerprints for V\(grade) duplicate detection")
        return fingerprints
    }

    private func extractPlacementIds(from frames: String) -> [Int] {
        frames.components(separatedBy: "p").filter { !$0.isEmpty }.compactMap { part in
            Int(part.components(separatedBy: "r").first ?? "")
        }
    }

    // MARK: - Helpers

    private static func mapRole(_ roleId: Int) -> HoldRole {
        switch roleId {
        case 12: return .start
        case 13: return .middle
        case 14: return .finish
        case 15: return .footOnly
        default: return .middle
        }
    }

    private static func difficultyRange(for vGrade: Int) -> (Double, Double) {
        switch vGrade {
        case 0:  return (10, 13)
        case 1:  return (13, 15)
        case 2:  return (15, 16)
        case 3:  return (16, 18)
        case 4:  return (18, 20)
        case 5:  return (20, 22)
        case 6:  return (22, 23)
        case 7:  return (23, 24)
        case 8:  return (24, 26)
        case 9:  return (26, 27)
        case 10: return (27, 28)
        case 11: return (28, 29)
        case 12: return (29, 30)
        case 13: return (30, 31)
        case 14: return (31, 32)
        case 15: return (32, 33)
        default: return (33, 99)
        }
    }

    private static func nearestAngle(to angle: Int) -> Int {
        validAngles.min(by: { abs($0 - angle) < abs($1 - angle) }) ?? 40
    }
}
