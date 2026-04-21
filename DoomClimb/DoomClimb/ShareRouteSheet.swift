import SwiftUI
import CoreImage.CIFilterBuiltins

// MARK: - Share Route Sheet
// Shows a QR code encoding the route as a doomclimb:// deep link, plus a
// share button that opens the iOS share sheet. Another DoomClimb user
// scanning the QR — or tapping the link — will have the route loaded and
// auto-saved in their app.

struct ShareRouteSheet: View {
    let route: BoulderRoute
    @Environment(\.dismiss) private var dismiss

    private var shareURL: URL? {
        RouteShareCodec.encode(route)
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 28) {
                VStack(spacing: 6) {
                    Text("Share This Climb")
                        .font(.system(.title2, design: .rounded, weight: .bold))
                    Text("Scan this QR code with another DoomClimb user's phone to send them this exact climb.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 8)
                }

                if let url = shareURL, let qrImage = QRCode.generate(from: url.absoluteString) {
                    Image(uiImage: qrImage)
                        .interpolation(.none)
                        .resizable()
                        .scaledToFit()
                        .frame(maxWidth: 260, maxHeight: 260)
                        .padding(20)
                        .background(Color.white, in: RoundedRectangle(cornerRadius: 14))
                } else {
                    ContentUnavailableView(
                        "Couldn't generate code",
                        systemImage: "qrcode.viewfinder",
                        description: Text("This route has no shareable holds.")
                    )
                }

                VStack(spacing: 10) {
                    HStack(spacing: 10) {
                        badge(route.grade, icon: "figure.climbing", color: .dcPrimary)
                        badge("\(route.angle)°", icon: "arrow.up.right", color: .dcSecondary)
                        badge("\(route.moveCount) moves", icon: "arrow.up.forward", color: .dcSecondary)
                    }
                    .font(.caption)
                }

                if let url = shareURL {
                    ShareLink(item: url,
                              subject: Text("DoomClimb route"),
                              message: Text("Try this climb in DoomClimb: \(route.grade) @ \(route.angle)°")) {
                        HStack {
                            Image(systemName: "square.and.arrow.up")
                            Text("Share Link")
                                .fontWeight(.semibold)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.dcPrimary)
                }

                Spacer(minLength: 0)
            }
            .padding()
            .navigationTitle("Share")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private func badge(_ text: String, icon: String, color: Color) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
            Text(text).lineLimit(1)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(color.opacity(0.12), in: Capsule())
        .foregroundStyle(color)
    }
}

// MARK: - QR Code Generation

enum QRCode {
    /// Render a QR code PNG-style UIImage from a string. Uses CoreImage's
    /// built-in QR generator — no third-party dependencies needed.
    static func generate(from string: String) -> UIImage? {
        let context = CIContext()
        let filter  = CIFilter.qrCodeGenerator()
        guard let data = string.data(using: .utf8) else { return nil }
        filter.message = data
        filter.correctionLevel = "M"  // 15% error correction — good balance

        guard let output = filter.outputImage else { return nil }

        // Scale up so it's crisp when displayed; .interpolation(.none) keeps edges sharp.
        let scaled = output.transformed(by: CGAffineTransform(scaleX: 10, y: 10))

        guard let cgImage = context.createCGImage(scaled, from: scaled.extent) else { return nil }
        return UIImage(cgImage: cgImage)
    }
}
