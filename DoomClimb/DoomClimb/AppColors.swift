import SwiftUI

// MARK: - DoomClimb Brand Palette
// Monochromatic green derived from Adobe Color.
// Hold colors (start/hand/finish/foot) are NOT defined here — those are
// Kilter LED colors defined on HoldRole and must never change.

extension Color {
    /// Vibrant mid-green. Primary CTAs, progress bars, send tracking.
    static let dcPrimary   = Color(hex: "38B51F")
    /// Muted forest green. Secondary actions, sliders, labels, icons.
    static let dcSecondary = Color(hex: "3E8C2E")
    /// Electric bright green. Celebration moments, accent highlights.
    static let dcAccent    = Color(hex: "25E000")
    /// Dark forest green. Active/selected surface states.
    static let dcSurface   = Color(hex: "396130")
    /// Very dark green. Deep surfaces, overlays.
    static let dcDeep      = Color(hex: "273624")
    /// Near-black green. Forced dark-mode app background.
    static let dcBase      = Color(hex: "2C332B")

    // MARK: - Hex initializer

    init(hex: String) {
        let hex = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&int)
        let r = Double((int >> 16) & 0xFF) / 255
        let g = Double((int >> 8)  & 0xFF) / 255
        let b = Double( int        & 0xFF) / 255
        self.init(red: r, green: g, blue: b)
    }
}
