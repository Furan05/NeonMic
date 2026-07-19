import XCTest
@testable import NeonMicKit

/// CI-safe subset only: `SongPlayer` is hardware-facing, so these tests cover
/// the error paths that never touch a running audio engine. Transport and
/// timing behavior must be exercised manually in the app.
final class SongPlayerTests: XCTestCase {

    func testLoadMissingFileThrowsFileNotFound() {
        let player = SongPlayer()
        let url = URL(fileURLWithPath: "/nonexistent/neon-mic-test.m4a")
        XCTAssertThrowsError(try player.load(fileAt: url)) { error in
            XCTAssertEqual(error as? SongPlayer.PlaybackError, .fileNotFound(url))
        }
    }

    func testLoadNonAudioFileThrowsUnsupportedFormat() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("neonmic-not-audio-\(UUID().uuidString).mp3")
        try Data("definitely not audio".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let player = SongPlayer()
        XCTAssertThrowsError(try player.load(fileAt: url)) { error in
            XCTAssertEqual(error as? SongPlayer.PlaybackError, .unsupportedFormat(url))
        }
    }

    func testTransportWithoutLoadThrowsNoFileLoaded() {
        let player = SongPlayer()
        XCTAssertThrowsError(try player.play()) { error in
            XCTAssertEqual(error as? SongPlayer.PlaybackError, .noFileLoaded)
        }
        XCTAssertThrowsError(try player.seek(to: 10)) { error in
            XCTAssertEqual(error as? SongPlayer.PlaybackError, .noFileLoaded)
        }
    }

    func testIdlePlayerReportsZeroTimeAndDuration() {
        let player = SongPlayer()
        XCTAssertEqual(player.currentTime, 0)
        XCTAssertEqual(player.duration, 0)
        XCTAssertFalse(player.isPlaying)
    }
}
