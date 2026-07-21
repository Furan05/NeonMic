import SwiftUI
import Observation
import NeonMicKit

/// When to allow background-clip downloads.
enum DownloadStrategy: String, CaseIterable, Identifiable {
    /// Download on any connection.
    case always
    /// Only on an unmetered (WiFi / ethernet) connection.
    case wifiOnly

    var id: String { rawValue }

    var label: String {
        switch self {
        case .always: "Toujours"
        case .wifiOnly: "WiFi uniquement"
        }
    }

    var systemImage: String {
        switch self {
        case .always: "arrow.down.circle"
        case .wifiOnly: "wifi"
        }
    }
}

/// Why a batch of downloads was started (shapes the confirmation banner).
enum DownloadReason {
    case single
    case selectionSweep
    case missingSweep
}

/// The Songbook's single entry point for background-clip downloads.
///
/// Everything the library UI does — a swipe, ⌘D, "Tout télécharger" — routes
/// here. The coordinator applies the current ``DownloadStrategy`` (WiFi gating
/// via ``NetworkMonitor``), orders batches by priority (the current song, then
/// the selection, then the rest), announces starts through ``BannerCenter``,
/// and keeps a short list of recently queued songs. The actual queue lives in
/// ``DownloadCenter``.
@MainActor
@Observable
final class VideoDownloadCoordinator {

    /// The shared coordinator, injected at the app root.
    static let shared = VideoDownloadCoordinator()

    /// The active download strategy (persisted across launches).
    var strategy: DownloadStrategy {
        didSet { UserDefaults.standard.set(strategy.rawValue, forKey: Self.strategyKey) }
    }

    /// Song names queued this session, newest first — the recent history.
    private(set) var recent: [String] = []

    /// The song currently in focus (selected / playing); it jumps the queue.
    var currentSong: Song?

    private let downloads: DownloadCenter
    private let banners: BannerCenter
    private let network: NetworkMonitor

    private static let strategyKey = "download.strategy"
    private static let recentLimit = 12

    init(
        downloads: DownloadCenter = .shared,
        banners: BannerCenter = .shared,
        network: NetworkMonitor = .shared
    ) {
        self.downloads = downloads
        self.banners = banners
        self.network = network
        let saved = UserDefaults.standard.string(forKey: Self.strategyKey)
        self.strategy = saved.flatMap(DownloadStrategy.init(rawValue:)) ?? .always
    }

    // MARK: Commands

    /// Queues one song's clip, giving it top priority.
    func download(_ song: Song) {
        guard song.videoSourceURL != nil else {
            banners.show(.info(
                title: "Pas de clip",
                message: "« \(song.title) » n'a pas de clip à télécharger."))
            return
        }
        guard passesStrategy() else { return }
        downloads.start(song)
        noteRecent(song)
        banners.show(.info(
            title: "Téléchargement lancé",
            message: "« \(song.title) » — le clip arrive 🎬"))
    }

    /// Queues every downloadable song in `songs`, skipping ones already
    /// in flight, in priority order.
    func downloadAll(_ songs: [Song], reason: DownloadReason) {
        let targets = songs.filter { song in
            song.videoSourceURL != nil && downloads.item(for: song)?.state.isActive != true
        }
        guard !targets.isEmpty else {
            banners.show(.success(
                title: "Tout est là 🎉",
                message: "Aucun clip à télécharger pour le moment."))
            return
        }
        guard passesStrategy() else { return }
        for song in orderedByPriority(targets) {
            downloads.start(song)
            noteRecent(song)
        }
        let count = targets.count
        banners.show(.info(
            title: "\(count) clip\(count > 1 ? "s" : "") en file",
            message: reason == .missingSweep
                ? "Récupération des clips manquants en arrière-plan."
                : "Téléchargement de la sélection en arrière-plan."))
    }

    /// Whether the current strategy blocks downloads right now.
    var isBlockedByStrategy: Bool {
        !network.isOnline || (strategy == .wifiOnly && !network.isUnmetered)
    }

    // MARK: Internals

    private func passesStrategy() -> Bool {
        if !network.isOnline {
            banners.show(AppBanner(
                style: .warning, title: "Hors ligne",
                message: "Connecte-toi à Internet pour récupérer les clips.", autoDismiss: 5))
            return false
        }
        if strategy == .wifiOnly && !network.isUnmetered {
            banners.show(AppBanner(
                style: .warning, title: "Connexion mesurée",
                message: "Le mode « WiFi uniquement » met les téléchargements en pause.",
                autoDismiss: 5))
            return false
        }
        return true
    }

    /// Puts the current song first; keeps the rest in their given order.
    private func orderedByPriority(_ songs: [Song]) -> [Song] {
        guard let current = currentSong?.librarySongName else { return songs }
        return songs.enumerated()
            .sorted { lhs, rhs in
                let lp = lhs.element.librarySongName == current ? 0 : 1
                let rp = rhs.element.librarySongName == current ? 0 : 1
                return lp == rp ? lhs.offset < rhs.offset : lp < rp
            }
            .map(\.element)
    }

    private func noteRecent(_ song: Song) {
        let name = song.librarySongName
        recent.removeAll { $0 == name }
        recent.insert(name, at: 0)
        if recent.count > Self.recentLimit {
            recent.removeLast(recent.count - Self.recentLimit)
        }
    }
}
