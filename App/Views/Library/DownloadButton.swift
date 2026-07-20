import SwiftUI
import NeonMicKit

/// The per-song "download the background clip" control.
///
/// One adaptive control that swaps between four looks driven by the shared
/// ``DownloadCenter``: an idle neon button, a circular progress indicator
/// while it runs, a done pill, and a retry prompt on failure — each with its
/// own contextual status line. Drop it anywhere a `Song` is on screen.
struct DownloadButton: View {
    /// The song whose clip this button downloads.
    let song: Song
    /// Which player's accent tints the progress ring.
    var player: DownloadPlayer = .one

    @Environment(DownloadCenter.self) private var center

    var body: some View {
        let item = center.item(for: song)
        VStack(spacing: 8) {
            control(for: item)
            statusLine(for: item)
        }
        .animation(.easeOut(duration: 0.25), value: item?.state)
    }

    // MARK: Control

    @ViewBuilder
    private func control(for item: DownloadItem?) -> some View {
        switch item?.state {
        case .some(.pending), .some(.downloading):
            activeControl(item!)
        case .some(.completed):
            completedControl(item!)
        case .some(.failed), .some(.cancelled):
            retryControl(item!)
        case .none:
            idleButton
        }
    }

    private var idleButton: some View {
        Button {
            center.start(song, player: player)
        } label: {
            Label("Télécharger clip", systemImage: "arrow.down.circle")
        }
        .buttonStyle(NeonButtonStyle(accent: player.accent))
        .disabled(!canDownload)
        .opacity(canDownload ? 1 : 0.4)
    }

    private func activeControl(_ item: DownloadItem) -> some View {
        HStack(spacing: 14) {
            CircularProgressRing(
                fraction: item.fractionCompleted,
                accent: player.accent,
                indeterminate: item.state == .pending || item.phase == .extractingAudio
            )
            .frame(width: 48, height: 48)

            Button {
                center.cancel(item)
            } label: {
                Label("Annuler", systemImage: "xmark")
            }
            .buttonStyle(NeonButtonStyle(accent: NeonMicDesign.ultraViolet))
        }
    }

    private func completedControl(_ item: DownloadItem) -> some View {
        HStack(spacing: 10) {
            Label("Clip téléchargé", systemImage: "checkmark.circle.fill")
                .font(.system(size: 15, weight: .bold, design: .rounded))
                .foregroundStyle(NeonMicDesign.electricCyan)
                .neonGlow(NeonMicDesign.electricCyan, radius: 4)
            CircleIconButton(system: "arrow.clockwise", accent: NeonMicDesign.ultraViolet) {
                center.start(song, player: player)
            }
            .help("Retélécharger")
        }
    }

    private func retryControl(_ item: DownloadItem) -> some View {
        Button {
            center.retry(item)
        } label: {
            Label("Réessayer", systemImage: "arrow.clockwise")
        }
        .buttonStyle(NeonButtonStyle(accent: NeonMicDesign.signalYellow))
    }

    // MARK: Status line

    @ViewBuilder
    private func statusLine(for item: DownloadItem?) -> some View {
        if let text = statusText(for: item) {
            Text(text)
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundStyle(statusColor(for: item))
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .frame(maxWidth: 260)
        }
    }

    private func statusText(for item: DownloadItem?) -> String? {
        guard let item else {
            return canDownload ? "Télécharge la vidéo de fond en tâche de fond." : "Aucune source vidéo pour ce chart."
        }
        switch item.state {
        case .pending:
            return "En file d'attente…"
        case .downloading:
            if item.phase == .extractingAudio { return "Extraction de l'audio…" }
            var line = "Téléchargement… \(Int((item.fractionCompleted * 100).rounded())) %"
            if let eta = item.etaSeconds { line += "  ·  \(DownloadFormat.eta(eta))" }
            return line
        case .completed:
            return "La vidéo est prête à jouer."
        case .cancelled:
            return "Téléchargement annulé."
        case .failed(let message):
            return message
        }
    }

    private func statusColor(for item: DownloadItem?) -> Color {
        switch item?.state {
        case .some(.completed): NeonMicDesign.electricCyan
        case .some(.failed): NeonMicDesign.neonPink
        default: NeonMicDesign.paper.opacity(0.5)
        }
    }

    private var canDownload: Bool {
        song.videoSourceURL != nil
    }
}

// MARK: - Circular progress ring

/// A glowing circular progress meter. With a known `fraction` it fills a ring;
/// while `indeterminate` it spins a short arc (the queued / extracting look).
/// The center reads the percentage, or a pulsing dot when indeterminate.
struct CircularProgressRing: View {
    let fraction: Double
    var accent: Color = NeonMicDesign.neonPink
    var indeterminate: Bool = false
    var lineWidth: CGFloat = 4

    @State private var spin = false

    var body: some View {
        ZStack {
            Circle()
                .stroke(NeonMicDesign.paper.opacity(0.1), lineWidth: lineWidth)

            if indeterminate {
                Circle()
                    .trim(from: 0, to: 0.28)
                    .stroke(accent, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                    .neonGlow(accent, radius: 5)
                    .rotationEffect(.degrees(spin ? 360 : 0))
                    .onAppear {
                        withAnimation(.linear(duration: 0.9).repeatForever(autoreverses: false)) {
                            spin = true
                        }
                    }
            } else {
                Circle()
                    .trim(from: 0, to: max(0.001, min(1, fraction)))
                    .stroke(accent, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .neonGlow(accent, radius: 5)
                    .animation(.easeOut(duration: 0.3), value: fraction)
            }

            centerLabel
        }
    }

    @ViewBuilder
    private var centerLabel: some View {
        if indeterminate {
            Circle()
                .fill(accent)
                .frame(width: 6, height: 6)
                .neonGlow(accent, radius: 4)
                .opacity(spin ? 1 : 0.4)
        } else {
            Text("\(Int((fraction * 100).rounded()))")
                .font(.system(size: 13, weight: .heavy, design: .rounded))
                .foregroundStyle(accent)
                .contentTransition(.numericText(value: fraction))
        }
    }
}

#Preview("Download button states") {
    let center = DownloadCenter.previewFilled()
    return VStack(spacing: 28) {
        ForEach(center.items) { item in
            DownloadButton(song: item.song, player: item.player)
        }
    }
    .environment(center)
    .padding(40)
    .frame(width: 360)
    .background(NeonMicDesign.ink)
}
