import SwiftUI
import AVKit
import PhotosUI
import UniformTypeIdentifiers

// MARK: - Video Attachment Section
// Embedded in ClimbDetailView. Shows an "Attach Send Video" button when no
// video is linked, or a thumbnail + play/remove controls when one is. The
// video file is copied into the app sandbox; the original stays in Photos.

struct VideoAttachmentSection: View {
    let climbId: UUID
    @ObservedObject var store: ClimbHistoryStore

    @State private var showPicker  = false
    @State private var showPlayer  = false
    @State private var thumbnail: UIImage?
    @State private var showRemoveConfirm = false
    @State private var isAttaching = false

    private var videoURL: URL? { store.videoURL(for: climbId) }
    private var hasVideo: Bool  { videoURL != nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Send Video", systemImage: "video.fill")
                .font(.system(.subheadline, design: .rounded, weight: .semibold))

            if hasVideo {
                attachedState
            } else {
                emptyState
            }
        }
        .padding()
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
        .sheet(isPresented: $showPicker) {
            VideoPicker(
                onLoadingStart: {
                    isAttaching = true
                },
                onPick: { tempURL in
                    store.attachVideo(id: climbId, from: tempURL)
                    isAttaching = false
                    generateThumbnail()
                }
            )
        }
        .fullScreenCover(isPresented: $showPlayer) {
            if let url = videoURL {
                VideoPlayerSheet(url: url)
            }
        }
        .onAppear { generateThumbnail() }
        .onChange(of: store.videoURL(for: climbId)?.path) { _, _ in
            generateThumbnail()
        }
        .confirmationDialog("Remove video?", isPresented: $showRemoveConfirm, titleVisibility: .visible) {
            Button("Remove", role: .destructive) {
                store.detachVideo(id: climbId)
                thumbnail = nil
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("This removes the video from DoomClimb. The original in your Photos is untouched.")
        }
    }

    // MARK: - States

    @ViewBuilder
    private var emptyState: some View {
        if isAttaching {
            HStack(spacing: 10) {
                ProgressView()
                    .tint(.purple)
                Text("Copying video…")
                    .font(.system(.subheadline, design: .rounded))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
        } else {
            Button {
                showPicker = true
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "video.badge.plus")
                    Text("Attach Send Video")
                        .fontWeight(.medium)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
            }
            .buttonStyle(.borderedProminent)
            .tint(.purple)
        }
    }

    @ViewBuilder
    private var attachedState: some View {
        HStack(spacing: 12) {
            // Thumbnail — tap to play
            Button { showPlayer = true } label: {
                ZStack {
                    if let img = thumbnail {
                        Image(uiImage: img)
                            .resizable()
                            .scaledToFill()
                    } else {
                        Color.black
                    }

                    Image(systemName: "play.circle.fill")
                        .font(.system(size: 36))
                        .foregroundStyle(.white.opacity(0.9))
                        .shadow(radius: 4)
                }
                .frame(width: 120, height: 80)
                .clipShape(RoundedRectangle(cornerRadius: 10))
            }
            .buttonStyle(.plain)

            VStack(alignment: .leading, spacing: 8) {
                Text("Video attached")
                    .font(.system(.subheadline, design: .rounded, weight: .semibold))
                Text("Tap to watch your send")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                HStack(spacing: 8) {
                    // Replace
                    Button {
                        showPicker = true
                    } label: {
                        Label("Replace", systemImage: "arrow.triangle.2.circlepath")
                            .font(.caption)
                    }
                    .buttonStyle(.bordered)
                    .tint(.purple)

                    // Remove
                    Button(role: .destructive) {
                        showRemoveConfirm = true
                    } label: {
                        Image(systemName: "trash")
                            .font(.caption)
                    }
                    .buttonStyle(.bordered)
                }
            }

            Spacer(minLength: 0)
        }
    }

    // MARK: - Thumbnail generation

    private func generateThumbnail() {
        guard let url = videoURL else { thumbnail = nil; return }
        Task.detached(priority: .userInitiated) {
            let asset = AVURLAsset(url: url)
            let gen   = AVAssetImageGenerator(asset: asset)
            gen.appliesPreferredTrackTransform = true
            gen.maximumSize = CGSize(width: 240, height: 160)
            let img: UIImage? = (try? gen.copyCGImage(at: .zero, actualTime: nil))
                .map { UIImage(cgImage: $0) }
            await MainActor.run { thumbnail = img }
        }
    }
}

// MARK: - Video Picker (PHPickerViewController wrapper)

struct VideoPicker: UIViewControllerRepresentable {
    let onLoadingStart: () -> Void
    let onPick: (URL) -> Void
    @Environment(\.dismiss) private var dismiss

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIViewController(context: Context) -> PHPickerViewController {
        var config = PHPickerConfiguration()
        config.filter = .videos
        config.selectionLimit = 1
        let picker = PHPickerViewController(configuration: config)
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: PHPickerViewController, context: Context) {}

    final class Coordinator: NSObject, PHPickerViewControllerDelegate {
        let parent: VideoPicker
        // Guard against loadFileRepresentation firing its callback multiple
        // times (happens when the video needs to download from iCloud first).
        private var hasCompleted = false

        init(_ parent: VideoPicker) { self.parent = parent }

        func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
            parent.dismiss()
            guard let provider = results.first?.itemProvider,
                  provider.hasItemConformingToTypeIdentifier(UTType.movie.identifier)
            else { return }

            // Signal the UI to show a loading spinner before the copy starts.
            Task { @MainActor in self.parent.onLoadingStart() }

            provider.loadFileRepresentation(forTypeIdentifier: UTType.movie.identifier) { url, error in
                guard !self.hasCompleted else { return }
                guard let url, error == nil else {
                    print("VideoPicker ⚠️  \(error?.localizedDescription ?? "no url")")
                    return
                }
                self.hasCompleted = true

                // url is only valid during this block — copy it immediately.
                let ext      = url.pathExtension.isEmpty ? "mov" : url.pathExtension
                let tempCopy = FileManager.default.temporaryDirectory
                    .appendingPathComponent(UUID().uuidString)
                    .appendingPathExtension(ext)
                do {
                    try FileManager.default.copyItem(at: url, to: tempCopy)
                    Task { @MainActor in self.parent.onPick(tempCopy) }
                } catch {
                    print("VideoPicker ❌  Copy failed: \(error)")
                }
            }
        }
    }
}

// MARK: - Fullscreen Video Player

struct VideoPlayerSheet: View {
    let url: URL
    @Environment(\.dismiss) private var dismiss
    @State private var player: AVPlayer?

    var body: some View {
        ZStack(alignment: .topTrailing) {
            VideoPlayer(player: player)
                .ignoresSafeArea()
                .background(.black)

            Button {
                player?.pause()
                dismiss()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.title)
                    .foregroundStyle(.white.opacity(0.85))
                    .shadow(radius: 4)
                    .padding(20)
            }
        }
        .onAppear {
            let p = AVPlayer(url: url)
            player = p
            p.play()
        }
        .onDisappear { player?.pause() }
    }
}
