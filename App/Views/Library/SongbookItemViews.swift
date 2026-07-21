import SwiftUI
import NeonMicKit

/// One song as a Songbook list row: cover, title with a "Clip" badge, artist,
/// an inline progress bar while downloading, and the status glyph. Songs that
/// offer a clip are gently highlighted; the selected row glows brighter.
struct SongbookRowView: View {
    let entry: LibrarySong
    let item: DownloadItem?
    var isSelected: Bool = false

    private var status: SongClipStatus {
        .resolve(hasClipOnDisk: entry.hasClipOnDisk, hasSource: entry.hasClipSource, item: item)
    }
    private var accent: Color {
        entry.hasClipSource ? NeonMicDesign.electricCyan : NeonMicDesign.ultraViolet
    }

    var body: some View {
        HStack(spacing: 12) {
            SongCoverView(song: entry.song, size: 44, cornerRadius: 8, accent: accent)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(entry.title)
                        .font(.system(size: 14, weight: .bold, design: .rounded))
                        .foregroundStyle(NeonMicDesign.paper)
                        .lineLimit(1)
                    if entry.hasClipSource {
                        ClipBadge(isDownloaded: entry.hasClipOnDisk)
                    }
                }
                Text(entry.artist)
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .foregroundStyle(NeonMicDesign.paper.opacity(0.55))
                    .lineLimit(1)
                if status == .downloading, let item {
                    NeonProgressBar(
                        fraction: item.fractionCompleted,
                        accent: NeonMicDesign.signalYellow,
                        indeterminate: item.state == .pending
                    )
                    .frame(height: 4)
                    .padding(.top, 2)
                }
            }

            Spacer(minLength: 8)
            ClipStatusIcon(status: status)
        }
        .padding(.vertical, 7)
        .padding(.horizontal, 10)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(isSelected ? accent.opacity(0.16)
                      : (entry.hasClipSource ? NeonMicDesign.roomGlow.opacity(0.5) : Color.clear))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(accent.opacity(isSelected ? 0.8 : 0), lineWidth: 1.5)
        )
        .contentShape(Rectangle())
    }
}

/// One song as a Songbook grid cell: a clip thumbnail (frame or cover) topped
/// with the "Clip" badge and status glyph, over the title and artist.
struct SongbookGridCell: View {
    let entry: LibrarySong
    let item: DownloadItem?
    var isSelected: Bool = false

    private var status: SongClipStatus {
        .resolve(hasClipOnDisk: entry.hasClipOnDisk, hasSource: entry.hasClipSource, item: item)
    }
    private var accent: Color {
        entry.hasClipSource ? NeonMicDesign.electricCyan : NeonMicDesign.ultraViolet
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ZStack(alignment: .topLeading) {
                ClipThumbnailView(
                    song: entry.song,
                    hasClipOnDisk: entry.hasClipOnDisk,
                    size: 148,
                    cornerRadius: 14,
                    accent: accent
                )
                if entry.hasClipSource {
                    ClipBadge(isDownloaded: entry.hasClipOnDisk)
                        .padding(8)
                }
                if status == .downloading, let item {
                    downloadingOverlay(item: item)
                }
            }
            .overlay(alignment: .topTrailing) {
                ClipStatusIcon(status: status).padding(8)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(entry.title)
                    .font(.system(size: 13, weight: .bold, design: .rounded))
                    .foregroundStyle(NeonMicDesign.paper)
                    .lineLimit(1)
                Text(entry.artist)
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .foregroundStyle(NeonMicDesign.paper.opacity(0.55))
                    .lineLimit(1)
            }
        }
        .padding(8)
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(isSelected ? accent.opacity(0.14) : NeonMicDesign.roomGlow.opacity(0.6))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .strokeBorder(accent.opacity(isSelected ? 0.85 : 0.12), lineWidth: 1.5)
        )
        .contentShape(Rectangle())
    }

    private func downloadingOverlay(item: DownloadItem) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 14).fill(NeonMicDesign.inkDeep.opacity(0.55))
            CircularProgressRing(
                fraction: item.fractionCompleted,
                accent: NeonMicDesign.signalYellow,
                indeterminate: item.state == .pending,
                lineWidth: 4
            )
            .frame(width: 46, height: 46)
        }
        .frame(width: 148, height: 148)
    }
}
