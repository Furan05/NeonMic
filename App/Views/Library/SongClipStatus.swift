import SwiftUI
import NeonMicKit

/// A song's background-clip situation, resolved from what's on disk plus any
/// live download. Drives the status glyph shown next to songs in the Songbook.
enum SongClipStatus {
    /// A clip is present on disk (or just finished downloading).
    case downloaded
    /// A download is pending or transferring right now.
    case downloading
    /// The last download attempt failed or was cancelled.
    case failed
    /// No clip yet, but the chart names a source we could fetch.
    case available
    /// The chart offers no downloadable clip.
    case none

    /// Resolves the status from cached disk state and the live download row.
    ///
    /// `hasClipOnDisk` is cached by ``LibraryService`` (never a per-render disk
    /// hit); `item` is the current ``DownloadItem``, if any. Main-actor
    /// isolated because it reads the observable ``DownloadItem/state``.
    @MainActor
    static func resolve(hasClipOnDisk: Bool, hasSource: Bool, item: DownloadItem?) -> SongClipStatus {
        if let item {
            switch item.state {
            case .pending, .downloading: return .downloading
            case .completed: return .downloaded
            case .failed: return .failed
            case .cancelled:
                return hasClipOnDisk ? .downloaded : (hasSource ? .available : .none)
            }
        }
        if hasClipOnDisk { return .downloaded }
        if hasSource { return .available }
        return .none
    }

    /// The token this status paints with.
    var accent: Color {
        switch self {
        case .downloaded: NeonMicDesign.electricCyan
        case .downloading: NeonMicDesign.signalYellow
        case .failed: NeonMicDesign.neonPink
        case .available: NeonMicDesign.ultraViolet
        case .none: NeonMicDesign.paper.opacity(0.3)
        }
    }

    /// The SF Symbol for the status, or nil when nothing should be drawn.
    var systemImage: String? {
        switch self {
        case .downloaded: "checkmark.circle.fill"
        case .downloading: "arrow.down.circle"
        case .failed: "exclamationmark.triangle.fill"
        case .available: "arrow.down.circle.dotted"
        case .none: nil
        }
    }

    /// A short accessibility / tooltip label.
    var label: String {
        switch self {
        case .downloaded: "Clip téléchargé"
        case .downloading: "Téléchargement en cours"
        case .failed: "Échec du téléchargement"
        case .available: "Clip disponible au téléchargement"
        case .none: "Pas de clip"
        }
    }
}

/// The status glyph shown next to a song. Pulses while downloading.
struct ClipStatusIcon: View {
    let status: SongClipStatus

    var body: some View {
        if let symbol = status.systemImage {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(status.accent)
                .symbolEffect(.pulse, options: .repeating, isActive: status == .downloading)
                .neonGlow(status == .downloaded ? status.accent : .clear, radius: 3)
                .help(status.label)
        }
    }
}

/// The little "Clip" pill marking songs that offer a downloadable background
/// video. Tinted electricCyan when the clip is already on disk, ultraViolet
/// when it can still be fetched.
struct ClipBadge: View {
    var isDownloaded: Bool

    private var accent: Color {
        isDownloaded ? NeonMicDesign.electricCyan : NeonMicDesign.ultraViolet
    }

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: "film.fill").font(.system(size: 8, weight: .bold))
            Text("Clip").font(.system(size: 9, weight: .heavy, design: .rounded))
        }
        .foregroundStyle(accent)
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(Capsule().fill(accent.opacity(0.14)))
        .overlay(Capsule().strokeBorder(accent.opacity(0.5), lineWidth: 1))
    }
}
