import Foundation

/// Scans the user's song library (one `Artist - Title/` folder per song,
/// see `library/README.md`) into parsed, video-annotated ``Song`` values.
///
/// For each folder the scanner parses the first `.txt` chart, stamps
/// ``Song/libraryFolderURL``, and reconciles the chart's `#VIDEO` header with
/// what is actually on disk: an existing local video wins, otherwise the
/// folder is searched for one (`.mp4` preferred over `.mov`). Folders whose
/// chart fails to parse are reported, never fatal.
///
/// Sandbox: the library root is a user-picked folder, so `scan` makes one
/// balanced security-scope claim around the whole traversal.
public struct LibraryScanner {

    /// One successfully scanned song folder.
    public struct Entry: Sendable {
        /// The parsed song, with ``Song/libraryFolderURL`` and video fields
        /// reconciled against the folder contents.
        public var song: Song
        /// The chart that was parsed.
        public var chartURL: URL
        /// Non-fatal chart oddities, straight from the parser.
        public var warnings: [ParseWarning]
    }

    /// A folder that looked like a song but could not be scanned.
    public struct Failure: Sendable {
        /// The folder that failed.
        public var folderURL: URL
        /// Why, for display.
        public var message: String
    }

    /// Everything a scan found.
    public struct Report: Sendable {
        /// Scanned songs, ordered by folder name.
        public var entries: [Entry]
        /// Folders skipped with an error.
        public var failures: [Failure]
    }

    /// Creates a scanner.
    public init() {}

    /// Scans every song folder directly under `root`.
    ///
    /// Folders without a `.txt` chart (like the `_INBOX` drop folder while
    /// empty) are silently ignored; unparseable charts become ``Failure``s.
    public func scan(libraryRoot root: URL) -> Report {
        let accessing = root.startAccessingSecurityScopedResource()
        defer { if accessing { root.stopAccessingSecurityScopedResource() } }

        let fileManager = FileManager.default
        var entries: [Entry] = []
        var failures: [Failure] = []

        let folders = (try? fileManager.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )) ?? []

        for folder in folders.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            guard (try? folder.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true,
                  let chartURL = Self.chartURL(inFolder: folder) else { continue }
            do {
                let parsed = try UltraStarParser.parseCollectingWarnings(fileAt: chartURL)
                var song = parsed.song
                song.libraryFolderURL = folder
                Self.applyVideoDiscovery(to: &song, folderURL: folder)
                entries.append(Entry(song: song, chartURL: chartURL, warnings: parsed.warnings))
            } catch {
                failures.append(Failure(folderURL: folder, message: String(describing: error)))
            }
        }
        return Report(entries: entries, failures: failures)
    }

    /// Points `song.videoFileName` at a video that exists in `folderURL`.
    ///
    /// A `#VIDEO` header naming an existing local file is kept as-is. A
    /// missing file — or a usdb-syncer `v=` tag, which is a download hint,
    /// not a file — is replaced by a discovered video when the folder has
    /// one, making ``Song/hasVideo`` flip true after a download completes
    /// and the library is rescanned.
    public static func applyVideoDiscovery(to song: inout Song, folderURL: URL) {
        if let named = song.videoFileName,
           Song.supportedVideoExtensions.contains((named as NSString).pathExtension.lowercased()),
           FileManager.default.fileExists(atPath: folderURL.appendingPathComponent(named).path) {
            return
        }
        if let discovered = discoverVideoFile(inFolder: folderURL) {
            song.videoFileName = discovered.lastPathComponent
        }
    }

    /// The folder's background video, if any: `.mp4` wins over `.mov`, ties
    /// break alphabetically for determinism.
    public static func discoverVideoFile(inFolder folder: URL) -> URL? {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: folder,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )) ?? []
        for ext in Song.supportedVideoExtensions {
            let matches = files
                .filter { $0.pathExtension.lowercased() == ext }
                .sorted { $0.lastPathComponent < $1.lastPathComponent }
            if let first = matches.first {
                return first
            }
        }
        return nil
    }

    /// The first `.txt` file in the folder (alphabetically), or nil.
    private static func chartURL(inFolder folder: URL) -> URL? {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: folder,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )) ?? []
        return files
            .filter { $0.pathExtension.lowercased() == "txt" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
            .first
    }
}
