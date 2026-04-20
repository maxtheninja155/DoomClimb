import Foundation
import SwiftUI

// MARK: - Hold Data Model
// Designed for future ingestion from SQLite (via GRDB/SQLite.swift) or JSON (Codable).
// Each hold on the physical board has a fixed coordinate and a role assigned per-route.

struct Hold: Identifiable, Codable, Hashable {
    let id: Int                 // Primary key — matches the physical board's hole ID
    let row: Int                // 0-indexed row on the grid (bottom = 0)
    let col: Int                // 0-indexed column on the grid (left = 0)
    let x: Double               // Normalized x position (0.0–1.0) for non-uniform boards
    let y: Double               // Normalized y position (0.0–1.0)
    let holdType: HoldType      // Physical shape bolted onto the wall
    let difficulty: Int          // 1–10 scale of how "bad" this hold is

    // Convenience initializer for uniform grids where x/y map directly from row/col
    init(id: Int, row: Int, col: Int, columns: Int, rows: Int,
         holdType: HoldType = .jug, difficulty: Int = 5) {
        self.id = id
        self.row = row
        self.col = col
        self.x = Double(col) / Double(max(columns - 1, 1))
        self.y = Double(row) / Double(max(rows - 1, 1))
        self.holdType = holdType
        self.difficulty = difficulty
    }

    // Full initializer for loading from database / JSON
    init(id: Int, row: Int, col: Int, x: Double, y: Double,
         holdType: HoldType, difficulty: Int) {
        self.id = id
        self.row = row
        self.col = col
        self.x = x
        self.y = y
        self.holdType = holdType
        self.difficulty = difficulty
    }
}

// MARK: - Enums

enum HoldType: String, Codable, CaseIterable {
    case jug, crimp, sloper, pinch, pocket, volume
}

/// The role a hold plays *within a specific route*.
enum HoldRole: String, Codable {
    case start      // Green
    case middle     // Cyan / Blue
    case finish     // Magenta / Red
    case footOnly   // Yellow

    var color: Color {
        switch self {
        case .start:    return .green
        case .middle:   return Color(red: 0.0, green: 0.75, blue: 0.9)   // Cyan
        case .finish:   return Color(red: 0.9, green: 0.15, blue: 0.4)   // Magenta-red
        case .footOnly: return .yellow
        }
    }

    var label: String {
        switch self {
        case .start:    return "Start"
        case .middle:   return "Hand"
        case .finish:   return "Finish"
        case .footOnly: return "Foot"
        }
    }
}

/// One hold's assignment in a generated route.
struct RouteHold: Identifiable, Hashable, Codable {
    var id: Int { hold.id }
    let hold: Hold
    let role: HoldRole
}

/// A fully generated boulder problem.
struct BoulderRoute: Codable, Hashable {
    let name: String?          // Real climb name from the database (nil for mock routes)
    let holds: [RouteHold]
    let grade: String
    let angle: Int
    let technique: String
    let generatedAt: Date

    var moveCount: Int {
        holds.filter { $0.role == .middle || $0.role == .finish }.count
    }
}

// MARK: - Saved Climb (history + favorites wrapper)

/// A climb that has been saved to history. Wraps a `BoulderRoute` with a stable
/// identifier, favorite flag, optional custom name, and send-tracking state.
struct SavedClimb: Identifiable, Codable, Hashable {
    let id: UUID
    var route: BoulderRoute
    let savedAt: Date
    var isFavorite: Bool
    var customName: String?

    // Send tracking
    var attempts: Int
    var isSent: Bool
    var sentAt: Date?

    init(route: BoulderRoute,
         id: UUID = UUID(),
         savedAt: Date = Date(),
         isFavorite: Bool = false,
         customName: String? = nil,
         attempts: Int = 0,
         isSent: Bool = false,
         sentAt: Date? = nil) {
        self.id = id
        self.route = route
        self.savedAt = savedAt
        self.isFavorite = isFavorite
        self.customName = customName
        self.attempts = attempts
        self.isSent = isSent
        self.sentAt = sentAt
    }

    // Custom decoder preserves backwards compatibility with history files
    // saved before the send-tracking fields existed.
    enum CodingKeys: String, CodingKey {
        case id, route, savedAt, isFavorite, customName, attempts, isSent, sentAt
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id         = try c.decode(UUID.self,         forKey: .id)
        self.route      = try c.decode(BoulderRoute.self, forKey: .route)
        self.savedAt    = try c.decode(Date.self,         forKey: .savedAt)
        self.isFavorite = try c.decode(Bool.self,         forKey: .isFavorite)
        self.customName = try c.decodeIfPresent(String.self, forKey: .customName)
        self.attempts   = try c.decodeIfPresent(Int.self,    forKey: .attempts) ?? 0
        self.isSent     = try c.decodeIfPresent(Bool.self,   forKey: .isSent)   ?? false
        self.sentAt     = try c.decodeIfPresent(Date.self,   forKey: .sentAt)
    }
}

// MARK: - Session Planner

/// Status of a single entry in a planned session.
enum SessionStatus: String, Codable {
    case pending, done, skipped
}

/// One climb slot in a planned session, referencing a `SavedClimb` by id.
struct SessionEntry: Identifiable, Codable, Hashable {
    let id: UUID
    let climbId: UUID
    let category: SessionCategory
    var status: SessionStatus

    init(id: UUID = UUID(),
         climbId: UUID,
         category: SessionCategory,
         status: SessionStatus = .pending) {
        self.id = id
        self.climbId = climbId
        self.category = category
        self.status = status
    }
}

// MARK: - Generation Mode

enum GenerationMode: String, CaseIterable, Identifiable {
    case kilterClimbs   = "Kilter Climbs"
    case newGenerated   = "New Generated"

    var id: String { rawValue }
}

// MARK: - Technique Presets

enum Technique: String, CaseIterable, Identifiable {
    case bigSpans       = "Big Spans"
    case staticTech     = "Static / Technical"
    case highTension    = "High Tension"
    case dynamic        = "Dynamic / Coordination"
    case compression    = "Compression"
    case slopers        = "Sloper Fest"
    case crimps         = "Crimp Ladder"
    case mixed          = "Mixed / Random"

    var id: String { rawValue }
}
