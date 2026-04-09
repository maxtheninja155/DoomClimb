import SwiftUI

// MARK: - History Sheet
// Presents the full climb history grouped by day with an All / Favorites
// segmented filter. Each row can be swiped to delete, favorited in place,
// or tapped to push a detail view.

struct HistorySheet: View {
    @ObservedObject var vm: RouteViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var showFavoritesOnly = false

    var body: some View {
        NavigationStack {
            Group {
                if filteredGroups.isEmpty {
                    emptyState
                } else {
                    climbList
                }
            }
            .navigationTitle("History")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .principal) {
                    Picker("Filter", selection: $showFavoritesOnly) {
                        Text("All").tag(false)
                        Text("★ Favorites").tag(true)
                    }
                    .pickerStyle(.segmented)
                    .frame(maxWidth: 220)
                }
            }
            .navigationDestination(for: UUID.self) { climbId in
                ClimbDetailView(vm: vm, climbId: climbId)
            }
        }
    }

    // MARK: - Subviews

    @ViewBuilder
    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: showFavoritesOnly ? "star.slash" : "tray")
                .font(.system(size: 42))
                .foregroundStyle(.secondary)
            Text(showFavoritesOnly ? "No favorites yet" : "No climbs in history")
                .font(.headline)
                .foregroundStyle(.secondary)
            Text(showFavoritesOnly
                 ? "Tap the star on any climb to save it here."
                 : "Generate a route to start your history.")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private var climbList: some View {
        List {
            ForEach(filteredGroups, id: \.day) { group in
                Section(header: Text(headerTitle(for: group.day))) {
                    ForEach(group.climbs) { climb in
                        NavigationLink(value: climb.id) {
                            HistoryRow(climb: climb, vm: vm)
                        }
                        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                            Button(role: .destructive) {
                                withAnimation {
                                    // If the deleted climb was currently
                                    // being shown on the main screen, also
                                    // blank the main display. `currentRoute`
                                    // is computed from `currentClimbId`, so
                                    // clearing the id is sufficient.
                                    if vm.currentClimbId == climb.id {
                                        vm.currentClimbId = nil
                                    }
                                    vm.store.delete(id: climb.id)
                                }
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }
                        }
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
    }

    // MARK: - Data helpers

    /// Day-groups filtered by the current All/Favorites toggle.
    private var filteredGroups: [(day: Date, climbs: [SavedClimb])] {
        let source: [SavedClimb] = showFavoritesOnly
            ? vm.store.history.filter(\.isFavorite)
            : vm.store.history

        let cal = Calendar.current
        let groups = Dictionary(grouping: source) { cal.startOfDay(for: $0.savedAt) }
        return groups
            .map { (day: $0.key, climbs: $0.value.sorted { $0.savedAt > $1.savedAt }) }
            .sorted { $0.day > $1.day }
    }

    private func headerTitle(for day: Date) -> String {
        let cal = Calendar.current
        if cal.isDateInToday(day)     { return "Today" }
        if cal.isDateInYesterday(day) { return "Yesterday" }
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter.string(from: day)
    }
}

// MARK: - Row

private struct HistoryRow: View {
    let climb: SavedClimb
    @ObservedObject var vm: RouteViewModel

    var body: some View {
        HStack(spacing: 12) {
            // Simple colored marker indicating grade
            Circle()
                .fill(Color.green.opacity(0.15))
                .overlay(
                    Text(climb.route.grade)
                        .font(.system(.caption, design: .rounded, weight: .bold))
                        .foregroundStyle(.green)
                )
                .frame(width: 36, height: 36)

            VStack(alignment: .leading, spacing: 2) {
                Text(vm.store.displayName(for: climb))
                    .font(.system(.subheadline, design: .rounded, weight: .semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)

                HStack(spacing: 6) {
                    Text(climb.route.grade)
                    Text("•")
                    Text("\(climb.route.angle)°")
                    Text("•")
                    Text("\(climb.route.moveCount) moves")
                    Text("•")
                    Text(timeString(climb.savedAt))
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
            }

            Spacer(minLength: 4)

            Button {
                withAnimation(.spring(response: 0.3, dampingFraction: 0.6)) {
                    vm.store.toggleFavorite(id: climb.id)
                }
            } label: {
                Image(systemName: climb.isFavorite ? "star.fill" : "star")
                    .foregroundStyle(climb.isFavorite ? .yellow : .secondary)
                    .font(.body)
                    .frame(width: 32, height: 32)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(.vertical, 4)
    }

    private func timeString(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "h:mm a"
        return formatter.string(from: date)
    }
}
