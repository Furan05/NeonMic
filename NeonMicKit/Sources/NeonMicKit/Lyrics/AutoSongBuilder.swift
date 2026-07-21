import Foundation

/// Turns a video URL into a ready-to-play library song: extract metadata, find
/// lyrics or an existing chart, generate the `.txt` when needed, then (on
/// commit) download the clip and write everything into the library.
///
/// This is the orchestration the brief calls "extending `VideoDownloaderService`".
/// It is kept a separate, composable type rather than piled onto the service,
/// which stays tightly scoped to the download queue — `AutoSongBuilder` *uses*
/// the service for the actual clip download in ``commit(_:into:downloader:)``.
///
/// Copyright: lyrics, charts, and video are third-party works fetched for the
/// player's personal use and written only into the (gitignored) library. The
/// generated chart is stamped `#CREATOR:NEON MIC` and carries placeholder
/// pitches — see ``LRCtoUltraStarConverter``.
public struct AutoSongBuilder: Sendable {

    private let metadataProvider: any VideoMetadataFetching
    private let lyricsFetcher: LyricsFetcher
    private let converter: LRCtoUltraStarConverter
    private let validator: ChartValidator

    public init(
        metadataProvider: any VideoMetadataFetching = YouTubeMetadataProvider(),
        lyricsFetcher: LyricsFetcher = .standard(),
        converter: LRCtoUltraStarConverter = LRCtoUltraStarConverter(),
        validator: ChartValidator = ChartValidator()
    ) {
        self.metadataProvider = metadataProvider
        self.lyricsFetcher = lyricsFetcher
        self.converter = converter
        self.validator = validator
    }

    // MARK: Plan

    /// Builds a preview plan **without downloading the video**: metadata +
    /// lyrics/chart + generated `.txt` + validation, fast enough for a sheet.
    ///
    /// - Throws: ``LyricsError/notFound`` when no lyrics or chart could be
    ///   located for the (possibly corrected) title/artist.
    public func buildPlan(
        from url: URL,
        titleOverride: String? = nil,
        artistOverride: String? = nil
    ) async throws -> AutoSongPlan {
        var metadata = try await metadataProvider.metadata(for: url)
        if let title = titleOverride?.trimmingCharacters(in: .whitespaces), !title.isEmpty {
            metadata.title = title
        }
        if let artist = artistOverride?.trimmingCharacters(in: .whitespaces), !artist.isEmpty {
            metadata.artist = artist
        }

        let songName = "\(metadata.artist) - \(metadata.title)"
        let baseName = VideoDownloaderService.sanitizedBaseName(from: songName)
        let videoFileName = baseName + ".mp4"
        let audioFileName = baseName + ".m4a"

        let query = LyricsQuery(
            title: metadata.title, artist: metadata.artist, durationSeconds: metadata.durationSeconds)
        let match = try await lyricsFetcher.bestMatch(for: query)

        let chartMetadata = LRCtoUltraStarConverter.ChartMetadata(
            title: metadata.title, artist: metadata.artist,
            audioFileName: audioFileName, videoFileName: videoFileName)

        var warnings: [String] = []
        let chartText: String
        let source: AutoSongPlan.Source

        switch match?.result {
        case .chart(let fetched):
            // A ready-made chart already has real pitches/timing; only point
            // its media headers at the files we're about to download.
            chartText = Self.setHeaders(in: fetched, [
                ("VIDEO", videoFileName), ("AUDIO", audioFileName), ("MP3", audioFileName),
            ])
            source = .existingChart(match?.source ?? "chart")

        case .synced(let document):
            let result = try converter.convert(document, metadata: chartMetadata)
            chartText = result.chartText
            warnings.append(contentsOf: result.warnings)
            source = .generatedFromSyncedLyrics(match?.source ?? "lrc")

        case .plain(let text):
            let document = LRCtoUltraStarConverter.syntheticDocument(
                fromPlain: text, durationSeconds: metadata.durationSeconds)
            let result = try converter.convert(document, metadata: chartMetadata)
            chartText = result.chartText
            warnings.append("Paroles non synchronisées — timing estimé, à caler manuellement.")
            warnings.append(contentsOf: result.warnings)
            source = .generatedFromPlainLyrics(match?.source ?? "plain")

        case .none:
            throw LyricsError.notFound
        }

        let (song, _) = try UltraStarParser.parseCollectingWarnings(chartText)
        let validation = validator.validate(song: song, videoDurationSeconds: metadata.durationSeconds)

        return AutoSongPlan(
            metadata: metadata,
            chartText: chartText,
            song: song,
            bpm: song.bpm,
            gapMs: song.gapMs,
            source: source,
            lyricsSource: match?.source,
            warnings: warnings,
            validation: validation,
            baseName: baseName,
            songName: songName,
            videoFileName: videoFileName,
            audioFileName: audioFileName)
    }

