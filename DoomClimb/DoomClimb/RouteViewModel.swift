import Foundation
import SwiftUI
import Combine

@MainActor
class RouteViewModel: ObservableObject {

    // MARK: - Input state (bound to UI controls)
    @Published var gradeValue: Double = 5        // V0–V16
    @Published var angleValue: Double = 40       // 0°–60°
    @Published var generationMode: GenerationMode = .kilterClimbs
    @Published var selectedTechnique: Technique = .mixed

    // MARK: - Output state
    @Published var isGenerating = false

    /// ID of the currently displayed climb within `store.history`.
    /// `nil` when no climb is being shown (e.g. right after Clear).
    @Published var currentClimbId: UUID?

    /// The route currently being displayed, looked up fresh from the store
    /// via `currentClimbId`. Making this computed (rather than a duplicate
    /// `@Published` copy) means any edit made to the underlying climb in
    /// the store — e.g. from the climb editor — is instantly reflected on
    /// the main screen without needing a manual sync.
    var currentRoute: BoulderRoute? {
        guard let id = currentClimbId else { return nil }
        return store.history.first(where: { $0.id == id })?.route
    }

    // MARK: - Bluetooth
    let ble = KilterBoardBLE()
    @Published var selectedBoardSize: LEDMappingService.BoardSize = .square12x12
    @Published var showBluetoothSheet = false
    @Published var ledSendStatus: String?

    // MARK: - Services
    private let database      = KilterDatabaseService()      // nil if kilter.db not in bundle
    private let coreMLGenerator = CoreMLRouteGenerator()      // nil if ClimbGPT.mlpackage not in bundle
    private let mockGenerator = RouteGenerator()              // fallback mock generator
    private let ledMapping    = LEDMappingService()           // nil if JSON files not in bundle
    let board: [Hold]         = RouteGenerator.defaultBoard   // mock fallback pool

    // MARK: - Climb history (auto-save, favorites, navigation)
    let store = ClimbHistoryStore()

    /// Forwards `store`'s change notifications to this VM so SwiftUI views
    /// that observe the VM (not the store directly) re-render when the
    /// store mutates — e.g. when a favorite is toggled.
    private var storeSubscription: AnyCancellable?

    // MARK: - Derived display values
    var gradeLabel: String { "V\(Int(gradeValue))" }
    var angleLabel: String { "\(Int(angleValue))°" }

    // MARK: - Init

    init() {
        // Re-emit whenever the store changes so views observing this VM
        // pick up favorite-toggle / delete / rename updates instantly.
        storeSubscription = store.objectWillChange
            .sink { [weak self] _ in
                self?.objectWillChange.send()
            }
    }

    // MARK: - Actions

    func generateRoute() {
        isGenerating = true
        currentClimbId = nil

        Task {
            // Small delay so the spinner feels intentional
            try? await Task.sleep(for: .milliseconds(300))

            let grade = Int(gradeValue)
            let angle = Int(angleValue)

            var route: BoulderRoute?

            switch generationMode {
            case .kilterClimbs:
                // Pull a real community-set climb from the Kilter database
                route = database?.fetchRandomClimb(grade: grade, angle: angle)

            case .newGenerated:
                // Try CoreML, rejecting routes that exactly match an existing Kilter climb.
                // The model was trained on real Kilter data and can memorize popular routes.
                let maxDuplicateRetries = 4
                for attempt in 1...maxDuplicateRetries {
                    guard let candidate = coreMLGenerator?.generate(grade: grade, angle: angle) else {
                        break  // CoreML unavailable — stop trying, fall through to mock
                    }
                    let placementIds = candidate.holds.map(\.hold.id)
                    if let db = database, db.isKnownClimb(placementIds: placementIds, grade: grade) {
                        print("RouteVM ⚠️  Generated route matches a known Kilter climb (attempt \(attempt)/\(maxDuplicateRetries)) — retrying")
                        if attempt == maxDuplicateRetries {
                            route = candidate  // Accept on final attempt rather than falling back to mock
                            print("RouteVM ⚠️  Accepting duplicate after \(maxDuplicateRetries) attempts")
                        }
                    } else {
                        route = candidate
                        break
                    }
                }

                if route == nil {
                    print("RouteVM ⚠️  CoreML unavailable, falling back to mock generator")
                    route = await mockGenerator.generate(
                        board: board,
                        grade: grade,
                        angle: angle,
                        technique: selectedTechnique
                    )
                }
            }

            // Filter holds to only those with valid LED positions for the selected board
            // size. The board photo includes 3 extra "commercial" rows at the top
            // (physical_y = 160/168/176) that don't exist on a standard 12×12 board.
            // Without this filter, those holds appear on the phone display but don't
            // light up on the physical board, creating an apparent 3-row shift.
            if let r = route {
                route = filterHoldsForBoardSize(r)
            }

            // Auto-save to history and snap current selection to the new climb
            var newClimbId: UUID?
            if let r = route {
                let saved = store.append(r)
                newClimbId = saved.id
                print("RouteVM 💾  Appended climb → total history: \(store.history.count)")
                print("          ID:          \(saved.id.uuidString.prefix(8))…")
                print("          Display:     \(store.displayName(for: saved))")
                print("          Grade/Angle: \(r.grade) @ \(r.angle)°")
                print("          Moves:       \(r.moveCount)")
                print("          Favorites:   \(store.favorites.count)")
            }

            withAnimation(.easeInOut(duration: 0.35)) {
                currentClimbId = newClimbId
                isGenerating = false
            }
        }
    }

    // MARK: - History navigation

    /// The `SavedClimb` currently being displayed, if any.
    var currentSavedClimb: SavedClimb? {
        guard let id = currentClimbId else { return nil }
        return store.history.first(where: { $0.id == id })
    }

