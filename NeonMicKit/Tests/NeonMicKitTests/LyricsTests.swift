import XCTest
@testable import NeonMicKit

/// Lyrics acquisition + LRC→UltraStar conversion tests. Fully offline: the HTTP
/// and command seams are mocked, and every fixture is original content.
final class LyricsTests: XCTestCase {

    // MARK: - LRC parsing

    func testParsesLineSyncedLRCWithMetadataAndOffset() {
        let lrc = """
        [ti:Test Tune]
        [ar:The Neon Signals]
        [offset:500]
        [00:10.00]First line here
        [00:12.50]Second line now
        """
        let document = LRCParser.parse(lrc)
        XCTAssertEqual(document.metadata["ti"], "Test Tune")
        XCTAssertEqual(document.metadata["ar"], "The Neon Signals")
        XCTAssertEqual(document.lines.count, 2)
        // offset +500 ms shifts both timestamps later.
        XCTAssertEqual(document.lines[0].time, 10.5, accuracy: 0.001)
        XCTAssertEqual(document.lines[1].time, 13.0, accuracy: 0.001)
        XCTAssertFalse(document.isWordSynced)
    }

    func testParsesEnhancedWordSyncedLRC() throws {
        let lrc = "[00:05.00]<00:05.00>Hey <00:05.40>there <00:05.90>friend"
        let document = LRCParser.parse(lrc)
        let line = try XCTUnwrap(document.lines.first)
        let words = try XCTUnwrap(line.words)
        XCTAssertEqual(words.count, 3)
        XCTAssertEqual(words[0].time, 5.0, accuracy: 0.001)
        XCTAssertEqual(words[1].time, 5.4, accuracy: 0.001)
        XCTAssertEqual(words[2].text.trimmingCharacters(in: .whitespaces), "friend")
        XCTAssertTrue(document.isWordSynced)
    }

    func testTimeTagParsing() {
        XCTAssertEqual(LRCParser.parseTime("01:02.50"), 62.5)
        XCTAssertEqual(LRCParser.parseTime("00:05"), 5.0)
        XCTAssertEqual(LRCParser.parseTime("1:02:03.5"), 3723.5) // hh:mm:ss
        XCTAssertNil(LRCParser.parseTime("nope"))
    }

    // MARK: - LRC → UltraStar conversion

    func testConvertsSyncedLyricsToRoundTrippingChart() throws {
        let lrc = """
        [00:10.00]Hello
        [00:11.50]World
        [00:13.20]Again
        [00:20.00]End
        """
        let document = LRCParser.parse(lrc)
        let metadata = LRCtoUltraStarConverter.ChartMetadata(
            title: "Round Trip", artist: "Tester",
            audioFileName: "Tester - Round Trip.m4a", videoFileName: "Tester - Round Trip.mp4")
        let result = try LRCtoUltraStarConverter().convert(document, metadata: metadata)

        XCTAssertGreaterThanOrEqual(result.bpm, 180)
        XCTAssertLessThanOrEqual(result.bpm, 600)
        XCTAssertEqual(result.gapMs, 10_000, accuracy: 1, "GAP comes from the first timestamp")
        XCTAssertEqual(result.noteCount, 4)
        XCTAssertTrue(result.generatedPitches)
        XCTAssertFalse(result.warnings.isEmpty)

        // Round-trip: parse the generated chart and confirm the note times
        // reconstruct the LRC timings to within one beat.
        let (song, _) = try UltraStarParser.parseCollectingWarnings(result.chartText)
        XCTAssertEqual(song.title, "Round Trip")
        XCTAssertEqual(song.voices.first?.phrases.count, 4, "one phrase per LRC line")

        let secondsPerBeat = 15.0 / result.bpm
        let expected = [10.0, 11.5, 13.2, 20.0]
        let notes = song.voices[0].phrases.map { $0.notes[0] }
        for (note, time) in zip(notes, expected) {
            let reconstructed = song.seconds(fromBeat: Double(note.startBeat))
            XCTAssertEqual(reconstructed, time, accuracy: secondsPerBeat,
                           "note time must reconstruct the LRC timestamp within a beat")
        }
    }

