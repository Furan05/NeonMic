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

/// Debug navigation until the Songbook exists: picker ↔ gameplay.
struct RootView: View {
    @State private var coordinator: GameCoordinator?
    /// The download hub, shared with the floating overlay and any detail view.
    @State private var downloads = DownloadCenter.shared
    /// Contextual top-banner notifications (success, network, disk…).
    @State private var banners = BannerCenter.shared
    /// Friendly mapping + recent-error history for download failures.
    @State private var errorHandler = VideoDownloadErrorHandler.shared

    var body: some View {
        Group {
            if let coordinator {
                GameplayView(coordinator: coordinator) {
                    self.coordinator = nil
                }
            } else {
                DebugSongPicker { chartURL, audioURL in
                    let next = try GameCoordinator(chartURL: chartURL, audioURL: audioURL)
                    try next.start()
                    coordinator = next
                }
            }
        }
        .frame(minWidth: 1024, minHeight: 640)
        .background(NeonMicDesign.ink)
        .environment(downloads)
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
    }
}
