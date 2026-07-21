import SwiftUI
import NeonMicKit

/// A compact downloads recap for the Songbook home: aggregate progress while
/// clips are transferring, or a tidy "all caught up" line otherwise. Tapping
/// opens the full download center.
struct DownloadsSummaryView: View {
    @Environment(DownloadCenter.self) private var downloads
    var onOpen: () -> Void

    var body: some View {
        let active = downloads.activeItems
        let done = downloads.completedItems.count
        let failed = downloads.failedItems.count

        Button(action: onOpen) {
            HStack(spacing: 12) {
                leading(active: active)

                VStack(alignment: .leading, spacing: 2) {
                    Text("Téléchargements")
                        .font(.system(size: 13, weight: .bold, design: .rounded))
                        .foregroundStyle(NeonMicDesign.paper)
                    Text(subtitle(activeCount: active.count, done: done, failed: failed))
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                        .foregroundStyle(NeonMicDesign.paper.opacity(0.5))
                }

                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(NeonMicDesign.paper.opacity(0.4))
            }
            .padding(12)
            .background(
                RoundedRectangle(cornerRadius: 12).fill(NeonMicDesign.roomGlow)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(accent(active: active, failed: failed).opacity(0.3), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func leading(active: [DownloadItem]) -> some View {
        if active.isEmpty {
            Image(systemName: "tray.and.arrow.down")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(NeonMicDesign.electricCyan)
                .frame(width: 30, height: 30)
        } else {
            CircularProgressRing(
                fraction: aggregate(active),
                accent: NeonMicDesign.signalYellow,
                indeterminate: active.allSatisfy { $0.state == .pending },
                lineWidth: 3
            )
            .frame(width: 30, height: 30)
        }
    }

    private func subtitle(activeCount: Int, done: Int, failed: Int) -> String {
        if activeCount > 0 {
            var parts = ["\(activeCount) en cours"]
            if failed > 0 { parts.append("\(failed) échec\(failed > 1 ? "s" : "")") }
            return parts.joined(separator: " · ")
        }
        if failed > 0 { return "\(failed) à revoir · \(done) terminé\(done > 1 ? "s" : "")" }
        if done > 0 { return "\(done) clip\(done > 1 ? "s" : "") téléchargé\(done > 1 ? "s" : "")" }
        return "Rien en cours"
    }

    private func aggregate(_ active: [DownloadItem]) -> Double {
        guard !active.isEmpty else { return 0 }
        return active.map(\.fractionCompleted).reduce(0, +) / Double(active.count)
    }

    private func accent(active: [DownloadItem], failed: Int) -> Color {
        if !active.isEmpty { return NeonMicDesign.signalYellow }
        if failed > 0 { return NeonMicDesign.neonPink }
        return NeonMicDesign.electricCyan
    }
}
