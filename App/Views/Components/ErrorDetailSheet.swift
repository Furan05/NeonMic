import SwiftUI
import NeonMicKit

/// A detailed, calm view of a complex download error.
///
/// Shown from an error banner's "Détails". It restates the friendly message,
/// explains in plain language what actually happened, exposes the raw
/// technical report (selectable and copyable for debugging), and offers the
/// corrective actions plus "copier les logs" and "contacter le support".
struct ErrorDetailSheet: View {
    let record: ErrorRecord
    /// Re-runs the download this error is about.
    var onRetry: (() -> Void)?

    @Environment(BannerCenter.self) private var banners
    @Environment(VideoDownloadErrorHandler.self) private var errors
    @Environment(\.dismiss) private var dismiss

    private var presentation: ErrorPresentation { record.presentation }
    private var accent: Color { presentation.severity.accent }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            header
            Text(presentation.message)
                .font(.system(size: 14, weight: .medium, design: .rounded))
                .foregroundStyle(NeonMicDesign.paper.opacity(0.85))
                .fixedSize(horizontal: false, vertical: true)

            section(title: "Ce qui s'est passé") {
                Text(presentation.explanation)
                    .font(.system(size: 12, weight: .regular, design: .rounded))
                    .foregroundStyle(NeonMicDesign.paper.opacity(0.7))
                    .fixedSize(horizontal: false, vertical: true)
            }

            section(title: "Détails techniques") {
                ScrollView {
                    Text(record.technicalReport)
                        .font(.system(size: 11, weight: .regular, design: .monospaced))
                        .foregroundStyle(NeonMicDesign.paper.opacity(0.65))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(10)
                }
                .frame(maxHeight: 120)
                .background(NeonMicDesign.inkDeep, in: RoundedRectangle(cornerRadius: 8))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(NeonMicDesign.paper.opacity(0.1), lineWidth: 1)
                )
            }

            actionButtons

            HStack {
                Spacer()
                Button("Fermer") { dismiss() }
                    .buttonStyle(.plain)
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .foregroundStyle(NeonMicDesign.paper.opacity(0.6))
            }
        }
        .padding(24)
        .frame(width: 460)
        .background(NeonMicDesign.ink)
    }

    // MARK: Pieces

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: presentation.severity.systemImage)
                .font(.system(size: 26, weight: .bold))
                .foregroundStyle(accent)
                .neonGlow(accent, radius: 8)
            VStack(alignment: .leading, spacing: 2) {
                Text(presentation.title)
                    .font(.system(size: 20, weight: .heavy, design: .rounded))
                    .foregroundStyle(NeonMicDesign.paper)
                if let songName = record.songName {
                    Text(songName)
                        .font(.system(size: 12, weight: .medium, design: .monospaced))
                        .foregroundStyle(NeonMicDesign.paper.opacity(0.45))
                }
            }
        }
    }

    private func section(title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title.uppercased())
                .font(.system(size: 10, weight: .heavy, design: .monospaced))
                .foregroundStyle(accent.opacity(0.8))
            content()
        }
    }

    private var actionButtons: some View {
        FlowButtons(actions: sheetActions) { kind in
            ErrorActionRunner.perform(
                kind,
                context: ErrorActionContext(record: record, onRetry: onRetry, bannerID: nil),
                banners: banners,
                errors: errors
            )
            if kind == .retry { dismiss() }
        }
    }

    /// Retry first (when it makes sense), then the specific corrective
    /// actions, always ending with copy-logs and contact-support.
    private var sheetActions: [ErrorActionKind] {
        var actions: [ErrorActionKind] = []
        if presentation.isRetryable { actions.append(.retry) }
        for action in presentation.actions where !actions.contains(action) {
            actions.append(action)
        }
        for action in [ErrorActionKind.copyLogs, .contactSupport] where !actions.contains(action) {
            actions.append(action)
        }
        return actions
    }
}

/// A wrapping row of neon action buttons for the detail sheet.
private struct FlowButtons: View {
    let actions: [ErrorActionKind]
    let perform: (ErrorActionKind) -> Void

    var body: some View {
        // Two columns keep the sheet tidy regardless of action count.
        let columns = [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)]
        LazyVGrid(columns: columns, spacing: 10) {
            ForEach(actions) { action in
                Button {
                    perform(action)
                } label: {
                    Label(action.label, systemImage: action.systemImage)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(NeonButtonStyle(accent: accent(for: action)))
                .controlSize(.small)
            }
        }
    }

    private func accent(for action: ErrorActionKind) -> Color {
        switch action {
        case .retry: NeonMicDesign.signalYellow
        case .copyLogs, .contactSupport: NeonMicDesign.ultraViolet
        case .dismiss: NeonMicDesign.paper
        default: NeonMicDesign.electricCyan
        }
    }
}

#Preview("Error detail") {
    let error = VideoDownloadError.ytDlpFailed(exitCode: 1, message: "ERROR: unable to download video data: HTTP Error 403: Forbidden")
    let handler = VideoDownloadErrorHandler()
    let record = handler.record(error, songName: "The Midnights - Neon Skyline")
    return ErrorDetailSheet(record: record, onRetry: {})
        .environment(BannerCenter())
        .environment(handler)
}
