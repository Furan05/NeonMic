import SwiftUI
import Observation
import NeonMicKit

/// A corrective action a user can take in response to a download error.
///
/// The kind is a semantic tag with display metadata; performing it lives in
/// ``ErrorActionRunner`` (system integrations) or the owning view (retry).
enum ErrorActionKind: Identifiable, Hashable {
    /// Re-run the failed download.
    case retry
    /// Open macOS network settings.
    case checkConnection
    /// Open the storage screen to free space.
    case freeSpace
    /// Copy the `brew install yt-dlp` command.
    case installYtDlp
    /// Copy the `brew install ffmpeg` command.
    case installFfmpeg
    /// Copy the technical report for debugging.
    case copyLogs
    /// Compose a pre-filled support email.
    case contactSupport
    /// Dismiss the current banner.
    case dismiss

    var id: Self { self }

    /// The button label, in NEON MIC's friendly-but-precise French.
    var label: String {
        switch self {
        case .retry: "Réessayer"
        case .checkConnection: "Vérifier la connexion"
        case .freeSpace: "Libérer de l'espace"
        case .installYtDlp: "Copier la commande"
        case .installFfmpeg: "Copier la commande"
        case .copyLogs: "Copier les logs"
        case .contactSupport: "Contacter le support"
        case .dismiss: "OK"
        }
    }

    var systemImage: String {
        switch self {
        case .retry: "arrow.clockwise"
        case .checkConnection: "wifi"
        case .freeSpace: "internaldrive"
        case .installYtDlp, .installFfmpeg: "terminal"
        case .copyLogs: "doc.on.doc"
        case .contactSupport: "envelope"
        case .dismiss: "checkmark"
        }
    }
}

/// A friendly, presentation-ready view of a download error: what to say, how
/// loud to say it, and what the player can do about it.
struct ErrorPresentation: Equatable {
    /// How prominently the UI should surface this.
    enum Severity: Equatable {
        /// Not really a failure — a nudge (no source, config).
        case info
        /// Recoverable; the player can usually fix it. Drawn in signalYellow.
        case warning
        /// A hard failure. Drawn in neonPink.
        case error

        /// The token this severity paints with.
        var accent: Color {
            switch self {
            case .info: NeonMicDesign.ultraViolet
            case .warning: NeonMicDesign.signalYellow
            case .error: NeonMicDesign.neonPink
            }
        }

        var systemImage: String {
            switch self {
            case .info: "info.circle.fill"
            case .warning: "exclamationmark.triangle.fill"
            case .error: "xmark.octagon.fill"
            }
        }
    }

    /// A short, human headline (also used as the row's compact failure text).
    var title: String
    /// The friendly explanation shown to the player.
    var message: String
    var severity: Severity
    /// A plain-language "what actually happened", shown in the detail sheet.
    var explanation: String
    /// Corrective actions offered, most useful first.
    var actions: [ErrorActionKind]
    /// Whether re-running the download makes sense.
    var isRetryable: Bool
}

/// One entry in the recent-errors log, with how it was ultimately resolved.
struct ErrorRecord: Identifiable, Equatable {
    let id: UUID
    /// The song the error belongs to (`"Artist - Title"`), if any.
    let songName: String?
    /// The classified error.
    let error: VideoDownloadError
    /// Its friendly presentation, computed once at record time.
    let presentation: ErrorPresentation
    /// How the error was resolved (updated as events unfold).
    var resolution: Resolution

    /// The lifecycle of an error after it is first shown.
    enum Resolution: String {
        case unresolved
        case retried
        case dismissed
        case succeeded

        var label: String {
            switch self {
            case .unresolved: "non résolue"
            case .retried: "réessayée"
            case .dismissed: "ignorée"
            case .succeeded: "résolue ✓"
            }
        }
    }

    /// A copy-pasteable technical report for support / debugging.
    var technicalReport: String {
        var lines = ["NEON MIC — rapport d'erreur"]
        if let songName { lines.append("Chanson : \(songName)") }
        lines.append("Type : \(String(reflecting: error))")
        lines.append("Explication : \(presentation.explanation)")
        lines.append("Résolution : \(resolution.label)")
        return lines.joined(separator: "\n")
    }
}

/// Turns technical ``VideoDownloadError`` values into friendly, actionable
/// presentations, and keeps a short log of recent errors and how they were
/// resolved.
///
/// The tone follows NEON MIC's "karaoke box host": warm and encouraging, but
/// precise about what went wrong and what to try next.
@MainActor
@Observable
final class VideoDownloadErrorHandler {

    /// The shared handler, injected at the app root.
    static let shared = VideoDownloadErrorHandler()

