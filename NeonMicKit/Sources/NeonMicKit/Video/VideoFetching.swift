import Foundation

/// Callbacks a ``VideoFetching`` implementation uses to report back to
/// ``VideoDownloaderService`` while a fetch runs.
public struct VideoFetchReporter {
    /// Called (from any thread) with fetch-local progress: `fractionCompleted`
    /// is the fetch's own 0…1, the service rescales it into the overall job.
    public let onProgress: (DownloadProgress) -> Void
    /// Called once if the transport is URLSession-backed, so the service can
    /// expose the task via ``VideoDownloadTask/urlSessionTask``.
    public let onURLSessionTask: (URLSessionTask) -> Void

    /// Creates a reporter; both callbacks default to no-ops.
    public init(
        onProgress: @escaping (DownloadProgress) -> Void = { _ in },
        onURLSessionTask: @escaping (URLSessionTask) -> Void = { _ in }
    ) {
        self.onProgress = onProgress
        self.onURLSessionTask = onURLSessionTask
    }
}

/// A transport that materializes a remote video as a local file.
///
/// Two implementations ship with the Kit: ``URLSessionVideoFetcher`` for
/// direct media URLs and ``YtDlpVideoFetcher`` for page URLs (YouTube and
/// friends). ``VideoDownloaderService`` picks between them per URL; tests
/// inject mocks. Cancellation is structured: implementations must observe
/// task cancellation and throw `CancellationError`.
public protocol VideoFetching: Sendable {
    /// Downloads `source` into `folder` as `<baseName>.<ext>` and returns the
    /// resulting file URL.
    func fetchVideo(
        from source: URL,
        into folder: URL,
        baseName: String,
        reporter: VideoFetchReporter
    ) async throws -> URL
}
