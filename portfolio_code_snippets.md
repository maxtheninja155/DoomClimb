# DoomClimb — Code Snippets

---

## 1. ClimbGPT — Transformer Architecture (Python)

Decoder-only GPT-style transformer (~2M params) trained on 60K real Kilter Board climbs. Pre-norm, GELU activations, weight-tied output projection.

```python
class ClimbGPT(nn.Module):
    """
    Decoder-only GPT for autoregressive climbing route generation.
    Input prefix: [BOS, GRADE_X, ANGLE_Y] → generates (HOLD, ROLE) pairs until EOS.
    """

    def __init__(self, vocab_size, embed_dim, num_heads, num_layers,
                 max_seq_len, dropout=0.1, pad_token_id=0, label_smoothing=0.0):
        super().__init__()
        self.token_emb = nn.Embedding(vocab_size, embed_dim, padding_idx=pad_token_id)
        self.pos_emb   = nn.Embedding(max_seq_len, embed_dim)
        self.drop      = nn.Dropout(dropout)

        encoder_layer = nn.TransformerEncoderLayer(
            d_model=embed_dim,
            nhead=num_heads,
            dim_feedforward=embed_dim * 4,
            dropout=dropout,
            activation='gelu',
            batch_first=True,
            norm_first=True,   # Pre-norm for stable training
        )
        self.transformer = nn.TransformerEncoder(encoder_layer, num_layers=num_layers)
        self.ln_f = nn.LayerNorm(embed_dim)

        self.head = nn.Linear(embed_dim, vocab_size, bias=False)
        self.head.weight = self.token_emb.weight  # Weight tying

    def forward(self, x, targets=None):
        B, T = x.shape
        positions = torch.arange(T, device=x.device).unsqueeze(0)
        h = self.token_emb(x) + self.pos_emb(positions)
        h = self.drop(h)

        # Causal mask prevents attending to future tokens
        causal_mask = nn.Transformer.generate_square_subsequent_mask(T, device=x.device, dtype=h.dtype)
        pad_mask = (x == self.pad_token_id)

        h = self.transformer(h, mask=causal_mask, src_key_padding_mask=pad_mask)
        h = self.ln_f(h)
        logits = self.head(h)

        loss = None
        if targets is not None:
            loss = F.cross_entropy(
                logits.view(-1, self.vocab_size),
                targets.view(-1),
                ignore_index=self.pad_token_id,
                label_smoothing=self.label_smoothing,
            )
        return logits, loss
```

---

## 2. Classifier-Free Guidance — Training-Time Dropout (Python)

10% of batches drop the grade/angle condition tokens, replacing them with an `UNCOND` token. This teaches the model both conditional and unconditional generation, enabling CFG steering at inference.

```python
# CFG dropout: replace GRADE+ANGLE with UNCOND for 10% of training batches.
# Sequence format: [BOS, GRADE, ANGLE, holds..., EOS, PAD...]
# At inference, we interpolate: uncond + scale * (cond - uncond)

CFG_DROP_PROB = 0.10

for batch_idx, (inp, tgt) in enumerate(train_loader):
    inp, tgt = inp.to(DEVICE), tgt.to(DEVICE)

    if CFG_DROP_PROB > 0:
        drop_mask = torch.rand(inp.size(0), device=inp.device) < CFG_DROP_PROB
        if drop_mask.any():
            inp[drop_mask, 1] = uncond_token  # GRADE → UNCOND
            inp[drop_mask, 2] = uncond_token  # ANGLE → UNCOND

    _, loss = model(inp, tgt)
    optimizer.zero_grad()
    loss.backward()
    torch.nn.utils.clip_grad_norm_(model.parameters(), 1.0)
    optimizer.step()
    scheduler.step()
```

---

## 3. Autoregressive Inference with CFG — On-Device (Swift)

Runs entirely on-device via CoreML with no cloud dependency. Interpolates conditional and unconditional logits at each step, plus physics-aware suppression of illegal start-hold placements.