    /// Recent errors, newest first, capped so the log never grows unbounded.
    private(set) var recent: [ErrorRecord] = []

    /// How many records to keep.
    private let historyLimit = 20

    // MARK: History

    /// Logs `error` for `songName` and returns the created record.
    @discardableResult
    func record(_ error: VideoDownloadError, songName: String?) -> ErrorRecord {
        let record = ErrorRecord(
            id: UUID(),
            songName: songName,
            error: error,
            presentation: presentation(for: error),
            resolution: .unresolved
        )
        recent.insert(record, at: 0)
        if recent.count > historyLimit {
            recent.removeLast(recent.count - historyLimit)
        }
        return record
    }

    /// Marks the newest unresolved record for `songName` as retried.
    func markRetried(songName: String) {
        updateLatest(songName: songName, to: .retried)
    }

    /// Marks the newest unresolved record for `songName` as manually dismissed.
    func markDismissed(_ id: UUID) {
        guard let index = recent.firstIndex(where: { $0.id == id }),
              recent[index].resolution == .unresolved else { return }
        recent[index].resolution = .dismissed
    }

    /// A later successful download for `songName` retroactively resolves any
    /// open errors it had.
    func noteSuccess(songName: String) {
        for index in recent.indices where recent[index].songName == songName
            && recent[index].resolution != .dismissed {
            recent[index].resolution = .succeeded
        }
    }

    /// Clears the entire recent-errors log.
    func clearHistory() {
        recent.removeAll()
    }

    private func updateLatest(songName: String, to resolution: ErrorRecord.Resolution) {
        guard let index = recent.firstIndex(where: {
            $0.songName == songName && $0.resolution == .unresolved
        }) else { return }
        recent[index].resolution = resolution
    }

    // MARK: Compact text

    /// The one-liner shown inline on a failed download row.
    func shortMessage(for error: VideoDownloadError) -> String {
        presentation(for: error).title
    }

    // MARK: Banner

    /// Builds the top-banner notification for a logged error.
    ///
    /// The quick action is retry when the error is retryable, otherwise the
    /// first corrective action (or none). Error banners stay until dismissed;
    /// gentler ones fade on their own.
    func banner(for record: ErrorRecord, onRetry: (() -> Void)?) -> AppBanner {
        let presentation = record.presentation
        let style: AppBanner.Style = switch presentation.severity {
        case .info: .info
        case .warning: .warning
        case .error: .error
        }
        let primary: ErrorActionKind? = presentation.isRetryable ? .retry : presentation.actions.first
        return AppBanner(
            style: style,
            title: presentation.title,
            message: presentation.message,
            primaryAction: primary,
            onRetry: onRetry,
            record: record,
            autoDismiss: presentation.severity == .error ? nil : 6
        )
    }

    // MARK: Mapping

