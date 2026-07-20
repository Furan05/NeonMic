import SwiftUI
import NeonMicKit

/// A song's cover art, loaded from its library folder, with a neon fallback.
///
/// The library folder is user-picked, so the read is wrapped in a balanced
/// security-scope claim (the same pattern chart/audio reads use). The image is
/// loaded off the main actor and only the decoded bytes cross back.
struct SongCoverView: View {
    let song: Song
    var size: CGFloat = 56
    var cornerRadius: CGFloat = 10
    /// Accent used by the placeholder glyph and border.
    var accent: Color = NeonMicDesign.ultraViolet

    @State private var image: NSImage?

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: cornerRadius)
                .fill(NeonMicDesign.inkDeep)

            if let image {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                Image(systemName: "music.note")
                    .font(.system(size: size * 0.4, weight: .semibold))
                    .foregroundStyle(accent.opacity(0.7))
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
        .overlay(
            RoundedRectangle(cornerRadius: cornerRadius)
                .strokeBorder(accent.opacity(0.35), lineWidth: 1)
        )
        .task(id: coverPath?.path) { await load() }
    }

    private var coverPath: URL? {
        guard let folder = song.libraryFolderURL, let name = song.coverFileName else { return nil }
        return folder.appendingPathComponent(name)
    }

    private func load() async {
        guard let folder = song.libraryFolderURL, let path = coverPath else {
            image = nil
            return
        }
        let data = await Task.detached(priority: .utility) { () -> Data? in
            let accessing = folder.startAccessingSecurityScopedResource()
            defer { if accessing { folder.stopAccessingSecurityScopedResource() } }
            return try? Data(contentsOf: path)
        }.value
        image = data.flatMap(NSImage.init(data:))
    }
}
