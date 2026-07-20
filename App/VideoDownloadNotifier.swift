import Foundation
import NeonMicKit
import UserNotifications

/// Posts a system notification when a background-video download finishes.
///
/// Lives in the app target, not the Kit: `UNUserNotificationCenter` requires
/// a real app bundle and traps in bare test processes, so the Kit only
/// defines the `DownloadNotifying` seam. Assigned to
/// `VideoDownloaderService.shared.notifier` at launch.
final class VideoDownloadNotifier: DownloadNotifying {

    func downloadDidComplete(songName: String, paths: VideoPaths) {
        post(title: "Video ready", body: "\(songName) — background video downloaded.")
    }

    func downloadDidFail(songName: String, message: String) {
        post(title: "Video download failed", body: "\(songName): \(message)")
    }

    private func post(title: String, body: String) {
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