    /// The friendly, actionable presentation for `error`.
    func presentation(for error: VideoDownloadError) -> ErrorPresentation {
        switch error {

        // Transport
        case .networkUnavailable:
            return ErrorPresentation(
                title: "Connexion perdue",
                message: "Vérifie ta connexion Internet, puis relance le téléchargement.",
                severity: .warning,
                explanation: "Impossible de joindre le serveur : ton Mac semble hors ligne ou la source est injoignable.",
                actions: [.checkConnection, .retry],
                isRetryable: true)
        case .badServerResponse(let code):
            return ErrorPresentation(
                title: "Serveur grognon",
                message: "La source a renvoyé une erreur (\(code)). Réessaie dans un instant.",
                severity: .warning,
                explanation: "Le serveur d'hébergement a répondu avec le code HTTP \(code) au lieu d'un fichier.",
                actions: [.retry],
                isRetryable: true)
        case .downloadedFileMissing:
            return ErrorPresentation(
                title: "Téléchargement incomplet",
                message: "Le clip n'est pas arrivé entier. On retente ?",
                severity: .warning,
                explanation: "Le transfert s'est terminé mais aucun fichier vidéo valide n'a été trouvé sur le disque.",
                actions: [.retry],
                isRetryable: true)
        case .downloadFailed(let message):
            return ErrorPresentation(
                title: "Téléchargement raté",
                message: "Petit couac pendant le téléchargement. Un nouvel essai devrait aider.",
                severity: .error,
                explanation: message,
                actions: [.retry, .copyLogs],
                isRetryable: true)

        // Disk
        case .insufficientStorage:
            return ErrorPresentation(
                title: "Plus de place en coulisses",
                message: "Espace insuffisant pour ce clip. Libère un peu d'espace disque, puis relance.",
                severity: .warning,
                explanation: "Le volume de destination n'a plus assez d'espace libre pour écrire la vidéo.",
                actions: [.freeSpace, .retry],
                isRetryable: true)
        case .writePermissionDenied:
            return ErrorPresentation(
                title: "Dossier verrouillé",
                message: "NEON MIC n'a pas pu écrire dans ta bibliothèque. Vérifie les permissions du dossier.",
                severity: .error,
                explanation: "L'écriture dans le dossier de la bibliothèque a été refusée par le système (permissions ou sandbox).",
                actions: [.retry, .copyLogs],
                isRetryable: true)

        // Content availability
        case .drmProtected:
            return ErrorPresentation(
                title: "Clip verrouillé",
                message: "Ce clip est protégé et ne peut pas être téléchargé.",
                severity: .error,
                explanation: "La source est protégée par DRM ; le téléchargement en est techniquement empêché.",
                actions: [],
                isRetryable: false)
        case .privateVideo:
            return ErrorPresentation(
                title: "Vidéo privée",
                message: "Ce clip est privé et n'est pas disponible.",
                severity: .error,
                explanation: "La vidéo source est marquée comme privée par son auteur.",
                actions: [],
                isRetryable: false)
        case .regionRestricted:
            return ErrorPresentation(
                title: "Bloqué dans ta région",
                message: "Ce clip n'est pas disponible dans ta région.",
                severity: .error,
                explanation: "La vidéo source est géo-restreinte et refuse l'accès depuis ton pays.",
                actions: [],
                isRetryable: false)
        case .videoUnavailable:
            return ErrorPresentation(
                title: "Clip introuvable",
                message: "Ce clip n'est plus disponible en ligne.",
                severity: .error,
                explanation: "La vidéo a été supprimée, rendue indisponible, ou n'a jamais été publique.",
                actions: [],
                isRetryable: false)

        // Tooling
        case .ytDlpNotFound:
            return ErrorPresentation(
                title: "Outil manquant",
                message: "Installe yt-dlp pour récupérer les clips : brew install yt-dlp.",
                severity: .warning,
                explanation: "Le programme yt-dlp, requis pour les sources type YouTube, est introuvable sur ce Mac.",
                actions: [.installYtDlp, .retry],
                isRetryable: true)
        case .ffmpegRequired:
            return ErrorPresentation(
                title: "ffmpeg requis",
                message: "Installe ffmpeg pour le 1080p fusionné : brew install ffmpeg.",
                severity: .warning,
                explanation: "yt-dlp a besoin de ffmpeg pour fusionner les pistes vidéo et audio en 1080p.",
                actions: [.installFfmpeg, .retry],
                isRetryable: true)
        case .ytDlpFailed(let code, let message):
            return ErrorPresentation(
                title: "Téléchargement raté",
                message: "yt-dlp a rencontré un souci. Un nouvel essai peut suffire.",
                severity: .error,
                explanation: "yt-dlp s'est arrêté (code \(code)).\n\n\(message)",
                actions: [.retry, .copyLogs],
                isRetryable: true)

        // Configuration / plumbing
        case .invalidURL(let raw):
            return ErrorPresentation(
                title: "Lien invalide",
                message: "L'adresse de la vidéo n'est pas valide.",
                severity: .error,
                explanation: "La source « \(raw) » n'est pas une URL exploitable.",
                actions: [.copyLogs],
                isRetryable: false)
        case .noVideoSource:
            return ErrorPresentation(
                title: "Pas de clip à télécharger",
                message: "Ce chart n'indique aucune vidéo à récupérer.",
                severity: .info,
                explanation: "Le chart ne contient ni #VIDEOURL ni identifiant vidéo usdb — rien à télécharger.",
                actions: [],
                isRetryable: false)
        case .noLibraryFolder:
            return ErrorPresentation(
                title: "Chanson hors bibliothèque",
                message: "Ajoute cette chanson à ta bibliothèque pour télécharger son clip.",
                severity: .info,
                explanation: "La chanson a été chargée hors d'un scan de bibliothèque : aucun dossier où écrire.",
                actions: [],
                isRetryable: false)
        case .noDestinationConfigured:
            return ErrorPresentation(
                title: "Bibliothèque non configurée",
                message: "Choisis d'abord un dossier de bibliothèque.",
                severity: .info,
                explanation: "Aucun dossier de destination n'a été défini pour les téléchargements.",
                actions: [],
                isRetryable: false)
        case .alreadyDownloading:
            return ErrorPresentation(
                title: "Déjà en cours",
                message: "Ce clip est déjà en train de se télécharger.",
                severity: .info,
                explanation: "Un téléchargement est déjà actif pour cette chanson.",
                actions: [],
                isRetryable: false)
        }
    }
}
