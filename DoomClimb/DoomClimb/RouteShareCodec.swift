import Foundation

// MARK: - Route Share Codec
// Encodes a BoulderRoute into a compact URL-safe string that can be transmitted
// via QR code or deep link, and decodes it back. The encoding strips information
// that can be reconstructed at the other end (e.g. hold positions come from
// HoldSocketMap), keeping payloads small enough to fit in a QR code.
//
// Compact format:
//   "V{grade}@{angle}:{pid}.{role}|{pid}.{role}|..."
//   grade: 0-16 (V-scale number)
//   angle: 0-70 in 5° increments
//   pid:   placement ID from the Kilter database
//   role:  0=start, 1=middle, 2=finish, 3=footOnly
//
// Wrapped in a "doomclimb://" URL for deep linking.

enum RouteShareCodec {

    private static let scheme = "doomclimb"
    private static let host   = "route"

    enum DecodeError: Error {
        case malformed
        case unknownHold(Int)
        case noHolds
    }

    // MARK: - Encode

    /// Encode a route into a `doomclimb://` URL that can be shared as-is or
    /// rendered as a QR code.
    static func encode(_ route: BoulderRoute) -> URL? {
        let gradeNum = Int(route.grade.dropFirst("V".count)) ?? 0

        let holdStrings: [String] = route.holds.map { rh in
            let roleCode = roleToCode(rh.role)
            return "\(rh.hold.id).\(roleCode)"
        }

        let payload = "V\(gradeNum)@\(route.angle):\(holdStrings.joined(separator: "|"))"

        var components = URLComponents()
        components.scheme = scheme
        components.host = host
        components.queryItems = [URLQueryItem(name: "d", value: payload)]
        return components.url
    }

    // MARK: - Decode

    /// Decode a `doomclimb://route?d=...` URL back into a BoulderRoute.
    static func decode(from url: URL) throws -> BoulderRoute {
        guard url.scheme?.lowercased() == scheme,
              url.host?.lowercased() == host,
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let payload = components.queryItems?.first(where: { $0.name == "d" })?.value
        else {
            throw DecodeError.malformed
        }

        return try decodePayload(payload)
    }

    /// Decode just the raw payload string (the part after "d="). Useful when
    /// the user pastes a code instead of tapping a link.
    static func decodePayload(_ payload: String) throws -> BoulderRoute {
        // Split "V4@40:1024.1|1156.0|..."
        let headerHoldsSplit = payload.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
        guard headerHoldsSplit.count == 2 else { throw DecodeError.malformed }

        let header    = String(headerHoldsSplit[0])
        let holdsPart = String(headerHoldsSplit[1])

        // Parse "V4@40"
        let gradeAngleSplit = header.split(separator: "@")
        guard gradeAngleSplit.count == 2 else { throw DecodeError.malformed }

        let gradeStr = String(gradeAngleSplit[0]).trimmingCharacters(in: CharacterSet(charactersIn: "Vv"))
        guard let gradeNum = Int(gradeStr),
              let angle    = Int(gradeAngleSplit[1]) else {
            throw DecodeError.malformed
        }

        // Parse each "pid.role" pair
        let holdTokens = holdsPart.split(separator: "|")
        var routeHolds: [RouteHold] = []

        for token in holdTokens {
            let parts = token.split(separator: ".")
            guard parts.count == 2,
                  let pid      = Int(parts[0]),
                  let roleCode = Int(parts[1]),
                  let role     = codeToRole(roleCode) else {
                throw DecodeError.malformed
            }

            guard let pos = HoldSocketMap.positions[pid] else {
                throw DecodeError.unknownHold(pid)
            }

            let hold = Hold(
                id: pid,
                row: 0, col: 0,
                x: Double(pos.x),
                y: Double(pos.y),
                holdType: .jug,
                difficulty: 5
            )
            routeHolds.append(RouteHold(hold: hold, role: role))
        }

        guard !routeHolds.isEmpty else { throw DecodeError.noHolds }

        return BoulderRoute(
            name:        nil,
            holds:       routeHolds,
            grade:       "V\(gradeNum)",
            angle:       angle,
            technique:   "Shared",
            generatedAt: .now
        )
    }

    // MARK: - Role <-> Code

    private static func roleToCode(_ role: HoldRole) -> Int {
        switch role {
        case .start:    return 0
        case .middle:   return 1
        case .finish:   return 2
        case .footOnly: return 3
        }
    }

    private static func codeToRole(_ code: Int) -> HoldRole? {
        switch code {
        case 0: return .start
        case 1: return .middle
        case 2: return .finish
        case 3: return .footOnly
        default: return nil
        }
    }
}
