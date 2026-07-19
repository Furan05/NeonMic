import XCTest
@testable import NeonMicKit

final class UltraStarParserTests: XCTestCase {

    // MARK: - Fixture loading

    private func fixtureURL(_ name: String) throws -> URL {
        try XCTUnwrap(
            Bundle.module.url(forResource: name, withExtension: "txt", subdirectory: "Fixtures"),
            "missing fixture \(name).txt"
        )
    }

    private func parseFixture(_ name: String) throws -> Song {
        try UltraStarParser.parse(fileAt: fixtureURL(name))
    }

    // MARK: - Headers

    func testHeaderParsingWithDecimalCommaBPM() throws {
        let song = try parseFixture("shibuya-rain-dance")
        XCTAssertEqual(song.title, "Shibuya Rain Dance")
        XCTAssertEqual(song.artist, "The Neon Signals")
        XCTAssertEqual(song.bpm, 285.5)
        XCTAssertEqual(song.gapMs, 1200)
        XCTAssertEqual(song.audioFileName, "shibuya-rain-dance.ogg", "AUDIO must be preferred over MP3")
        XCTAssertEqual(song.coverFileName, "shibuya-cover.jpg")
        XCTAssertEqual(song.language, "English")
        XCTAssertEqual(song.genre, "Synthpop")
        XCTAssertEqual(song.year, 2024)
        XCTAssertFalse(song.isRelative)
    }

    func testNegativeGapAndUnknownHeaders() throws {
        let (song, _) = try UltraStarParser.parseCollectingWarnings(fileAt: fixtureURL("quirky"))
        XCTAssertEqual(song.gapMs, -250)
        XCTAssertEqual(song.rawHeaders, [
            "CREATOR": "NeonMic Fixtures",
            "MYSTERYTAG": "totally unknown",
            "PREVIEWSTART": "12,5",
        ])
    }

    func testWellFormedFixtureHasNoWarnings() throws {
        let (_, warnings) = try UltraStarParser.parseCollectingWarnings(fileAt: fixtureURL("shibuya-rain-dance"))
        XCTAssertTrue(warnings.isEmpty, "unexpected warnings: \(warnings)")
    }

    // MARK: - Notes and phrases

    func testPhraseSplittingAndNoteFields() throws {
        let song = try parseFixture("shibuya-rain-dance")
        XCTAssertEqual(song.voices.count, 1)
        let phrases = song.voices[0].phrases
        XCTAssertEqual(phrases.count, 4)
        XCTAssertEqual(phrases.map { $0.notes.count }, [5, 4, 5, 3])

        let first = phrases[0].notes[0]
        XCTAssertEqual(first.startBeat, 0)
        XCTAssertEqual(first.lengthBeats, 3)
        XCTAssertEqual(first.pitch, 12)
        XCTAssertEqual(first.text, "Nee")
        XCTAssertEqual(first.type, .normal)

        XCTAssertEqual(phrases[0].startBeat, 0)
        XCTAssertEqual(phrases[0].endBeat, 18)
        XCTAssertEqual(phrases[3].startBeat, 66)
        XCTAssertEqual(phrases[3].endBeat, 78)
    }

    func testNoteTextPreservesSpacing() throws {
        let song = try parseFixture("shibuya-rain-dance")
        let notes = song.voices[0].phrases[0].notes
        XCTAssertEqual(notes[1].text, "on~", "the single separator space is not part of the text")
        XCTAssertEqual(notes[2].text, " rain", "an extra leading space must be preserved")

        let inlineText = "#TITLE:T\n#ARTIST:A\n#BPM:100\n: 0 2 0 la \n: 3 2 0 di\nE\n"
        let inlineSong = try UltraStarParser.parse(inlineText)
        XCTAssertEqual(inlineSong.voices[0].phrases[0].notes[0].text, "la ", "a trailing space must be preserved")
    }

