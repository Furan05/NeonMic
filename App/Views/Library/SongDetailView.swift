import SwiftUI
import NeonMicKit

/// A song's detail screen: big cover, metadata, and the actions for it —
/// the primary SING call-to-action and the background-clip ``DownloadButton``.
///
/// Presentation only: it reads the shared ``DownloadCenter`` from the
/// environment (via `DownloadButton`) and never touches the download queue
/// directly.
struct SongDetailView: View {
    let song: Song
    /// Which player's accent tints the download affordances.
    var player: DownloadPlayer = .one
    /// Invoked by the SING button; omit to hide it.
    var onSing: (() -> Void)?

    var body: some View {
        ZStack {
            NeonMicDesign.ink.ignoresSafeArea()

            VStack(spacing: 28) {
                hero
                metaChips
                actions
                Spacer(minLength: 0)
            }
            .padding(40)
            .frame(maxWidth: 560)

            GrainOverlay()
        }
    }

    // MARK: Hero

    private var hero: some View {
        VStack(spacing: 18) {
            SongCoverView(song: song, size: 200, cornerRadius: 18, accent: player.accent)
                .neonGlow(player.accent.opacity(0.5), radius: 18)

            VStack(spacing: 6) {
                Text(song.title)
                    .font(.system(size: 30, weight: .heavy, design: .rounded))
                    .foregroundStyle(NeonMicDesign.paper)
                    .multilineTextAlignment(.center)
                Text(song.artist)
                    .font(.system(size: 17, weight: .semibold, design: .rounded))
                    .foregroundStyle(player.accent)
                    .neonGlow(player.accent, radius: 6)
            }
        }
    }

    // MARK: Metadata

    private var metaChips: some View {
        HStack(spacing: 10) {
            if let year = song.year {
                MetaChip(text: String(year))
            }
            if let genre = song.genre, !genre.isEmpty {
                MetaChip(text: genre)
            }
            if let language = song.language, !language.isEmpty {
                MetaChip(text: language)
            }
            if song.hasVideo {
                MetaChip(text: "clip présent", accent: NeonMicDesign.electricCyan, icon: "film")
            }
        }
    }

    // MARK: Actions

    private var actions: some View {
        VStack(spacing: 18) {
            if let onSing {
                Button {
                    onSing()
                } label: {
                    Label("SING", systemImage: "mic.fill")
                }
                .buttonStyle(NeonButtonStyle(accent: NeonMicDesign.neonPink))
            }

            DownloadButton(song: song, player: player)
        }
    }
}

// MARK: - Meta chip

/// A rounded metadata pill (year, genre, language, "clip présent").
struct MetaChip: View {
    let text: String
    var accent: Color = NeonMicDesign.ultraViolet
    var icon: String?

    var body: some View {
        HStack(spacing: 5) {
            if let icon {
                Image(systemName: icon).font(.system(size: 10, weight: .bold))
            }
            Text(text)
                .font(.system(size: 11, weight: .bold, design: .monospaced))
        }
        .foregroundStyle(accent)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Capsule().fill(accent.opacity(0.12)))
        .overlay(Capsule().strokeBorder(accent.opacity(0.4), lineWidth: 1))
    }
}

#Preview("Song detail") {
    let song = Song(
        title: "Neon Skyline",
        artist: "The Midnights",
        bpm: 120,
        genre: "Synthpop",
        year: 1986,
        rawHeaders: ["VIDEOURL": "https://example.com/clip.mp4"]
    )
    return SongDetailView(song: song, player: .one, onSing: {})
        .environment(DownloadCenter())
        .frame(width: 620, height: 720)
}
