import Foundation

// MARK: - lrclib

/// Fetches synchronized lyrics from lrclib.net — a free, open, community lyrics
/// database with an anonymous JSON API (no key, no account).
///
/// Tries the exact `get` endpoint first (artist + title + duration), then falls
/// back to `search`. Lyrics remain the property of their rights holders; this
/// is for the player's personal karaoke use.
public struct LRCProvider: LyricsFetching {
    public let sourceName = "lrclib"

    private let http: any HTTPFetching
    private let baseURL: URL

    public init(http: any HTTPFetching = URLSessionHTTPClient(),
                baseURL: URL = URL(string: "https://lrclib.net")!) {
        self.http = http
        self.baseURL = baseURL
    }

    public func fetch(_ query: LyricsQuery) async throws -> LyricsMatch? {
        if let exact = try await getExact(query) { return exact }
        return try await search(query)
    }

    private func getExact(_ query: LyricsQuery) async throws -> LyricsMatch? {
        var components = URLComponents(
            url: baseURL.appendingPathComponent("api").appendingPathComponent("get"),
            resolvingAgainstBaseURL: false)!
        var items = [
            URLQueryItem(name: "track_name", value: query.title),
            URLQueryItem(name: "artist_name", value: query.artist),
        ]
        if let album = query.album { items.append(URLQueryItem(name: "album_name", value: album)) }
        if let duration = query.durationSeconds {
            items.append(URLQueryItem(name: "duration", value: String(Int(duration.rounded()))))
        }
        components.queryItems = items

        let (data, response) = try await http.get(components.url!)
        if response.statusCode == 404 { return nil }
        guard (200..<300).contains(response.statusCode) else {
            throw LyricsError.badResponse(status: response.statusCode)
        }
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw LyricsError.malformedResponse("lrclib get: not an object")
        }
        return Self.match(from: object, source: sourceName, confidence: 0.95)
    }

    private func search(_ query: LyricsQuery) async throws -> LyricsMatch? {
        var components = URLComponents(
            url: baseURL.appendingPathComponent("api").appendingPathComponent("search"),
            resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "track_name", value: query.title),
            URLQueryItem(name: "artist_name", value: query.artist),
        ]
        let (data, response) = try await http.get(components.url!)
        guard (200..<300).contains(response.statusCode) else {
            if response.statusCode == 404 { return nil }
            throw LyricsError.badResponse(status: response.statusCode)
        }
        guard let array = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            return nil
        }
        // First result with usable lyrics, scored a little lower than an exact hit.
        for object in array {
            if let match = Self.match(from: object, source: sourceName, confidence: 0.7) {
                return match
            }
        }
        return nil
    }

    /// Turns one lrclib track object into a match (synced wins over plain).
    static func match(from object: [String: Any], source: String, confidence: Double) -> LyricsMatch? {
        if let synced = object["syncedLyrics"] as? String, !synced.isEmpty {
            let document = LRCParser.parse(synced)
            if document.isSynced {
                return LyricsMatch(result: .synced(document), source: source, confidence: confidence)
            }
        }
        if let plain = object["plainLyrics"] as? String, !plain.isEmpty {
            return LyricsMatch(result: .plain(plain), source: source, confidence: confidence * 0.6)
        }
        return nil
    }
}

// MARK: - UltraStar chart database (inert seam)

/// A seam for pulling ready-made UltraStar charts from a community database.
///
/// NEON MIC ships **no scraper**: databases like usdb.animux.de require an
/// account and their terms forbid automated access, and the charts are
/// third-party works. This provider therefore stays **inert unless the user
/// supplies an endpoint they are entitled to use** (for example a personal
/// mirror). When configured it performs a single GET
/// `<endpoint>?artist=&title=` and treats a `#TITLE`-bearing body as a chart.
public struct UltraStarDBProvider: LyricsFetching {
    public let sourceName = "usdb"

    private let endpoint: URL?
    private let http: any HTTPFetching

    /// - Parameter endpoint: nil (the default) keeps the provider inert.
    public init(endpoint: URL? = nil, http: any HTTPFetching = URLSessionHTTPClient()) {
        self.endpoint = endpoint
        self.http = http
    }

    public func fetch(_ query: LyricsQuery) async throws -> LyricsMatch? {
        guard let endpoint else { return nil }
        var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false)!
        components.queryItems = (components.queryItems ?? []) + [
            URLQueryItem(name: "artist", value: query.artist),
            URLQueryItem(name: "title", value: query.title),
        ]
        let (data, response) = try await http.get(components.url!)
        if response.statusCode == 404 { return nil }
        guard (200..<300).contains(response.statusCode) else {
            throw LyricsError.badResponse(status: response.statusCode)
        }
        guard let text = String(data: data, encoding: .utf8), text.contains("#TITLE") else {
            return nil
        }
        return LyricsMatch(result: .chart(text), source: sourceName, confidence: 0.85)
    }
}

// MARK: - YouTube metadata (yt-dlp)

/// Extracts song metadata from a video URL via yt-dlp's JSON dump — no download.
///
/// Reuses the system yt-dlp that ``YtDlpVideoFetcher`` already depends on,
/// behind a ``CommandRunning`` seam so tests never shell out.
public struct YouTubeMetadataProvider: VideoMetadataFetching {

    private let runner: any CommandRunning
    private let executableURL: URL?

    public init(
        runner: any CommandRunning = ProcessCommandRunner(),
        executableURL: URL? = YtDlpVideoFetcher.locateExecutable()
    ) {
        self.runner = runner
        self.executableURL = executableURL
    }