    func testGoldenNotes() throws {
        let song = try parseFixture("shibuya-rain-dance")
        let goldenNotes = song.voices[0].phrases.flatMap(\.notes).filter { $0.type == .golden }
        XCTAssertEqual(goldenNotes.count, 3)
        XCTAssertEqual(song.voices[0].phrases[0].notes[1].type, .golden)
        XCTAssertTrue(NoteType.normal.isPitchScored)
        XCTAssertTrue(NoteType.golden.isPitchScored)
    }

    func testFreestyleAndRapNotes() throws {
        let (song, _) = try UltraStarParser.parseCollectingWarnings(fileAt: fixtureURL("quirky"))
        let notes = song.voices[0].phrases[0].notes
        XCTAssertEqual(notes.map(\.type), [.normal, .freestyle, .rap, .rapGolden])
        XCTAssertFalse(NoteType.freestyle.isPitchScored)
        XCTAssertFalse(NoteType.rap.isPitchScored)
        XCTAssertFalse(NoteType.rapGolden.isPitchScored)
    }

    // MARK: - Duets

    func testDuetVoiceSeparation() throws {
        let song = try parseFixture("ferry-to-kowloon-duet")
        XCTAssertEqual(song.voices.count, 2)
        XCTAssertEqual(song.voices[0].phrases.count, 2)
        XCTAssertEqual(song.voices[1].phrases.count, 2)
        XCTAssertEqual(song.voices[0].phrases[0].notes.first?.text, "Cross")
        XCTAssertEqual(song.voices[1].phrases[0].notes.first?.text, "Har")
        XCTAssertEqual(song.voices[1].phrases[0].notes.first?.startBeat, 40)
    }

    func testVoiceMarkerWithSpaceIsAccepted() throws {
        let text = "#TITLE:T\n#ARTIST:A\n#BPM:100\nP 1\n: 0 1 0 a\nP 2\n: 4 1 0 b\nE\n"
        let song = try UltraStarParser.parse(text)
        XCTAssertEqual(song.voices.count, 2)
        XCTAssertEqual(song.voices[1].phrases[0].notes[0].text, "b")
    }

    // MARK: - Relative mode

    func testRelativeModeConvertsToAbsoluteBeats() throws {
        let song = try parseFixture("relative-mode")
        XCTAssertTrue(song.isRelative)
        let phrases = song.voices[0].phrases
        XCTAssertEqual(phrases.count, 3)
        XCTAssertEqual(phrases[0].notes.map(\.startBeat), [0, 3, 6])
        XCTAssertEqual(phrases[1].notes.map(\.startBeat), [12, 15])
        XCTAssertEqual(phrases[2].notes.map(\.startBeat), [22])
    }

    // MARK: - Encodings and line endings

    func testEncodingFallbackToWindows1252() throws {
        let text = "#TITLE:Café Décalé\n#ARTIST:Señor Müller\n#BPM:120\n: 0 2 0 Olé\nE\n"
        let data = try XCTUnwrap(text.data(using: .windowsCP1252))
        XCTAssertNil(String(data: data, encoding: .utf8), "sample must not be valid UTF-8 or this test proves nothing")

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("neonmic-encoding-test-\(UUID().uuidString).txt")
        try data.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let song = try UltraStarParser.parse(fileAt: url)
        XCTAssertEqual(song.title, "Café Décalé")
        XCTAssertEqual(song.artist, "Señor Müller")
        XCTAssertEqual(song.voices[0].phrases[0].notes[0].text, "Olé")
    }

    func testBOMAndCRLFHandling() throws {
        let url = try fixtureURL("quirky")
        let data = try Data(contentsOf: url)
        XCTAssertTrue(data.starts(with: [0xEF, 0xBB, 0xBF]), "fixture must keep its UTF-8 BOM")
        XCTAssertTrue(data.contains(0x0D), "fixture must keep CRLF line endings")

        let (song, _) = try UltraStarParser.parseCollectingWarnings(fileAt: url)
        XCTAssertEqual(song.title, "Quirky Test Pattern")
        XCTAssertEqual(song.artist, "The Edge Cases")
    }

