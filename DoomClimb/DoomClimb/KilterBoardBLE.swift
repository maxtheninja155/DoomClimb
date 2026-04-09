import Foundation
import CoreBluetooth
import Combine

// MARK: - Kilter Board BLE Manager
// Handles Bluetooth LE scanning, connection, and data transmission
// to a physical Kilter Board.

final class KilterBoardBLE: NSObject, ObservableObject {

    // MARK: - Connection State

    enum ConnectionState: Equatable {
        case disconnected
        case scanning
        case connecting(String)   // peripheral name
        case connected(String)    // peripheral name

        var isConnected: Bool {
            if case .connected = self { return true }
            return false
        }

        var boardName: String? {
            switch self {
            case .connecting(let name), .connected(let name): return name
            default: return nil
            }
        }

        var displayText: String {
            switch self {
            case .disconnected:       return "Not Connected"
            case .scanning:           return "Scanning…"
            case .connecting(let n):  return "Connecting to \(n)…"
            case .connected(let n):   return "Connected to \(n)"
            }
        }
    }

    // MARK: - Discovered Device

    struct DiscoveredBoard: Identifiable, Equatable {
        let id: UUID
        let name: String
        let peripheral: CBPeripheral
        let rssi: Int

        static func == (lhs: DiscoveredBoard, rhs: DiscoveredBoard) -> Bool {
            lhs.id == rhs.id
        }
    }

    // MARK: - BLE UUIDs (Aurora Climbing protocol)

    private static let advertisingServiceUUID = CBUUID(string: "4488b571-7806-4df6-bcff-a2897e4953ff")
    private static let uartServiceUUID        = CBUUID(string: "6e400001-b5a3-f393-e0a9-e50e24dcca9e")
    private static let txCharacteristicUUID   = CBUUID(string: "6e400002-b5a3-f393-e0a9-e50e24dcca9e")

    // MARK: - Published State

    @Published private(set) var state: ConnectionState = .disconnected
    @Published private(set) var discoveredBoards: [DiscoveredBoard] = []
    @Published private(set) var lastError: String?

    // MARK: - Private Properties

    private var centralManager: CBCentralManager!
    private var connectedPeripheral: CBPeripheral?
    private var txCharacteristic: CBCharacteristic?
    private var pendingChunks: [Data] = []
    private var isSending = false

    // MARK: - Init

    override init() {
        super.init()
        centralManager = CBCentralManager(delegate: self, queue: .main)
    }

    // MARK: - Public API

    /// Start scanning for Kilter Boards
    func startScan() {
        guard centralManager.state == .poweredOn else {
            lastError = "Bluetooth is not available"
            print("KilterBLE ❌  Bluetooth not powered on (state: \(centralManager.state.rawValue))")
            return
        }

        discoveredBoards = []
        state = .scanning
        lastError = nil

        centralManager.scanForPeripherals(
            withServices: [Self.advertisingServiceUUID],
            options: [CBCentralManagerScanOptionAllowDuplicatesKey: false]
        )

        print("KilterBLE 📡  Scanning for boards...")

        // Auto-stop scan after 15 seconds
        DispatchQueue.main.asyncAfter(deadline: .now() + 15) { [weak self] in
            guard let self, case .scanning = self.state else { return }
            self.stopScan()
        }
    }

    /// Stop scanning
    func stopScan() {
        centralManager.stopScan()
        if case .scanning = state {
            state = .disconnected
        }
        print("KilterBLE 📡  Scan stopped")
    }

    /// Connect to a discovered board
    func connect(to board: DiscoveredBoard) {
        stopScan()
        state = .connecting(board.name)
        connectedPeripheral = board.peripheral
        board.peripheral.delegate = self
        centralManager.connect(board.peripheral, options: nil)
        print("KilterBLE 🔗  Connecting to \(board.name)...")
    }

    /// Disconnect from the current board
    func disconnect() {
        if let peripheral = connectedPeripheral {
            centralManager.cancelPeripheralConnection(peripheral)
        }
        cleanup()
        state = .disconnected
        print("KilterBLE 🔗  Disconnected")
    }

