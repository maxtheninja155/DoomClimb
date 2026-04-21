import SwiftUI

// MARK: - Bluetooth Connection Sheet
// Shown when the user taps the Bluetooth icon in the toolbar.
// Lists discovered Kilter Boards and lets the user connect/disconnect.

struct BluetoothSheet: View {
    @ObservedObject var ble: KilterBoardBLE
    @Binding var selectedBoardSize: LEDMappingService.BoardSize
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                // MARK: - Status
                Section {
                    HStack {
                        statusIcon
                        Text(ble.state.displayText)
                            .font(.headline)
                        Spacer()
                        if case .scanning = ble.state {
                            ProgressView()
                        }
                    }
                }

                // MARK: - Board Size Picker
                Section("Board Size") {
                    Picker("Size", selection: $selectedBoardSize) {
                        ForEach(LEDMappingService.BoardSize.allCases) { size in
                            Text(size.displayName).tag(size)
                        }
                    }
                    .pickerStyle(.menu)
                }

                // MARK: - Actions
                Section {
                    if ble.state.isConnected {
                        Button("Disconnect", role: .destructive) {
                            ble.disconnect()
                        }
                    } else if case .scanning = ble.state {
                        Button("Stop Scanning") {
                            ble.stopScan()
                        }
                    } else {
                        Button {
                            ble.startScan()
                        } label: {
                            HStack {
                                Image(systemName: "antenna.radiowaves.left.and.right")
                                Text("Scan for Kilter Board")
                            }
                        }
                    }
                }

                // MARK: - Discovered Boards
                if !ble.discoveredBoards.isEmpty {
                    Section("Discovered Boards") {
                        ForEach(ble.discoveredBoards) { board in
                            Button {
                                ble.connect(to: board)
                            } label: {
                                HStack {
                                    VStack(alignment: .leading) {
                                        Text(board.name)
                                            .font(.body.weight(.medium))
                                            .foregroundStyle(.primary)
                                        Text("Signal: \(board.rssi) dBm")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    if case .connecting(let name) = ble.state, name == board.name {
                                        ProgressView()
                                    } else {
                                        Image(systemName: "chevron.right")
                                            .foregroundStyle(.secondary)
                                    }
                                }
                            }
                            .disabled(ble.state.isConnected)
                        }
                    }
                }

                // MARK: - Error
                if let error = ble.lastError {
                    Section {
                        Label(error, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.red)
                            .font(.footnote)
                    }
                }
            }
            .navigationTitle("Bluetooth")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    @ViewBuilder
    private var statusIcon: some View {
        switch ble.state {
        case .disconnected:
            Image(systemName: "antenna.radiowaves.left.and.right")
                .foregroundStyle(.secondary)
        case .scanning:
            Image(systemName: "antenna.radiowaves.left.and.right")
                .foregroundStyle(Color.dcSecondary)
                .symbolEffect(.pulse)
        case .connecting:
            Image(systemName: "antenna.radiowaves.left.and.right")
                .foregroundStyle(Color.dcSecondary)
        case .connected:
            Image(systemName: "antenna.radiowaves.left.and.right.circle.fill")
                .foregroundStyle(Color.dcPrimary)
        }
    }
}
