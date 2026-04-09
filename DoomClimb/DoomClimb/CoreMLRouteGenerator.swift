import Foundation
import CoreML

// MARK: - CoreML Route Generator
// Runs the trained ClimbGPT model on-device to generate novel climbing routes.
// The model was trained on ~60K real Kilter Board climbs and generates
// (placement_id, role) sequences conditioned on grade and angle.

final class CoreMLRouteGenerator {

    // MARK: - Token constants (must match training vocab)

    private static let PAD   = 0
    private static let BOS   = 1
    private static let EOS   = 2

    // Grade tokens:  GRADE_0 = 4, GRADE_1 = 5, ..., GRADE_16 = 20
    private static func gradeToken(for grade: Int) -> Int { 4 + min(max(grade, 0), 16) }

    // Angle tokens:  ANGLE_0 = 21, ANGLE_5 = 22, ..., ANGLE_70 = 35
    private static let validAngles = [0, 5, 10, 15, 20, 25, 30, 35, 40, 45, 50, 55, 60, 65, 70]
    private static func angleToken(for angle: Int) -> Int? {
        let snapped = validAngles.min(by: { abs($0 - angle) < abs($1 - angle) }) ?? 40
        guard let idx = validAngles.firstIndex(of: snapped) else { return nil }
        return 21 + idx
    }

    // Role tokens
    private static let roleTokenToHoldRole: [Int: HoldRole] = [
        36: .start,     // ROLE_12
        37: .middle,    // ROLE_13
        38: .finish,    // ROLE_14
        39: .footOnly,  // ROLE_15
    ]

    // MARK: - Properties

    private let model: ClimbGPT
    private let maxSeqLen: Int
    private let vocabSize: Int

    /// Maps token ID → placement ID (for HOLD_* tokens only)
    private let tokenToPlacementId: [Int: Int]

    /// Set of hold token IDs that map to kickboard positions (y > kickboardY)
    private let kickboardHoldTokens: Set<Int>

    /// Minimum token ID that represents a hold (everything >= this is a HOLD_* token)
    private let holdTokenStart = 40

    /// Y threshold for kickboard zone — holds below this line (i.e. with
    /// y > this value) should never be hand/start holds. The 12×12 with
    /// kickboard board has main-wall bolt-ons at y ≈ 0.931 (bottom row) and
    /// kickboard screw-ons at y ≈ 0.955–0.960, so 0.94 cleanly splits them.
    private static let kickboardY: Double = 0.94

    /// Role token ID for START
    private static let startRoleToken = 36

    // MARK: - Init

    init?() {
        // Load the CoreML model
        guard let mlModel = try? ClimbGPT(configuration: .init()) else {
            print("CoreMLGen ❌  Failed to load ClimbGPT.mlpackage")
            return nil
        }
        self.model = mlModel

        // Load id_to_token.json to build the reverse mapping
        guard let url = Bundle.main.url(forResource: "id_to_token", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: String] else {
            print("CoreMLGen ❌  Failed to load id_to_token.json")
            return nil
        }

        // Build token → placement_id mapping for HOLD_* tokens
        var mapping: [Int: Int] = [:]
        for (idStr, tokenName) in dict {
            guard let tokenId = Int(idStr),
                  tokenName.hasPrefix("HOLD_"),
                  let pid = Int(tokenName.replacingOccurrences(of: "HOLD_", with: "")) else {
                continue
            }
            mapping[tokenId] = pid
        }
        self.tokenToPlacementId = mapping

        // Pre-compute which hold tokens land on the kickboard
        var kbTokens = Set<Int>()
        for (tokenId, pid) in mapping {
            if let pos = HoldSocketMap.positions[pid], Double(pos.y) > Self.kickboardY {
                kbTokens.insert(tokenId)
            }
        }
        self.kickboardHoldTokens = kbTokens

        // Read model shape from first prediction
        // maxSeqLen is the second dimension of the input "tokens" tensor
        self.maxSeqLen = 80  // Must match training config
        self.vocabSize = 555 // Must match training config

        print("CoreMLGen ✅  Loaded — \(mapping.count) hold tokens (\(kbTokens.count) kickboard), maxSeqLen=\(maxSeqLen)")
    }