    public func metadata(for url: URL) async throws -> VideoMetadata {
        guard let executableURL else { throw LyricsError.ytDlpNotFound }
        let result = try await runner.run(
            executable: executableURL,
            arguments: ["--dump-single-json", "--no-warnings", "--skip-download", "--no-playlist",
                        "--", url.absoluteString])
        guard result.status == 0 else {
            let message = String(decoding: result.standardError, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            throw LyricsError.metadataUnavailable(message.isEmpty ? "yt-dlp exit \(result.status)" : message)
        }
        guard let object = try? JSONSerialization.jsonObject(with: result.standardOutput) as? [String: Any] else {
            throw LyricsError.malformedResponse("yt-dlp json")
        }
        return Self.parse(object, sourceURL: url)
    }

    /// Builds metadata from yt-dlp's JSON, preferring explicit music tags and
    /// otherwise splitting a cleaned "Artist - Title" video title.
    static func parse(_ object: [String: Any], sourceURL: URL) -> VideoMetadata {
        let rawTitle = (object["title"] as? String) ?? ""
        let duration = (object["duration"] as? Double) ?? (object["duration"] as? Int).map(Double.init)
        let channel = nonEmpty(object["channel"] as? String) ?? nonEmpty(object["uploader"] as? String)

        var artist = nonEmpty(object["artist"] as? String) ?? ""
        var title = nonEmpty(object["track"] as? String) ?? ""

        if artist.isEmpty || title.isEmpty {
            let (guessArtist, guessTitle) = splitArtistTitle(cleanTitle(rawTitle), channel: channel)
            if artist.isEmpty { artist = guessArtist }
            if title.isEmpty { title = guessTitle }
        }
        if title.isEmpty { title = cleanTitle(rawTitle) }
        if artist.isEmpty { artist = channel ?? "" }

        return VideoMetadata(
            title: title, artist: artist, rawTitle: rawTitle,
            durationSeconds: duration, sourceURL: sourceURL)
    }

    /// Noise commonly wrapped in brackets in music-video titles.
    static let noiseKeywords = [
        "official", "video", "audio", "lyric", "lyrics", "visualizer", "visualiser",
        "hd", "hq", "4k", "mv", "m/v", "remaster", "explicit", "clean", "clip officiel",
        "vidéo officielle", "paroles", "music video", "lyric video",
    ]

    /// Strips bracketed "(Official Video)"-style noise and tidies separators.
    static func cleanTitle(_ title: String) -> String {
        var text = stripNoiseGroups(title, open: "(", close: ")")
        text = stripNoiseGroups(text, open: "[", close: "]")
        while text.contains("  ") { text = text.replacingOccurrences(of: "  ", with: " ") }
        return text.trimmingCharacters(in: CharacterSet(charactersIn: " -_|·"))
    }

    private static func stripNoiseGroups(_ text: String, open: Character, close: Character) -> String {
        var output = ""
        var index = text.startIndex
        while index < text.endIndex {
            if text[index] == open, let closeIndex = text[index...].firstIndex(of: close) {
                let inner = text[text.index(after: index)..<closeIndex].lowercased()
                if noiseKeywords.contains(where: { inner.contains($0) }) {
                    index = text.index(after: closeIndex)
                    continue
                }
            }
            output.append(text[index])
            index = text.index(after: index)
        }
        return output
    }

    /// Splits "Artist - Title", or falls back to a "… - Topic" channel name.
    static func splitArtistTitle(_ cleaned: String, channel: String?) -> (artist: String, title: String) {
        if let range = cleaned.range(of: " - ") {
            let artist = cleaned[..<range.lowerBound].trimmingCharacters(in: .whitespaces)
            let title = cleaned[range.upperBound...].trimmingCharacters(in: .whitespaces)
            if !artist.isEmpty && !title.isEmpty { return (artist, title) }
        }
        if let channel, channel.hasSuffix(" - Topic") {
            return (String(channel.dropLast(" - Topic".count)).trimmingCharacters(in: .whitespaces), cleaned)
        }
        return (channel ?? "", cleaned)
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let value, !value.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        return value
    }
}

private func nonEmpty(_ value: String?) -> String? {
    guard let value, !value.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
    return value
}

// MARK: - Aggregator

/// Queries several lyrics/chart sources and returns the best match.
///
/// A ready-made chart short-circuits the search; otherwise the highest-
/// confidence lyrics win. One source failing never sinks the others.
public struct LyricsFetcher: Sendable {
    private let providers: [any LyricsFetching]

    public init(providers: [any LyricsFetching] = [LRCProvider()]) {
        self.providers = providers
    }

    /// Standard provider stack: lrclib for lyrics, plus an optional (inert by
    /// default) UltraStar chart endpoint the user is entitled to use.
    public static func standard(
        usdbEndpoint: URL? = nil,
        http: any HTTPFetching = URLSessionHTTPClient()
    ) -> LyricsFetcher {
        LyricsFetcher(providers: [
            UltraStarDBProvider(endpoint: usdbEndpoint, http: http),
            LRCProvider(http: http),
        ])
    }

    public func bestMatch(for query: LyricsQuery) async throws -> LyricsMatch? {
        var best: LyricsMatch?
        for provider in providers {
            guard let match = try? await provider.fetch(query) else { continue }
            if case .chart = match.result { return match } // a ready chart wins outright
            if best == nil || match.confidence > best!.confidence {
                best = match
            }
        }
        return best
    }
}
