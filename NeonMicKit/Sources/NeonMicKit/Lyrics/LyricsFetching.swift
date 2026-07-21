import Foundation

/// A source that can look up lyrics (or a ready-made chart) for a song.
///
/// Implementations sit behind ``HTTPFetching`` / ``CommandRunning`` seams so
/// the pipeline is fully testable offline — the real network and yt-dlp are
/// never touched by tests.
public protocol LyricsFetching: Sendable {
    /// A short display name for the source ("lrclib", "usdb"…).
    var sourceName: String { get }
    /// Looks up `query`, returning the best match or nil when nothing fit.
    func fetch(_ query: LyricsQuery) async throws -> LyricsMatch?
}

/// A source that extracts song metadata from a video URL.
public protocol VideoMetadataFetching: Sendable {
    /// Extracts title/artist/duration for the video at `url`.
    func metadata(for url: URL) async throws -> VideoMetadata
}

// MARK: - HTTP seam

/// Minimal HTTP GET seam so providers can be tested with canned responses.
public protocol HTTPFetching: Sendable {
    /// Performs a GET and returns the body plus the HTTP response.
    func get(_ url: URL) async throws -> (Data, HTTPURLResponse)
}

/// The production ``HTTPFetching`` client, backed by URLSession.
public struct URLSessionHTTPClient: HTTPFetching {
    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func get(_ url: URL) async throws -> (Data, HTTPURLResponse) {
        var request = URLRequest(url: url)
        // lrclib asks clients to identify themselves.
        request.setValue("NeonMic/0.1 (+https://github.com/Furan05/NeonMic)", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw LyricsError.malformedResponse("non-HTTP response")
        }
        return (data, http)
    }
}

// MARK: - Command seam

/// The captured result of running a subprocess.
public struct CommandResult: Sendable {
    public var status: Int32
    public var standardOutput: Data
    public var standardError: Data

    public init(status: Int32, standardOutput: Data, standardError: Data) {
        self.status = status
        self.standardOutput = standardOutput
        self.standardError = standardError
    }
}

/// Seam for running a command-line tool (yt-dlp), so metadata extraction is
/// testable without shelling out.
public protocol CommandRunning: Sendable {
    func run(executable: URL, arguments: [String]) async throws -> CommandResult
}

/// The production ``CommandRunning`` runner, backed by `Process`.
///
/// The child inherits the app sandbox; metadata extraction needs only network
/// access (`--skip-download`), never a write outside granted scope.
public struct ProcessCommandRunner: CommandRunning {
    public init() {}

    public func run(executable: URL, arguments: [String]) async throws -> CommandResult {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                process.terminationHandler = { process in
                    let out = stdout.fileHandleForReading.readDataToEndOfFile()
                    let err = stderr.fileHandleForReading.readDataToEndOfFile()
                    continuation.resume(returning: CommandResult(
                        status: process.terminationStatus, standardOutput: out, standardError: err))
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
    }
}
