import Foundation

// MARK: - Kilter Board BLE Protocol
// Encodes LED placement data into the packet format expected by the Kilter Board.
// Protocol reference: https://github.com/Stevie-Ray/hangtime-grip-connect
//                     https://github.com/1-max-1/fake_kilter_board

enum KilterBoardProtocol {

    // MARK: - Role Colors (matches official Kilter app)

    /// RGB colors for each hold role on the physical board
    static func color(for role: HoldRole) -> (r: UInt8, g: UInt8, b: UInt8) {
        switch role {
        case .start:    return (0x00, 0xFF, 0x00)   // Green
        case .middle:   return (0x00, 0xFF, 0xFF)   // Cyan
        case .finish:   return (0xFF, 0x00, 0xFF)   // Magenta
        case .footOnly: return (0xFF, 0xB6, 0x00)   // Orange
        }
    }

    // MARK: - Color Encoding

    /// Pack 24-bit RGB into a single byte: RRRGGGBB
    static func encodeColor(r: UInt8, g: UInt8, b: UInt8) -> UInt8 {
        let rBits = r / 32          // 0-7 (3 bits)
        let gBits = g / 32          // 0-7 (3 bits)
        let bBits = b / 64          // 0-3 (2 bits)
        return (rBits << 5) | (gBits << 2) | bBits
    }

    /// Pack a HoldRole into an encoded color byte
    static func encodeColor(for role: HoldRole) -> UInt8 {
        let (r, g, b) = color(for: role)
        return encodeColor(r: r, g: g, b: b)
    }

    // MARK: - Placement Encoding

    /// Encode a single (position, role) into 3 bytes: [pos_lo, pos_hi, color]
    static func encodePlacement(position: Int, role: HoldRole) -> [UInt8] {
        let posLo = UInt8(position & 0xFF)
        let posHi = UInt8((position >> 8) & 0xFF)
        let color = encodeColor(for: role)
        return [posLo, posHi, color]
    }

    // MARK: - Packet Framing (API v3)

    /// Header byte indicating packet position in a multi-packet message
    private enum PacketHeader: UInt8 {
        case only  = 84   // 'T' — single packet message
        case first = 82   // 'R' — first of multiple
        case mid   = 81   // 'Q' — middle packet
        case last  = 83   // 'S' — last packet
    }

    /// Maximum payload bytes per packet (excluding framing)
    private static let maxPayloadSize = 255

    /// BLE chunk size (max bytes per write)
    static let bleChunkSize = 20

    /// Compute checksum: bitwise NOT of sum of payload bytes, masked to 8 bits
    private static func checksum(_ data: [UInt8]) -> UInt8 {
        let sum = data.reduce(0) { ($0 + UInt16($1)) & 0xFF }
        return UInt8(~sum & 0xFF)
    }

    /// Wrap a payload (with header byte already included) into a framed packet:
    /// [0x01, length, checksum, 0x02, ...payload, 0x03]
    private static func framePacket(_ payload: [UInt8]) -> [UInt8] {
        var packet: [UInt8] = []
        packet.append(0x01)                         // start marker
        packet.append(UInt8(payload.count & 0xFF))  // length
        packet.append(checksum(payload))            // checksum
        packet.append(0x02)                         // data marker
        packet.append(contentsOf: payload)          // payload
        packet.append(0x03)                         // end marker
        return packet
    }

    // MARK: - Full Message Assembly

    /// Build the complete BLE message for a set of LED placements.
    /// Returns an array of Data chunks, each ≤ 20 bytes, ready to write to the TX characteristic.
    static func buildMessage(placements: [(position: Int, role: HoldRole)]) -> [Data] {
        // Encode all placements into raw bytes
        var holdBytes: [UInt8] = []
        for p in placements {
            holdBytes.append(contentsOf: encodePlacement(position: p.position, role: p.role))
        }

        // Split into payloads (max 254 bytes each, leaving 1 byte for header)
        let maxDataPerPacket = maxPayloadSize - 1  // 254
        var payloadChunks: [[UInt8]] = []
        var offset = 0
        while offset < holdBytes.count {
            let end = min(offset + maxDataPerPacket, holdBytes.count)
            payloadChunks.append(Array(holdBytes[offset..<end]))
            offset = end
        }

        // If empty, send a single empty "turn off all LEDs" packet
        if payloadChunks.isEmpty {
            payloadChunks = [[]]
        }

        // Frame each chunk with the appropriate header
        var allBytes: [UInt8] = []
        for (i, chunk) in payloadChunks.enumerated() {
            let header: PacketHeader
            if payloadChunks.count == 1 {
                header = .only
            } else if i == 0 {
                header = .first
            } else if i == payloadChunks.count - 1 {
                header = .last
            } else {
                header = .mid
            }

            var payload: [UInt8] = [header.rawValue]
            payload.append(contentsOf: chunk)
            allBytes.append(contentsOf: framePacket(payload))
        }

        // Split into BLE chunks of 20 bytes
        var chunks: [Data] = []
        var chunkOffset = 0
        while chunkOffset < allBytes.count {
            let end = min(chunkOffset + bleChunkSize, allBytes.count)
            chunks.append(Data(allBytes[chunkOffset..<end]))
            chunkOffset = end
        }

        print("KilterProto ✅  \(placements.count) holds → \(payloadChunks.count) packets → \(chunks.count) BLE chunks")
        return chunks
    }

    /// Convenience: build a "turn off LEDs" message (empty placement list)
    static func buildClearMessage() -> [Data] {
        return buildMessage(placements: [])
    }
}