```swift
private func generateOnce(grade: Int, angle: Int, temperature: Float,
                           topK: Int, guidanceScale: Float) -> BoulderRoute? {
    let gradeTok = Self.gradeToken(for: grade)
    guard let angleTok = Self.angleToken(for: angle) else { return nil }

    // Conditional prefix: [BOS, GRADE, ANGLE, PAD...]
    var condTokens = [Int](repeating: Self.PAD, count: maxSeqLen)
    condTokens[0] = Self.BOS; condTokens[1] = gradeTok; condTokens[2] = angleTok

    // Unconditional prefix: [BOS, UNCOND, UNCOND, PAD...]
    var uncondTokens = [Int](repeating: Self.PAD, count: maxSeqLen)
    uncondTokens[0] = Self.BOS; uncondTokens[1] = Self.UNCOND; uncondTokens[2] = Self.UNCOND

    var length = 3

    for _ in 0..<(maxSeqLen - 3) {
        guard let condLogits = predict(tokens: condTokens) else { return nil }
        guard let uncondLogits = predict(tokens: uncondTokens) else { return nil }

        let offset = (length - 1) * vocabSize

        // CFG: steer toward target grade/angle
        var logits = [Float](repeating: 0, count: vocabSize)
        for i in 0..<vocabSize {
            let c = condLogits[offset + i]
            let u = uncondLogits[offset + i]
            logits[i] = u + guidanceScale * (c - u)
        }

        // Physics constraint: suppress START role after kickboard holds
        if kickboardHoldTokens.contains(condTokens[length - 1]) {
            logits[Self.startRoleToken] = -Float.infinity
        }

        // Temperature + top-k sampling
        for i in 0..<logits.count { logits[i] /= temperature }
        let nextToken = sampleTopK(logits: logits, k: topK)

        if nextToken == Self.EOS { break }
        condTokens[length] = nextToken
        uncondTokens[length] = nextToken
        length += 1
    }

    return decodeRoute(tokens: Array(condTokens[0..<length]), grade: grade, angle: angle)
}
```

---

## 4. Top-K Sampling (Swift)

```swift
private func sampleTopK(logits: [Float], k: Int) -> Int {
    let indexed = logits.enumerated().map { ($0.offset, $0.element) }
    let topK = indexed.sorted(by: { $0.1 > $1.1 }).prefix(k)

    // Numerically stable softmax over the top-k subset
    let maxLogit = topK.first?.1 ?? 0
    let exps = topK.map { exp($0.1 - maxLogit) }
    let sumExps = exps.reduce(0, +)
    let probs = exps.map { $0 / sumExps }

    // Multinomial sample
    let r = Float.random(in: 0..<1)
    var cumulative: Float = 0
    for (i, prob) in probs.enumerated() {
        cumulative += prob
        if r < cumulative {
            return topK[topK.index(topK.startIndex, offsetBy: i)].0
        }
    }
    return topK.last?.0 ?? Self.EOS
}
```

---

## 5. Climbability Validator — BFS Reachability (Swift)

Graph-reachability algorithm that guarantees every generated route is physically solvable before it reaches the UI. The `maxReach` threshold (0.3179) was empirically calibrated from 66K real climbs at the 95th percentile of MST critical-reach distances.

```swift
enum ClimbabilityValidator {

    /// Calibrated from real climb data: 95th percentile of critical reaches.
    static let maxReach: Double = 0.3179

    static func isClimbable(_ holds: [RouteHold]) -> Bool {
        var handHolds: [(id: Int, x: Double, y: Double)] = []
        var startIndices: [Int] = []
        var finishIndices: [Int] = []

        for rh in holds {
            guard rh.role != .footOnly else { continue }
            let idx = handHolds.count
            handHolds.append((id: rh.hold.id, x: rh.hold.x, y: rh.hold.y))
            switch rh.role {
            case .start:  startIndices.append(idx)
            case .finish: finishIndices.append(idx)
            default:      break
            }
        }

        guard !startIndices.isEmpty, !finishIndices.isEmpty, handHolds.count >= 3 else {
            return false
        }

        // Build adjacency graph within human reach distance
        let n = handHolds.count
        var adj = [[Int]](repeating: [], count: n)
        for i in 0..<n {
            for j in (i + 1)..<n {
                let dx = handHolds[i].x - handHolds[j].x
                let dy = handHolds[i].y - handHolds[j].y
                if (dx*dx + dy*dy).squareRoot() <= maxReach {
                    adj[i].append(j); adj[j].append(i)
                }
            }
        }

        // BFS from all start holds — success if any finish hold is reached
        let finishSet = Set(finishIndices)
        var visited = Set(startIndices)
        var queue = startIndices
        var head = 0

        while head < queue.count {
            let node = queue[head]; head += 1
            if finishSet.contains(node) { return true }
            for neighbor in adj[node] where !visited.contains(neighbor) {
                visited.insert(neighbor); queue.append(neighbor)
            }
        }
        return false
    }
}
```