    func testConversionEmbedsMediaHeaders() throws {
        let document = LRCParser.parse("[00:01.00]Only line")
        let metadata = LRCtoUltraStarConverter.ChartMetadata(
            title: "T", artist: "A", audioFileName: "A - T.m4a", videoFileName: "A - T.mp4")
        let chart = try LRCtoUltraStarConverter().convert(document, metadata: metadata).chartText
        XCTAssertTrue(chart.contains("#VIDEO:A - T.mp4"))
        XCTAssertTrue(chart.contains("#AUDIO:A - T.m4a"))
        XCTAssertTrue(chart.contains("#CREATOR:NEON MIC"))
    }

    func testEmptyLyricsThrows() {
        let document = LRCDocument(lines: [])
        XCTAssertThrowsError(try LRCtoUltraStarConverter().convert(
            document, metadata: .init(title: "T", artist: "A"))) { error in
            XCTAssertEqual(error as? LyricsError, .emptyLyrics)
        }
    }

    func testSyntheticDocumentSpreadsPlainLyrics() {
        let document = LRCtoUltraStarConverter.syntheticDocument(
            fromPlain: "one\ntwo\nthree", durationSeconds: 30)
        XCTAssertEqual(document.lines.count, 3)
        XCTAssertTrue(zip(document.lines, document.lines.dropFirst()).allSatisfy { $0.time < $1.time })
    }

    func testHeuristicBPMStaysInRange() {
        let fast = LRCtoUltraStarConverter.heuristicBPM([0, 0.1, 0.2, 0.3], minBPM: 180, maxBPM: 600)
        XCTAssertLessThanOrEqual(fast, 600)
        XCTAssertGreaterThanOrEqual(fast, 180)
        let empty = LRCtoUltraStarConverter.heuristicBPM([], minBPM: 180, maxBPM: 600)
        XCTAssertGreaterThanOrEqual(empty, 180)
    }

    // MARK: - YouTube metadata parsing

    func testMetadataCleansTitleAndSplitsArtist() {
        let object: [String: Any] = [
            "title": "The Midnights - Neon Skyline (Official Music Video)",
            "channel": "The Midnights",
            "duration": 214,
        ]
        let metadata = YouTubeMetadataProvider.parse(object, sourceURL: URL(string: "https://y.tube/x")!)
        XCTAssertEqual(metadata.artist, "The Midnights")
        XCTAssertEqual(metadata.title, "Neon Skyline")
        XCTAssertEqual(metadata.durationSeconds, 214)
    }

    func testMetadataPrefersExplicitMusicTags() {
        let object: [String: Any] = [
            "title": "some random upload [Lyrics]",
            "artist": "Lumen",
            "track": "Cassette Heart",
        ]
        let metadata = YouTubeMetadataProvider.parse(object, sourceURL: URL(string: "https://y.tube/x")!)
        XCTAssertEqual(metadata.artist, "Lumen")
        XCTAssertEqual(metadata.title, "Cassette Heart")
    }

    func testTitleCleaningStripsNoiseGroups() {
        XCTAssertEqual(YouTubeMetadataProvider.cleanTitle("Song (Official Video) [HD]"), "Song")
        XCTAssertEqual(YouTubeMetadataProvider.cleanTitle("Artist - Title (Lyrics)"), "Artist - Title")
    }

    // MARK: - lrclib provider (mock HTTP)

    func testLRCProviderReturnsSyncedFromGet() async throws {
        let json = #"{"syncedLyrics":"[00:10.00]Hi there","plainLyrics":"Hi there"}"#
        let http = MockHTTP { url in
            XCTAssertTrue(url.path.contains("/api/get"))
            return (Data(json.utf8), 200)
        }
        let provider = LRCProvider(http: http)
        let match = try await provider.fetch(LyricsQuery(title: "Hi", artist: "Someone", durationSeconds: 100))
        guard case .synced(let document)? = match?.result else {
            return XCTFail("expected synced lyrics")
        }
        XCTAssertEqual(document.lines.count, 1)
        XCTAssertEqual(match?.source, "lrclib")
    }

    func testLRCProviderFallsBackToSearchOn404() async throws {
        let searchJSON = #"[{"syncedLyrics":"[00:01.00]Found","plainLyrics":"Found"}]"#
        let http = MockHTTP { url in
            if url.path.contains("/api/get") { return (Data(), 404) }
            return (Data(searchJSON.utf8), 200)
        }
        let provider = LRCProvider(http: http)
        let match = try await provider.fetch(LyricsQuery(title: "X", artist: "Y"))
        guard case .synced? = match?.result else { return XCTFail("expected synced from search") }
        XCTAssertEqual(match?.confidence ?? 0, 0.7, accuracy: 0.001)
    }

