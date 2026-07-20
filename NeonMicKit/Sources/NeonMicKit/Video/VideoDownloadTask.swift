import Foundation

/// A point-in-time view of one queued download, vended by
/// ``VideoDownloaderService/task(for:)``.
///
/// `progress` and `updates` are live objects shared with the service:
/// `progress` keeps counting after the snapshot was taken, and `updates` is a
/// single-consumer stream — attach exactly one `for await` loop per download.
/// `state` is frozen at snapshot time; re-query the service for the latest.
public struct VideoDownloadTask {
    /// The queue key, normally `"Artist - Title"` (see ``Song/librarySongName``).
    public let songName: String
    /// The remote URL being fetched.
    public let source: URL
    /// Live Foundation progress (unit count 100), suitable for `ProgressView`.
    public let progress: Progress
    /// The underlying URLSession task for direct downloads; nil while queued
    /// and for yt-dlp downloads, which run as a subprocess.
    public let urlSessionTask: URLSessionTask?
    /// The download state when this snapshot was taken.
    public let state: VideoDownloadState
    /// Progress updates for the whole job (fetch + optional audio
    /// extraction). Finishes after a terminal state is emitted.
    public let updates: AsyncStream<DownloadProgress>
}
