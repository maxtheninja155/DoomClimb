import SwiftUI

// MARK: - Climb Detail View
// Pushed onto the navigation stack from the History sheet when the user
// taps a specific climb (or presented as a sheet from the main screen
// when the user taps Edit). Displays the climb on the board, allows
// sending to the physical Kilter Board via BLE, toggling the favorite
// flag, and — via the Edit toggle — tap-to-cycle climb editing.

struct ClimbDetailView: View {
    @ObservedObject var vm: RouteViewModel
    let climbId: UUID

    /// When true, the view starts with edit mode enabled. Used when the
    /// view is presented from the main screen's "Edit" button.
    var startInEditMode: Bool = false

    // Rename alert state
    @State private var showRenameAlert = false
    @State private var renameText: String = ""

    // Editor state
    @State private var isEditing: Bool = false
    @State private var didApplyStartInEditMode = false

    /// Look the climb up fresh every render so name/favorite/route changes
    /// reflect immediately even after the store mutates.
    private var climb: SavedClimb? {
        vm.store.history.first(where: { $0.id == climbId })
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                if let climb = climb {
                    header(climb)

                    BoardView(
                        route: climb.route,
                        onTap: isEditing ? { point, size in
                            handleEditTap(at: point, in: size, climb: climb)
                        } : nil
                    )
                    .padding(.horizontal, 4)
                    .overlay(alignment: .topTrailing) {
                        if isEditing {
                            Text("EDITING")
                                .font(.caption2.bold())
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(.orange, in: Capsule())
                                .foregroundStyle(.white)
                                .padding(10)
                                .transition(.opacity.combined(with: .scale))
                        }
                    }

                    HoldLegend()

                    if isEditing {
                        editorHint
                    }

                    // Send to Board (only when BLE connected)
                    if vm.ble.state.isConnected {
                        Button {
                            vm.sendToBoard(climb.route)
                        } label: {
                            HStack {
                                Image(systemName: "lightbulb.led.fill")
                                Text("Send to Board")
                                    .fontWeight(.medium)
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.green)
                    }

                    // LED send status
                    if let status = vm.ledSendStatus {
                        Text(status)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .transition(.opacity)
                    }
                } else {
                    // Climb was deleted while this view was open
                    ContentUnavailableView(
                        "Climb not found",
                        systemImage: "questionmark.folder",
                        description: Text("This climb was removed from history.")
                    )
                }
            }
            .padding()
        }
        .navigationTitle(isEditing ? "Editing Climb" : "Climb")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            if startInEditMode && !didApplyStartInEditMode {
                isEditing = true
                didApplyStartInEditMode = true
            }
        }
        .alert("Rename Climb", isPresented: $showRenameAlert) {
            TextField("Name", text: $renameText)
                .textInputAutocapitalization(.words)
            Button("Save") {
                if let climb = climb {
                    vm.store.rename(id: climb.id, to: renameText)
                }
            }
            Button("Reset", role: .destructive) {
                if let climb = climb {
                    vm.store.rename(id: climb.id, to: nil)
                }
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("Enter a custom name for this climb. Reset clears it back to the default.")
        }
        .toolbar {
            // Edit mode toggle
            if climb != nil {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            isEditing.toggle()
                        }
                    } label: {
                        Image(systemName: isEditing ? "pencil.circle.fill" : "pencil.circle")
                            .foregroundStyle(isEditing ? .orange : .primary)
                    }
                }
            }

            // Favorite star
            if let climb = climb {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.6)) {
                            vm.store.toggleFavorite(id: climb.id)
                        }
                    } label: {
                        Image(systemName: climb.isFavorite ? "star.fill" : "star")
                            .foregroundStyle(climb.isFavorite ? .yellow : .primary)
                    }
                }
            }

            // Bluetooth status / sheet
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    vm.showBluetoothSheet = true
                } label: {
                    Image(systemName: bluetoothIcon)
                        .foregroundStyle(bluetoothColor)
                }
            }
        }
    }

    // MARK: - Header

    @ViewBuilder
    private func header(_ climb: SavedClimb) -> some View {
        VStack(spacing: 6) {
            Button {
                renameText = climb.customName ?? ""
                showRenameAlert = true
            } label: {
                HStack(spacing: 6) {
                    Text(vm.store.displayName(for: climb))
                        .font(.system(.title3, design: .rounded, weight: .bold))
                        .foregroundStyle(.primary)
                    Image(systemName: "pencil")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .buttonStyle(.plain)

            HStack(spacing: 10) {
                badge(climb.route.grade, icon: "figure.climbing", color: .green)
                badge("\(climb.route.angle)°", icon: "arrow.up.right", color: .orange)
                badge("\(climb.route.moveCount) moves", icon: "arrow.up.forward", color: .cyan)
            }
            .font(.caption)

            Text(climb.savedAt.formatted(date: .abbreviated, time: .shortened))
                .font(.caption2)
                .foregroundStyle(.tertiary)
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

    // MARK: - Editor hint

    @ViewBuilder
    private var editorHint: some View {
        VStack(spacing: 4) {
            Text("Tap an empty spot to add a hold.")
            Text("Tap an existing hold to cycle:  Hand → Foot → Start → Finish → Remove")
        }
        .font(.caption2)
        .foregroundStyle(.secondary)
        .multilineTextAlignment(.center)
        .padding(.horizontal)
    }

    // MARK: - Editor: tap handling

    /// Handles a tap on the board while in edit mode. Uses cycle-mode
    /// semantics: tapping an existing hold walks it through the role cycle
    /// (and ultimately removes it), while tapping an empty spot snaps to
    /// the nearest hold socket and drops a new Hand (middle) hold there.
    private func handleEditTap(at point: CGPoint, in size: CGSize, climb: SavedClimb) {
        let w = size.width
        let h = size.height
        let smallDim = min(w, h)
        let tapRadiusOnExisting: CGFloat = smallDim * 0.045
        let snapRadiusOnEmpty:  CGFloat = smallDim * 0.060

        var holds = climb.route.holds

        // 1. Did the tap land on an existing hold? Socket coordinates are
        //    already in the same fractional space as the board image, so
        //    hit-testing is a direct scale — no row-shift compensation.
        for (idx, rh) in holds.enumerated() {
            let dispX = CGFloat(rh.hold.x) * w
            let dispY = CGFloat(rh.hold.y) * h
            let dist  = hypot(dispX - point.x, dispY - point.y)

            if dist < tapRadiusOnExisting {
                if let next = nextRole(rh.role) {
                    holds[idx] = RouteHold(hold: rh.hold, role: next)
                    print("Editor ✏️  Cycle \(rh.hold.id) \(rh.role.label) → \(next.label)")
                } else {
                    holds.remove(at: idx)
                    print("Editor 🗑️  Remove \(rh.hold.id) (\(rh.role.label))")
                }
                commit(holds: holds, climb: climb)
                return
            }
        }

        // 2. No existing hold hit → snap to nearest socket from HoldSocketMap.
        //    The map contains exactly 476 real climbable sockets for the
        //    12×12 with kickboard — no filtering needed here.
        var best: (id: Int, x: Double, y: Double, dist: CGFloat)? = nil
        for (id, pos) in HoldSocketMap.positions {
            let dispX = CGFloat(pos.x) * w
            let dispY = CGFloat(pos.y) * h
            let dist  = hypot(dispX - point.x, dispY - point.y)

            if best == nil || dist < best!.dist {
                best = (id, Double(pos.x), Double(pos.y), dist)
            }
        }

        guard let b = best, b.dist < snapRadiusOnEmpty else { return }

        // If the snapped socket is already in the route, do nothing (the
        // existing-hold hit-test above would normally catch it, but the
        // snap radius is larger than the tap radius).
        if holds.contains(where: { $0.hold.id == b.id }) { return }

        let newHold = Hold(
            id: b.id,
            row: 0,
            col: 0,
            x: b.x,
            y: b.y,
            holdType: .jug,
            difficulty: 5
        )
        holds.append(RouteHold(hold: newHold, role: .middle))
        print("Editor ➕  Add \(b.id) as Hand")
        commit(holds: holds, climb: climb)
    }

    /// Cycle order for tap-cycling an existing hold. Returning nil means
    /// "delete the hold" (i.e. we've walked past the last state).
    ///   Hand → Foot → Start → Finish → (delete)
    private func nextRole(_ current: HoldRole) -> HoldRole? {
        switch current {
        case .middle:   return .footOnly
        case .footOnly: return .start
        case .start:    return .finish
        case .finish:   return nil
        }
    }

    /// Persist the edited hold list back to the store and, if the board is
    /// connected, immediately push the new LED pattern over Bluetooth.
    private func commit(holds: [RouteHold], climb: SavedClimb) {
        let updated = BoulderRoute(
            name:        climb.route.name,
            holds:       holds,
            grade:       climb.route.grade,
            angle:       climb.route.angle,
            technique:   climb.route.technique,
            generatedAt: climb.route.generatedAt
        )
        vm.store.updateRoute(id: climb.id, to: updated)

        // Real-time BLE push: send the updated LED pattern on every edit
        // while connected. `sendToBoard` already no-ops (and surfaces a
        // status message) if the board is disconnected.
        if vm.ble.state.isConnected {
            vm.sendToBoard(updated)
        }
    }

    // MARK: - Bluetooth icon helpers

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
