import SwiftUI
import AppKit
import Observation
import NeonMicKit

/// A contextual notification shown in the top banner: a success toast, an
/// informational nudge, or an error with a quick corrective action.
///
/// Errors carry their ``ErrorRecord`` (so the banner can open the detail
/// sheet) and an `onRetry` closure (the download is retried in place).
struct AppBanner: Identifiable {
    let id = UUID()
    var style: Style
    var title: String
    var message: String
    /// The single quick action shown on the banner, if any.
    var primaryAction: ErrorActionKind?
    /// Re-runs the download this banner is about (retry actions call it).
    var onRetry: (() -> Void)?
    /// The logged error, when this banner reports one — enables "Détails".
    var record: ErrorRecord?
    /// Seconds before auto-dismiss; nil keeps it until the player acts.
    var autoDismiss: TimeInterval?

    /// The banner's visual register.
    enum Style {
        case success
        case info
        case warning
        case error

        /// The token this style paints with.
        var accent: Color {
            switch self {
            case .success: NeonMicDesign.electricCyan
            case .info: NeonMicDesign.ultraViolet
            case .warning: NeonMicDesign.signalYellow
            case .error: NeonMicDesign.neonPink
            }
        }

        var systemImage: String {
            switch self {
            case .success: "checkmark.circle.fill"
            case .info: "info.circle.fill"
            case .warning: "exclamationmark.triangle.fill"
            case .error: "xmark.octagon.fill"
            }
        }
    }

    /// A success toast (auto-dismisses quickly by default).
    static func success(title: String, message: String, autoDismiss: TimeInterval? = 3.5) -> AppBanner {
        AppBanner(style: .success, title: title, message: message, autoDismiss: autoDismiss)
    }

    /// An informational nudge.
    static func info(title: String, message: String, autoDismiss: TimeInterval? = 4) -> AppBanner {
        AppBanner(style: .info, title: title, message: message, autoDismiss: autoDismiss)
    }
}

/// The app's single top-banner presenter: one contextual notification at a
/// time, with configurable auto-dismiss.
///
/// Non-intrusive by contract — it shows one slim banner and never blocks the
/// screen. Success/info toasts fade on their own; error banners stay until the
/// player dismisses or resolves them.
@MainActor
@Observable
final class BannerCenter {

    /// The shared presenter, injected at the app root.
    static let shared = BannerCenter()

    /// The banner currently on screen, or nil.
    private(set) var current: AppBanner?

    @ObservationIgnored private var dismissTask: Task<Void, Never>?

    /// Shows `banner`, replacing whatever is on screen, and arms its
    /// auto-dismiss timer when it has one.
    func show(_ banner: AppBanner) {
        dismissTask?.cancel()
        current = banner
        guard let delay = banner.autoDismiss else { dismissTask = nil; return }
        dismissTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            self?.dismiss(banner.id)
        }
    }

    /// Dismisses the banner. When `id` is given, only dismisses if it is still
    /// the one showing (so a stale timer can't close a newer banner).
    func dismiss(_ id: UUID? = nil) {
        if let id, current?.id != id { return }
        dismissTask?.cancel()
        dismissTask = nil
        current = nil
    }

    /// Convenience for the common success toast.
    func success(_ title: String, _ message: String) {
        show(.success(title: title, message: message))
    }
}

// MARK: - Action side effects

/// Context an ``ErrorActionKind`` needs to run: which error, how to retry, and
/// which banner (if any) triggered it.
struct ErrorActionContext {
    var record: ErrorRecord?
    var onRetry: (() -> Void)?
    var bannerID: UUID?
}

/// Performs the system-level side effects behind an ``ErrorActionKind``
/// (retry, open settings, copy commands/logs, compose support mail).
enum ErrorActionRunner {

    /// The address a "Contacter le support" mail is composed to.
    static let supportAddress = "francois.dubois1994@gmail.com"

    @MainActor
    static func perform(
        _ kind: ErrorActionKind,
        context: ErrorActionContext,
        banners: BannerCenter,
        errors: VideoDownloadErrorHandler
    ) {
        switch kind {
        case .retry:
            if let songName = context.record?.songName {
                errors.markRetried(songName: songName)
            }
            context.onRetry?()
            banners.dismiss(context.bannerID)

        case .checkConnection:
            open("x-apple.systempreferences:com.apple.Network-Settings.extension")

        case .freeSpace:
            open("x-apple.systempreferences:com.apple.settings.Storage")

        case .installYtDlp:
            copy(YtDlpWrapper.installCommand)
            banners.success("Commande copiée",
                            "Colle-la dans le Terminal : \(YtDlpWrapper.installCommand), puis relance l'app.")

        case .installFfmpeg:
            copy("brew install ffmpeg")
            banners.success("Commande copiée", "Colle-la dans le Terminal : brew install ffmpeg")

        case .copyLogs:
            guard let report = context.record?.technicalReport else { return }
            copy(report)
            banners.success("Logs copiés", "Le rapport technique est dans le presse-papiers.")

        case .contactSupport:
            composeSupport(record: context.record)

        case .dismiss:
            if let id = context.record?.id { errors.markDismissed(id) }
            banners.dismiss(context.bannerID)
        }
    }

    // MARK: Helpers

    private static func open(_ urlString: String) {
        guard let url = URL(string: urlString) else { return }
        NSWorkspace.shared.open(url)
    }

    private static func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    private static func composeSupport(record: ErrorRecord?) {
        var components = URLComponents()
        components.scheme = "mailto"
        components.path = supportAddress
        components.queryItems = [
            URLQueryItem(name: "subject", value: "NEON MIC — souci de téléchargement"),
            URLQueryItem(name: "body", value: record?.technicalReport ?? "Décris ton problème ici."),
        ]
        guard let url = components.url else { return }
        NSWorkspace.shared.open(url)
    }
}
