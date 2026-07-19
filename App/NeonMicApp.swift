import SwiftUI

@main
struct NeonMicApp: App {
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
    }
}
