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
/// identifier, favorite flag, and optional custom name.
struct SavedClimb: Identifiable, Codable, Hashable {
    let id: UUID
    var route: BoulderRoute
    let savedAt: Date
    var isFavorite: Bool
    var customName: String?

    init(route: BoulderRoute,
         id: UUID = UUID(),
         savedAt: Date = Date(),
         isFavorite: Bool = false,
         customName: String? = nil) {
        self.id = id
        self.route = route
        self.savedAt = savedAt
        self.isFavorite = isFavorite
        self.customName = customName
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