    // MARK: - Validator

    func testValidatorFlagsLyricsLongerThanVideo() throws {
        let document = LRCParser.parse("[00:10.00]a\n[03:00.00]b")
        let chart = try LRCtoUltraStarConverter().convert(
            document, metadata: .init(title: "T", artist: "A")).chartText
        let (song, _) = try UltraStarParser.parseCollectingWarnings(chart)
        let report = ChartValidator().validate(song: song, videoDurationSeconds: 60)
        XCTAssertTrue(report.issues.contains { $0.message.contains("dépassent la vidéo") })
    }

    // MARK: - AutoSongBuilder (mocked providers)

    func testBuildPlanFromSyncedLyrics() async throws {
        let metadata = VideoMetadata(
            title: "Neon Skyline", artist: "The Midnights", rawTitle: "raw",
            durationSeconds: 200, sourceURL: URL(string: "https://youtu.be/abc")!)
        let lyrics = LyricsMatch(
            result: .synced(LRCParser.parse("[00:05.00]Hello\n[00:07.00]World")),
            source: "lrclib", confidence: 0.95)
        let builder = AutoSongBuilder(
            metadataProvider: MockMetadata(metadata: metadata),
            lyricsFetcher: LyricsFetcher(providers: [MockLyrics(match: lyrics)]))

        let plan = try await builder.buildPlan(from: metadata.sourceURL)
        XCTAssertEqual(plan.songName, "The Midnights - Neon Skyline")
        XCTAssertEqual(plan.videoFileName, "The Midnights - Neon Skyline.mp4")
        XCTAssertTrue(plan.chartText.contains("#VIDEO:The Midnights - Neon Skyline.mp4"))
        XCTAssertEqual(plan.song.voices.first?.phrases.count, 2)
        if case .generatedFromSyncedLyrics = plan.source {} else { XCTFail("wrong source") }

        // Manual GAP nudge re-parses truthfully.
        let nudged = builder.plan(plan, applyingGapDeltaMs: 500)
        XCTAssertEqual(nudged.gapMs, plan.gapMs + 500, accuracy: 1)
    }

    func testBuildPlanThrowsWhenNoLyrics() async {
        let metadata = VideoMetadata(
            title: "X", artist: "Y", rawTitle: "X", durationSeconds: 100,
            sourceURL: URL(string: "https://youtu.be/none")!)
        let builder = AutoSongBuilder(
            metadataProvider: MockMetadata(metadata: metadata),
            lyricsFetcher: LyricsFetcher(providers: [MockLyrics(match: nil)]))
        do {
            _ = try await builder.buildPlan(from: metadata.sourceURL)
            XCTFail("expected notFound")
        } catch {
            XCTAssertEqual(error as? LyricsError, .notFound)
        }
    }

    func testSetHeadersReplacesAndInserts() {
        let chart = "#TITLE:T\n#ARTIST:A\n#BPM:200\n: 0 4 0 la\nE\n"
        let updated = AutoSongBuilder.setHeaders(in: chart, [("BPM", "300"), ("VIDEO", "clip.mp4")])
        XCTAssertTrue(updated.contains("#BPM:300"))
        XCTAssertTrue(updated.contains("#VIDEO:clip.mp4"))
        XCTAssertFalse(updated.contains("#BPM:200"))
    }
}

// MARK: - Mocks

private struct MockHTTP: HTTPFetching {
    let handler: @Sendable (URL) -> (Data, Int)
    func get(_ url: URL) async throws -> (Data, HTTPURLResponse) {
        let (data, status) = handler(url)
        let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil)!
        return (data, response)
    }
}

private struct MockMetadata: VideoMetadataFetching {
    let metadata: VideoMetadata
    func metadata(for url: URL) async throws -> VideoMetadata { metadata }
}

private struct MockLyrics: LyricsFetching {
    let sourceName = "mock"
    let match: LyricsMatch?
    func fetch(_ query: LyricsQuery) async throws -> LyricsMatch? { match }
}
