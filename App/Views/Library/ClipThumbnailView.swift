import SwiftUI
import AppKit
import AVFoundation
import NeonMicKit

/// A grid thumbnail for a song: a frame grabbed from the downloaded clip when
/// one exists, otherwise the cover art. A small play glyph marks songs whose
/// clip is already on disk.
///
/// Frame extraction runs off the main actor and is cached by video path, so a
/// scroll never re-decodes. The library folder is user-picked, so the read is
/// wrapped in a balanced security-scope claim.
struct ClipThumbnailView: View {
    let song: Song
    var hasClipOnDisk: Bool
    var size: CGFloat = 132
    var cornerRadius: CGFloat = 12
    var accent: Color = NeonMicDesign.electricCyan

    @State private var frame: NSImage?

    var body: some View {
        ZStack {
            if let frame {
                Image(nsImage: frame)
                    .resizable()
                    .scaledToFill()
                    .frame(width: size, height: size)
                    .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
                    .overlay(
                        RoundedRectangle(cornerRadius: cornerRadius)
                            .strokeBorder(accent.opacity(0.4), lineWidth: 1)
                    )
            } else {
                SongCoverView(song: song, size: size, cornerRadius: cornerRadius, accent: accent)
            }

            if hasClipOnDisk {
                Image(systemName: "play.circle.fill")
                    .font(.system(size: 26, weight: .regular))
                    .foregroundStyle(NeonMicDesign.paper.opacity(0.92))
                    .neonGlow(accent, radius: 6)
            }
        }
        .frame(width: size, height: size)
        .task(id: taskKey) { await load() }
    }

    private var videoPath: URL? { hasClipOnDisk ? song.videoPath : nil }
    private var taskKey: String { "\(videoPath?.path ?? "none")-\(hasClipOnDisk)" }

    @MainActor
    private func load() async {
        guard let path = videoPath, let folder = song.libraryFolderURL else {
            frame = nil
            return
        }
        let key = path.path as NSString
        if let cached = Self.cache.object(forKey: key) {
            frame = cached
            return
        }
        let data = await Task.detached(priority: .utility) { () -> Data? in
            let accessing = folder.startAccessingSecurityScopedResource()
            defer { if accessing { folder.stopAccessingSecurityScopedResource() } }
            let asset = AVURLAsset(url: path)
            let generator = AVAssetImageGenerator(asset: asset)
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: 480, height: 480)
            let time = CMTime(seconds: 1, preferredTimescale: 600)
            guard let result = try? await generator.image(at: time) else { return nil }
            return NSBitmapImageRep(cgImage: result.image).representation(using: .png, properties: [:])
        }.value
        guard let data, let image = NSImage(data: data) else { return }
        Self.cache.setObject(image, forKey: key)
        frame = image
    }

    /// Decoded frames, keyed by video path — cheap re-renders on scroll.
    @MainActor private static let cache = NSCache<NSString, NSImage>()
}
