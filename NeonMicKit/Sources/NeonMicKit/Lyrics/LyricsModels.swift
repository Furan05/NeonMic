import Foundation

// MARK: - Copyright note
//
// Everything in this module fetches third-party content — song lyrics, video
// metadata, community charts — for the player's *personal* use, exactly like
// usdb-syncer or an LRC-capable music player. It is the user's responsibility
// to hold the rights to anything they acquire; NEON MIC neither redistributes
// nor commits fetched content (it lands in the gitignored `library/`). Tests
// use original fixtures only.

/// What we know about a song when searching for its lyrics or an existing chart.
public struct LyricsQuery: Equatable, Sendable {
    /// The song title.
    public var title: String
    /// The performing artist.
    public var artist: String
    /// The album, when known — improves matching.
    public var album: String?
    /// The recording's duration in seconds, when known — lets sources return
    /// the timing that matches this specific version.
    public var durationSeconds: Double?

    public init(title: String, artist: String, album: String? = nil, durationSeconds: Double? = nil) {
        self.title = title
        self.artist = artist
        self.album = album
        self.durationSeconds = durationSeconds
    }
}

/// Metadata extracted from a source video (a YouTube page, say).
public struct VideoMetadata: Equatable, Sendable {
    /// Best-guess song title (cleaned of "(Official Video)" cruft).
    public var title: String
    /// Best-guess performing artist.
    public var artist: String
    /// The untouched video title, kept for display and manual correction.
    public var rawTitle: String
    /// The video duration in seconds, when reported.
    public var durationSeconds: Double?
    /// The source page URL.
    public var sourceURL: URL

    public init(
        title: String,
        artist: String,
        rawTitle: String,
        durationSeconds: Double? = nil,
        sourceURL: URL
    ) {
        self.title = title
        self.artist = artist
        self.rawTitle = rawTitle
        self.durationSeconds = durationSeconds
        self.sourceURL = sourceURL
    }
}

/// One timed word inside an enhanced-LRC line.
public struct TimedWord: Equatable, Sendable {
    /// Seconds from the start of the audio.
    public var time: TimeInterval
    /// The word text (without its `<..>` tag).
    public var text: String

    public init(time: TimeInterval, text: String) {
        self.time = time
        self.text = text
    }
}

/// One LRC line: a start time and its text, with optional per-word timing.
public struct LRCLine: Equatable, Sendable {
    /// Seconds from the start of the audio.
    public var time: TimeInterval
    /// The whole line's text.
    public var text: String
    /// Per-word timing, when the LRC is "enhanced" (word-synced).
    public var words: [TimedWord]?

    public init(time: TimeInterval, text: String, words: [TimedWord]? = nil) {
        self.time = time
        self.text = text
        self.words = words
    }
}

/// A parsed LRC document: metadata tags plus timed lines (sorted by time).
public struct LRCDocument: Equatable, Sendable {
    /// ID tags like `ti`, `ar`, `al`, `offset`, `length`.
    public var metadata: [String: String]
    /// Timed lyric lines, ascending by time.
    public var lines: [LRCLine]
    /// The original LRC text, kept for archival / display.
    public var raw: String

    public init(metadata: [String: String] = [:], lines: [LRCLine], raw: String = "") {
        self.metadata = metadata
        self.lines = lines
        self.raw = raw
    }

    /// Whether the document carries any timed lines to synchronize against.
    public var isSynced: Bool { !lines.isEmpty }

    /// Whether any line carries word-level timing.
    public var isWordSynced: Bool { lines.contains { ($0.words?.isEmpty == false) } }
}

/// What kind of match a lyrics source returned.
public enum LyricsSourceResult: Equatable, Sendable {
    /// Time-synchronized lyrics (LRC).
    case synced(LRCDocument)
    /// Unsynchronized plain-text lyrics.
    case plain(String)
    /// A ready-made UltraStar `.txt` chart.
    case chart(String)
}

/// A lyrics/chart match from one source, with a crude confidence score.
public struct LyricsMatch: Equatable, Sendable {
    /// The content returned.
    public var result: LyricsSourceResult
    /// Which provider produced it (for display / debugging).
    public var source: String
    /// Rough match confidence in `0...1` (exact-key hits score highest).
    public var confidence: Double

    public init(result: LyricsSourceResult, source: String, confidence: Double) {
        self.result = result
        self.source = source
        self.confidence = confidence
    }
}

/// Errors thrown while acquiring lyrics, charts, or metadata.
public enum LyricsError: Error, Equatable {
    /// No source had a usable match.
    case notFound
    /// An HTTP source answered outside 200…299.
    case badResponse(status: Int)
    /// A source's payload could not be decoded.
    case malformedResponse(String)
    /// Video metadata could not be extracted.
    case metadataUnavailable(String)
    /// No yt-dlp executable was found (needed for video metadata).
    case ytDlpNotFound
    /// The provided URL was not usable.
    case invalidURL(String)
    /// The lyrics carried no timed lines to build a chart from.
    case emptyLyrics
}
