import XCTest
@testable import NeonMicKit

/// Deterministic PRNG (xorshift64) so the noise tests never flake.
struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) {
        precondition(seed != 0, "xorshift64 must not be seeded with 0")
        state = seed
    }

    mutating func next() -> UInt64 {
        state ^= state << 13
        state ^= state >> 7
        state ^= state << 17
        return state
    }
}

/// Generates a pure sine, the synthesized stand-in for a steady sung vowel.
func sineSamples(
    frequency: Double,
    sampleRate: Double = 44_100,
    count: Int = 4096,
    amplitude: Float = 0.5
) -> [Float] {
    (0..<count).map { index in
        amplitude * Float(sin(2 * .pi * frequency * Double(index) / sampleRate))
    }
}

final class YinPitchDetectorTests: XCTestCase {

    private let sampleRate = 44_100.0

    func testDetectsA4() throws {
        let detector = YinPitchDetector()
        let frequency = try XCTUnwrap(detector.detectFrequency(in: sineSamples(frequency: 440), sampleRate: sampleRate))
        XCTAssertEqual(MusicalMath.midiNote(fromHz: frequency), 69, accuracy: 0.1)
    }

    func testDetectsA2() throws {
        let detector = YinPitchDetector()
        let frequency = try XCTUnwrap(detector.detectFrequency(in: sineSamples(frequency: 110), sampleRate: sampleRate))
        XCTAssertEqual(MusicalMath.midiNote(fromHz: frequency), 45, accuracy: 0.1)
    }

    func testDetectsSineBuriedInNoise() throws {
        var generator = SeededGenerator(seed: 0x5EED_CAFE)
        // 10% noise relative to a 0.5-amplitude sine.
        let samples = sineSamples(frequency: 440).map { sample in
            sample + Float.random(in: -0.05...0.05, using: &generator)
        }
        let detector = YinPitchDetector()
        let frequency = try XCTUnwrap(detector.detectFrequency(in: samples, sampleRate: sampleRate))
        XCTAssertEqual(MusicalMath.midiNote(fromHz: frequency), 69, accuracy: 0.2)
    }

    func testSilenceReturnsNil() {
        let detector = YinPitchDetector()
        let silence = [Float](repeating: 0, count: 4096)
        XCTAssertNil(detector.detectFrequency(in: silence, sampleRate: sampleRate))
    }

    func testPureNoiseReturnsNil() {
        var generator = SeededGenerator(seed: 0xBAD_5EED)
        let noise = (0..<4096).map { _ in Float.random(in: -0.5...0.5, using: &generator) }
        let detector = YinPitchDetector()
        XCTAssertNil(detector.detectFrequency(in: noise, sampleRate: sampleRate))
    }

    func testDetectorInstanceIsReusableAcrossFrequencies() throws {
        // Scratch buffers are reused between calls; results must not bleed.
        let detector = YinPitchDetector()
        let first = try XCTUnwrap(detector.detectFrequency(in: sineSamples(frequency: 440), sampleRate: sampleRate))
        let second = try XCTUnwrap(detector.detectFrequency(in: sineSamples(frequency: 110), sampleRate: sampleRate))
        XCTAssertEqual(first, 440, accuracy: 1)
        XCTAssertEqual(second, 110, accuracy: 0.5)
    }
}
