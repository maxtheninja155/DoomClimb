import Foundation
import Combine

// MARK: - Climb History Store
// Persists generated climbs to disk as JSON. Provides history + favorites,
// auto-prunes the oldest non-favorited climb when the cap is reached, and
// publishes changes so SwiftUI can react.

@MainActor
final class ClimbHistoryStore: ObservableObject {

    // MARK: - Configuration

    /// Hard cap on total stored climbs. When exceeded, the oldest
    /// non-favorited climb is pruned. Favorites never count against the cap.
    static let maxClimbs = 5000

    // MARK: - Published state

    /// All saved climbs in chronological order (oldest → newest).
    @Published private(set) var history: [SavedClimb] = []

    /// Convenience view of just favorited climbs (newest first).
    var favorites: [SavedClimb] {
        history.filter(\.isFavorite).reversed()
    }

    // MARK: - Storage

    private let fileURL: URL

    init(filename: String = "climb_history.json") {
        let docs = FileManager.default.urls(
            for: .documentDirectory, in: .userDomainMask
        )[0]
        self.fileURL = docs.appendingPathComponent(filename)
        load()
    }

    // MARK: - Mutations

    /// Append a newly generated route to history. Returns the saved wrapper.
    @discardableResult
    func append(_ route: BoulderRoute) -> SavedClimb {
        let climb = SavedClimb(route: route)
        history.append(climb)
        prune()
        save()
        return climb
    }

    /// Remove a climb by id. Safe to call with an unknown id.
    func delete(id: UUID) {
        history.removeAll { $0.id == id }
        save()
    }

    /// Toggle favorite flag on a climb.
    func toggleFavorite(id: UUID) {
        guard let idx = history.firstIndex(where: { $0.id == id }) else { return }
        history[idx].isFavorite.toggle()
        save()
    }

    /// Replace the route (holds / grade / etc.) of an existing climb in
    /// place. Used by the climb editor. All other fields on the SavedClimb
    /// wrapper (id, savedAt, isFavorite, customName) are preserved.
    func updateRoute(id: UUID, to route: BoulderRoute) {
        guard let idx = history.firstIndex(where: { $0.id == id }) else { return }
        history[idx].route = route
        save()
    }

    /// Set a user-provided custom name on a climb. Passing `nil` or empty
    /// string clears the custom name (reverts to the default display name).
    func rename(id: UUID, to name: String?) {
        guard let idx = history.firstIndex(where: { $0.id == id }) else { return }
        let trimmed = name?.trimmingCharacters(in: .whitespacesAndNewlines)
        history[idx].customName = (trimmed?.isEmpty == false) ? trimmed : nil
        save()
    }

    // MARK: - Display-name helper

    /// The name to show for a climb in lists/headers. Priority:
    ///   1. User-assigned custom name (from `rename(id:to:)`)
    ///   2. Real Kilter DB climb name (for climbs pulled from kilter.db)
    ///   3. Auto-generated default: `V4@40_Climb#13` where the sequence
    ///      number is the climb's position within its day-session.
    ///
    /// Note: renaming a climb does not shift the position numbers of
    /// surrounding climbs. A renamed climb still occupies its slot, so
    /// its neighbors keep their original numbers (e.g. renaming #5
    /// leaves #4 and #6 intact with a gap where #5 would be).
    func displayName(for climb: SavedClimb) -> String {
        // 1. User-set custom name wins.
        if let custom = climb.customName, !custom.isEmpty { return custom }

        // 2. Real DB climb name for Kilter database climbs.
        if let dbName = climb.route.name, !dbName.isEmpty { return dbName }

        // 3. Fallback: position-based default.
        let cal = Calendar.current
        let day = cal.startOfDay(for: climb.savedAt)
        let sameDay = history.filter { cal.startOfDay(for: $0.savedAt) == day }
        let position = (sameDay.firstIndex(where: { $0.id == climb.id }) ?? 0) + 1

        return "\(climb.route.grade)@\(climb.route.angle)_Climb#\(position)"
    }

    // MARK: - Grouping

    /// Climbs grouped by calendar day, newest day first, newest climb first
    /// within each day. Used by the History sheet.
    func groupedByDay() -> [(day: Date, climbs: [SavedClimb])] {
        let cal = Calendar.current
        let groups = Dictionary(grouping: history) { cal.startOfDay(for: $0.savedAt) }
        return groups
            .map { (day: $0.key, climbs: $0.value.sorted { $0.savedAt > $1.savedAt }) }
            .sorted { $0.day > $1.day }
    }

    // MARK: - Persistence

    private func load() {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            print("ClimbHistoryStore 📭  No existing history file")
            return
        }
        do {
            let data = try Data(contentsOf: fileURL)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            history = try decoder.decode([SavedClimb].self, from: data)
            print("ClimbHistoryStore ✅  Loaded \(history.count) climbs from disk")
        } catch {
            print("ClimbHistoryStore ⚠️  Failed to load history: \(error)")
            history = []
        }
    }

    private func save() {
        do {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(history)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            print("ClimbHistoryStore ❌  Failed to save history: \(error)")
        }
    }

    /// Record a new attempt on a climb. Incrementing-only; does not flip `isSent`.
    func logAttempt(id: UUID) {
        guard let idx = history.firstIndex(where: { $0.id == id }) else { return }
        history[idx].attempts += 1
        save()
    }

    /// Undo the most recent attempt (does nothing if attempts is already 0).
    func undoAttempt(id: UUID) {
        guard let idx = history.firstIndex(where: { $0.id == id }) else { return }
        if history[idx].attempts > 0 {
            history[idx].attempts -= 1
            save()
        }
    }

    /// Mark a climb as sent (completed). Also increments attempts so the send
    /// counts as an attempt if the user never tapped Log Attempt first.
    func markSent(id: UUID) {
        guard let idx = history.firstIndex(where: { $0.id == id }) else { return }
        if !history[idx].isSent {
            history[idx].isSent = true
            history[idx].sentAt = Date()
            if history[idx].attempts == 0 {
                history[idx].attempts = 1
            }
            save()
        }
    }

    /// Clear the sent flag (keeps attempt count intact).
    func unmarkSent(id: UUID) {
        guard let idx = history.firstIndex(where: { $0.id == id }) else { return }
        history[idx].isSent = false
        history[idx].sentAt = nil
        save()
    }

    /// All climbs that have been sent, newest-send first.
    var sends: [SavedClimb] {
        history.filter(\.isSent).sorted { ($0.sentAt ?? .distantPast) > ($1.sentAt ?? .distantPast) }
    }

    /// Remove all climbs that are not marked as favorites.
    func clearNonFavorites() {
        history.removeAll { !$0.isFavorite }
        save()
    }

    /// Remove every climb from history, including favorites.
    func clearAll() {
        history.removeAll()
        save()
    }

    /// If we're over the cap, remove the oldest non-favorited climb(s) until
    /// we're back under. Favorites are immune.
    private func prune() {
        while history.count > Self.maxClimbs {
            guard let idx = history.firstIndex(where: { !$0.isFavorite }) else {
                // Nothing left to prune — every climb is a favorite.
                break
            }
            history.remove(at: idx)
        }
    }
}