    // MARK: - Generation

    func generate(grade: Int, angle: Int, temperature: Float = 0.9, topK: Int = 40) -> BoulderRoute? {

        guard let angleTok = Self.angleToken(for: angle) else { return nil }
        let gradeTok = Self.gradeToken(for: grade)

        // Start with [BOS, GRADE, ANGLE, PAD, PAD, ...]
        var tokens = [Int](repeating: Self.PAD, count: maxSeqLen)
        tokens[0] = Self.BOS
        tokens[1] = gradeTok
        tokens[2] = angleTok
        var length = 3

        // Autoregressive generation loop
        for _ in 0..<(maxSeqLen - 3) {
            // Predict
            guard let logitsArray = predict(tokens: tokens) else { return nil }

            // Get logits at position (length - 1)
            let offset = (length - 1) * vocabSize
            var logits = Array(logitsArray[offset..<(offset + vocabSize)])

            // Suppress START role after kickboard holds.
            // If the last token was a kickboard HOLD, the model is about to
            // pick a ROLE — prevent it from choosing START (token 36).
            let lastToken = tokens[length - 1]
            if kickboardHoldTokens.contains(lastToken) {
                logits[Self.startRoleToken] = -Float.infinity
            }

            // Apply temperature
            if temperature != 1.0 {
                for i in 0..<logits.count {
                    logits[i] /= temperature
                }
            }

            // Top-k filtering
            let nextToken = sampleTopK(logits: logits, k: topK)

            // Stop at EOS
            if nextToken == Self.EOS { break }

            // Append token
            if length < maxSeqLen {
                tokens[length] = nextToken
                length += 1
            } else {
                break
            }
        }

        // Decode tokens into RouteHolds
        return decodeRoute(tokens: Array(tokens[0..<length]), grade: grade, angle: angle)
    }

    // MARK: - CoreML Prediction

    private func predict(tokens: [Int]) -> [Float]? {
        do {
            // Create MLMultiArray for input: shape (1, maxSeqLen)
            let inputArray = try MLMultiArray(shape: [1, NSNumber(value: maxSeqLen)], dataType: .int32)
            for i in 0..<maxSeqLen {
                inputArray[[0, NSNumber(value: i)] as [NSNumber]] = NSNumber(value: Int32(tokens[i]))
            }

            let input = ClimbGPTInput(tokens: inputArray)
            let output = try model.prediction(input: input)

            // output.logits is shape (1, maxSeqLen, vocabSize)
            // CoreML may use Float16 or Float32 — read via MLShapedArray for safety
            let shaped = output.logitsShapedArray  // MLShapedArray<Float16>
            return shaped.scalars.map { Float($0) }
        } catch {
            print("CoreMLGen ❌  Prediction failed: \(error)")
            return nil
        }
    }

    // MARK: - Sampling

