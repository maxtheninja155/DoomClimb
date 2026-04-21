import SwiftUI

struct ContentView: View {
    @StateObject private var vm = RouteViewModel()
    @State private var showBoard = false
    @State private var showHistorySheet = false
    @State private var showEditSheet = false

    // Rename alert state for the currently displayed climb
    @State private var showRenameAlert = false
    @State private var renameText: String = ""
    @State private var showSettingsSheet = false
    @State private var showSessionSheet = false
    @State private var showStatsSheet = false
    @State private var showShareSheet = false
    @State private var showImportAlert = false
    @State private var importAlertMessage = ""

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 28) {

                    // MARK: - Header
                    VStack(spacing: 4) {
                        Text("Route Generator")
                            .font(.system(.largeTitle, design: .rounded, weight: .bold))
                        Text("Set your constraints, then generate")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.top, 8)

                    // MARK: - Grade slider
                    ControlCard {
                        VStack(alignment: .leading, spacing: 10) {
                            HStack {
                                Label("Grade", systemImage: "figure.climbing")
                                Spacer()
                                Text(vm.gradeLabel)
                                    .font(.title3.bold())
                                    .monospacedDigit()
                                    .contentTransition(.numericText())
                            }
                            Slider(value: $vm.gradeValue, in: 0...16, step: 1)
                                .tint(.dcPrimary)
                        }
                    }

                    // MARK: - Angle slider
                    ControlCard {
                        VStack(alignment: .leading, spacing: 10) {
                            HStack {
                                Label("Wall Angle", systemImage: "angle")
                                Spacer()
                                Text(vm.angleLabel)
                                    .font(.title3.bold())
                                    .monospacedDigit()
                                    .contentTransition(.numericText())
                            }
                            Slider(value: $vm.angleValue, in: 0...60, step: 5)
                                .tint(.dcSecondary)
                        }
                    }

                    // MARK: - Mode toggle
                    ControlCard {
                        VStack(alignment: .leading, spacing: 10) {
                            Label("Source", systemImage: "arrow.triangle.branch")
                            Picker("Mode", selection: $vm.generationMode.animation(.easeInOut(duration: 0.25))) {
                                ForEach(GenerationMode.allCases) { mode in
                                    Text(mode.rawValue).tag(mode)
                                }
                            }
                            .pickerStyle(.segmented)
                        }
                    }

                    // MARK: - Generate button
                    Button {
                        vm.generateRoute()
                        withAnimation { showBoard = true }
                    } label: {
                        HStack {
                            if vm.isGenerating {
                                ProgressView()
                                    .tint(.white)
                            }
                            Text(vm.isGenerating ? "Generating…" : "Generate Route")
                                .fontWeight(.semibold)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.dcPrimary)
                    .disabled(vm.isGenerating)

                    // MARK: - Board display
                    if showBoard {
                        VStack(spacing: 12) {
                            if let route = vm.currentRoute {
                                routeHeader(route)
                            }

                            BoardView(route: vm.currentRoute)
                                .padding(.horizontal, 4)

                            HoldLegend()

                            if vm.currentRoute != nil {
                                // Send to Board button (shown when Bluetooth connected)
                                if vm.ble.state.isConnected {
                                    Button {
                                        vm.sendToBoard()
                                    } label: {
                                        HStack {
                                            Image(systemName: "lightbulb.led.fill")
                                            Text("Send to Board")
                                                .fontWeight(.medium)
                                        }
                                        .frame(maxWidth: .infinity)
                                        .padding(.vertical, 10)
                                    }
                                    .buttonStyle(.borderedProminent)
                                    .tint(.dcPrimary)
                                }

                                // LED send status
                                if let status = vm.ledSendStatus {
                                    Text(status)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .transition(.opacity)
                                }

                                Button("Clear", role: .destructive) {
                                    vm.clearRoute()
                                    if vm.ble.state.isConnected {
                                        vm.clearBoard()
                                    }
                                }
                                .font(.footnote)
                            }
                        }
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                    }
                }
                .padding()
            }
            .navigationTitle("DoomClimb")
            .navigationBarTitleDisplayMode(.inline)
            .background(Color(.systemBackground))
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        showHistorySheet = true
                    } label: {
                        Image(systemName: "clock.arrow.circlepath")
                    }
                }
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        showSessionSheet = true
                    } label: {
                        Image(systemName: "list.bullet.rectangle")
                    }
                }
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        showStatsSheet = true
                    } label: {
                        Image(systemName: "chart.bar.xaxis")
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        vm.showBluetoothSheet = true
                    } label: {
                        Image(systemName: bluetoothIcon)
                            .foregroundStyle(bluetoothColor)
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showSettingsSheet = true
                    } label: {
                        Image(systemName: "gearshape")
                    }
                }
            }
            .sheet(isPresented: $vm.showBluetoothSheet) {
                BluetoothSheet(
                    ble: vm.ble,
                    selectedBoardSize: $vm.selectedBoardSize
                )
                .presentationDetents([.medium, .large])
            }
            .sheet(isPresented: $showHistorySheet) {
                HistorySheet(vm: vm)
            }
            .sheet(isPresented: $showSettingsSheet) {
                SettingsView(store: vm.store)
            }
            .sheet(isPresented: $showSessionSheet) {
                SessionPlannerView(vm: vm)
            }
            .sheet(isPresented: $showStatsSheet) {
                StatsView(vm: vm)
            }
            .sheet(isPresented: $showShareSheet) {
                if let route = vm.currentRoute {
                    ShareRouteSheet(route: route)
                        .presentationDetents([.large])
                } else {
                    ContentUnavailableView(
                        "No climb to share",
                        systemImage: "square.dashed",
                        description: Text("Generate a climb first.")
                    )
                }
            }
            .onOpenURL { url in
                handleIncomingURL(url)
            }
            .alert("Import Climb", isPresented: $showImportAlert) {
                Button("OK", role: .cancel) { }
            } message: {
                Text(importAlertMessage)
            }
            .sheet(isPresented: $showEditSheet) {
                NavigationStack {
                    if let id = vm.currentClimbId {
                        ClimbDetailView(vm: vm, climbId: id, startInEditMode: true)
                            .toolbar {
                                ToolbarItem(placement: .topBarLeading) {
                                    Button("Done") { showEditSheet = false }
                                }
                            }
                    } else {
                        ContentUnavailableView(
                            "No climb to edit",
                            systemImage: "square.dashed",
                            description: Text("Generate a climb first.")
                        )
                    }
                }
            }
            .alert("Rename Climb", isPresented: $showRenameAlert) {
                TextField("Name", text: $renameText)
                    .textInputAutocapitalization(.words)
                Button("Save") {
                    if let id = vm.currentClimbId {
                        vm.store.rename(id: id, to: renameText)
                    }
                }
                Button("Reset", role: .destructive) {
                    if let id = vm.currentClimbId {
                        vm.store.rename(id: id, to: nil)
                    }
                }
                Button("Cancel", role: .cancel) { }
            } message: {
                Text("Enter a custom name for this climb. Reset clears it back to the default.")
            }
        }
    }

    // MARK: - Deep link handling

    private func handleIncomingURL(_ url: URL) {
        do {
            let route = try RouteShareCodec.decode(from: url)
            let saved = vm.store.append(route)
            withAnimation(.easeInOut(duration: 0.35)) {
                vm.currentClimbId = saved.id
                showBoard = true
            }
            importAlertMessage = "Added a \(route.grade) @ \(route.angle)° climb to your history."
            showImportAlert = true
            print("ContentView 📥  Imported shared route → \(saved.id.uuidString.prefix(8))…")
        } catch {
            importAlertMessage = "This share link couldn't be loaded. It may be from a newer version of DoomClimb or may be corrupted."
            showImportAlert = true
            print("ContentView ⚠️  Failed to import shared URL: \(error)")
        }
    }

    // MARK: - Bluetooth icon state

    private var bluetoothIcon: String {
        vm.ble.state.isConnected ? "antenna.radiowaves.left.and.right.circle.fill" : "antenna.radiowaves.left.and.right"
    }

    private var bluetoothColor: Color {
        switch vm.ble.state {
        case .disconnected: return .secondary
        case .scanning:     return .dcSecondary
        case .connecting:   return .dcSecondary
        case .connected:    return .dcPrimary
        }
    }

    // MARK: - Route metadata badge row

    @ViewBuilder
    private func routeHeader(_ route: BoulderRoute) -> some View {
        VStack(spacing: 8) {
            // Display name (tap to rename) + favorite toggle
            if let saved = vm.currentSavedClimb {
                HStack(spacing: 8) {
                    Button {
                        renameText = saved.customName ?? ""
                        showRenameAlert = true
                    } label: {
                        HStack(spacing: 6) {
                            Text(vm.store.displayName(for: saved))
                                .font(.system(.headline, design: .rounded, weight: .bold))
                                .foregroundStyle(.primary)
                                .lineLimit(1)
                            Image(systemName: "pencil")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .buttonStyle(.plain)

                    Button {
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.6)) {
                            vm.toggleFavoriteCurrent()
                        }
                    } label: {
                        Image(systemName: vm.isCurrentFavorited ? "star.fill" : "star")
                            .foregroundStyle(vm.isCurrentFavorited ? .yellow : .secondary)
                            .font(.headline)
                    }
                    .buttonStyle(.plain)

                    // Edit → open detail view in edit mode
                    Button {
                        showEditSheet = true
                    } label: {
                        Image(systemName: "slider.horizontal.3")
                            .foregroundStyle(Color.dcSecondary)
                            .font(.headline)
                    }
                    .buttonStyle(.plain)

                    // Share → show QR code + share sheet
                    Button {
                        showShareSheet = true
                    } label: {
                        Image(systemName: "square.and.arrow.up")
                            .foregroundStyle(Color.dcPrimary)
                            .font(.headline)
                    }
                    .buttonStyle(.plain)
                }
            }

            // Badges with back/forward arrows flanking
            HStack(spacing: 10) {
                Button {
                    vm.goBack()
                } label: {
                    Image(systemName: "chevron.left")
                        .font(.headline)
                        .foregroundStyle(vm.canGoBack ? Color.primary : Color.secondary.opacity(0.3))
                        .frame(width: 32, height: 32)
                        .background(.ultraThinMaterial, in: Circle())
                }
                .buttonStyle(.plain)
                .disabled(!vm.canGoBack)

                badge(route.grade, icon: "figure.climbing", color: .dcPrimary)
                badge("\(route.angle)°", icon: "arrow.up.right", color: .dcSecondary)
                badge("\(route.moveCount) moves", icon: "arrow.up.forward", color: .dcSecondary)

                Button {
                    vm.goForward()
                } label: {
                    Image(systemName: "chevron.right")
                        .font(.headline)
                        .foregroundStyle(vm.canGoForward ? Color.primary : Color.secondary.opacity(0.3))
                        .frame(width: 32, height: 32)
                        .background(.ultraThinMaterial, in: Circle())
                }
                .buttonStyle(.plain)
                .disabled(!vm.canGoForward)
            }
            .font(.caption)
        }
    }

    private func badge(_ text: String, icon: String, color: Color) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
            Text(text).lineLimit(1)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(color.opacity(0.12), in: Capsule())
        .foregroundStyle(color)
    }
}

// MARK: - Reusable card wrapper

struct ControlCard<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        content
            .padding()
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
    }
}

#Preview {
    ContentView()
}
