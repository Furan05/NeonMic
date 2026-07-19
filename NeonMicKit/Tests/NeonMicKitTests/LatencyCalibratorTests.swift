import XCTest
@testable import NeonMicKit

final class LatencyCalibratorTests: XCTestCase {

    private let ticks: [TimeInterval] = [1, 2, 3, 4, 5]

    func testCleanDataReturnsExactOffset() throws {
        let onsets = ticks.map { $0 + 0.12 }
        let offset = try XCTUnwrap(LatencyCalibrator.offset(tickTimes: ticks, detectedOnsets: onsets))
        XCTAssertEqual(offset, 0.12, accuracy: 1e-9)
    }

    func testOneMissedOnsetStillCalibrates() throws {
        let onsets = [1, 2, 4, 5].map { Double($0) + 0.12 }
        let offset = try XCTUnwrap(LatencyCalibrator.offset(tickTimes: ticks, detectedOnsets: onsets))
        XCTAssertEqual(offset, 0.12, accuracy: 1e-9)
    }

    func testOneWildOutlierIsRejected() throws {
        // The clap for tick 3 registered nowhere near any tick.
        let onsets = [1.12, 2.12, 3.45, 4.12, 5.12]
        let offset = try XCTUnwrap(LatencyCalibrator.offset(tickTimes: ticks, detectedOnsets: onsets))
        XCTAssertEqual(offset, 0.12, accuracy: 1e-9)
    }

    func testDoubleTriggerKeepsClosestOnsetPerTick() throws {
        // Tick 2 fired the detector twice; the echo (+0.30) must lose to +0.12.
        let onsets = [1.12, 2.12, 2.30, 3.12, 4.12, 5.12]
        let offset = try XCTUnwrap(LatencyCalibrator.offset(tickTimes: ticks, detectedOnsets: onsets))
        XCTAssertEqual(offset, 0.12, accuracy: 1e-9)
    }

    func testFewerThanThreeValidPairsReturnsNil() {
        XCTAssertNil(LatencyCalibrator.offset(tickTimes: [1, 2, 3], detectedOnsets: [1.12, 2.12]))
        XCTAssertNil(LatencyCalibrator.offset(tickTimes: ticks, detectedOnsets: []))
        XCTAssertNil(LatencyCalibrator.offset(tickTimes: [], detectedOnsets: [1.12, 2.12, 3.12]))
    }

    func testNegativeOffsetIsSupported() throws {
        // Onset detection can report slightly early (analysis window bias).
        let onsets = ticks.map { $0 - 0.05 }
        let offset = try XCTUnwrap(LatencyCalibrator.offset(tickTimes: ticks, detectedOnsets: onsets))
        XCTAssertEqual(offset, -0.05, accuracy: 1e-9)
    }
}
