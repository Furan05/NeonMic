import Foundation

/// Downloads background videos for library songs, one at a time.
///
/// The service keeps a serial FIFO queue: `downloadVideo` calls enqueue and
/// suspend until their turn completes, `cancelDownload(for:)` interrupts a
/// running or queued download, and per-song progress is observable three ways
/// — the returned ``VideoPaths``, the live `Progress`/`AsyncStream` on
/// ``task(for:)``, and the synchronous ``isDownloading(songName:)`` used by
/// ``Song/isVideoDownloading``.
///
/// Transports: direct media URLs (`.mp4`/`.mov`/`.m4v`, or `file://`) go
/// through ``URLSessionVideoFetcher``; every other URL (YouTube pages in
/// particular) goes through ``YtDlpVideoFetcher``. After the video lands,
/// ``AudioExtractor`` can produce a standalone AAC `.m4a` (AVFoundation has
/// no MP3 encoder — see the extractor's docs).
///
/// Sandbox: the app is sandboxed, so downloads require
/// `com.apple.security.network.client`, and the destination must be inside a
/// user-picked folder covered by `com.apple.security.files.user-selected.read-write`.
/// The service makes a balanced security-scope claim around each download's
/// writes, matching the pattern used for chart and audio reads.
///
/// Thread-safety: all members may be called from any thread; internal state
/// is lock-protected. This class never touches the gameplay sample clock —
/// downloads are pure background I/O.
public final class VideoDownloaderService: @unchecked Sendable {

    /// The app-wide instance, used by ``Song``'s video conveniences.
    public static let shared = VideoDownloaderService()

    /// One queued download's live state. A reference type so the work task,
    /// progress callbacks, and public accessors share it under `lock`.
    private final class Entry {
        let songName: String
        let source: URL
        let progress = Progress(totalUnitCount: 100)
        let updates: AsyncStream<DownloadProgress>
        let continuation: AsyncStream<DownloadProgress>.Continuation
        var state: VideoDownloadState = .pending
        var urlSessionTask: URLSessionTask?
        var work: Task<VideoPaths, Error>?

        init(songName: String, source: URL) {
            self.songName = songName
            self.source = source
            var continuation: AsyncStream<DownloadProgress>.Continuation!
            updates = AsyncStream(bufferingPolicy: .bufferingNewest(16)) { continuation = $0 }
            self.continuation = continuation
        }
    }

    private let lock = NSLock()
    private var entries: [String: Entry] = [:]
    private var queueTail: Task<Void, Never>?

    private let directFetcher: VideoFetching
    private let siteFetcher: VideoFetching
    private let audioExtractor: AudioExtracting
    private var _notifier: DownloadNotifying?
    private var _destinationRootURL: URL?

    /// Notified on completion and failure; set once at app launch.
    public var notifier: DownloadNotifying? {
        get { lock.withLock { _notifier } }
        set { lock.withLock { _notifier = newValue } }
    }

    /// Fallback destination for ``downloadVideo(from:songName:)``: each song
    /// downloads into `<root>/<songName>/`. Point this at the user-picked
    /// library root at app launch.
    public var destinationRootURL: URL? {
        get { lock.withLock { _destinationRootURL } }
        set { lock.withLock { _destinationRootURL = newValue } }
    }

    /// Creates a service. The default transports and extractor are the real
    /// ones; tests inject mocks.
    public init(
        directFetcher: VideoFetching = URLSessionVideoFetcher(),
        siteFetcher: VideoFetching = YtDlpVideoFetcher(),
        audioExtractor: AudioExtracting = AudioExtractor(),
        notifier: DownloadNotifying? = nil
    ) {
        self.directFetcher = directFetcher
        self.siteFetcher = siteFetcher
        self.audioExtractor = audioExtractor
        self._notifier = notifier
    }

    // MARK: Public API

