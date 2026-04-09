import SwiftUI

struct BoardView: View {
    /// The route to render on the board. Pass `nil` to show an empty board.
    let route: BoulderRoute?

    /// Optional tap callback. When supplied, the board becomes interactive
    /// and invokes this closure for every tap, passing the local point and
    /// the current board size. Used by the climb editor.
    var onTap: ((CGPoint, CGSize) -> Void)? = nil

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height
            let dotD   = min(w, h) * 0.028   // small filled dot
            let ringD  = dotD * 1.5           // outer glow ring

            ZStack {
                // ── Kilter board photo ──────────────────────────────────────
                Image("kilterBoard")
                    .resizable()
                    .scaledToFit()
                    .frame(width: w, height: h)
                    .cornerRadius(12)

                // ── Hold-marker overlay (hidden, coordinate reference) ────
                Image("holdMarkers")
                    .resizable()
                    .scaledToFit()
                    .frame(width: w, height: h)
                    .opacity(0)

                // ── Active hold overlays ────────────────────────────────────
                // hold.x / hold.y come from HoldSocketMap — exact blob-detected
                // centers in Kilter-HoldMarkers.png, expressed as fractions of
                // image width/height. The marker image and the board photo are
                // perfectly aligned, so no row-shift compensation is needed.
                if let route = route {
                    ForEach(route.holds) { rh in
                        let posX = CGFloat(rh.hold.x) * w
                        let posY = CGFloat(rh.hold.y) * h

                        // Clean hollow circle
                        Circle()
                            .stroke(rh.role.color, lineWidth: 2.5)
                            .frame(width: ringD, height: ringD)
                            .shadow(color: rh.role.color.opacity(0.9), radius: 5)
                            .position(x: posX, y: posY)
                            .transition(.scale.combined(with: .opacity))
                    }
                }
            }
            .contentShape(Rectangle())
            .gesture(
                onTap == nil ? nil :
                DragGesture(minimumDistance: 0)
                    .onEnded { value in
                        // DragGesture with minimumDistance 0 gives us the
                        // exact tap location in the ZStack's local space.
                        onTap?(value.location, CGSize(width: w, height: h))
                    }
            )
        }
        .aspectRatio(451.0 / 509.0, contentMode: .fit)   // matches Kilter-HoldMarkers.png (source of truth)
    }
}

// MARK: - Legend strip shown below the board

struct HoldLegend: View {
    private let items: [(HoldRole, String)] = [
        (.start,    "Start"),
        (.middle,   "Hand"),
        (.finish,   "Finish"),
        (.footOnly, "Foot Only"),
    ]

    var body: some View {
        HStack(spacing: 16) {
            ForEach(items, id: \.0) { role, label in
                HStack(spacing: 5) {
                    Circle()
                        .stroke(role.color, lineWidth: 2)
                        .frame(width: 12, height: 12)
                    Text(label)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}

#Preview {
    VStack {
        BoardView(route: nil)
            .padding()
        HoldLegend()
    }
}