    // MARK: - Warnings and end marker

    func testMalformedNoteLineProducesWarningNotFailure() throws {
        let (song, warnings) = try UltraStarParser.parseCollectingWarnings(fileAt: fixtureURL("quirky"))
        XCTAssertEqual(warnings.count, 1)
        let warning = try XCTUnwrap(warnings.first)
        XCTAssertEqual(warning.lineNumber, 12)
        XCTAssertTrue(warning.lineContent.contains("twelve"))

        let allNotes = song.voices.flatMap(\.phrases).flatMap(\.notes)
        XCTAssertEqual(allNotes.count, 6)
        XCTAssertFalse(allNotes.contains { $0.text.contains("broken") })
    }

    func testContentAfterEndMarkerIsIgnored() throws {
        let (song, warnings) = try UltraStarParser.parseCollectingWarnings(fileAt: fixtureURL("quirky"))
        let allNotes = song.voices.flatMap(\.phrases).flatMap(\.notes)
        XCTAssertFalse(allNotes.contains { $0.startBeat == 99 })
        XCTAssertTrue(warnings.allSatisfy { $0.lineNumber < 17 }, "lines after E must not even be inspected")
    }

    // MARK: - Structural errors

    func testMissingBPMThrows() throws {
        let url = try fixtureURL("broken-no-bpm")
        XCTAssertThrowsError(try UltraStarParser.parse(fileAt: url)) { error in
            XCTAssertEqual(error as? UltraStarParseError, .missingRequiredHeader("BPM"))
        }
    }

    func testInvalidBPMThrows() {
        let text = "#TITLE:T\n#ARTIST:A\n#BPM:andante\n: 0 1 0 a\nE\n"
        XCTAssertThrowsError(try UltraStarParser.parse(text)) { error in
            XCTAssertEqual(error as? UltraStarParseError, .invalidBPM(lineNumber: 3, value: "andante"))
        }
    }

    func testMissingTitleThrows() {
        let text = "#ARTIST:A\n#BPM:100\n: 0 1 0 a\nE\n"
        XCTAssertThrowsError(try UltraStarParser.parse(text)) { error in
            XCTAssertEqual(error as? UltraStarParseError, .missingRequiredHeader("TITLE"))
        }
    }

    func testMissingArtistThrows() {
        let text = "#TITLE:T\n#BPM:100\n: 0 1 0 a\nE\n"
        XCTAssertThrowsError(try UltraStarParser.parse(text)) { error in
            XCTAssertEqual(error as? UltraStarParseError, .missingRequiredHeader("ARTIST"))
        }
    }

    func testNoNotesThrows() {
        let text = "#TITLE:T\n#ARTIST:A\n#BPM:100\nE\n"
        XCTAssertThrowsError(try UltraStarParser.parse(text)) { error in
            XCTAssertEqual(error as? UltraStarParseError, .noNotes)
        }
    }

    // MARK: - Timing

    func testBeatToSecondsConversion() {
        let song = Song(title: "T", artist: "A", bpm: 300, gapMs: 1000)
        XCTAssertEqual(song.seconds(fromBeat: 0), 1.0, accuracy: 1e-9)
        XCTAssertEqual(song.seconds(fromBeat: 20), 2.0, accuracy: 1e-9)
    }

    func testBeatToSecondsWithNegativeGap() {
        // One chart beat at BPM 120 lasts 60 / (120 * 4) = 0.125 s.
        let song = Song(title: "T", artist: "A", bpm: 120, gapMs: -500)
        XCTAssertEqual(song.seconds(fromBeat: 0), -0.5, accuracy: 1e-9)
        XCTAssertEqual(song.seconds(fromBeat: 8), 0.5, accuracy: 1e-9)
    }
}