    /// Downloads `url` into `<destinationRootURL>/<songName>/`.
    ///
    /// Convenience over ``downloadVideo(from:songName:into:extractingAudio:)``
    /// for callers without a song folder; throws
    /// ``VideoDownloadError/noDestinationConfigured`` when no root is set.
    @discardableResult
    public func downloadVideo(from url: String, songName: String) async throws -> VideoPaths {
        guard let root = destinationRootURL else { throw VideoDownloadError.noDestinationConfigured }
        let folder = root.appendingPathComponent(Self.sanitizedBaseName(from: songName), isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return try await downloadVideo(from: url, songName: songName, into: folder)
    }

    /// Enqueues a download and suspends until it finishes.
    ///
    /// - Parameters:
    ///   - url: A direct media URL or a page URL yt-dlp understands.
    ///   - songName: The queue key, normally `"Artist - Title"`. One active
    ///     download per key; a second call while active throws
    ///     ``VideoDownloadError/alreadyDownloading(songName:)``.
    ///   - folder: The song's folder; the video lands as `<songName>.mp4`.
    ///   - extractingAudio: When true (the default) also writes the video's
    ///     audio track as an AAC `.m4a` next to it.
    /// - Returns: The paths of everything written.
    @discardableResult
    public func downloadVideo(
        from url: String,
        songName: String,
        into folder: URL,
        extractingAudio: Bool = true
    ) async throws -> VideoPaths {
        guard let source = URL(string: url), source.scheme != nil else {
            throw VideoDownloadError.invalidURL(url)
        }

        let entry = Entry(songName: songName, source: source)
        let previous: Task<Void, Never>? = try lock.withLock {
            if let existing = entries[songName], existing.state.isActive {
                entry.continuation.finish()
                throw VideoDownloadError.alreadyDownloading(songName: songName)
            }
            entries[songName] = entry
            return queueTail
        }

        let work = Task<VideoPaths, Error> { [self] in
            await previous?.value
            return try await run(entry, folder: folder, extractingAudio: extractingAudio)
        }
        lock.withLock {
            entry.work = work
            queueTail = Task { _ = try? await work.value }
        }
        return try await work.value
    }

    /// Cancels the download for `songName`; a no-op when none is active.
    /// The awaiting `downloadVideo` call throws `CancellationError`, and the
    /// task's state becomes ``VideoDownloadState/cancelled``.
    public func cancelDownload(for songName: String) {
        let entry: Entry? = lock.withLock {
            guard let entry = entries[songName], entry.state.isActive else { return nil }
            // A still-queued item flips immediately; a running one flips in
            // the work task's catch, once the transport unwinds.
            if entry.state == .pending {
                entry.state = .cancelled
            }
            return entry
        }
        guard let entry else { return }
        entry.work?.cancel()
        entry.urlSessionTask?.cancel()
    }

    /// Whether a download for `songName` is pending or running.
    public func isDownloading(songName: String) -> Bool {
        lock.withLock { entries[songName]?.state.isActive ?? false }
    }

    /// A snapshot of the newest download for `songName` (including finished
    /// ones), or nil if none was ever enqueued.
    public func task(for songName: String) -> VideoDownloadTask? {
        lock.withLock {
            guard let entry = entries[songName] else { return nil }
            return VideoDownloadTask(
                songName: entry.songName,
                source: entry.source,
                progress: entry.progress,
                urlSessionTask: entry.urlSessionTask,
                state: entry.state,
                updates: entry.updates
            )
        }
    }

    /// Replaces filesystem-hostile characters so a song name can be a file
    /// base name (`"AC/DC: Live"` → `"AC-DC- Live"`).
    public static func sanitizedBaseName(from songName: String) -> String {
        let hostile = CharacterSet(charactersIn: "/:\\?%*|\"<>")
        return String(songName.map { character in
            character.unicodeScalars.contains(where: hostile.contains) ? "-" : character
        })
    }

    // MARK: Internals

    /// Runs one dequeued download end to end. Splits overall progress 0…0.85
    /// for the fetch and the rest for extraction (all of 0…1 without it).
    private func run(_ entry: Entry, folder: URL, extractingAudio: Bool) async throws -> VideoPaths {
        let fetchPortion = extractingAudio ? 0.85 : 1.0
        do {
            try Task.checkCancellation()
            update(entry) { $0.state = .downloading }
            yield(entry, DownloadProgress(phase: .fetchingVideo, fractionCompleted: 0))

            // Balanced security-scope claim around all writes of this run;
            // returns false (harmlessly) when the caller's root claim already
            // covers the folder.
            let accessing = folder.startAccessingSecurityScopedResource()
            defer { if accessing { folder.stopAccessingSecurityScopedResource() } }

            let fetcher = Self.isDirectMediaURL(entry.source) ? directFetcher : siteFetcher
            let reporter = VideoFetchReporter(
                onProgress: { [weak self, weak entry] progress in
                    guard let self, let entry else { return }
                    var scaled = progress
                    scaled.fractionCompleted *= fetchPortion
                    self.yield(entry, scaled)
                },
                onURLSessionTask: { [weak self, weak entry] task in
                    guard let self, let entry else { return }
                    self.update(entry) { $0.urlSessionTask = task }
                }
            )
            let baseName = Self.sanitizedBaseName(from: entry.songName)
            let videoURL = try await fetcher.fetchVideo(
                from: entry.source, into: folder, baseName: baseName, reporter: reporter)

            var audioURL: URL?
            if extractingAudio {
                try Task.checkCancellation()
                yield(entry, DownloadProgress(phase: .extractingAudio, fractionCompleted: fetchPortion))
                // Never clobber an existing audio file of the same name.
                var destination = folder.appendingPathComponent(baseName).appendingPathExtension("m4a")
                if FileManager.default.fileExists(atPath: destination.path) {
                    destination = folder.appendingPathComponent("\(baseName) (extracted)")
                        .appendingPathExtension("m4a")
                }
                audioURL = try await audioExtractor.extractAudio(from: videoURL, to: destination)
            }

            let paths = VideoPaths(videoURL: videoURL, extractedAudioURL: audioURL)
            update(entry) { $0.state = .completed }
            yield(entry, DownloadProgress(
                phase: extractingAudio ? .extractingAudio : .fetchingVideo,
                fractionCompleted: 1, state: .completed))
            entry.continuation.finish()
            notifier?.downloadDidComplete(songName: entry.songName, paths: paths)
            return paths
        } catch {
            let cancelled = error is CancellationError
            update(entry) { entry in
                if entry.state != .cancelled {
                    entry.state = cancelled ? .cancelled : .failed(message: String(describing: error))
                }
            }
            let state = lock.withLock { entry.state }
            yield(entry, DownloadProgress(phase: .fetchingVideo, fractionCompleted: 0, state: state))
            entry.continuation.finish()
            if !cancelled {
                notifier?.downloadDidFail(songName: entry.songName, message: String(describing: error))
            }
            throw error
        }
    }

    /// URLs URLSession can fetch as-is; everything else needs yt-dlp.
    static func isDirectMediaURL(_ url: URL) -> Bool {
        if url.isFileURL { return true }
        return ["mp4", "mov", "m4v"].contains(url.pathExtension.lowercased())
    }

    private func update(_ entry: Entry, _ mutate: (Entry) -> Void) {
        lock.withLock { mutate(entry) }
    }

    /// Publishes one snapshot to both progress surfaces (Progress + stream),
    /// stamping the current state unless the snapshot carries a terminal one.
    private func yield(_ entry: Entry, _ progress: DownloadProgress) {
        var snapshot = progress
        lock.withLock {
            if snapshot.state == .downloading {
                snapshot.state = entry.state
            }
            entry.progress.completedUnitCount = Int64((snapshot.fractionCompleted * 100).rounded())
        }
        entry.continuation.yield(snapshot)
    }
}
