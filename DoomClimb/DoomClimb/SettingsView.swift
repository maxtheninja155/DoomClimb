import SwiftUI

struct SettingsView: View {
    @ObservedObject var store: ClimbHistoryStore
    @Environment(\.dismiss) private var dismiss

    @State private var showClearNonFavoritesAlert = false
    @State private var showClearAllAlert = false

    private var appVersion: String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "—"
        return "\(version) (\(build))"
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack {
                        Text("Total Climbs")
                        Spacer()
                        Text("\(store.history.count)")
                            .foregroundStyle(.secondary)
                    }
                    HStack {
                        Text("Favorites")
                        Spacer()
                        Text("\(store.favorites.count)")
                            .foregroundStyle(.yellow)
                    }
                } header: {
                    Text("History")
                }

                Section {
                    Button("Clear Non-Favorites") {
                        showClearNonFavoritesAlert = true
                    }
                    .foregroundStyle(.orange)
                    .disabled(store.history.filter { !$0.isFavorite }.isEmpty)

                    Button("Clear All History", role: .destructive) {
                        showClearAllAlert = true
                    }
                    .disabled(store.history.isEmpty)
                } header: {
                    Text("Manage")
                } footer: {
                    Text("Clearing history cannot be undone.")
                }

                Section("About") {
                    HStack {
                        Text("Version")
                        Spacer()
                        Text(appVersion)
                            .foregroundStyle(.secondary)
                    }

                    NavigationLink("Privacy Policy") {
                        PrivacyPolicyView()
                    }
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
            .alert("Clear Non-Favorites?", isPresented: $showClearNonFavoritesAlert) {
                Button("Clear", role: .destructive) { store.clearNonFavorites() }
                Button("Cancel", role: .cancel) { }
            } message: {
                Text("This permanently deletes all climbs that aren't marked as favorites.")
            }
            .alert("Clear All History?", isPresented: $showClearAllAlert) {
                Button("Clear All", role: .destructive) { store.clearAll() }
                Button("Cancel", role: .cancel) { }
            } message: {
                Text("This permanently deletes your entire climb history, including favorites.")
            }
        }
    }
}

#Preview {
    SettingsView(store: ClimbHistoryStore())
        .preferredColorScheme(.dark)
}
