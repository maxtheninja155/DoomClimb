import Foundation
import CoreML

// MARK: - CoreML Route Generator
// Runs the trained ClimbGPT model on-device to generate novel climbing routes.
// The model was trained on ~60K real Kilter Board climbs and generates
// (placement_id, role) sequences conditioned on grade and angle.

final class CoreMLRouteGenerator {

    // MARK: - Token constants (must match training vocab)

    private static let PAD    = 0
    private static let BOS    = 1
    private static let EOS    = 2
    private static let UNCOND = 4   // Unconditional token for CFG (replaces GRADE+ANGLE)

    // Grade tokens:  GRADE_0 = 5, GRADE_1 = 6, ..., GRADE_16 = 21
    private static func gradeToken(for grade: Int) -> Int { 5 + min(max(grade, 0), 16) }

    // Angle tokens:  ANGLE_0 = 22, ANGLE_5 = 23, ..., ANGLE_70 = 36
    private static let validAngles = [0, 5, 10, 15, 20, 25, 30, 35, 40, 45, 50, 55, 60, 65, 70]
    private static func angleToken(for angle: Int) -> Int? {
        let snapped = validAngles.min(by: { abs($0 - angle) < abs($1 - angle) }) ?? 40
        guard let idx = validAngles.firstIndex(of: snapped) else { return nil }
        return 22 + idx
    }

    // Role tokens
    private static let roleTokenToHoldRole: [Int: HoldRole] = [
        37: .start,     // ROLE_12
        38: .middle,    // ROLE_13
        39: .finish,    // ROLE_14
        40: .footOnly,  // ROLE_15
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
    private let holdTokenStart = 41

    /// Y threshold for kickboard zone — holds below this line (i.e. with
    /// y > this value) should never be hand/start holds. The 12×12 with
    /// kickboard board has main-wall bolt-ons at y ≈ 0.931 (bottom row) and
    /// kickboard screw-ons at y ≈ 0.955–0.960, so 0.94 cleanly splits them.
    private static let kickboardY: Double = 0.94

    /// Role token ID for START
    private static let startRoleToken = 37

    // MARK: - Init

    init?() {
        // Load the CoreML model
        // Use CPU-only on the simulator (no real GPU → MPS backend produces garbage).
        // On device, let CoreML pick the best backend (Neural Engine / GPU / CPU).
        let config = MLModelConfiguration()
        #if targetEnvironment(simulator)
        config.computeUnits = .cpuOnly
        print("CoreMLGen ℹ️  Simulator detected — forcing CPU-only compute")
        #else
        config.computeUnits = .all
        #endif
        guard let mlModel = try? ClimbGPT(configuration: config) else {
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
        self.vocabSize = 517 // Must match training config

        print("CoreMLGen ✅  Loaded — \(mapping.count) hold tokens (\(kbTokens.count) kickboard), maxSeqLen=\(maxSeqLen)")
    }

    // MARK: - Generation

    /// Maximum number of generation attempts before giving up.
    private static let maxRetries = 8

    /// Classifier-Free Guidance scale. Higher values push the model harder toward
    /// the target grade/angle. 3.5 gives tight grade accuracy with good route diversity.
    func generate(grade: Int, angle: Int, temperature: Float = 0.75, topK: Int = 20,
                  guidanceScale: Float = 3.5) -> BoulderRoute? {
        for attempt in 1...Self.maxRetries {
            guard let route = generateOnce(grade: grade, angle: angle, temperature: temperature,
                                           topK: topK, guidanceScale: guidanceScale) else {
                continue
            }

            if ClimbabilityValidator.isClimbable(route.holds) {
                if attempt > 1 {
                    print("CoreMLGen \u{2705}  Climbable on attempt \(attempt)")
                }
                return route
            }

            print("CoreMLGen \u{26A0}\u{FE0F}  Attempt \(attempt)/\(Self.maxRetries) failed climbability check, retrying...")
        }

        print("CoreMLGen \u{274C}  All \(Self.maxRetries) attempts failed climbability validation")
        return nil
    }

    private func generateOnce(grade: Int, angle: Int, temperature: Float, topK: Int,
                              guidanceScale: Float) -> BoulderRoute? {

        guard let angleTok = Self.angleToken(for: angle) else { return nil }
        let gradeTok = Self.gradeToken(for: grade)

        // Conditional prefix: [BOS, GRADE, ANGLE, PAD, PAD, ...]
        var condTokens = [Int](repeating: Self.PAD, count: maxSeqLen)
        condTokens[0] = Self.BOS
        condTokens[1] = gradeTok
        condTokens[2] = angleTok

        // Unconditional prefix: [BOS, UNCOND, UNCOND, PAD, PAD, ...]
        // Only used when guidanceScale > 1.0
        let useCFG = guidanceScale > 1.0
        var uncondTokens: [Int]?
        if useCFG {
            var u = [Int](repeating: Self.PAD, count: maxSeqLen)
            u[0] = Self.BOS
            u[1] = Self.UNCOND
            u[2] = Self.UNCOND
            uncondTokens = u
        }

        var length = 3

        // Autoregressive generation loop
        for _ in 0..<(maxSeqLen - 3) {
            // Conditional forward pass
            guard let condLogitsArray = predict(tokens: condTokens) else { return nil }
            let offset = (length - 1) * vocabSize
            var logits: [Float]

            if useCFG, let uncondToks = uncondTokens {
                // Unconditional forward pass
                guard let uncondLogitsArray = predict(tokens: uncondToks) else { return nil }

                // CFG: uncond + scale * (cond - uncond)
                logits = [Float](repeating: 0, count: vocabSize)
                for i in 0..<vocabSize {
                    let c = condLogitsArray[offset + i]
                    let u = uncondLogitsArray[offset + i]
                    logits[i] = u + guidanceScale * (c - u)
                }
            } else {
                logits = Array(condLogitsArray[offset..<(offset + vocabSize)])
            }

            // Suppress START role after kickboard holds
            let lastToken = condTokens[length - 1]
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

            // Append token to both sequences
            if length < maxSeqLen {
                condTokens[length] = nextToken
                uncondTokens?[length] = nextToken
                length += 1
            } else {
                break
            }
        }

        // Decode tokens into RouteHolds
        return decodeRoute(tokens: Array(condTokens[0..<length]), grade: grade, angle: angle)
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