    /// Send LED data to the board (pre-encoded BLE chunks)
    func sendLEDs(chunks: [Data]) {
        guard let characteristic = txCharacteristic,
              let peripheral = connectedPeripheral,
              state.isConnected else {
            lastError = "Not connected to a board"
            print("KilterBLE ❌  Cannot send — not connected")
            return
        }

        pendingChunks = chunks
        isSending = true
        print("KilterBLE 💡  Sending \(chunks.count) BLE chunks...")

        sendNextChunk(peripheral: peripheral, characteristic: characteristic)
    }

    /// Clear all LEDs on the board
    func clearLEDs() {
        let chunks = KilterBoardProtocol.buildClearMessage()
        sendLEDs(chunks: chunks)
    }

    // MARK: - Private Helpers

    private func sendNextChunk(peripheral: CBPeripheral, characteristic: CBCharacteristic) {
        guard !pendingChunks.isEmpty else {
            isSending = false
            print("KilterBLE 💡  All chunks sent ✅")
            return
        }

        let chunk = pendingChunks.removeFirst()
        peripheral.writeValue(chunk, for: characteristic, type: .withoutResponse)

        // Small delay between chunks to avoid overwhelming the BLE stack
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.01) { [weak self] in
            guard let self else { return }
            self.sendNextChunk(peripheral: peripheral, characteristic: characteristic)
        }
    }

    private func cleanup() {
        connectedPeripheral = nil
        txCharacteristic = nil
        pendingChunks = []
        isSending = false
    }
}

// MARK: - CBCentralManagerDelegate

extension KilterBoardBLE: CBCentralManagerDelegate {

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        print("KilterBLE 📱  Bluetooth state: \(central.state.rawValue)")
        if central.state != .poweredOn {
            if case .scanning = state { state = .disconnected }
        }
    }

    func centralManager(_ central: CBCentralManager,
                         didDiscover peripheral: CBPeripheral,
                         advertisementData: [String: Any],
                         rssi RSSI: NSNumber) {

        let name = peripheral.name ?? advertisementData[CBAdvertisementDataLocalNameKey] as? String ?? "Unknown Board"
        let board = DiscoveredBoard(
            id: peripheral.identifier,
            name: name,
            peripheral: peripheral,
            rssi: RSSI.intValue
        )

        // Avoid duplicates
        if !discoveredBoards.contains(where: { $0.id == board.id }) {
            discoveredBoards.append(board)
            print("KilterBLE 📡  Found: \(name) (RSSI: \(RSSI))")
        }
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        let name = peripheral.name ?? "Kilter Board"
        print("KilterBLE 🔗  Connected to \(name) — discovering services...")
        peripheral.discoverServices([Self.uartServiceUUID])
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        let msg = error?.localizedDescription ?? "Unknown error"
        print("KilterBLE ❌  Connection failed: \(msg)")
        lastError = "Connection failed: \(msg)"
        cleanup()
        state = .disconnected
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        let name = peripheral.name ?? "Board"
        print("KilterBLE 🔗  Disconnected from \(name)")
        if error != nil {
            lastError = "Lost connection to \(name)"
        }
        cleanup()
        state = .disconnected
    }
}

// MARK: - CBPeripheralDelegate

extension KilterBoardBLE: CBPeripheralDelegate {

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        if let error {
            print("KilterBLE ❌  Service discovery failed: \(error)")
            lastError = "Service discovery failed"
            return
        }

        guard let uartService = peripheral.services?.first(where: { $0.uuid == Self.uartServiceUUID }) else {
            print("KilterBLE ❌  UART service not found")
            lastError = "Board doesn't support LED control"
            disconnect()
            return
        }

        print("KilterBLE 🔗  Found UART service — discovering characteristics...")
        peripheral.discoverCharacteristics([Self.txCharacteristicUUID], for: uartService)
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        if let error {
            print("KilterBLE ❌  Characteristic discovery failed: \(error)")
            lastError = "Characteristic discovery failed"
            return
        }

        guard let tx = service.characteristics?.first(where: { $0.uuid == Self.txCharacteristicUUID }) else {
            print("KilterBLE ❌  TX characteristic not found")
            lastError = "Board communication not available"
            disconnect()
            return
        }

        txCharacteristic = tx
        let name = peripheral.name ?? "Kilter Board"
        state = .connected(name)
        print("KilterBLE ✅  Ready — TX characteristic found, connected to \(name)")
    }
}