---

## 6. Reach Threshold Calibration via MST (Python)

Calibrates the reach threshold against real climb data rather than using a guessed constant. For each climb, finds the longest edge in its Minimum Spanning Tree — the minimum reach needed to connect all holds. Uses the 95th percentile across 66K climbs.

```python
def _mst_max_edge(positions):
    """Longest edge in the Minimum Spanning Tree (Prim's algorithm).
    This is the 'critical reach' — the minimum max_reach to connect all holds."""
    n = len(positions)
    if n < 2:
        return 0.0

    in_mst = [False] * n
    min_edge = [float('inf')] * n
    min_edge[0] = 0.0
    max_edge = 0.0

    for _ in range(n):
        u = min((v for v in range(n) if not in_mst[v]), key=lambda v: min_edge[v])
        in_mst[u] = True
        if min_edge[u] > max_edge and min_edge[u] < float('inf'):
            max_edge = min_edge[u]
        for v in range(n):
            if not in_mst[v]:
                d = euclidean_distance(positions[u], positions[v])
                if d < min_edge[v]:
                    min_edge[v] = d

    return max_edge


def calibrate_reach(climbs, socket_positions, percentile=95):
    """Returns the Nth percentile of critical reaches across all training climbs."""
    critical_reaches = []
    for holds in climbs:
        hand_positions = [socket_positions[pid] for pid, rid in holds
                          if rid in HAND_ROLES and pid in socket_positions]
        if len(hand_positions) >= 2:
            critical_reaches.append(_mst_max_edge(hand_positions))

    critical_reaches.sort()
    idx = min(int(len(critical_reaches) * percentile / 100), len(critical_reaches) - 1)
    return critical_reaches[idx], critical_reaches
```

---

## 7. BLE Packet Protocol — Framing & Color Encoding (Swift)

Complete reverse-engineered implementation of the Kilter Board's Aurora Climbing BLE protocol. 24-bit RGB is compressed to 8-bit `RRRGGGBB`, packets are framed with start/end markers and checksums, and multi-packet messages use T/R/Q/S position headers.

```swift
enum KilterBoardProtocol {

    // Pack 24-bit RGB → 8-bit RRRGGGBB (3 bits R, 3 bits G, 2 bits B)
    static func encodeColor(r: UInt8, g: UInt8, b: UInt8) -> UInt8 {
        let rBits = r / 32   // 0–7  (3 bits)
        let gBits = g / 32   // 0–7  (3 bits)
        let bBits = b / 64   // 0–3  (2 bits)
        return (rBits << 5) | (gBits << 2) | bBits
    }

    // Encode a single hold: [pos_lo, pos_hi, color_byte]
    static func encodePlacement(position: Int, role: HoldRole) -> [UInt8] {
        let (r, g, b): (UInt8, UInt8, UInt8) = switch role {
            case .start:    (0x00, 0xFF, 0x00)   // Green
            case .middle:   (0x00, 0xFF, 0xFF)   // Cyan
            case .finish:   (0xFF, 0x00, 0xFF)   // Magenta
            case .footOnly: (0xFF, 0xB6, 0x00)   // Orange
        }
        return [UInt8(position & 0xFF), UInt8((position >> 8) & 0xFF), encodeColor(r: r, g: g, b: b)]
    }

    // Packet position headers (multi-packet messages)
    private enum PacketHeader: UInt8 {
        case only  = 84   // 'T' — single packet
        case first = 82   // 'R' — first of multiple
        case mid   = 81   // 'Q' — middle
        case last  = 83   // 'S' — last
    }

    // Checksum: bitwise NOT of sum of payload bytes
    private static func checksum(_ data: [UInt8]) -> UInt8 {
        let sum = data.reduce(0) { ($0 + UInt16($1)) & 0xFF }
        return UInt8(~sum & 0xFF)
    }

    // Frame a payload: [0x01, length, checksum, 0x02, ...payload, 0x03]
    private static func framePacket(_ payload: [UInt8]) -> [UInt8] {
        var packet: [UInt8] = [0x01, UInt8(payload.count & 0xFF), checksum(payload), 0x02]
        packet.append(contentsOf: payload)
        packet.append(0x03)
        return packet
    }

    // Build the complete BLE message, split into 20-byte chunks for transmission
    static func buildMessage(placements: [(position: Int, role: HoldRole)]) -> [Data] {
        var holdBytes: [UInt8] = placements.flatMap { encodePlacement(position: $0.position, role: $0.role) }

        // Split into ≤254-byte payloads (1 byte reserved for header)
        var payloadChunks: [[UInt8]] = stride(from: 0, to: max(holdBytes.count, 1), by: 254).map {
            Array(holdBytes[$0..<min($0 + 254, holdBytes.count)])
        }
        if payloadChunks.isEmpty { payloadChunks = [[]] }

        var allBytes: [UInt8] = []
        for (i, chunk) in payloadChunks.enumerated() {
            let header: PacketHeader = payloadChunks.count == 1 ? .only
                : i == 0 ? .first : i == payloadChunks.count - 1 ? .last : .mid
            allBytes += framePacket([header.rawValue] + chunk)
        }

        // Split into 20-byte BLE writes
        return stride(from: 0, to: allBytes.count, by: 20).map {
            Data(allBytes[$0..<min($0 + 20, allBytes.count)])
        }
    }
}
```

