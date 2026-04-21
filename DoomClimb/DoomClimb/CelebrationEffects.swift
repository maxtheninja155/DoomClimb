import SwiftUI
import UIKit

// MARK: - Send Flash
// Subtle one-shot "you sent it" effect: a green checkmark seal scales up
// from the center and fades while a ring of sparkles radiates outward.
// Triggered by incrementing a bound Int — each change replays the animation.

struct SendFlashOverlay: ViewModifier {
    @Binding var trigger: Int
    @State private var playing = false
    @State private var scale: CGFloat = 0.4
    @State private var opacity: CGFloat = 0
    @State private var sparkleProgress: CGFloat = 0

    func body(content: Content) -> some View {
        content
            .overlay(alignment: .center) {
                if playing {
                    ZStack {
                        ForEach(0..<8, id: \.self) { i in
                            Image(systemName: "sparkle")
                                .font(.title3)
                                .foregroundStyle(.yellow)
                                .offset(sparkleOffset(for: i))
                                .opacity(1 - sparkleProgress)
                        }

                        Image(systemName: "checkmark.seal.fill")
                            .font(.system(size: 92, weight: .bold))
                            .foregroundStyle(Color.dcAccent)
                            .shadow(color: .dcAccent.opacity(0.45), radius: 18)
                            .scaleEffect(scale)
                            .opacity(opacity)
                    }
                    .allowsHitTesting(false)
                }
            }
            .onChange(of: trigger) { _, _ in play() }
    }

    private func sparkleOffset(for i: Int) -> CGSize {
        let angle = Double(i) / 8.0 * 2 * .pi
        let radius: CGFloat = 50 + sparkleProgress * 60
        return CGSize(width: cos(angle) * radius, height: sin(angle) * radius)
    }

    private func play() {
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        scale = 0.4
        opacity = 0
        sparkleProgress = 0
        playing = true

        withAnimation(.spring(response: 0.35, dampingFraction: 0.55)) {
            scale = 1.15
            opacity = 1
        }
        withAnimation(.easeOut(duration: 0.75)) {
            sparkleProgress = 1
        }
        withAnimation(.easeIn(duration: 0.4).delay(0.45)) {
            opacity = 0
            scale = 1.6
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) {
            playing = false
        }
    }
}

extension View {
    /// Subtle success effect for a single-climb send.
    func sendFlash(trigger: Binding<Int>) -> some View {
        modifier(SendFlashOverlay(trigger: trigger))
    }
}

// MARK: - Confetti
// Lightweight SwiftUI confetti without any external dependency. A burst of
// ~28 colored shapes falls from the top with randomized horizontal drift
// and rotation. One-shot: triggered by incrementing a bound Int.

private struct ConfettiPiece: Identifiable {
    let id = UUID()
    let x: CGFloat              // 0..1 horizontal start
    let color: Color
    let shape: Int              // 0=circle, 1=rect, 2=triangle
    let size: CGFloat
    let delay: Double
    let duration: Double
    let drift: CGFloat
    let spin: Double
}

struct ConfettiBurst: View {
    @Binding var trigger: Int
    @State private var pieces: [ConfettiPiece] = []
    @State private var progress: CGFloat = 0

    private let palette: [Color] = [.dcPrimary, .dcAccent, .dcSecondary, .yellow, .orange, .pink]

    var body: some View {
        GeometryReader { geo in
            ZStack {
                ForEach(pieces) { p in
                    confettiShape(p)
                        .fill(p.color)
                        .frame(width: p.size, height: p.size)
                        .rotationEffect(.degrees(progress * p.spin))
                        .position(
                            x: p.x * geo.size.width + drift(for: p) * geo.size.width,
                            y: -20 + progress * (geo.size.height + 60)
                        )
                        .opacity(opacity(for: p))
                }
            }
            .allowsHitTesting(false)
        }
        .onChange(of: trigger) { _, _ in fire() }
    }

    private func drift(for p: ConfettiPiece) -> CGFloat {
        let t = max(0, min(1, (progress - CGFloat(p.delay)) / CGFloat(p.duration)))
        return p.drift * sin(t * .pi * 2) * 0.08
    }

    private func opacity(for p: ConfettiPiece) -> Double {
        let t = Double(progress) - p.delay
        if t < 0 { return 0 }
        if t > p.duration { return 0 }
        if t > p.duration - 0.3 { return max(0, (p.duration - t) / 0.3) }
        return 1
    }

    private func confettiShape(_ p: ConfettiPiece) -> AnyShape {
        switch p.shape {
        case 0:  return AnyShape(Circle())
        case 1:  return AnyShape(Rectangle())
        default: return AnyShape(Triangle())
        }
    }

    private func fire() {
        pieces = (0..<28).map { _ in
            ConfettiPiece(
                x: .random(in: 0...1),
                color: palette.randomElement() ?? .green,
                shape: Int.random(in: 0...2),
                size: CGFloat.random(in: 7...12),
                delay: Double.random(in: 0...0.35),
                duration: Double.random(in: 1.1...1.6),
                drift: CGFloat.random(in: -1...1),
                spin: Double.random(in: -540...540)
            )
        }
        progress = 0
        withAnimation(.easeIn(duration: 1.8)) {
            progress = 1
        }
    }
}

private struct Triangle: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: rect.midX, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        p.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        p.closeSubpath()
        return p
    }
}
