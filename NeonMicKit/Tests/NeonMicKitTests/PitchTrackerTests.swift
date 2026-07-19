import XCTest
@testable import NeonMicKit

final class PitchTrackerTests: XCTestCase {

    private let sampleRate = 44_100.0

    func testSilenceIsGated() {
        let tracker = PitchTracker(sampleRate: sampleRate)
        let silence = [Float](repeating: 0, count: 4096)
        XCTAssertNil(tracker.process(silence, at: 0))
    }

    func testQuietRumbleBelowGateIsRejectedBeforeDetection() {
        let tracker = PitchTracker(sampleRate: sampleRate)
        // A perfectly periodic signal, but far too quiet to be singing.
        let faint = sineSamples(frequency: 220, amplitude: 0.001)
        XCTAssertNil(tracker.process(faint, at: 0))
    }

    func testSteadyToneProducesStableReadings() throws {
        let tracker = PitchTracker(sampleRate: sampleRate)
        let buffer = sineSamples(frequency: 220)
        for step in 0..<4 {
            let reading = try XCTUnwrap(tracker.process(buffer, at: Double(step) * 0.05))
            XCTAssertEqual(reading.midiNote, 57, accuracy: 0.1)
        }
    }

    func testMedianFilterAbsorbsOctaveJump() throws {
        let tracker = PitchTracker(sampleRate: sampleRate)
        let steady = sineSamples(frequency: 220)
        for step in 0..<4 {
            _ = tracker.process(steady, at: Double(step) * 0.05)
        }
        // One glitchy frame an octave up must not move the smoothed output.
        let glitch = sineSamples(frequency: 440)
        let reading = try XCTUnwrap(tracker.process(glitch, at: 0.2))
        XCTAssertEqual(reading.midiNote, 57, accuracy: 0.1)
        XCTAssertEqual(reading.f0Hz, 220, accuracy: 1)
        // And the tracker recovers once the glitch has left the window.
        var last: PitchReading?
        for step in 5..<10 {
            last = tracker.process(steady, at: Double(step) * 0.05)
        }
        XCTAssertEqual(try XCTUnwrap(last).midiNote, 57, accuracy: 0.1)
    }

    func testReadingCarriesCaptureTime() throws {
        let tracker = PitchTracker(sampleRate: sampleRate)
        let reading = try XCTUnwrap(tracker.process(sineSamples(frequency: 440), at: 12.345))
        XCTAssertEqual(reading.time, 12.345)
        XCTAssertEqual(reading.midiNote, 69, accuracy: 0.1)
        XCTAssertEqual(reading.f0Hz, 440, accuracy: 2)
    }
}