---

## 8. CoreBluetooth BLE Stack (Swift)

Scans for the Aurora Climbing service UUID, connects to the board, discovers the Nordic nRF UART TX characteristic, and sequences 20-byte chunk writes with a 10ms inter-chunk delay.

```swift
final class KilterBoardBLE: NSObject, ObservableObject {

    // Aurora Climbing / Nordic nRF UART service + TX characteristic UUIDs
    private static let advertisingServiceUUID = CBUUID(string: "4488b571-7806-4df6-bcff-a2897e4953ff")
    private static let uartServiceUUID        = CBUUID(string: "6e400001-b5a3-f393-e0a9-e50e24dcca9e")
    private static let txCharacteristicUUID   = CBUUID(string: "6e400002-b5a3-f393-e0a9-e50e24dcca9e")

    @Published private(set) var state: ConnectionState = .disconnected

    func sendLEDs(chunks: [Data]) {
        guard let characteristic = txCharacteristic,
              let peripheral = connectedPeripheral,
              state.isConnected else { return }

        pendingChunks = chunks
        sendNextChunk(peripheral: peripheral, characteristic: characteristic)
    }

    private func sendNextChunk(peripheral: CBPeripheral, characteristic: CBCharacteristic) {
        guard !pendingChunks.isEmpty else { return }
        let chunk = pendingChunks.removeFirst()
        peripheral.writeValue(chunk, for: characteristic, type: .withoutResponse)

        // 10ms delay between chunks to avoid overwhelming the BLE stack
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.01) { [weak self] in
            self?.sendNextChunk(peripheral: peripheral, characteristic: characteristic)
        }
    }
}

extension KilterBoardBLE: CBPeripheralDelegate {
    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        guard let tx = service.characteristics?.first(where: { $0.uuid == Self.txCharacteristicUUID }) else {
            disconnect(); return
        }
        txCharacteristic = tx
        state = .connected(peripheral.name ?? "Kilter Board")
    }
}
```

---

## 9. Kilter Database Query + Frame Parsing (Swift)

Read-only SQLite query engine that pulls real community-set climbs from the bundled `kilter.db`. Parses Kilter's proprietary `p1073r12p1074r13` frame format and maps `placement_id` → normalized board coordinates.

