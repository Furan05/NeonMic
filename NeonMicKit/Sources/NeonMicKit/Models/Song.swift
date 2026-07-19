import Foundation

/// A parsed UltraStar song: header metadata plus one ``Voice`` per singer part.
public struct Song: Equatable, Sendable {
    /// The song title (`#TITLE`).
    public var title: String
    /// The performing artist (`#ARTIST`).
    public var artist: String
    /// The chart tempo (`#BPM`). Beware: UltraStar "BPM" counts quarter-beats,
    /// not musical beats — see ``seconds(fromBeat:)``.
    public var bpm: Double
    /// Milliseconds from the start of the audio file to beat 0 (`#GAP`).
    /// May be negative.
    public var gapMs: Double
    /// The audio file name (`#AUDIO`, falling back to the older `#MP3`).
    public var audioFileName: String?
    /// The cover image file name (`#COVER`).
    public var coverFileName: String?
    /// The background video file name (`#VIDEO`).
    public var videoFileName: String?
    /// The background image file name (`#BACKGROUND`).
    public var backgroundFileName: String?
    /// The lyric language (`#LANGUAGE`).
    public var language: String?
    /// The musical genre (`#GENRE`).
    public var genre: String?
    /// The release year (`#YEAR`).
    public var year: Int?
    /// Whether the source chart used `RELATIVE:YES` timing. Purely
    /// informational: note beats are always converted to absolute values
    /// during parsing.
    public var isRelative: Bool
    /// The singer parts. Solo songs have one voice, duets two.
    public var voices: [Voice]
    /// Headers the parser does not model, keyed by uppercased header name
    /// (for example `"CREATOR"`). Unknown headers are preserved, never an error.
    public var rawHeaders: [String: String]

    /// Creates a song.
    public init(
        title: String,
        artist: String,
        bpm: Double,
        gapMs: Double = 0,
        audioFileName: String? = nil,
        coverFileName: String? = nil,
        videoFileName: String? = nil,
        backgroundFileName: String? = nil,
        language: String? = nil,
        genre: String? = nil,
        year: Int? = nil,
        isRelative: Bool = false,
        voices: [Voice] = [],
        rawHeaders: [String: String] = [:]
    ) {
        self.title = title
        self.artist = artist
        self.bpm = bpm
        self.gapMs = gapMs
        self.audioFileName = audioFileName
        self.coverFileName = coverFileName
        self.videoFileName = videoFileName
        self.backgroundFileName = backgroundFileName
        self.language = language
        self.genre = genre
        self.year = year
        self.isRelative = isRelative
        self.voices = voices
        self.rawHeaders = rawHeaders
    }

    /// Converts a chart beat position to a time offset from the start of the
    /// audio file.
    ///
    /// UltraStar's `#BPM` header is famously *not* beats per minute: charts
    /// store the tempo quadrupled, so one chart beat lasts `60 / (bpm * 4)`
    /// seconds. `#GAP` (milliseconds, possibly negative) then shifts beat 0
    /// relative to the audio start:
    ///
    ///     seconds = gapMs / 1000 + beat * 60 / (bpm * 4)
    ///
    /// Forgetting the `* 4` is the single most common mistake made with this
    /// format — every beat-to-time conversion must go through this method.
    public func seconds(fromBeat beat: Double) -> TimeInterval {
        gapMs / 1000 + beat * 60 / (bpm * 4)
    }
}
