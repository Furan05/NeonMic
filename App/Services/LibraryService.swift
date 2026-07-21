import SwiftUI
import Observation
import NeonMicKit

/// One scanned library song, plus the disk facts the Songbook needs to render
/// and filter it without touching the filesystem every frame.
struct LibrarySong: Identifiable {
    /// The parsed, video-annotated song.
    var song: Song
    /// The chart the song was parsed from (also its SING source).
    let chartURL: URL
    /// Whether a playable clip currently exists on disk (cached at scan /
    /// ``LibraryService/refreshVideoStatus()`` time).
    var hasClipOnDisk: Bool

    /// Stable identity: the chart path is unique per song folder.
    var id: URL { chartURL }

    var title: String { song.title }
    var artist: String { song.artist }

    /// Whether the chart names a clip we could download.
    var hasClipSource: Bool { song.videoSourceURL != nil }
    /// A clip is "missing" when there's a source but nothing on disk yet.
    var isClipMissing: Bool { hasClipSource && !hasClipOnDisk }

    /// The backing audio file, if the chart names one inside its folder.
    var audioURL: URL? {
        guard let folder = song.libraryFolderURL, let name = song.audioFileName else { return nil }
        return folder.appendingPathComponent(name)
    }
}

/// Aggregate library counts shown in the Songbook header.
struct LibraryStats: Equatable {
    var total = 0
    var withClips = 0
    var missingClips = 0
}

/// Owns the scanned song library and the video-availability state layered on
/// top of it.
///
/// Wraps ``LibraryScanner`` (the Kit's pure disk walker) into an observable
/// list, remembers the user-picked root as a security-scoped bookmark, and
/// exposes the filters and counters the Songbook needs. Video *download* state
/// lives in ``DownloadCenter``; this service tracks only what's on disk.
@MainActor
@Observable
final class LibraryService {

    /// The shared library, injected at the app root.
    static let shared = LibraryService()

    /// Where the scan currently stands.
    enum LoadState: Equatable {
        case noLibrary
        case scanning
        case loaded
    }

    private(set) var state: LoadState = .noLibrary
    /// The scanned songs, ordered by folder name.
    private(set) var songs: [LibrarySong] = []
    /// Folders that failed to scan, surfaced for the player.
    private(set) var failures: [LibraryScanner.Failure] = []
    /// The chosen library root, if any.
    private(set) var rootURL: URL?

    private static let bookmarkKey = "library.rootBookmark"

    /// Whether we hold the root's security scope. The library root is a
    /// user-picked folder; holding its claim for as long as the library is
    /// open grants access to every child (charts, audio, covers, clips) the
    /// app reads or writes — the Songbook, playback, and downloads all rely on
    /// this instead of a per-file bookmark.
    @ObservationIgnored private var rootAccessing = false

    // MARK: Loading

    /// Restores the previously chosen library and scans it, if one was saved.
    func restore() {
        guard rootURL == nil, let url = Self.resolveBookmark() else { return }
        setRoot(url)
        scan()
    }

    /// Adopts `url` as the library root, remembers it, and scans.
    func chooseRoot(_ url: URL) {
        Self.saveBookmark(for: url)
        setRoot(url)
        scan()
    }

    /// Swaps the root, holding a balanced long-lived security-scope claim on
    /// whichever folder is current.
    private func setRoot(_ url: URL?) {
        if rootAccessing, let old = rootURL {
            old.stopAccessingSecurityScopedResource()
            rootAccessing = false
        }
        rootURL = url
        if let url {
            rootAccessing = url.startAccessingSecurityScopedResource()
        }
    }

    /// (Re)scans the library root off the main actor, then publishes results.
    func scan() {
        guard let root = rootURL else { state = .noLibrary; return }
        state = .scanning
        Task {
            let report = await Task.detached(priority: .userInitiated) {
                LibraryScanner().scan(libraryRoot: root)
            }.value
            songs = report.entries.map {
                LibrarySong(song: $0.song, chartURL: $0.chartURL, hasClipOnDisk: $0.song.hasVideo)
            }
            failures = report.failures
            state = .loaded
        }
    }

    // MARK: Video status

