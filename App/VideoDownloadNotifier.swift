import Foundation
import AppKit
import NeonMicKit
import UserNotifications

/// Posts a system notification when a background-video download finishes —
/// but only while NEON MIC is in the background.
///
/// In the foreground the in-app banner (see ``BannerCenter``) already tells the
/// story, so a system banner on top would be noise. Lives in the app target,
/// not the Kit: `UNUserNotificationCenter` requires a real app bundle and traps
/// in bare test processes, so the Kit only defines the `DownloadNotifying` seam.
/// Assigned to `VideoDownloaderService.shared.notifier` at launch.
final class VideoDownloadNotifier: DownloadNotifying {

    func downloadDidComplete(songName: String, paths: VideoPaths) {
        postIfBackground(title: "Clip prêt 🎬", body: "\(songName) — le clip est téléchargé.")
    }

    func downloadDidFail(songName: String, message: String) {
        postIfBackground(title: "Téléchargement échoué", body: "\(songName) : \(message)")
    }

    /// Raises a system notification only when the app is not frontmost.
    private func postIfBackground(title: String, body: String) {
        Task { @MainActor in
            guard !NSApplication.shared.isActive else { return }
            Self.post(title: title, body: body)
        }
    }

    private static func post(title: String, body: String) {
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
            guard granted else { return }
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            center.add(UNNotificationRequest(
                identifier: UUID().uuidString, content: content, trigger: nil))
        }
    }
}
