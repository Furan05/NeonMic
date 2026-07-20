import Foundation

/// Background-video conveniences for library songs.
///
/// All of these need ``Song/libraryFolderURL``, which only ``LibraryScanner``
/// sets — for a chart parsed in isolation they report "no video" and
/// ``Song/downloadVideo(using:)`` throws.
extension Song {

    /// Video containers the game plays, in preference order (MP4 first).
    public static let supportedVideoExtensions = ["mp4", "mov"]

    /// The queue key used with ``VideoDownloaderService``: `"Artist - Title"`.
    public var librarySongName: String {
        "\(artist) - \(title)"
    }

    /// The chart's `#VIDEO` header refers to a *local file* only when it has
    /// a media extension; usdb-syncer charts instead store a resource tag
    /// like `v=dQw4w9WgXcQ` there, which is a download hint, not a file.
    private var videoHeaderFileName: String? {
        guard let videoFileName,
              Self.supportedVideoExtensions.contains(
                (videoFileName as NSString).pathExtension.lowercased())
        else { return nil }
        return videoFileName
    }

    /// The local background video, if the chart names one inside the song's
    /// library folder. Existence on disk is not checked — see ``hasVideo``.
    public var videoPath: URL? {
        guard let libraryFolderURL, let videoHeaderFileName else { return nil }
        return libraryFolderURL.appendingPathComponent(videoHeaderFileName)
    }

    /// Whether a background video actually exists on disk for this song.
    public var hasVideo: Bool {
        guard let videoPath else { return false }
        return FileManager.default.fileExists(atPath: videoPath.path)
    }

    /// Whether ``VideoDownloaderService/shared`` is currently fetching this
    /// song's video.
    public var isVideoDownloading: Bool {
        VideoDownloaderService.shared.isDownloading(songName: librarySongName)
    }

    /// Where this song's video can be downloaded from, resolved from chart
    /// headers: an explicit `#VIDEOURL`, or a usdb-syncer `v=<id>` tag in
    /// `#VIDEO` (translated to a YouTube watch URL). Nil when the chart
    /// carries no source.
    public var videoSourceURL: URL? {
        if let raw = rawHeaders["VIDEOURL"], let url = URL(string: raw), url.scheme != nil {
            return url
        }
        guard let videoFileName, videoHeaderFileName == nil else { return nil }
        // Tag format: comma-separated k=v pairs ("v=dQw4w9WgXcQ,co=cover.jpg").
        for pair in videoFileName.split(separator: ",") {
            let parts = pair.split(separator: "=", maxSplits: 1)
            if parts.count == 2, parts[0].trimmingCharacters(in: .whitespaces) == "v" {
                return URL(string: "https://www.youtube.com/watch?v=\(parts[1])")
            }
        }
        return nil
    }

    /// Downloads this song's background video into its library folder and
    /// returns the written paths. Audio is additionally extracted only when
    /// the chart names no `#AUDIO` file, so an owned track is never shadowed.
    ///
    /// - Throws: ``VideoDownloadError/noVideoSource`` when the chart has no
    ///   `#VIDEOURL`/usdb tag, ``VideoDownloadError/noLibraryFolder`` when
    ///   the song was parsed outside a library scan.
    @discardableResult
    public func downloadVideo(
        using service: VideoDownloaderService = .shared
    ) async throws -> VideoPaths {
        guard let source = videoSourceURL else { throw VideoDownloadError.noVideoSource }
        guard let libraryFolderURL else { throw VideoDownloadError.noLibraryFolder }
        return try await service.downloadVideo(
            from: source.absoluteString,
            songName: librarySongName,
            into: libraryFolderURL,
            extractingAudio: audioFileName == nil
        )
    }
}