    /// True if there's a climb earlier than the current one in history.
    var canGoBack: Bool {
        guard let id = currentClimbId,
              let idx = store.history.firstIndex(where: { $0.id == id })
        else { return false }
        return idx > 0
    }

    /// True if there's a climb later than the current one in history.
    var canGoForward: Bool {
        guard let id = currentClimbId,
              let idx = store.history.firstIndex(where: { $0.id == id })
        else { return false }
        return idx < store.history.count - 1
    }

    /// Move to the previous climb in history (does nothing if at start).
    func goBack() {
        guard canGoBack,
              let id = currentClimbId,
              let idx = store.history.firstIndex(where: { $0.id == id }) else { return }
        let prev = store.history[idx - 1]
        withAnimation(.easeInOut(duration: 0.25)) {
            currentClimbId = prev.id
        }
        print("RouteVM ◀️  Back → \(store.displayName(for: prev))")
    }

    /// Move to the next climb in history (does nothing if at end).
    func goForward() {
        guard canGoForward,
              let id = currentClimbId,
              let idx = store.history.firstIndex(where: { $0.id == id }) else { return }
        let next = store.history[idx + 1]
        withAnimation(.easeInOut(duration: 0.25)) {
            currentClimbId = next.id
        }
        print("RouteVM ▶️  Forward → \(store.displayName(for: next))")
    }

    // MARK: - Favorites

    /// Whether the currently displayed climb is marked as favorite.
    var isCurrentFavorited: Bool {
        currentSavedClimb?.isFavorite ?? false
    }

    /// Toggle the favorite flag on the currently displayed climb.
    func toggleFavoriteCurrent() {
        guard let id = currentClimbId else { return }
        store.toggleFavorite(id: id)
        let nowFav = isCurrentFavorited
        print("RouteVM \(nowFav ? "⭐️" : "☆")  Favorite toggled → total favorites: \(store.favorites.count)")
    }

    // MARK: - Board-size filtering

    /// Returns a copy of `route` containing only holds that have a valid LED position
    /// for `selectedBoardSize`. Holds from the mock generator (IDs 0–999) are skipped
    /// since they don't live in the physical LED map.
    private func filterHoldsForBoardSize(_ route: BoulderRoute) -> BoulderRoute {
        guard let mapping = ledMapping else { return route }

        // Mock-generator holds use IDs 0–323; skip filtering for those routes.
        let usesRealIds = route.holds.contains { $0.hold.id >= 1000 }
        guard usesRealIds else { return route }

        let filtered = route.holds.filter {
            mapping.ledPosition(forPlacement: $0.hold.id, boardSize: selectedBoardSize) != nil
        }

        // Safety: if filtering leaves too few holds fall back to the unfiltered route.
        guard filtered.count >= 3 else {
            print("RouteVM ⚠️  Board-size filter removed too many holds — showing unfiltered route")
            return route
        }

        print("RouteVM ✅  Filtered \(route.holds.count) → \(filtered.count) holds for \(selectedBoardSize.displayName)")

        return BoulderRoute(
            name: route.name,
            holds: filtered,
            grade: route.grade,
            angle: route.angle,
            technique: route.technique,
            generatedAt: route.generatedAt
        )
    }

    /// Clear the currently displayed climb. Per design: this also removes the
    /// climb from history (it was a throwaway the user didn't like). Sequence
    /// numbers for remaining climbs in the same session auto-renumber because
    /// the default display name is computed dynamically.
    func clearRoute() {
        if let id = currentClimbId {
            store.delete(id: id)
            print("RouteVM 🗑️  Cleared climb \(id.uuidString.prefix(8))… → history: \(store.history.count)")
        }
        withAnimation {
            currentClimbId = nil
        }
    }

    /// Look up the role for a given hold in the current route (used by mock board rendering).
    func role(for hold: Hold) -> HoldRole? {
        currentRoute?.holds.first(where: { $0.hold.id == hold.id })?.role
    }

    // MARK: - Bluetooth / LED Actions

    /// Send the current route's holds to the connected Kilter Board LEDs
    func sendToBoard() {
        guard let route = currentRoute else {
            ledSendStatus = "No route to send"
            return
        }
        sendToBoard(route)
    }

    /// Send a specific route's holds to the connected Kilter Board LEDs.
    /// Used by detail views that render a climb other than the current one.
    func sendToBoard(_ route: BoulderRoute) {
        guard ble.state.isConnected else {
            ledSendStatus = "Not connected"
            showBluetoothSheet = true
            return
        }
        guard let mapping = ledMapping else {
            ledSendStatus = "LED mapping unavailable"
            return
        }

        let placements = mapping.ledPlacements(for: route, boardSize: selectedBoardSize)

        guard !placements.isEmpty else {
            ledSendStatus = "No LEDs mapped for this board size"
            return
        }

        let chunks = KilterBoardProtocol.buildMessage(placements: placements)
        ble.sendLEDs(chunks: chunks)
        ledSendStatus = "Sent \(placements.count) holds to board"

        // Clear status after a few seconds
        Task {
            try? await Task.sleep(for: .seconds(3))
            if ledSendStatus?.starts(with: "Sent") == true {
                ledSendStatus = nil
            }
        }
    }

    /// Clear LEDs on the board
    func clearBoard() {
        guard ble.state.isConnected else { return }
        ble.clearLEDs()
        ledSendStatus = "LEDs cleared"
        Task {
            try? await Task.sleep(for: .seconds(2))
            if ledSendStatus == "LEDs cleared" {
                ledSendStatus = nil
            }
        }
    }
}
