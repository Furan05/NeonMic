import XCTest
@testable import NeonMicKit

final class SongClockTests: XCTestCase {

    private func makeLookupSong() -> Song {
        let phrase1 = Phrase(notes: [
            Note(startBeat: 0, lengthBeats: 2, pitch: 5, text: "a", type: .normal),
            Note(startBeat: 3, lengthBeats: 2, pitch: 7, text: "b", type: .normal),
        ])
        let phrase2 = Phrase(notes: [
            Note(startBeat: 10, lengthBeats: 4, pitch: 9, text: "c", type: .golden),
        ])
        return Song(title: "T", artist: "A", bpm: 240, voices: [Voice(phrases: [phrase1, phrase2])])
    }

    // MARK: - Time ↔ beat

    func testTimeAndBeatAreInverse() {
        let clock = SongClock(song: Song(title: "T", artist: "A", bpm: 300, gapMs: 1000))
        XCTAssertEqual(clock.time(atBeat: 20), 2.0, accuracy: 1e-9)
        XCTAssertEqual(clock.currentBeat(at: 2.0), 20, accuracy: 1e-9)
        XCTAssertEqual(clock.currentBeat(at: clock.time(atBeat: 137.5)), 137.5, accuracy: 1e-9)
    }

    func testNegativeGap() {
        // BPM 120 → 8 beats per second; beat 0 sits at -0.5 s.
        let clock = SongClock(song: Song(title: "T", artist: "A", bpm: 120, gapMs: -500))
        XCTAssertEqual(clock.time(atBeat: 8), 0.5, accuracy: 1e-9)
        XCTAssertEqual(clock.currentBeat(at: 0.5), 8, accuracy: 1e-9)
        XCTAssertEqual(clock.currentBeat(at: -0.5), 0, accuracy: 1e-9)
    }

    func testLatencyOffsetAppliesOnlyToInputSide() {
        let clock = SongClock(song: Song(title: "T", artist: "A", bpm: 300, gapMs: 1000), latencyOffsetMs: 100)
        // Chart side is untouched by latency…
        XCTAssertEqual(clock.currentBeat(at: 2.1), 22, accuracy: 1e-9)
        // …while a mic sample captured at 2.1 s was sung against beat 20.
        XCTAssertEqual(clock.inputBeat(at: 2.1), 20, accuracy: 1e-9)
    }

    func testZeroLatencyInputBeatMatchesCurrentBeat() {
        let clock = SongClock(song: Song(title: "T", artist: "A", bpm: 300, gapMs: 1000))
        XCTAssertEqual(clock.inputBeat(at: 2.0), clock.currentBeat(at: 2.0), accuracy: 1e-9)
    }

    // MARK: - Chart lookup

    func testNoteLookup() {
        let clock = SongClock(song: makeLookupSong())
        XCTAssertEqual(clock.note(atBeat: 0, inVoice: 0)?.text, "a")
        XCTAssertEqual(clock.note(atBeat: 1.9, inVoice: 0)?.text, "a")
        XCTAssertEqual(clock.note(atBeat: 3.5, inVoice: 0)?.text, "b")
        XCTAssertEqual(clock.note(atBeat: 10, inVoice: 0)?.text, "c")
        XCTAssertEqual(clock.note(atBeat: 13.9, inVoice: 0)?.text, "c")
    }

    func testLookupInRestsAndGapsReturnsNil() {
        let clock = SongClock(song: makeLookupSong())
        // Rest inside a phrase: no note, but still in the phrase.
        XCTAssertNil(clock.note(atBeat: 2.5, inVoice: 0))
        XCTAssertEqual(clock.phrase(atBeat: 2.5, inVoice: 0)?.startBeat, 0)
        // Between phrases: neither.
        XCTAssertNil(clock.note(atBeat: 7, inVoice: 0))
        XCTAssertNil(clock.phrase(atBeat: 7, inVoice: 0))
        // Before the first phrase.
        XCTAssertNil(clock.phrase(atBeat: -1, inVoice: 0))
    }

    func testLookupRangesAreHalfOpen() {
        let clock = SongClock(song: makeLookupSong())
        // Note "b" ends at beat 5, which is also the phrase's end.
        XCTAssertNil(clock.note(atBeat: 5, inVoice: 0))
        XCTAssertNil(clock.phrase(atBeat: 5, inVoice: 0))
        // Phrase 2 ends at beat 14.
        XCTAssertNil(clock.phrase(atBeat: 14, inVoice: 0))
    }

    func testLookupInMissingVoiceReturnsNil() {
        let clock = SongClock(song: makeLookupSong())
        XCTAssertNil(clock.phrase(atBeat: 0, inVoice: 1))
        XCTAssertNil(clock.note(atBeat: 0, inVoice: -1))
    }
}
