import XCTest
@testable import NeonMicKit

final class MusicalMathTests: XCTestCase {

    func testHzToMidi() {
        XCTAssertEqual(MusicalMath.midiNote(fromHz: 440), 69, accuracy: 1e-9)
        XCTAssertEqual(MusicalMath.midiNote(fromHz: 220), 57, accuracy: 1e-9)
        XCTAssertEqual(MusicalMath.midiNote(fromHz: 880), 81, accuracy: 1e-9)
    }

    func testMidiToHz() {
        XCTAssertEqual(MusicalMath.hz(fromMidiNote: 69), 440, accuracy: 1e-9)
        XCTAssertEqual(MusicalMath.hz(fromMidiNote: 57), 220, accuracy: 1e-9)
        XCTAssertEqual(MusicalMath.hz(fromMidiNote: 60), 261.6255653, accuracy: 1e-6)
    }

    func testRoundTrip() {
        for midi in stride(from: 30.0, through: 100.0, by: 7.3) {
            XCTAssertEqual(MusicalMath.midiNote(fromHz: MusicalMath.hz(fromMidiNote: midi)), midi, accuracy: 1e-9)
        }
    }

    func testSemitoneDistanceIgnoringOctave() {
        XCTAssertEqual(MusicalMath.semitoneDistanceIgnoringOctave(60, 72), 0, accuracy: 1e-9)
        XCTAssertEqual(MusicalMath.semitoneDistanceIgnoringOctave(60, 61), 1, accuracy: 1e-9)
        XCTAssertEqual(MusicalMath.semitoneDistanceIgnoringOctave(59, 60), 1, accuracy: 1e-9)
        XCTAssertEqual(MusicalMath.semitoneDistanceIgnoringOctave(60, 60), 0, accuracy: 1e-9)
        // Two octaves down is still a perfect match.
        XCTAssertEqual(MusicalMath.semitoneDistanceIgnoringOctave(45, 69), 0, accuracy: 1e-9)
        // Distance wraps: 11 semitones apart is 1 semitone as pitch classes.
        XCTAssertEqual(MusicalMath.semitoneDistanceIgnoringOctave(60, 71), 1, accuracy: 1e-9)
        // Fractional notes survive.
        XCTAssertEqual(MusicalMath.semitoneDistanceIgnoringOctave(60.5, 72.5), 0, accuracy: 1e-9)
    }
}
