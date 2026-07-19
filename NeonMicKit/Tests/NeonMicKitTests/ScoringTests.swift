import XCTest
@testable import NeonMicKit

final class ScoringTests: XCTestCase {

    /// Two phrases, one golden note among normals — 1 s per note at BPM 60.
    private func makeStandardSong() -> Song {
        makeSong(phrases: [
            [chartNote(0, 4, pitch: 60), chartNote(4, 4, pitch: 62), chartNote(8, 4, pitch: 64, type: .golden)],
            [chartNote(16, 4, pitch: 65), chartNote(20, 4, pitch: 67)],
        ])
    }

    private func playThrough(_ song: Song, readings: [PitchReading]) -> GameSnapshot {
        let session = GameSession(song: song, voiceIndex: 0)
        for reading in readings {
            session.process(reading)
        }
        let endBeat = Double(song.voices[0].phrases.last?.endBeat ?? 0)
        return session.snapshot(at: session.clock.time(atBeat: endBeat))
    }

    func testPerfectSingerScoresExactlyMaxScore() {
        let song = makeStandardSong()
        let clock = SongClock(song: song)
        let snapshot = playThrough(song, readings: SimulatedSinger.readings(for: song.voices[0], clock: clock))
        XCTAssertEqual(snapshot.score, 100_000)
        XCTAssertEqual(snapshot.accuracy, 1.0, accuracy: 1e-9)
        XCTAssertEqual(snapshot.combo, 5)
        XCTAssertEqual(snapshot.comboBest, 5)
    }

    func testOctaveDownPerfectSingerScoresIdentically() {
        let song = makeStandardSong()
        let clock = SongClock(song: song)
        let straight = playThrough(song, readings: SimulatedSinger.readings(for: song.voices[0], clock: clock))
        let octaveDown = playThrough(
            song,
            readings: SimulatedSinger.readings(for: song.voices[0], clock: clock, semitoneOffset: -12)
        )
        XCTAssertEqual(octaveDown.score, straight.score)
        XCTAssertEqual(octaveDown.score, 100_000)
    }

    func testHalfDurationSingerScoresAboutHalf() {
        let song = makeStandardSong()
        let clock = SongClock(song: song)
        let snapshot = playThrough(
            song,
            readings: SimulatedSinger.readings(for: song.voices[0], clock: clock, noteFraction: 0.5)
        )
        // Half of each note plus the per-note first-reading grace (~30 ms/s).
        XCTAssertGreaterThan(snapshot.score, 45_000)
        XCTAssertLessThan(snapshot.score, 58_000)
    }

    func testSilenceScoresZero() {
        let song = makeStandardSong()
        let snapshot = playThrough(song, readings: [])
        XCTAssertEqual(snapshot.score, 0)
        XCTAssertEqual(snapshot.accuracy, 0)
        XCTAssertEqual(snapshot.combo, 0)
        XCTAssertEqual(snapshot.comboBest, 0)
        XCTAssertTrue(snapshot.phraseResults.allSatisfy { $0.rating == .tryAgain })
    }

    func testGoldenNotesWeighDoubleTheirBeats() {
        // 4 normal beats + 4 golden beats → weights 4 and 8 of 12 total.
        let song = makeSong(phrases: [
            [chartNote(0, 4, pitch: 60), chartNote(4, 4, pitch: 62, type: .golden)],
        ])
        let clock = SongClock(song: song)
        let voice = song.voices[0]

        let goldenOnly = playThrough(
            song,
            readings: SimulatedSinger.readings(for: voice, clock: clock) { _, note in note == 1 }
        )
        XCTAssertEqual(goldenOnly.score, 66_667)

        let normalOnly = playThrough(
            song,
            readings: SimulatedSinger.readings(for: voice, clock: clock) { _, note in note == 0 }
        )
        XCTAssertEqual(normalOnly.score, 33_333)
    }

    func testPitchToleranceEdges() {
        let song = makeSong(phrases: [[chartNote(0, 8, pitch: 60)]])
        let clock = SongClock(song: song)
        let voice = song.voices[0]

        let justInside = playThrough(
            song,
            readings: SimulatedSinger.readings(for: voice, clock: clock, semitoneOffset: 0.7)
        )
        XCTAssertEqual(justInside.score, 100_000, "+0.7 semitones is within the 0.75 tolerance")

        let justOutside = playThrough(
            song,
            readings: SimulatedSinger.readings(for: voice, clock: clock, semitoneOffset: 0.8)
        )
        XCTAssertEqual(justOutside.score, 0, "+0.8 semitones is outside the 0.75 tolerance")
    }

    func testStalledReadingsCannotCreditAHole() {
        // Two readings 1 s apart across a 1 s note: only maxReadingGap (50 ms)
        // of the gap may be credited, not the whole second.
        let song = makeSong(phrases: [[chartNote(0, 4, pitch: 60)]])
        let session = GameSession(song: song, voiceIndex: 0)
        session.process(PitchReading(time: 0.0, f0Hz: MusicalMath.hz(fromMidiNote: 60), midiNote: 60))
        session.process(PitchReading(time: 0.99, f0Hz: MusicalMath.hz(fromMidiNote: 60), midiNote: 60))
        let snapshot = session.snapshot(at: 1.0)
        // At most two capped credits (2 × 50 ms) over a 1 s note = 10%.
        XCTAssertLessThanOrEqual(snapshot.score, 10_000)
    }
}
