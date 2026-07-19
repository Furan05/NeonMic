import XCTest
@testable import NeonMicKit

final class HighwayFrameTests: XCTestCase {

    /// BPM 60 → 0.25 s per beat. Notes at 0–1 s, 1–2 s, and 4–5 s.
    private func makeHighwaySong() -> Song {
        makeSong(phrases: [
            [chartNote(0, 4, pitch: 0, text: "Shi"), chartNote(4, 4, pitch: 14, type: .golden, text: " bu")],
            [chartNote(16, 4, pitch: -1, text: "ya")],
        ])
    }

    private func frame(at time: TimeInterval) -> HighwayFrame {
        let song = makeHighwaySong()
        return HighwayFrame.compute(voice: song.voices[0], clock: SongClock(song: song), at: time)
    }

    private func note(_ text: String, in frame: HighwayFrame) -> HighwayNote? {
        frame.notes.first { $0.note.text == text }
    }

    // MARK: - Geometry

    func testNormalizedXAtKnownTimes() throws {
        let atStart = frame(at: 0)
        XCTAssertEqual(atStart.notes.count, 3)
        XCTAssertEqual(try XCTUnwrap(note("Shi", in: atStart)).normalizedX, 0, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(note("Shi", in: atStart)).normalizedWidth, 0.25, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(note(" bu", in: atStart)).normalizedX, 0.25, accuracy: 1e-9)
        // The far note starts exactly at the look-ahead edge.
        XCTAssertEqual(try XCTUnwrap(note("ya", in: atStart)).normalizedX, 1.0, accuracy: 1e-9)
    }

    func testNotesBehindTheNowLineHaveNegativeX() throws {
        let mid = frame(at: 2.0)
        // "Shi" played 1–2 s ago but is still inside the 1.5 s look-behind.
        XCTAssertEqual(try XCTUnwrap(note("Shi", in: mid)).normalizedX, -0.5, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(note(" bu", in: mid)).normalizedX, -0.25, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(note("ya", in: mid)).normalizedX, 0.5, accuracy: 1e-9)
    }

    func testWindowDropsNotesOutsideIt() {
        let late = frame(at: 3.6)
        // "Shi" (ended 1.0 s) and " bu" (ended 2.0 s) left the 2.1 s cutoff.
        XCTAssertEqual(late.notes.map { $0.note.text }, ["ya"])
    }

    // MARK: - Lanes

    func testLaneIndexIsOctaveFoldedPitchClass() {
        XCTAssertEqual(HighwayFrame.laneIndex(forPitch: 0), 0)
        XCTAssertEqual(HighwayFrame.laneIndex(forPitch: 12), 0)
        XCTAssertEqual(HighwayFrame.laneIndex(forPitch: 14), 2)
        XCTAssertEqual(HighwayFrame.laneIndex(forPitch: 61), 1)
        XCTAssertEqual(HighwayFrame.laneIndex(forPitch: -1), 11)
        XCTAssertEqual(HighwayFrame.laneIndex(forPitch: -13), 11)
    }

    func testLanesAreStableAcrossFrames() throws {
        let early = try XCTUnwrap(note("ya", in: frame(at: 2.0)))
        let late = try XCTUnwrap(note("ya", in: frame(at: 3.6)))
        XCTAssertEqual(early.laneIndex, 11)
        XCTAssertEqual(late.laneIndex, early.laneIndex)
        // Note type travels with the note for styling.
        XCTAssertEqual(try XCTUnwrap(note(" bu", in: frame(at: 0))).note.type, .golden)
    }

    // MARK: - Lyrics

    func testWipeProgressMidSyllable() throws {
        // Beat 2 = halfway through "Shi" (beats 0–4); " bu" not started.
        let mid = try XCTUnwrap(frame(at: 0.5).currentLine)
        XCTAssertEqual(mid.phraseIndex, 0)
        XCTAssertEqual(mid.syllables.map(\.text), ["Shi", " bu"])
        XCTAssertEqual(mid.syllables[0].progress, 0.5, accuracy: 1e-9)
        XCTAssertEqual(mid.syllables[1].progress, 0, accuracy: 1e-9)

        let next = try XCTUnwrap(frame(at: 0.5).nextLine)
        XCTAssertEqual(next.phraseIndex, 1)
        XCTAssertEqual(next.syllables.map(\.progress), [0])
    }

    func testCurrentLineDuringRestIsTheUpcomingLine() throws {
        // Beat 10 is after phrase 0 (ends 8) and before phrase 1 (starts 16).
        let resting = frame(at: 2.5)
        XCTAssertEqual(try XCTUnwrap(resting.currentLine).phraseIndex, 1)
        XCTAssertNil(resting.nextLine)
    }

    func testNoLinesAfterTheLastPhraseEnds() {
        let over = frame(at: 5.5)
        XCTAssertNil(over.currentLine)
        XCTAssertNil(over.nextLine)
    }

    // MARK: - Live coverage

    func testSessionWiresCoverageIntoFrame() throws {
        let song = makeSong(phrases: [
            [chartNote(0, 4, pitch: 60, text: "sung"), chartNote(4, 4, pitch: 0, type: .freestyle, text: "free")],
        ])
        let session = GameSession(song: song, voiceIndex: 0)
        for reading in SimulatedSinger.readings(for: song.voices[0], clock: session.clock) {
            session.process(reading)
        }

        let frame = session.highwayFrame(at: 1.0)
        let sung = try XCTUnwrap(frame.notes.first { $0.note.text == "sung" })
        let free = try XCTUnwrap(frame.notes.first { $0.note.text == "free" })
        XCTAssertGreaterThan(sung.coverage, 0.99, "the sung note should render ignited")
        XCTAssertEqual(free.coverage, 0, "freestyle notes have no coverage")
    }
}
