import SwiftUI
import NeonMicKit

/// A slim, non-intrusive notification banner pinned to the top of the screen.
///
/// One line of headline plus a friendly detail, tinted by the banner's style
/// (signalYellow for warnings, neonPink for errors, electricCyan for success),
/// with an optional quick action, a "Détails" link for logged errors, and a
/// close button. Auto-dismiss is driven by ``BannerCenter``; this view is pure
/// presentation.
struct ErrorBannerView: View {
    let banner: AppBanner
    /// Runs the banner's quick action (retry, install…, etc.).
    var onAction: (ErrorActionKind) -> Void = { _ in }
    /// Opens the detailed error sheet.
    var onDetails: () -> Void = {}
    /// Dismisses the banner.
    var onClose: () -> Void = {}

    private var accent: Color { banner.style.accent }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: banner.style.systemImage)
                .font(.system(size: 18, weight: .bold))
                .foregroundStyle(accent)
                .neonGlow(accent, radius: 5)
                .padding(.top, 1)

            VStack(alignment: .leading, spacing: 3) {
                Text(banner.title)
                    .font(.system(size: 14, weight: .heavy, design: .rounded))
                    .foregroundStyle(NeonMicDesign.paper)
                Text(banner.message)
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .foregroundStyle(NeonMicDesign.paper.opacity(0.72))
                    .fixedSize(horizontal: false, vertical: true)

                if banner.primaryAction != nil || banner.record != nil {
                    HStack(spacing: 10) {
                        if let action = banner.primaryAction {
                            BannerActionButton(
                                label: action.label,
                                systemImage: action.systemImage,
                                accent: accent
                            ) { onAction(action) }
                        }
                        if banner.record != nil {
                            Button(action: onDetails) {
                                Text("Détails")
                                    .font(.system(size: 12, weight: .bold, design: .rounded))
                                    .foregroundStyle(NeonMicDesign.paper.opacity(0.7))
                                    .underline()
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.top, 4)
                }
            }

            Spacer(minLength: 4)

            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(NeonMicDesign.paper.opacity(0.5))
                    .padding(6)
            }
            .buttonStyle(.plain)
        }
        .padding(14)
        .frame(maxWidth: 540, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(NeonMicDesign.roomGlow)
        )
        .overlay(alignment: .leading) {
            // Accent stripe down the leading edge.
            Capsule()
                .fill(accent)
                .frame(width: 3)
                .padding(.vertical, 10)
                .padding(.leading, 3)
                .neonGlow(accent, radius: 4)
        }
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .strokeBorder(accent.opacity(0.4), lineWidth: 1)
        )
        .shadow(color: NeonMicDesign.inkDeep.opacity(0.6), radius: 16, y: 8)
    }
}

/// A compact filled pill action used inside a banner.
private struct BannerActionButton: View {
    let label: String
    let systemImage: String
    let accent: Color
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: systemImage).font(.system(size: 10, weight: .bold))
                Text(label).font(.system(size: 12, weight: .bold, design: .rounded))
            }
            .foregroundStyle(hovering ? NeonMicDesign.ink : accent)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(Capsule().fill(hovering ? accent : accent.opacity(0.16)))
            .overlay(Capsule().strokeBorder(accent.opacity(0.7), lineWidth: 1))
            .neonGlow(hovering ? accent : .clear, radius: hovering ? 6 : 0)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
    }
}

// MARK: - Host

/// Hosts the single top banner and the error detail sheet.
///
/// Reads ``BannerCenter`` and ``VideoDownloadErrorHandler`` from the
/// environment, animates the current banner in from the top, routes its quick
/// actions through ``ErrorActionRunner``, and presents ``ErrorDetailSheet``
/// when the player asks for details. Overlay this at the top of the app root.
struct BannerHostView: View {
    @Environment(BannerCenter.self) private var banners
    @Environment(VideoDownloadErrorHandler.self) private var errors

    @State private var detail: DetailPresentation?

    var body: some View {
        VStack {
            if let banner = banners.current {
                ErrorBannerView(
                    banner: banner,
                    onAction: { kind in
                        ErrorActionRunner.perform(
                            kind, context: context(for: banner), banners: banners, errors: errors)
                    },
                    onDetails: {
                        detail = DetailPresentation(record: banner.record, onRetry: banner.onRetry)
                    },
                    onClose: {
                        if let id = banner.record?.id { errors.markDismissed(id) }
                        banners.dismiss(banner.id)
                    }
                )
                .id(banner.id)
                .transition(.move(edge: .top).combined(with: .opacity))
                .padding(.top, 14)
            }
            Spacer(minLength: 0)
        }
        .animation(.spring(response: 0.4, dampingFraction: 0.85), value: banners.current?.id)
        .allowsHitTesting(banners.current != nil)
        .sheet(item: $detail) { presentation in
            ErrorDetailSheet(record: presentation.record, onRetry: presentation.onRetry)
                .environment(banners)
                .environment(errors)
        }
    }

    private func context(for banner: AppBanner) -> ErrorActionContext {
        ErrorActionContext(record: banner.record, onRetry: banner.onRetry, bannerID: banner.id)
    }
}

/// Identifiable wrapper so the detail sheet can be presented for a record.
private struct DetailPresentation: Identifiable {
    let id: UUID
    let record: ErrorRecord
    let onRetry: (() -> Void)?

    init?(record: ErrorRecord?, onRetry: (() -> Void)?) {
        guard let record else { return nil }
        self.id = record.id
        self.record = record
        self.onRetry = onRetry
    }
}

#Preview("Banners") {
    VStack(spacing: 16) {
        ErrorBannerView(banner: .success(title: "Clip téléchargé avec succès",
                                         message: "« Neon Skyline » est prêt à chanter 🎤"))
        ErrorBannerView(banner: AppBanner(
            style: .warning, title: "Connexion perdue",
            message: "Vérifie ta connexion Internet, puis relance le téléchargement.",
            primaryAction: .retry, record: nil, autoDismiss: nil))
        ErrorBannerView(banner: AppBanner(
            style: .error, title: "Clip verrouillé",
            message: "Ce clip est protégé et ne peut pas être téléchargé.",
            record: nil, autoDismiss: nil))
    }
    .padding(24)
    .frame(width: 620)
    .background(NeonMicDesign.ink)
}
