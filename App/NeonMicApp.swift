import SwiftUI
import NeonMicKit

@main
struct NeonMicApp: App {
    init() {
        VideoDownloaderService.shared.notifier = VideoDownloadNotifier()
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .preferredColorScheme(.dark)
        }
    }
}

/// Root navigation: Songbook ↔ gameplay, with the download HUD and contextual
/// banners overlaid on top of whichever screen is showing.
struct RootView: View {
    @State private var game: GameCoordinator?
    /// The scanned song library (source of the Songbook).
    @State private var library = LibraryService.shared
    /// The download hub, shared with the floating overlay and any detail view.
    @State private var downloads = DownloadCenter.shared
    /// The Songbook's download entry point (strategy, priorities, history).
    @State private var coordinator = VideoDownloadCoordinator.shared
    /// Network reachability, for the WiFi-only strategy.
    @State private var network = NetworkMonitor.shared
    /// Contextual top-banner notifications (success, network, disk…).
    @State private var banners = BannerCenter.shared
    /// Friendly mapping + recent-error history for download failures.
    @State private var errorHandler = VideoDownloadErrorHandler.shared

    var body: some View {
        Group {
            if let game {
                GameplayView(coordinator: game) {
                    self.game = nil
                }
            } else {
                SongbookView(onSing: startSinging)
            }
        }
        .frame(minWidth: 1024, minHeight: 640)
        .background(NeonMicDesign.ink)
        .environment(library)
        .environment(downloads)
        .environment(coordinator)
        .environment(network)
        .environment(banners)
        .environment(errorHandler)
        // The download HUD floats over whatever screen is showing.
        .overlay(alignment: .bottomTrailing) {
            DownloadOverlayView()
                .padding(20)
        }
        // Contextual notifications ride along the top, above every screen.
        .overlay(alignment: .top) {
            BannerHostView()
                .padding(.horizontal, 20)
        }
        .task { library.restore() }
    }

    /// Starts a run for the picked song, resolving its chart and audio.
    private func startSinging(_ entry: LibrarySong) {
        guard let audioURL = entry.audioURL else {
            banners.show(AppBanner(
                style: .warning, title: "Audio manquant",
                message: "« \(entry.title) » n'a pas de fichier audio jouable.",
                autoDismiss: 5))
            return
        }
        do {
            let next = try GameCoordinator(chartURL: entry.chartURL, audioURL: audioURL)
            try next.start()
            game = next
        } catch {
            banners.show(AppBanner(
                style: .error, title: "Lancement impossible",
                message: String(describing: error), autoDismiss: 6))
        }
    }
}
