import SwiftUI
import NeonMicKit

/// The full download manager: every background-clip download this session,
/// filterable by status, each row with its own progress, cancel, and retry.
///
/// Reads the shared ``DownloadCenter`` from the environment, so it renders the
/// same live rows the overlay and detail buttons drive.
struct VideoDownloadListView: View {
    @Environment(DownloadCenter.self) private var center

    @State private var filter: DownloadFilter = .all

    var body: some View {
        VStack(spacing: 0) {
            headerBar
            filterBar
            content
        }
        .background(NeonMicDesign.ink)
    }

    // MARK: Header

    private var headerBar: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("TÉLÉCHARGEMENTS")
                    .font(.system(size: 20, weight: .heavy, design: .rounded))
                    .foregroundStyle(NeonMicDesign.paper)
                Text("clips vidéo en arrière-plan")
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundStyle(NeonMicDesign.paper.opacity(0.4))
            }
            Spacer()
            if center.items.contains(where: { !$0.state.isActive }) {
                Button("Nettoyer") { center.clearFinished() }
                    .buttonStyle(NeonButtonStyle(accent: NeonMicDesign.ultraViolet))
                    .controlSize(.small)
            }
        }
        .padding(.horizontal, 24)
        .padding(.top, 22)
        .padding(.bottom, 16)
    }

    // MARK: Filters

    private var filterBar: some View {
        HStack(spacing: 10) {
            ForEach(DownloadFilter.allCases, id: \.self) { option in
                FilterChip(
                    title: option.title,
                    count: count(for: option),
                    isSelected: filter == option,
                    accent: option.accent
                ) {
                    withAnimation(.easeOut(duration: 0.15)) { filter = option }
                }
            }
            Spacer()
        }
        .padding(.horizontal, 24)
        .padding(.bottom, 14)
    }

    // MARK: Content

    @ViewBuilder
    private var content: some View {
        let rows = filtered
        if rows.isEmpty {
            emptyState
        } else {
            ScrollView {
                LazyVStack(spacing: 12) {
                    ForEach(rows) { item in
                        VideoDownloadRowView(
                            item: item,
                            onCancel: { center.cancel(item) },
                            onRetry: { center.retry(item) },
                            onRemove: { center.remove(item) }
                        )
                        .transition(.move(edge: .top).combined(with: .opacity))
                    }
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 24)
                .animation(.easeOut(duration: 0.25), value: rows.map(\.id))
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: filter == .failed ? "checkmark.seal" : "arrow.down.circle")
                .font(.system(size: 40, weight: .light))
                .foregroundStyle(NeonMicDesign.paper.opacity(0.25))
            Text(emptyMessage)
                .font(.system(size: 13, weight: .medium, design: .rounded))
                .foregroundStyle(NeonMicDesign.paper.opacity(0.4))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(40)
    }

    private var emptyMessage: String {
        switch filter {
        case .all: "Aucun téléchargement pour l'instant."
        case .active: "Aucun téléchargement en cours."
        case .completed: "Aucun clip terminé."
        case .failed: "Aucun échec — tout roule."
        }
    }

    // MARK: Data

    private var filtered: [DownloadItem] {
        center.items.filter { filter.matches($0.state) }
    }

    private func count(for filter: DownloadFilter) -> Int {
        center.items.filter { filter.matches($0.state) }.count
    }
}

// MARK: - Filter model

/// The status buckets offered by the list's segmented filter.
enum DownloadFilter: CaseIterable {
    case all
    case active
    case completed
    case failed

    var title: String {
        switch self {
        case .all: "Tous"
        case .active: "En cours"
        case .completed: "Terminés"
        case .failed: "Échoués"
        }
    }

    var accent: Color {
        switch self {
        case .all: NeonMicDesign.paper
        case .active: NeonMicDesign.electricCyan
        case .completed: NeonMicDesign.signalYellow
        case .failed: NeonMicDesign.neonPink
        }
    }

    func matches(_ state: VideoDownloadState) -> Bool {
        switch self {
        case .all:
            return true
        case .active:
            return state.isActive
        case .completed:
            return state == .completed
        case .failed:
            if case .failed = state { return true }
            return state == .cancelled
        }
    }
}

// MARK: - Filter chip

/// A neon segmented-filter pill with a live count badge.
struct FilterChip: View {
    let title: String
    let count: Int
    let isSelected: Bool
    var accent: Color = NeonMicDesign.paper
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Text(title)
                    .font(.system(size: 12, weight: .bold, design: .rounded))
                Text("\(count)")
                    .font(.system(size: 10, weight: .heavy, design: .monospaced))
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(Capsule().fill(accent.opacity(isSelected ? 0.9 : 0.18)))
                    .foregroundStyle(isSelected ? NeonMicDesign.ink : accent)
            }
            .foregroundStyle(isSelected ? accent : NeonMicDesign.paper.opacity(0.55))
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(
                Capsule().fill(isSelected ? accent.opacity(0.14) : NeonMicDesign.roomGlow)
            )
            .overlay(
                Capsule().strokeBorder(accent.opacity(isSelected ? 0.9 : (hovering ? 0.5 : 0.2)), lineWidth: 1.2)
            )
            .neonGlow(isSelected ? accent : .clear, radius: isSelected ? 6 : 0)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
    }
}

#Preview("Download list") {
    VideoDownloadListView()
        .environment(DownloadCenter.previewFilled())
        .frame(width: 560, height: 520)
}