    /// Returns a copy of `plan` with the `#GAP` shifted by `deltaMs` — the
    /// manual timing adjustment offered in the preview. Re-parses and
    /// re-validates so the preview stays truthful.
    public func plan(_ plan: AutoSongPlan, applyingGapDeltaMs deltaMs: Double) -> AutoSongPlan {
        let newGap = plan.gapMs + deltaMs
        let chartText = Self.setHeaders(in: plan.chartText, [("GAP", String(Int(newGap.rounded())))])
        guard let parsed = try? UltraStarParser.parseCollectingWarnings(chartText) else { return plan }
        var updated = plan
        updated.chartText = chartText
        updated.song = parsed.song
        updated.gapMs = parsed.song.gapMs
        updated.validation = validator.validate(
            song: parsed.song, videoDurationSeconds: plan.metadata.durationSeconds)
        return updated
    }

    // MARK: Commit

    /// Writes the chart and downloads the clip (+ extracted audio) into a new
    /// `<library>/<Artist - Title>/` folder. Audio extraction is forced so the
    /// `#AUDIO` file the generated chart names actually exists.
    public func commit(
        _ plan: AutoSongPlan,
        into libraryRoot: URL,
        downloader: VideoDownloaderService = .shared
    ) async throws -> CommitResult {
        let accessing = libraryRoot.startAccessingSecurityScopedResource()
        defer { if accessing { libraryRoot.stopAccessingSecurityScopedResource() } }

        let folder = libraryRoot.appendingPathComponent(plan.baseName, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        let chartURL = folder.appendingPathComponent(plan.baseName).appendingPathExtension("txt")
        try Data(plan.chartText.utf8).write(to: chartURL)

        let paths = try await downloader.downloadVideo(
            from: plan.metadata.sourceURL.absoluteString,
            songName: plan.songName,
            into: folder,
            extractingAudio: true)

        var song = plan.song
        song.libraryFolderURL = folder
        return CommitResult(folderURL: folder, chartURL: chartURL, song: song, paths: paths)
    }

    // MARK: Header rewriting

    /// Replaces the given headers in a chart (case-insensitive), inserting any
    /// that are absent just after the existing header block.
    static func setHeaders(in chart: String, _ headers: [(String, String)]) -> String {
        var lines = chart.components(separatedBy: "\n")
        var present = Set<String>()
        for index in lines.indices {
            let line = lines[index]
            guard line.hasPrefix("#"), let colon = line.firstIndex(of: ":") else { continue }
            let key = line[line.index(after: line.startIndex)..<colon].uppercased()
            if let replacement = headers.first(where: { $0.0.uppercased() == key }) {
                lines[index] = "#\(replacement.0):\(replacement.1)"
                present.insert(replacement.0.uppercased())
            }
        }
        let missing = headers.filter { !present.contains($0.0.uppercased()) }
        guard !missing.isEmpty else { return lines.joined(separator: "\n") }

        var insertAt = 0
        for (index, line) in lines.enumerated() {
            if line.hasPrefix("#") { insertAt = index + 1 } else if !line.trimmingCharacters(in: .whitespaces).isEmpty { break }
        }
        lines.insert(contentsOf: missing.map { "#\($0.0):\($0.1)" }, at: insertAt)
        return lines.joined(separator: "\n")
    }
}

/// A previewable plan for one auto-created song.
public struct AutoSongPlan: Sendable {
    /// Extracted (and possibly corrected) video metadata.
    public var metadata: VideoMetadata
    /// The full UltraStar `.txt` that will be written.
    public var chartText: String
    /// The parsed chart, for preview/validation.
    public var song: Song
    public var bpm: Double
    public var gapMs: Double
    /// Where the chart came from.
    public var source: Source
    /// The lyrics/chart source name, if any.
    public var lyricsSource: String?
    /// Human-readable caveats about the generated chart.
    public var warnings: [String]
    /// The validator's findings.
    public var validation: ChartValidator.Report
    /// Sanitized `"Artist - Title"` base for files/folder.
    public var baseName: String
    /// The download queue key (`"Artist - Title"`).
    public var songName: String
    public var videoFileName: String
    public var audioFileName: String

    /// How the chart was obtained.
    public enum Source: Equatable, Sendable {
        case existingChart(String)
        case generatedFromSyncedLyrics(String)
        case generatedFromPlainLyrics(String)
    }

    public init(
        metadata: VideoMetadata, chartText: String, song: Song, bpm: Double, gapMs: Double,
        source: Source, lyricsSource: String?, warnings: [String],
        validation: ChartValidator.Report, baseName: String, songName: String,
        videoFileName: String, audioFileName: String
    ) {
        self.metadata = metadata
        self.chartText = chartText
        self.song = song
        self.bpm = bpm
        self.gapMs = gapMs
        self.source = source
        self.lyricsSource = lyricsSource
        self.warnings = warnings
        self.validation = validation
        self.baseName = baseName
        self.songName = songName
        self.videoFileName = videoFileName
        self.audioFileName = audioFileName
    }
}

/// The result of committing a plan to the library.
public struct CommitResult: Sendable {
    public var folderURL: URL
    public var chartURL: URL
    public var song: Song
    public var paths: VideoPaths

    public init(folderURL: URL, chartURL: URL, song: Song, paths: VideoPaths) {
        self.folderURL = folderURL
        self.chartURL = chartURL
        self.song = song
        self.paths = paths
    }
}