    private func sampleTopK(logits: [Float], k: Int) -> Int {
        // Find top-k indices
        let indexed = logits.enumerated().map { ($0.offset, $0.element) }
        let topK = indexed.sorted(by: { $0.1 > $1.1 }).prefix(k)

        // Softmax over top-k
        let maxLogit = topK.first?.1 ?? 0
        let exps = topK.map { exp($0.1 - maxLogit) }
        let sumExps = exps.reduce(0, +)
        let probs = exps.map { $0 / sumExps }

        // Sample from the distribution
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

    // MARK: - Decoding

    private func decodeRoute(tokens: [Int], grade: Int, angle: Int) -> BoulderRoute? {
        var routeHolds: [RouteHold] = []

        // Debug: print raw token sequence
        print("CoreMLGen 🔍 Raw tokens (\(tokens.count)): \(tokens)")

        // Walk through tokens starting after BOS, GRADE, ANGLE
        var i = 3
        while i < tokens.count - 1 {
            let holdToken = tokens[i]
            let roleToken = tokens[i + 1]

            // Debug: check what each token pair looks like
            let pidOrNil = tokenToPlacementId[holdToken]
            let roleOrNil = Self.roleTokenToHoldRole[roleToken]

            // Check if this is a valid (HOLD, ROLE) pair
            guard let pid = pidOrNil,
                  let role = roleOrNil,
                  let pos = HoldSocketMap.positions[pid] else {
                print("CoreMLGen 🔍 Skipping token[\(i)]=\(holdToken) token[\(i+1)]=\(roleToken) — pid=\(pidOrNil.map(String.init) ?? "nil") role=\(roleOrNil.map(String.init(describing:)) ?? "nil") pos=\(pidOrNil.flatMap { HoldSocketMap.positions[$0] }.map { "(\($0.x), \($0.y))" } ?? "nil")")
                i += 1
                continue
            }

            let fx = Double(pos.x)
            let fy = Double(pos.y)

            // Debug: print every decoded hold with position and role
            let roleName: String
            switch role {
            case .start:    roleName = "START ⭐"
            case .middle:   roleName = "MIDDLE"
            case .finish:   roleName = "FINISH"
            case .footOnly: roleName = "FOOT"
            }
            print("CoreMLGen 🔍 Hold: token=\(holdToken) → pid=\(pid), role=\(roleName), pos=(\(String(format: "%.3f", fx)), \(String(format: "%.3f", fy)))")

            // No coordinate bounds check needed: HoldSocketMap.positions
            // contains exactly the 476 real climbable sockets for the 12×12
            // with kickboard (323 bolt-ons + 153 screw-ons). Frame/structural
            // bolts and unsupported holds are already excluded at source.

            let hold = Hold(id: pid, row: 0, col: 0,
                            x: fx, y: fy,
                            holdType: .jug, difficulty: 5)
            routeHolds.append(RouteHold(hold: hold, role: role))
            i += 2
        }

        // Fallback: if no start holds, promote the two lowest non-kickboard holds
        let startCount = routeHolds.filter({ $0.role == .start }).count
        if startCount == 0 {
            // Sort by y descending (highest y = lowest on board) but exclude kickboard
            let candidates = routeHolds.enumerated()
                .filter { $0.element.role != .finish && $0.element.hold.y <= Self.kickboardY }
                .sorted { $0.element.hold.y > $1.element.hold.y }

            let promoteCount = min(2, candidates.count)
            for j in 0..<promoteCount {
                let idx = candidates[j].offset
                let old = routeHolds[idx]
                routeHolds[idx] = RouteHold(hold: old.hold, role: .start)
                print("CoreMLGen 🔧 Promoted pid=\(old.hold.id) to START (was \(old.role), y=\(String(format: "%.3f", old.hold.y)))")
            }
        }

        // Debug: summary
        let startHolds = routeHolds.filter { $0.role == .start }
        let finishHolds = routeHolds.filter { $0.role == .finish }
        print("CoreMLGen 🔍 SUMMARY: \(routeHolds.count) holds total — \(startHolds.count) starts, \(finishHolds.count) finishes")
        for sh in startHolds {
            let yStr = String(format: "%.3f", sh.hold.y)
            print("CoreMLGen 🔍   Start hold pid=\(sh.hold.id) at y=\(yStr)")
        }

        guard routeHolds.count >= 3 else {
            print("CoreMLGen ⚠️  Generated route too short (\(routeHolds.count) holds)")
            return nil
        }

        let snappedAngle = Self.validAngles.min(by: { abs($0 - angle) < abs($1 - angle) }) ?? angle

        return BoulderRoute(
            name: nil,
            holds: routeHolds,
            grade: "V\(grade)",
            angle: snappedAngle,
            technique: "AI Generated",
            generatedAt: .now
        )
    }
}
