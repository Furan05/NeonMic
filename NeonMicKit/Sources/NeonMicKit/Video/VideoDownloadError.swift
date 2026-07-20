import Foundation

/// Errors thrown by ``VideoDownloaderService`` and ``Song/downloadVideo(using:)``.
///
/// Cases fall into groups: configuration/plumbing (invalid URL, missing
/// source/folder), tooling (yt-dlp/ffmpeg), transport (network, server), disk
/// (space, permissions), and content availability (private/DRM/region). The
/// transports throw the most specific case they can prove; ``classify(_:)``
/// and ``fromYtDlp(exitCode:message:)`` map raw system errors and yt-dlp
/// stderr onto these semantic cases so the UI never has to parse strings.
public enum VideoDownloadError: Error, Equatable {

    // MARK: Configuration & plumbing

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

    // MARK: Tooling

    /// No yt-dlp executable was found — see ``YtDlpVideoFetcher/locateExecutable(searchPaths:fileManager:)``.
    case ytDlpNotFound
    /// yt-dlp needs `ffmpeg` on the PATH to merge the chosen 1080p streams and
    /// could not find it (`brew install ffmpeg`).
    case ffmpegRequired
    /// yt-dlp exited non-zero for a reason we could not classify further;
    /// `message` carries its last stderr output.
    case ytDlpFailed(exitCode: Int32, message: String)

    // MARK: Transport

    /// The device is offline or the host could not be reached.
    case networkUnavailable
    /// A direct HTTP download answered outside 200…299.
    case badServerResponse(statusCode: Int)
    /// The transport reported success but no video file exists on disk.
    case downloadedFileMissing
    /// A download failed for a reason without a more specific case; `message`
    /// is a already-normalized, human-readable explanation.
    case downloadFailed(message: String)

    // MARK: Disk

    /// The destination volume ran out of room while writing the clip.
    case insufficientStorage
    /// The sandbox or filesystem refused a write into the library folder.
    case writePermissionDenied

    // MARK: Content availability

    /// The video is DRM-protected and cannot be downloaded.
    case drmProtected
    /// The video is private and the account is not authorized to see it.
    case privateVideo
    /// The video is blocked in the current region.
    case regionRestricted
    /// The video no longer exists, was removed, or was never public.
    case videoUnavailable

    // MARK: - Classification

    /// Normalizes any thrown error into a ``VideoDownloadError``.
    ///
    /// Already-typed errors pass through; `URLError`s become
    /// ``networkUnavailable`` for connectivity codes; POSIX/Cocoa write errors
    /// become ``insufficientStorage`` or ``writePermissionDenied``; everything
    /// else falls back to ``downloadFailed(message:)`` carrying a readable
    /// description. Cancellations are *not* handled here — callers detect
    /// `CancellationError` before classifying.
    public static func classify(_ error: Error) -> VideoDownloadError {
        if let known = error as? VideoDownloadError { return known }

        if let urlError = error as? URLError {
            switch urlError.code {
            case .notConnectedToInternet, .networkConnectionLost, .cannotFindHost,
                 .cannotConnectToHost, .dnsLookupFailed, .timedOut, .dataNotAllowed,
                 .internationalRoamingOff, .resourceUnavailable, .secureConnectionFailed:
                return .networkUnavailable
            case .badServerResponse:
                return .downloadFailed(message: urlError.localizedDescription)
            default:
                return .downloadFailed(message: urlError.localizedDescription)
            }
        }

        let nsError = error as NSError
        switch nsError.domain {
        case NSPOSIXErrorDomain:
            switch Int32(nsError.code) {
            case ENOSPC: return .insufficientStorage
            case EACCES, EPERM, EROFS: return .writePermissionDenied
            default: break
            }
        case NSCocoaErrorDomain:
            switch nsError.code {
            case NSFileWriteOutOfSpaceError:
                return .insufficientStorage
            case NSFileWriteNoPermissionError, NSFileWriteVolumeReadOnlyError:
                return .writePermissionDenied
            default: break
            }
        case NSURLErrorDomain where nsError.code == NSURLErrorNotConnectedToInternet:
            return .networkUnavailable
        default:
            break
        }

        return .downloadFailed(message: (error as NSError).localizedDescription)
    }

    /// Maps a non-zero yt-dlp exit into the most specific case its stderr
    /// supports, falling back to ``ytDlpFailed(exitCode:message:)``.
    ///
    /// yt-dlp phrases these failures in prose, so we match on the stable
    /// substrings it prints (case-insensitively).
    public static func fromYtDlp(exitCode: Int32, message: String) -> VideoDownloadError {
        let text = message.lowercased()
        func mentions(_ needles: String...) -> Bool {
            needles.contains { text.contains($0) }
        }

        if mentions("private video", "this video is private", "sign in to confirm your age") {
            return .privateVideo
        }
        if mentions("drm", "protected content") {
            return .drmProtected
        }
        if mentions("in your country", "in your location", "geo restrict",
                    "blocked it in your country", "who has blocked it", "not available in your region") {
            return .regionRestricted
        }
        if mentions("video unavailable", "no longer available", "has been removed",
                    "this video is not available", "account associated with this video has been terminated",
                    "content isn't available") {
            return .videoUnavailable
        }
        if mentions("ffmpeg is not installed", "ffmpeg not found", "you have requested merging",
                    "requested format is not available", "install ffmpeg") {
            return .ffmpegRequired
        }
        if mentions("unable to download webpage", "temporary failure in name resolution",
                    "failed to resolve", "network is unreachable", "getaddrinfo",
                    "urlopen error", "connection refused", "connection reset", "timed out") {
            return .networkUnavailable
        }
        return .ytDlpFailed(exitCode: exitCode, message: message)
    }
}
