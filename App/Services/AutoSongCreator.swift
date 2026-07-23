import SwiftUI
import Observation
import NeonMicKit

/// Drives the "create a song from a YouTube URL" flow: analyze → preview →
/// (optionally nudge timing) → commit into the library.
///
/// A thin, observable wrapper over the Kit's ``AutoSongBuilder``. Analysis
/// hits the network (yt-dlp metadata + lyrics lookup); commit writes the chart
/// and downloads the clip. All acquired content is third-party and lands only
/// in the user's library — see the copyright notice in ``AutoSongCreatorView``.
@MainActor
@Observable
final class AutoSongCreator {

    /// Where the flow currently stands.
    enum Phase: Equatable {
        case idle
        case analyzing
        case ready
        case committing
        case done
        case failed(String)
    }

    /// The pasted video URL.
    var urlText = ""
    /// Manual metadata corrections (prefilled from detection once analyzed).
    var titleOverride = ""
    var artistOverride = ""
    /// Manual timing nudge applied to the generated chart's `#GAP`.
    var gapOffsetMs: Double = 0

    private(set) var phase: Phase = .idle
    private(set) var plan: AutoSongPlan?
    /// Clip-download progress during commit, `0...1`.
    private(set) var commitFraction: Double = 0

    private let builder: AutoSongBuilder
    private let banners: BannerCenter
    private let service: VideoDownloaderService

    init(
        builder: AutoSongBuilder = AutoSongBuilder(),
        banners: BannerCenter = .shared,
        service: VideoDownloaderService = .shared
    ) {
        self.builder = builder
        self.banners = banners
        self.service = service
    }

    /// The `#GAP` that would be written, including the manual nudge.
    var adjustedGapMs: Double { (plan?.gapMs ?? 0) + gapOffsetMs }

    var isBusy: Bool { phase == .analyzing || phase == .committing }

    // MARK: Analyze

    /// Extracts metadata, finds lyrics, and generates the chart preview.
    func analyze() async {
        let trimmed = urlText.trimmingCharacters(in: .whitespaces)
        guard let url = URL(string: trimmed), url.scheme != nil else {
            phase = .failed("Colle une URL de vidéo valide.")
            return
        }
        phase = .analyzing
        do {
            let built = try await builder.buildPlan(
                from: url,
                titleOverride: titleOverride.isEmpty ? nil : titleOverride,
                artistOverride: artistOverride.isEmpty ? nil : artistOverride)
            plan = built
            gapOffsetMs = 0
            if titleOverride.isEmpty { titleOverride = built.metadata.title }
            if artistOverride.isEmpty { artistOverride = built.metadata.artist }
            phase = .ready
        } catch {
            phase = .failed(Self.message(for: error))
        }
    }

    // MARK: Commit

    /// Writes the chart and downloads the clip into `library`'s root, then
    /// rescans so the new song appears in the Songbook.
    func commit(into library: LibraryService) async {
        guard let root = library.rootURL else {
            banners.show(AppBanner(
                style: .warning, title: "Bibliothèque requise",
                message: "Choisis d'abord un dossier de bibliothèque.", autoDismiss: 5))
            return
        }
        guard let base = plan else { return }
        let toCommit = gapOffsetMs == 0 ? base : builder.plan(base, applyingGapDeltaMs: gapOffsetMs)

        phase = .committing
        commitFraction = 0
        let observer = observeProgress(songName: toCommit.songName)
        do {
            _ = try await builder.commit(toCommit, into: root)
            observer.cancel()
            commitFraction = 1
            phase = .done
            banners.show(.success(
                title: "Chanson créée 🎤",
                message: "« \(toCommit.metadata.title) » a rejoint ta bibliothèque."))
            library.scan()
        } catch {
            observer.cancel()
            let message = Self.message(for: error)
            phase = .failed(message)
            banners.show(AppBanner(
                style: .error, title: "Création impossible", message: message, autoDismiss: 6))
        }
    }

    /// Resets the flow for a new song.
    func reset() {
        urlText = ""
        titleOverride = ""
        artistOverride = ""
        gapOffsetMs = 0
        plan = nil
        commitFraction = 0
        phase = .idle
    }

    // MARK: Internals

    /// Mirrors the clip download's progress into `commitFraction`.
    private func observeProgress(songName: String) -> Task<Void, Never> {
        Task { [weak self] in
            for _ in 0..<600 {
                if Task.isCancelled { return }
                if let updates = self?.service.task(for: songName)?.updates {
                    for await progress in updates { self?.commitFraction = progress.fractionCompleted }
                    return
                }
                await Task.yield()
            }
        }
    }

    /// Friendly French for the errors this flow can hit.
    static func message(for error: Error) -> String {
        if let error = error as? LyricsError {
            switch error {
            case .notFound: return "Aucune parole trouvée pour ce titre. Corrige l'artiste/titre et réessaie."
            case .ytDlpNotFound: return "yt-dlp est requis. Installe-le puis relance NEON MIC : \(YtDlpWrapper.installCommand)."
            case .metadataUnavailable(let detail): return "Métadonnées indisponibles : \(detail)"
            case .invalidURL(let raw): return "URL invalide : \(raw)"
            case .badResponse(let status): return "Le service de paroles a répondu \(status)."
            case .malformedResponse: return "Réponse illisible d'une source de paroles."
            case .emptyLyrics: return "Les paroles trouvées n'ont aucun timing exploitable."
            }
        }
        if let error = error as? VideoDownloadError {
            return VideoDownloadErrorHandler.shared.presentation(for: error).message
        }
        return String(describing: error)
    }
}