    /// Re-checks which songs have a clip on disk, without a full reparse.
    ///
    /// A completed download writes a new video file; this flips the affected
    /// rows' ``LibrarySong/hasClipOnDisk`` (and thus the Songbook badges) true.
    func refreshVideoStatus() {
        guard !songs.isEmpty else { return }
        let snapshot = songs
        Task {
            let updates = await Task.detached(priority: .utility) { () -> [(URL, String?, Bool)] in
                snapshot.map { entry in
                    var song = entry.song
                    if let folder = song.libraryFolderURL {
                        LibraryScanner.applyVideoDiscovery(to: &song, folderURL: folder)
                    }
                    return (entry.id, song.videoFileName, song.hasVideo)
                }
            }.value
            for (id, videoFileName, hasClip) in updates {
                guard let index = songs.firstIndex(where: { $0.id == id }) else { continue }
                songs[index].song.videoFileName = videoFileName
                songs[index].hasClipOnDisk = hasClip
            }
        }
    }

    // MARK: Filters & stats

    /// Songs whose chart offers a downloadable clip.
    var songsWithClipSource: [LibrarySong] { songs.filter(\.hasClipSource) }
    /// Songs that offer a clip but don't have it on disk yet.
    var missingClipSongs: [LibrarySong] { songs.filter(\.isClipMissing) }

    /// Library counts for the header.
    var stats: LibraryStats {
        LibraryStats(
            total: songs.count,
            withClips: songs.filter(\.hasClipOnDisk).count,
            missingClips: missingClipSongs.count
        )
    }

    /// The songs to show given the "with clips" filter and a search query.
    func filtered(onlyClips: Bool, search: String) -> [LibrarySong] {
        let query = search.trimmingCharacters(in: .whitespaces).lowercased()
        return songs.filter { entry in
            if onlyClips && !entry.hasClipSource { return false }
            guard !query.isEmpty else { return true }
            return entry.title.lowercased().contains(query)
                || entry.artist.lowercased().contains(query)
        }
    }

    /// Enqueues every missing clip through the coordinator (which applies the
    /// download strategy and priorities).
    func downloadAllMissingVideos(using coordinator: VideoDownloadCoordinator) {
        coordinator.downloadAll(missingClipSongs.map(\.song), reason: .missingSweep)
    }

    // MARK: Bookmarks

    private static func saveBookmark(for url: URL) {
        let data = (try? url.bookmarkData(
            options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil))
            ?? (try? url.bookmarkData())
        UserDefaults.standard.set(data, forKey: bookmarkKey)
    }

    private static func resolveBookmark() -> URL? {
        guard let data = UserDefaults.standard.data(forKey: bookmarkKey) else { return nil }
        var isStale = false
        return (try? URL(resolvingBookmarkData: data, options: .withSecurityScope,
                         relativeTo: nil, bookmarkDataIsStale: &isStale))
            ?? (try? URL(resolvingBookmarkData: data, relativeTo: nil, bookmarkDataIsStale: &isStale))
    }
}

#if DEBUG
extension LibraryService {
    /// A service pre-seeded with fixture songs for previews (no disk access).
    static func preview() -> LibraryService {
        let service = LibraryService()
        func song(_ title: String, _ artist: String, source: Bool, onDisk: Bool) -> LibrarySong {
            var headers: [String: String] = [:]
            if source { headers["VIDEOURL"] = "https://example.com/\(title).mp4" }
            let model = Song(title: title, artist: artist, bpm: 120,
                             coverFileName: nil, genre: "Synthpop", year: 1986,
                             rawHeaders: headers,
                             libraryFolderURL: URL(fileURLWithPath: "/tmp/\(artist) - \(title)"))
            return LibrarySong(song: model,
                               chartURL: URL(fileURLWithPath: "/tmp/\(artist) - \(title)/chart.txt"),
                               hasClipOnDisk: onDisk)
        }
        service.songs = [
            song("Neon Skyline", "The Midnights", source: true, onDisk: true),
            song("Cassette Heart", "Lumen", source: true, onDisk: false),
            song("Corridor", "Violet Static", source: true, onDisk: false),
            song("Paper Moon", "Sora", source: false, onDisk: false),
            song("After Hours", "Neon Divers", source: true, onDisk: true),
        ]
        service.state = .loaded
        return service
    }
}
#endif
