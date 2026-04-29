import SwiftUI

struct ContentView: View {
    @StateObject private var vm = RouteViewModel()

    var body: some View {
        TabView {
            GeneratorTabView(vm: vm)
                .tabItem {
                    Label("Generate", systemImage: "wand.and.stars")
                }

            HistorySheet(vm: vm)
                .tabItem {
                    Label("History", systemImage: "clock.fill")
                }

            SessionPlannerView(vm: vm)
                .tabItem {
                    Label("Session", systemImage: "figure.climbing")
                }

            StatsView(vm: vm)
                .tabItem {
                    Label("Stats", systemImage: "chart.bar.fill")
                }
        }
    }
}

// MARK: - Generator Tab

private struct GeneratorTabView: View {
    @ObservedObject var vm: RouteViewModel
    @State private var showBoard = false
    @State private var showEditSheet = false
    @State private var showLegendPopover = false
    @State private var showRenameAlert = false
    @State private var renameText: String = ""
    @State private var showSettingsSheet = false
    @State private var showShareSheet = false
    @State private var showImportAlert = false
    @State private var importAlertMessage = ""

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 24) {
                    headerSection
                    parametersCard
                    generateButton

                    if showBoard {
                        boardSection
                            .transition(.move(edge: .bottom).combined(with: .opacity))
                    }
                }
                .padding()
            }
            .navigationTitle("DoomClimb")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        showSettingsSheet = true
                    } label: {
                        Image(systemName: "gearshape")
                            .foregroundStyle(.secondary)
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
            }
            .sheet(isPresented: $vm.showBluetoothSheet) {
                BluetoothSheet(ble: vm.ble, selectedBoardSize: $vm.selectedBoardSize)
                    .presentationDetents([.medium, .large])
            }
            .sheet(isPresented: $showSettingsSheet) {
                SettingsView(vm: vm)
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
                    if let id = vm.currentClimbId { vm.store.rename(id: id, to: renameText) }
                }
                Button("Reset", role: .destructive) {
                    if let id = vm.currentClimbId { vm.store.rename(id: id, to: nil) }
                }
                Button("Cancel", role: .cancel) { }
            } message: {
                Text("Enter a custom name for this climb. Reset clears it back to the default.")
            }
            .alert("Import Climb", isPresented: $showImportAlert) {
                Button("OK", role: .cancel) { }
            } message: {
                Text(importAlertMessage)
            }
            .onOpenURL { url in handleIncomingURL(url) }
        }
    }

    // MARK: - Header

    private var headerSection: some View {
        VStack(spacing: 4) {
            Text("Route Generator")
                .font(.system(.largeTitle, design: .rounded, weight: .heavy))
            Text("Set your constraints, then generate")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .padding(.top, 8)
    }

    // MARK: - Parameters Card

    private var parametersCard: some View {
        ControlCard {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Label("Grade", systemImage: "figure.climbing")
                    Spacer()
                    Text(vm.gradeLabel)
                        .font(.title3.bold())
                        .monospacedDigit()
                        .contentTransition(.numericText())
                }
                Slider(value: $vm.gradeValue, in: 0...16, step: 1)
                    .tint(.green)

                Divider()

                HStack {
                    Label("Wall Angle", systemImage: "angle")
                    Spacer()
                    Text(vm.angleLabel)
                        .font(.title3.bold())
                        .monospacedDigit()
                        .contentTransition(.numericText())
                }
                Slider(value: $vm.angleValue, in: 0...60, step: 5)
                    .tint(.orange)
            }
        }
    }

    // MARK: - Generate Button

    private var generateButton: some View {
        Button {
            vm.generateRoute()
            withAnimation { showBoard = true }
        } label: {
            HStack(spacing: 8) {
                if vm.isGenerating {
                    ProgressView().tint(.white)
                } else {
                    Image(systemName: "wand.and.stars")
                }
                Text(vm.isGenerating ? "Generating…" : "Generate Route")
                    .fontWeight(.semibold)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
        }
        .buttonStyle(.borderedProminent)
        .tint(.indigo)
        .disabled(vm.isGenerating)
    }

    // MARK: - Board Section

    @ViewBuilder
    private var boardSection: some View {
        VStack(spacing: 12) {
            if let route = vm.currentRoute {
                routeHeader(route)
            }

            BoardView(route: vm.currentRoute)
                .padding(.horizontal, 4)

            Button {
                showLegendPopover = true
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "info.circle")
                    Text("Hold Legend")
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .buttonStyle(.plain)
            .popover(isPresented: $showLegendPopover, arrowEdge: .bottom) {
                HoldLegend()
                    .padding()
                    .presentationCompactAdaptation(.popover)
            }

            if vm.currentRoute != nil {
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
                    .tint(.green)
                }

                if let status = vm.ledSendStatus {
                    Text(status)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .transition(.opacity)
                }
            }
        }
    }

    // MARK: - Route Header

    @ViewBuilder
    private func routeHeader(_ route: BoulderRoute) -> some View {
        VStack(spacing: 8) {
            if let saved = vm.currentSavedClimb {
                HStack(alignment: .center) {
                    Button {
                        renameText = saved.customName ?? ""
                        showRenameAlert = true
                    } label: {
                        HStack(spacing: 5) {
                            Text(vm.store.displayName(for: saved))
                                .font(.system(.headline, design: .rounded, weight: .bold))
                                .foregroundStyle(.primary)
                                .lineLimit(1)
                            Image(systemName: "pencil")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .buttonStyle(.plain)

                    Spacer()

                    HStack(spacing: 18) {
                        Button {
                            withAnimation(.spring(response: 0.3, dampingFraction: 0.6)) {
                                vm.toggleFavoriteCurrent()
                            }
                        } label: {
                            Image(systemName: vm.isCurrentFavorited ? "star.fill" : "star")
                                .foregroundStyle(vm.isCurrentFavorited ? .yellow : .secondary)
                        }
                        .buttonStyle(.plain)

                        Button {
                            showEditSheet = true
                        } label: {
                            Image(systemName: "slider.horizontal.3")
                                .foregroundStyle(.orange)
                        }
                        .buttonStyle(.plain)

                        Button {
                            showShareSheet = true
                        } label: {
                            Image(systemName: "square.and.arrow.up")
                                .foregroundStyle(.indigo)
                        }
                        .buttonStyle(.plain)
                    }
                    .font(.headline)
                }
            }

            HStack(spacing: 8) {
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

                badge(route.grade, icon: "figure.climbing", color: .green)
                badge("\(route.angle)°", icon: "arrow.up.right", color: .orange)
                badge("\(route.moveCount) moves", icon: "arrow.up.forward", color: .cyan)

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
        } catch {
            importAlertMessage = "This share link couldn't be loaded. It may be from a newer version of DoomClimb or may be corrupted."
            showImportAlert = true
        }
    }

    // MARK: - Bluetooth helpers

    private var bluetoothIcon: String {
        vm.ble.state.isConnected
            ? "antenna.radiowaves.left.and.right.circle.fill"
            : "antenna.radiowaves.left.and.right"
    }

    private var bluetoothColor: Color {
        switch vm.ble.state {
        case .disconnected: return .secondary
        case .scanning:     return .blue
        case .connecting:   return .orange
        case .connected:    return .green
        }
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