```swift
func fetchRandomClimb(grade: Int, angle: Int) -> BoulderRoute? {
    let (minDiff, maxDiff) = Self.difficultyRange(for: grade)

    let sql = """
        SELECT c.name, c.frames
        FROM   climbs c
        JOIN   climb_stats cs ON cs.climb_uuid = c.uuid
        WHERE  cs.angle               = ?
          AND  cs.difficulty_average >= ?
          AND  cs.difficulty_average  < ?
          AND  c.is_listed            = 1
          AND  c.frames_count         = 1
          AND  c.layout_id            = ?
        ORDER  BY RANDOM()
        LIMIT  1
    """

    var stmt: OpaquePointer?
    guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
    defer { sqlite3_finalize(stmt) }

    sqlite3_bind_int(stmt, 1, Int32(angle))
    sqlite3_bind_double(stmt, 2, minDiff)
    sqlite3_bind_double(stmt, 3, maxDiff)
    sqlite3_bind_int(stmt, 4, Int32(Self.layoutId))

    guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }

    let name   = String(cString: sqlite3_column_text(stmt, 0))
    let frames = String(cString: sqlite3_column_text(stmt, 1))
    let holds  = parseFrames(frames)

    return BoulderRoute(name: name, holds: holds, grade: "V\(grade)",
                        angle: angle, technique: "Kilter Board", generatedAt: .now)
}

// Parse Kilter's proprietary frame format: "p1073r12p1074r13p1489r14..."
private func parseFrames(_ frames: String) -> [RouteHold] {
    frames.components(separatedBy: "p").filter { !$0.isEmpty }.compactMap { part in
        let tokens = part.components(separatedBy: "r")
        guard tokens.count == 2,
              let pid = Int(tokens[0]), let rid = Int(tokens[1]),
              let pos = HoldSocketMap.positions[pid] else { return nil }

        let hold = Hold(id: pid, row: 0, col: 0, x: Double(pos.x), y: Double(pos.y),
                        holdType: .jug, difficulty: 5)
        return RouteHold(hold: hold, role: Self.mapRole(rid))
    }
}
```

---

## 10. CoreML Export — TorchScript Wrapper (Python)

Because CoreML doesn't support in-graph autoregressive loops, the model is exported as a single forward pass returning all-position logits. The Swift inference engine handles the generation loop, picking the relevant position slice at each step.

```python
class ClimbGPTForExport(nn.Module):
    """Wraps ClimbGPT for CoreML tracing.
    Returns full (1, MAX_SEQ_LEN, vocab_size) logits so the Swift caller
    can index any position without data-dependent tensor ops in the graph."""

    def forward(self, tokens):  # tokens: (1, MAX_SEQ_LEN) int32
        logits, _ = self.model(tokens)
        return logits  # (1, MAX_SEQ_LEN, vocab_size)


# Trace and convert
traced = torch.jit.trace(wrapper, (example_tokens,), check_trace=False)

mlmodel = ct.convert(
    traced,
    inputs=[ct.TensorType(name="tokens", shape=(1, max_seq_len), dtype=int)],
    outputs=[ct.TensorType(name="logits")],
    minimum_deployment_target=ct.target.iOS17,
)
mlmodel.save("export/ClimbGPT.mlpackage")
```

---

## 11. Climb History Store — Persistence & Smart Naming (Swift)

JSON-codable persist store with UUID keys, ISO8601 timestamps, favorites, and smart display-name hierarchy. Auto-prunes the oldest non-favorited climb when the 5,000-climb cap is reached.

```swift
@MainActor
final class ClimbHistoryStore: ObservableObject {

    static let maxClimbs = 5000

    @Published private(set) var history: [SavedClimb] = []

    /// Display name priority: user custom name → DB climb name → positional default
    func displayName(for climb: SavedClimb) -> String {
        if let custom = climb.customName, !custom.isEmpty { return custom }
        if let dbName = climb.route.name, !dbName.isEmpty { return dbName }

        let cal = Calendar.current
        let day = cal.startOfDay(for: climb.savedAt)
        let sameDay = history.filter { cal.startOfDay(for: $0.savedAt) == day }
        let position = (sameDay.firstIndex(where: { $0.id == climb.id }) ?? 0) + 1
        return "\(climb.route.grade)@\(climb.route.angle)_Climb#\(position)"
    }

    /// Prunes oldest non-favorited climbs to stay under the cap. Favorites are immune.
    private func prune() {
        while history.count > Self.maxClimbs {
            guard let idx = history.firstIndex(where: { !$0.isFavorite }) else { break }
            history.remove(at: idx)
        }
    }

    private func save() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        if let data = try? encoder.encode(history) {
            try? data.write(to: fileURL, options: .atomic)
        }
    }
}
```
