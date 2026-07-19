import XCTest
@testable import NeonMicKit

final class GameSessionTests: XCTestCase {

    // MARK: - Phrase ratings

    private func rateOnePhraseSong(noteCount: Int, sungCount: Int) -> PhraseResult? {
        let notes = (0..<noteCount).map { chartNote($0 * 4, 4, pitch: 60) }
        let song = makeSong(phrases: [notes])
        let session = GameSession(song: song, voiceIndex: 0)
        let readings = SimulatedSinger.readings(for: song.voices[0], clock: session.clock) { _, note in
            note < sungCount
        }
        for reading in readings {
            session.process(reading)
        }
        let endTime = session.clock.time(atBeat: Double(noteCount * 4))
        return session.snapshot(at: endTime).phraseResults.first
    }

    func testPhraseRatingGreatAt95Percent() throws {
        let result = try XCTUnwrap(rateOnePhraseSong(noteCount: 20, sungCount: 19))
        XCTAssertEqual(result.accuracy, 0.95, accuracy: 1e-9)
        XCTAssertEqual(result.rating, .great)
    }

    func testPhraseRatingOkAt75Percent() throws {
        let result = try XCTUnwrap(rateOnePhraseSong(noteCount: 4, sungCount: 3))
        XCTAssertEqual(result.accuracy, 0.75, accuracy: 1e-9)
        XCTAssertEqual(result.rating, .ok)
    }

    func testPhraseRatingTryAgainAt30Percent() throws {
        let result = try XCTUnwrap(rateOnePhraseSong(noteCount: 10, sungCount: 3))
        XCTAssertEqual(result.accuracy, 0.30, accuracy: 1e-9)
        XCTAssertEqual(result.rating, .tryAgain)
    }

    func testRatingThresholdBoundaries() {
        let rules = ScoringRules()
        XCTAssertEqual(rules.rating(forAccuracy: 0.90), .great)
        XCTAssertEqual(rules.rating(forAccuracy: 0.899), .ok)
        XCTAssertEqual(rules.rating(forAccuracy: 0.60), .ok)
        XCTAssertEqual(rules.rating(forAccuracy: 0.599), .tryAgain)
    }

    // MARK: - Combo

    func testComboIncrementsResetsAndKeepsBest() {
        let song = makeSong(phrases: [
            [chartNote(0, 4, pitch: 60), chartNote(4, 4, pitch: 62), chartNote(8, 4, pitch: 64)],
            [chartNote(16, 4, pitch: 60), chartNote(20, 4, pitch: 62)],
        ])
        let session = GameSession(song: song, voiceIndex: 0)
        let voice = song.voices[0]
        let sung = SimulatedSinger.readings(for: voice, clock: session.clock) { phrase, note in
            (phrase == 0 && note < 2) || (phrase == 1 && note == 0)
        }
        for reading in sung {
            session.process(reading)
        }

        // After the first two notes end (beat 8): two consecutive hits.
        let early = session.snapshot(at: session.clock.time(atBeat: 8))
        XCTAssertEqual(early.combo, 2)
        XCTAssertEqual(early.comboBest, 2)

        // The third note was missed (beat 12): combo resets, best survives.
        let afterMiss = session.snapshot(at: session.clock.time(atBeat: 12))
        XCTAssertEqual(afterMiss.combo, 0)
        XCTAssertEqual(afterMiss.comboBest, 2)

        // Phrase 2: one hit, then a final miss.
        let final = session.snapshot(at: session.clock.time(atBeat: 24))
        XCTAssertEqual(final.combo, 0)
        XCTAssertEqual(final.comboBest, 2)
        XCTAssertEqual(final.phraseResults.count, 2)
    }

    // MARK: - Stars

    func testStarsCaughtCountsWellSungGoldenNotes() {
        let song = makeSong(phrases: [
            [
                chartNote(0, 4, pitch: 60),
                chartNote(4, 4, pitch: 62, type: .golden),
                chartNote(8, 4, pitch: 64, type: .golden),
            ],
        ])
        let session = GameSession(song: song, voiceIndex: 0)
        let voice = song.voices[0]
        // First golden sung fully; second golden only 60% — below the 0.8 bar.
        let fullGolden = SimulatedSinger.readings(for: voice, clock: session.clock) { _, note in note == 1 }
        let partialGolden = SimulatedSinger.readings(for: voice, clock: session.clock, noteFraction: 0.6) { _, note in
            note == 2
        }
        for reading in fullGolden + partialGolden {
            session.process(reading)
        }

        let snapshot = session.snapshot(at: session.clock.time(atBeat: 12))
        XCTAssertEqual(snapshot.starsTotal, 2)
        XCTAssertEqual(snapshot.starsCaught, 1)
    }

    // MARK: - Freestyle / rap

    func testFreestyleAndRapChartScoresZeroButFailsNoPhrases() {
        let song = makeSong(phrases: [
            [
                chartNote(0, 4, pitch: 0, type: .freestyle),
                chartNote(4, 4, pitch: 0, type: .rap),
                chartNote(8, 4, pitch: 0, type: .rapGolden),
            ],
        ])
        let session = GameSession(song: song, voiceIndex: 0)
        // Even singing something during them changes nothing.
        session.process(PitchReading(time: 0.5, f0Hz: 440, midiNote: 69))

        let snapshot = session.snapshot(at: session.clock.time(atBeat: 12))
        XCTAssertEqual(snapshot.score, 0)
        XCTAssertTrue(snapshot.phraseResults.isEmpty, "unratable phrases must not be reported as failed")
        XCTAssertEqual(snapshot.starsTotal, 0, "rap-golden is not a pitch star")
        XCTAssertEqual(snapshot.combo, 0)
    }

    // MARK: - Duets

    func testDuetSessionsAreIndependent() {
        let voice0 = Voice(phrases: [Phrase(notes: [chartNote(0, 4, pitch: 60), chartNote(4, 4, pitch: 62)])])
        let voice1 = Voice(phrases: [Phrase(notes: [chartNote(0, 4, pitch: 67), chartNote(4, 4, pitch: 69)])])
        let song = Song(title: "Duet", artist: "Two", bpm: 60, voices: [voice0, voice1])

        let session0 = GameSession(song: song, voiceIndex: 0)
        let session1 = GameSession(song: song, voiceIndex: 1)

        // Singer 0 is perfect; singer 1 sings singer 0's part — wrong notes.
        for reading in SimulatedSinger.readings(for: voice0, clock: session0.clock) {
            session0.process(reading)
            session1.process(reading)
        }

        let end = session0.clock.time(atBeat: 8)
        let snapshot0 = session0.snapshot(at: end)
        let snapshot1 = session1.snapshot(at: end)

        XCTAssertEqual(snapshot0.score, 100_000)
        XCTAssertEqual(snapshot0.comboBest, 2)
        XCTAssertEqual(snapshot1.score, 0, "voice 1 expects different pitches at the same beats")
        XCTAssertEqual(snapshot1.comboBest, 0)
        XCTAssertEqual(snapshot1.phraseResults.first?.rating, .tryAgain)
    }
}
