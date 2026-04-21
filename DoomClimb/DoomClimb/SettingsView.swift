import SwiftUI

struct SettingsView: View {
    @ObservedObject var vm: RouteViewModel
    @Environment(\.dismiss) private var dismiss

    @State private var showClearNonFavoritesAlert = false
    @State private var showClearAllAlert = false

    private var store: ClimbHistoryStore { vm.store }

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
                        Spacer()
                        VStack(spacing: 6) {
                            Image(systemName: "figure.climbing")
                                .font(.system(size: 32))
                                .foregroundStyle(.green)
                            Text("DoomClimb")
                                .font(.system(.title3, design: .rounded, weight: .bold))
                            Text("Version \(appVersion)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                    }
                    .padding(.vertical, 10)
                    .listRowBackground(Color.clear)
                }

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

                Section {
                    Picker("Source", selection: $vm.generationMode) {
                        ForEach(GenerationMode.allCases) { mode in
                            Text(mode.rawValue).tag(mode)
                        }
                    }
                } header: {
                    Text("Generation")
                } footer: {
                    Text("Kilter Climbs uses curated routes. New Generated creates routes from scratch.")
                }

                Section("About") {
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
    SettingsView(vm: RouteViewModel())
        .preferredColorScheme(.dark)
}
