import SwiftUI
import NeonMicKit

/// One download in ``VideoDownloadListView``: cover, song, a player-accented
/// progress bar, the live speed/ETA line, a state glyph, and the contextual
/// action (cancel while active, retry when failed, dismiss when finished).
struct VideoDownloadRowView: View {
    /// The observed row this view renders and drives.
    let item: DownloadItem
    /// Cancel the in-flight download.
    var onCancel: () -> Void = {}
    /// Restart a failed or cancelled download.
    var onRetry: () -> Void = {}
    /// Remove a finished/failed row from the list.
    var onRemove: () -> Void = {}

    private var accent: Color { item.player.accent }

    var body: some View {
        HStack(spacing: 14) {
            SongCoverView(song: item.song, size: 56, accent: accent)

            VStack(alignment: .leading, spacing: 6) {
                header
                NeonProgressBar(
                    fraction: item.fractionCompleted,
                    accent: accent,
                    indeterminate: item.state == .pending
                )
                .frame(height: 6)
                statusLine
            }

            actionControl
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(NeonMicDesign.roomGlow)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(accent.opacity(item.state.isActive ? 0.35 : 0.12), lineWidth: 1)
        )
    }

    // MARK: Pieces

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                Text(item.song.title)
                    .font(.system(size: 15, weight: .bold, design: .rounded))
                    .foregroundStyle(NeonMicDesign.paper)
                    .lineLimit(1)
                Text(item.song.artist)
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .foregroundStyle(NeonMicDesign.paper.opacity(0.55))
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            PlayerBadge(player: item.player)
        }
    }

    private var statusLine: some View {
        HStack(spacing: 6) {
            DownloadStateIcon(state: item.state, accent: accent)
            Text(statusText)
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundStyle(statusColor)
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }

    @ViewBuilder
    private var actionControl: some View {
        switch item.state {
        case .pending, .downloading:
            CircleIconButton(system: "xmark", accent: accent, action: onCancel)
                .help("Annuler")
        case .failed, .cancelled:
            CircleIconButton(system: "arrow.clockwise", accent: NeonMicDesign.signalYellow, action: onRetry)
                .help("Réessayer")
        case .completed:
            CircleIconButton(system: "checkmark", accent: NeonMicDesign.electricCyan, action: onRemove)
                .help("Retirer de la liste")
        }
    }

    // MARK: Status text

    private var statusText: String {
        switch item.state {
        case .pending:
            return "En file d'attente…"
        case .downloading:
            if item.phase == .extractingAudio {
                return "Extraction audio…"
            }
            var parts = ["\(Int((item.fractionCompleted * 100).rounded())) %"]
            if let speed = item.speedBytesPerSecond, speed > 0 {
                parts.append(DownloadFormat.speed(speed))
            }
            if let eta = item.etaSeconds {
                parts.append(DownloadFormat.eta(eta))
            }
            return parts.joined(separator: "  ·  ")
        case .completed:
            return "Terminé"
        case .cancelled:
            return "Annulé"
        case .failed(let message):
            return message
        }
    }

    private var statusColor: Color {
        switch item.state {
        case .completed: NeonMicDesign.electricCyan
        case .failed: NeonMicDesign.neonPink
        case .cancelled: NeonMicDesign.paper.opacity(0.4)
        default: NeonMicDesign.paper.opacity(0.6)
        }
    }
}

// MARK: - Neon progress bar

/// A thin capsule track with a glowing accent fill. When `indeterminate` it
/// runs a looping shimmer instead of a fixed fill (used while queued).
struct NeonProgressBar: View {
    let fraction: Double
    var accent: Color = NeonMicDesign.neonPink
    var indeterminate: Bool = false

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(NeonMicDesign.paper.opacity(0.08))
                if indeterminate {
                    ShimmerBar(accent: accent, width: geo.size.width)
                } else {
                    Capsule()
                        .fill(
                            LinearGradient(
                                colors: [accent.opacity(0.7), accent],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                        .frame(width: max(0, min(1, fraction)) * geo.size.width)
                        .neonGlow(accent, radius: 5)
                        .animation(.easeOut(duration: 0.3), value: fraction)
                }
            }
        }
    }

    /// A short accent segment sliding across the track for the queued state.
    private struct ShimmerBar: View {
        let accent: Color
        let width: CGFloat
        @State private var phase: CGFloat = -0.3

        var body: some View {
            let segment = width * 0.35
            Capsule()
                .fill(
                    LinearGradient(
                        colors: [accent.opacity(0), accent, accent.opacity(0)],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                )
                .frame(width: segment)
                .neonGlow(accent, radius: 4)
                .offset(x: phase * width)
                .onAppear {
                    withAnimation(.easeInOut(duration: 1.1).repeatForever(autoreverses: false)) {
                        phase = 1.0
                    }
                }
        }
    }
}

// MARK: - State icon

/// The little status glyph in front of the progress line.
struct DownloadStateIcon: View {
    let state: VideoDownloadState
    var accent: Color = NeonMicDesign.neonPink

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: 11, weight: .bold))
            .foregroundStyle(color)
            .symbolEffect(.pulse, options: .repeating, isActive: state == .downloading)
    }

    private var symbol: String {
        switch state {
        case .pending: "hourglass"
        case .downloading: "arrow.down"
        case .completed: "checkmark.circle.fill"
        case .cancelled: "minus.circle"
        case .failed: "exclamationmark.triangle.fill"
        }
    }

    private var color: Color {
        switch state {
        case .pending: NeonMicDesign.ultraViolet
        case .downloading: accent
        case .completed: NeonMicDesign.electricCyan
        case .cancelled: NeonMicDesign.paper.opacity(0.4)
        case .failed: NeonMicDesign.neonPink
        }
    }
}

// MARK: - Small controls

/// A round neon-outlined icon button used for row actions.
struct CircleIconButton: View {
    let system: String
    var accent: Color = NeonMicDesign.neonPink
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: system)
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(NeonMicDesign.paper)
                .frame(width: 30, height: 30)
                .background(Circle().fill(hovering ? accent.opacity(0.22) : NeonMicDesign.inkDeep))
                .overlay(Circle().strokeBorder(accent.opacity(hovering ? 1 : 0.6), lineWidth: 1.5))
                .neonGlow(accent, radius: hovering ? 8 : 3)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
    }
}

/// A tiny "P1"/"P2" chip tinted with the player's accent.
struct PlayerBadge: View {
    let player: DownloadPlayer

    var body: some View {
        Text(player.badge)
            .font(.system(size: 9, weight: .heavy, design: .monospaced))
            .foregroundStyle(player.accent)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Capsule().fill(player.accent.opacity(0.14)))
            .overlay(Capsule().strokeBorder(player.accent.opacity(0.5), lineWidth: 1))
    }
}

#Preview("Download rows") {
    let center = DownloadCenter.previewFilled()
    return VStack(spacing: 12) {
        ForEach(center.items) { item in
            VideoDownloadRowView(item: item)
        }
    }
    .padding(24)
    .frame(width: 520)
    .background(NeonMicDesign.ink)
}
