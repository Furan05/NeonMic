import SwiftUI
import NeonMicKit

/// A floating download HUD that rides above every screen.
///
/// Overlaid on the app root, so it is reachable from the songbook, a detail
/// screen, or mid-game. It stays hidden while nothing is downloading, shows a
/// compact pill with aggregate progress when work is in flight, expands to a
/// per-download summary, and opens the full ``VideoDownloadListView`` in a
/// sheet for the whole history.
struct DownloadOverlayView: View {
    @Environment(DownloadCenter.self) private var center

    @State private var expanded = false
    @State private var showingList = false

    var body: some View {
        Group {
            if shouldShow {
                panel
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        .animation(.spring(response: 0.35, dampingFraction: 0.85), value: shouldShow)
        .animation(.spring(response: 0.3, dampingFraction: 0.85), value: expanded)
        .sheet(isPresented: $showingList) {
            VideoDownloadListView()
                .environment(center)
                .frame(minWidth: 560, minHeight: 480)
        }
    }

    @ViewBuilder
    private var panel: some View {
        if expanded {
            expandedCard
        } else {
            collapsedPill
        }
    }

    // MARK: Collapsed

    private var collapsedPill: some View {
        Button {
            expanded = true
        } label: {
            HStack(spacing: 12) {
                CircularProgressRing(
                    fraction: aggregateFraction,
                    accent: accent,
                    indeterminate: allPending,
                    lineWidth: 3
                )
                .frame(width: 30, height: 30)

                VStack(alignment: .leading, spacing: 1) {
                    Text(summaryTitle)
                        .font(.system(size: 13, weight: .bold, design: .rounded))
                        .foregroundStyle(NeonMicDesign.paper)
                    Text(summarySubtitle)
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .foregroundStyle(NeonMicDesign.paper.opacity(0.5))
                }
                Image(systemName: "chevron.up")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(NeonMicDesign.paper.opacity(0.5))
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(cardBackground)
        }
        .buttonStyle(.plain)
    }

    // MARK: Expanded

    private var expandedCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Téléchargements")
                    .font(.system(size: 14, weight: .heavy, design: .rounded))
                    .foregroundStyle(NeonMicDesign.paper)
                Spacer()
                CircleIconButton(system: "chevron.down", accent: NeonMicDesign.ultraViolet) {
                    expanded = false
                }
                .help("Réduire")
            }

            ForEach(previewedItems) { item in
                MiniDownloadRow(item: item, onCancel: { center.cancel(item) }, onRetry: { center.retry(item) })
            }

            if overflowCount > 0 {
                Text("+ \(overflowCount) autre\(overflowCount > 1 ? "s" : "")")
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundStyle(NeonMicDesign.paper.opacity(0.4))
            }

            Button {
                showingList = true
            } label: {
                Label("Voir tout", systemImage: "list.bullet")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(NeonButtonStyle(accent: accent))
        }
        .padding(16)
        .frame(width: 320)
        .background(cardBackground)
    }

    private var cardBackground: some View {
        RoundedRectangle(cornerRadius: 16)
            .fill(NeonMicDesign.roomGlow)
            .overlay(
                RoundedRectangle(cornerRadius: 16)
                    .strokeBorder(accent.opacity(0.35), lineWidth: 1)
            )
            .neonGlow(accent.opacity(0.6), radius: 10)
    }

    // MARK: Derived state

    private var shouldShow: Bool {
        !center.activeItems.isEmpty || !center.failedItems.isEmpty
    }

    /// Active rows first (they're the story), then anything needing attention.
    private var relevantItems: [DownloadItem] {
        center.activeItems + center.failedItems
    }

    private var previewedItems: [DownloadItem] { Array(relevantItems.prefix(3)) }
    private var overflowCount: Int { max(0, relevantItems.count - previewedItems.count) }

    private var aggregateFraction: Double {
        let active = center.activeItems
        guard !active.isEmpty else { return 1 }
        return active.map(\.fractionCompleted).reduce(0, +) / Double(active.count)
    }

    private var allPending: Bool {
        let active = center.activeItems
        return !active.isEmpty && active.allSatisfy { $0.state == .pending }
    }

    /// Accent follows the first active download's player, so the HUD glows the
    /// same pink/cyan as the row it is summarizing.
    private var accent: Color {
        center.activeItems.first?.player.accent
            ?? center.failedItems.first?.player.accent
            ?? NeonMicDesign.neonPink
    }

    private var summaryTitle: String {
        let active = center.activeItems.count
        if active > 0 {
            return "\(active) téléchargement\(active > 1 ? "s" : "")"
        }
        let failed = center.failedItems.count
        return "\(failed) échec\(failed > 1 ? "s" : "")"
    }

    private var summarySubtitle: String {
        if center.activeItems.isEmpty {
            return "à revoir"
        }
        return "\(Int((aggregateFraction * 100).rounded())) % · appuie pour détails"
    }
}

// MARK: - Mini row

/// A condensed download row for the overlay: cover, title, thin bar, action.
private struct MiniDownloadRow: View {
    let item: DownloadItem
    var onCancel: () -> Void
    var onRetry: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            SongCoverView(song: item.song, size: 34, cornerRadius: 7, accent: item.player.accent)

            VStack(alignment: .leading, spacing: 4) {
                Text(item.song.title)
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .foregroundStyle(NeonMicDesign.paper)
                    .lineLimit(1)
                NeonProgressBar(
                    fraction: item.fractionCompleted,
                    accent: item.player.accent,
                    indeterminate: item.state == .pending
                )
                .frame(height: 4)
            }

            action
        }
    }

    @ViewBuilder
    private var action: some View {
        switch item.state {
        case .pending, .downloading:
            CircleIconButton(system: "xmark", accent: item.player.accent, action: onCancel)
        default:
            CircleIconButton(system: "arrow.clockwise", accent: NeonMicDesign.signalYellow, action: onRetry)
        }
    }
}

#Preview("Overlay") {
    ZStack {
        NeonMicDesign.ink.ignoresSafeArea()
    }
    .frame(width: 700, height: 500)
    .overlay(alignment: .bottomTrailing) {
        DownloadOverlayView()
            .environment(DownloadCenter.previewFilled())
            .padding(20)
    }
}
