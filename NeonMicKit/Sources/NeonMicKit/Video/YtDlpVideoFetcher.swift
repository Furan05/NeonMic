import Foundation

/// Downloads a video from a page URL (YouTube and any other site yt-dlp
/// understands) by shelling out to the system `yt-dlp` executable.
///
/// yt-dlp is a *system dependency*, not bundled: install it with
/// `brew install yt-dlp`. The format selector asks for MP4 at up to 1080p
/// first; merged 1080p streams additionally need `ffmpeg` on the PATH
/// (yt-dlp falls back to progressive MP4 without it).
///
/// Sandbox note: a child process inherits the app's sandbox. Network access
/// requires the `com.apple.security.network.client` entitlement, and the
/// output folder must be within the app's granted scope (a user-picked
/// library folder). Homebrew's Python stack is readable from the sandbox,
/// but distribution builds intended for the App Store should treat this
/// fetcher as best-effort and surface ``VideoDownloadError/ytDlpFailed(exitCode:message:)``
/// to the user.
public struct YtDlpVideoFetcher: VideoFetching {

    /// Locations tried, in order, by ``locateExecutable(searchPaths:fileManager:)``.
    public static let defaultSearchPaths = [
        "/opt/homebrew/bin/yt-dlp",
        "/usr/local/bin/yt-dlp",
        "/usr/bin/yt-dlp",
    ]

    /// The resolved yt-dlp binary; nil when none was found at init time.
    public let executableURL: URL?

    /// Creates a fetcher, locating yt-dlp in the default search paths unless
    /// an explicit executable is given.
    public init(executableURL: URL? = YtDlpVideoFetcher.locateExecutable()) {
        self.executableURL = executableURL
    }

    /// Returns the first existing executable among `searchPaths`, or nil.
    /// The `NEONMIC_YTDLP` environment variable, when set, wins over the
    /// built-in paths.
    public static func locateExecutable(
        searchPaths: [String] = defaultSearchPaths,
        fileManager: FileManager = .default
    ) -> URL? {
        var candidates = searchPaths
        if let override = ProcessInfo.processInfo.environment["NEONMIC_YTDLP"] {
            candidates.insert(override, at: 0)
        }
        for path in candidates where fileManager.isExecutableFile(atPath: path) {
            return URL(fileURLWithPath: path)
        }
        return nil
    }

    /// The yt-dlp invocation for `source`, writing to `outputTemplate`
    /// (a yt-dlp `-o` template like `…/Song.%(ext)s`).
    ///
    /// The format selector implements "MP4 at 1080p first": best MP4 video
    /// stream capped at 1080p merged with M4A audio, then progressive MP4,
    /// then anything capped at 1080p. `--newline` makes progress parseable
    /// line by line; `--no-cache-dir` avoids writes outside the sandbox.
    public static func arguments(for source: URL, outputTemplate: String) -> [String] {
        [
            "-f", "bv*[ext=mp4][height<=1080]+ba[ext=m4a]/b[ext=mp4][height<=1080]/bv*[height<=1080]+ba/b",
            "--merge-output-format", "mp4",
            "--no-playlist",
            "--no-cache-dir",
            "--newline",
            "-o", outputTemplate,
            "--", source.absoluteString,
        ]
    }

    /// Parses one `--newline` progress line (`"[download]  42.3% of …"`)
    /// into a 0…1 fraction; returns nil for every other line.
    public static func parseProgressLine(_ line: String) -> Double? {
        let prefix = "[download]"
        guard line.hasPrefix(prefix), let percent = line.firstIndex(of: "%") else { return nil }
        let token = line[line.index(line.startIndex, offsetBy: prefix.count)..<percent]
            .trimmingCharacters(in: .whitespaces)
        guard let value = Double(token), (0...100).contains(value) else { return nil }
        return value / 100
    }

    public func fetchVideo(
        from source: URL,
        into folder: URL,
        baseName: String,
        reporter: VideoFetchReporter
    ) async throws -> URL {
        guard let executableURL else { throw VideoDownloadError.ytDlpNotFound }

        let template = folder.appendingPathComponent(baseName).path + ".%(ext)s"
        let process = Process()
        process.executableURL = executableURL
        process.arguments = Self.arguments(for: source, outputTemplate: template)

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr

        // Feed progress line by line; readabilityHandler delivers arbitrary
        // chunks, so keep the trailing partial line across calls.
        let lineBuffer = LineBuffer()
        stdout.fileHandleForReading.readabilityHandler = { handle in
            for line in lineBuffer.append(handle.availableData) {
                if let fraction = Self.parseProgressLine(line) {
                    reporter.onProgress(DownloadProgress(
                        phase: .fetchingVideo,
                        fractionCompleted: fraction
                    ))
                }
            }
        }

        let status: Int32 = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                process.terminationHandler = { process in
                    continuation.resume(returning: process.terminationStatus)
                }
                do {
                    try process.run()
                } catch {
                    process.terminationHandler = nil
                    continuation.resume(throwing: error)
                }
            }
        } onCancel: {
            process.terminate()
        }
        stdout.fileHandleForReading.readabilityHandler = nil

        try Task.checkCancellation()
        guard status == 0 else {
            let data = stderr.fileHandleForReading.readDataToEndOfFile()
            let message = String(decoding: data, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            throw VideoDownloadError.ytDlpFailed(exitCode: status, message: message)
        }

        // The template's %(ext)s means the exact name depends on the source;
        // resolve it MP4-first, mirroring the format priority.
        let base = folder.appendingPathComponent(baseName)
        for ext in ["mp4", "mov", "mkv", "webm"] {
            let candidate = base.appendingPathExtension(ext)
            if FileManager.default.fileExists(atPath: candidate.path) {
                reporter.onProgress(DownloadProgress(phase: .fetchingVideo, fractionCompleted: 1))
                return candidate
            }
        }
        throw VideoDownloadError.downloadedFileMissing
    }
}

/// Splits an incoming byte stream into complete lines, keeping the trailing
/// partial line between `append` calls. Thread-confined to the pipe's
/// readability handler queue.
private final class LineBuffer: @unchecked Sendable {
    private var pending = Data()

    func append(_ data: Data) -> [String] {
        pending.append(data)
        var lines: [String] = []
        while let newline = pending.firstIndex(of: UInt8(ascii: "\n")) {
            let lineData = pending[pending.startIndex..<newline]
            lines.append(String(decoding: lineData, as: UTF8.self))
            pending.removeSubrange(pending.startIndex...newline)
        }
        return lines
    }
}
