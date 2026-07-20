import Foundation

/// Errors thrown by ``VideoDownloaderService`` and ``Song/downloadVideo(using:)``.
public enum VideoDownloadError: Error, Equatable {
    /// The string passed to `downloadVideo(from:songName:)` is not a URL.
    case invalidURL(String)
    /// A download for the same song name is already pending or running.
    case alreadyDownloading(songName: String)
    /// `downloadVideo(from:songName:)` was called before the service knew
    /// where to write (`destinationRootURL` unset and no explicit folder).
    case noDestinationConfigured
    /// The song has no `#VIDEOURL` header and no usdb-style `v=` tag to
    /// download from.
    case noVideoSource
    /// The song was parsed outside a library scan, so it has no folder to
    /// download into (``Song/libraryFolderURL`` is nil).
    case noLibraryFolder
    /// No yt-dlp executable was found — see ``YtDlpVideoFetcher/locateExecutable(searchPaths:fileManager:)``.
    case ytDlpNotFound
    /// yt-dlp exited non-zero; `message` carries its last stderr output.
    case ytDlpFailed(exitCode: Int32, message: String)
    /// A direct HTTP download answered outside 200…299.
    case badServerResponse(statusCode: Int)
    /// The transport reported success but no video file exists on disk.
    case downloadedFileMissing
}
