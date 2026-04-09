import Foundation
import simd

// MARK: - LED Mapping Service
// Maps placement IDs (used in our app) to LED positions (used by the physical board)
// via the chain: placement_id → hole_id (placements.json) → LED position (leds.json)

final class LEDMappingService {

    // MARK: - Board Size

    /// Kilter Board product_size_id values (product_id = 1)
    enum BoardSize: Int, CaseIterable, Identifiable {
        case commercial12x14    = 7    // 12 x 14 Commercial
        case home8x12           = 8    // 8 x 12 Home
        case square12x12        = 10   // 12 x 12 with kickboard
        case small7x10          = 14   // 7 x 10 Small
        case squareNoKB12x12    = 27   // 12 x 12 without kickboard
        case superWide16x12     = 28   // 16 x 12 Super Wide

        var id: Int { rawValue }

        var displayName: String {
            switch self {
            case .commercial12x14:  return "12×14 Commercial"
            case .home8x12:         return "8×12 Home"
            case .square12x12:      return "12×12 (with kickboard)"
            case .small7x10:        return "7×10 Small"
            case .squareNoKB12x12:  return "12×12 (no kickboard)"
            case .superWide16x12:   return "16×12 Super Wide"
            }
        }
    }

    // MARK: - Properties

    /// placement_id → hole_id (from placements.json, layout_id = 1)
    private let placementToHole: [Int: Int]

    /// (hole_id, product_size_id) → LED position (from leds.json)
    private let holeLEDMap: [Int: [Int: Int]]  // hole_id → [product_size_id: position]

    // MARK: - Init

    init?() {
        // Load placements.json
        guard let placementsURL = Bundle.main.url(forResource: "placements", withExtension: "json"),
              let placementsData = try? Data(contentsOf: placementsURL),
              let placements = try? JSONSerialization.jsonObject(with: placementsData) as? [[String: Any]] else {
            print("LEDMapping ❌  Failed to load placements.json")
            return nil
        }

        // Build placement_id → hole_id (layout_id = 1 for Kilter Board)
        var pToH: [Int: Int] = [:]
        for p in placements {
            guard let pid = p["id"] as? Int,
                  let holeId = p["hole_id"] as? Int else { continue }
            pToH[pid] = holeId
        }
        self.placementToHole = pToH

        // Load leds.json
        guard let ledsURL = Bundle.main.url(forResource: "leds", withExtension: "json"),
              let ledsData = try? Data(contentsOf: ledsURL),
              let leds = try? JSONSerialization.jsonObject(with: ledsData) as? [[String: Any]] else {
            print("LEDMapping ❌  Failed to load leds.json")
            return nil
        }

        // Build hole_id → [product_size_id: LED position]
        // Only keep Kilter Board product_size_ids
        let validSizes = Set(BoardSize.allCases.map(\.rawValue))
        var hMap: [Int: [Int: Int]] = [:]
        for led in leds {
            guard let holeId = led["hole_id"] as? Int,
                  let position = led["position"] as? Int,
                  let sizeId = led["product_size_id"] as? Int,
                  validSizes.contains(sizeId) else { continue }
            hMap[holeId, default: [:]][sizeId] = position
        }
        self.holeLEDMap = hMap

        print("LEDMapping ✅  Loaded — \(pToH.count) placements, \(hMap.count) hole→LED entries")
    }

    // MARK: - Lookup

    /// Convert a placement_id to an LED position for the given board size.
    func ledPosition(forPlacement placementId: Int, boardSize: BoardSize) -> Int? {
        guard let holeId = placementToHole[placementId],
              let sizeMap = holeLEDMap[holeId],
              let position = sizeMap[boardSize.rawValue] else {
            return nil
        }
        return position
    }

    /// Convert a full route into LED (position, role) pairs for the given board size.
    func ledPlacements(for route: BoulderRoute, boardSize: BoardSize) -> [(position: Int, role: HoldRole)] {
        var result: [(position: Int, role: HoldRole)] = []
        for rh in route.holds {
            if let pos = ledPosition(forPlacement: rh.hold.id, boardSize: boardSize) {
                result.append((position: pos, role: rh.role))
            } else {
                print("LEDMapping ⚠️  No LED for placement \(rh.hold.id) on \(boardSize.displayName)")
            }
        }
        return result
    }
}
