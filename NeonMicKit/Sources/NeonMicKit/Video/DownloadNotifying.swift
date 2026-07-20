import Foundation

/// Receives terminal download events, typically to post system notifications.
///
/// The Kit only defines the seam: `UNUserNotificationCenter` requires a real
/// app bundle (it traps in bare test processes), so the concrete notifier
/// lives in the app target and is assigned to
/// ``VideoDownloaderService/notifier`` at launch.
public protocol DownloadNotifying: Sendable {
    /// A download (and its optional audio extraction) finished successfully.
    func downloadDidComplete(songName: String, paths: VideoPaths)
    /// A download stopped with an error (never called for cancellations).
    func downloadDidFail(songName: String, message: String)
}
