import XCTest
@testable import NeonMicKit

/// yt-dlp detection tests. A stub `FileManager` reports which paths are
/// "executable", so the search order (Homebrew Apple Silicon → Intel → MacPorts
/// → pip → system → PATH) is verified without touching the real filesystem or
/// depending on this machine's PATH.
final class YtDlpWrapperTests: XCTestCase {

    func testPrefersAppleSiliconOverIntelHomebrew() {
        let fileManager = StubFileManager(executablePaths: [
            "/opt/homebrew/bin/yt-dlp", "/usr/local/bin/yt-dlp",
        ])
        let url = YtDlpWrapper.locate(
            environment: [:], homeDirectory: "/Users/t", fileManager: fileManager)
        XCTAssertEqual(url?.path, "/opt/homebrew/bin/yt-dlp", "Apple Silicon Homebrew wins")
    }

    func testFallsBackToIntelHomebrew() {
        let fileManager = StubFileManager(executablePaths: ["/usr/local/bin/yt-dlp"])
        let url = YtDlpWrapper.locate(
            environment: [:], homeDirectory: "/Users/t", fileManager: fileManager)
        XCTAssertEqual(url?.path, "/usr/local/bin/yt-dlp")
    }

    func testSearchesPATHAsFallback() {
        // Not on any well-known absolute path — only reachable via PATH. This is
        // the case that matters when the app's PATH differs from the Terminal's.
        let fileManager = StubFileManager(executablePaths: ["/custom/tools/yt-dlp"])
        let url = YtDlpWrapper.locate(
            environment: ["PATH": "/nope/bin:/custom/tools"],
            homeDirectory: "/Users/t", fileManager: fileManager)
        XCTAssertEqual(url?.path, "/custom/tools/yt-dlp")
    }

    func testOverrideBeatsEverything() {
        let fileManager = StubFileManager(executablePaths: [
            "/opt/homebrew/bin/yt-dlp", "/opt/custom/yt-dlp",
        ])
        let url = YtDlpWrapper.locate(
            environment: ["NEONMIC_YTDLP": "/opt/custom/yt-dlp"],
            homeDirectory: "/Users/t", fileManager: fileManager)
        XCTAssertEqual(url?.path, "/opt/custom/yt-dlp")
    }

    func testExpandsTildeInSearchPaths() {
        let fileManager = StubFileManager(executablePaths: ["/Users/t/.local/bin/yt-dlp"])
        let url = YtDlpWrapper.locate(
            searchPaths: ["~/.local/bin/yt-dlp"], environment: [:],
            homeDirectory: "/Users/t", fileManager: fileManager)
        XCTAssertEqual(url?.path, "/Users/t/.local/bin/yt-dlp")
    }

    func testLocateReturnsNilWhenAbsent() {
        // Controlled empty environment so a real yt-dlp on this machine's PATH
        // can't sneak in.
        let url = YtDlpWrapper.locate(
            searchPaths: ["/nonexistent/yt-dlp"], environment: [:],
            homeDirectory: "/nonexistent", fileManager: StubFileManager(executablePaths: []))
        XCTAssertNil(url)
    }

    // MARK: findExecutablePath

    func testFindExecutablePathReturnsResolvedURL() throws {
        let fileManager = StubFileManager(executablePaths: ["/opt/homebrew/bin/yt-dlp"])
        let url = try YtDlpWrapper.findExecutablePath(
            environment: [:], homeDirectory: "/Users/t", fileManager: fileManager)
        XCTAssertEqual(url.path, "/opt/homebrew/bin/yt-dlp")
    }

    func testFindExecutablePathThrowsWithInstallInstructions() {
        let fileManager = StubFileManager(executablePaths: [])
        XCTAssertThrowsError(try YtDlpWrapper.findExecutablePath(
            environment: [:], homeDirectory: "/nope", fileManager: fileManager)) { error in
            XCTAssertEqual(error as? VideoDownloadError, .ytDlpNotFound)
            let message = (error as? VideoDownloadError)?.errorDescription ?? ""
            XCTAssertTrue(message.contains("brew install yt-dlp ffmpeg"),
                          "message must include the full install command")
            XCTAssertTrue(message.contains("relaunch"),
                          "message must tell the user to relaunch")
            XCTAssertTrue(message.contains("/opt/homebrew/bin"),
                          "message must name the exact searched paths")
        }
    }

    func testInstallCommandIsComplete() {
        XCTAssertEqual(YtDlpWrapper.installCommand, "brew install yt-dlp ffmpeg")
    }
}

/// A FileManager that treats exactly the given paths as executable, so yt-dlp
/// detection can be tested without touching the real filesystem.
private final class StubFileManager: FileManager, @unchecked Sendable {
    private let executablePaths: Set<String>

    init(executablePaths: Set<String>) {
        self.executablePaths = executablePaths
        super.init()
    }

    override func isExecutableFile(atPath path: String) -> Bool {
        executablePaths.contains(path)
    }
}
